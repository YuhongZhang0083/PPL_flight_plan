import SwiftUI
import MapKit

/// GPS taxi map: runways (FAA/OurAirports geometry) plus OpenStreetMap taxiways, aprons, buildings and hold lines.
struct TaxiDiagramView: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    @State private var layout: AirportLayout?
    @State private var error: String?
    @State private var satellite = false
    @State private var trackUp = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TaxiMapView(airport: airport, layout: layout, satellite: satellite, trackUp: trackUp,
                        ownship: model.flight.hasPosition ? model.flight.coordinate.map { ($0, model.flight.trackTrue, model.flight.groundSpeedKt) } : nil)
                .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 4) {
                if layout == nil && error == nil { HStack { ProgressView(); Text("Loading taxiways…") }.font(.caption) }
                if let error { Text("Taxiway data unavailable (\(error)). Runways shown from the airport database.").font(.caption) }
                if let l = layout, l.isEmpty { Text("No taxiway data in OpenStreetMap for this airport.").font(.caption) }
                if model.flight.hasPosition, model.flight.groundSpeedKt < 40, let c = model.flight.coordinate, Geo.distanceNM(c, airport.coordinate) < 3 {
                    Text("GS \(Int(model.flight.groundSpeedKt)) kt").font(.headline.monospacedDigit())
                }
                Text("Situational awareness only — follow ATC instructions, signs and markings. Map data © OpenStreetMap contributors.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .padding(10)
        }
        .navigationTitle("\(airport.displayIdent) Taxi Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { trackUp.toggle() } label: { Image(systemName: trackUp ? "location.north.line.fill" : "location.north.line") }
                Button { satellite.toggle() } label: { Image(systemName: satellite ? "globe.americas.fill" : "globe.americas") }
            }
        }
        .task {
            do { layout = try await OverpassService.layout(for: airport) } catch { self.error = error.localizedDescription }
        }
    }
}

final class TaxiPolyline: MKPolyline { var kind = "" }
final class TaxiPolygon: MKPolygon { var kind = "" }
final class TaxiLabel: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let text: String
    let kind: String
    init(_ c: CLLocationCoordinate2D, _ t: String, _ k: String) { coordinate = c; text = t; kind = k }
}

struct TaxiMapView: UIViewRepresentable {
    let airport: Airport
    let layout: AirportLayout?
    let satellite: Bool
    let trackUp: Bool
    let ownship: (CLLocationCoordinate2D, Double, Double)?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var drawnLayout = false
        var drawnRunways = false
        var own: OwnshipAnnotation?
        var satellite: Bool?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let p = overlay as? TaxiPolygon {
                let r = MKPolygonRenderer(polygon: p)
                switch p.kind {
                case "runway": r.fillColor = UIColor(white: 0.12, alpha: 1); r.strokeColor = .white; r.lineWidth = 1.5
                case "apron": r.fillColor = UIColor(white: 0.45, alpha: 0.55); r.strokeColor = UIColor(white: 0.7, alpha: 0.6); r.lineWidth = 0.5
                default: r.fillColor = UIColor(red: 0.35, green: 0.4, blue: 0.5, alpha: 0.7); r.strokeColor = UIColor(white: 0.8, alpha: 0.5); r.lineWidth = 0.5
                }
                return r
            }
            if let l = overlay as? TaxiPolyline {
                let r = MKPolylineRenderer(polyline: l)
                switch l.kind {
                case "holding_position": r.strokeColor = .systemRed; r.lineWidth = 4
                case "runway": r.strokeColor = UIColor(white: 0.15, alpha: 1); r.lineWidth = 14
                case "centerline": r.strokeColor = UIColor.white; r.lineWidth = 1.2; r.lineDashPattern = [8, 6]
                default: r.strokeColor = UIColor(red: 0.98, green: 0.82, blue: 0.1, alpha: 1); r.lineWidth = 2.5
                }
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let o = annotation as? OwnshipAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "own") ?? MKAnnotationView(annotation: o, reuseIdentifier: "own")
                v.annotation = o
                v.image = MarkerImages.ownship
                v.zPriority = .max
                v.transform = CGAffineTransform(rotationAngle: CGFloat(Geo.rad(o.track - mapView.camera.heading)))
                return v
            }
            if let l = annotation as? TaxiLabel {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "lbl") ?? MKAnnotationView(annotation: l, reuseIdentifier: "lbl")
                v.annotation = l
                let font = UIFont.systemFont(ofSize: l.kind == "runway" ? 13 : 11, weight: .heavy)
                let ts = (l.text as NSString).size(withAttributes: [.font: font])
                let size = CGSize(width: ts.width + 8, height: ts.height + 4)
                v.image = UIGraphicsImageRenderer(size: size).image { _ in
                    let bg: UIColor = l.kind == "runway" ? UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1) : UIColor.black
                    bg.setFill()
                    UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3).fill()
                    let fg: UIColor = l.kind == "runway" ? .white : UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
                    (l.text as NSString).draw(at: CGPoint(x: 4, y: 2), withAttributes: [.font: font, .foregroundColor: fg])
                }
                v.displayPriority = l.kind == "runway" ? .required : .defaultHigh
                v.collisionMode = .rectangle
                return v
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.overrideUserInterfaceStyle = .dark
        m.pointOfInterestFilter = .excludingAll
        m.showsCompass = true
        let span = max(0.012, Double(airport.longestRunwayFt) / 6076 / 60 * 1.3)
        m.setRegion(MKCoordinateRegion(center: airport.coordinate, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span / cos(Geo.rad(airport.lat)))), animated: false)
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        let c = context.coordinator
        if c.satellite != satellite {
            c.satellite = satellite
            m.preferredConfiguration = satellite ? MKImageryMapConfiguration() : MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        }
        if !c.drawnRunways {
            c.drawnRunways = true
            for r in airport.runways {
                guard let a = r.leCoord, let b = r.heCoord else { continue }
                let brg = Geo.bearing(a, b)
                let halfW = Double(max(r.widthFt, 50)) / 2 / Geo.feetPerMeter / Geo.metersPerNM
                var pts = [Geo.destination(a, bearing: brg - 90, distanceNM: halfW), Geo.destination(b, bearing: brg - 90, distanceNM: halfW),
                           Geo.destination(b, bearing: brg + 90, distanceNM: halfW), Geo.destination(a, bearing: brg + 90, distanceNM: halfW)]
                let poly = TaxiPolygon(coordinates: &pts, count: 4)
                poly.kind = "runway"
                m.addOverlay(poly, level: .aboveLabels)
                var cl = [a, b]
                let line = TaxiPolyline(coordinates: &cl, count: 2)
                line.kind = "centerline"
                m.addOverlay(line, level: .aboveLabels)
                m.addAnnotation(TaxiLabel(Geo.destination(a, bearing: brg, distanceNM: 0.03), r.le, "runway"))
                m.addAnnotation(TaxiLabel(Geo.destination(b, bearing: brg + 180, distanceNM: 0.03), r.he, "runway"))
            }
        }
        if let l = layout, !c.drawnLayout {
            c.drawnLayout = true
            var under: [MKOverlay] = [], over: [MKOverlay] = []
            var labels: [TaxiLabel] = []
            for a in l.areas where a.kind != "runway" {
                var pts = a.coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                let p = TaxiPolygon(coordinates: &pts, count: pts.count)
                p.kind = a.kind == "apron" ? "apron" : "building"
                under.append(p)
            }
            var refsSeen: [String: Int] = [:]
            for line in l.lines where line.kind != "runway" {
                var pts = line.coords.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                let p = TaxiPolyline(coordinates: &pts, count: pts.count)
                p.kind = line.kind
                over.append(p)
                if (line.kind == "taxiway" || line.kind == "taxilane"), !line.ref.isEmpty, pts.count >= 2, (refsSeen[line.ref] ?? 0) < 3 {
                    refsSeen[line.ref, default: 0] += 1
                    labels.append(TaxiLabel(pts[pts.count / 2], line.ref, "taxiway"))
                }
            }
            for p in l.points where p.kind == "holding_position" {
                labels.append(TaxiLabel(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), p.ref.isEmpty ? "HOLD" : p.ref, "hold"))
            }
            for (i, o) in under.enumerated() { m.insertOverlay(o, at: i, level: .aboveLabels) }
            m.addOverlays(over, level: .aboveLabels)
            m.addAnnotations(labels)
        }
        if let o = ownship {
            if let a = c.own { a.coordinate = o.0; a.track = o.1 } else {
                let a = OwnshipAnnotation(coordinate: o.0); a.track = o.1; m.addAnnotation(a); c.own = a
            }
            if let a = c.own, let v = m.view(for: a) { v.transform = CGAffineTransform(rotationAngle: CGFloat(Geo.rad(o.1 - m.camera.heading))) }
            if trackUp {
                let cam = m.camera
                cam.centerCoordinate = o.0
                cam.heading = o.1
                m.setCamera(cam, animated: true)
            }
        } else if let a = c.own {
            m.removeAnnotation(a); c.own = nil
        }
        if !trackUp && m.camera.heading != 0 {
            let cam = m.camera; cam.heading = 0; m.setCamera(cam, animated: true)
        }
    }
}
