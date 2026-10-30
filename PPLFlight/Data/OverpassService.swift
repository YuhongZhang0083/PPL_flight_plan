import Foundation
import CoreLocation

/// Vector airport layout (taxiways, aprons, buildings, hold lines) from OpenStreetMap.
struct AirportLayout: Codable {
    struct Line: Codable { let kind: String; let ref: String; let coords: [[Double]] }      // [lat, lon]
    struct Area: Codable { let kind: String; let ref: String; let coords: [[Double]] }
    struct Point: Codable { let kind: String; let ref: String; let lat: Double; let lon: Double }
    var lines: [Line] = []
    var areas: [Area] = []
    var points: [Point] = []
    var isEmpty: Bool { lines.isEmpty && areas.isEmpty }
}

enum OverpassService {
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    static func layout(for airport: Airport) async throws -> AirportLayout {
        let file = AppPaths.cacheDir("osm").appendingPathComponent("\(airport.ident).json")
        if let d = try? Data(contentsOf: file), let l = try? JSONDecoder().decode(AirportLayout.self, from: d) { return l }
        let span = max(0.02, Double(airport.longestRunwayFt) / 6076 / 60 * 1.2)
        let dLon = span / max(0.3, cos(Geo.rad(airport.lat)))
        let bbox = String(format: "%.5f,%.5f,%.5f,%.5f", airport.lat - span, airport.lon - dLon, airport.lat + span, airport.lon + dLon)
        let query = """
        [out:json][timeout:30];
        (
          way["aeroway"~"^(taxiway|taxilane|apron|runway|hangar|terminal|holding_position|parking_position|helipad)$"](\(bbox));
          way["building"](\(bbox));
          node["aeroway"~"^(holding_position|parking_position)$"](\(bbox));
        );
        out geom;
        """
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        var lastError: Error = HTTPError.noData
        for ep in endpoints {
            do {
                let d = try await HTTP.data(URL(string: ep)!, timeout: 35, method: "POST", body: body.data(using: .utf8),
                                            contentType: "application/x-www-form-urlencoded")
                let layout = try parse(d)
                if let enc = try? JSONEncoder().encode(layout) { try? enc.write(to: file, options: .atomic) }
                return layout
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func parse(_ d: Data) throws -> AirportLayout {
        guard let json = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw HTTPError.noData }
        var layout = AirportLayout()
        for e in elements {
            let tags = e["tags"] as? [String: String] ?? [:]
            let aeroway = tags["aeroway"] ?? (tags["building"] != nil ? "building" : "")
            let ref = tags["ref"] ?? tags["name"] ?? ""
            if (e["type"] as? String) == "node" {
                if let la = (e["lat"] as? NSNumber)?.doubleValue, let lo = (e["lon"] as? NSNumber)?.doubleValue {
                    layout.points.append(.init(kind: aeroway, ref: ref, lat: la, lon: lo))
                }
                continue
            }
            guard let geom = e["geometry"] as? [[String: Any]] else { continue }
            let coords: [[Double]] = geom.compactMap {
                guard let la = ($0["lat"] as? NSNumber)?.doubleValue, let lo = ($0["lon"] as? NSNumber)?.doubleValue else { return nil }
                return [la, lo]
            }
            guard coords.count >= 2 else { continue }
            let closed = coords.first == coords.last && coords.count > 3
            switch aeroway {
            case "apron", "hangar", "terminal", "building", "helipad":
                if closed { layout.areas.append(.init(kind: aeroway, ref: ref, coords: coords)) }
            case "runway":
                if closed { layout.areas.append(.init(kind: "runway", ref: ref, coords: coords)) }
                else { layout.lines.append(.init(kind: "runway", ref: ref, coords: coords)) }
            default:
                layout.lines.append(.init(kind: aeroway, ref: ref, coords: coords))
            }
        }
        return layout
    }
}
