import Foundation
import Observation

/// One FAA d-TPP chart.
struct Plate: Codable, Hashable, Identifiable {
    var id: String { pdf + "|" + name }
    let code: String     // APD, IAP, DP, ODP, STR, MIN, HOT, LAH, DAU
    let name: String
    let pdf: String

    var group: String {
        switch code {
        case "APD": return "Airport Diagram"
        case "IAP": return "Approaches"
        case "DP", "ODP": return "Departures"
        case "STR": return "Arrivals"
        case "MIN": return "Minimums"
        case "HOT": return "Hot Spots"
        case "LAH": return "LAHSO"
        default: return "Other"
        }
    }
    static let groupOrder = ["Airport Diagram", "Hot Spots", "Departures", "Arrivals", "Approaches", "Minimums", "LAHSO", "Other"]
}

private struct PlatesIndexFile: Codable {
    let cycle: String
    let effective: String
    let index: [String: [Plate]]
}

/// FAA digital Terminal Procedures Publication (d-TPP): cycle detection, metafile index and PDF cache.
@MainActor
@Observable
final class PlatesService {
    enum Status: Equatable { case idle, loading(String), ready, failed(String) }
    private(set) var status: Status = .idle
    private(set) var cycle: String = ""
    private(set) var effective: String = ""
    private var index: [String: [Plate]] = [:]

    var isReady: Bool { !index.isEmpty }
    var airportCount: Int { index.count }

    private var indexURL: URL { AppPaths.supportDir("plates").appendingPathComponent("index.json") }

    init() {
        if let d = try? Data(contentsOf: indexURL), let f = try? JSONDecoder().decode(PlatesIndexFile.self, from: d) {
            cycle = f.cycle; effective = f.effective; index = f.index; status = .ready
        }
    }

    func plates(for airport: Airport) -> [Plate] {
        for key in [airport.faa, airport.icao, airport.ident] where !key.isEmpty {
            if let p = index[key.uppercased()] { return p }
        }
        return []
    }

    func pdfURL(_ plate: Plate) -> URL {
        URL(string: "https://aeronav.faa.gov/d-tpp/\(cycle)/\(plate.pdf)")!
    }

    /// Download (or return cached) PDF for a plate.
    func localPDF(_ plate: Plate) async throws -> URL {
        let folder = AppPaths.cacheDir("plates-\(cycle)")
        let file = folder.appendingPathComponent(plate.pdf)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try await HTTP.download(pdfURL(plate), to: file)
        return file
    }

    /// Ask the FAA APRA API for the current d-TPP edition.
    nonisolated static func currentCycle() async -> (cycle: String, date: String)? {
        guard let url = URL(string: "https://external-api.faa.gov/apra/dtpp/info"),
              let d = try? await HTTP.data(url, timeout: 20),
              let xml = String(data: d, encoding: .utf8) else { return computedCycle() }
        func tag(_ name: String) -> String? {
            guard let r1 = xml.range(of: "<\(name)>"), let r2 = xml.range(of: "</\(name)>", range: r1.upperBound..<xml.endIndex) else { return nil }
            return String(xml[r1.upperBound..<r2.lowerBound])
        }
        guard let num = tag("editionNumber").flatMap({ Int($0) }), let date = tag("editionDate") else { return computedCycle() }
        let yy = date.split(separator: "/").last.map { String($0.suffix(2)) } ?? ""
        return (yy + String(format: "%02d", num), date)
    }

    /// Fallback: 28-day AIRAC arithmetic from a known cycle (2611 effective 29 Oct 2026).
    nonisolated static func computedCycle(for now: Date = Date()) -> (cycle: String, date: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let ref = cal.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        let days = Int(floor(now.timeIntervalSince(ref) / 86400))
        let steps = Int(floor(Double(days) / 28))
        let eff = cal.date(byAdding: .day, value: steps * 28, to: ref)!
        let year = cal.component(.year, from: eff)
        var number = 1
        var d = eff
        while true {
            let prev = cal.date(byAdding: .day, value: -28, to: d)!
            if cal.component(.year, from: prev) != year { break }
            number += 1
            d = prev
        }
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return (String(format: "%02d%02d", year % 100, number), f.string(from: eff))
    }

    func refreshIndex(force: Bool = false) async {
        if case .loading = status { return }
        status = .loading("Checking FAA cycle…")
        guard let current = await Self.currentCycle() else { status = .failed("Could not determine the d-TPP cycle"); return }
        if !force && current.cycle == cycle && !index.isEmpty { status = .ready; return }
        status = .loading("Downloading d-TPP index (≈16 MB)…")
        do {
            let url = URL(string: "https://aeronav.faa.gov/d-tpp/\(current.cycle)/xml_data/d-TPP_Metafile.xml")!
            let data = try await HTTP.data(url, timeout: 180)
            status = .loading("Indexing procedures…")
            let parsed = await Task.detached(priority: .userInitiated) { MetafileParser.parse(data) }.value
            guard !parsed.isEmpty else { status = .failed("d-TPP index was empty"); return }
            index = parsed
            cycle = current.cycle
            effective = current.date
            let file = PlatesIndexFile(cycle: cycle, effective: effective, index: index)
            if let d = try? JSONEncoder().encode(file) { try? d.write(to: indexURL, options: .atomic) }
            status = .ready
        } catch {
            status = index.isEmpty ? .failed(error.localizedDescription) : .ready
        }
    }
}

/// Streaming parser for d-TPP_Metafile.xml.
final class MetafileParser: NSObject, XMLParserDelegate {
    private var result: [String: [Plate]] = [:]
    private var aptIdent = "", icaoIdent = ""
    private var current: [String: String] = [:]
    private var text = ""
    private var inRecord = false

    static func parse(_ data: Data) -> [String: [Plate]] {
        let p = MetafileParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "airport_name":
            aptIdent = attributeDict["apt_ident"] ?? ""
            icaoIdent = attributeDict["icao_ident"] ?? ""
        case "record":
            inRecord = true
            current = [:]
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if inRecord {
            switch elementName {
            case "chart_code", "chart_name", "pdf_name", "useraction":
                current[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "record":
                inRecord = false
                if current["useraction"] == "D" { break }  // deleted this cycle
                if let code = current["chart_code"], let name = current["chart_name"], let pdf = current["pdf_name"], !pdf.isEmpty {
                    let plate = Plate(code: code, name: name, pdf: pdf)
                    if !aptIdent.isEmpty { result[aptIdent, default: []].append(plate) }
                    if !icaoIdent.isEmpty && icaoIdent != aptIdent { result[icaoIdent, default: []].append(plate) }
                }
            default: break
            }
        }
        text = ""
    }
}
