import Foundation
import CoreLocation
import Observation

/// Flies the active route so the map, synthetic vision and hazard advisor can be explored on the ground.
@MainActor
@Observable
final class FlightSimulator {
    enum Phase: String { case takeoff = "Takeoff roll", climb = "Climb", cruise = "Cruise", descent = "Descent", approach = "Approach", landed = "Landed" }

    /// Where the takeoff roll begins: a runway threshold and its true heading.
    struct RunwayStart {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let headingT: Double
        let elevationFt: Double
    }

    private(set) var isRunning = false
    private(set) var phase: Phase = .takeoff
    var timeScale: Double = 1

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var route: [Waypoint] = []
    @ObservationIgnored private var leg = 1
    @ObservationIgnored private var pos = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @ObservationIgnored private var alt = 0.0
    @ObservationIgnored private var gs = 0.0
    @ObservationIgnored private var trk = 0.0
    @ObservationIgnored private var vs = 0.0
    @ObservationIgnored private var bank = 0.0
    @ObservationIgnored private var cruiseAlt = 5500.0
    @ObservationIgnored private var destElev = 0.0
    @ObservationIgnored private var aircraft = AircraftProfile.c172n
    @ObservationIgnored private weak var flight: FlightState?
    /// Runway heading to hold until this altitude (runway takeoff only).
    @ObservationIgnored private var holdHeadingUntilFt: Double?
    private(set) var departureRunway: String?

    func start(route: [Waypoint], cruiseAltitudeFt: Double, aircraft: AircraftProfile, flight: FlightState, runway: RunwayStart? = nil) {
        guard route.count >= 2 else { return }
        stop()
        self.route = route
        self.flight = flight
        self.aircraft = aircraft
        cruiseAlt = cruiseAltitudeFt
        leg = 1
        pos = route[0].coordinate
        alt = route[0].elevationFt ?? 0
        destElev = route.last?.elevationFt ?? 0
        trk = Geo.bearing(route[0].coordinate, route[1].coordinate)
        holdHeadingUntilFt = nil
        departureRunway = runway?.name
        if let r = runway {
            pos = r.coordinate
            alt = r.elevationFt
            trk = r.headingT
            holdHeadingUntilFt = r.elevationFt + 400
        }
        gs = 0; vs = 0; bank = 0
        phase = .takeoff
        isRunning = true
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private var remainingNM: Double {
        guard leg < route.count else { return 0 }
        var d = Geo.distanceNM(pos, route[leg].coordinate)
        if leg + 1 < route.count {
            for i in (leg + 1)..<route.count { d += Geo.distanceNM(route[i - 1].coordinate, route[i].coordinate) }
        }
        return d
    }

    private func tick() {
        guard isRunning, let flight else { return }
        let dt = 0.1 * timeScale
        let target = route[min(leg, route.count - 1)].coordinate
        let isLastLeg = leg >= route.count - 1
        let distToWp = Geo.distanceNM(pos, target)
        let remaining = remainingNM

        // Speed and vertical profile
        switch phase {
        case .takeoff:
            gs += 3.5 * dt
            vs = 0
            if gs >= aircraft.vr { phase = .climb }
        case .climb:
            let tas = aircraft.climbTAS(densityAltitudeFt: alt)
            gs += max(-2 * dt, min(2 * dt, tas - gs))
            vs = aircraft.climbRate(densityAltitudeFt: alt)
            if alt >= cruiseAlt - 10 { alt = cruiseAlt; phase = .cruise }
        case .cruise:
            let tas = aircraft.cruiseTAS(densityAltitudeFt: alt)
            gs += max(-2 * dt, min(2 * dt, tas - gs))
            vs = 0
        case .descent:
            gs += max(-2 * dt, min(2 * dt, aircraft.descentTAS - gs))
            vs = -aircraft.descentRate
            if alt <= destElev + 1000 { vs = 0; alt = destElev + 1000 }
        case .approach:
            gs += max(-2 * dt, min(2 * dt, 68 - gs))
            let glide = destElev + max(0, remaining) * 318
            vs = max(-900, min(0, (glide - alt) * 6))
        case .landed:
            gs = max(0, gs - 4 * dt)
            vs = 0
            if gs == 0 { stop() }
        }

        // Phase transitions
        if phase == .cruise || phase == .climb {
            let todNM = (alt - (destElev + 1000)) / aircraft.descentRate * (aircraft.descentTAS / 60) + 3
            if remaining <= todNM && phase == .cruise { phase = .descent }
            if remaining < 6 && isLastLeg { phase = .approach }
        }
        if phase == .descent && remaining < 6 && isLastLeg { phase = .approach }
        if phase == .approach && remaining < 0.15 && alt - destElev < 60 { phase = .landed; alt = destElev }

        alt += vs * dt / 60
        if phase == .approach { alt = max(destElev, alt) }

        // Lateral guidance (runway heading until 400 ft above the field after a runway takeoff)
        if let h = holdHeadingUntilFt, alt >= h { holdHeadingUntilFt = nil }
        if phase != .landed && phase != .takeoff && holdHeadingUntilFt == nil {
            let desired = Geo.bearing(pos, target)
            let diff = Geo.angleDiff(trk, desired)
            let rate = max(-3, min(3, diff * 0.6))
            trk = Geo.norm360(trk + rate * dt)
            let v = gs * 0.5144
            bank = Geo.deg(atan(v * Geo.rad(rate) / 9.81))
        } else {
            bank *= 0.8
        }
        pos = Geo.destination(pos, bearing: trk, distanceNM: gs * dt / 3600)

        // Waypoint sequencing
        if !isLastLeg && distToWp < max(0.4, gs / 3600 * 25) { leg += 1 }

        let pitch = phase == .takeoff ? 0 : Geo.deg(atan(vs / max(1, gs * 101.27))) + (phase == .landed ? 0 : 3)
        flight.ingest(coordinate: pos, altitudeFt: alt, groundSpeedKt: gs, trackTrue: trk, accuracyM: 3,
                      source: .simulator, timestamp: Date(), pitch: pitch, roll: bank, verticalSpeedFpm: vs)
    }
}

/// Records the GPS track while flying and turns it into a logbook entry.
@MainActor
@Observable
final class TrackRecorder {
    private(set) var isRecording = false
    private(set) var points: [TrackPoint] = []
    private(set) var startedAt: Date?
    @ObservationIgnored private var lastSample = Date.distantPast

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func start() {
        points = []
        startedAt = Date()
        isRecording = true
    }

    func stop() -> [TrackPoint] {
        isRecording = false
        return points
    }

    func sample(_ f: FlightState) {
        guard isRecording, let c = f.coordinate else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= 5 else { return }
        lastSample = now
        points.append(TrackPoint(t: now, lat: c.latitude, lon: c.longitude, altFt: f.altitudeFt, gsKt: f.groundSpeedKt))
    }
}
