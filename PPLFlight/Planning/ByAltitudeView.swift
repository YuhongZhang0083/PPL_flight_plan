import SwiftUI
import CoreLocation

/// By-Altitude performance: groundspeed per altitude and route segment, terrain profile, and time/fuel per altitude.
struct ByAltitudeView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    @State private var terrain: [Double] = []
    @State private var loading = true

    private let segments = 6

    struct Row: Identifiable {
        var id: Int { altitude }
        let altitude: Int
        let calc: FlightCalc
        let segmentGS: [Double]
        let vfrOK: Bool
    }

    var body: some View {
        if let plan = model.plans.first(where: { $0.id == planID }), plan.waypoints.count >= 2 {
            let rows = computeRows(plan)
            let selected = rows.first { $0.altitude == plan.cruiseAltitudeFt } ?? rows.first
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    chart(plan: plan, rows: rows)
                        .frame(height: 360)
                        .background(Color(red: 0.07, green: 0.1, blue: 0.3), in: RoundedRectangle(cornerRadius: 10))
                    if let s = selected { statsBar(plan: plan, row: s) }
                    table(plan: plan, rows: rows)
                    Text("Groundspeed bubbles: cruise TAS at each altitude (\(model.aircraftFor(plan).model), \(Int(model.aircraftFor(plan).cruisePowerPct))% power, full throttle where power is limited) combined with GFS forecast winds along each route segment. Green = within 3 kt of the best altitude for that segment. ✓ = VFR cruising altitude for the route's magnetic course (14 CFR 91.159).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Theme.navy)
            .navigationTitle("By-Altitude")
            .overlay { if loading && model.routeWinds.isEmpty { ProgressView("Loading winds & terrain…").padding().panelStyle() } }
            .task {
                await model.loadRouteWinds(for: plan)
                terrain = await TerrainService.shared.profile(along: plan.waypoints.map(\.coordinate), samples: 120)
                loading = false
            }
        } else {
            ContentUnavailableView("Route needed", systemImage: "chart.bar.xaxis", description: Text("Enter at least two waypoints."))
        }
    }

    // MARK: Computation

    private func position(along wps: [Waypoint], at s: Double) -> (CLLocationCoordinate2D, Double) {
        var acc = 0.0
        for i in 1..<wps.count {
            let a = wps[i - 1].coordinate, b = wps[i].coordinate
            let d = Geo.distanceNM(a, b)
            if acc + d >= s || i == wps.count - 1 {
                let f = d > 0 ? min(1, max(0, (s - acc) / d)) : 0
                return (Geo.interpolate(a, b, f), Geo.bearing(a, b))
            }
            acc += d
        }
        return (wps[0].coordinate, 0)
    }

    private func computeRows(_ plan: FlightPlan) -> [Row] {
        let ac = model.aircraftFor(plan)
        let wps = plan.waypoints
        let minAlt = max(wps.first?.elevationFt ?? 0, wps.last?.elevationFt ?? 0) + 1000
        let top = min(17500, Int(ac.serviceCeilingFt) + 500)
        let alts = stride(from: 2500, through: top, by: 1000).filter { Double($0) >= minAlt }
        let total = plan.totalDistanceNM
        let lookup = plan.routeString == model.routeWindsPlanKey ? model.windLookup(model.routeWinds, at: plan.departureTime) : nil
        let calcBase = model.calculate(plan)
        let mainMC = calcBase.legs.max(by: { $0.distanceNM < $1.distanceNM })?.magCourse ?? 0
        return alts.map { alt in
            let calc = model.calculate(plan, altitude: Double(alt))
            var gs: [Double] = []
            for k in 0..<segments {
                let s = total * (Double(k) + 0.5) / Double(segments)
                let (p, crs) = position(along: wps, at: s)
                let w = lookup?(p, Double(alt))
                let dev = w.map { $0.tempC - Atmosphere.isaTempC(altitudeFt: Double(alt)) } ?? 0
                let tas = ac.cruiseTAS(densityAltitudeFt: Double(alt) + 120 * dev)
                gs.append(WindSolution(trueCourse: crs, tas: tas, windFrom: w?.dir ?? 0, windSpeed: w?.speed ?? 0).groundSpeed)
            }
            return Row(altitude: alt, calc: calc, segmentGS: gs, vfrOK: PerformanceEngine.isVFRCruisingAltitude(alt, magneticCourse: mainMC))
        }
    }

    // MARK: Views

    private func chart(plan: FlightPlan, rows: [Row]) -> some View {
        Canvas { ctx, size in
            guard !rows.isEmpty else { return }
            let left: CGFloat = 54, bottom: CGFloat = 18
            let w = size.width - left - 8, h = size.height - bottom - 8
            let maxAlt = Double((rows.last?.altitude ?? 10000) + 1500)
            func y(_ a: Double) -> CGFloat { 8 + h - CGFloat(a / maxAlt) * h }
            func x(_ f: Double) -> CGFloat { left + CGFloat(f) * w }

            // Terrain
            if terrain.count > 1 {
                var p = Path()
                p.move(to: CGPoint(x: x(0), y: y(0)))
                for (i, t) in terrain.enumerated() { p.addLine(to: CGPoint(x: x(Double(i) / Double(terrain.count - 1)), y: y(t))) }
                p.addLine(to: CGPoint(x: x(1), y: y(0)))
                p.closeSubpath()
                ctx.fill(p, with: .color(Color(red: 0.25, green: 0.6, blue: 0.2).opacity(0.85)))
            }
            // Altitude labels + selected line
            for r in rows {
                let yy = y(Double(r.altitude))
                ctx.draw(Text("\(r.altitude.formatted())'").font(.system(size: 10, weight: r.altitude == plan.cruiseAltitudeFt ? .heavy : .medium))
                    .foregroundColor(r.altitude == plan.cruiseAltitudeFt ? .white : .gray), at: CGPoint(x: 26, y: yy))
                if r.altitude == plan.cruiseAltitudeFt {
                    var l = Path(); l.move(to: CGPoint(x: left, y: yy)); l.addLine(to: CGPoint(x: x(1), y: yy))
                    ctx.stroke(l, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            // Planned profile (selected altitude)
            if let sel = rows.first(where: { $0.altitude == plan.cruiseAltitudeFt }) {
                let total = max(0.1, sel.calc.totalDistanceNM)
                let dep = plan.waypoints.first?.elevationFt ?? 0, dest = plan.waypoints.last?.elevationFt ?? 0
                var p = Path()
                p.move(to: CGPoint(x: x(0), y: y(dep)))
                p.addLine(to: CGPoint(x: x(sel.calc.climbDistanceNM / total), y: y(Double(sel.altitude))))
                p.addLine(to: CGPoint(x: x(1 - sel.calc.descentDistanceNM / total), y: y(Double(sel.altitude))))
                p.addLine(to: CGPoint(x: x(1), y: y(dest + 1000)))
                ctx.stroke(p, with: .color(Theme.magenta), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            }
            // Bubbles
            for k in 0..<segments {
                let best = rows.map { $0.segmentGS[k] }.max() ?? 0
                for r in rows {
                    let gs = r.segmentGS[k]
                    let c = CGPoint(x: x((Double(k) + 0.5) / Double(segments)), y: y(Double(r.altitude)))
                    let rect = CGRect(x: c.x - 17, y: c.y - 8, width: 34, height: 16)
                    let good = gs >= best - 3
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(good ? Color(red: 0.2, green: 0.62, blue: 0.2) : Color(red: 0.22, green: 0.3, blue: 0.5)))
                    ctx.draw(Text("\(Int(gs.rounded()))").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: c)
                }
            }
            // Waypoint labels
            var acc = 0.0
            let total = max(0.1, plan.totalDistanceNM)
            var lastX: CGFloat = -100
            var raised = false
            for (i, wp) in plan.waypoints.enumerated() {
                if i > 0 { acc += Geo.distanceNM(plan.waypoints[i - 1].coordinate, wp.coordinate) }
                let px = min(max(x(acc / total), left + 16), size.width - 22)
                raised = px - lastX < 34 ? !raised : false
                ctx.draw(Text(wp.ident).font(.system(size: 10, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: px, y: size.height - (raised ? 20 : 8)))
                lastX = px
            }
        }
    }

    private func statsBar(plan: FlightPlan, row: Row) -> some View {
        let highest = terrain.max() ?? 0
        let c = row.calc
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
            StatCell(label: "DIST", value: "\(Fmt.nm(c.totalDistanceNM)) nm")
            StatCell(label: "ETE", value: Fmt.ete(c.totalTimeSec))
            StatCell(label: "ETA", value: Fmt.timeShort.string(from: plan.departureTime.addingTimeInterval(c.totalTimeSec)))
            StatCell(label: "FUEL", value: "\(Fmt.gallons(c.tripFuelGal)) g")
            StatCell(label: "WIND", value: "\(Int(abs(c.averageWindComponent).rounded())) kt \(c.averageWindComponent >= 0 ? "tail" : "head")")
            StatCell(label: "HIGHEST PT", value: terrain.isEmpty ? "…" : Fmt.feet(highest))
            StatCell(label: "CLEARANCE", value: terrain.isEmpty ? "…" : Fmt.feet(Double(row.altitude) - highest),
                     tint: Double(row.altitude) - highest < 1000 ? .red : (Double(row.altitude) - highest < 2000 ? .orange : Theme.hazardYellow))
            StatCell(label: "TAS", value: "\(Int(c.cruiseTAS)) kt")
        }
        .padding(10)
        .panelStyle()
    }

    private func table(plan: FlightPlan, rows: [Row]) -> some View {
        let best = rows.min { $0.calc.totalTimeSec < $1.calc.totalTimeSec }?.altitude
        return VStack(spacing: 0) {
            HStack {
                Text("ALTITUDE").frame(width: 90, alignment: .leading)
                Text("ETE").frame(width: 64, alignment: .leading)
                Text("FUEL").frame(width: 54, alignment: .leading)
                Text("WIND").frame(width: 76, alignment: .leading)
                Text("VFR").frame(width: 34)
                Spacer()
            }
            .font(.caption.weight(.heavy)).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(rows.reversed()) { r in
                Button {
                    if var p = model.plans.first(where: { $0.id == planID }) { p.cruiseAltitudeFt = r.altitude; model.upsert(p) }
                } label: {
                    HStack {
                        Text(Fmt.feet(Double(r.altitude))).font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 90, alignment: .leading)
                        Text(Fmt.ete(r.calc.totalTimeSec)).monospacedDigit().frame(width: 64, alignment: .leading)
                        Text(Fmt.gallons(r.calc.tripFuelGal)).monospacedDigit().frame(width: 54, alignment: .leading)
                        Text("\(Int(abs(r.calc.averageWindComponent).rounded())) \(r.calc.averageWindComponent >= 0 ? "tail" : "head")")
                            .foregroundStyle(r.calc.averageWindComponent >= 0 ? .green : .orange).frame(width: 76, alignment: .leading)
                        Image(systemName: r.vfrOK ? "checkmark" : "minus").foregroundStyle(r.vfrOK ? .green : .secondary).frame(width: 34)
                        Spacer()
                        if r.altitude == best { Text("FASTEST").font(.caption2.weight(.heavy)).foregroundStyle(.green) }
                        if r.altitude == plan.cruiseAltitudeFt { Image(systemName: "largecircle.fill.circle").foregroundStyle(Theme.magenta) }
                    }
                    .font(.subheadline)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.25)
            }
        }
        .padding(12)
        .panelStyle()
    }
}
