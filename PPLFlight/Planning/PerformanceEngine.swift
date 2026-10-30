import Foundation
import CoreLocation

/// Resolves route text like "KCNO PDZ KRAL" or "KCNO 33.95/-117.30 L35".
enum RouteParser {
    struct Result { var waypoints: [Waypoint]; var unresolved: [String] }

    @MainActor
    static func parse(_ text: String, index: AirportIndex?) async -> Result {
        let tokens = text.uppercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { $0 != "DCT" && $0 != "->" }
        var wps: [Waypoint] = []
        var bad: [String] = []
        for t in tokens {
            if let w = await resolve(t, index: index, near: wps.last?.coordinate) { wps.append(w) } else { bad.append(t) }
        }
        return Result(waypoints: wps, unresolved: bad)
    }

    @MainActor
    static func resolve(_ t: String, index: AirportIndex?, near: CLLocationCoordinate2D?) async -> Waypoint? {
        // Lat/lon "33.95/-117.30"
        if t.contains("/") {
            let parts = t.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 {
                return Waypoint(user: .init(latitude: parts[0], longitude: parts[1]))
            }
        }
        guard let idx = index else { return nil }
        // Exact OurAirports ident (e.g. L35, KCNO) first
        if let a = idx.airport(t), a.ident.uppercased() == t || a.icao.uppercased() == t { return Waypoint(airport: a) }
        // Navaid (closest one with that ident)
        let navs = idx.navaids(t)
        if !navs.isEmpty {
            let n = near.map { c in navs.min { Geo.distanceNM(c, $0.coordinate) < Geo.distanceNM(c, $1.coordinate) }! } ?? navs[0]
            return Waypoint(navaid: n)
        }
        if let a = idx.airport(t) { return Waypoint(airport: a) }
        if t.count == 5, t.allSatisfy({ $0.isLetter }) { return await FixService.lookup(t) }
        return nil
    }
}

/// One leg in the navigation log.
struct LegCalc: Identifiable {
    let id = UUID()
    let from: Waypoint
    let to: Waypoint
    let distanceNM: Double
    let trueCourse: Double
    let magVar: Double
    var magCourse: Double { Geo.norm360(trueCourse - magVar) }
    let windDir: Double
    let windSpeed: Double
    let tempC: Double?
    let tas: Double
    let wca: Double
    var trueHeading: Double { Geo.norm360(trueCourse + wca) }
    var magHeading: Double { Geo.norm360(trueHeading - magVar) }
    let groundSpeed: Double
    let timeSec: Double
    let fuelGal: Double
    let phase: String
}

struct FlightCalc {
    var legs: [LegCalc] = []
    var cruiseAltitudeFt: Double = 0
    var totalDistanceNM: Double = 0
    var totalTimeSec: Double = 0
    var tripFuelGal: Double = 0
    var taxiFuelGal: Double = 0
    var reserveFuelGal: Double = 0
    var climbTimeSec: Double = 0
    var climbDistanceNM: Double = 0
    var descentDistanceNM: Double = 0
    var averageWindComponent: Double = 0   // + tailwind
    var cruiseTAS: Double = 0
    var climbLimited = false
    var totalFuelRequired: Double { tripFuelGal + taxiFuelGal + reserveFuelGal }
    var averageGS: Double { totalTimeSec > 0 ? totalDistanceNM / (totalTimeSec / 3600) : 0 }
}

/// Wind lookup closure: (position, altitude ft) -> (dir from, speed kt, temp °C)
typealias WindLookup = (CLLocationCoordinate2D, Double) -> (dir: Double, speed: Double, tempC: Double)?

enum PerformanceEngine {
    /// Climb profile from `fromFt` to `toFt`. Returns (time s, distance nm at TAS, fuel gal).
    static func climb(from fromFt: Double, to toFt: Double, aircraft ac: AircraftProfile, tempDev: Double = 0) -> (time: Double, dist: Double, fuel: Double, limited: Bool) {
        guard toFt > fromFt else { return (0, 0, 0, false) }
        var h = fromFt, t = 0.0, d = 0.0
        let step = 250.0
        var limited = false
        while h < toFt {
            let da = h + 120 * tempDev
            let roc = ac.climbRate(densityAltitudeFt: da)
            if roc < 80 { limited = true; break }
            let dh = min(step, toFt - h)
            let dtMin = dh / roc
            t += dtMin * 60
            d += ac.climbTAS(densityAltitudeFt: da) * dtMin / 60
            h += dh
        }
        return (t, d, ac.climbGPH * t / 3600, limited)
    }

    static func calculate(waypoints wps: [Waypoint], cruiseAltitudeFt: Double, aircraft ac: AircraftProfile,
                          wind: WindLookup?, magVar: (CLLocationCoordinate2D) -> Double) -> FlightCalc {
        var calc = FlightCalc()
        calc.cruiseAltitudeFt = cruiseAltitudeFt
        guard wps.count >= 2 else { return calc }
        let depElev = wps.first?.elevationFt ?? 0
        let destElev = wps.last?.elevationFt ?? 0
        let patternAlt = destElev + 1000

        // Leg geometry
        var legLen: [Double] = [], cum: [Double] = [0]
        for i in 1..<wps.count {
            let d = Geo.distanceNM(wps[i - 1].coordinate, wps[i].coordinate)
            legLen.append(d)
            cum.append(cum.last! + d)
        }
        let total = cum.last!
        calc.totalDistanceNM = total

        // Temperature deviation near departure at cruise level (affects density altitude)
        let midTemp = wind?(wps[0].coordinate, cruiseAltitudeFt)?.tempC
        let tempDev = midTemp.map { $0 - Atmosphere.isaTempC(altitudeFt: cruiseAltitudeFt) } ?? 0
        let cruiseDA = cruiseAltitudeFt + 120 * tempDev

        let cl = climb(from: depElev, to: cruiseAltitudeFt, aircraft: ac, tempDev: tempDev)
        calc.climbLimited = cl.limited
        let descentTime = max(0, cruiseAltitudeFt - patternAlt) / ac.descentRate * 60
        let descentDist = ac.descentTAS * descentTime / 3600
        var climbDist = cl.dist, descDist = descentDist
        if climbDist + descDist > total {
            let k = total / max(0.01, climbDist + descDist)
            climbDist *= k; descDist *= k
        }
        calc.climbDistanceNM = climbDist
        calc.descentDistanceNM = descDist
        calc.climbTimeSec = cl.time
        let cruiseTAS = ac.cruiseTAS(densityAltitudeFt: cruiseDA)
        let cruiseGPH = ac.cruiseGPH(densityAltitudeFt: cruiseDA)
        calc.cruiseTAS = cruiseTAS
        let climbTASavg = climbDist > 0 && cl.time > 0 ? cl.dist / (cl.time / 3600) : ac.climbTAS(densityAltitudeFt: (depElev + cruiseAltitudeFt) / 2)

        var windWeighted = 0.0
        for i in 0..<legLen.count {
            let a = wps[i], b = wps[i + 1]
            let tc = Geo.bearing(a.coordinate, b.coordinate)
            let mid = Geo.interpolate(a.coordinate, b.coordinate, 0.5)
            let mv = magVar(mid)
            let s0 = cum[i], s1 = cum[i + 1]
            // Phase overlaps
            let climbPart = max(0, min(s1, climbDist) - s0)
            let descStart = total - descDist
            let descPart = max(0, s1 - max(s0, descStart))
            let cruisePart = max(0, legLen[i] - climbPart - descPart)

            func solve(_ tas: Double, _ altFt: Double) -> (WindSolution, Double, Double, Double?) {
                let w = wind?(mid, altFt)
                let sol = WindSolution(trueCourse: tc, tas: tas, windFrom: w?.dir ?? 0, windSpeed: w?.speed ?? 0)
                return (sol, w?.dir ?? 0, w?.speed ?? 0, w?.tempC)
            }
            let cr = solve(cruiseTAS, cruiseAltitudeFt)
            let clS = solve(climbTASavg, (depElev + cruiseAltitudeFt) / 2)
            let deS = solve(ac.descentTAS, (cruiseAltitudeFt + patternAlt) / 2)
            var time = 0.0, fuel = 0.0
            if climbPart > 0 { let tt = climbPart / clS.0.groundSpeed * 3600; time += tt; fuel += ac.climbGPH * tt / 3600 }
            if cruisePart > 0 { let tt = cruisePart / cr.0.groundSpeed * 3600; time += tt; fuel += cruiseGPH * tt / 3600 }
            if descPart > 0 { let tt = descPart / deS.0.groundSpeed * 3600; time += tt; fuel += ac.descentGPH * tt / 3600 }
            var phases: [String] = []
            if climbPart > 0.05 { phases.append("CLB") }
            if cruisePart > 0.05 { phases.append("CRZ") }
            if descPart > 0.05 { phases.append("DES") }
            let gs = time > 0 ? legLen[i] / (time / 3600) : cr.0.groundSpeed
            windWeighted += -cr.0.headwind * legLen[i]
            calc.legs.append(LegCalc(from: a, to: b, distanceNM: legLen[i], trueCourse: tc, magVar: mv,
                                     windDir: cr.1, windSpeed: cr.2, tempC: cr.3, tas: cruiseTAS, wca: cr.0.wca,
                                     groundSpeed: gs, timeSec: time, fuelGal: fuel, phase: phases.joined(separator: "/")))
            calc.totalTimeSec += time
            calc.tripFuelGal += fuel
        }
        calc.averageWindComponent = total > 0 ? windWeighted / total : 0
        calc.taxiFuelGal = ac.taxiFuelGal
        calc.reserveFuelGal = cruiseGPH * ac.reserveMinutes / 60
        return calc
    }

    /// VFR cruising altitude rule (14 CFR 91.159): MC 0-179 odd thousands + 500, 180-359 even thousands + 500.
    static func isVFRCruisingAltitude(_ alt: Int, magneticCourse mc: Double) -> Bool {
        guard alt % 1000 == 500 else { return false }
        let thousands = alt / 1000
        return Geo.norm360(mc) < 180 ? thousands % 2 == 1 : thousands % 2 == 0
    }

    static func suggestedVFRAltitudes(magneticCourse mc: Double, minimum: Double) -> [Int] {
        stride(from: 3500, through: 17500, by: 1000).filter { isVFRCruisingAltitude($0, magneticCourse: mc) && Double($0) >= minimum }
    }
}
