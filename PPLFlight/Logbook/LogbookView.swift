import SwiftUI
import MapKit

/// Digital logbook with totals, 14 CFR 61.109 private pilot progress and track recording.
struct LogbookView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: LogEntry?
    var embedded = false

    var body: some View {
        @Bindable var model = model
        OptionalNavigationStack(embedded: embedded) {
            List {
                Section { RecorderCard(onSave: { editing = $0 }) }
                Section("Totals") { TotalsGrid(entries: model.logbook) }
                Section("Private pilot requirements · 14 CFR 61.109(a)") { PPLProgress(entries: model.logbook) }
                Section("Flights") {
                    if model.logbook.isEmpty { Text("No entries yet. Tap + or record a flight.").foregroundStyle(.secondary) }
                    ForEach(model.logbook.sorted { $0.date > $1.date }) { e in
                        Button { editing = e } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(e.from.isEmpty ? "—" : e.from) → \(e.to.isEmpty ? "—" : e.to)").font(.headline)
                                    Text("\(Fmt.dayMonth.string(from: e.date)) · \(e.aircraftType) \(e.tailNumber)").font(.caption).foregroundStyle(.secondary)
                                    if !e.remarks.isEmpty { Text(e.remarks).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(String(format: "%.1f", e.totalTime)).font(.title3.monospacedDigit().weight(.bold))
                                    Text(e.solo > 0 ? "SOLO" : (e.dualReceived > 0 ? "DUAL" : "")).font(.caption2.weight(.heavy)).foregroundStyle(e.solo > 0 ? .green : Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        let sorted = model.logbook.sorted { $0.date > $1.date }
                        let ids = idx.map { sorted[$0].id }
                        model.logbook.removeAll { ids.contains($0.id) }
                    }
                }
            }
            .themedList()
            .navigationTitle("Logbook")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        var e = LogEntry()
                        e.tailNumber = model.activeAircraft.tailNumber
                        e.from = model.homeAirport?.displayIdent ?? ""
                        e.to = e.from
                        editing = e
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: csv()) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(item: $editing) { e in
                NavigationStack { LogEntryEditor(entry: e) }
            }
            .onChange(of: model.pendingLogEntry) { _, e in
                if let e { editing = e; model.pendingLogEntry = nil }
            }
        }
    }

    private func csv() -> String {
        var s = "Date,Type,Tail,From,To,Route,Total,PIC,Dual,Solo,XC,SoloXC,Night,ActInst,SimInst,DayLdg,NightLdg,TowerLdg,Appr,Instructor,Remarks\n"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for e in model.logbook.sorted(by: { $0.date < $1.date }) {
            let fields: [String] = [df.string(from: e.date), e.aircraftType, e.tailNumber, e.from, e.to, e.route,
                                    String(e.totalTime), String(e.pic), String(e.dualReceived), String(e.solo), String(e.crossCountry), String(e.soloCrossCountry),
                                    String(e.night), String(e.actualInstrument), String(e.simulatedInstrument), String(e.dayLandings), String(e.nightLandings),
                                    String(e.towerLandings), String(e.approaches), e.instructor, e.remarks]
            s += fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        }
        return s
    }
}

struct RecorderCard: View {
    @Environment(AppModel.self) private var model
    let onSave: (LogEntry) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack {
                Image(systemName: model.recorder.isRecording ? "record.circle.fill" : "record.circle")
                    .font(.title2).foregroundStyle(model.recorder.isRecording ? .red : .secondary)
                VStack(alignment: .leading) {
                    Text(model.recorder.isRecording ? "Recording track · \(Fmt.hhmm(model.recorder.elapsed))" : "Track recorder").font(.headline)
                    Text(model.recorder.isRecording ? "\(model.recorder.points.count) points" : (model.settings.autoRecordTrack ? "Starts automatically above 35 kt" : "Manual start"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.recorder.isRecording {
                    Button("Stop & log") {
                        model.finishRecording()
                        if let e = model.pendingLogEntry { model.pendingLogEntry = nil; onSave(e) }
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("Start") { model.recorder.start() }.buttonStyle(.bordered)
                }
            }
        }
    }
}

struct TotalsGrid: View {
    let entries: [LogEntry]
    var body: some View {
        let sum = { (k: KeyPath<LogEntry, Double>) in entries.reduce(0) { $0 + $1[keyPath: k] } }
        let landings = entries.reduce(0) { $0 + $1.dayLandings + $1.nightLandings }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
            StatCell(label: "TOTAL", value: String(format: "%.1f", sum(\.totalTime)))
            StatCell(label: "DUAL", value: String(format: "%.1f", sum(\.dualReceived)))
            StatCell(label: "SOLO", value: String(format: "%.1f", sum(\.solo)))
            StatCell(label: "PIC", value: String(format: "%.1f", sum(\.pic)))
            StatCell(label: "XC", value: String(format: "%.1f", sum(\.crossCountry)))
            StatCell(label: "NIGHT", value: String(format: "%.1f", sum(\.night)))
            StatCell(label: "INSTR", value: String(format: "%.1f", sum(\.actualInstrument) + sum(\.simulatedInstrument)))
            StatCell(label: "LANDINGS", value: "\(landings)")
        }
    }
}

struct PPLProgress: View {
    let entries: [LogEntry]
    var body: some View {
        let sum = { (k: KeyPath<LogEntry, Double>) in entries.reduce(0) { $0 + $1[keyPath: k] } }
        let nightLdg = entries.reduce(0) { $0 + $1.nightLandings }
        let towerLdg = entries.filter { $0.solo > 0 }.reduce(0) { $0 + $1.towerLandings }
        let items: [(String, Double, Double, String)] = [
            ("Total flight time", sum(\.totalTime), 40, "h"),
            ("Dual received", sum(\.dualReceived), 20, "h"),
            ("Solo", sum(\.solo), 10, "h"),
            ("Solo cross-country", sum(\.soloCrossCountry), 5, "h"),
            ("Dual cross-country", min(sum(\.crossCountry), sum(\.dualReceived)), 3, "h"),
            ("Night (dual)", sum(\.night), 3, "h"),
            ("Night landings (full stop)", Double(nightLdg), 10, ""),
            ("Instrument (simulated)", sum(\.simulatedInstrument) + sum(\.actualInstrument), 3, "h"),
            ("Solo landings at towered airport", Double(towerLdg), 3, ""),
        ]
        VStack(spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.0).font(.subheadline)
                        Spacer()
                        Text(String(format: item.3.isEmpty ? "%.0f / %.0f" : "%.1f / %.0f %@", item.1, item.2, item.3))
                            .font(.caption.monospacedDigit()).foregroundStyle(item.1 >= item.2 ? .green : .secondary)
                    }
                    ProgressView(value: min(1, item.1 / item.2)).tint(item.1 >= item.2 ? .green : Theme.accent)
                }
            }
            Text("Also required: 3 h test prep with a CFI within 2 calendar months, one solo XC ≥ 150 nm with full-stop landings at 3 points (one leg ≥ 50 nm), and a night XC > 100 nm.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct LogEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var entry: LogEntry

    var body: some View {
        Form {
            Section("Flight") {
                DatePicker("Date", selection: $entry.date, displayedComponents: .date)
                field("Aircraft", "C172N", $entry.aircraftType)
                field("Tail number", "N12345", $entry.tailNumber)
                field("From", "KCNO", $entry.from)
                field("To", "KCNO", $entry.to)
                field("Route", "via PDZ BNG", $entry.route)
            }
            Section("Time (hours)") {
                hours("Total", $entry.totalTime)
                hours("Dual received", $entry.dualReceived)
                hours("Solo", $entry.solo)
                hours("PIC", $entry.pic)
                hours("Cross-country", $entry.crossCountry)
                hours("Solo cross-country", $entry.soloCrossCountry)
                hours("Night", $entry.night)
                hours("Simulated instrument", $entry.simulatedInstrument)
                hours("Actual instrument", $entry.actualInstrument)
            }
            Section("Landings") {
                Stepper("Day landings: \(entry.dayLandings)", value: $entry.dayLandings, in: 0...99)
                Stepper("Night landings: \(entry.nightLandings)", value: $entry.nightLandings, in: 0...99)
                Stepper("At towered airports: \(entry.towerLandings)", value: $entry.towerLandings, in: 0...99)
            }
            Section("Remarks") {
                TextField("Instructor name / certificate", text: $entry.instructor)
                TextField("Maneuvers, lesson notes…", text: $entry.remarks, axis: .vertical).lineLimit(3...8)
            }
            if let track = entry.track, track.count > 1 {
                Section("Track") {
                    TrackMap(points: track).frame(height: 220).listRowInsets(EdgeInsets())
                    Text("Max altitude \(Fmt.feet(track.map(\.altFt).max() ?? 0)) · max GS \(Int(track.map(\.gsKt).max() ?? 0)) kt").font(.caption)
                }
            }
        }
        .themedList()
        .navigationTitle("Log Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let i = model.logbook.firstIndex(where: { $0.id == entry.id }) { model.logbook[i] = entry } else { model.logbook.append(entry) }
                    dismiss()
                }
            }
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    private func hours(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0.0", value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Stepper("", value: value, in: 0...24, step: 0.1).labelsHidden()
        }
    }
}

struct TrackMap: View {
    let points: [TrackPoint]
    var body: some View {
        Map(initialPosition: .region(Geo.region(around: points.map(\.coordinate), paddingFactor: 1.3) ?? MKCoordinateRegion())) {
            MapPolyline(coordinates: points.map(\.coordinate)).stroke(Theme.magenta, lineWidth: 3)
        }
        .mapStyle(.standard(emphasis: .muted))
    }
}
