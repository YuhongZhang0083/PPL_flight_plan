import SwiftUI
import CoreLocation

/// Imagery & weather tab: nearby METARs, FB winds aloft and official imagery.
struct WeatherView: View {
    @Environment(AppModel.self) private var model
    enum Pane: String, CaseIterable, Identifiable { case metars = "METARs", winds = "Winds Aloft", imagery = "Imagery"; var id: String { rawValue } }
    @State private var section: Pane = .metars
    var embedded = false

    var body: some View {
        OptionalNavigationStack(embedded: embedded) {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) { ForEach(Pane.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .padding()
                switch section {
                case .metars: NearbyMETARs()
                case .winds: FBWindsView()
                case .imagery: ImageryView()
                }
            }
            .background(Theme.navy)
            .navigationTitle("Weather")
        }
    }
}

struct NearbyMETARs: View {
    @Environment(AppModel.self) private var model
    @State private var radius = 60.0

    var center: CLLocationCoordinate2D? { model.flight.hasPosition ? model.flight.coordinate : model.homeAirport?.coordinate }

    var body: some View {
        List {
            if let c = center {
                let list = model.weather.metarsNear(c, radiusNM: radius)
                Section {
                    Picker("Radius", selection: $radius) { Text("30 nm").tag(30.0); Text("60 nm").tag(60.0); Text("120 nm").tag(120.0) }
                        .pickerStyle(.segmented)
                }
                Section("\(list.count) stations near \(model.flight.hasPosition ? "you" : (model.homeAirport?.displayIdent ?? ""))") {
                    ForEach(list) { m in
                        NavigationLink {
                            ScrollView {
                                METARCard(metar: m, fieldElevation: (m.elev ?? 0) * Geo.feetPerMeter).padding()
                                if let a = model.airport(m.icaoId) {
                                    TAFSection(airport: a).padding(.horizontal)
                                }
                            }
                            .background(Theme.navy)
                            .navigationTitle(m.icaoId)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(m.category).font(.caption2.weight(.heavy)).frame(width: 40).padding(.vertical, 3)
                                    .background(Theme.category(m.category), in: Capsule()).foregroundStyle(.black)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(m.icaoId).font(.headline)
                                        Text(m.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer()
                                        Text("\(Fmt.nm(Geo.distanceNM(c, m.coordinate))) nm").font(.caption.monospacedDigit())
                                    }
                                    Text(m.rawOb).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Waiting for position or home base…")
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load(force: true) }
        .task(id: radius) { await load(force: false) }
    }

    private func load(force: Bool) async {
        guard let c = center else { return }
        let d = radius / 60
        await model.weather.fetchMETARs(minLat: c.latitude - d, minLon: c.longitude - d * 1.2, maxLat: c.latitude + d, maxLon: c.longitude + d * 1.2)
    }
}

struct FBWindsView: View {
    @Environment(AppModel.self) private var model
    @State private var product: FBProduct?
    @State private var fcst = "06"
    @State private var filter = ""

    var body: some View {
        List {
            Section {
                Picker("Forecast", selection: $fcst) { Text("6 h").tag("06"); Text("12 h").tag("12"); Text("24 h").tag("24") }.pickerStyle(.segmented)
                TextField("Filter stations (e.g. ONT SAN LAX)", text: $filter).textInputAutocapitalization(.characters)
            } footer: {
                if let p = product { Text(p.validText) }
            }
            if let p = product {
                Section("FB winds aloft (true °, kt, °C)") {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 0) {
                                Text("STN").frame(width: 44, alignment: .leading)
                                ForEach(p.altitudes, id: \.self) { a in Text(a >= 18000 ? "FL\(a / 100)" : "\(a / 1000)k").frame(width: 70, alignment: .leading) }
                            }
                            .font(.caption.weight(.heavy)).foregroundStyle(.secondary)
                            ForEach(stations(p)) { st in
                                HStack(spacing: 0) {
                                    Text(st.station).font(.caption.weight(.bold)).frame(width: 44, alignment: .leading)
                                    ForEach(st.cells.indices, id: \.self) { i in
                                        let c = st.cells[i]
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(c.raw.isEmpty ? "—" : c.raw).font(.system(size: 12, design: .monospaced))
                                            if let d = FBStation.decode(c.raw, altitude: c.altitude) {
                                                Text(d.lightVariable ? "L/V" : "\(String(format: "%03d", d.dir ?? 0))/\(d.speed)\(d.temp.map { " \($0)°" } ?? "")")
                                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: 70, alignment: .leading)
                                    }
                                }
                                Divider().opacity(0.2)
                            }
                        }
                    }
                }
            } else {
                ProgressView("Loading FB product…")
            }
        }
        .scrollContentBackground(.hidden)
        .task(id: fcst) { product = await model.weather.windsAloft(fcst: fcst) }
    }

    private func stations(_ p: FBProduct) -> [FBStation] {
        let wanted = filter.uppercased().split(separator: " ").map(String.init)
        if !wanted.isEmpty { return p.stations.filter { wanted.contains($0.station) } }
        // Default: stations within 250 nm of home/ownship
        guard let c = (model.flight.hasPosition ? model.flight.coordinate : nil) ?? model.homeAirport?.coordinate, let idx = model.db.index else { return p.stations }
        let near = p.stations.compactMap { st -> (FBStation, Double)? in
            guard let loc = idx.airport("K" + st.station)?.coordinate ?? idx.navaids(st.station).first?.coordinate else { return nil }
            return (st, Geo.distanceNM(c, loc))
        }.filter { $0.1 < 250 }.sorted { $0.1 < $1.1 }.map(\.0)
        return near.isEmpty ? p.stations : near
    }
}

struct ImageryView: View {
    struct Item: Identifiable { let id = UUID(); let title: String; let subtitle: String; let url: String; let isImage: Bool }
    let items: [Item] = [
        Item(title: "Graphical Forecasts for Aviation (GFA)", subtitle: "Clouds, weather, ceilings & visibility", url: "https://aviationweather.gov/gfa/", isImage: false),
        Item(title: "Surface Prog Chart (12 h)", subtitle: "WPC fronts and precipitation", url: "https://aviationweather.gov/data/products/progs/F012_wpc_prog.gif", isImage: true),
        Item(title: "Surface Prog Chart (24 h)", subtitle: "WPC fronts and precipitation", url: "https://aviationweather.gov/data/products/progs/F024_wpc_prog.gif", isImage: true),
        Item(title: "Current Surface Analysis", subtitle: "WPC fronts, pressure and weather", url: "https://aviationweather.gov/data/products/progs/F000_wpc_sfc.gif", isImage: true),
        Item(title: "Surface Forecast (Day 1)", subtitle: "WPC national forecast chart", url: "https://www.wpc.ncep.noaa.gov/basicwx/92fwbg.gif", isImage: true),
        Item(title: "Convective Outlook", subtitle: "Storm Prediction Center", url: "https://www.spc.noaa.gov/products/outlook/", isImage: false),
        Item(title: "G-AIRMETs, SIGMETs, CWAs", subtitle: "AviationWeather.gov interactive map", url: "https://aviationweather.gov/gairmet/", isImage: false),
        Item(title: "Icing (CIP/FIP)", subtitle: "Current and forecast icing", url: "https://aviationweather.gov/icing/fip/", isImage: false),
        Item(title: "Turbulence (GTG)", subtitle: "Graphical turbulence guidance", url: "https://aviationweather.gov/turbulence/gtg/", isImage: false),
        Item(title: "Satellite", subtitle: "GOES imagery", url: "https://aviationweather.gov/satellite/", isImage: false),
    ]

    var body: some View {
        List(items) { item in
            if item.isImage {
                NavigationLink {
                    ZoomableRemoteImage(url: URL(string: item.url)!).navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                } label: { row(item) }
            } else {
                Link(destination: URL(string: item.url)!) { row(item) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ i: Item) -> some View {
        HStack {
            Image(systemName: i.isImage ? "photo" : "safari").foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading) {
                Text(i.title).font(.headline)
                Text(i.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ZoomableRemoteImage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Text("Image unavailable").foregroundStyle(.secondary)
                default: ProgressView()
                }
            }
            .frame(width: 700 * scale)
            .gesture(MagnifyGesture().onChanged { v in scale = max(0.5, min(4, lastScale * v.magnification)) }.onEnded { _ in lastScale = scale })
        }
        .background(Color.white)
    }
}
