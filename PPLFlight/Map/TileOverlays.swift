import Foundation
import MapKit
import UIKit

/// FAA aeronautical chart layers served by the FAA AIS ArcGIS tile services.
enum ChartLayer: String, Codable, CaseIterable, Identifiable {
    case sectional, terminal, ifrLow, ifrHigh, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sectional: return "VFR Sectional"
        case .terminal: return "VFR Terminal (TAC)"
        case .ifrLow: return "IFR Low Enroute"
        case .ifrHigh: return "IFR High Enroute"
        case .none: return "No chart"
        }
    }
    var service: String {
        switch self {
        case .sectional: return "VFR_Sectional"
        case .terminal: return "VFR_Terminal"
        case .ifrLow: return "IFR_AreaLow"
        case .ifrHigh: return "IFR_High"
        case .none: return ""
        }
    }
    var nativeMinZ: Int {
        switch self {
        case .sectional: return 8
        case .terminal: return 10
        case .ifrLow: return 7
        case .ifrHigh: return 5
        case .none: return 0
        }
    }
    var nativeMaxZ: Int {
        switch self {
        case .ifrHigh: return 9
        default: return 12
        }
    }
    func url(z: Int, x: Int, y: Int) -> URL {
        URL(string: "https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/\(service)/MapServer/tile/\(z)/\(y)/\(x)")!
    }
}

/// Disk-cached tile fetching with over-zoom (crop + upscale of the parent tile beyond the native max zoom).
actor TileLoader {
    static let shared = TileLoader()
    private let memory = NSCache<NSString, NSData>()

    init() { memory.totalCostLimit = 64 << 20 }

    private func fileURL(_ key: String, z: Int, x: Int, y: Int) -> URL {
        AppPaths.cacheDir("tiles/\(key)/\(z)").appendingPathComponent("\(x)_\(y).img")
    }

    func cachedTileCount(_ key: String) -> Int {
        let base = AppPaths.cacheDir("tiles/\(key)")
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var n = 0
        while e?.nextObject() != nil { n += 1 }
        return n
    }

    /// Raw tile at native zoom. `maxAge` nil = keep forever (charts), else refresh after maxAge seconds.
    func native(key: String, z: Int, x: Int, y: Int, maxAge: TimeInterval?, url: URL) async throws -> Data {
        let mk = "\(key)/\(z)/\(x)/\(y)" as NSString
        if let d = memory.object(forKey: mk) { return d as Data }
        let file = fileURL(key, z: z, x: x, y: y)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mod = attrs[.modificationDate] as? Date,
           maxAge == nil || Date().timeIntervalSince(mod) < maxAge!,
           let d = try? Data(contentsOf: file) {
            memory.setObject(d as NSData, forKey: mk, cost: d.count)
            return d
        }
        let d = try await HTTP.data(url, timeout: 30)
        try? d.write(to: file, options: .atomic)
        memory.setObject(d as NSData, forKey: mk, cost: d.count)
        return d
    }

    func tile(key: String, z: Int, x: Int, y: Int, nativeMax: Int, maxAge: TimeInterval?, urlFor: @Sendable (Int, Int, Int) -> URL) async throws -> Data {
        if z <= nativeMax {
            return try await native(key: key, z: z, x: x, y: y, maxAge: maxAge, url: urlFor(z, x, y))
        }
        let shift = min(z - nativeMax, 8)
        let pz = z - shift
        let px = x >> shift, py = y >> shift
        let parent = try await native(key: key, z: pz, x: px, y: py, maxAge: maxAge, url: urlFor(pz, px, py))
        guard let img = UIImage(data: parent)?.cgImage else { throw HTTPError.noData }
        let sub = 1 << shift
        let w = CGFloat(img.width) / CGFloat(sub)
        let rect = CGRect(x: CGFloat(x - px * sub) * w, y: CGFloat(y - py * sub) * w, width: w, height: w)
        guard let cropped = img.cropping(to: rect.integral) else { throw HTTPError.noData }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .medium
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        guard let png = out.pngData() else { throw HTTPError.noData }
        return png
    }
}

final class ChartTileOverlay: MKTileOverlay {
    let layer: ChartLayer

    init(layer: ChartLayer) {
        self.layer = layer
        super.init(urlTemplate: nil)
        minimumZ = layer.nativeMinZ
        maximumZ = 19
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let layer = self.layer
        Task {
            do {
                let d = try await TileLoader.shared.tile(key: layer.rawValue, z: path.z, x: path.x, y: path.y, nativeMax: layer.nativeMaxZ,
                                                         maxAge: nil, urlFor: { z, x, y in layer.url(z: z, x: x, y: y) })
                result(d, nil)
            } catch {
                result(nil, error)
            }
        }
    }
}

/// NEXRAD base reflectivity composite (Iowa Environmental Mesonet).
final class RadarTileOverlay: MKTileOverlay {
    let stamp: Int

    init(stamp: Int) {
        self.stamp = stamp
        super.init(urlTemplate: nil)
        minimumZ = 3
        maximumZ = 19
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let stamp = self.stamp
        Task {
            do {
                let d = try await TileLoader.shared.tile(key: "radar", z: path.z, x: path.x, y: path.y, nativeMax: 10, maxAge: 240,
                                                         urlFor: { z, x, y in
                    URL(string: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/\(z)/\(x)/\(y).png?t=\(stamp)")!
                })
                result(d, nil)
            } catch {
                result(nil, error)
            }
        }
    }
}

/// Hazard Advisor: colors terrain red within 100 ft and yellow within 1,000 ft of the reference altitude.
final class HazardTileOverlay: MKTileOverlay {
    private let lock = NSLock()
    private var _altitude: Double = 5500

    var altitudeFt: Double {
        get { lock.lock(); defer { lock.unlock() }; return _altitude }
        set { lock.lock(); _altitude = newValue; lock.unlock() }
    }

    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        minimumZ = 6
        maximumZ = 19
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let alt = altitudeFt
        Task.detached(priority: .utility) {
            let srcZ = min(path.z, 12)
            let shift = min(path.z - srcZ, 7)
            let px = path.x >> shift, py = path.y >> shift
            guard let tile = try? await TerrainService.shared.tile(z: srcZ, x: px, y: py) else { result(nil, nil); return }
            let sub = 1 << shift
            let ox = Double(path.x - px * sub) * 256 / Double(sub)
            let oy = Double(path.y - py * sub) * 256 / Double(sub)
            let scale = 1 / Double(sub)
            let red = (alt - 100) / Geo.feetPerMeter, yellow = (alt - 1000) / Geo.feetPerMeter
            let n = 256
            var bytes = [UInt8](repeating: 0, count: n * n * 4)
            var any = false
            for j in 0..<n {
                for i in 0..<n {
                    let e = Double(tile.sample(px: ox + (Double(i) + 0.5) * scale, py: oy + (Double(j) + 0.5) * scale))
                    let k = (j * n + i) * 4
                    if e >= red {
                        bytes[k] = 140; bytes[k + 1] = 24; bytes[k + 2] = 18; bytes[k + 3] = 150; any = true   // premultiplied
                    } else if e >= yellow {
                        bytes[k] = 128; bytes[k + 1] = 106; bytes[k + 2] = 22; bytes[k + 3] = 135; any = true
                    }
                }
            }
            guard any else { result(Self.emptyPNG, nil); return }
            let data: Data? = bytes.withUnsafeMutableBytes { ptr in
                guard let ctx = CGContext(data: ptr.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let cg = ctx.makeImage() else { return nil }
                return UIImage(cgImage: cg).pngData()
            }
            result(data, nil)
        }
    }

    static let emptyPNG: Data = {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: fmt).pngData { _ in }
    }()
}
