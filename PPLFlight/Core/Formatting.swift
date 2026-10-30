import Foundation
import SwiftUI

enum Fmt {
    static func ete(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    static func hhmm(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    static func nm(_ v: Double) -> String {
        guard v.isFinite else { return "--" }
        return v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }

    static func heading(_ v: Double) -> String {
        guard v.isFinite else { return "---" }
        var h = Int(Geo.norm360(v).rounded())
        if h == 0 { h = 360 }
        return String(format: "%03d°", h)
    }

    static func feet(_ v: Double) -> String {
        guard v.isFinite else { return "--" }
        return Int(v.rounded()).formatted(.number.grouping(.automatic)) + "'"
    }

    static func gallons(_ v: Double) -> String { String(format: "%.1f", v) }

    static let timeShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let zulu: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let zuluDayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd HHmm'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func age(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m ago" }
        return "\(Int(s / 86400))d ago"
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

/// ForeFlight-inspired dark navy palette.
enum Theme {
    static let navy = Color(red: 0.086, green: 0.122, blue: 0.188)
    static let navyLight = Color(red: 0.137, green: 0.184, blue: 0.267)
    static let panel = Color(red: 0.11, green: 0.153, blue: 0.231)
    static let accent = Color(red: 0.157, green: 0.722, blue: 1.0)
    static let magenta = Color(red: 1.0, green: 0.0, blue: 0.8)
    static let vfr = Color(red: 0.2, green: 0.8, blue: 0.3)
    static let mvfr = Color(red: 0.25, green: 0.5, blue: 1.0)
    static let ifr = Color(red: 0.95, green: 0.2, blue: 0.2)
    static let lifr = Color(red: 0.85, green: 0.2, blue: 0.85)
    static let hazardRed = Color(red: 0.92, green: 0.2, blue: 0.16)
    static let hazardYellow = Color(red: 0.96, green: 0.8, blue: 0.2)

    static func category(_ cat: String?) -> Color {
        switch cat?.uppercased() {
        case "VFR": return vfr
        case "MVFR": return mvfr
        case "IFR": return ifr
        case "LIFR": return lifr
        default: return .gray
        }
    }

    static func uiCategory(_ cat: String?) -> UIColor { UIColor(category(cat)) }
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))
    }
}

extension View {
    func panelStyle() -> some View { modifier(PanelBackground()) }
    /// Navy background for List / Form screens.
    func themedList() -> some View { scrollContentBackground(.hidden).background(Theme.navy) }
}

/// Small label/value cell used in data strips.
struct StatCell: View {
    let label: String
    let value: String
    var tint: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
