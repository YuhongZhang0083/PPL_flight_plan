import Foundation
import PDFKit
import CoreLocation

/// Geo-reference for an FAA airport diagram, derived from its printed latitude/longitude graticule labels.
/// FAA diagrams are drawn with straight, axis-aligned graticule lines; each label is centered on its line.
struct PlateGeoref {
    let latOnX: Bool          // true: latitude varies along page x (diagram rotated); false: along page y
    let latA: Double, latB: Double   // lat = latA + latB * u
    let lonA: Double, lonB: Double   // lon = lonA + lonB * v

    func pagePoint(_ c: CLLocationCoordinate2D) -> CGPoint {
        let u = (c.latitude - latA) / latB
        let v = (c.longitude - lonA) / lonB
        return latOnX ? CGPoint(x: u, y: v) : CGPoint(x: v, y: u)
    }

    func coordinate(_ p: CGPoint) -> CLLocationCoordinate2D {
        let u = Double(latOnX ? p.x : p.y), v = Double(latOnX ? p.y : p.x)
        return CLLocationCoordinate2D(latitude: latA + latB * u, longitude: lonA + lonB * v)
    }

    /// Angle (radians, page space, y up) of a true bearing.
    func pageAngle(forTrueBearing brg: Double, at c: CLLocationCoordinate2D) -> CGFloat {
        let a = pagePoint(c)
        let b = pagePoint(Geo.destination(c, bearing: brg, distanceNM: 0.05))
        return CGFloat(atan2(b.y - a.y, b.x - a.x))
    }

    /// Detect from text labels like 33°58'N / 117°38.5'W.
    static func detect(page: PDFPage) -> PlateGeoref? {
        guard let text = page.string else { return nil }
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "(\\d{2,3})\\s?°\\s?(\\d{1,2}(?:\\.\\d+)?)\\s?['’′]\\s?([NSEW])") else { return nil }
        var lats: [(CGPoint, Double)] = [], lons: [(CGPoint, Double)] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let deg = Double(ns.substring(with: m.range(at: 1))), let min = Double(ns.substring(with: m.range(at: 2))) else { continue }
            let hemi = ns.substring(with: m.range(at: 3))
            var value = deg + min / 60
            if hemi == "S" || hemi == "W" { value = -value }
            guard let sel = page.selection(for: m.range) else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            let center = CGPoint(x: b.midX, y: b.midY)
            if hemi == "N" || hemi == "S" { lats.append((center, value)) } else { lons.append((center, value)) }
        }
        guard Set(lats.map(\.1)).count >= 2, Set(lons.map(\.1)).count >= 2 else { return nil }

        func fit(_ pts: [(CGPoint, Double)], useX: Bool) -> (a: Double, b: Double, rms: Double)? {
            let xs = pts.map { Double(useX ? $0.0.x : $0.0.y) }, ys = pts.map(\.1)
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for i in xs.indices { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
            guard sxx > 1 else { return nil }
            let b = sxy / sxx, a = my - b * mx
            var se = 0.0
            for i in xs.indices { let r = ys[i] - (a + b * xs[i]); se += r * r }
            return (a, b, sqrt(se / n))
        }

        let meanLat = lats.map(\.1).reduce(0, +) / Double(lats.count)
        var best: (PlateGeoref, Double)?
        for latOnX in [true, false] {
            guard let lf = fit(lats, useX: latOnX), let gf = fit(lons, useX: !latOnX), lf.b != 0, gf.b != 0 else { continue }
            // Both axes must give the same ground scale (nm per point).
            let latScale = abs(lf.b) * 60
            let lonScale = abs(gf.b) * 60 * cos(Geo.rad(meanLat))
            let mismatch = abs(log(latScale / lonScale))
            let resid = (lf.rms / abs(lf.b) + gf.rms / abs(gf.b))   // residual in points
            let score = mismatch * 10 + resid / 20
            if mismatch < 0.15 && resid < 30 && (best == nil || score < best!.1) {
                best = (PlateGeoref(latOnX: latOnX, latA: lf.a, latB: lf.b, lonA: gf.a, lonB: gf.b), score)
            }
        }
        return best?.0
    }
}

/// Ownship symbol drawn in PDF page space so it zooms and scrolls with the plate.
final class OwnshipPDFAnnotation: PDFAnnotation {
    var angle: CGFloat = .pi / 2   // page-space direction of travel

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: angle - .pi / 2)
        let s = min(bounds.width, bounds.height) / 520
        let pts: [(CGFloat, CGFloat)] = [(0, 250), (28, 210), (34, 70), (250, -10), (250, -52), (34, -20), (24, -170), (95, -215), (95, -245), (0, -225),
                                         (-95, -245), (-95, -215), (-24, -170), (-34, -20), (-250, -52), (-250, -10), (-34, 70), (-28, 210)]
        context.beginPath()
        for (i, p) in pts.enumerated() {
            let q = CGPoint(x: p.0 * s, y: p.1 * s)
            if i == 0 { context.move(to: q) } else { context.addLine(to: q) }
        }
        context.closePath()
        context.setFillColor(UIColor(red: 0.1, green: 0.75, blue: 1, alpha: 1).cgColor)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(max(0.6, 12 * s))
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
}
