import Foundation
import SceneKit
import UIKit
import CoreLocation

/// Height-field mesh around an origin. Scene axes: +x east, +y up, -z north (meters).
struct TerrainMeshData: @unchecked Sendable {
    let origin: CLLocationCoordinate2D
    let n: Int
    let spacing: Double
    let heights: [Float]          // meters, row-major (j = south index)
    let vertices: [SCNVector3]
    let normals: [SCNVector3]
    let indices: [Int32]

    static let metersPerDegLat = 110_540.0
    static func metersPerDegLon(_ lat: Double) -> Double { 111_320.0 * cos(Geo.rad(lat)) }

    static func build(center: CLLocationCoordinate2D, halfSize: Double = 32_000, n: Int = 161) async -> TerrainMeshData? {
        let dLat = halfSize / metersPerDegLat * 1.05
        let dLon = halfSize / metersPerDegLon(center.latitude) * 1.05
        let z = 11
        let tiles = await TerrainService.shared.tiles(minLat: center.latitude - dLat, maxLat: center.latitude + dLat,
                                                      minLon: center.longitude - dLon, maxLon: center.longitude + dLon, z: z)
        guard !tiles.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> TerrainMeshData in
            let spacing = 2 * halfSize / Double(n - 1)
            var h = [Float](repeating: 0, count: n * n)
            let mLon = metersPerDegLon(center.latitude)
            for j in 0..<n {
                let zSouth = -halfSize + Double(j) * spacing
                let lat = center.latitude - zSouth / metersPerDegLat
                for i in 0..<n {
                    let x = -halfSize + Double(i) * spacing
                    let lon = center.longitude + x / mLon
                    h[j * n + i] = max(0, TerrainService.sample(tiles, lat: lat, lon: lon, z: z) ?? 0)
                }
            }
            var verts = [SCNVector3](repeating: SCNVector3Zero, count: n * n)
            var norms = [SCNVector3](repeating: SCNVector3Zero, count: n * n)
            for j in 0..<n {
                for i in 0..<n {
                    let k = j * n + i
                    verts[k] = SCNVector3(Float(-halfSize + Double(i) * spacing), h[k], Float(-halfSize + Double(j) * spacing))
                    let hl = h[j * n + max(0, i - 1)], hr = h[j * n + min(n - 1, i + 1)]
                    let hu = h[max(0, j - 1) * n + i], hd = h[min(n - 1, j + 1) * n + i]
                    let dx = (hr - hl) / Float(2 * spacing), dz = (hd - hu) / Float(2 * spacing)
                    let len = sqrt(dx * dx + 1 + dz * dz)
                    norms[k] = SCNVector3(-dx / len, 1 / len, -dz / len)
                }
            }
            var idx: [Int32] = []
            idx.reserveCapacity((n - 1) * (n - 1) * 6)
            for j in 0..<(n - 1) {
                for i in 0..<(n - 1) {
                    let a = Int32(j * n + i), b = a + 1, c = a + Int32(n), d = c + 1
                    idx += [a, c, b, b, c, d]
                }
            }
            return TerrainMeshData(origin: center, n: n, spacing: spacing, heights: h, vertices: verts, normals: norms, indices: idx)
        }.value
    }

    /// Scene position for a coordinate/altitude relative to this mesh's origin.
    func scenePosition(_ c: CLLocationCoordinate2D, altitudeM: Double) -> SCNVector3 {
        let x = (c.longitude - origin.longitude) * Self.metersPerDegLon(origin.latitude)
        let zNorth = (c.latitude - origin.latitude) * Self.metersPerDegLat
        return SCNVector3(Float(x), Float(altitudeM), Float(-zNorth))
    }

    func colors(hazardAltitudeFt alt: Double) -> Data {
        let red = Float((alt - 100) / Geo.feetPerMeter), yellow = Float((alt - 1000) / Geo.feetPerMeter)
        var c = [Float](repeating: 0, count: heights.count * 3)
        for k in 0..<heights.count {
            let e = heights[k]
            var r: Float, g: Float, b: Float
            if e < 1 { r = 0.16; g = 0.32; b = 0.55 }
            else if e >= red { r = 0.86; g = 0.16; b = 0.11 }
            else if e >= yellow { r = 0.92; g = 0.76; b = 0.16 }
            else {
                let t = min(1, e / 2600)
                // green lowlands -> olive -> tan -> grey
                if t < 0.35 { let f = t / 0.35; r = 0.30 + 0.14 * f; g = 0.52 + 0.02 * f; b = 0.22 + 0.02 * f }
                else if t < 0.7 { let f = (t - 0.35) / 0.35; r = 0.44 + 0.12 * f; g = 0.54 - 0.1 * f; b = 0.24 + 0.06 * f }
                else { let f = (t - 0.7) / 0.3; r = 0.56 + 0.06 * f; g = 0.44 + 0.12 * f; b = 0.30 + 0.24 * f }
            }
            c[k * 3] = r; c[k * 3 + 1] = g; c[k * 3 + 2] = b
        }
        return c.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Owns the SceneKit scene for synthetic vision.
@MainActor
final class SyntheticVisionController {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let terrainNode = SCNNode()
    private let runwaysNode = SCNNode()
    private var mesh: TerrainMeshData?
    private var vertexSource: SCNGeometrySource?
    private var normalSource: SCNGeometrySource?
    private var element: SCNGeometryElement?
    private var building = false
    private var lastColorAlt: Double = -9999
    private var runwayAirports: Set<String> = []
    static let hFOV: CGFloat = 70

    init() {
        let cam = SCNCamera()
        cam.zNear = 15
        cam.zFar = 110_000
        cam.fieldOfView = Self.hFOV
        cam.projectionDirection = .horizontal
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(terrainNode)
        scene.rootNode.addChildNode(runwaysNode)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        scene.rootNode.addChildNode(sun)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 420
        scene.rootNode.addChildNode(amb)

        scene.fogColor = Self.haze
        scene.fogStartDistance = 22_000
        scene.fogEndDistance = 62_000
        scene.fogDensityExponent = 1.4
        scene.background.contents = Self.skyCube()
    }

    static let haze = UIColor(red: 0.70, green: 0.82, blue: 0.94, alpha: 1)

    /// Cube-map sky (+X, -X, +Y, -Y, +Z, -Z) so the horizon follows pitch and roll.
    static func skyCube() -> [UIImage] {
        let s: CGFloat = 256
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let side = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            let colors = [UIColor(red: 0.12, green: 0.36, blue: 0.78, alpha: 1).cgColor,
                          UIColor(red: 0.45, green: 0.66, blue: 0.92, alpha: 1).cgColor,
                          haze.cgColor,
                          UIColor(red: 0.38, green: 0.36, blue: 0.26, alpha: 1).cgColor,
                          UIColor(red: 0.22, green: 0.22, blue: 0.16, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.35, 0.5, 0.505, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: s), options: [])
        }
        let top = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            UIColor(red: 0.12, green: 0.36, blue: 0.78, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        }
        let bottom = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            UIColor(red: 0.22, green: 0.22, blue: 0.16, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        }
        return [side, side, top, bottom, side, side]
    }

    func ensureMesh(around c: CLLocationCoordinate2D, airports: @escaping () -> [Airport]) {
        if building { return }
        if let m = mesh {
            let dx = (c.longitude - m.origin.longitude) * TerrainMeshData.metersPerDegLon(m.origin.latitude)
            let dz = (c.latitude - m.origin.latitude) * TerrainMeshData.metersPerDegLat
            if sqrt(dx * dx + dz * dz) < 12_000 { return }
        }
        building = true
        Task {
            let built = await TerrainMeshData.build(center: c)
            building = false
            guard let built else { return }
            install(built)
            buildRunways(airports())
        }
    }

    private func install(_ m: TerrainMeshData) {
        mesh = m
        vertexSource = SCNGeometrySource(vertices: m.vertices)
        normalSource = SCNGeometrySource(normals: m.normals)
        element = SCNGeometryElement(indices: m.indices, primitiveType: .triangles)
        lastColorAlt = -9999
        runwayAirports = []
    }

    func updateColors(hazardAltitudeFt alt: Double) {
        guard let m = mesh, let vs = vertexSource, let ns = normalSource, let el = element else { return }
        guard abs(alt - lastColorAlt) >= 50 else { return }
        lastColorAlt = alt
        let data = m.colors(hazardAltitudeFt: alt)
        let cs = SCNGeometrySource(data: data, semantic: .color, vectorCount: m.heights.count, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geo = SCNGeometry(sources: [vs, ns, cs], elements: [el])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white
        mat.lightingModel = .lambert
        mat.isDoubleSided = true
        geo.materials = [mat]
        terrainNode.geometry = geo
    }

    private func buildRunways(_ airports: [Airport]) {
        guard let m = mesh else { return }
        runwaysNode.childNodes.forEach { $0.removeFromParentNode() }
        let asphalt = SCNMaterial()
        asphalt.diffuse.contents = UIColor(white: 0.18, alpha: 1)
        asphalt.emission.contents = UIColor(white: 0.08, alpha: 1)
        let stripe = SCNMaterial()
        stripe.diffuse.contents = UIColor.white
        stripe.emission.contents = UIColor(white: 0.6, alpha: 1)
        for a in airports {
            for r in a.runways {
                guard let p1 = r.leCoord, let p2 = r.heCoord else { continue }
                let mid = Geo.interpolate(p1, p2, 0.5)
                let elevM = a.elevFt / Geo.feetPerMeter
                let pos = m.scenePosition(mid, altitudeM: elevM + 3)
                let length = CGFloat(Geo.distanceNM(p1, p2) * Geo.metersPerNM)
                let width = CGFloat(max(18, Double(r.widthFt) / Geo.feetPerMeter))
                let box = SCNBox(width: width, height: 2, length: length, chamferRadius: 0)
                box.materials = [asphalt]
                let node = SCNNode(geometry: box)
                node.position = pos
                node.eulerAngles.y = Float(-Geo.rad(Geo.bearing(p1, p2)))
                let center = SCNBox(width: 1.2, height: 0.3, length: length * 0.8, chamferRadius: 0)
                center.materials = [stripe]
                let cn = SCNNode(geometry: center)
                cn.position = SCNVector3(0, 1.1, 0)
                node.addChildNode(cn)
                runwaysNode.addChildNode(node)
            }
        }
    }

    func updateCamera(position c: CLLocationCoordinate2D, altitudeFt: Double, headingTrue: Double, pitchDeg: Double, rollDeg: Double) {
        guard let m = mesh else { return }
        cameraNode.position = m.scenePosition(c, altitudeM: altitudeFt / Geo.feetPerMeter + 2)
        let yaw = simd_quatf(angle: Float(-Geo.rad(headingTrue)), axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: Float(Geo.rad(pitchDeg)), axis: SIMD3<Float>(1, 0, 0))
        let roll = simd_quatf(angle: Float(-Geo.rad(rollDeg)), axis: SIMD3<Float>(0, 0, 1))
        cameraNode.simdOrientation = yaw * pitch * roll
    }

    /// Terrain height (m) under a coordinate, from the loaded mesh.
    func meshElevation(at c: CLLocationCoordinate2D) -> Double? {
        guard let m = mesh else { return nil }
        let p = m.scenePosition(c, altitudeM: 0)
        let half = Double(m.n - 1) * m.spacing / 2
        let fi = (Double(p.x) + half) / m.spacing, fj = (Double(p.z) + half) / m.spacing
        guard fi >= 0, fj >= 0, fi < Double(m.n - 1), fj < Double(m.n - 1) else { return nil }
        return Double(m.heights[Int(fj) * m.n + Int(fi)])
    }
}
