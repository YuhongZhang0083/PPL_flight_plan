import Foundation
import CoreLocation

/// Wind/temperature at one pressure level.
struct WindLevel: Hashable {
    let pressure: Int
    let heightFt: Double
    let dir: Double
    let speedKt: Double
    let tempC: Double
}

/// Hourly vertical profiles of wind/temperature at one location (Open-Meteo GFS pressure levels).
struct WindProfile {
    let coordinate: CLLocationCoordinate2D
    let times: [Date]
    let levels: [[WindLevel]]   // [timeIndex][level ascending]

    func timeIndex(for date: Date) -> Int {
        guard !times.isEmpty else { return 0 }
        var best = 0
        var bestD = Double.infinity
        for (i, t) in times.enumerated() {
            let d = abs(t.timeIntervalSince(date))
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// Interpolated wind (from-direction, speed kt) and temperature at an MSL altitude.
    func wind(altitudeFt: Double, at date: Date) -> (dir: Double, speed: Double, tempC: Double)? {
        let ti = timeIndex(for: date)
        guard ti < levels.count else { return nil }
        let ls = levels[ti].sorted { $0.heightFt < $1.heightFt }
        guard let first = ls.first, let last = ls.last else { return nil }
        if altitudeFt <= first.heightFt { return (first.dir, first.speedKt, first.tempC) }
        if altitudeFt >= last.heightFt { return (last.dir, last.speedKt, last.tempC) }
        for i in 1..<ls.count where ls[i].heightFt >= altitudeFt {
            let a = ls[i - 1], b = ls[i]
            let f = (altitudeFt - a.heightFt) / max(1, b.heightFt - a.heightFt)
            // interpolate as vectors
            let ua = -a.speedKt * sin(Geo.rad(a.dir)), va = -a.speedKt * cos(Geo.rad(a.dir))
            let ub = -b.speedKt * sin(Geo.rad(b.dir)), vb = -b.speedKt * cos(Geo.rad(b.dir))
            let u = ua + (ub - ua) * f, v = va + (vb - va) * f
            let spd = sqrt(u * u + v * v)
            let dir = Geo.norm360(Geo.deg(atan2(-u, -v)))
            return (dir, spd, a.tempC + (b.tempC - a.tempC) * f)
        }
        return nil
    }
}

/// Selectable altitude levels for the animated winds layer.
enum WindsLevel: Int, CaseIterable, Identifiable {
    case surface = 0, p925 = 925, p850 = 850, p700 = 700, p600 = 600, p500 = 500
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .surface: return "Surface"
        case .p925: return "3,000'"
        case .p850: return "5,000'"
        case .p700: return "10,000'"
        case .p600: return "14,000'"
        case .p500: return "18,000'"
        }
    }
    var variables: (speed: String, dir: String, temp: String) {
        switch self {
        case .surface: return ("wind_speed_10m", "wind_direction_10m", "temperature_2m")
        default: return ("wind_speed_\(rawValue)hPa", "wind_direction_\(rawValue)hPa", "temperature_\(rawValue)hPa")
        }
    }
}

/// Regular lat/lon grid of winds for the animated map layer.
final class WindGrid: @unchecked Sendable {
    let lats: [Double]          // ascending
    let lons: [Double]          // ascending
    let times: [Date]
    let speed: [[Float]]        // [t][j*nx+i]
    let dir: [[Float]]
    let temp: [[Float]]

    init(lats: [Double], lons: [Double], times: [Date], speed: [[Float]], dir: [[Float]], temp: [[Float]]) {
        self.lats = lats; self.lons = lons; self.times = times; self.speed = speed; self.dir = dir; self.temp = temp
    }

    var minLat: Double { lats.first ?? 0 }
    var maxLat: Double { lats.last ?? 0 }
    var minLon: Double { lons.first ?? 0 }
    var maxLon: Double { lons.last ?? 0 }

    /// Bilinear sample returning u (east), v (north) components in kt, speed and temperature.
    func sample(lat: Double, lon: Double, t: Int) -> (u: Double, v: Double, speed: Double, temp: Double)? {
        guard t < speed.count, lats.count > 1, lons.count > 1,
              lat >= minLat, lat <= maxLat, lon >= minLon, lon <= maxLon else { return nil }
        let nx = lons.count
        let fx = (lon - minLon) / (maxLon - minLon) * Double(nx - 1)
        let fy = (lat - minLat) / (maxLat - minLat) * Double(lats.count - 1)
        let i0 = min(nx - 2, max(0, Int(fx))), j0 = min(lats.count - 2, max(0, Int(fy)))
        let tx = fx - Double(i0), ty = fy - Double(j0)
        func uv(_ i: Int, _ j: Int) -> (Double, Double, Double) {
            let k = j * nx + i
            let s = Double(speed[t][k]), d = Geo.rad(Double(dir[t][k]))
            return (-s * sin(d), -s * cos(d), Double(temp[t][k]))
        }
        let a = uv(i0, j0), b = uv(i0 + 1, j0), c = uv(i0, j0 + 1), d = uv(i0 + 1, j0 + 1)
        func lerp(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> Double {
            (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + s * tx) * ty
        }
        let u = lerp(a.0, b.0, c.0, d.0), v = lerp(a.1, b.1, c.1, d.1)
        return (u, v, sqrt(u * u + v * v), lerp(a.2, b.2, c.2, d.2))
    }
}

enum WindsAloftService {
    static let pressureLevels = [1000, 975, 950, 925, 900, 850, 800, 700, 600, 500]

    /// Vertical profiles at up to ~60 points (one request).
    static func profiles(at points: [CLLocationCoordinate2D]) async throws -> [WindProfile] {
        guard !points.isEmpty else { return [] }
        var vars: [String] = []
        for p in pressureLevels {
            vars += ["wind_speed_\(p)hPa", "wind_direction_\(p)hPa", "temperature_\(p)hPa", "geopotential_height_\(p)hPa"]
        }
        let lat = points.map { String(format: "%.3f", $0.latitude) }.joined(separator: ",")
        let lon = points.map { String(format: "%.3f", $0.longitude) }.joined(separator: ",")
        let urlString = "https://api.open-meteo.com/v1/gfs?latitude=\(lat)&longitude=\(lon)&hourly=\(vars.joined(separator: ","))&wind_speed_unit=kn&timeformat=unixtime&forecast_hours=48&past_hours=1"
        guard let url = URL(string: urlString) else { return [] }
        let data = try await HTTP.data(url, timeout: 60)
        let objects = try jsonObjects(data)
        var out: [WindProfile] = []
        for (idx, obj) in objects.enumerated() {
            guard let hourly = obj["hourly"] as? [String: Any], let times = hourly["time"] as? [Double] else { continue }
            var levels: [[WindLevel]] = Array(repeating: [], count: times.count)
            for p in pressureLevels {
                let sp = numbers(hourly["wind_speed_\(p)hPa"]), dr = numbers(hourly["wind_direction_\(p)hPa"])
                let tp = numbers(hourly["temperature_\(p)hPa"]), gh = numbers(hourly["geopotential_height_\(p)hPa"])
                for t in 0..<times.count {
                    guard t < sp.count, t < dr.count, t < tp.count, t < gh.count,
                          let s = sp[t], let d = dr[t], let te = tp[t], let h = gh[t] else { continue }
                    levels[t].append(WindLevel(pressure: p, heightFt: h * Geo.feetPerMeter, dir: d, speedKt: s, tempC: te))
                }
            }
            let coord = idx < points.count ? points[idx] : CLLocationCoordinate2D(latitude: obj["latitude"] as? Double ?? 0, longitude: obj["longitude"] as? Double ?? 0)
            out.append(WindProfile(coordinate: coord, times: times.map { Date(timeIntervalSince1970: $0) }, levels: levels))
        }
        return out
    }

    /// A regular grid of one level for the animated layer.
    static func grid(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, nx: Int = 10, ny: Int = 9, level: WindsLevel) async throws -> WindGrid {
        var lats: [Double] = [], lons: [Double] = []
        for j in 0..<ny { lats.append(minLat + (maxLat - minLat) * Double(j) / Double(ny - 1)) }
        for i in 0..<nx { lons.append(minLon + (maxLon - minLon) * Double(i) / Double(nx - 1)) }
        var qlat: [String] = [], qlon: [String] = []
        for j in 0..<ny { for i in 0..<nx { qlat.append(String(format: "%.2f", lats[j])); qlon.append(String(format: "%.2f", lons[i])) } }
        let v = level.variables
        let urlString = "https://api.open-meteo.com/v1/gfs?latitude=\(qlat.joined(separator: ","))&longitude=\(qlon.joined(separator: ","))&hourly=\(v.speed),\(v.dir),\(v.temp)&wind_speed_unit=kn&timeformat=unixtime&forecast_hours=48"
        guard let url = URL(string: urlString) else { throw HTTPError.noData }
        let data = try await HTTP.data(url, timeout: 60)
        let objects = try jsonObjects(data)
        guard let firstHourly = objects.first?["hourly"] as? [String: Any], let times = firstHourly["time"] as? [Double] else { throw HTTPError.noData }
        let nt = times.count
        var speed = Array(repeating: Array(repeating: Float(0), count: nx * ny), count: nt)
        var dir = speed, temp = speed
        for (k, obj) in objects.enumerated() where k < nx * ny {
            guard let h = obj["hourly"] as? [String: Any] else { continue }
            let s = numbers(h[v.speed]), d = numbers(h[v.dir]), te = numbers(h[v.temp])
            for t in 0..<nt {
                speed[t][k] = Float(t < s.count ? (s[t] ?? 0) : 0)
                dir[t][k] = Float(t < d.count ? (d[t] ?? 0) : 0)
                temp[t][k] = Float(t < te.count ? (te[t] ?? 0) : 0)
            }
        }
        return WindGrid(lats: lats, lons: lons, times: times.map { Date(timeIntervalSince1970: $0) }, speed: speed, dir: dir, temp: temp)
    }

    private static func jsonObjects(_ data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]] { return arr }
        if let obj = json as? [String: Any] {
            if let reason = obj["reason"] as? String, obj["error"] != nil { throw HTTPError.status(400, reason) }
            return [obj]
        }
        return []
    }

    private static func numbers(_ any: Any?) -> [Double?] {
        guard let arr = any as? [Any] else { return [] }
        return arr.map { ($0 as? NSNumber)?.doubleValue }
    }
}
