import SwiftUI
import SceneKit
import CoreLocation

/// Synthetic vision: 3D terrain with hazard coloring and a PFD-style overlay (GS / GPS ALT / track / pseudo-attitude).
struct SyntheticVisionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let f = model.flight
        let home = model.homeAirport
        let hasPos = f.hasPosition && f.coordinate != nil
        let pos = hasPos ? f.coordinate! : (home?.coordinate ?? CLLocationCoordinate2D(latitude: 33.9747, longitude: -117.637))
        let alt = hasPos ? f.altitudeFt : (home?.elevFt ?? 650) + 2500
        let hdg = hasPos ? f.trackTrue : 90
        let mv = model.magVar(at: pos)
        ZStack {
            SVSceneView(center: pos, altitudeFt: alt, headingTrue: hdg, pitch: hasPos ? f.pitchDeg : 0, roll: hasPos ? f.rollDeg : 0,
                        hazardAltitudeFt: alt, airports: { model.db.index?.nearestAirports(to: pos, count: 25, maxNM: 30).map(\.airport) ?? [] })
            PFDOverlay(groundSpeed: hasPos ? f.groundSpeedKt : 0, altitudeFt: alt, verticalSpeed: hasPos ? f.verticalSpeedFpm : 0,
                       trackMag: Geo.norm360(hdg - mv), pitch: hasPos ? f.pitchDeg : 0, roll: hasPos ? f.rollDeg : 0)
            if !hasPos {
                VStack {
                    Spacer()
                    Text("No GPS position — showing \(home?.displayIdent ?? "home") at \(Fmt.feet(alt)). Start the simulator from a route to fly.")
                        .font(.caption2.weight(.semibold))
                        .padding(6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 54)
                }
            }
        }
        .clipped()
    }
}

struct SVSceneView: UIViewRepresentable {
    var center: CLLocationCoordinate2D
    var altitudeFt: Double
    var headingTrue: Double
    var pitch: Double
    var roll: Double
    var hazardAltitudeFt: Double
    var airports: () -> [Airport]

    func makeCoordinator() -> SyntheticVisionController { SyntheticVisionController() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = context.coordinator.scene
        v.pointOfView = context.coordinator.cameraNode
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 30
        v.rendersContinuously = true
        v.allowsCameraControl = false
        v.backgroundColor = UIColor(red: 0.45, green: 0.66, blue: 0.92, alpha: 1)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        c.ensureMesh(around: center, airports: airports)
        c.updateColors(hazardAltitudeFt: hazardAltitudeFt)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.12
        c.updateCamera(position: center, altitudeFt: altitudeFt, headingTrue: headingTrue, pitchDeg: pitch, rollDeg: roll)
        SCNTransaction.commit()
    }
}

/// Speed tape, altitude tape, heading tape, horizon/pitch ladder and roll scale.
struct PFDOverlay: View {
    var groundSpeed: Double
    var altitudeFt: Double
    var verticalSpeed: Double
    var trackMag: Double
    var pitch: Double
    var roll: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let f = (w / 2) / tan(SyntheticVisionController.hFOV / 2 * .pi / 180)
            ZStack {
                // Horizon + pitch ladder
                Canvas { ctx, size in
                    var c = ctx
                    c.translateBy(x: size.width / 2, y: size.height / 2)
                    c.rotate(by: .degrees(-roll))
                    let py = CGFloat(tan(pitch * .pi / 180)) * f
                    var horizon = Path()
                    horizon.move(to: CGPoint(x: -size.width * 2, y: py)); horizon.addLine(to: CGPoint(x: size.width * 2, y: py))
                    c.stroke(horizon, with: .color(.white), lineWidth: 2)
                    for deg in stride(from: -20, through: 20, by: 5) where deg != 0 {
                        let y = py - CGFloat(tan(Double(deg) * .pi / 180)) * f
                        let half: CGFloat = deg % 10 == 0 ? 34 : 18
                        var l = Path(); l.move(to: CGPoint(x: -half, y: y)); l.addLine(to: CGPoint(x: half, y: y))
                        c.stroke(l, with: .color(.white.opacity(0.85)), lineWidth: 1.4)
                        if deg % 10 == 0 {
                            c.draw(Text("\(abs(deg))").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: half + 12, y: y))
                        }
                    }
                }
                // Aircraft reference symbol
                Path { p in
                    p.move(to: CGPoint(x: w / 2 - 60, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 - 22, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 - 22, y: h / 2 + 8))
                    p.move(to: CGPoint(x: w / 2 + 60, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 + 22, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 + 22, y: h / 2 + 8))
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .shadow(color: .black, radius: 1)
                Circle().fill(Color.yellow).frame(width: 6, height: 6).position(x: w / 2, y: h / 2)

                RollScale(roll: roll).frame(width: min(w * 0.5, 240), height: 60).position(x: w / 2, y: 38)

                // Tapes
                Tape(value: groundSpeed, step: 10, label: "GS KTS", digits: "%.0f", leftAligned: true)
                    .frame(width: 64, height: min(h * 0.62, 240))
                    .position(x: max(52, w * 0.2), y: h / 2)
                Tape(value: altitudeFt, step: 100, label: "GPS ALT", digits: "%.0f", leftAligned: false)
                    .frame(width: 78, height: min(h * 0.62, 240))
                    .position(x: min(w - 60, w * 0.8), y: h / 2)
                Text(String(format: "%+.0f", (verticalSpeed / 10).rounded() * 10))
                    .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 4).background(.black.opacity(0.5))
                    .position(x: min(w - 60, w * 0.8), y: h / 2 + min(h * 0.62, 240) / 2 + 12)

                HeadingTape(heading: trackMag)
                    .frame(width: min(w * 0.7, 360), height: 36)
                    .position(x: w / 2, y: h - 24)
            }
        }
        .allowsHitTesting(false)
    }
}

struct Tape: View {
    var value: Double
    var step: Double
    var label: String
    var digits: String
    var leftAligned: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let pxPerUnit = h / (step * 6)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35))
                Canvas { ctx, size in
                    let base = (value / step).rounded(.down) * step
                    for k in -4...5 {
                        let v = base + Double(k) * step
                        guard v >= 0 else { continue }
                        let y = size.height / 2 - CGFloat(v - value) * pxPerUnit
                        var tick = Path()
                        let x0: CGFloat = leftAligned ? size.width - 10 : 0
                        tick.move(to: CGPoint(x: x0, y: y)); tick.addLine(to: CGPoint(x: x0 + 10, y: y))
                        ctx.stroke(tick, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
                        ctx.draw(Text(String(format: digits, v)).font(.system(size: 11, weight: .semibold)).foregroundColor(.white),
                                 at: CGPoint(x: size.width / 2 + (leftAligned ? -6 : 6), y: y))
                    }
                }
                .clipped()
                Text(String(format: digits, value))
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: geo.size.width - 4, height: 26)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: 1.2))
                VStack {
                    Spacer()
                    Text(label).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white.opacity(0.85)).padding(.bottom, 3)
                }
            }
        }
    }
}

struct HeadingTape: View {
    var heading: Double
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { ctx, size in
                    let pxPerDeg = size.width / 70
                    let base = (heading / 5).rounded(.down) * 5
                    for k in -8...8 {
                        let d = base + Double(k) * 5
                        let x = size.width / 2 + CGFloat(d - heading) * pxPerDeg
                        let isMajor = Int(Geo.norm360(d)) % 10 == 0
                        var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: isMajor ? 9 : 5))
                        ctx.stroke(p, with: .color(.white), lineWidth: 1.2)
                        if Int(Geo.norm360(d)) % 30 == 0 {
                            let v = Int(Geo.norm360(d))
                            let label = [0: "N", 90: "E", 180: "S", 270: "W"][v] ?? "\(v / 10)"
                            ctx.draw(Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(.white), at: CGPoint(x: x, y: 20))
                        }
                    }
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                Text(Fmt.heading(heading) + "M")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white))
                    .offset(y: -24)
            }
        }
    }
}

struct RollScale: View {
    var roll: Double
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height * 1.6)
            let r = size.height * 1.35
            for a in [-60.0, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60] {
                let ang = (a - 90) * .pi / 180
                let len: CGFloat = abs(a).truncatingRemainder(dividingBy: 30) == 0 ? 10 : 6
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r))
                p.addLine(to: CGPoint(x: c.x + cos(ang) * (r - len), y: c.y + sin(ang) * (r - len)))
                ctx.stroke(p, with: .color(.white), lineWidth: 1.5)
            }
            let ang = (-roll - 90) * .pi / 180
            let tip = CGPoint(x: c.x + cos(ang) * (r - 12), y: c.y + sin(ang) * (r - 12))
            var tri = Path()
            let perp = ang + .pi / 2
            tri.move(to: tip)
            tri.addLine(to: CGPoint(x: tip.x - cos(ang) * 10 + cos(perp) * 6, y: tip.y - sin(ang) * 10 + sin(perp) * 6))
            tri.addLine(to: CGPoint(x: tip.x - cos(ang) * 10 - cos(perp) * 6, y: tip.y - sin(ang) * 10 - sin(perp) * 6))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(.yellow))
        }
    }
}
