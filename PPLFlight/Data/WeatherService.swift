import Foundation
import CoreLocation
import Observation

/// A JSON value that may be a number or a string (e.g. visib "10+" or wdir "VRB").
enum FlexValue: Codable, Hashable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .text("") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .text(let s): try c.encode(s)
        }
    }
    var number: Double? {
        switch self {
        case .number(let d): return d
        case .text(let s): return Double(s.replacingOccurrences(of: "+", with: ""))
        }
    }
    var text: String {
        switch self {
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .text(let s): return s
        }
    }
}

struct CloudLayer: Codable, Hashable {
    let cover: String
    let base: Int?
    var text: String { base.map { "\(cover) \($0.formatted())'" } ?? cover }
}

struct METAR: Codable, Hashable, Identifiable {
    var id: String { icaoId }
    let icaoId: String
    let obsTime: Double?
    let temp: Double?
    let dewp: Double?
    let wdir: FlexValue?
    let wspd: Double?
    let wgst: Double?
    let visib: FlexValue?
    let altim: Double?
    let rawOb: String
    let lat: Double
    let lon: Double
    let elev: Double?
    let name: String?
    let clouds: [CloudLayer]?
    let fltCat: String?
    let wxString: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var observed: Date? { obsTime.map { Date(timeIntervalSince1970: $0) } }
    var altimeterInHg: Double? { altim.map { $0 > 100 ? $0 * 0.0295300 : $0 } }
    var category: String { fltCat ?? computedCategory }
    var windDirection: Double? { wdir?.number }
    var isVariableWind: Bool { wdir?.text.uppercased() == "VRB" }

    var ceilingFt: Int? {
        (clouds ?? []).filter { ["BKN", "OVC", "OVX", "VV"].contains($0.cover) }.compactMap(\.base).min()
    }
    var visibilitySM: Double? { visib?.number }

    var computedCategory: String {
        let c = ceilingFt ?? 99999
        let v = visibilitySM ?? 10
        if c < 500 || v < 1 { return "LIFR" }
        if c < 1000 || v < 3 { return "IFR" }
        if c <= 3000 || v <= 5 { return "MVFR" }
        return "VFR"
    }

    var windText: String {
        guard let s = wspd else { return "--" }
        if s == 0 { return "Calm" }
        let dir = isVariableWind ? "VRB" : String(format: "%03d°", Int(windDirection ?? 0))
        var t = "\(dir) @ \(Int(s)) kt"
        if let g = wgst { t += " G\(Int(g))" }
        return t
    }

    var visibilityText: String {
        guard let v = visib else { return "--" }
        return v.text.hasSuffix("+") ? "\(v.text) SM" : "\(v.text) SM"
    }

    var cloudsText: String {
        let c = clouds ?? []
        if c.isEmpty { return "Clear" }
        return c.map(\.text).joined(separator: ", ")
    }

    func densityAltitude(fieldElevationFt: Double) -> Double? {
        guard let t = temp, let a = altimeterInHg else { return nil }
        let pa = Atmosphere.pressureAltitude(fieldElevationFt: fieldElevationFt, altimeterInHg: a)
        return Atmosphere.densityAltitude(pressureAltitudeFt: pa, oatC: t)
    }
}

struct TAFPeriod: Codable, Hashable {
    let timeFrom: Double?
    let timeTo: Double?
    let fcstChange: String?
    let probability: Double?
    let wdir: FlexValue?
    let wspd: Double?
    let wgst: Double?
    let visib: FlexValue?
    let wxString: String?
    let clouds: [CloudLayer]?

    var from: Date? { timeFrom.map { Date(timeIntervalSince1970: $0) } }
    var to: Date? { timeTo.map { Date(timeIntervalSince1970: $0) } }
    var category: String {
        let c = (clouds ?? []).filter { ["BKN", "OVC", "OVX", "VV"].contains($0.cover) }.compactMap(\.base).min() ?? 99999
        let v = visib?.number ?? 10
        if c < 500 || v < 1 { return "LIFR" }
        if c < 1000 || v < 3 { return "IFR" }
        if c <= 3000 || v <= 5 { return "MVFR" }
        return "VFR"
    }
    var windText: String {
        guard let s = wspd else { return "" }
        if s == 0 { return "Calm" }
        let d = wdir?.text.uppercased() == "VRB" ? "VRB" : String(format: "%03d°", Int(wdir?.number ?? 0))
        return "\(d) @ \(Int(s))" + (wgst.map { " G\(Int($0))" } ?? "") + " kt"
    }
    var title: String {
        switch fcstChange {
        case "FM": return "From"
        case "BECMG": return "Becoming"
        case "TEMPO": return "Temporary"
        case "PROB": return "Probability \(Int(probability ?? 0))%"
        default: return probability != nil ? "Probability \(Int(probability ?? 0))%" : "Initial"
        }
    }
}

struct TAF: Codable, Hashable, Identifiable {
    var id: String { icaoId + (rawTAF.prefix(30)) }
    let icaoId: String
    let rawTAF: String
    let issueTime: String?
    let validTimeFrom: Double?
    let validTimeTo: Double?
    let fcsts: [TAFPeriod]?
    let name: String?
    let lat: Double?
    let lon: Double?
}

struct PIREP: Codable, Hashable, Identifiable {
    var id: String { rawOb }
    let rawOb: String
    let lat: Double?
    let lon: Double?
    let fltLvl: Double?
    let acType: String?
    let pirepType: String?
    let obsTime: Double?
    var observed: Date? { obsTime.map { Date(timeIntervalSince1970: $0) } }
}

/// One FB (winds and temperatures aloft) station row.
struct FBStation: Identifiable, Hashable {
    var id: String { station }
    let station: String
    let cells: [(altitude: Int, raw: String)]

    static func == (a: FBStation, b: FBStation) -> Bool { a.station == b.station && a.cells.map(\.raw) == b.cells.map(\.raw) }
    func hash(into h: inout Hasher) { h.combine(station) }

    /// Decode "1719+04" / "9900" / "7525-12" / "212645".
    static func decode(_ raw: String, altitude: Int) -> (dir: Int?, speed: Int, temp: Int?, lightVariable: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 4, let dd = Int(s.prefix(2)), let ss = Int(s.dropFirst(2).prefix(2)) else { return nil }
        var temp: Int? = nil
        if s.count > 4 {
            let rest = s.dropFirst(4)
            if let t = Int(rest) { temp = altitude > 24000 && !rest.hasPrefix("+") && !rest.hasPrefix("-") ? -abs(t) : t }
        }
        if dd == 99 && ss == 0 { return (nil, 0, temp, true) }
        var dir = dd * 10, spd = ss
        if dd > 36 { dir = (dd - 50) * 10; spd += 100 }
        return (dir, spd, temp, false)
    }
}

struct FBProduct {
    let header: String
    let validText: String
    let altitudes: [Int]
    let stations: [FBStation]

    static func parse(_ text: String) -> FBProduct? {
        let lines = text.components(separatedBy: "\n")
        guard let hIdx = lines.firstIndex(where: { $0.hasPrefix("FT ") }) else { return nil }
        let header = lines[hIdx]
        // Column ends = end index of each altitude token in header
        var tokens: [(alt: Int, end: Int)] = []
        let chars = Array(header)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber {
                var j = i
                while j < chars.count && chars[j].isNumber { j += 1 }
                if let alt = Int(String(chars[i..<j])) { tokens.append((alt, j)) }
                i = j
            } else { i += 1 }
        }
        var stations: [FBStation] = []
        for line in lines[(hIdx + 1)...] {
            let lc = Array(line)
            guard lc.count >= 3, lc[0].isLetter else { continue }
            let st = String(lc[0..<3])
            var cells: [(Int, String)] = []
            var start = 4
            for t in tokens {
                let end = min(t.end, lc.count)
                let s = start < end ? String(lc[start..<end]).trimmingCharacters(in: .whitespaces) : ""
                cells.append((t.alt, s))
                start = t.end + 1
            }
            stations.append(FBStation(station: st, cells: cells.map { (altitude: $0.0, raw: $0.1) }))
        }
        let valid = lines.first(where: { $0.contains("VALID") }) ?? ""
        return FBProduct(header: lines.prefix(hIdx).joined(separator: "\n"), validText: valid,
                         altitudes: tokens.map(\.alt), stations: stations)
    }
}

/// aviationweather.gov Data API client with short-lived caching.
@MainActor
@Observable
final class WeatherService {
    private(set) var metars: [String: METAR] = [:]
    @ObservationIgnored private var regionFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var tafCache: [String: (Date, [TAF])] = [:]
    @ObservationIgnored private var fbCache: [String: (Date, FBProduct)] = [:]

    static let base = "https://aviationweather.gov/api/data/"

    func metar(_ ident: String) -> METAR? { metars[ident.uppercased()] }

    @discardableResult
    func fetchMETARs(ids: [String]) async -> [METAR] {
        let list = ids.map { $0.uppercased() }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return [] }
        var out: [METAR] = []
        for chunk in stride(from: 0, to: list.count, by: 80).map({ Array(list[$0..<min($0 + 80, list.count)]) }) {
            guard let url = URL(string: Self.base + "metar?ids=\(chunk.joined(separator: ","))&format=json") else { continue }
            if let m = try? await HTTP.json([METAR].self, from: url) { out += m }
        }
        for m in out { metars[m.icaoId] = m }
        return out
    }

    /// Fetch METARs inside a bounding box (cached ~5 min per rounded box).
    func fetchMETARs(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async {
        let key = String(format: "%.0f,%.0f,%.0f,%.0f", minLat * 2, minLon * 2, maxLat * 2, maxLon * 2)
        if let t = regionFetchedAt[key], Date().timeIntervalSince(t) < 300 { return }
        if inflight.contains(key) { return }
        inflight.insert(key)
        defer { inflight.remove(key) }
        let bbox = String(format: "%.2f,%.2f,%.2f,%.2f", minLat, minLon, maxLat, maxLon)
        guard let url = URL(string: Self.base + "metar?bbox=\(bbox)&format=json") else { return }
        if let list = try? await HTTP.json([METAR].self, from: url) {
            for m in list { metars[m.icaoId] = m }
            regionFetchedAt[key] = Date()
        }
    }

    func metarsNear(_ c: CLLocationCoordinate2D, radiusNM: Double) -> [METAR] {
        metars.values.filter { Geo.distanceNM(c, $0.coordinate) <= radiusNM }
            .sorted { Geo.distanceNM(c, $0.coordinate) < Geo.distanceNM(c, $1.coordinate) }
    }

    func tafs(_ ident: String) async -> [TAF] {
        let id = ident.uppercased()
        if let c = tafCache[id], Date().timeIntervalSince(c.0) < 600 { return c.1 }
        guard let url = URL(string: Self.base + "taf?ids=\(id)&format=json") else { return [] }
        let list = (try? await HTTP.json([TAF].self, from: url)) ?? []
        tafCache[id] = (Date(), list)
        return list
    }

    /// TAF from the nearest reporting station if the airport has none.
    func nearestTAF(to c: CLLocationCoordinate2D) async -> TAF? {
        let bbox = String(format: "%.2f,%.2f,%.2f,%.2f", c.latitude - 0.9, c.longitude - 1.1, c.latitude + 0.9, c.longitude + 1.1)
        guard let url = URL(string: Self.base + "taf?bbox=\(bbox)&format=json"),
              let list = try? await HTTP.json([TAF].self, from: url) else { return nil }
        return list.filter { $0.lat != nil && $0.lon != nil }
            .min { Geo.distanceNM(c, .init(latitude: $0.lat!, longitude: $0.lon!)) < Geo.distanceNM(c, .init(latitude: $1.lat!, longitude: $1.lon!)) }
    }

    func pireps(near c: CLLocationCoordinate2D, radiusNM: Int = 100) async -> [PIREP] {
        let bbox = String(format: "%.2f,%.2f,%.2f,%.2f", c.latitude - 1.7, c.longitude - 2.0, c.latitude + 1.7, c.longitude + 2.0)
        guard let url = URL(string: Self.base + "pirep?bbox=\(bbox)&age=3&format=json") else { return [] }
        return (try? await HTTP.json([PIREP].self, from: url)) ?? []
    }

    /// FB winds aloft text product. fcst: "06", "12" or "24".
    func windsAloft(fcst: String = "06") async -> FBProduct? {
        if let c = fbCache[fcst], Date().timeIntervalSince(c.0) < 1800 { return c.1 }
        guard let url = URL(string: Self.base + "windtemp?region=all&level=low&fcst=\(fcst)") else { return nil }
        guard let d = try? await HTTP.data(url), let text = String(data: d, encoding: .utf8),
              let p = FBProduct.parse(text) else { return nil }
        fbCache[fcst] = (Date(), p)
        return p
    }
}
