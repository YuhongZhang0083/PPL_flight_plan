import SwiftUI
import MapKit

/// Maps tab: moving map with charts, layers, route, instruments, synthetic vision split and profile.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var regionBox = RegionBox()
    @State private var screenSize = CGSize(width: 400, height: 800)
    private var region: MKCoordinateRegion? { regionBox.region }
    @State private var visibleAirports: [Airport] = []
    @State private var obstacles: [Obstacle] = []
    @State private var follow = false
    @State private var showLayers = false
    @State private var showRouteEditor = false
    @State private var pin: CLLocationCoordinate2D?
    @State private var pinInfo: PinInfo?
    @State private var radarStamp = Int(Date().timeIntervalSince1970 / 300)
    @State private var windTask: Task<Void, Never>?
    @State private var windStatus = ""
    @State private var groundElevation: Double?
    @State private var lastElevationQuery = Date.distantPast

    struct PinInfo: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        var elevationFt: Double?
    }

    private var hazardAltitude: Double {
        if model.flight.isAirborne { return model.flight.altitudeFt }
        return model.settings.hazardAltitudeFt
    }

    private var ownship: OwnshipSnapshot? {
        guard model.flight.hasPosition, let c = model.flight.coordinate else { return nil }
        return OwnshipSnapshot(coordinate: c, track: model.flight.trackTrue, groundSpeed: model.flight.groundSpeedKt, altitudeFt: model.flight.altitudeFt)
    }

    private var glideRadius: Double? {
        guard model.flight.isAirborne, let g = groundElevation else { return nil }
        return model.activeAircraft.glideRangeNM(heightAGLFt: model.flight.altitudeFt - g)
    }

    var body: some View {
        // Layout without a GeometryReader closure so every observable read happens in `body` (keeps the map in sync).
        let wide = screenSize.width > screenSize.height && screenSize.width > 700
        ZStack(alignment: .top) {
            if model.showSyntheticVision {
                if wide {
                    HStack(spacing: 0) {
                        SyntheticVisionView().frame(width: screenSize.width * 0.42)
                        mapStack
                    }
                } else {
                    VStack(spacing: 0) {
                        SyntheticVisionView().frame(height: max(200, screenSize.height * 0.42))
                        mapStack
                    }
                }
            } else {
                mapStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
        .background(Theme.navy)
        .inspector(isPresented: Binding(get: { model.mapSelectedAirport != nil }, set: { if !$0 { model.mapSelectedAirport = nil } })) {
            if let a = model.mapSelectedAirport {
                AirportSheet(airport: a, compact: true)
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 480)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showLayers) {
            LayerPicker()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showRouteEditor) {
            NavigationStack { RouteEditorView() }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $pinInfo, onDismiss: { pin = nil }) { info in
            PinSheet(info: info)
                .presentationDetents([.medium])
        }
        .onChange(of: model.settings.showWinds) { _, on in if on { loadWinds() } }
        .onChange(of: model.db.airportCount) { _, _ in if let r = region { regionChanged(r) } }
        .onChange(of: model.simulator.isRunning) { _, running in if running { follow = true } }
        .onChange(of: model.settings.showObstacles) { _, _ in if let r = region { regionChanged(r) } }
        .onChange(of: model.settings.windsLevel) { _, _ in loadWinds() }
        .onChange(of: model.flight.coordinate?.latitude) { _, _ in updateGroundElevation() }
        .task {
            // Refresh radar every 5 minutes while visible
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                radarStamp = Int(Date().timeIntervalSince1970 / 300)
            }
        }
    }

    private var mapStack: some View {
        ZStack(alignment: .top) {
            ChartMapView(
                settings: model.settings,
                route: model.routeWaypoints,
                ownship: ownship,
                focus: model.mapFocus,
                airports: visibleAirports,
                metars: model.weather.metars,
                obstacles: obstacles,
                windGrid: model.windGrid,
                windTimeIndex: model.windTimeIndex,
                hazardAltitude: hazardAltitude,
                radarStamp: radarStamp,
                glideRadiusNM: glideRadius,
                follow: follow,
                pin: pin,
                onSelectAirport: { a in model.mapSelectedAirport = a; model.noteRecent(a.ident) },
                onLongPress: { c in
                    pin = c
                    pinInfo = PinInfo(coordinate: c)
                },
                onRegionChange: { r in regionChanged(r) },
                onUserGesture: { follow = false }
            )
            .ignoresSafeArea(edges: [.horizontal, .bottom])

            // Top and bottom overlays are independent layers so a short map (synthetic vision split) never pushes panels off-screen.
            VStack(spacing: 8) {
                InstrumentStrip()
                topControls
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    // MARK: Controls

    private var topControls: some View {
        HStack(alignment: .top) {
            RouteBar(onEdit: { showRouteEditor = true })
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                MapButton(system: "square.3.layers.3d", active: false) { showLayers = true }
                MapButton(system: follow ? "location.fill" : "location", active: follow) {
                    follow.toggle()
                    if follow, let c = model.flight.coordinate { model.mapFocus = MapFocus(center: c, spanDegrees: 0.5) }
                }
                MapButton(system: model.settings.trackUp ? "location.north.line.fill" : "location.north.line", active: model.settings.trackUp) {
                    model.settings.trackUp.toggle()
                }
                MapButton(system: "mountain.2", active: model.showSyntheticVision) { model.showSyntheticVision.toggle() }
                MapButton(system: "chart.xyaxis.line", active: model.showProfile) { model.showProfile.toggle() }
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 8) {
            if model.simulator.isRunning {
                SimulatorBar()
            }
            if model.settings.showHazard {
                HazardBar(airborne: model.flight.isAirborne, altitude: hazardAltitude)
            }
            if model.settings.showWinds {
                WindsBar(status: windStatus)
            }
            if model.showProfile {
                RouteProfileView()
                    .frame(height: hSize == .regular ? 190 : (model.showSyntheticVision ? 118 : 150))
            }
        }
    }

    // MARK: Data loading

    /// Holds the latest map region without triggering SwiftUI re-renders (the map reports it many times a second while following).
    final class RegionBox { var region: MKCoordinateRegion?; var task: Task<Void, Never>? }

    private func regionChanged(_ r: MKCoordinateRegion) {
        regionBox.region = r
        guard regionBox.task == nil else { return }   // throttle: the pending task reads the latest region when it fires
        let box = regionBox
        box.task = Task {
            try? await Task.sleep(for: .milliseconds(450))
            box.task = nil
            guard let r = regionBox.region else { return }
            let minLat = r.center.latitude - r.span.latitudeDelta / 2, maxLat = r.center.latitude + r.span.latitudeDelta / 2
            let minLon = r.center.longitude - r.span.longitudeDelta / 2, maxLon = r.center.longitude + r.span.longitudeDelta / 2
            let span = r.span.latitudeDelta
            let minRank = span > 6 ? 3 : (span > 2.5 ? 2 : (span > 0.7 ? 1 : 0))
            if let idx = model.db.index {
                let list = idx.airports(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, minRank: minRank, limit: span > 2.5 ? 250 : 400)
                if list.map(\.ident) != visibleAirports.map(\.ident) { visibleAirports = list }
            }
            if span < 8 {
                let weather = model.weather
                Task { await weather.fetchMETARs(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }
            }
            if model.settings.showObstacles && span < 1.6 {
                Task {
                    let list = await ObstacleService.shared.obstacles(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
                    if list.map(\.id) != obstacles.map(\.id) { obstacles = list }
                }
            } else if !obstacles.isEmpty {
                obstacles = []
            }
            if model.settings.showWinds {
                if let g = model.windGrid {
                    // Reload the wind grid if the view moved well outside it
                    if r.center.latitude < g.minLat || r.center.latitude > g.maxLat || r.center.longitude < g.minLon || r.center.longitude > g.maxLon
                        || span > (g.maxLat - g.minLat) * 1.3 || span < (g.maxLat - g.minLat) / 5 {
                        loadWinds()
                    }
                } else if windStatus != "Loading winds…" {
                    // Layer was left on from a previous launch: load the first grid now.
                    loadWinds()
                }
            }
        }
    }

    private func loadWinds() {
        guard model.settings.showWinds, let r = region else { return }
        windTask?.cancel()
        windStatus = "Loading winds…"
        windTask = Task {
            let latPad = r.span.latitudeDelta * 0.35, lonPad = r.span.longitudeDelta * 0.35
            let level = WindsLevel(rawValue: model.settings.windsLevel) ?? .p850
            do {
                let g = try await WindsAloftService.grid(minLat: max(-80, r.center.latitude - r.span.latitudeDelta / 2 - latPad),
                                                         maxLat: min(80, r.center.latitude + r.span.latitudeDelta / 2 + latPad),
                                                         minLon: r.center.longitude - r.span.longitudeDelta / 2 - lonPad,
                                                         maxLon: r.center.longitude + r.span.longitudeDelta / 2 + lonPad,
                                                         level: level)
                if Task.isCancelled { return }
                model.windGrid = g
                model.windTimeIndex = g.times.firstIndex(where: { $0 >= Date().addingTimeInterval(-1800) }) ?? 0
                windStatus = ""
            } catch {
                if !Task.isCancelled { windStatus = "Winds unavailable: \(error.localizedDescription)" }
            }
        }
    }

    private func updateGroundElevation() {
        guard let c = model.flight.coordinate, Date().timeIntervalSince(lastElevationQuery) > 3 else { return }
        lastElevationQuery = Date()
        Task { groundElevation = await TerrainService.shared.elevationFt(at: c) }
    }
}

struct MapButton: View {
    let system: String
    var active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(active ? Color.black : Color.white)
                .background(active ? Theme.accent : Theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

/// Compact route summary shown over the map.
struct RouteBar: View {
    @Environment(AppModel.self) private var model
    let onEdit: () -> Void
    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 8) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Theme.magenta)
                if let plan = model.activePlan, !plan.waypoints.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.routeString).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(Fmt.nm(plan.totalDistanceNM)) nm · \(Fmt.feet(Double(plan.cruiseAltitudeFt)))").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Tap to enter a route").font(.callout).foregroundStyle(.secondary)
                }
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .panelStyle()
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct SimulatorBar: View {
    @Environment(AppModel.self) private var model
    private var phaseText: String {
        let sim = model.simulator
        if sim.phase == .takeoff, let rw = sim.departureRunway { return "Takeoff · RWY " + rw }
        return sim.phase.rawValue
    }
    var body: some View {
        @Bindable var sim = model.simulator
        HStack(spacing: 12) {
            Image(systemName: "airplane.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("SIMULATOR").font(.system(size: 9, weight: .heavy)).foregroundStyle(.orange)
                Text(phaseText).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(minWidth: 92, alignment: .leading)
            HStack(spacing: 4) {
                ForEach([1.0, 4.0, 16.0], id: \.self) { k in
                    Button { sim.timeScale = k } label: {
                        Text("\(Int(k))×").font(.caption.weight(.bold)).frame(width: 40, height: 28)
                            .background(sim.timeScale == k ? Theme.accent : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(sim.timeScale == k ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speed \(Int(k)) times")
                }
            }
            Button("Stop") { model.stopSimulation() }.buttonStyle(.borderedProminent).tint(.orange)
        }
        .padding(8)
        .panelStyle()
        .frame(maxWidth: 520)
    }
}

struct HazardBar: View {
    @Environment(AppModel.self) private var model
    let airborne: Bool
    let altitude: Double
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.hazardYellow).frame(width: 14, height: 10)
                Text("−1000'").font(.caption2)
                RoundedRectangle(cornerRadius: 2).fill(Theme.hazardRed).frame(width: 14, height: 10)
                Text("−100'").font(.caption2)
            }
            if airborne {
                Text("Hazard Advisor at GPS altitude \(Fmt.feet(altitude))").font(.caption.weight(.semibold))
            } else {
                Text(Fmt.feet(model.settings.hazardAltitudeFt)).font(.caption.monospacedDigit().weight(.bold)).frame(width: 56)
                Slider(value: $model.settings.hazardAltitudeFt, in: 500...17500, step: 100)
                Text("Auto < 30 kt").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .panelStyle()
        .frame(maxWidth: 560)
    }
}

struct WindsBar: View {
    @Environment(AppModel.self) private var model
    let status: String
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            HStack {
                Picker("Level", selection: $model.settings.windsLevel) {
                    ForEach(WindsLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                HStack(spacing: 0) {
                    modeButton("°C", speed: false)
                    modeButton("kt", speed: true)
                }
                .background(Color.white.opacity(0.08), in: Capsule())
                Spacer(minLength: 4)
                legend
            }
            if let g = model.windGrid, g.times.count > 1 {
                HStack {
                    Text(g.times[min(model.windTimeIndex, g.times.count - 1)].formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.caption.monospacedDigit().weight(.semibold)).frame(width: 96, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.windTimeIndex) }, set: { model.windTimeIndex = Int($0.rounded()) }),
                           in: 0...Double(g.times.count - 1), step: 1)
                }
            }
            if !status.isEmpty { Text(status).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(8)
        .panelStyle()
        .frame(maxWidth: 620)
    }

    private func modeButton(_ title: String, speed: Bool) -> some View {
        let on = model.settings.windsShowSpeed == speed
        return Button { model.settings.windsShowSpeed = speed } label: {
            Text(title).font(.caption.weight(.bold)).frame(width: 36, height: 26)
                .background(on ? Theme.accent.opacity(0.85) : .clear, in: Capsule())
                .foregroundStyle(on ? .black : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speed ? "Show wind speeds" : "Show temperatures")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var legend: some View {
        let showSpeed = model.settings.windsShowSpeed
        let values: [Double] = showSpeed ? [0, 10, 20, 35, 50, 70] : [-30, -15, 0, 10, 20, 30]
        return HStack(spacing: 0) {
            ForEach(values, id: \.self) { v in
                let c = showSpeed ? WindHeatOverlay.speedColor(v) : WindHeatOverlay.tempColor(v)
                Text(showSpeed ? "\(Int(v))" : "\(Int(v))°")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 16)
                    .background(Color(red: c.0, green: c.1, blue: c.2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Long-press info: coordinates, elevation, nearest airports, direct-to.
struct PinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let info: MapScreen.PinInfo
    @State private var elevation: Double?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Position", value: Geo.formatLatLon(info.coordinate))
                    LabeledContent("Terrain", value: elevation.map { Fmt.feet($0) + " MSL" } ?? "…")
                    if let c = model.flight.coordinate {
                        LabeledContent("From ownship", value: "\(Fmt.heading(Geo.bearing(c, info.coordinate) - model.magVar(at: c)))M · \(Fmt.nm(Geo.distanceNM(c, info.coordinate))) nm")
                    }
                }
                Section {
                    Button { model.directTo(Waypoint(user: info.coordinate)); dismiss() } label: { Label("Direct To", systemImage: "arrow.right.circle") }
                    Button { model.addToRoute(Waypoint(user: info.coordinate)); dismiss() } label: { Label("Add to Route", systemImage: "plus.circle") }
                }
                if let near = model.db.index?.nearestAirports(to: info.coordinate, count: 6, maxNM: 40), !near.isEmpty {
                    Section("Nearest airports") {
                        ForEach(near, id: \.airport.ident) { item in
                            Button {
                                model.mapSelectedAirport = item.airport
                                dismiss()
                            } label: {
                                HStack {
                                    Text(item.airport.displayIdent).font(.headline)
                                    Text(item.airport.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text("\(Fmt.nm(item.distance)) nm").font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }
            .themedList()
            .navigationTitle("Map point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { elevation = await TerrainService.shared.elevationFt(at: info.coordinate, z: 12) }
    }
}
