import Foundation
import CoreLocation

struct Runway: Codable, Hashable, Identifiable {
    var id: String { "\(le)/\(he)" }
    let le: String
    let he: String
    let lengthFt: Int
    let widthFt: Int
    let surface: String
    let lighted: Bool
    let leLat: Double?
    let leLon: Double?
    let heLat: Double?
    let heLon: Double?
    let leHeadingT: Double?
    let heHeadingT: Double?
    let leElevFt: Double?
    let heElevFt: Double?
    let leDisplacedFt: Int?
    let heDisplacedFt: Int?

    var name: String { "\(le)/\(he)" }
    var leCoord: CLLocationCoordinate2D? {
        guard let a = leLat, let b = leLon else { return nil }
        return .init(latitude: a, longitude: b)
    }
    var heCoord: CLLocationCoordinate2D? {
        guard let a = heLat, let b = heLon else { return nil }
        return .init(latitude: a, longitude: b)
    }
    /// True heading of the low end, derived from ends when not given, or from the designator.
    var leTrueHeading: Double? {
        if let h = leHeadingT { return h }
        if let a = leCoord, let b = heCoord { return Geo.bearing(a, b) }
        return nil
    }
    var heTrueHeading: Double? {
        if let h = heHeadingT { return h }
        if let l = leTrueHeading { return Geo.norm360(l + 180) }
        return nil
    }
    var surfaceDescription: String {
        let s = surface.uppercased()
        if s.hasPrefix("ASP") || s.contains("ASPH") { return "Asphalt" }
        if s.hasPrefix("CON") || s.contains("PEM") { return "Concrete" }
        if s.hasPrefix("TURF") || s.hasPrefix("GRS") || s.contains("GRASS") { return "Turf" }
        if s.contains("GRV") || s.contains("GRAVEL") { return "Gravel" }
        if s.contains("DIRT") { return "Dirt" }
        if s.contains("WATER") { return "Water" }
        return surface.capitalized
    }
}

struct Frequency: Codable, Hashable, Identifiable {
    var id: String { "\(type)-\(mhz)-\(desc)" }
    let type: String
    let desc: String
    let mhz: Double
    var formatted: String {
        var s = String(format: "%.3f", mhz)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s
    }
    var label: String {
        switch type.uppercased() {
        case "TWR": return "Tower"
        case "GND": return "Ground"
        case "ATIS": return "ATIS"
        case "AWOS", "ASOS": return type.uppercased()
        case "CTAF": return "CTAF"
        case "UNIC": return "UNICOM"
        case "APP", "A/D", "DEP": return desc.isEmpty ? "Approach/Departure" : desc.capitalized
        case "CLD", "CD": return "Clearance"
        default: return desc.isEmpty ? type : desc.capitalized
        }
    }
}

struct Airport: Codable, Hashable, Identifiable {
    var id: String { ident }
    let ident: String        // OurAirports ident (KCNO, L35, CL35)
    let faa: String          // FAA LID (CNO)
    let icao: String
    let name: String
    let type: String         // small_airport | medium_airport | large_airport | seaplane_base
    let lat: Double
    let lon: Double
    let elevFt: Double
    let city: String
    let region: String       // US-CA
    let country: String
    var runways: [Runway] = []
    var freqs: [Frequency] = []

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
    var displayIdent: String { icao.isEmpty ? ident : icao }
    /// Identifier used by FAA d-TPP (apt_ident) and weather (ICAO if available).
    var weatherIdent: String { icao.isEmpty ? (ident.count == 4 ? ident : "K" + faa) : icao }
    var stateCode: String { region.split(separator: "-").last.map(String.init) ?? region }
    var longestRunwayFt: Int { runways.map(\.lengthFt).max() ?? 0 }
    var isTowered: Bool { freqs.contains { $0.type.uppercased() == "TWR" } }
    /// Heuristic: public-use fields have an ICAO code or a 3-character FAA identifier; private strips use 4-character
    /// local codes containing digits (CA12, 2CA4) or OurAirports placeholders (US-1234).
    var isLikelyPrivate: Bool {
        if !icao.isEmpty { return false }
        if ident.hasPrefix("US-") || ident.contains("-") { return true }
        return faa.count >= 4 && faa.contains(where: { $0.isNumber })
    }
    var rank: Int {
        switch type {
        case "large_airport": return 3
        case "medium_airport": return 2
        case "small_airport": return isLikelyPrivate ? 0 : 1
        default: return isLikelyPrivate ? 0 : 1
        }
    }
    var typeDescription: String {
        switch type {
        case "large_airport": return "Large airport"
        case "medium_airport": return "Medium airport"
        case "seaplane_base": return "Seaplane base"
        default: return "Small airport"
        }
    }
}

struct Navaid: Codable, Hashable, Identifiable {
    var id: String { "\(ident)-\(type)-\(lat)" }
    let ident: String
    let name: String
    let type: String          // VOR, VORTAC, VOR-DME, NDB...
    let freqKHz: Int
    let lat: Double
    let lon: Double
    let elevFt: Double?
    let magVar: Double?       // degrees, + east
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var frequencyText: String {
        if type.contains("NDB") { return "\(freqKHz) kHz" }
        return String(format: "%.2f", Double(freqKHz) / 1000)
    }
}

enum WaypointKind: String, Codable { case airport, navaid, fix, user }

struct Waypoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var ident: String
    var name: String
    var kind: WaypointKind
    var lat: Double
    var lon: Double
    var elevationFt: Double?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init(ident: String, name: String, kind: WaypointKind, lat: Double, lon: Double, elevationFt: Double? = nil) {
        self.ident = ident; self.name = name; self.kind = kind; self.lat = lat; self.lon = lon; self.elevationFt = elevationFt
    }
    init(airport a: Airport) {
        self.init(ident: a.displayIdent, name: a.name, kind: .airport, lat: a.lat, lon: a.lon, elevationFt: a.elevFt)
    }
    init(navaid n: Navaid) {
        self.init(ident: n.ident, name: "\(n.name) \(n.type) \(n.frequencyText)", kind: .navaid, lat: n.lat, lon: n.lon, elevationFt: n.elevFt)
    }
    init(user c: CLLocationCoordinate2D) {
        let id = String(format: "%.2f/%.2f", c.latitude, c.longitude)
        self.init(ident: id, name: "User waypoint", kind: .user, lat: c.latitude, lon: c.longitude)
    }
}

struct FlightPlan: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String = ""
    var waypoints: [Waypoint] = []
    var cruiseAltitudeFt: Int = 5500
    var departureTime: Date = Date().addingTimeInterval(3600)
    var aircraftID: UUID?
    var notes: String = ""
    var created = Date()

    var routeString: String { waypoints.map(\.ident).joined(separator: " ") }
    var departure: Waypoint? { waypoints.first }
    var destination: Waypoint? { waypoints.count > 1 ? waypoints.last : nil }
    var title: String {
        if !name.isEmpty { return name }
        if let d = departure, let a = destination { return "\(d.ident) → \(a.ident)" }
        return departure?.ident ?? "New Flight"
    }
    var totalDistanceNM: Double {
        guard waypoints.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<waypoints.count { d += Geo.distanceNM(waypoints[i - 1].coordinate, waypoints[i].coordinate) }
        return d
    }
}

/// Aircraft performance profile. Defaults are a Cessna 172N (from the student's kneeboard card / POH-like figures).
struct AircraftProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var tailNumber = "N734XX"
    var icaoType = "C172"
    var model = "Cessna 172N Skyhawk"
    var equipment = "S"          // ICAO item 10a
    var surveillance = "C"       // item 10b (Mode C)
    var color = "WHITE/BLUE"
    var homeBase = "KCNO"

    var usableFuelGal = 40.0
    var taxiFuelGal = 1.1
    var reserveMinutes = 30.0

    // Climb
    var climbIAS = 73.0          // Vy
    var climbRateSL = 770.0      // fpm at sea level, max gross
    var serviceCeilingFt = 14200.0
    var climbGPH = 9.0

    // Cruise at 5,000 ft (TAS kt / GPH) for 55/65/75 % power
    var cruisePowerPct = 65.0
    var tas55 = 99.0, tas65 = 107.0, tas75 = 114.0
    var gph55 = 6.3, gph65 = 7.3, gph75 = 8.4
    var tasGainPer1000 = 0.7     // kt TAS gained per 1,000 ft at constant power

    // Descent
    var descentRate = 500.0
    var descentTAS = 110.0
    var descentGPH = 6.0

    // Misc
    var bestGlideKIAS = 65.0
    var glideRatio = 9.0
    var maxCrosswindKt = 15.0
    var vr = 55.0, vx = 59.0, vy = 73.0, vso = 41.0, vs1 = 47.0, va = 97.0, vno = 127.0, vne = 158.0, vfe = 85.0

    var title: String { "\(tailNumber) · \(model)" }

    static let c172n = AircraftProfile()
}

extension AircraftProfile {
    /// Fraction of rated power available at a density altitude (Gagg-Ferrar).
    func maxPowerFraction(densityAltitudeFt h: Double) -> Double {
        let s = Atmosphere.sigma(densityAltitudeFt: h)
        return max(0.2, min(1, (s - 0.12) / 0.88))
    }

    private func interp(_ p: Double, _ v55: Double, _ v65: Double, _ v75: Double) -> Double {
        if p <= 65 { return v55 + (v65 - v55) * (p - 55) / 10 }
        return v65 + (v75 - v65) * (p - 65) / 10
    }

    func cruisePower(densityAltitudeFt h: Double) -> Double {
        min(cruisePowerPct, maxPowerFraction(densityAltitudeFt: h) * 100)
    }

    func cruiseTAS(densityAltitudeFt h: Double) -> Double {
        let p = cruisePower(densityAltitudeFt: h)
        return max(60, interp(p, tas55, tas65, tas75) + tasGainPer1000 * (h - 5000) / 1000)
    }

    func cruiseGPH(densityAltitudeFt h: Double) -> Double {
        max(3, interp(cruisePower(densityAltitudeFt: h), gph55, gph65, gph75))
    }

    var absoluteCeilingFt: Double {
        serviceCeilingFt / max(0.05, 1 - 100 / max(climbRateSL, 150))
    }

    func climbRate(densityAltitudeFt h: Double) -> Double {
        max(0, climbRateSL * (1 - h / absoluteCeilingFt))
    }

    func climbTAS(densityAltitudeFt h: Double) -> Double {
        Atmosphere.tasFromIAS(climbIAS, densityAltitudeFt: h)
    }

    /// Glide distance (nm) from a height above ground (ft), no wind.
    func glideRangeNM(heightAGLFt: Double) -> Double {
        max(0, heightAGLFt) * glideRatio / 6076.12
    }
}

struct LogEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var date = Date()
    var aircraftType = "C172N"
    var tailNumber = ""
    var from = ""
    var to = ""
    var route = ""
    var totalTime = 0.0
    var pic = 0.0
    var dualReceived = 0.0
    var solo = 0.0
    var crossCountry = 0.0
    var soloCrossCountry = 0.0
    var night = 0.0
    var actualInstrument = 0.0
    var simulatedInstrument = 0.0
    var dayLandings = 0
    var nightLandings = 0
    var towerLandings = 0
    var approaches = 0
    var instructor = ""
    var remarks = ""
    var track: [TrackPoint]? = nil
}

struct TrackPoint: Codable, Hashable {
    var t: Date
    var lat: Double
    var lon: Double
    var altFt: Double
    var gsKt: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
