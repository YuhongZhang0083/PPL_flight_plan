import Foundation
import MapKit
import UIKit

/// Heat-map overlay for winds aloft (temperature or speed), drawn in Mercator space.
final class WindHeatOverlay: NSObject, MKOverlay {
    let grid: WindGrid
    let timeIndex: Int
    let showSpeed: Bool
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (grid.minLat + grid.maxLat) / 2, longitude: (grid.minLon + grid.maxLon) / 2)
    }
    private(set) lazy var image: UIImage? = makeImage()

    init(grid: WindGrid, timeIndex: Int, showSpeed: Bool) {
        self.grid = grid
        self.timeIndex = timeIndex
        self.showSpeed = showSpeed
        let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: grid.maxLat, longitude: grid.minLon))
        let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: grid.minLat, longitude: grid.maxLon))
        boundingMapRect = MKMapRect(x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y)
    }

    static func tempColor(_ c: Double) -> (Double, Double, Double) {
        // -40°C purple -> -20 blue -> 0 cyan/green -> 15 yellow -> 30 red
        let stops: [(Double, (Double, Double, Double))] = [
            (-40, (0.35, 0.1, 0.55)), (-25, (0.2, 0.2, 0.75)), (-10, (0.15, 0.45, 0.85)), (0, (0.2, 0.65, 0.7)),
            (8, (0.35, 0.7, 0.35)), (16, (0.85, 0.75, 0.25)), (24, (0.9, 0.45, 0.15)), (34, (0.75, 0.15, 0.12)),
        ]
        return interpolateStops(stops, c)
    }

    static func speedColor(_ kt: Double) -> (Double, Double, Double) {
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.15, 0.25, 0.55)), (10, (0.15, 0.5, 0.75)), (20, (0.2, 0.7, 0.45)), (35, (0.85, 0.8, 0.25)),
            (50, (0.9, 0.45, 0.15)), (70, (0.8, 0.15, 0.25)), (100, (0.6, 0.2, 0.7)),
        ]
        return interpolateStops(stops, kt)
    }

    private static func interpolateStops(_ stops: [(Double, (Double, Double, Double))], _ v: Double) -> (Double, Double, Double) {
        if v <= stops[0].0 { return stops[0].1 }
        for i in 1..<stops.count where v <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let f = (v - a.0) / (b.0 - a.0)
            return (a.1.0 + (b.1.0 - a.1.0) * f, a.1.1 + (b.1.1 - a.1.1) * f, a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return stops.last!.1
    }

    private func makeImage() -> UIImage? {
        let w = 160, h = 160
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let r = boundingMapRect
        for j in 0..<h {
            for i in 0..<w {
                let mp = MKMapPoint(x: r.minX + (Double(i) + 0.5) / Double(w) * r.width, y: r.minY + (Double(j) + 0.5) / Double(h) * r.height)
                let c = mp.coordinate
                guard let s = grid.sample(lat: c.latitude, lon: c.longitude, t: timeIndex) else { continue }
                let col = showSpeed ? Self.speedColor(s.speed) : Self.tempColor(s.temp)
                let a = 0.42
                let k = (j * w + i) * 4
                bytes[k] = UInt8(col.0 * a * 255); bytes[k + 1] = UInt8(col.1 * a * 255); bytes[k + 2] = UInt8(col.2 * a * 255); bytes[k + 3] = UInt8(a * 255)
            }
        }
        return bytes.withUnsafeMutableBytes { ptr -> UIImage? in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
    }
}

final class WindHeatRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let o = overlay as? WindHeatOverlay, let img = o.image else { return }
        let rect = self.rect(for: o.boundingMapRect)
        UIGraphicsPushContext(context)
        context.interpolationQuality = .high
        img.draw(in: rect)
        UIGraphicsPopContext()
    }
}

/// Animated wind particles drawn above the map, advected in screen space so speed looks the same at every zoom.
/// Particles live in MKMapPoint space; projection uses the visible map rect (fast path when north-up).
final class WindParticleView: UIView {
    weak var mapView: MKMapView?
    var grid: WindGrid? { didSet { respawnAll() } }
    var timeIndex = 0
    private var particles: [Particle] = []
    private var link: CADisplayLink?
    private var running = false
    private let trailLength = 8

    private struct Particle {
        var trail: [MKMapPoint]
        var age: Int
        var maxAge: Int
    }

    /// Per-frame projection between map points and view points.
    private struct Projection {
        let rect: MKMapRect
        let scale: Double
        let northUp: Bool
        weak var map: MKMapView?
        weak var view: UIView?
        func point(_ mp: MKMapPoint) -> CGPoint {
            if northUp { return CGPoint(x: (mp.x - rect.minX) * scale, y: (mp.y - rect.minY) * scale) }
            guard let map, let view else { return .zero }
            return map.convert(mp.coordinate, toPointTo: view)
        }
        func mapPoint(_ p: CGPoint) -> MKMapPoint {
            if northUp { return MKMapPoint(x: rect.minX + Double(p.x) / scale, y: rect.minY + Double(p.y) / scale) }
            guard let map, let view else { return MKMapPoint() }
            return MKMapPoint(map.convert(p, toCoordinateFrom: view))
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        running = true
        attachLinkIfNeeded()
    }

    func stop() {
        running = false
        link?.invalidate()
        link = nil
        particles = []
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { link?.invalidate(); link = nil } else { attachLinkIfNeeded() }
    }

    private func attachLinkIfNeeded() {
        guard running, link == nil, window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private var targetCount: Int { UIDevice.current.userInterfaceIdiom == .pad ? 1200 : 700 }

    private func projection() -> Projection? {
        guard let map = mapView, bounds.width > 0 else { return nil }
        let rect = map.visibleMapRect
        return Projection(rect: rect, scale: Double(bounds.width) / rect.width, northUp: abs(map.camera.heading) < 0.5, map: map, view: self)
    }

    private func randomPoint(_ proj: Projection) -> MKMapPoint? {
        guard let g = grid else { return nil }
        for _ in 0..<8 {
            let p = CGPoint(x: CGFloat.random(in: 0...max(1, bounds.width)), y: CGFloat.random(in: 0...max(1, bounds.height)))
            let mp = proj.mapPoint(p)
            let c = mp.coordinate
            if c.latitude > g.minLat && c.latitude < g.maxLat && c.longitude > g.minLon && c.longitude < g.maxLon { return mp }
        }
        return nil
    }

    func respawnAll() {
        particles = []
        guard let proj = projection() else { return }
        for _ in 0..<targetCount {
            if let mp = randomPoint(proj) { particles.append(Particle(trail: [mp], age: Int.random(in: 0..<60), maxAge: Int.random(in: 50...110))) }
        }
    }

    @objc private func step() {
        guard let g = grid, let proj = projection() else { return }
        if particles.count < targetCount / 2 { respawnAll() }
        let pxPerKt: CGFloat = 0.24
        let visible = bounds.insetBy(dx: -20, dy: -20)
        for i in particles.indices {
            var p = particles[i]
            p.age += 1
            let head = p.trail[p.trail.count - 1]
            let c = head.coordinate
            let sp = proj.point(head)
            guard p.age < p.maxAge, visible.contains(sp), let w = g.sample(lat: c.latitude, lon: c.longitude, t: timeIndex) else {
                if let mp = randomPoint(proj) { p = Particle(trail: [mp], age: 0, maxAge: Int.random(in: 50...110)) }
                particles[i] = p
                continue
            }
            let np = CGPoint(x: sp.x + CGFloat(w.u) * pxPerKt, y: sp.y - CGFloat(w.v) * pxPerKt)
            p.trail.append(proj.mapPoint(np))
            if p.trail.count > trailLength { p.trail.removeFirst() }
            particles[i] = p
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !particles.isEmpty, let proj = projection() else { return }
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.6)
        let projected: [[CGPoint]] = particles.map { $0.trail.map { proj.point($0) } }
        for r in 0..<(trailLength - 1) {
            let path = CGMutablePath()
            for pts in projected {
                let n = pts.count
                let s = r - (trailLength - n)
                guard s >= 0, s + 1 < n else { continue }
                path.move(to: pts[s])
                path.addLine(to: pts[s + 1])
            }
            ctx.setStrokeColor(UIColor(white: 1, alpha: 0.1 + 0.8 * CGFloat(r + 1) / CGFloat(trailLength - 1)).cgColor)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }
}
