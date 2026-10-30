import SwiftUI

@main
struct PPLFlightApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await model.startup() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Maps", systemImage: "map.fill", value: AppTab.maps) { MapScreen() }
            Tab("Flights", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", value: AppTab.flights) { FlightsView() }
            Tab("Airports", systemImage: "airplane.circle.fill", value: AppTab.airports) { AirportsView() }
            Tab("Plates", systemImage: "doc.richtext.fill", value: AppTab.plates) { PlatesView() }
            if hSize == .compact {
                // iPhone: five tabs; the rest live in one More list (avoids nested navigation bars).
                Tab("More", systemImage: "ellipsis.circle.fill", value: AppTab.more) { MoreMenuView() }
            } else {
                Tab("Weather", systemImage: "cloud.sun.fill", value: AppTab.weather) { WeatherView() }
                Tab("Logbook", systemImage: "book.closed.fill", value: AppTab.logbook) { LogbookView() }
                Tab("Settings", systemImage: "gearshape.fill", value: AppTab.more) { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: hSize) { _, size in
            if size == .compact, model.selectedTab == .weather || model.selectedTab == .logbook { model.selectedTab = .more }
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep the screen awake while using the map in flight.
            UIApplication.shared.isIdleTimerDisabled = phase == .active && (model.flight.isAirborne || model.simulator.isRunning || model.selectedTab == .maps)
            model.location.enableBackground(model.recorder.isRecording)
        }
        .onChange(of: model.selectedTab) { _, tab in
            UIApplication.shared.isIdleTimerDisabled = tab == .maps || model.flight.isAirborne
        }
        .overlay(alignment: .top) {
            if case .downloading(let s) = model.db.status {
                HStack(spacing: 8) { ProgressView(); Text(s).font(.caption.weight(.semibold)) }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 4)
            }
        }
    }
}

/// Wraps content in a NavigationStack unless it is already pushed inside one.
struct OptionalNavigationStack<Content: View>: View {
    let embedded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
}

/// iPhone "More" tab: Weather, Logbook and Settings in one navigation stack.
struct MoreMenuView: View {
    enum Item: String, Hashable, CaseIterable, Identifiable {
        case weather = "Weather", logbook = "Logbook", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self { case .weather: "cloud.sun.fill"; case .logbook: "book.closed.fill"; case .settings: "gearshape.fill" }
        }
        var subtitle: String {
            switch self {
            case .weather: "METARs, winds aloft, prog charts"
            case .logbook: "Totals, PPL progress, track recorder"
            case .settings: "Home base, aircraft, offline charts"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(Item.allCases) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.rawValue).font(.headline)
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .themedList()
            .navigationTitle("More")
            .navigationDestination(for: Item.self) { item in
                switch item {
                case .weather: WeatherView(embedded: true)
                case .logbook: LogbookView(embedded: true)
                case .settings: SettingsView(embedded: true)
                }
            }
        }
    }
}
