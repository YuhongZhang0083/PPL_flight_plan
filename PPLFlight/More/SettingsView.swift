import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var homeText = ""
    @State private var cacheSize: Int64 = 0
    @State private var offlineRadius = 60.0
    @State private var offlineMaxZ = 11
    @State private var offlineProgress: Double?
    @State private var offlineMessage = ""
    var embedded = false

    var body: some View {
        @Bindable var model = model
        OptionalNavigationStack(embedded: embedded) {
            Form {
                Section("Home base") {
                    HStack {
                        TextField("KCNO", text: $homeText).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .onSubmit { saveHome() }
                        Button("Set") { saveHome() }
                    }
                    if let h = model.homeAirport { Text("\(h.displayIdent) · \(h.name)").font(.caption).foregroundStyle(.secondary) }
                }

                Section("Aircraft") {
                    ForEach(model.aircraft) { ac in
                        NavigationLink {
                            AircraftEditor(aircraft: ac)
                        } label: {
                            HStack {
                                Image(systemName: ac.id == model.activeAircraft.id ? "checkmark.circle.fill" : "airplane")
                                    .foregroundStyle(ac.id == model.activeAircraft.id ? .green : .secondary)
                                VStack(alignment: .leading) {
                                    Text(ac.tailNumber).font(.headline)
                                    Text(ac.model).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { idx in if model.aircraft.count > idx.count { model.aircraft.remove(atOffsets: idx) } }
                    Button { var a = AircraftProfile.c172n; a.id = UUID(); a.tailNumber = "N"; model.aircraft.append(a) } label: { Label("Add aircraft (172N template)", systemImage: "plus") }
                }

                Section {
                    if model.simulator.isRunning {
                        Button("Stop simulation", role: .destructive) { model.stopSimulation() }
                    } else {
                        Button { model.startSimulation() } label: { Label("Simulate active route", systemImage: "airplane.departure") }
                            .disabled((model.activePlan?.waypoints.count ?? 0) < 2)
                    }
                    Toggle("Auto-record flights (> 35 kt)", isOn: $model.settings.autoRecordTrack)
                } header: { Text("Flight") } footer: {
                    Text("The simulator flies your active route with the aircraft's performance profile so you can rehearse with the moving map, synthetic vision, hazard advisor and plates on the ground.")
                }

                Section {
                    dataRow(title: "Airport database", detail: dbDetail, busy: { if case .downloading = model.db.status { return true }; return false }()) {
                        Task { await model.db.download() }
                    }
                    dataRow(title: "Procedures (d-TPP) index", detail: platesDetail, busy: { if case .loading = model.plates.status { return true }; return false }()) {
                        Task { await model.plates.refreshIndex(force: true) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Offline sectional charts").font(.headline)
                        HStack {
                            Text("Radius \(Int(offlineRadius)) nm around \(model.homeAirport?.displayIdent ?? "home")").font(.caption)
                            Slider(value: $offlineRadius, in: 25...200, step: 25)
                        }
                        Picker("Detail", selection: $offlineMaxZ) { Text("Normal").tag(11); Text("High").tag(12) }.pickerStyle(.segmented)
                        if let p = offlineProgress { ProgressView(value: p) { Text(offlineMessage).font(.caption) } }
                        Button("Download charts & terrain for offline use") { Task { await downloadOffline() } }
                            .disabled(offlineProgress != nil)
                        Text("Estimated \(tileEstimate) tiles").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Cache size")
                        Spacer()
                        Text(Fmt.bytes(cacheSize)).foregroundStyle(.secondary)
                    }
                    Button("Clear downloaded tiles & plates", role: .destructive) {
                        try? FileManager.default.removeItem(at: AppPaths.caches)
                        cacheSize = AppPaths.folderSize(AppPaths.caches)
                    }
                } header: { Text("Data") } footer: {
                    Text("Airports, runways, frequencies and navaids: OurAirports (public domain). Charts, d-TPP plates and obstacles: FAA. Weather: aviationweather.gov (NOAA). Winds: Open-Meteo (CC BY 4.0). Terrain: AWS Terrain Tiles. Taxiways: © OpenStreetMap contributors (ODbL).")
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0 (1)")
                    Text("PPL Flight is a training and situational-awareness tool for student pilots. It is not certified for navigation. Always use current FAA charts, a full weather briefing, the POH/AFM and your instructor's guidance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .themedList()
            .navigationTitle("Settings")
            .onAppear {
                homeText = model.settings.homeBase
                cacheSize = AppPaths.folderSize(AppPaths.caches)
            }
        }
    }

    private var dbDetail: String {
        switch model.db.status {
        case .ready: return "\(model.db.airportCount.formatted()) airports · \(model.db.navaidCount.formatted()) navaids · \(model.db.downloadedAt.map { Fmt.dayMonth.string(from: $0) } ?? "")"
        case .downloading(let s): return s
        case .failed(let e): return "Failed: \(e)"
        case .loading: return "Loading…"
        case .empty: return "Not downloaded"
        }
    }

    private var platesDetail: String {
        switch model.plates.status {
        case .ready: return "Cycle \(model.plates.cycle) · \(model.plates.airportCount.formatted()) identifiers"
        case .loading(let s): return s
        case .failed(let e): return "Failed: \(e)"
        case .idle: return "Not downloaded"
        }
    }

    private func dataRow(title: String, detail: String, busy: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView() } else { Button("Update", action: action).buttonStyle(.bordered) }
        }
    }

    private func saveHome() {
        let t = homeText.uppercased().trimmingCharacters(in: .whitespaces)
        if let a = model.airport(t) {
            model.settings.homeBase = a.ident
            homeText = a.ident
        }
    }

    private var tileEstimate: Int { offlineTiles().count * 2 }

    private func offlineTiles() -> [(Int, Int, Int)] {
        guard let home = model.homeAirport else { return [] }
        let dLat = offlineRadius / 60, dLon = offlineRadius / 60 / cos(Geo.rad(home.lat))
        var out: [(Int, Int, Int)] = []
        for z in 8...offlineMaxZ {
            let a = TileMath.tileXY(lat: home.lat + dLat, lon: home.lon - dLon, z: z)
            let b = TileMath.tileXY(lat: home.lat - dLat, lon: home.lon + dLon, z: z)
            for y in Int(a.y)...Int(b.y) { for x in Int(a.x)...Int(b.x) { out.append((z, x, y)) } }
        }
        return out
    }

    private func downloadOffline() async {
        let tiles = offlineTiles()
        guard !tiles.isEmpty else { return }
        offlineProgress = 0
        var done = 0
        let total = tiles.count
        for (z, x, y) in tiles {
            offlineMessage = "Sectional z\(z) · \(done)/\(total)"
            _ = try? await TileLoader.shared.native(key: ChartLayer.sectional.rawValue, z: z, x: x, y: y, maxAge: nil, url: ChartLayer.sectional.url(z: z, x: x, y: y))
            if z <= 11 { _ = try? await TerrainService.shared.tile(z: z, x: x, y: y) }
            done += 1
            offlineProgress = Double(done) / Double(total)
        }
        offlineMessage = "Done"
        offlineProgress = nil
        cacheSize = AppPaths.folderSize(AppPaths.caches)
    }
}

struct AircraftEditor: View {
    @Environment(AppModel.self) private var model
    @State var aircraft: AircraftProfile

    var body: some View {
        Form {
            Section("Identity") {
                text("Tail number", "N12345", $aircraft.tailNumber, caps: true)
                text("Model", "Cessna 172N Skyhawk", $aircraft.model, caps: false)
                text("ICAO type", "C172", $aircraft.icaoType, caps: true)
                text("Equipment (10a)", "S", $aircraft.equipment, caps: true)
                text("Surveillance (10b)", "C", $aircraft.surveillance, caps: true)
                text("Color", "W/B", $aircraft.color, caps: true)
            }
            Section("Fuel") {
                num("Usable fuel (gal)", $aircraft.usableFuelGal)
                num("Taxi fuel (gal)", $aircraft.taxiFuelGal)
                num("Reserve (min)", $aircraft.reserveMinutes)
            }
            Section("Climb") {
                num("Climb IAS (kt)", $aircraft.climbIAS)
                num("Rate of climb at SL (fpm)", $aircraft.climbRateSL)
                num("Service ceiling (ft)", $aircraft.serviceCeilingFt)
                num("Climb fuel flow (gph)", $aircraft.climbGPH)
            }
            Section {
                num("Cruise power (%)", $aircraft.cruisePowerPct)
                num("TAS @ 55%", $aircraft.tas55); num("GPH @ 55%", $aircraft.gph55)
                num("TAS @ 65%", $aircraft.tas65); num("GPH @ 65%", $aircraft.gph65)
                num("TAS @ 75%", $aircraft.tas75); num("GPH @ 75%", $aircraft.gph75)
                num("TAS gain per 1,000 ft", $aircraft.tasGainPer1000)
            } header: { Text("Cruise (5,000 ft)") } footer: { Text("172N card: 55% 99 kt 6.3 gph · 65% 107 kt 7.3 gph · 75% 114 kt 8.4 gph. Above the altitude where the selected power is available, full-throttle power is used.") }
            Section("Descent") {
                num("Descent rate (fpm)", $aircraft.descentRate)
                num("Descent TAS (kt)", $aircraft.descentTAS)
                num("Descent fuel flow (gph)", $aircraft.descentGPH)
            }
            Section("Speeds & limits (KIAS)") {
                num("Vr", $aircraft.vr); num("Vx", $aircraft.vx); num("Vy", $aircraft.vy)
                num("Vso", $aircraft.vso); num("Vs1", $aircraft.vs1); num("Va (gross)", $aircraft.va)
                num("Vfe", $aircraft.vfe); num("Vno", $aircraft.vno); num("Vne", $aircraft.vne)
                num("Best glide", $aircraft.bestGlideKIAS); num("Glide ratio", $aircraft.glideRatio)
                num("Max demo crosswind (kt)", $aircraft.maxCrosswindKt)
            }
            Section {
                Button("Make active aircraft") { save(); model.settings.activeAircraftID = aircraft.id }
            }
        }
        .themedList()
        .navigationTitle(aircraft.tailNumber)
        .onDisappear { save() }
    }

    private func save() {
        if let i = model.aircraft.firstIndex(where: { $0.id == aircraft.id }) {
            if model.aircraft[i] != aircraft { model.aircraft[i] = aircraft }
        }
    }

    private func text(_ label: String, _ prompt: String, _ v: Binding<String>, caps: Bool) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: v)
                .textInputAutocapitalization(caps ? .characters : .words)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    private func num(_ label: String, _ v: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: v, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}
