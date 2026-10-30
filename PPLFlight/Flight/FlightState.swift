import Foundation
import CoreLocation
import Observation

/// Current ownship state, fed by GPS or the built-in flight simulator.
@MainActor
@Observable
final class FlightState {
    enum Source: String { case none = "No position", gps = "GPS", simulator = "Simulator" }

    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var altitudeFt: Double = 0
    private(set) var groundSpeedKt: Double = 0
    private(set) var trackTrue: Double = 0
    private(set) var verticalSpeedFpm: Double = 0
    private(set) var pitchDeg: Double = 0
    private(set) var rollDeg: Double = 0
    private(set) var horizontalAccuracyM: Double = 0
    private(set) var source: Source = .none
    private(set) var lastUpdate: Date = .distantPast

    private var lastAlt: Double?
    private var lastTrack: Double?
    private var lastTime: Date?
    private var turnRate: Double = 0

    var hasPosition: Bool { coordinate != nil && Date().timeIntervalSince(lastUpdate) < 15 }
    var isAirborne: Bool { hasPosition && groundSpeedKt > 35 }

    func ingest(coordinate c: CLLocationCoordinate2D, altitudeFt alt: Double, groundSpeedKt gs: Double, trackTrue trk: Double?,
                accuracyM: Double = 5, source src: Source, timestamp: Date = Date(),
                pitch: Double? = nil, roll: Double? = nil, verticalSpeedFpm vsOverride: Double? = nil) {
        let dt = lastTime.map { timestamp.timeIntervalSince($0) } ?? 0
        coordinate = c
        groundSpeedKt = max(0, gs)
        if let trk, gs > 2 { trackTrue = Geo.norm360(trk) }
        horizontalAccuracyM = accuracyM
        source = src
        if dt > 0.05 {
            if let v = vsOverride {
                verticalSpeedFpm = v
            } else if let la = lastAlt {
                let vs = (alt - la) / dt * 60
                verticalSpeedFpm = verticalSpeedFpm * 0.6 + vs * 0.4
            }
            if let lt = lastTrack, gs > 20 {
                let tr = Geo.angleDiff(lt, trackTrue) / dt
                turnRate = turnRate * 0.6 + tr * 0.4
            } else {
                turnRate *= 0.5
            }
        }
        altitudeFt = alt
        // GPS-derived pseudo-attitude unless the source provides attitude.
        if let pitch { pitchDeg = pitch } else {
            let gsFpm = max(1, groundSpeedKt * 101.27)
            let fpa = Geo.deg(atan(verticalSpeedFpm / gsFpm))
            pitchDeg = gs > 30 ? fpa + 2 : 0
        }
        if let roll { rollDeg = roll } else {
            let v = groundSpeedKt * 0.5144
            let omega = Geo.rad(turnRate)
            rollDeg = gs > 30 ? max(-45, min(45, Geo.deg(atan(v * omega / 9.81)))) : 0
        }
        lastAlt = alt
        lastTrack = trackTrue
        lastTime = timestamp
        lastUpdate = timestamp
    }

    func clear() {
        coordinate = nil
        source = .none
        lastAlt = nil; lastTrack = nil; lastTime = nil
        groundSpeedKt = 0; verticalSpeedFpm = 0; pitchDeg = 0; rollDeg = 0
    }
}

/// CoreLocation wrapper.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    weak var flight: FlightState?
    var isSuspended = false   // true while the simulator is driving
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    var onUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .airborne
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func enableBackground(_ on: Bool) {
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.allowsBackgroundLocationUpdates = on
        manager.showsBackgroundLocationIndicator = on
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            guard !self.isSuspended, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 200 else { return }
            let gs = loc.speed >= 0 ? loc.speed * 1.943844 : 0
            let trk: Double? = loc.course >= 0 ? loc.course : nil
            self.flight?.ingest(coordinate: loc.coordinate, altitudeFt: loc.altitude * Geo.feetPerMeter, groundSpeedKt: gs,
                                trackTrue: trk, accuracyM: loc.horizontalAccuracy, source: .gps, timestamp: loc.timestamp)
            self.onUpdate?(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
