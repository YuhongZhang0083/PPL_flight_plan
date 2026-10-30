import SwiftUI
import MapKit

/// Top instrument strip (GS, ALT, TRK, VS, next waypoint, DTK, DIS, ETE, ETA).
struct InstrumentStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let f = model.flight
        let nav = model.navInfo()
        let mv = f.coordinate.map { model.magVar(at: $0) } ?? 0
        let has = f.hasPosition
        let cells: [(String, String, Color)] = [
            ("GS", has ? "\(Int(f.groundSpeedKt.rounded())) kt" : "--", .white),
            ("ALT", has ? Fmt.feet(f.altitudeFt) : "--", .white),
            ("TRK", has && f.groundSpeedKt > 2 ? Fmt.heading(f.trackTrue - mv) : "---", .white),
            ("VS", has ? String(format: "%+d", Int((f.verticalSpeedFpm / 10).rounded() * 10)) : "--", .white),
            ("NEXT", nav.next?.ident ?? "--", Theme.magenta),
            ("DTK", nav.desiredTrack.map { Fmt.heading($0 - mv) } ?? "---", Theme.magenta),
            ("DIS", nav.distanceNext.map { Fmt.nm($0) + " nm" } ?? "--", .white),
            ("ETE", nav.eteNext.map { Fmt.ete($0) } ?? "--", .white),
            ("ETA", nav.eteDest.map { Fmt.timeShort.string(from: Date().addingTimeInterval($0)) } ?? "--", .white),
        ]
        let shown = hSize == .regular ? cells : Array(cells.prefix(4)) + [cells[6], cells[7]]
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                VStack(spacing: 1) {
                    Text(c.0).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    Text(c.1).font(.system(size: hSize == .regular ? 17 : 15, weight: .bold, design: .rounded))
                        .foregroundStyle(c.2).lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                if i < shown.count - 1 { Divider().frame(height: 28).overlay(.white.opacity(0.15)) }
            }
        }
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if f.source != .none {
                Text(f.source.rawValue.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(f.source == .simulator ? Color.orange : Color.green, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(x: -4, y: -5)
            }
        }
    }
}

/// Map layer picker sheet.
struct LayerPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Aeronautical chart") {
                    Picker("Chart", selection: $model.settings.chartLayer) {
                        ForEach(ChartLayer.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Base map") {
                    Picker("Base map", selection: $model.settings.baseMap) {
                        ForEach(BaseMap.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Overlays") {
                    Toggle(isOn: $model.settings.showAirports) { Label("Airports (flight category)", systemImage: "circle.fill") }
                    Toggle(isOn: $model.settings.showRadar) { Label("Radar (NEXRAD)", systemImage: "cloud.rain") }
                    Toggle(isOn: $model.settings.showHazard) { Label("Hazard Advisor (terrain)", systemImage: "exclamationmark.triangle") }
                    Toggle(isOn: $model.settings.showObstacles) { Label("Obstacles ≥ 200' AGL", systemImage: "antenna.radiowaves.left.and.right") }
                    Toggle(isOn: $model.settings.showWinds) { Label("Winds & Temps Aloft (animated)", systemImage: "wind") }
                }
                Section("Ownship") {
                    Toggle(isOn: $model.settings.showRangeRings) { Label("Range rings 5/10/20 nm", systemImage: "circle.circle") }
                    Toggle(isOn: $model.settings.showGlideRing) { Label("Glide range ring", systemImage: "arrow.down.right.circle") }
                    Picker(selection: $model.settings.trackVectorMinutes) {
                        Text("Off").tag(0); Text("1 min").tag(1); Text("2 min").tag(2); Text("5 min").tag(5); Text("10 min").tag(10)
                    } label: { Label("Track vector", systemImage: "arrow.up.forward") }
                }
                Section {
                    Text("Charts: FAA Aeronautical Information Services. Radar: Iowa Environmental Mesonet. Terrain: AWS Terrain Tiles. Winds: Open-Meteo (GFS). Not for primary navigation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .themedList()
            .navigationTitle("Map Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Edit the active route as text or as a list.
struct RouteEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var unresolved: [String] = []
    @State private var busy = false
    @State private var altitude = 5500

    var body: some View {
        Form {
            Section {
                TextField("KCNO PDZ KRAL", text: $text, axis: .vertical)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit { apply() }
                if !unresolved.isEmpty {
                    Label("Not found: \(unresolved.joined(separator: ", "))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Button { apply() } label: {
                    if busy { ProgressView() } else { Label("Update route", systemImage: "checkmark.circle.fill") }
                }
            } header: { Text("Route") } footer: {
                Text("Airports (KCNO, CNO, L35), VORs (PDZ), 5-letter fixes, or lat/lon like 33.95/-117.30. Separate with spaces.")
            }
            Section("Cruise altitude") {
                Stepper(value: $altitude, in: 1500...17500, step: 500) {
                    Text(Fmt.feet(Double(altitude))).font(.headline.monospacedDigit())
                }
                .onChange(of: altitude) { _, v in
                    if var p = model.activePlan { p.cruiseAltitudeFt = v; model.activePlan = p }
                }
            }
            if let plan = model.activePlan, !plan.waypoints.isEmpty {
                Section("Waypoints") {
                    ForEach(plan.waypoints) { w in
                        HStack {
                            Image(systemName: icon(w.kind)).foregroundStyle(Theme.magenta)
                            VStack(alignment: .leading) {
                                Text(w.ident).font(.headline)
                                Text(w.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onDelete { idx in
                        guard var p = model.activePlan else { return }
                        p.waypoints.remove(atOffsets: idx)
                        model.activePlan = p
                        text = p.routeString
                    }
                    .onMove { from, to in
                        guard var p = model.activePlan else { return }
                        p.waypoints.move(fromOffsets: from, toOffset: to)
                        model.activePlan = p
                        text = p.routeString
                    }
                }
                Section {
                    Button { model.focus(on: plan.waypoints.map(\.coordinate)); dismiss() } label: { Label("Zoom to route", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    Button { model.startSimulation(); dismiss() } label: { Label("Simulate this flight", systemImage: "airplane.departure") }
                        .disabled(plan.waypoints.count < 2)
                    Button(role: .destructive) {
                        var p = plan; p.waypoints = []; model.activePlan = p; text = ""
                    } label: { Label("Clear route", systemImage: "trash") }
                }
            }
        }
        .themedList()
        .navigationTitle("Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .onAppear {
            text = model.activePlan?.routeString ?? ""
            altitude = model.activePlan?.cruiseAltitudeFt ?? 5500
        }
    }

    private func icon(_ k: WaypointKind) -> String {
        switch k {
        case .airport: return "airplane.circle"
        case .navaid: return "hexagon"
        case .fix: return "triangle"
        case .user: return "mappin"
        }
    }

    private func apply() {
        busy = true
        Task {
            let r = await RouteParser.parse(text, index: model.db.index)
            var p = model.activePlan ?? FlightPlan()
            p.waypoints = r.waypoints
            p.aircraftID = p.aircraftID ?? model.activeAircraft.id
            model.activePlan = p
            unresolved = r.unresolved
            busy = false
            if r.waypoints.count >= 1 { model.focus(on: r.waypoints.map(\.coordinate)) }
        }
    }
}
