import SwiftUI
import CoreLocation

/// Generates an ICAO-format VFR flight plan (as required by the FAA for domestic filing) to copy into 1800wxbrief / ForeFlight / FSS.
struct FilingView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    @State private var pilotName = ""
    @State private var phone = ""
    @State private var souls = 1
    @State private var remarks = "STUDENT PILOT"

    var body: some View {
        if let plan = model.plans.first(where: { $0.id == planID }), plan.waypoints.count >= 2 {
            let ac = model.aircraftFor(plan)
            let calc = model.calculate(plan)
            let fuelEndurance = ac.usableFuelGal / max(1, ac.cruiseGPH(densityAltitudeFt: Double(plan.cruiseAltitudeFt))) * 3600
            let text = icao(plan: plan, ac: ac, calc: calc, endurance: fuelEndurance)
            Form {
                Section("Pilot") {
                    TextField("Pilot name", text: $pilotName)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    Stepper("Persons on board: \(souls)", value: $souls, in: 1...4)
                    TextField("Remarks", text: $remarks)
                }
                Section("Summary") {
                    LabeledContent("Aircraft", value: "\(ac.tailNumber) \(ac.icaoType)/L \(ac.equipment)/\(ac.surveillance)")
                    LabeledContent("Departure", value: "\(plan.departure?.ident ?? "") at \(Fmt.zulu.string(from: plan.departureTime))")
                    LabeledContent("Cruise", value: "N\(String(format: "%04d", Int(calc.cruiseTAS))) VFR \(plan.cruiseAltitudeFt)'")
                    LabeledContent("ETE", value: Fmt.hhmm(calc.totalTimeSec))
                    LabeledContent("Fuel endurance", value: Fmt.hhmm(fuelEndurance))
                }
                Section {
                    Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    ShareLink(item: text) { Label("Share / copy flight plan", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = text } label: { Label("Copy to clipboard", systemImage: "doc.on.doc") }
                } header: { Text("ICAO flight plan") } footer: {
                    Text("File with Flight Service (1-800-WX-BRIEF or 1800wxbrief.com) and remember to open it after departure and close it on arrival.")
                }
                Section {
                    Link(destination: URL(string: "https://www.1800wxbrief.com/Website/flightplan")!) { Label("Open 1800wxbrief.com", systemImage: "safari") }
                    Link(destination: URL(string: "tel:18009922743")!) { Label("Call 1-800-WX-BRIEF", systemImage: "phone") }
                }
            }
            .themedList()
            .navigationTitle("Flight Plan")
            .onAppear {
                if pilotName.isEmpty { pilotName = UserDefaults.standard.string(forKey: "pilotName") ?? "" }
                if phone.isEmpty { phone = UserDefaults.standard.string(forKey: "pilotPhone") ?? "" }
            }
            .onChange(of: pilotName) { _, v in UserDefaults.standard.set(v, forKey: "pilotName") }
            .onChange(of: phone) { _, v in UserDefaults.standard.set(v, forKey: "pilotPhone") }
        }
    }

    private func icao(plan: FlightPlan, ac: AircraftProfile, calc: FlightCalc, endurance: Double) -> String {
        let dep = plan.departure?.ident ?? "ZZZZ"
        let dest = plan.destination?.ident ?? "ZZZZ"
        let route = plan.waypoints.dropFirst().dropLast().map { w -> String in
            if w.kind == .user {
                let la = abs(w.lat), lo = abs(w.lon)
                return String(format: "%02d%02d%@%03d%02d%@", Int(la), Int((la - floor(la)) * 60), w.lat >= 0 ? "N" : "S",
                              Int(lo), Int((lo - floor(lo)) * 60), w.lon >= 0 ? "E" : "W")
            }
            return w.ident
        }.joined(separator: " DCT ")
        let speed = String(format: "N%04d", Int(calc.cruiseTAS.rounded()))
        let level = String(format: "VFR")
        let ete = calc.totalTimeSec
        let eteStr = String(format: "%02d%02d", Int(ete) / 3600, (Int(ete) % 3600) / 60)
        let endStr = String(format: "%02d%02d", Int(endurance) / 3600, (Int(endurance) % 3600) / 60)
        let dofStr: String = { let f = DateFormatter(); f.dateFormat = "yyMMdd"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: plan.departureTime) }()
        var rmk = remarks.uppercased()
        if rmk.isEmpty { rmk = "NIL" }
        rmk += " CRZ ALT \(plan.cruiseAltitudeFt)"
        let pic = pilotName.trimmingCharacters(in: .whitespaces).uppercased()
        let supplementary = "-E/\(endStr) P/\(souls) R/V" + (pic.isEmpty ? "" : " C/\(pic)")
        var text = """
        (FPL-\(ac.tailNumber.uppercased())-VG
        -\(ac.icaoType)/L-\(ac.equipment)/\(ac.surveillance)
        -\(dep)\(Fmt.zulu.string(from: plan.departureTime).replacingOccurrences(of: "Z", with: ""))
        -\(speed)\(level) \(route.isEmpty ? "DCT" : "DCT \(route)")
        -\(dest)\(eteStr)
        -DOF/\(dofStr) RMK/\(rmk)
        \(supplementary))
        """
        text += "\nAircraft color: \(ac.color) · Home base: \(ac.homeBase)"
        if !phone.isEmpty { text += " · Pilot contact: \(phone)" }
        return text
    }
}

/// Weather along the route: METAR/TAF at departure & destination, METARs near the course, PIREPs.
struct RouteBriefingView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    @State private var tafs: [String: TAF] = [:]
    @State private var pireps: [PIREP] = []
    @State private var loaded = false

    var body: some View {
        if let plan = model.plans.first(where: { $0.id == planID }) {
            let coords = plan.waypoints.map(\.coordinate)
            List {
                ForEach([plan.departure, plan.destination].compactMap { $0 }, id: \.id) { w in
                    if let a = model.airport(w.ident) {
                        Section("\(w.id == plan.departure?.id ? "Departure" : "Destination") · \(a.displayIdent)") {
                            if let m = model.weather.metar(a.weatherIdent) {
                                METARCard(metar: m, fieldElevation: a.elevFt).listRowInsets(EdgeInsets())
                            } else { Text("No METAR").foregroundStyle(.secondary) }
                            if let t = tafs[a.weatherIdent] { Text(t.rawTAF).font(.system(.caption, design: .monospaced)) }
                        }
                    }
                }
                Section("Along the route (within 25 nm)") {
                    let near = model.weather.metars.values.filter { m in
                        guard coords.count >= 2 else { return false }
                        for i in 1..<coords.count {
                            let at = Geo.alongTrackNM(m.coordinate, from: coords[i - 1], to: coords[i])
                            if at >= -5, at <= Geo.distanceNM(coords[i - 1], coords[i]) + 5,
                               abs(Geo.crossTrackNM(m.coordinate, from: coords[i - 1], to: coords[i])) < 25 { return true }
                        }
                        return false
                    }.sorted { $0.icaoId < $1.icaoId }
                    if near.isEmpty { Text(loaded ? "No reports" : "Loading…").foregroundStyle(.secondary) }
                    ForEach(near) { m in
                        HStack(alignment: .top) {
                            Circle().fill(Theme.category(m.category)).frame(width: 10, height: 10).padding(.top, 4)
                            Text(m.rawOb).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Section("PIREPs (last 3 h)") {
                    if pireps.isEmpty { Text(loaded ? "None" : "Loading…").foregroundStyle(.secondary) }
                    ForEach(pireps) { p in Text(p.rawOb).font(.system(.caption, design: .monospaced)) }
                }
            }
            .themedList()
            .navigationTitle("Route Weather")
            .task {
                guard let r = Geo.region(around: coords, paddingFactor: 1.4) else { return }
                await model.weather.fetchMETARs(minLat: r.center.latitude - r.span.latitudeDelta / 2, minLon: r.center.longitude - r.span.longitudeDelta / 2,
                                                maxLat: r.center.latitude + r.span.latitudeDelta / 2, maxLon: r.center.longitude + r.span.longitudeDelta / 2)
                for w in [plan.departure, plan.destination].compactMap({ $0 }) {
                    if let a = model.airport(w.ident) {
                        await model.weather.fetchMETARs(ids: [a.weatherIdent])
                        if let t = await model.weather.tafs(a.weatherIdent).first { tafs[a.weatherIdent] = t }
                    }
                }
                pireps = await model.weather.pireps(near: r.center)
                loaded = true
            }
        }
    }
}
