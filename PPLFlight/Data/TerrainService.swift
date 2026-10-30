import Foundation
import UIKit
import CoreLocation

/// 256x256 elevation tile (meters) decoded from AWS Terrain Tiles (Terrarium encoding).
struct ElevationTile: Sendable {
    let z: Int, x: Int, y: Int
    let meters: [Float]

    /// Bilinear sample at fractional pixel coordinates.
    func sample(px: Double, py: Double) -> Float {
        let fx = min(255, max(0, px - 0.5)), fy = min(255, max(0, py - 0.5))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(255, x0 + 1), y1 = min(255, y0 + 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let a = meters[y0 * 256 + x0], b = meters[y0 * 256 + x1]
        let c = meters[y1 * 256 + x0], d = meters[y1 * 256 + x1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }
}

struct TileKey: Hashable, Sendable { let z: Int, x: Int, y: Int }

actor TerrainService {
    static let shared = TerrainService()

    private var cache: [TileKey: ElevationTile] = [:]
    private var order: [TileKey] = []
    private var inflight: [TileKey: Task<ElevationTile, Error>] = [:]
    private let maxTiles = 160
    private let dir = AppPaths.cacheDir("terrain")

    func tile(z: Int, x: Int, y: Int) async throws -> ElevationTile {
        let n = 1 << z
        let key = TileKey(z: z, x: ((x % n) + n) % n, y: min(n - 1, max(0, y)))
        if let t = cache[key] { return t }
        if let task = inflight[key] { return try await task.value }
        let folder = dir
        let task = Task<ElevationTile, Error> {
            let file = folder.appendingPathComponent("\(key.z)-\(key.x)-\(key.y).png")
            var data = try? Data(contentsOf: file)
            if data == nil {
                let url = URL(string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(key.z)/\(key.x)/\(key.y).png")!
                let d = try await HTTP.data(url, timeout: 30)
                try? d.write(to: file, options: .atomic)
                data = d
            }
            guard let d = data, let tile = Self.decode(d, key: key) else { throw HTTPError.noData }
            return tile
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        let tile = try await task.value
        cache[key] = tile
        order.append(key)
        if order.count > maxTiles {
            let old = order.removeFirst()
            cache[old] = nil
        }
        return tile
    }

    nonisolated static func decode(_ data: Data, key: TileKey) -> ElevationTile? {
        guard let img = UIImage(data: data)?.cgImage else { return nil }
        let w = 256, h = 256
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var m = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(bytes[i * 4]), g = Float(bytes[i * 4 + 1]), b = Float(bytes[i * 4 + 2])
            m[i] = r * 256 + g + b / 256 - 32768
        }
        return ElevationTile(z: key.z, x: key.x, y: key.y, meters: m)
    }

    /// Fetch all tiles covering a bounding box (used to build synthetic-vision meshes).
    func tiles(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, z: Int) async -> [TileKey: ElevationTile] {
        let a = TileMath.tileXY(lat: maxLat, lon: minLon, z: z), b = TileMath.tileXY(lat: minLat, lon: maxLon, z: z)
        var out: [TileKey: ElevationTile] = [:]
        for ty in Int(floor(a.y))...Int(floor(b.y)) {
            for tx in Int(floor(a.x))...Int(floor(b.x)) {
                if let t = try? await tile(z: z, x: tx, y: ty) { out[TileKey(z: z, x: tx, y: ty)] = t }
            }
        }
        return out
    }

    /// Sample elevation (meters) from a prefetched tile set.
    nonisolated static func sample(_ tiles: [TileKey: ElevationTile], lat: Double, lon: Double, z: Int) -> Float? {
        let t = TileMath.tileXY(lat: lat, lon: lon, z: z)
        let tx = Int(floor(t.x)), ty = Int(floor(t.y))
        guard let tile = tiles[TileKey(z: z, x: tx, y: ty)] else { return nil }
        return tile.sample(px: (t.x - Double(tx)) * 256, py: (t.y - Double(ty)) * 256)
    }

    /// Terrain elevation (feet MSL) at a coordinate.
    func elevationFt(at c: CLLocationCoordinate2D, z: Int = 11) async -> Double? {
        let t = TileMath.tileXY(lat: c.latitude, lon: c.longitude, z: z)
        let tx = Int(floor(t.x)), ty = Int(floor(t.y))
        guard let tile = try? await tile(z: z, x: tx, y: ty) else { return nil }
        let m = tile.sample(px: (t.x - Double(tx)) * 256, py: (t.y - Double(ty)) * 256)
        return Double(max(0, m)) * Geo.feetPerMeter
    }

    /// Elevation profile (feet) along a polyline, `samples` evenly spaced points. Returns max over each sample window.
    func profile(along coords: [CLLocationCoordinate2D], samples: Int = 160, z: Int = 10) async -> [Double] {
        guard coords.count > 1 else { return [] }
        var cum: [Double] = [0]
        for i in 1..<coords.count { cum.append(cum[i - 1] + Geo.distanceNM(coords[i - 1], coords[i])) }
        let total = cum.last ?? 0
        guard total > 0 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(samples)
        var seg = 1
        for s in 0..<samples {
            let d = total * Double(s) / Double(samples - 1)
            while seg < cum.count - 1 && cum[seg] < d { seg += 1 }
            let segLen = max(1e-6, cum[seg] - cum[seg - 1])
            let f = min(1, max(0, (d - cum[seg - 1]) / segLen))
            let p = Geo.interpolate(coords[seg - 1], coords[seg], f)
            // Sample a small cross-track window (±1 nm) to catch ridges near the course
            let crs = Geo.bearing(coords[seg - 1], coords[seg])
            var m = await elevationFt(at: p, z: z) ?? 0
            for off in [-1.0, 1.0] {
                let q = Geo.destination(p, bearing: crs + 90, distanceNM: off)
                m = max(m, await elevationFt(at: q, z: z) ?? 0)
            }
            out.append(m)
        }
        return out
    }
}
