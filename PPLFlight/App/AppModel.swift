import Foundation
import SwiftUI
import MapKit
import Observation

enum AppTab: String, Hashable, CaseIterable {
    case maps, flights, airports, plates, weather, logbook, more
}

enum BaseMap: String, Codable, CaseIterable, Identifiable {
    case standard, muted, satellite, hybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Street"
        case .muted: return "Muted"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var homeBase = "KCNO"
    var chartLayer: ChartLayer = .sectional
    var baseMap: BaseMap = .muted
    var showRadar = false
    var showHazard = false
    var showObstacles = false
    var showWinds = false
    var showAirports = true
    var showRangeRings = true
    var showGlideRing = true
    var trackVectorMinutes = 2
    var trackUp = false
    var hazardAltitudeFt = 5500.0
    var windsLevel = 850
    var windsShowSpeed = false
    var favorites: [String] = []
    var recentAirports: [String] = []
    var autoRecordTrack = true
    var seededDemo = false
    var activeAircraftID: UUID?
    var activePlanID: UUID?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        homeBase = (try? c.decodeIfPresent(type(of: d.homeBase), forKey: .homeBase)) ?? d.homeBase
        chartLayer = (try? c.decodeIfPresent(type(of: d.chartLayer), forKey: .chartLayer)) ?? d.chartLayer
        baseMap = (try? c.decodeIfPresent(type(of: d.baseMap), forKey: .baseMap)) ?? d.baseMap
        showRadar = (try? c.decodeIfPresent(type(of: d.showRadar), forKey: .showRadar)) ?? d.showRadar
        showHazard = (try? c.decodeIfPresent(type(of: d.showHazard), forKey: .showHazard)) ?? d.showHazard
        showObstacles = (try? c.decodeIfPresent(type(of: d.showObstacles), forKey: .showObstacles)) ?? d.showObstacles
        showWinds = (try? c.decodeIfPresent(type(of: d.showWinds), forKey: .showWinds)) ?? d.showWinds
        showAirports = (try? c.decodeIfPresent(type(of: d.showAirports), forKey: .showAirports)) ?? d.showAirports
        showRangeRings = (try? c.decodeIfPresent(type(of: d.showRangeRings), forKey: .showRangeRings)) ?? d.showRangeRings
        showGlideRing = (try? c.decodeIfPresent(type(of: d.showGlideRing), forKey: .showGlideRing)) ?? d.showGlideRing
        trackVectorMinutes = (try? c.decodeIfPresent(type(of: d.trackVectorMinutes), forKey: .trackVectorMinutes)) ?? d.trackVectorMinutes
        trackUp = (try? c.decodeIfPresent(type(of: d.trackUp), forKey: .trackUp)) ?? d.trackUp
        hazardAltitudeFt = (try? c.decodeIfPresent(type(of: d.hazardAltitudeFt), forKey: .hazardAltitudeFt)) ?? d.hazardAltitudeFt
        windsLevel = (try? c.decodeIfPresent(type(of: d.windsLevel), forKey: .windsLevel)) ?? d.windsLevel
        windsShowSpeed = (try? c.decodeIfPresent(type(of: d.windsShowSpeed), forKey: .windsShowSpeed)) ?? d.windsShowSpeed
        favorites = (try? c.decodeIfPresent(type(of: d.favorites), forKey: .favorites)) ?? d.favorites
        recentAirports = (try? c.decodeIfPresent(type(of: d.recentAirports), forKey: .recentAirports)) ?? d.recentAirports
        autoRecordTrack = (try? c.decodeIfPresent(type(of: d.autoRecordTrack), forKey: .autoRecordTrack)) ?? d.autoRecordTrack
        seededDemo = (try? c.decodeIfPresent(type(of: d.seededDemo), forKey: .seededDemo)) ?? d.seededDemo
        activeAircraftID = try? c.decodeIfPresent(UUID.self, forKey: .activeAircraftID)
        activePlanID = try? c.decodeIfPresent(UUID.self, forKey: .activePlanID)
    }
}

struct MapFocus: Equatable {
    let id = UUID()
    let center: CLLocationCoordinate2D
    let spanDegrees: Double
    static func == (a: MapFocus, b: MapFocus) -> Bool { a.id == b.id }
}

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings { didSet { if settings != oldValue { JSONStore.save(settings, "settings") } } }
    var plans: [FlightPlan] { didSet { JSONStore.save(plans, "plans") } }
    var aircraft: [AircraftProfile] { didSet { JSONStore.save(aircraft, "aircraft") } }
    var logbook: [LogEntry] { didSet { JSONStore.save(logbook, "logbook") } }

    let db = AirportDatabase()
    let weather = WeatherService()
    let plates = PlatesService()
    let flight = FlightState()
    let simulator = FlightSimulator()
    let recorder = TrackRecorder()
    @ObservationIgnored let location = LocationProvider()

    // UI coordination
    var selectedTab: AppTab = .maps
    var mapSelectedAirport: Airport?
    var mapFocus: MapFocus?
    var showSyntheticVision = false
    var showProfile = false
    var windGrid: WindGrid?
    var windTimeIndex = 0
    var routeWinds: [WindProfile] = []
    var routeWindsPlanKey = ""
    var pendingLogEntry: LogEntry?
    var startedUp = false

    init() {
        settings = JSONStore.load(AppSettings.self, "settings") ?? AppSettings()
        plans = JSONStore.load([FlightPlan].self, "plans") ?? []
        var ac = JSONStore.load([AircraftProfile].self, "aircraft") ?? []
        if ac.isEmpty {
            ac = [AircraftProfile.c172n]
            JSONStore.save(ac, "aircraft")
        }
        aircraft = ac
        logbook = JSONStore.load([LogEntry].self, "logbook") ?? []
        location.flight = flight
    }

    // MARK: - Startup

    func startup() async {
        guard !startedUp else { return }
        startedUp = true
        location.start()
        location.onUpdate = { [weak self] _ in self?.onPositionUpdate() }
        await db.loadFromDisk()
        if !db.isReady { await db.download() }
        if activePlan == nil, let home = homeAirport {
            var p = FlightPlan(name: "\(home.displayIdent) local")
            p.waypoints = [Waypoint(airport: home)]
            p.aircraftID = activeAircraft.id
            plans.append(p)
            settings.activePlanID = p.id
        }
        if !settings.seededDemo, db.isReady, settings.homeBase.uppercased() == "KCNO" {
            settings.seededDemo = true
            let r = await RouteParser.parse("KCNO PDZ BNG KPSP", index: db.index)
            if r.waypoints.count >= 3 {
                var p = FlightPlan(name: "Demo XC · Banning Pass")
                p.waypoints = r.waypoints
                p.cruiseAltitudeFt = 7500
                p.aircraftID = activeAircraft.id
                plans.append(p)
            }
        }
        if mapFocus == nil, let home = homeAirport {
            mapFocus = MapFocus(center: home.coordinate, spanDegrees: 1.2)
        }
        if !plates.isReady { Task { await plates.refreshIndex() } }
        else { Task { await plates.refreshIndex() } }
    }

    // MARK: - Position-driven housekeeping

    private var wasAirborne = false

    func onPositionUpdate() {
        recorder.sample(flight)
        if settings.autoRecordTrack {
            if flight.isAirborne && !recorder.isRecording && !wasAirborne { recorder.start() }
        }
        if wasAirborne && !flight.isAirborne && flight.groundSpeedKt < 5 && recorder.isRecording && recorder.elapsed > 300 {
            finishRecording()
        }
        wasAirborne = flight.isAirborne
    }

    func finishRecording() {
        let pts = recorder.stop()
        guard let first = pts.first, let last = pts.last else { return }
        var e = LogEntry()
        e.date = first.t
        e.aircraftType = activeAircraft.icaoType == "C172" ? "C172N" : activeAircraft.icaoType
        e.tailNumber = activeAircraft.tailNumber
        e.from = db.index?.nearestAirports(to: first.coordinate, count: 1, maxNM: 5).first?.airport.displayIdent ?? ""
        e.to = db.index?.nearestAirports(to: last.coordinate, count: 1, maxNM: 5).first?.airport.displayIdent ?? ""
        let hours = (last.t.timeIntervalSince(first.t) / 360).rounded() / 10
        e.totalTime = hours
        e.dayLandings = 1
        e.track = pts
        pendingLogEntry = e
    }

    // MARK: - Lookups

    func airport(_ ident: String) -> Airport? { db.index?.airport(ident) }
    var homeAirport: Airport? { airport(settings.homeBase) }

    func magVar(at c: CLLocationCoordinate2D) -> Double {
        db.index?.magneticVariation(at: c) ?? AirportIndex.fallbackVariation(c)
    }

    var activeAircraft: AircraftProfile {
        get { aircraft.first { $0.id == settings.activeAircraftID } ?? aircraft.first ?? .c172n }
        set {
            if let i = aircraft.firstIndex(where: { $0.id == newValue.id }) { aircraft[i] = newValue } else { aircraft.append(newValue) }
            settings.activeAircraftID = newValue.id
        }
    }

    func aircraftFor(_ plan: FlightPlan) -> AircraftProfile {
        aircraft.first { $0.id == plan.aircraftID } ?? activeAircraft
    }

    // MARK: - Plans / route

    var activePlan: FlightPlan? {
        get { plans.first { $0.id == settings.activePlanID } }
        set {
            guard let p = newValue else { settings.activePlanID = nil; return }
            upsert(p)
            settings.activePlanID = p.id
        }
    }

    func upsert(_ plan: FlightPlan) {
        if let i = plans.firstIndex(where: { $0.id == plan.id }) {
            if plans[i] != plan { plans[i] = plan }
        } else {
            plans.insert(plan, at: 0)
        }
    }

    func deletePlans(at offsets: IndexSet) {
        plans.remove(atOffsets: offsets)
    }

    var routeWaypoints: [Waypoint] { activePlan?.waypoints ?? [] }

    func isInRoute(_ ident: String) -> Bool { routeWaypoints.contains { $0.ident == ident } }

    func directTo(_ wp: Waypoint) {
        var plan = activePlan ?? FlightPlan()
        let start: Waypoint
        if let c = flight.coordinate, flight.hasPosition {
            start = Waypoint(ident: "PPOS", name: "Present position", kind: .user, lat: c.latitude, lon: c.longitude, elevationFt: nil)
        } else if let home = homeAirport {
            start = Waypoint(airport: home)
        } else { return }
        plan.waypoints = [start, wp]
        plan.name = ""
        activePlan = plan
        selectedTab = .maps
        focus(on: plan.waypoints.map(\.coordinate))
    }

    func addToRoute(_ wp: Waypoint) {
        var plan = activePlan ?? FlightPlan()
        plan.waypoints.append(wp)
        activePlan = plan
    }

    func removeFromRoute(_ ident: String) {
        guard var plan = activePlan else { return }
        plan.waypoints.removeAll { $0.ident == ident }
        activePlan = plan
    }

    func activate(_ plan: FlightPlan) {
        activePlan = plan
        selectedTab = .maps
        focus(on: plan.waypoints.map(\.coordinate))
    }

    func focus(on coords: [CLLocationCoordinate2D]) {
        guard let r = Geo.region(around: coords, paddingFactor: 1.5) else { return }
        mapFocus = MapFocus(center: r.center, spanDegrees: max(r.span.latitudeDelta, r.span.longitudeDelta * cos(Geo.rad(r.center.latitude))))
    }

    func showOnMap(_ airport: Airport) {
        selectedTab = .maps
        mapFocus = MapFocus(center: airport.coordinate, spanDegrees: 0.4)
        mapSelectedAirport = airport
    }

    // MARK: - Favorites / recents

    func toggleFavorite(_ ident: String) {
        if let i = settings.favorites.firstIndex(of: ident) { settings.favorites.remove(at: i) } else { settings.favorites.append(ident) }
    }
    func isFavorite(_ ident: String) -> Bool { settings.favorites.contains(ident) }
    func noteRecent(_ ident: String) {
        var r = settings.recentAirports.filter { $0 != ident }
        r.insert(ident, at: 0)
        settings.recentAirports = Array(r.prefix(15))
    }

    // MARK: - Winds and performance

    func windLookup(_ profiles: [WindProfile], at time: Date) -> WindLookup? {
        guard !profiles.isEmpty else { return nil }
        return { c, alt in
            let p = profiles.min { Geo.distanceNM(c, $0.coordinate) < Geo.distanceNM(c, $1.coordinate) }!
            return p.wind(altitudeFt: alt, at: time)
        }
    }

    /// Sample points used for route winds: departure, leg midpoints / every ~40 nm, destination.
    static func windSamplePoints(_ wps: [Waypoint]) -> [CLLocationCoordinate2D] {
        let coords = wps.map(\.coordinate)
        guard coords.count >= 2 else { return coords }
        let dense = Geo.densify(coords, stepNM: 40)
        if dense.count <= 40 { return dense }
        let step = Double(dense.count) / 40
        return (0..<40).map { dense[Int(Double($0) * step)] }
    }

    func loadRouteWinds(for plan: FlightPlan, force: Bool = false) async {
        let key = plan.routeString
        guard plan.waypoints.count >= 2 else { routeWinds = []; return }
        if !force && key == routeWindsPlanKey && !routeWinds.isEmpty { return }
        if let p = try? await WindsAloftService.profiles(at: Self.windSamplePoints(plan.waypoints)) {
            routeWinds = p
            routeWindsPlanKey = key
        }
    }

    func calculate(_ plan: FlightPlan, altitude: Double? = nil) -> FlightCalc {
        PerformanceEngine.calculate(waypoints: plan.waypoints, cruiseAltitudeFt: altitude ?? Double(plan.cruiseAltitudeFt),
                                    aircraft: aircraftFor(plan),
                                    wind: plan.routeString == routeWindsPlanKey ? windLookup(routeWinds, at: plan.departureTime) : nil,
                                    magVar: { [weak self] c in self?.magVar(at: c) ?? 0 })
    }

    // MARK: - Navigation to next waypoint

    struct NavInfo {
        var next: Waypoint?
        var desiredTrack: Double?
        var distanceNext: Double?
        var eteNext: Double?
        var distanceDest: Double?
        var eteDest: Double?
        var bearingNext: Double?
    }

    func navInfo() -> NavInfo {
        var info = NavInfo()
        let wps = routeWaypoints
        guard let pos = flight.coordinate, wps.count >= 1 else { return info }
        // Choose the next waypoint: the first whose along-track position is ahead of us.
        var nextIdx = wps.count - 1
        if wps.count >= 2 {
            var best = (idx: 1, xt: Double.infinity)
            for i in 1..<wps.count {
                let a = wps[i - 1].coordinate, b = wps[i].coordinate
                let legLen = Geo.distanceNM(a, b)
                let at = Geo.alongTrackNM(pos, from: a, to: b)
                let xt = abs(Geo.crossTrackNM(pos, from: a, to: b))
                if at > -1 && at < legLen - 0.3 && xt < best.xt { best = (i, xt) }
            }
            nextIdx = best.xt.isFinite ? best.idx : wps.count - 1
            info.desiredTrack = Geo.bearing(wps[nextIdx - 1].coordinate, wps[nextIdx].coordinate)
        }
        let next = wps[nextIdx]
        info.next = next
        let dNext = Geo.distanceNM(pos, next.coordinate)
        info.distanceNext = dNext
        info.bearingNext = Geo.bearing(pos, next.coordinate)
        var dDest = dNext
        if nextIdx + 1 < wps.count {
            for i in (nextIdx + 1)..<wps.count { dDest += Geo.distanceNM(wps[i - 1].coordinate, wps[i].coordinate) }
        }
        info.distanceDest = dDest
        if flight.groundSpeedKt > 20 {
            info.eteNext = dNext / flight.groundSpeedKt * 3600
            info.eteDest = dDest / flight.groundSpeedKt * 3600
        }
        return info
    }

    // MARK: - Simulator

    func startSimulation() {
        guard let plan = activePlan, plan.waypoints.count >= 2 else { return }
        location.isSuspended = true
        flight.clear()
        simulator.start(route: plan.waypoints, cruiseAltitudeFt: Double(plan.cruiseAltitudeFt), aircraft: aircraftFor(plan), flight: flight,
                        runway: takeoffRunway(for: plan))
        selectedTab = .maps
        if let c = plan.waypoints.first?.coordinate { mapFocus = MapFocus(center: c, spanDegrees: 0.5) }
    }

    /// Picks the departure runway end: most headwind when the METAR wind is 5 kt or more, otherwise closest to the first course.
    private func takeoffRunway(for plan: FlightPlan) -> FlightSimulator.RunwayStart? {
        guard plan.waypoints.count >= 2, let first = plan.waypoints.first, first.kind == .airport, let apt = airport(first.ident) else { return nil }
        let course = Geo.bearing(first.coordinate, plan.waypoints[1].coordinate)
        let m = weather.metar(apt.ident)
        let windDir = m?.windDirection, windKt = m?.wspd ?? 0
        var best: (score: Double, start: FlightSimulator.RunwayStart)?
        for r in apt.runways where r.lengthFt >= 1500 && !r.surface.uppercased().contains("WAT") {
            guard let a = r.leCoord, let b = r.heCoord else { continue }
            let ends: [(String, CLLocationCoordinate2D, Double, Double?)] = [
                (r.le, a, r.leHeadingT ?? Geo.bearing(a, b), r.leElevFt),
                (r.he, b, r.heHeadingT ?? Geo.bearing(b, a), r.heElevFt),
            ]
            for (name, c, hdg, elev) in ends {
                let score: Double
                if let wd = windDir, windKt >= 5 {
                    score = windKt * cos(Geo.rad(Geo.angleDiff(hdg, wd)))   // headwind component
                } else {
                    score = -abs(Geo.angleDiff(hdg, course))
                }
                if best == nil || score > best!.score {
                    best = (score, FlightSimulator.RunwayStart(name: name, coordinate: c, headingT: hdg, elevationFt: elev ?? apt.elevFt))
                }
            }
        }
        return best?.start
    }

    func stopSimulation() {
        simulator.stop()
        location.isSuspended = false
        flight.clear()
    }
}
