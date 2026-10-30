import SwiftUI
import CoreLocation

struct AirportWeatherTab: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    enum Sub: String, CaseIterable, Identifiable { case metar = "METAR", taf = "TAF", winds = "Winds", daily = "Daily"; var id: String { rawValue } }
    @State private var sub: Sub = .metar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Weather", selection: $sub) { ForEach(Sub.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            switch sub {
            case .metar: METARSection(airport: airport)
            case .taf: TAFSection(airport: airport)
            case .winds: WindsAtAirport(airport: airport)
            case .daily: DailyForecast(airport: airport)
            }
        }
    }
}

struct METARSection: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    @State private var nearbyLoaded = false

    var body: some View {
        let own = model.weather.metar(airport.weatherIdent)
        let nearby = own == nil ? model.weather.metarsNear(airport.coordinate, radiusNM: 30).first : nil
        VStack(alignment: .leading, spacing: 10) {
            if let m = own ?? nearby {
                if own == nil {
                    Label("No weather at \(airport.displayIdent). Nearest: \(m.icaoId) (\(Fmt.nm(Geo.distanceNM(airport.coordinate, m.coordinate))) nm)", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                METARCard(metar: m, fieldElevation: own != nil ? airport.elevFt : (m.elev.map { $0 * Geo.feetPerMeter } ?? airport.elevFt))
            } else {
                ProgressView("Loading METAR…").frame(maxWidth: .infinity)
            }
        }
        .task {
            if own == nil && !nearbyLoaded {
                nearbyLoaded = true
                let c = airport.coordinate
                await model.weather.fetchMETARs(minLat: c.latitude - 0.5, minLon: c.longitude - 0.6, maxLat: c.latitude + 0.5, maxLon: c.longitude + 0.6)
            }
        }
    }
}

struct METARCard: View {
    let metar: METAR
    let fieldElevation: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(metar.category)
                    .font(.headline.weight(.heavy))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.category(metar.category), in: Capsule())
                    .foregroundStyle(.black)
                Text(metar.icaoId).font(.headline)
                Spacer()
                if let t = metar.observed {
                    Text(Fmt.age(t)).font(.caption.weight(.semibold))
                        .foregroundStyle(Date().timeIntervalSince(t) > 5400 ? .orange : .secondary)
                }
            }
            Text(metar.rawOb)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.category(metar.category))
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Wind").foregroundStyle(.secondary); Text(metar.windText) }
                GridRow { Text("Visibility").foregroundStyle(.secondary); Text(metar.visibilityText) }
                GridRow { Text("Clouds").foregroundStyle(.secondary); Text(metar.cloudsText) }
                if let c = metar.ceilingFt { GridRow { Text("Ceiling").foregroundStyle(.secondary); Text("\(c.formatted())' AGL") } }
                if let t = metar.temp, let d = metar.dewp {
                    GridRow { Text("Temp / Dew").foregroundStyle(.secondary); Text(String(format: "%.0f°C / %.0f°C  (spread %.0f°)", t, d, t - d)) }
                }
                if let a = metar.altimeterInHg { GridRow { Text("Altimeter").foregroundStyle(.secondary); Text(String(format: "%.2f inHg", a)) } }
                if let da = metar.densityAltitude(fieldElevationFt: fieldElevation) {
                    GridRow {
                        Text("Density alt.").foregroundStyle(.secondary)
                        Text(Fmt.feet(da)).foregroundStyle(da > fieldElevation + 2000 ? .orange : .white)
                    }
                }
                if let wx = metar.wxString, !wx.isEmpty { GridRow { Text("Weather").foregroundStyle(.secondary); Text(wx) } }
            }
            .font(.subheadline)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TAFSection: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    @State private var taf: TAF?
    @State private var loaded = false
    @State private var fromNearby = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = taf {
                if fromNearby {
                    Label("No TAF for \(airport.displayIdent). Showing nearest: \(t.icaoId)", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                Text(t.rawTAF).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                ForEach(Array((t.fcsts ?? []).enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.category(p.category)).frame(width: 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(p.title).font(.subheadline.weight(.bold))
                                Spacer()
                                if let a = p.from, let b = p.to {
                                    Text("\(Fmt.zuluDayTime.string(from: a)) – \(Fmt.zulu.string(from: b))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Text([p.windText, p.visib.map { "\($0.text) SM" } ?? "", p.wxString ?? "", (p.clouds ?? []).map(\.text).joined(separator: " ")]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                        }
                    }
                    .padding(10)
                    .background(Theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if loaded {
                Text("No TAF available near \(airport.displayIdent).").foregroundStyle(.secondary)
            } else {
                ProgressView("Loading TAF…").frame(maxWidth: .infinity)
            }
        }
        .task {
            let list = await model.weather.tafs(airport.weatherIdent)
            if let t = list.first { taf = t } else {
                taf = await model.weather.nearestTAF(to: airport.coordinate)
                fromNearby = taf != nil
            }
            loaded = true
        }
    }
}

/// Forecast winds and temperatures aloft over the airport (GFS), plus the nearest FB product station.
struct WindsAtAirport: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    @State private var profile: WindProfile?
    @State private var fb: FBStation?
    @State private var hourOffset = 0.0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = profile {
                let time = Date().addingTimeInterval(hourOffset * 3600)
                InfoCard(title: "Winds aloft · \(time.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                    Slider(value: $hourOffset, in: 0...36, step: 1) { Text("Hours") }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("ALT").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("WIND").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("TEMP").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("ISA ±").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                        ForEach([18000, 15000, 12000, 10000, 9000, 7500, 6000, 4500, 3000].filter { Double($0) > airport.elevFt + 500 }, id: \.self) { alt in
                            if let w = p.wind(altitudeFt: Double(alt), at: time) {
                                GridRow {
                                    Text(Fmt.feet(Double(alt))).monospacedDigit()
                                    Text("\(String(format: "%03d", Int(w.dir.rounded()) % 360))° @ \(Int(w.speed.rounded())) kt").monospacedDigit()
                                    Text(String(format: "%+.0f°C", w.tempC)).monospacedDigit()
                                    Text(String(format: "%+.0f", w.tempC - Atmosphere.isaTempC(altitudeFt: Double(alt)))).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.subheadline)
                    Text("Source: GFS via Open-Meteo. Directions are true.").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let e = error {
                Text(e).foregroundStyle(.orange)
            } else {
                ProgressView("Loading winds aloft…").frame(maxWidth: .infinity)
            }
            if let st = fb {
                InfoCard(title: "FB winds aloft · station \(st.station)") {
                    ForEach(st.cells.indices, id: \.self) { i in
                        let cell = st.cells[i]
                        HStack {
                            Text(Fmt.feet(Double(cell.altitude))).monospacedDigit().frame(width: 70, alignment: .leading)
                            Text(cell.raw.isEmpty ? "—" : cell.raw).font(.system(.subheadline, design: .monospaced)).frame(width: 80, alignment: .leading)
                            if let d = FBStation.decode(cell.raw, altitude: cell.altitude) {
                                Text(d.lightVariable ? "Light & variable" : "\(String(format: "%03d", d.dir ?? 0))° @ \(d.speed) kt").font(.caption)
                                if let t = d.temp { Text("\(t)°C").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Text("Decode: DDSS±TT — direction (tens of degrees, true), speed kt, temp °C. 9900 = light & variable. Blank within 1,500' of station elevation.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            do {
                profile = try await WindsAloftService.profiles(at: [airport.coordinate]).first
            } catch { self.error = "Winds aloft unavailable: \(error.localizedDescription)" }
            if let prod = await model.weather.windsAloft(), let idx = model.db.index {
                let ranked = prod.stations.compactMap { st -> (FBStation, Double)? in
                    let loc = idx.airport("K" + st.station)?.coordinate ?? idx.navaids(st.station).first?.coordinate
                    return loc.map { (st, Geo.distanceNM($0, airport.coordinate)) }
                }.sorted { $0.1 < $1.1 }
                if let best = ranked.first { fb = best.0 }
            }
        }
    }
}

struct DailyForecast: View {
    let airport: Airport
    struct Day: Identifiable { let id: Int; let date: Date; let tMax: Double; let tMin: Double; let wind: Double; let gust: Double; let dir: Double; let precip: Double; let code: Int }
    @State private var days: [Day] = []
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if days.isEmpty {
                if failed { Text("Forecast unavailable.").foregroundStyle(.secondary) } else { ProgressView().frame(maxWidth: .infinity) }
            }
            ForEach(days) { d in
                HStack(spacing: 12) {
                    Text(d.date.formatted(.dateTime.weekday(.abbreviated).day())).font(.subheadline.weight(.bold)).frame(width: 64, alignment: .leading)
                    Image(systemName: symbol(d.code)).symbolRenderingMode(.multicolor).frame(width: 28)
                    Text(String(format: "%.0f° / %.0f°", d.tMax, d.tMin)).monospacedDigit()
                    Spacer()
                    Text(String(format: "%03.0f° %.0f G%.0f kt", d.dir, d.wind, d.gust)).font(.caption.monospacedDigit())
                    Text("\(Int(d.precip))%").font(.caption.monospacedDigit()).foregroundStyle(.cyan).frame(width: 36, alignment: .trailing)
                }
                .padding(10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("°C · surface wind kt (true) · precipitation probability. Open-Meteo.").font(.caption2).foregroundStyle(.secondary)
        }
        .task { await load() }
    }

    private func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67: return "cloud.rain.fill"
        case 71...77: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    private func load() async {
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(airport.lat)&longitude=\(airport.lon)&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant&wind_speed_unit=kn&timeformat=unixtime&timezone=auto&forecast_days=7"
        guard let url = URL(string: s), let d = try? await HTTP.data(url),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let daily = json["daily"] as? [String: Any], let t = daily["time"] as? [Double] else { failed = true; return }
        func arr(_ k: String) -> [Double] { (daily[k] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 } ?? [] }
        let tmax = arr("temperature_2m_max"), tmin = arr("temperature_2m_min"), w = arr("wind_speed_10m_max"), g = arr("wind_gusts_10m_max"),
            dir = arr("wind_direction_10m_dominant"), p = arr("precipitation_probability_max"), code = arr("weather_code")
        days = t.indices.map { i in
            Day(id: i, date: Date(timeIntervalSince1970: t[i]), tMax: i < tmax.count ? tmax[i] : 0, tMin: i < tmin.count ? tmin[i] : 0,
                wind: i < w.count ? w[i] : 0, gust: i < g.count ? g[i] : 0, dir: i < dir.count ? dir[i] : 0,
                precip: i < p.count ? p[i] : 0, code: Int(i < code.count ? code[i] : 3))
        }
    }
}
