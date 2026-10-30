import SwiftUI
import CoreLocation

/// Airports tab: search, favorites, recents and nearest airports.
struct AirportsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !model.db.isReady {
                    DatabaseStatusRow()
                }
                if !query.isEmpty {
                    Section("Results") {
                        ForEach(results, id: \.ident) { a in AirportRow(airport: a).tag(a.ident) }
                    }
                } else {
                    if !model.settings.favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(model.settings.favorites, id: \.self) { id in
                                if let a = model.airport(id) { AirportRow(airport: a).tag(a.ident) }
                            }
                        }
                    }
                    if let home = model.homeAirport {
                        Section("Home base") { AirportRow(airport: home).tag(home.ident) }
                    }
                    let near = nearest
                    if !near.isEmpty {
                        Section(model.flight.coordinate != nil ? "Nearest" : "Near \(model.homeAirport?.displayIdent ?? "home")") {
                            ForEach(near, id: \.airport.ident) { item in
                                AirportRow(airport: item.airport, distance: item.distance).tag(item.airport.ident)
                            }
                        }
                    }
                    if !model.settings.recentAirports.isEmpty {
                        Section("Recent") {
                            ForEach(model.settings.recentAirports, id: \.self) { id in
                                if let a = model.airport(id) { AirportRow(airport: a).tag(a.ident) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Identifier, name or city")
            .textInputAutocapitalization(.characters)
            .themedList()
            .navigationTitle("Airports")
            .task(id: nearestKey) {
                let ids = nearest.map { $0.airport.weatherIdent }
                if !ids.isEmpty { await model.weather.fetchMETARs(ids: ids) }
            }
        } detail: {
            if let id = selection, let a = model.airport(id) {
                AirportSheet(airport: a, compact: false)
                    .id(a.ident)
            } else {
                ContentUnavailableView("Select an airport", systemImage: "airplane.circle", description: Text("Search by identifier (KCNO, CNO), name or city."))
            }
        }
        .onChange(of: selection) { _, id in if let id { model.noteRecent(id) } }
    }

    private var results: [Airport] {
        model.db.index?.search(query, near: model.flight.coordinate ?? model.homeAirport?.coordinate) ?? []
    }

    private var nearestKey: String {
        let c = model.flight.coordinate ?? model.homeAirport?.coordinate
        return (c.map { String(format: "%.1f,%.1f", $0.latitude, $0.longitude) } ?? "") + "|\(model.db.airportCount)"
    }

    private var nearest: [(airport: Airport, distance: Double)] {
        guard let c = model.flight.coordinate ?? model.homeAirport?.coordinate else { return [] }
        return model.db.index?.nearestAirports(to: c, count: 15, maxNM: 50) ?? []
    }
}

struct AirportRow: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    var distance: Double? = nil

    var body: some View {
        let metar = model.weather.metar(airport.weatherIdent)
        HStack(spacing: 10) {
            Circle()
                .fill(metar.map { Theme.category($0.category) } ?? Color.gray.opacity(0.4))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(airport.displayIdent).font(.headline)
                    if airport.isTowered { Image(systemName: "dot.radiowaves.up.forward").font(.caption2).foregroundStyle(Theme.accent) }
                }
                Text(airport.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let d = distance { Text("\(Fmt.nm(d)) nm").font(.caption.monospacedDigit().weight(.semibold)) }
                Text("\(airport.city), \(airport.stateCode)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct DatabaseStatusRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            switch model.db.status {
            case .downloading(let s):
                ProgressView()
                Text(s)
            case .loading:
                ProgressView(); Text("Loading airport database…")
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Airport database not downloaded").font(.subheadline.weight(.semibold))
                    Text(e).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") { Task { await model.db.download() } }
            default:
                Image(systemName: "arrow.down.circle")
                Text("Airport database needed")
                Spacer()
                Button("Download") { Task { await model.db.download() } }
            }
        }
    }
}
