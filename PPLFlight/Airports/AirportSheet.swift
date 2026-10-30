import SwiftUI
import CoreLocation

/// ForeFlight-style airport card: Direct To / Route actions and Info / Weather / Runway / Procedure / NOTAM tabs.
struct AirportSheet: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    var compact: Bool

    enum Tab: String, CaseIterable, Identifiable { case info = "Info", weather = "Weather", runway = "Runway", procedure = "Procedure", notam = "NOTAM"; var id: String { rawValue } }
    @State private var tab: Tab = .weather

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actions
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .info: AirportInfoTab(airport: airport)
                    case .weather: AirportWeatherTab(airport: airport)
                    case .runway: RunwayTab(airport: airport)
                    case .procedure: ProcedureTab(airport: airport)
                    case .notam: NotamTab(airport: airport)
                    }
                }
                .padding()
            }
            .background(Theme.navy)
            .navigationTitle(airport.displayIdent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.toggleFavorite(airport.ident) } label: {
                        Image(systemName: model.isFavorite(airport.ident) ? "star.fill" : "star")
                    }
                }
                if compact {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { model.mapSelectedAirport = nil }
                    }
                }
            }
        }
        .task {
            await model.weather.fetchMETARs(ids: [airport.weatherIdent])
        }
    }

    private var header: some View {
        let sun = Solar.times(on: Date(), latitude: airport.lat, longitude: airport.lon)
        return HStack(alignment: .top, spacing: 12) {
            RunwaySketch(airport: airport, wind: model.weather.metar(airport.weatherIdent))
                .frame(width: 84, height: 84)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(airport.name).font(.title3.weight(.bold)).lineLimit(2)
                Text("\(airport.city), \(airport.stateCode)").font(.subheadline).foregroundStyle(.secondary)
                Text("Elevation \(Fmt.feet(airport.elevFt))").font(.subheadline)
                HStack(spacing: 10) {
                    if let r = sun.sunrise { Label(Fmt.timeShort.string(from: r), systemImage: "sunrise.fill") }
                    if let s = sun.sunset { Label(Fmt.timeShort.string(from: s), systemImage: "sunset.fill") }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
        }
    }

    private var actions: some View {
        let inRoute = model.isInRoute(airport.displayIdent)
        return HStack(spacing: 8) {
            ActionButton(title: "Direct To", system: "arrow.right.circle.fill", tint: .red) { model.directTo(Waypoint(airport: airport)) }
            ActionButton(title: inRoute ? "Remove" : "Add to Route", system: inRoute ? "minus.circle.fill" : "plus.circle.fill", tint: Theme.magenta) {
                if inRoute { model.removeFromRoute(airport.displayIdent) } else { model.addToRoute(Waypoint(airport: airport)) }
            }
            ActionButton(title: "Map", system: "map.fill", tint: Theme.accent) { model.showOnMap(airport) }
            Menu {
                Button { model.settings.homeBase = airport.ident } label: { Label("Set as home base", systemImage: "house") }
                Button {
                    var p = FlightPlan()
                    p.waypoints = [Waypoint(airport: airport)]
                    p.aircraftID = model.activeAircraft.id
                    model.plans.insert(p, at: 0)
                    model.selectedTab = .flights
                } label: { Label("New flight from here", systemImage: "airplane.departure") }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle.fill").font(.title3)
                    Text("More").font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct ActionButton: View {
    let title: String
    let system: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system).font(.title3).foregroundStyle(tint)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Small runway layout with wind arrow (true north up).
struct RunwaySketch: View {
    let airport: Airport
    let wind: METAR?
    var body: some View {
        Canvas { ctx, size in
            let rws = airport.runways.filter { $0.leCoord != nil && $0.heCoord != nil }
            guard !rws.isEmpty else {
                ctx.draw(Text(airport.displayIdent).font(.caption.bold()), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let all = rws.flatMap { [$0.leCoord!, $0.heCoord!] }
            let lat0 = all.map(\.latitude).reduce(0, +) / Double(all.count)
            let lon0 = all.map(\.longitude).reduce(0, +) / Double(all.count)
            let k = cos(Geo.rad(lat0))
            let pts = all.map { CGPoint(x: ($0.longitude - lon0) * k, y: -($0.latitude - lat0)) }
            let extent = max(pts.map { abs($0.x) }.max() ?? 0.001, pts.map { abs($0.y) }.max() ?? 0.001, 0.002)
            let scale = (min(size.width, size.height) / 2 - 8) / extent
            func p(_ c: CLLocationCoordinate2D) -> CGPoint {
                CGPoint(x: size.width / 2 + (c.longitude - lon0) * k * scale, y: size.height / 2 - (c.latitude - lat0) * scale)
            }
            for r in rws {
                var path = Path(); path.move(to: p(r.leCoord!)); path.addLine(to: p(r.heCoord!))
                ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: max(3, CGFloat(r.widthFt) / 40), lineCap: .butt))
            }
            if let w = wind, let dir = w.windDirection, let s = w.wspd, s > 0, !w.isVariableWind {
                let ang = Geo.rad(dir)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let from = CGPoint(x: c.x + sin(ang) * size.width * 0.45, y: c.y - cos(ang) * size.height * 0.45)
                let to = CGPoint(x: c.x + sin(ang) * size.width * 0.15, y: c.y - cos(ang) * size.height * 0.15)
                var arrow = Path(); arrow.move(to: from); arrow.addLine(to: to)
                ctx.stroke(arrow, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                let back = ang + .pi
                var head = Path()
                head.move(to: to)
                head.addLine(to: CGPoint(x: to.x + sin(back + 0.5 + .pi) * -7, y: to.y - cos(back + 0.5 + .pi) * -7))
                head.move(to: to)
                head.addLine(to: CGPoint(x: to.x + sin(back - 0.5 + .pi) * -7, y: to.y - cos(back - 0.5 + .pi) * -7))
                ctx.stroke(head, with: .color(.cyan), lineWidth: 2.5)
            }
        }
    }
}

struct AirportInfoTab: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoCard(title: "Airport") {
                LabeledContent("Identifier", value: [airport.icao, airport.faa].filter { !$0.isEmpty }.removingDuplicates().joined(separator: " / "))
                LabeledContent("Type", value: airport.typeDescription + (airport.isTowered ? " · Towered" : " · Non-towered"))
                LabeledContent("Position", value: Geo.formatLatLon(airport.coordinate))
                LabeledContent("Elevation", value: Fmt.feet(airport.elevFt))
                LabeledContent("Pattern altitude", value: "\(Fmt.feet(airport.elevFt + 1000)) (typical)")
                let mv = model.magVar(at: airport.coordinate)
                LabeledContent("Magnetic variation", value: String(format: "%.1f° %@", abs(mv), mv >= 0 ? "E" : "W"))
                if let c = model.flight.coordinate ?? model.homeAirport?.coordinate {
                    LabeledContent(model.flight.hasPosition ? "From ownship" : "From home", value: "\(Fmt.heading(Geo.bearing(c, airport.coordinate) - model.magVar(at: c)))M · \(Fmt.nm(Geo.distanceNM(c, airport.coordinate))) nm")
                }
            }
            if !airport.freqs.isEmpty {
                InfoCard(title: "Frequencies") {
                    ForEach(airport.freqs.sorted { order($0.type) < order($1.type) }) { f in
                        LabeledContent(f.label, value: f.formatted).monospacedDigit()
                    }
                }
            }
            let navs = model.db.index?.navaids(near: airport.coordinate, radiusNM: 30).filter { $0.type.contains("VOR") } ?? []
            if !navs.isEmpty {
                InfoCard(title: "Nearby VORs") {
                    ForEach(navs.prefix(5), id: \.id) { n in
                        let brg = Geo.bearing(n.coordinate, airport.coordinate) - (n.magVar ?? model.magVar(at: n.coordinate))
                        LabeledContent("\(n.ident) \(n.name) \(n.frequencyText)", value: "R-\(Fmt.heading(brg)) / \(Fmt.nm(Geo.distanceNM(n.coordinate, airport.coordinate))) nm")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func order(_ t: String) -> Int {
        ["ATIS", "AWOS", "ASOS", "CLD", "GND", "TWR", "CTAF", "UNIC", "APP", "A/D", "DEP"].firstIndex(of: t.uppercased()) ?? 99
    }
}

struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

struct RunwayTab: View {
    @Environment(AppModel.self) private var model
    let airport: Airport

    var body: some View {
        let metar = model.weather.metar(airport.weatherIdent) ?? model.weather.metarsNear(airport.coordinate, radiusNM: 20).first
        let windDir = metar?.windDirection
        let windSpd = metar?.wspd ?? 0
        let gust = metar?.wgst
        let limit = model.activeAircraft.maxCrosswindKt
        let best = bestRunwayEnd(windDir: windDir, speed: windSpd)
        VStack(alignment: .leading, spacing: 12) {
            if let m = metar {
                HStack {
                    Image(systemName: "wind")
                    Text("Wind \(m.windText) (\(m.icaoId), \(m.observed.map { Fmt.age($0) } ?? ""))").font(.subheadline.weight(.semibold))
                }
            }
            ForEach(airport.runways) { r in
                InfoCard(title: "Runway \(r.name)") {
                    LabeledContent("Dimensions", value: "\(r.lengthFt.formatted()) × \(r.widthFt) ft")
                    LabeledContent("Surface", value: r.surfaceDescription + (r.lighted ? " · Lighted" : ""))
                    ForEach([(r.le, r.leTrueHeading, r.leDisplacedFt, r.leElevFt), (r.he, r.heTrueHeading, r.heDisplacedFt, r.heElevFt)], id: \.0) { end in
                        if let hdg = end.1 {
                            let mv = model.magVar(at: airport.coordinate)
                            HStack(alignment: .firstTextBaseline) {
                                Text("RWY \(end.0)").font(.headline).frame(width: 82, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(Fmt.heading(hdg - mv))M" + (end.2.map { $0 > 0 ? " · displaced \($0)'" : "" } ?? "") + (end.3.map { " · TDZE \(Int($0))'" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let wd = windDir, windSpd > 0 {
                                        let sol = WindSolution(trueCourse: hdg, tas: 100, windFrom: wd, windSpeed: windSpd)
                                        let gustX = gust.map { WindSolution(trueCourse: hdg, tas: 100, windFrom: wd, windSpeed: $0).crosswind }
                                        let xw = abs(sol.crosswind)
                                        HStack(spacing: 10) {
                                            Label("\(Int(abs(sol.headwind).rounded())) kt \(sol.headwind >= 0 ? "head" : "TAIL")", systemImage: sol.headwind >= 0 ? "arrow.down" : "arrow.up")
                                                .foregroundStyle(sol.headwind >= 0 ? .green : .red)
                                            Label("\(Int(xw.rounded()))\(gustX.map { "G\(Int(abs($0).rounded()))" } ?? "") kt \(sol.crosswind >= 0 ? "R" : "L") xwind", systemImage: "arrow.left.and.right")
                                                .foregroundStyle(xw > limit ? .red : (xw > limit * 0.66 ? .orange : .white))
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                }
                                Spacer()
                                if best == end.0 {
                                    Text("BEST").font(.caption2.weight(.heavy)).padding(4).background(.green, in: Capsule()).foregroundStyle(.black)
                                }
                            }
                        }
                    }
                }
            }
            Text("Wind components use the METAR (true) wind and true runway headings. Max demonstrated crosswind for \(model.activeAircraft.model): \(Int(limit)) kt.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bestRunwayEnd(windDir: Double?, speed: Double) -> String? {
        guard let wd = windDir, speed > 0 else { return nil }
        var best: (String, Double)?
        for r in airport.runways {
            for (id, h) in [(r.le, r.leTrueHeading), (r.he, r.heTrueHeading)] {
                guard let h else { continue }
                let hw = WindSolution(trueCourse: h, tas: 100, windFrom: wd, windSpeed: speed).headwind
                if best == nil || hw > best!.1 { best = (id, hw) }
            }
        }
        return best?.0
    }
}

struct NotamTab: View {
    let airport: Airport
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoCard(title: "NOTAMs & TFRs") {
                Text("Always obtain a complete briefing (14 CFR 91.103). Open the official FAA sources:").font(.subheadline)
                Link(destination: URL(string: "https://notams.aim.faa.gov/notamSearch/nsapp.html#/results?searchType=0&designatorsForLocation=\(airport.faa)")!) {
                    Label("FAA NOTAM Search — \(airport.faa)", systemImage: "doc.text.magnifyingglass")
                }
                Link(destination: URL(string: "https://tfr.faa.gov/tfr3/?page=list")!) {
                    Label("FAA TFR List", systemImage: "exclamationmark.octagon")
                }
                Link(destination: URL(string: "https://www.1800wxbrief.com")!) {
                    Label("1800wxbrief.com (Leidos Flight Service)", systemImage: "phone.bubble")
                }
                Link(destination: URL(string: "https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/dafd/search/?searchName=\(airport.faa)")!) {
                    Label("Chart Supplement (A/FD) — \(airport.faa)", systemImage: "book")
                }
            }
        }
    }
}
