import SwiftUI
import PDFKit
import CoreLocation

/// Plates tab: pick an airport, browse its procedures.
struct PlatesView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var airportID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $airportID) {
                PlatesStatusRow()
                if !query.isEmpty {
                    ForEach(model.db.index?.search(query, near: model.homeAirport?.coordinate, limit: 30) ?? [], id: \.ident) { a in
                        AirportRow(airport: a).tag(a.ident)
                    }
                } else {
                    let routeAirports = model.routeWaypoints.filter { $0.kind == .airport }.compactMap { model.airport($0.ident) }
                    if !routeAirports.isEmpty {
                        Section("Route") { ForEach(routeAirports.removingDuplicates(), id: \.ident) { AirportRow(airport: $0).tag($0.ident) } }
                    }
                    if let home = model.homeAirport { Section("Home base") { AirportRow(airport: home).tag(home.ident) } }
                    let favs = model.settings.favorites.compactMap { model.airport($0) }
                    if !favs.isEmpty { Section("Favorites") { ForEach(favs, id: \.ident) { AirportRow(airport: $0).tag($0.ident) } } }
                    let recents = model.settings.recentAirports.compactMap { model.airport($0) }
                    if !recents.isEmpty { Section("Recent") { ForEach(recents, id: \.ident) { AirportRow(airport: $0).tag($0.ident) } } }
                }
            }
            .searchable(text: $query, prompt: "Airport")
            .themedList()
            .navigationTitle("Plates")
        } detail: {
            NavigationStack {
                if let id = airportID, let a = model.airport(id) {
                    ScrollView { ProcedureTab(airport: a).padding() }
                        .background(Theme.navy)
                        .navigationTitle("\(a.displayIdent) Procedures")
                } else {
                    ContentUnavailableView("Choose an airport", systemImage: "doc.richtext", description: Text("FAA d-TPP airport diagrams, approaches, departures and arrivals."))
                }
            }
        }
    }
}

struct PlatesStatusRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.plates.status {
        case .loading(let s):
            HStack { ProgressView(); Text(s).font(.caption) }
        case .failed(let e):
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(e).font(.caption)
                Spacer()
                Button("Retry") { Task { await model.plates.refreshIndex(force: true) } }
            }
        case .ready:
            Text("d-TPP cycle \(model.plates.cycle) · effective \(model.plates.effective)").font(.caption).foregroundStyle(.secondary)
        case .idle:
            Button("Download procedures index") { Task { await model.plates.refreshIndex() } }
        }
    }
}

struct ProcedureTab: View {
    @Environment(AppModel.self) private var model
    let airport: Airport

    var body: some View {
        let plates = model.plates.plates(for: airport)
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                TaxiDiagramView(airport: airport)
            } label: {
                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text("Taxi Map (GPS)").font(.headline)
                        Text("Vector taxiways & hold lines with your position").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            if plates.isEmpty {
                if model.plates.isReady {
                    Text("No FAA terminal procedures are published for \(airport.displayIdent).").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    PlatesStatusRow()
                }
            }
            let groups = Dictionary(grouping: plates, by: \.group)
            ForEach(Plate.groupOrder.filter { groups[$0] != nil }, id: \.self) { g in
                VStack(alignment: .leading, spacing: 0) {
                    Text(g.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.bottom, 6)
                    ForEach(groups[g]!, id: \.id) { p in
                        NavigationLink {
                            PlateViewer(airport: airport, plate: p)
                        } label: {
                            HStack {
                                Image(systemName: p.code == "APD" ? "location.viewfinder" : "doc.text").foregroundStyle(p.code == "APD" ? .green : Theme.accent)
                                Text(p.name).font(.subheadline).multilineTextAlignment(.leading)
                                Spacer()
                                if p.code == "APD" { Text("GEO").font(.caption2.weight(.heavy)).padding(3).background(.green.opacity(0.25), in: Capsule()) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.3)
                    }
                }
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            if model.plates.isReady {
                Text("FAA d-TPP cycle \(model.plates.cycle). Verify currency before use.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// PDF plate viewer with geo-referenced ownship on airport diagrams.
struct PlateViewer: View {
    @Environment(AppModel.self) private var model
    let airport: Airport
    let plate: Plate
    @State private var url: URL?
    @State private var error: String?
    @State private var georef: PlateGeoref?
    @State private var georefChecked = false
    @State private var rotation = 0

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            if let url {
                PDFKitView(url: url, rotation: rotation, georef: georef, ownship: ownship) { page in
                    if !georefChecked {
                        georefChecked = true
                        georef = PlateGeoref.detect(page: page)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            } else if let error {
                ContentUnavailableView("Couldn't load plate", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Downloading \(plate.pdf)…")
            }
        }
        .navigationTitle(plate.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if georefChecked {
                    Label(georef != nil ? "Geo-referenced" : "Not geo-referenced", systemImage: georef != nil ? "location.fill.viewfinder" : "location.slash")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(georef != nil ? .green : .secondary)
                }
                Button { rotation = (rotation + 90) % 360 } label: { Image(systemName: "rotate.right") }
                if let url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
            }
        }
        .task {
            do { url = try await model.plates.localPDF(plate) } catch { self.error = error.localizedDescription }
        }
    }

    private var ownship: (CLLocationCoordinate2D, Double)? {
        guard model.flight.hasPosition, let c = model.flight.coordinate else { return nil }
        guard Geo.distanceNM(c, airport.coordinate) < 8 else { return nil }
        return (c, model.flight.trackTrue)
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    var rotation: Int
    var georef: PlateGeoref?
    var ownship: (CLLocationCoordinate2D, Double)?
    var onLoad: (PDFPage) -> Void

    final class Coordinator {
        var loadedURL: URL?
        var annotation: OwnshipPDFAnnotation?
        var baseRotation = 0
        var appliedRotation = -1
        var lastOwnshipUpdate = Date.distantPast
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePage
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(white: 0.12, alpha: 1)
        v.pageShadowsEnabled = true
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        let c = context.coordinator
        if c.loadedURL != url {
            c.loadedURL = url
            v.document = PDFDocument(url: url)
            if let page = v.document?.page(at: 0) {
                c.baseRotation = page.rotation
                DispatchQueue.main.async { onLoad(page) }
            }
        }
        guard let page = v.document?.page(at: 0) else { return }
        if c.appliedRotation != rotation {
            c.appliedRotation = rotation
            page.rotation = (c.baseRotation + rotation) % 360
            v.layoutDocumentView()
            v.autoScales = true
        }
        if let g = georef, let own = ownship {
            guard Date().timeIntervalSince(c.lastOwnshipUpdate) > 0.5 else { return }
            c.lastOwnshipUpdate = Date()
            let coord = own.0, trk = own.1
            let p = g.pagePoint(coord)
            let size: CGFloat = 26
            let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            let ann = c.annotation ?? OwnshipPDFAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
            ann.angle = g.pageAngle(forTrueBearing: trk, at: coord)
            if c.annotation != nil { page.removeAnnotation(ann) }
            ann.bounds = rect
            page.addAnnotation(ann)
            c.annotation = ann
        } else if let ann = c.annotation {
            page.removeAnnotation(ann)
            c.annotation = nil
        }
    }
}
