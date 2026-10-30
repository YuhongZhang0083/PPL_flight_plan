import Foundation
import CoreLocation

struct Obstacle: Hashable, Identifiable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    let aglFt: Double
    let amslFt: Double
    let type: String
    let lighted: Bool
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// FAA Digital Obstacle File via the FAA AIS ArcGIS feature service, cached per half-degree cell.
actor ObstacleService {
    static let shared = ObstacleService()
    private var cells: [String: [Obstacle]] = [:]
    private var backoffUntil = Date.distantPast
    private let base = "https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/arcgis/rest/services/Digital_Obstacle_File/FeatureServer/0/query"

    func obstacles(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, minAGL: Double = 200) async -> [Obstacle] {
        var out: [Obstacle] = []
        let la0 = Int(floor(minLat * 2)), la1 = Int(floor(maxLat * 2)), lo0 = Int(floor(minLon * 2)), lo1 = Int(floor(maxLon * 2))
        guard (la1 - la0 + 1) * (lo1 - lo0 + 1) <= 16 else { return [] }
        for la in la0...la1 {
            for lo in lo0...lo1 {
                out += await cell(la, lo, minAGL: minAGL)
            }
        }
        return out.filter { $0.lat >= minLat && $0.lat <= maxLat && $0.lon >= minLon && $0.lon <= maxLon }
    }

    private func cell(_ la: Int, _ lo: Int, minAGL: Double) async -> [Obstacle] {
        let key = "\(la),\(lo),\(Int(minAGL))"
        if let c = cells[key] { return c }
        if Date() < backoffUntil { return [] }
        let file = AppPaths.cacheDir("obstacles").appendingPathComponent(key.replacingOccurrences(of: ",", with: "_") + ".json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < 14 * 86400,
           let d = try? Data(contentsOf: file), let list = Self.parse(d) {
            cells[key] = list
            return list
        }
        let xmin = Double(lo) / 2, ymin = Double(la) / 2
        let whereClause = "AGL>=\(Int(minAGL))".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let urlString = "\(base)?where=\(whereClause)&geometry=\(xmin),\(ymin),\(xmin + 0.5),\(ymin + 0.5)&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=OAS_Number,AGL,AMSL,Type_Code,Lighting&returnGeometry=true&outSR=4326&resultRecordCount=2000&f=json"
        guard let url = URL(string: urlString) else { return [] }
        do {
            let d = try await HTTP.data(url, timeout: 30)
            if let s = String(data: d.prefix(200), encoding: .utf8), s.contains("\"error\"") {
                backoffUntil = Date().addingTimeInterval(60)
                return []
            }
            let list = Self.parse(d) ?? []
            try? d.write(to: file, options: .atomic)
            cells[key] = list
            return list
        } catch {
            backoffUntil = Date().addingTimeInterval(60)
            return []
        }
    }

    private static func parse(_ d: Data) -> [Obstacle]? {
        guard let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return nil }
        return features.compactMap { f in
            guard let a = f["attributes"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let x = (g["x"] as? NSNumber)?.doubleValue, let y = (g["y"] as? NSNumber)?.doubleValue else { return nil }
            let agl = (a["AGL"] as? NSNumber)?.doubleValue ?? 0
            let amsl = (a["AMSL"] as? NSNumber)?.doubleValue ?? 0
            let type = ((a["Type_Code"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let light = ((a["Lighting"] as? String) ?? "N") != "N"
            return Obstacle(id: (a["OAS_Number"] as? String) ?? "\(x),\(y)", lat: y, lon: x, aglFt: agl, amslFt: amsl, type: type, lighted: light)
        }
    }
}

/// FAA designated points (fixes) lookup for route parsing.
enum FixService {
    static func lookup(_ ident: String) async -> Waypoint? {
        let q = "IDENT='\(ident.uppercased())'".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let s = "https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/arcgis/rest/services/DesignatedPoints/FeatureServer/0/query?where=\(q)&outFields=IDENT,TYPE_CODE,STATE&returnGeometry=true&outSR=4326&f=json"
        guard let url = URL(string: s), let d = try? await HTTP.data(url, timeout: 20),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let f = (json["features"] as? [[String: Any]])?.first,
              let g = f["geometry"] as? [String: Any],
              let x = (g["x"] as? NSNumber)?.doubleValue, let y = (g["y"] as? NSNumber)?.doubleValue else { return nil }
        return Waypoint(ident: ident.uppercased(), name: "Fix", kind: .fix, lat: y, lon: x)
    }
}
