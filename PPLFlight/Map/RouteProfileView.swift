import SwiftUI
import CoreLocation

/// Vertical profile of the active route: terrain (hazard-colored), planned altitude, ownship.
struct RouteProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var terrain: [Double] = []
    @State private var key = ""

    var body: some View {
        let plan = model.activePlan
        let wps = plan?.waypoints ?? []
        VStack(alignment: .leading, spacing: 4) {
            if wps.count < 2 {
                Text("Enter a route with at least two waypoints to see the profile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let calc = model.calculate(plan!)
                let total = max(0.1, plan!.totalDistanceNM)
                let cruise = Double(plan!.cruiseAltitudeFt)
                let maxTerrain = terrain.max() ?? 0
                HStack(spacing: 14) {
                    StatCell(label: "HIGHEST TERRAIN", value: terrain.isEmpty ? "…" : Fmt.feet(maxTerrain))
                    StatCell(label: "CLEARANCE", value: terrain.isEmpty ? "…" : Fmt.feet(cruise - maxTerrain),
                             tint: cruise - maxTerrain < 1000 ? Theme.hazardRed : (cruise - maxTerrain < 2000 ? Theme.hazardYellow : .white))
                    StatCell(label: "TOC", value: "\(Fmt.nm(calc.climbDistanceNM)) nm")
                    StatCell(label: "TOD", value: "\(Fmt.nm(max(0, total - calc.descentDistanceNM))) nm")
                }
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size, wps: wps, total: total, cruise: cruise, calc: calc)
                }
            }
        }
        .padding(10)
        .panelStyle()
        .task(id: plan?.routeString ?? "") { await loadTerrain() }
    }

    private func loadTerrain() async {
        guard let plan = model.activePlan, plan.waypoints.count >= 2 else { terrain = []; return }
        let k = plan.routeString
        if k == key && !terrain.isEmpty { return }
        let t = await TerrainService.shared.profile(along: plan.waypoints.map(\.coordinate), samples: 140)
        terrain = t
        key = k
    }

    private func draw(ctx: GraphicsContext, size: CGSize, wps: [Waypoint], total: Double, cruise: Double, calc: FlightCalc) {
        let maxAlt = max(cruise + 2000, (terrain.max() ?? 0) + 1500)
        func x(_ d: Double) -> CGFloat { CGFloat(d / total) * size.width }
        func y(_ a: Double) -> CGFloat { size.height - CGFloat(a / maxAlt) * size.height }

        // Grid
        var gridAlt = 0.0
        let step = maxAlt > 10000 ? 2000.0 : 1000.0
        while gridAlt <= maxAlt {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y(gridAlt))); p.addLine(to: CGPoint(x: size.width, y: y(gridAlt)))
            ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 1)
            ctx.draw(Text("\(Int(gridAlt / 1000))k").font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: 10, y: y(gridAlt) - 6))
            gridAlt += step
        }

        // Terrain with hazard coloring
        if terrain.count > 1 {
            let n = terrain.count
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (i, t) in terrain.enumerated() { area.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: y(t))) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Color(red: 0.45, green: 0.5, blue: 0.25), Color(red: 0.2, green: 0.35, blue: 0.15)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            for i in 0..<n {
                let t = terrain[i]
                let col: Color? = t >= cruise - 100 ? Theme.hazardRed : (t >= cruise - 1000 ? Theme.hazardYellow : nil)
                if let col {
                    let w = size.width / CGFloat(n - 1)
                    let r = CGRect(x: size.width * CGFloat(i) / CGFloat(n - 1) - w / 2, y: y(t), width: w + 0.5, height: size.height - y(t))
                    ctx.fill(Path(r), with: .color(col.opacity(0.85)))
                }
            }
        }

        // Planned altitude profile
        let dep = wps.first?.elevationFt ?? 0, dest = wps.last?.elevationFt ?? 0
        var prof = Path()
        prof.move(to: CGPoint(x: 0, y: y(dep)))
        prof.addLine(to: CGPoint(x: x(calc.climbDistanceNM), y: y(cruise)))
        prof.addLine(to: CGPoint(x: x(total - calc.descentDistanceNM), y: y(cruise)))
        prof.addLine(to: CGPoint(x: size.width, y: y(dest + 1000)))
        ctx.stroke(prof, with: .color(Theme.magenta), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        // Waypoint ticks
        var cum = 0.0
        for i in 0..<wps.count {
            if i > 0 { cum += Geo.distanceNM(wps[i - 1].coordinate, wps[i].coordinate) }
            let px = x(cum)
            var p = Path(); p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: size.height))
            ctx.stroke(p, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text(wps[i].ident).font(.system(size: 9, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: min(max(px, 18), size.width - 18), y: 7))
        }

        // Ownship
        if let pos = model.flight.coordinate, model.flight.hasPosition {
            var best = (d: 0.0, xt: Double.infinity)
            var c = 0.0
            for i in 1..<wps.count {
                let a = wps[i - 1].coordinate, b = wps[i].coordinate
                let len = Geo.distanceNM(a, b)
                let at = min(max(0, Geo.alongTrackNM(pos, from: a, to: b)), len)
                let xt = abs(Geo.crossTrackNM(pos, from: a, to: b))
                if xt < best.xt { best = (c + at, xt) }
                c += len
            }
            let pt = CGPoint(x: x(best.d), y: y(model.flight.altitudeFt))
            let r = CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)
            ctx.fill(Path(ellipseIn: r), with: .color(Theme.accent))
            ctx.stroke(Path(ellipseIn: r), with: .color(.black), lineWidth: 1.5)
        }
    }
}
