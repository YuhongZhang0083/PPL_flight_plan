import SwiftUI
import CoreLocation

/// Flights tab: saved flight plans and the planning workspace.
struct FlightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.plans) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(p.title).font(.headline)
                            if p.id == model.settings.activePlanID {
                                Text("ACTIVE").font(.caption2.weight(.heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Theme.magenta, in: Capsule())
                            }
                        }
                        Text(p.routeString.isEmpty ? "No route" : p.routeString).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(Fmt.nm(p.totalDistanceNM)) nm · \(Fmt.feet(Double(p.cruiseAltitudeFt))) · \(p.departureTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(p.id)
                }
                .onDelete { model.deletePlans(at: $0) }
            }
            .themedList()
            .navigationTitle("Flights")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        var p = FlightPlan()
                        if let home = model.homeAirport { p.waypoints = [Waypoint(airport: home)] }
                        p.aircraftID = model.activeAircraft.id
                        model.plans.insert(p, at: 0)
                        selection = p.id
                    } label: { Image(systemName: "plus") }
                }
            }
            .overlay {
                if model.plans.isEmpty {
                    ContentUnavailableView("No flights", systemImage: "airplane", description: Text("Tap + to plan a flight."))
                }
            }
        } detail: {
            NavigationStack {
                if let id = selection, model.plans.contains(where: { $0.id == id }) {
                    FlightDetailView(planID: id).id(id)
                } else {
                    ContentUnavailableView("Select a flight", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
        }
        .onAppear { if selection == nil && hSize == .regular { selection = model.settings.activePlanID } }
    }
}

struct FlightDetailView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    @State private var routeText = ""
    @State private var unresolved: [String] = []
    @State private var parsing = false
    @State private var loadingWinds = false

    private var plan: FlightPlan? { model.plans.first { $0.id == planID } }

    private func update(_ f: (inout FlightPlan) -> Void) {
        guard var p = plan else { return }
        f(&p)
        model.upsert(p)
    }

    var body: some View {
        if let plan {
            let calc = model.calculate(plan)
            let ac = model.aircraftFor(plan)
            let windsReady = plan.routeString == model.routeWindsPlanKey && !model.routeWinds.isEmpty
            Form {
                Section {
                    TextField("Name (optional)", text: Binding(get: { plan.name }, set: { v in update { $0.name = v } }))
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Route: KCNO PDZ KRAL", text: $routeText, axis: .vertical)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onSubmit { parse() }
                        HStack {
                            Button { parse() } label: { if parsing { ProgressView() } else { Label("Update route", systemImage: "arrow.triangle.2.circlepath") } }
                                .buttonStyle(.bordered)
                            if !unresolved.isEmpty {
                                Text("Not found: \(unresolved.joined(separator: " "))").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Picker("Aircraft", selection: Binding(get: { model.aircraftFor(plan).id }, set: { v in update { $0.aircraftID = v } })) {
                        ForEach(model.aircraft) { Text($0.title).tag($0.id) }
                    }
                    Stepper(value: Binding(get: { plan.cruiseAltitudeFt }, set: { v in update { $0.cruiseAltitudeFt = v } }), in: 1500...17500, step: 500) {
                        HStack {
                            Text("Cruise altitude")
                            Spacer()
                            Text(Fmt.feet(Double(plan.cruiseAltitudeFt))).font(.headline.monospacedDigit())
                            if let mc = calc.legs.max(by: { $0.distanceNM < $1.distanceNM })?.magCourse {
                                let ok = PerformanceEngine.isVFRCruisingAltitude(plan.cruiseAltitudeFt, magneticCourse: mc)
                                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
                            }
                        }
                    }
                    DatePicker("Departure", selection: Binding(get: { plan.departureTime }, set: { v in update { $0.departureTime = v } }))
                } header: { Text("Flight") }

                if plan.waypoints.count >= 2 {
                    Section {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                StatCell(label: "DISTANCE", value: "\(Fmt.nm(calc.totalDistanceNM)) nm")
                                StatCell(label: "ETE", value: Fmt.ete(calc.totalTimeSec))
                                StatCell(label: "ETA", value: Fmt.timeShort.string(from: plan.departureTime.addingTimeInterval(calc.totalTimeSec)))
                            }
                            GridRow {
                                StatCell(label: "TRIP FUEL", value: "\(Fmt.gallons(calc.tripFuelGal)) gal")
                                StatCell(label: "REQUIRED", value: "\(Fmt.gallons(calc.totalFuelRequired)) gal",
                                         tint: calc.totalFuelRequired > ac.usableFuelGal ? .red : .white)
                                StatCell(label: "WIND", value: windsReady ? "\(Int(abs(calc.averageWindComponent).rounded())) kt \(calc.averageWindComponent >= 0 ? "tail" : "head")" : "no data")
                            }
                        }
                        if calc.totalFuelRequired > ac.usableFuelGal {
                            Label("Fuel required (incl. \(Int(ac.reserveMinutes)) min reserve) exceeds usable fuel \(Int(ac.usableFuelGal)) gal — plan a fuel stop.", systemImage: "fuelpump.exclamationmark")
                                .foregroundStyle(.red).font(.caption)
                        }
                        if calc.climbLimited {
                            Label("Cruise altitude is above what the aircraft can reach efficiently.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                        }
                        if !windsReady {
                            Button { Task { loadingWinds = true; await model.loadRouteWinds(for: plan, force: true); loadingWinds = false } } label: {
                                if loadingWinds { ProgressView() } else { Label("Load forecast winds aloft", systemImage: "wind") }
                            }
                        }
                    } header: { Text("Summary") }

                    Section("Planning") {
                        NavigationLink { NavLogView(planID: planID) } label: { Label("Navigation Log", systemImage: "list.bullet.rectangle") }
                        NavigationLink { ByAltitudeView(planID: planID) } label: { Label("By-Altitude Performance", systemImage: "chart.bar.xaxis") }
                        NavigationLink { RouteBriefingView(planID: planID) } label: { Label("Route Weather Briefing", systemImage: "cloud.sun") }
                        NavigationLink { FilingView(planID: planID) } label: { Label("File / ICAO Flight Plan", systemImage: "paperplane") }
                    }
                }

                Section("Waypoints") {
                    ForEach(plan.waypoints) { w in
                        HStack {
                            Text(w.ident).font(.headline.monospaced()).frame(width: 90, alignment: .leading)
                            Text(w.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .onDelete { idx in update { $0.waypoints.remove(atOffsets: idx) }; routeText = self.plan?.routeString ?? "" }
                    .onMove { a, b in update { $0.waypoints.move(fromOffsets: a, toOffset: b) }; routeText = self.plan?.routeString ?? "" }
                }

                Section {
                    Button { model.activate(plan) } label: { Label("Activate on Map", systemImage: "map") }
                    Button { model.activate(plan); model.startSimulation() } label: { Label("Simulate flight", systemImage: "airplane.departure") }
                        .disabled(plan.waypoints.count < 2)
                    Button {
                        var copy = plan
                        copy.id = UUID()
                        copy.name = "Return"
                        copy.waypoints = plan.waypoints.reversed()
                        model.plans.insert(copy, at: 0)
                    } label: { Label("Create return flight", systemImage: "arrow.uturn.backward") }
                    TextField("Notes", text: Binding(get: { plan.notes }, set: { v in update { $0.notes = v } }), axis: .vertical)
                }
            }
            .themedList()
            .navigationTitle(plan.title)
            .toolbar { EditButton() }
            .onAppear { routeText = plan.routeString }
            .task(id: plan.routeString) { await model.loadRouteWinds(for: plan) }
        }
    }

    private func parse() {
        parsing = true
        Task {
            let r = await RouteParser.parse(routeText, index: model.db.index)
            update { $0.waypoints = r.waypoints }
            unresolved = r.unresolved
            parsing = false
            routeText = plan?.routeString ?? routeText
        }
    }
}

struct NavLogView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID

    var body: some View {
        if let plan = model.plans.first(where: { $0.id == planID }) {
            let calc = model.calculate(plan)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            row(["LEG", "PHASE", "TC", "WIND", "WCA", "TH", "VAR", "MH", "DIST", "GS", "ETE", "FUEL"], header: true)
                            ForEach(calc.legs) { l in
                                row(["\(l.from.ident)→\(l.to.ident)", l.phase, Fmt.heading(l.trueCourse),
                                     l.windSpeed > 0 ? String(format: "%03.0f/%.0f", l.windDir, l.windSpeed) : "—",
                                     String(format: "%+.0f°", l.wca), Fmt.heading(l.trueHeading),
                                     String(format: "%.0f%@", abs(l.magVar), l.magVar >= 0 ? "E" : "W"),
                                     Fmt.heading(l.magHeading), Fmt.nm(l.distanceNM), "\(Int(l.groundSpeed.rounded()))",
                                     Fmt.hhmm(l.timeSec), Fmt.gallons(l.fuelGal)], header: false)
                            }
                            row(["TOTAL", "", "", "", "", "", "", "", Fmt.nm(calc.totalDistanceNM), "\(Int(calc.averageGS.rounded()))",
                                 Fmt.hhmm(calc.totalTimeSec), Fmt.gallons(calc.tripFuelGal)], header: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cruise TAS \(Int(calc.cruiseTAS)) kt at \(Fmt.feet(calc.cruiseAltitudeFt)) · climb \(Fmt.ete(calc.climbTimeSec)) / \(Fmt.nm(calc.climbDistanceNM)) nm")
                        Text("Fuel: trip \(Fmt.gallons(calc.tripFuelGal)) + taxi \(Fmt.gallons(calc.taxiFuelGal)) + reserve \(Fmt.gallons(calc.reserveFuelGal)) = \(Fmt.gallons(calc.totalFuelRequired)) gal")
                        Text("Swipe the table sideways for all columns. MH = TC + WCA − East variation. Winds: GFS forecast at cruise altitude, leg midpoint, departure time.").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 12)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.navy)
            .navigationTitle("Nav Log")
            .toolbar {
                ShareLink(item: navLogText(plan, calc)) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

    private let widths: [CGFloat] = [120, 70, 56, 72, 52, 56, 50, 56, 52, 44, 56, 50]

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { i in
                Text(cells[i])
                    .font(header ? .caption.weight(.heavy) : .system(.subheadline, design: .monospaced))
                    .foregroundStyle(header ? Color.secondary : (i == 7 ? Theme.accent : Color.white))
                    .frame(width: widths[i], alignment: .leading)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }

    private func navLogText(_ plan: FlightPlan, _ calc: FlightCalc) -> String {
        var s = "NAV LOG \(plan.title)  ALT \(plan.cruiseAltitudeFt)  DEP \(plan.departureTime.formatted())\n"
        s += "LEG            TC   WIND    WCA  MH   DIST  GS   ETE   FUEL\n"
        for l in calc.legs {
            s += String(format: "%-14@ %03.0f  %03.0f/%02.0f %+3.0f  %03.0f  %5.1f %3.0f  %@  %4.1f\n",
                        "\(l.from.ident)-\(l.to.ident)" as NSString, l.trueCourse, l.windDir, l.windSpeed, l.wca, l.magHeading,
                        l.distanceNM, l.groundSpeed, Fmt.hhmm(l.timeSec) as NSString, l.fuelGal)
        }
        s += "TOTAL \(Fmt.nm(calc.totalDistanceNM)) nm  \(Fmt.hhmm(calc.totalTimeSec))  \(Fmt.gallons(calc.tripFuelGal)) gal (req \(Fmt.gallons(calc.totalFuelRequired)))\n"
        return s
    }
}
