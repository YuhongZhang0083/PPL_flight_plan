import Foundation
import CoreLocation
import MapKit

/// Great-circle navigation math. Distances in nautical miles, angles in degrees.
enum Geo {
    static let earthRadiusNM = 3440.065
    static let metersPerNM = 1852.0
    static let feetPerMeter = 3.28084

    static func rad(_ d: Double) -> Double { d * .pi / 180 }
    static func deg(_ r: Double) -> Double { r * 180 / .pi }

    static func norm360(_ x: Double) -> Double {
        var v = x.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    /// Signed difference b - a in -180...180
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = rad(a.latitude), p2 = rad(b.latitude)
        let dp = p2 - p1, dl = rad(b.longitude - a.longitude)
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusNM * asin(min(1, sqrt(h)))
    }

    /// Initial true course from a to b.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = rad(a.latitude), p2 = rad(b.latitude), dl = rad(b.longitude - a.longitude)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return norm360(deg(atan2(y, x)))
    }

    static func destination(_ a: CLLocationCoordinate2D, bearing: Double, distanceNM: Double) -> CLLocationCoordinate2D {
        let d = distanceNM / earthRadiusNM
        let b = rad(bearing)
        let p1 = rad(a.latitude), l1 = rad(a.longitude)
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
        let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        var lon = deg(l2)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return CLLocationCoordinate2D(latitude: deg(p2), longitude: lon)
    }

    /// Point at fraction f (0...1) along the great circle from a to b.
    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ f: Double) -> CLLocationCoordinate2D {
        let d = distanceNM(a, b)
        if d < 0.001 { return a }
        return destination(a, bearing: bearing(a, b), distanceNM: d * f)
    }

    /// Cross-track distance (nm, + right of course) of p from great circle a->b.
    static func crossTrackNM(_ p: CLLocationCoordinate2D, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let d13 = distanceNM(a, p) / earthRadiusNM
        let t13 = rad(bearing(a, p)), t12 = rad(bearing(a, b))
        return asin(sin(d13) * sin(t13 - t12)) * earthRadiusNM
    }

    /// Along-track distance (nm) of p projected onto a->b.
    static func alongTrackNM(_ p: CLLocationCoordinate2D, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let d13 = distanceNM(a, p) / earthRadiusNM
        let xt = crossTrackNM(p, from: a, to: b) / earthRadiusNM
        let v = cos(d13) / max(cos(xt), 1e-9)
        let at = acos(max(-1, min(1, v))) * earthRadiusNM
        let ang = abs(angleDiff(bearing(a, b), bearing(a, p)))
        return ang > 90 ? -at : at
    }

    /// Densify a route into points no further apart than `stepNM`.
    static func densify(_ coords: [CLLocationCoordinate2D], stepNM: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 1 else { return coords }
        var out: [CLLocationCoordinate2D] = [coords[0]]
        for i in 1..<coords.count {
            let a = coords[i - 1], b = coords[i]
            let d = distanceNM(a, b)
            let n = max(1, Int(ceil(d / stepNM)))
            for k in 1...n { out.append(interpolate(a, b, Double(k) / Double(n))) }
        }
        return out
    }

    /// Parse "33-58-29.2055N" or "33 56 04.15N" style DMS strings.
    static func parseDMS(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let hemi = trimmed.last, "NSEW".contains(hemi) else { return nil }
        let body = trimmed.dropLast()
        let parts = body.split(whereSeparator: { $0 == "-" || $0 == " " }).compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var v = parts[0]
        if parts.count > 1 { v += parts[1] / 60 }
        if parts.count > 2 { v += parts[2] / 3600 }
        return (hemi == "S" || hemi == "W") ? -v : v
    }

    static func formatLatLon(_ c: CLLocationCoordinate2D) -> String {
        func f(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v)
            let d = Int(a)
            let m = (a - Double(d)) * 60
            return String(format: "%d°%05.2f'%@", d, m, v >= 0 ? pos : neg)
        }
        return "\(f(c.latitude, "N", "S")) \(f(c.longitude, "E", "W"))"
    }

    static func region(around coords: [CLLocationCoordinate2D], paddingFactor: Double = 1.3) -> MKCoordinateRegion? {
        guard let first = coords.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.05, (maxLat - minLat) * paddingFactor),
                                    longitudeDelta: max(0.05, (maxLon - minLon) * paddingFactor))
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// Web-Mercator slippy tile math.
enum TileMath {
    static func tileXY(lat: Double, lon: Double, z: Int) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(z))
        let x = (lon + 180) / 360 * n
        let latR = Geo.rad(max(-85.05112878, min(85.05112878, lat)))
        let y = (1 - log(tan(latR) + 1 / cos(latR)) / .pi) / 2 * n
        return (x, y)
    }

    static func coordinate(x: Double, y: Double, z: Int) -> CLLocationCoordinate2D {
        let n = pow(2.0, Double(z))
        let lon = x / n * 360 - 180
        let latR = atan(sinh(.pi * (1 - 2 * y / n)))
        return CLLocationCoordinate2D(latitude: Geo.deg(latR), longitude: lon)
    }
}

extension CLLocationCoordinate2D {
    var isValidCoordinate: Bool { CLLocationCoordinate2DIsValid(self) && !(latitude == 0 && longitude == 0) }
}

/// Simple atmospheric helpers.
enum Atmosphere {
    /// Density ratio sigma at a density altitude in feet (ISA troposphere).
    static func sigma(densityAltitudeFt h: Double) -> Double {
        pow(max(0.05, 1 - 6.8756e-6 * h), 4.2559)
    }
    static func isaTempC(altitudeFt h: Double) -> Double { 15 - 1.98 * h / 1000 }
    static func pressureAltitude(fieldElevationFt: Double, altimeterInHg: Double) -> Double {
        fieldElevationFt + (29.92 - altimeterInHg) * 1000
    }
    static func densityAltitude(pressureAltitudeFt pa: Double, oatC: Double) -> Double {
        pa + 120 * (oatC - isaTempC(altitudeFt: pa))
    }
    static func tasFromIAS(_ ias: Double, densityAltitudeFt: Double) -> Double {
        ias / sqrt(sigma(densityAltitudeFt: densityAltitudeFt))
    }
}

/// Wind triangle solution.
struct WindSolution {
    let wca: Double       // degrees, + = correct right
    let trueHeading: Double
    let groundSpeed: Double
    let headwind: Double  // + headwind, - tailwind
    let crosswind: Double // + from right

    init(trueCourse tc: Double, tas: Double, windFrom wd: Double, windSpeed ws: Double) {
        let rel = Geo.rad(wd - tc)
        let cross = ws * sin(rel)
        let ratio = tas > 1 ? max(-1, min(1, cross / tas)) : 0
        let wcaR = asin(ratio)
        wca = Geo.deg(wcaR)
        trueHeading = Geo.norm360(tc + wca)
        groundSpeed = max(1, tas * cos(wcaR) - ws * cos(rel))
        headwind = ws * cos(rel)
        crosswind = cross
    }
}
