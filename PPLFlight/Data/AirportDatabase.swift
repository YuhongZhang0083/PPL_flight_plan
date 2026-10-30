import Foundation
import CoreLocation
import Observation

/// Immutable, thread-safe spatial index over airports and navaids.
final class AirportIndex: @unchecked Sendable {
    let airports: [Airport]
    let navaids: [Navaid]
    private let byIdent: [String: Int]
    private let byFAA: [String: Int]
    private let byICAO: [String: Int]
    private let navByIdent: [String: [Int]]
    private let grid: [Int: [Int]]
    private let navGrid: [Int: [Int]]

    static func cell(_ lat: Double, _ lon: Double) -> Int {
        Int(floor(lat + 90)) * 400 + Int(floor(lon + 180))
    }

    init(airports: [Airport], navaids: [Navaid]) {
        self.airports = airports
        self.navaids = navaids
        var bi: [String: Int] = [:], bf: [String: Int] = [:], bc: [String: Int] = [:], g: [Int: [Int]] = [:]
        for (i, a) in airports.enumerated() {
            bi[a.ident.uppercased()] = i
            if !a.faa.isEmpty, bf[a.faa.uppercased()] == nil || a.country == "US" { bf[a.faa.uppercased()] = i }
            if !a.icao.isEmpty { bc[a.icao.uppercased()] = i }
            g[Self.cell(a.lat, a.lon), default: []].append(i)
        }
        var nb: [String: [Int]] = [:], ng: [Int: [Int]] = [:]
        for (i, n) in navaids.enumerated() {
            nb[n.ident.uppercased(), default: []].append(i)
            ng[Self.cell(n.lat, n.lon), default: []].append(i)
        }
        byIdent = bi; byFAA = bf; byICAO = bc; grid = g; navByIdent = nb; navGrid = ng
    }

    func airport(_ ident: String) -> Airport? {
        let q = ident.uppercased().trimmingCharacters(in: .whitespaces)
        if let i = byIdent[q] ?? byICAO[q] { return airports[i] }
        if q.count == 3, let i = byIdent["K" + q] ?? byICAO["K" + q] { return airports[i] }
        if let i = byFAA[q] { return airports[i] }
        if q.count == 4, q.hasPrefix("K"), let i = byFAA[String(q.dropFirst())] { return airports[i] }
        return nil
    }

    func navaids(_ ident: String) -> [Navaid] {
        (navByIdent[ident.uppercased()] ?? []).map { navaids[$0] }
    }

    func search(_ text: String, near: CLLocationCoordinate2D?, limit: Int = 60) -> [Airport] {
        let q = text.uppercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var exact: [Airport] = []
        if let a = airport(q) { exact.append(a) }
        var scored: [(Airport, Int)] = []
        for a in airports {
            var s = 0
            if a.ident.uppercased().hasPrefix(q) || a.faa.uppercased().hasPrefix(q) || a.icao.uppercased().hasPrefix(q) { s = 100 }
            else if a.name.uppercased().contains(q) { s = 50 }
            else if a.city.uppercased().contains(q) { s = 40 }
            if s > 0 {
                s += a.rank * 5
                if let n = near { s -= Int(min(30, Geo.distanceNM(n, a.coordinate) / 20)) }
                scored.append((a, s))
            }
        }
        scored.sort { $0.1 > $1.1 }
        var out = exact
        for (a, _) in scored where !out.contains(where: { $0.ident == a.ident }) {
            out.append(a)
            if out.count >= limit { break }
        }
        return out
    }

    func airports(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, minRank: Int, limit: Int = 400) -> [Airport] {
        var out: [Airport] = []
        let la0 = Int(floor(minLat)), la1 = Int(floor(maxLat)), lo0 = Int(floor(minLon)), lo1 = Int(floor(maxLon))
        guard (la1 - la0 + 1) * (lo1 - lo0 + 1) < 900 else { return [] }
        for la in la0...la1 {
            for lo in lo0...lo1 {
                for i in grid[Self.cell(Double(la), Double(lo))] ?? [] {
                    let a = airports[i]
                    if a.rank >= minRank, a.lat >= minLat, a.lat <= maxLat, a.lon >= minLon, a.lon <= maxLon { out.append(a) }
                }
            }
        }
        if out.count > limit {
            out.sort { ($0.rank, $0.longestRunwayFt) > ($1.rank, $1.longestRunwayFt) }
            out = Array(out.prefix(limit))
        }
        return out
    }

    func nearestAirports(to c: CLLocationCoordinate2D, count: Int = 10, maxNM: Double = 60, minRank: Int = 1) -> [(airport: Airport, distance: Double)] {
        let degLat = maxNM / 60, degLon = maxNM / 60 / max(0.2, cos(Geo.rad(c.latitude)))
        let list = airports(minLat: c.latitude - degLat, maxLat: c.latitude + degLat,
                            minLon: c.longitude - degLon, maxLon: c.longitude + degLon, minRank: minRank, limit: 5000)
        return list.map { ($0, Geo.distanceNM(c, $0.coordinate)) }
            .filter { $0.1 <= maxNM }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map { (airport: $0.0, distance: $0.1) }
    }

    func navaids(near c: CLLocationCoordinate2D, radiusNM: Double) -> [Navaid] {
        let dLat = radiusNM / 60, dLon = radiusNM / 60 / max(0.2, cos(Geo.rad(c.latitude)))
        var out: [Navaid] = []
        for la in Int(floor(c.latitude - dLat))...Int(floor(c.latitude + dLat)) {
            for lo in Int(floor(c.longitude - dLon))...Int(floor(c.longitude + dLon)) {
                for i in navGrid[Self.cell(Double(la), Double(lo))] ?? [] {
                    let n = navaids[i]
                    if Geo.distanceNM(c, n.coordinate) <= radiusNM { out.append(n) }
                }
            }
        }
        return out
    }

    /// Magnetic variation (+E) estimated by inverse-distance weighting of nearby navaids.
    func magneticVariation(at c: CLLocationCoordinate2D) -> Double {
        var radius = 120.0
        var list: [Navaid] = []
        while list.count < 3 && radius < 700 {
            list = navaids(near: c, radiusNM: radius).filter { $0.magVar != nil }
            radius *= 2
        }
        guard !list.isEmpty else { return Self.fallbackVariation(c) }
        let ranked = list.map { ($0, max(1, Geo.distanceNM(c, $0.coordinate))) }.sorted { $0.1 < $1.1 }.prefix(4)
        var sw = 0.0, sv = 0.0
        for (n, d) in ranked { let w = 1 / (d * d); sw += w; sv += w * (n.magVar ?? 0) }
        return sv / sw
    }

    /// Very rough CONUS model when no navaid data is loaded (good to ~2°).
    static func fallbackVariation(_ c: CLLocationCoordinate2D) -> Double {
        // Agonic line runs roughly through the Mississippi valley; ~0.33°/deg longitude east-west.
        return -(c.longitude + 90) * 0.33 + (c.latitude - 38) * 0.05
    }
}

private struct AirportDBFile: Codable {
    var version: Int
    var downloaded: Date
    var airports: [Airport]
    var navaids: [Navaid]
}

@MainActor
@Observable
final class AirportDatabase {
    enum Status: Equatable { case empty, loading, downloading(String), ready, failed(String) }

    private(set) var status: Status = .empty
    private(set) var index: AirportIndex?
    private(set) var downloadedAt: Date?
    var airportCount: Int { index?.airports.count ?? 0 }
    var navaidCount: Int { index?.navaids.count ?? 0 }
    var isReady: Bool { index != nil }

    private static var fileURL: URL { AppPaths.support.appendingPathComponent("airportdb.json") }
    private static let base = "https://davidmegginson.github.io/ourairports-data/"
    nonisolated static let countries: Set<String> = ["US", "PR", "VI", "CA", "MX", "BS"]

    func loadFromDisk() async {
        guard index == nil else { return }
        status = .loading
        let url = Self.fileURL
        let result: (AirportIndex, Date)? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            guard let file = try? dec.decode(AirportDBFile.self, from: data) else { return nil }
            return (AirportIndex(airports: file.airports, navaids: file.navaids), file.downloaded)
        }.value
        if let result {
            index = result.0
            downloadedAt = result.1
            status = .ready
        } else {
            status = .empty
        }
    }

    func download() async {
        if case .downloading = status { return }
        do {
            status = .downloading("Downloading airports…")
            async let a = HTTP.data(URL(string: Self.base + "airports.csv")!, timeout: 120, cachePolicy: .reloadIgnoringLocalCacheData)
            async let r = HTTP.data(URL(string: Self.base + "runways.csv")!, timeout: 120, cachePolicy: .reloadIgnoringLocalCacheData)
            async let f = HTTP.data(URL(string: Self.base + "airport-frequencies.csv")!, timeout: 120, cachePolicy: .reloadIgnoringLocalCacheData)
            async let n = HTTP.data(URL(string: Self.base + "navaids.csv")!, timeout: 120, cachePolicy: .reloadIgnoringLocalCacheData)
            let (ad, rd, fd, nd) = try await (a, r, f, n)
            status = .downloading("Building database…")
            let url = Self.fileURL
            let built: (AirportIndex, Date) = try await Task.detached(priority: .userInitiated) {
                let file = Self.build(airportsCSV: ad, runwaysCSV: rd, freqCSV: fd, navaidsCSV: nd)
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .iso8601
                let data = try enc.encode(file)
                try data.write(to: url, options: .atomic)
                return (AirportIndex(airports: file.airports, navaids: file.navaids), file.downloaded)
            }.value
            index = built.0
            downloadedAt = built.1
            status = .ready
        } catch {
            status = index == nil ? .failed(error.localizedDescription) : .ready
        }
    }

    nonisolated private static func build(airportsCSV: Data, runwaysCSV: Data, freqCSV: Data, navaidsCSV: Data) -> AirportDBFile {
        func columns(_ header: [String]) -> [String: Int] {
            var m: [String: Int] = [:]
            for (i, h) in header.enumerated() { m[h] = i }
            return m
        }
        func val(_ row: [String], _ col: Int?) -> String {
            guard let c = col, c < row.count else { return "" }
            return row[c]
        }

        // Runways
        var runways: [String: [Runway]] = [:]
        var rc: [String: Int] = [:]
        var first = true
        CSV.parse(runwaysCSV) { row in
            if first { rc = columns(row); first = false; return }
            if val(row, rc["closed"]) == "1" { return }
            let ident = val(row, rc["airport_ident"])
            let rw = Runway(
                le: val(row, rc["le_ident"]), he: val(row, rc["he_ident"]),
                lengthFt: Int(val(row, rc["length_ft"])) ?? 0, widthFt: Int(val(row, rc["width_ft"])) ?? 0,
                surface: val(row, rc["surface"]), lighted: val(row, rc["lighted"]) == "1",
                leLat: Double(val(row, rc["le_latitude_deg"])), leLon: Double(val(row, rc["le_longitude_deg"])),
                heLat: Double(val(row, rc["he_latitude_deg"])), heLon: Double(val(row, rc["he_longitude_deg"])),
                leHeadingT: Double(val(row, rc["le_heading_degT"])), heHeadingT: Double(val(row, rc["he_heading_degT"])),
                leElevFt: Double(val(row, rc["le_elevation_ft"])), heElevFt: Double(val(row, rc["he_elevation_ft"])),
                leDisplacedFt: Int(val(row, rc["le_displaced_threshold_ft"])), heDisplacedFt: Int(val(row, rc["he_displaced_threshold_ft"])))
            runways[ident, default: []].append(rw)
        }

        // Frequencies
        var freqs: [String: [Frequency]] = [:]
        var fc: [String: Int] = [:]
        first = true
        CSV.parse(freqCSV) { row in
            if first { fc = columns(row); first = false; return }
            guard let mhz = Double(val(row, fc["frequency_mhz"])) else { return }
            freqs[val(row, fc["airport_ident"]), default: []].append(
                Frequency(type: val(row, fc["type"]), desc: val(row, fc["description"]), mhz: mhz))
        }

        // Airports
        var airports: [Airport] = []
        airports.reserveCapacity(30000)
        var ac: [String: Int] = [:]
        first = true
        let keep: Set<String> = ["small_airport", "medium_airport", "large_airport", "seaplane_base"]
        CSV.parse(airportsCSV) { row in
            if first { ac = columns(row); first = false; return }
            let type = val(row, ac["type"])
            guard keep.contains(type) else { return }
            let country = val(row, ac["iso_country"])
            guard countries.contains(country) else { return }
            guard let lat = Double(val(row, ac["latitude_deg"])), let lon = Double(val(row, ac["longitude_deg"])) else { return }
            let ident = val(row, ac["ident"])
            var faa = val(row, ac["local_code"])
            if faa.isEmpty && country == "US" && ident.count == 4 && ident.hasPrefix("K") { faa = String(ident.dropFirst()) }
            if faa.isEmpty { faa = ident }
            var icao = val(row, ac["icao_code"])
            if icao.isEmpty {
                let gps = val(row, ac["gps_code"])
                if gps.count == 4, gps == ident, gps.first?.isLetter == true, gps.allSatisfy({ $0.isLetter }) { icao = gps }
            }
            var rws = runways[ident] ?? []
            rws.sort { $0.lengthFt > $1.lengthFt }
            airports.append(Airport(
                ident: ident, faa: faa, icao: icao, name: val(row, ac["name"]), type: type,
                lat: lat, lon: lon, elevFt: Double(val(row, ac["elevation_ft"])) ?? 0,
                city: val(row, ac["municipality"]), region: val(row, ac["iso_region"]), country: country,
                runways: rws, freqs: freqs[ident] ?? []))
        }

        // Navaids
        var navaids: [Navaid] = []
        var nc: [String: Int] = [:]
        first = true
        CSV.parse(navaidsCSV) { row in
            if first { nc = columns(row); first = false; return }
            guard countries.contains(val(row, nc["iso_country"])) else { return }
            guard let lat = Double(val(row, nc["latitude_deg"])), let lon = Double(val(row, nc["longitude_deg"])) else { return }
            let mv = Double(val(row, nc["magnetic_variation_deg"]))
            navaids.append(Navaid(ident: val(row, nc["ident"]), name: val(row, nc["name"]), type: val(row, nc["type"]),
                                  freqKHz: Int(val(row, nc["frequency_khz"])) ?? 0, lat: lat, lon: lon,
                                  elevFt: Double(val(row, nc["elevation_ft"])), magVar: mv))
        }
        return AirportDBFile(version: 1, downloaded: Date(), airports: airports, navaids: navaids)
    }
}
