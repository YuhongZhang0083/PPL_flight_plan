import SwiftUI
import MapKit

struct OwnshipSnapshot: Equatable {
    var coordinate: CLLocationCoordinate2D
    var track: Double
    var groundSpeed: Double
    var altitudeFt: Double
    static func == (a: OwnshipSnapshot, b: OwnshipSnapshot) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.track == b.track
    }
}

/// MKMapView wrapper hosting FAA chart tiles, weather/hazard layers, route, airports and ownship.
struct ChartMapView: UIViewRepresentable {
    var settings: AppSettings
    var route: [Waypoint]
    var ownship: OwnshipSnapshot?
    var focus: MapFocus?
    var airports: [Airport]
    var metars: [String: METAR]
    var obstacles: [Obstacle]
    var windGrid: WindGrid?
    var windTimeIndex: Int
    var hazardAltitude: Double
    var radarStamp: Int
    var glideRadiusNM: Double?
    var follow: Bool
    var pin: CLLocationCoordinate2D?
    var onSelectAirport: (Airport) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onRegionChange: (MKCoordinateRegion) -> Void
    var onUserGesture: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "apt")
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "own")
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "obs")
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "wp")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")
        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        lp.minimumPressDuration = 0.5
        map.addGestureRecognizer(lp)
        let particles = WindParticleView(frame: .zero)
        particles.mapView = map
        particles.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(particles)
        NSLayoutConstraint.activate([
            particles.leadingAnchor.constraint(equalTo: map.leadingAnchor), particles.trailingAnchor.constraint(equalTo: map.trailingAnchor),
            particles.topAnchor.constraint(equalTo: map.topAnchor), particles.bottomAnchor.constraint(equalTo: map.bottomAnchor),
        ])
        context.coordinator.particles = particles
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ChartMapView
        weak var particles: WindParticleView?

        private var chartOverlay: ChartTileOverlay?
        private var radarOverlay: RadarTileOverlay?
        private var hazardOverlay: HazardTileOverlay?
        private var hazardRenderer: MKTileOverlayRenderer?
        private var windOverlay: WindHeatOverlay?
        private var routeLine: MKPolyline?
        private var routeSignature = ""
        private var rings: [MKCircle] = []
        private var ringCenter: CLLocationCoordinate2D?
        private var glideCircle: MKCircle?
        private var trackVector: MKPolyline?
        private var lastVector: (CLLocationCoordinate2D, Double)?
        private var ownshipAnn: OwnshipAnnotation?
        private var airportAnns: [String: AirportAnnotation] = [:]
        private var obstacleAnns: [String: ObstacleAnnotation] = [:]
        private var waypointAnns: [WaypointAnnotation] = []
        private var pinAnn: PinAnnotation?
        private var lastFocusID: UUID?
        private var lastFocusTime = Date.distantPast
        private var baseMap: BaseMap?
        private var lastHazardAlt: Double = -1
        private var userGesture = false

        init(_ parent: ChartMapView) { self.parent = parent }

        // MARK: Update

        func update(_ map: MKMapView) {
            let p = parent
            applyBaseMap(map, p.settings.baseMap)
            updateTileOverlays(map, p)
            updateRoute(map, p.route)
            updateOwnship(map, p)
            updateAirports(map, p)
            updateObstacles(map, p)
            updatePin(map, p.pin)
            if let f = p.focus, f.id != lastFocusID {
                lastFocusID = f.id
                lastFocusTime = Date()
                let span = MKCoordinateSpan(latitudeDelta: f.spanDegrees, longitudeDelta: f.spanDegrees / max(0.3, cos(Geo.rad(f.center.latitude))))
                map.setRegion(MKCoordinateRegion(center: f.center, span: span), animated: true)
            }
        }

        private func applyBaseMap(_ map: MKMapView, _ b: BaseMap) {
            guard b != baseMap else { return }
            baseMap = b
            switch b {
            case .standard: map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
            case .muted: map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            case .satellite: map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .hybrid: map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
            }
        }

        /// Keeps tile overlays ordered: chart < hazard < radar < winds, all below vectors.
        private func insertTile(_ map: MKMapView, _ o: MKOverlay, rank: Int) {
            let present: [(MKOverlay?, Int)] = [(chartOverlay, 0), (hazardOverlay, 1), (radarOverlay, 2), (windOverlay, 3)]
            let below = present.filter { $0.0 != nil && $0.1 < rank && !($0.0 === o) }.count
            map.insertOverlay(o, at: below, level: .aboveLabels)
        }

        private func updateTileOverlays(_ map: MKMapView, _ p: ChartMapView) {
            // Chart
            let layer = p.settings.chartLayer
            if chartOverlay?.layer != layer {
                if let o = chartOverlay { map.removeOverlay(o); chartOverlay = nil }
                if layer != .none {
                    let o = ChartTileOverlay(layer: layer)
                    insertTile(map, o, rank: 0)
                    chartOverlay = o
                }
            }
            // Hazard
            if p.settings.showHazard {
                if hazardOverlay == nil {
                    let o = HazardTileOverlay(urlTemplate: nil)
                    o.altitudeFt = p.hazardAltitude
                    lastHazardAlt = p.hazardAltitude
                    hazardOverlay = o
                    insertTile(map, o, rank: 1)
                } else if abs(p.hazardAltitude - lastHazardAlt) >= 100 {
                    lastHazardAlt = p.hazardAltitude
                    hazardOverlay?.altitudeFt = p.hazardAltitude
                    hazardRenderer?.reloadData()
                }
            } else if let o = hazardOverlay {
                map.removeOverlay(o); hazardOverlay = nil; hazardRenderer = nil
            }
            // Radar
            if p.settings.showRadar {
                if radarOverlay?.stamp != p.radarStamp {
                    if let o = radarOverlay { map.removeOverlay(o) }
                    let o = RadarTileOverlay(stamp: p.radarStamp)
                    radarOverlay = o
                    insertTile(map, o, rank: 2)
                }
            } else if let o = radarOverlay {
                map.removeOverlay(o); radarOverlay = nil
            }
            // Winds
            if p.settings.showWinds, let g = p.windGrid {
                if windOverlay == nil || windOverlay!.grid !== g || windOverlay!.timeIndex != p.windTimeIndex || windOverlay!.showSpeed != p.settings.windsShowSpeed {
                    if let o = windOverlay { map.removeOverlay(o) }
                    let o = WindHeatOverlay(grid: g, timeIndex: p.windTimeIndex, showSpeed: p.settings.windsShowSpeed)
                    windOverlay = o
                    insertTile(map, o, rank: 3)
                }
                if particles?.grid !== g { particles?.grid = g }
                particles?.timeIndex = p.windTimeIndex
                particles?.start()
                particles?.isHidden = false
            } else {
                if let o = windOverlay { map.removeOverlay(o); windOverlay = nil }
                particles?.stop()
                particles?.isHidden = true
            }
        }

        private func updateRoute(_ map: MKMapView, _ route: [Waypoint]) {
            let sig = route.map { "\($0.ident)@\($0.lat),\($0.lon)" }.joined(separator: ";")
            guard sig != routeSignature else { return }
            routeSignature = sig
            if let l = routeLine { map.removeOverlay(l); routeLine = nil }
            map.removeAnnotations(waypointAnns)
            waypointAnns = []
            guard route.count >= 2 else { return }
            let coords = Geo.densify(route.map(\.coordinate), stepNM: 10)
            let line = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(line, level: .aboveLabels)
            routeLine = line
            waypointAnns = route.filter { $0.kind != .airport }.map { WaypointAnnotation($0) }
            map.addAnnotations(waypointAnns)
        }

        private func updateOwnship(_ map: MKMapView, _ p: ChartMapView) {
            guard let o = p.ownship else {
                if let a = ownshipAnn { map.removeAnnotation(a); ownshipAnn = nil }
                map.removeOverlays(rings); rings = []; ringCenter = nil
                if let g = glideCircle { map.removeOverlay(g); glideCircle = nil }
                if let t = trackVector { map.removeOverlay(t); trackVector = nil }
                return
            }
            if let a = ownshipAnn {
                a.coordinate = o.coordinate
                a.track = o.track
            } else {
                let a = OwnshipAnnotation(coordinate: o.coordinate)
                a.track = o.track
                map.addAnnotation(a)
                ownshipAnn = a
            }
            if let a = ownshipAnn, let v = map.view(for: a) {
                v.transform = CGAffineTransform(rotationAngle: CGFloat(Geo.rad(o.track - map.camera.heading)))
            }
            // Range rings + glide ring (refresh when moved > 0.1 nm)
            let moved = ringCenter.map { Geo.distanceNM($0, o.coordinate) > 0.1 } ?? true
            if moved || (rings.isEmpty == p.settings.showRangeRings) {
                map.removeOverlays(rings)
                rings = []
                if p.settings.showRangeRings {
                    rings = [5.0, 10.0, 20.0].map { MKCircle(center: o.coordinate, radius: $0 * Geo.metersPerNM) }
                    map.addOverlays(rings, level: .aboveLabels)
                }
                if let g = glideCircle { map.removeOverlay(g); glideCircle = nil }
                if p.settings.showGlideRing, let r = p.glideRadiusNM, r > 0.2 {
                    let g = MKCircle(center: o.coordinate, radius: r * Geo.metersPerNM)
                    g.title = "glide"
                    map.addOverlay(g, level: .aboveLabels)
                    glideCircle = g
                }
                ringCenter = o.coordinate
            }
            // Track vector (refresh only on meaningful change to avoid overlay churn)
            let vectorStale = lastVector.map { Geo.distanceNM($0.0, o.coordinate) > 0.03 || abs(Geo.angleDiff($0.1, o.track)) > 2 } ?? true
            if vectorStale || (p.settings.trackVectorMinutes > 0 && o.groundSpeed > 20) != (trackVector != nil) {
                lastVector = (o.coordinate, o.track)
                if let t = trackVector { map.removeOverlay(t); trackVector = nil }
            }
            if trackVector == nil && p.settings.trackVectorMinutes > 0 && o.groundSpeed > 20 {
                let end = Geo.destination(o.coordinate, bearing: o.track, distanceNM: o.groundSpeed * Double(p.settings.trackVectorMinutes) / 60)
                var pts = [o.coordinate, end]
                let t = MKPolyline(coordinates: &pts, count: 2)
                t.title = "vector"
                map.addOverlay(t, level: .aboveLabels)
                trackVector = t
            }
            if p.follow && Date().timeIntervalSince(lastFocusTime) > 1.2 {
                // Only move the camera when the aircraft has drifted from the centre (avoids a region-change feedback loop).
                let rect = map.visibleMapRect
                let c = MKMapPoint(map.centerCoordinate), q = MKMapPoint(o.coordinate)
                let drift = hypot(c.x - q.x, c.y - q.y) / max(1, rect.width)
                let wantHeading = p.settings.trackUp ? o.track : 0
                let headingOff = abs(Geo.angleDiff(map.camera.heading, wantHeading)) > 3
                if drift > 0.01 || headingOff {
                    let cam = map.camera.copy() as! MKMapCamera
                    cam.centerCoordinate = o.coordinate
                    cam.heading = wantHeading
                    map.setCamera(cam, animated: false)
                }
            }
        }

        private func updateAirports(_ map: MKMapView, _ p: ChartMapView) {
            let wanted = p.settings.showAirports ? p.airports : []
            let ids = Set(wanted.map(\.ident))
            var remove: [AirportAnnotation] = []
            for (k, a) in airportAnns where !ids.contains(k) { remove.append(a); airportAnns[k] = nil }
            map.removeAnnotations(remove)
            var add: [AirportAnnotation] = []
            for a in wanted {
                let cat = p.metars[a.weatherIdent]?.category
                if let existing = airportAnns[a.ident] {
                    if existing.category != cat {
                        existing.category = cat
                        if let v = map.view(for: existing) { configureAirportView(v, existing, map) }
                    }
                } else {
                    let ann = AirportAnnotation(airport: a, category: cat)
                    airportAnns[a.ident] = ann
                    add.append(ann)
                }
            }
            map.addAnnotations(add)
        }

        private func updateObstacles(_ map: MKMapView, _ p: ChartMapView) {
            let wanted = p.settings.showObstacles ? p.obstacles : []
            let ids = Set(wanted.map(\.id))
            var remove: [ObstacleAnnotation] = []
            for (k, a) in obstacleAnns where !ids.contains(k) { remove.append(a); obstacleAnns[k] = nil }
            map.removeAnnotations(remove)
            var add: [ObstacleAnnotation] = []
            for o in wanted where obstacleAnns[o.id] == nil {
                let a = ObstacleAnnotation(o)
                obstacleAnns[o.id] = a
                add.append(a)
            }
            map.addAnnotations(add)
            if abs(p.hazardAltitude - lastObstacleAlt) >= 100 {
                lastObstacleAlt = p.hazardAltitude
                for a in obstacleAnns.values { if let v = map.view(for: a) { v.image = obstacleImage(a.obstacle) } }
            }
        }
        private var lastObstacleAlt: Double = -1

        private func updatePin(_ map: MKMapView, _ c: CLLocationCoordinate2D?) {
            if let c {
                if let a = pinAnn { a.coordinate = c } else { let a = PinAnnotation(c); pinAnn = a; map.addAnnotation(a) }
            } else if let a = pinAnn {
                map.removeAnnotation(a); pinAnn = nil
            }
        }

        private func obstacleImage(_ o: Obstacle) -> UIImage {
            let alt = parent.hazardAltitude
            let color: UIColor = o.amslFt >= alt - 100 ? UIColor(Theme.hazardRed) : (o.amslFt >= alt - 1000 ? UIColor(Theme.hazardYellow) : UIColor(white: 0.85, alpha: 1))
            return MarkerImages.obstacle(color: color, tall: o.aglFt >= 1000)
        }

        private func configureAirportView(_ v: MKAnnotationView, _ a: AirportAnnotation, _ map: MKMapView) {
            let showLabel = map.region.span.latitudeDelta < 3 || a.airport.rank >= 2
            let color: UIColor = a.category != nil ? Theme.uiCategory(a.category) : (a.airport.isTowered ? UIColor(red: 0.3, green: 0.55, blue: 0.95, alpha: 1) : UIColor(red: 0.75, green: 0.3, blue: 0.75, alpha: 1))
            v.image = MarkerImages.airport(ident: a.airport.displayIdent, color: color, rank: a.airport.rank, towered: a.airport.isTowered, showLabel: showLabel)
            let r: CGFloat = a.airport.rank >= 2 ? 9 : 7.5
            v.centerOffset = CGPoint(x: (v.image?.size.width ?? 0) / 2 - r, y: 0)
            v.displayPriority = a.airport.rank >= 3 ? .required : (a.airport.rank == 2 ? .defaultHigh : (a.category != nil ? .defaultHigh : .defaultLow))
            v.collisionMode = .circle
        }

        // MARK: Delegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let a as AirportAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "apt", for: a)
                v.canShowCallout = false
                configureAirportView(v, a, mapView)
                return v
            case let a as OwnshipAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "own", for: a)
                v.image = MarkerImages.ownship
                v.zPriority = .max
                v.displayPriority = .required
                v.canShowCallout = false
                v.transform = CGAffineTransform(rotationAngle: CGFloat(Geo.rad(a.track - mapView.camera.heading)))
                return v
            case let a as ObstacleAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "obs", for: a)
                v.image = obstacleImage(a.obstacle)
                v.canShowCallout = true
                v.displayPriority = .defaultLow
                v.centerOffset = CGPoint(x: 0, y: -(v.image?.size.height ?? 0) / 2)
                return v
            case let a as WaypointAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "wp", for: a)
                v.image = MarkerImages.waypoint(a.waypoint.ident)
                v.centerOffset = CGPoint(x: ((v.image?.size.width ?? 0) - 16) / 2, y: 0)
                v.displayPriority = .required
                return v
            case let a as PinAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: a) as! MKMarkerAnnotationView
                v.markerTintColor = .systemOrange
                v.glyphImage = UIImage(systemName: "mappin")
                return v
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let o as HazardTileOverlay:
                let r = MKTileOverlayRenderer(tileOverlay: o)
                hazardRenderer = r
                return r
            case let o as RadarTileOverlay:
                let r = MKTileOverlayRenderer(tileOverlay: o)
                r.alpha = 0.65
                return r
            case let o as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: o)
            case let o as WindHeatOverlay:
                return WindHeatRenderer(overlay: o)
            case let o as MKPolyline:
                let r = MKPolylineRenderer(polyline: o)
                if o.title == "vector" {
                    r.strokeColor = UIColor.white.withAlphaComponent(0.9)
                    r.lineWidth = 2.5
                    r.lineDashPattern = [6, 4]
                } else {
                    r.strokeColor = UIColor(Theme.magenta)
                    r.lineWidth = 5
                }
                return r
            case let o as MKCircle:
                let r = MKCircleRenderer(circle: o)
                if o.title == "glide" {
                    r.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9)
                    r.lineWidth = 2
                    r.lineDashPattern = [8, 5]
                    r.fillColor = UIColor.systemGreen.withAlphaComponent(0.05)
                } else {
                    r.strokeColor = UIColor.white.withAlphaComponent(0.55)
                    r.lineWidth = 1.2
                }
                return r
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if let a = annotation as? AirportAnnotation {
                parent.onSelectAirport(a.airport)
                mapView.deselectAnnotation(annotation, animated: false)
            } else if let w = annotation as? WaypointAnnotation, let a = (parent.airports.first { $0.displayIdent == w.waypoint.ident }) {
                parent.onSelectAirport(a)
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if let gs = mapView.subviews.first?.gestureRecognizers, gs.contains(where: { $0.state == .began || $0.state == .changed }) {
                userGesture = true
                parent.onUserGesture()
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionChange(mapView.region)
            // Labels depend on zoom; refresh airport images when zoom bucket changes.
            let bucket = mapView.region.span.latitudeDelta < 3
            if bucket != lastLabelBucket {
                lastLabelBucket = bucket
                for a in airportAnns.values { if let v = mapView.view(for: a) { configureAirportView(v, a, mapView) } }
            }
            if let a = ownshipAnn, let v = mapView.view(for: a) {
                v.transform = CGAffineTransform(rotationAngle: CGFloat(Geo.rad(a.track - mapView.camera.heading)))
            }
        }
        private var lastLabelBucket: Bool?

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            parent.onLongPress(c)
        }
    }
}
