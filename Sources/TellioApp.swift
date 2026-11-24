import SwiftUI

@main
struct TellioApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var player = PlayerEngineHolder()

    init() {
        // As early as possible, so a crash during launch is still caught.
        CrashReporting.apply(enabled: Preferences.load().crashReports)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(player)
                .preferredColorScheme(.dark)
        }
    }
}

enum AppTab: Hashable {
    case home, movies, series, live, sports, calendar, search, settings
}

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerEngineHolder
    @State private var tab: AppTab = .home
    /// A channel opened from a reminder.
    @State private var reminderPlayback: PlaybackRequest?
    /// Opened from a Top Shelf card.
    @State private var deepLink: DeepLink?
    @ObservedObject private var multiview = MultiviewStore.shared

    var body: some View {
        tabs
            // Reminders slide in over every tab; the player shows its own while it's open.
            .overlay {
                if !player.isPresentingPlayer {
                    ReminderBanner { reminder in
                        reminderPlayback = .liveChannel(reminder.channel, settings: settings)
                    }
                }
            }
            .task { await ReminderStore.shared.run() }
            .task {
                TraktSync.shared.attach(settings)
                await TraktSync.shared.run()
            }
            .fullScreenCover(item: $reminderPlayback) { request in
                PlayerView(request: request).ignoresSafeArea()
            }
            .background {
                // A separate view, so this cover doesn't clash with the reminder one.
                Color.clear
                    .fullScreenCover(item: $deepLink) { link in
                        NavigationStack {
                            switch link {
                            case .resume(let target): StreamListView(target: target)
                            case .match(let fixture): FixtureDetailView(fixture: fixture)
                            case .title(let item):
                                DetailView(item: item)
                                    .navigationDestination(for: TMDBItem.self) { DetailView(item: $0) }
                            }
                        }
                    }
            }
            .background {
                Color.clear
                    .fullScreenCover(isPresented: $multiview.presented) {
                        MultiviewView()
                    }
            }
            .background {
                // First-run setup, once. Closes itself when setupDone is set.
                Color.clear
                    .fullScreenCover(isPresented: Binding(get: { !settings.prefs.setupDone },
                                                          set: { if !$0 { settings.prefs.setupDone = true } })) {
                        SetupView()
                    }
            }
            .onOpenURL { url in
                deepLink = DeepLink(url: url)
            }
            .task { await TopShelfPublisher.start(settings) }
            // My List changes go straight to the shelf.
            .onChange(of: settings.prefs.myList) { _, _ in TopShelfPublisher.publish() }
            .onChange(of: settings.prefs.topShelfExtra) { _, _ in TopShelfPublisher.publish() }
            .overlay {
                if !player.isPresentingPlayer { UpdateCard() }
            }
            .task { await UpdateChecker.shared.check() }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab(String(localized: "tab.home", defaultValue: "Home", comment: "Tab bar: keep it short, or the icon tabs are pushed off the bar"), systemImage: "house", value: AppTab.home) {
                CatalogView(mode: .home)
            }
            Tab(String(localized: "tab.movies", defaultValue: "Movies", comment: "Tab bar: keep it short, or the icon tabs are pushed off the bar"), systemImage: "film", value: AppTab.movies) {
                CatalogView(mode: .movies)
            }
            Tab(String(localized: "tab.series", defaultValue: "Series", comment: "Tab bar: keep it short, or the icon tabs are pushed off the bar"), systemImage: "play.tv", value: AppTab.series) {
                CatalogView(mode: .series)
            }
            Tab(String(localized: "tab.liveTV", defaultValue: "Live TV", comment: "Tab bar: keep it short, or the icon tabs are pushed off the bar"), systemImage: "antenna.radiowaves.left.and.right", value: AppTab.live) {
                LiveTVView()
            }
            // Sports, Calendar, Search and Settings show only their icon, which keeps the bar on one line.
            // The text tabs have their own short translations (tab.*) for the same reason.
            Tab(value: AppTab.sports) {
                SportsView()
            } label: {
                Image(systemName: "sportscourt")
                    .accessibilityLabel("Sports")
            }
            Tab(value: AppTab.calendar) {
                CalendarView()
            } label: {
                Image(systemName: "calendar")
                    .accessibilityLabel("Calendar")
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("Search")
            }
            Tab(value: AppTab.settings) {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
            }
        }
    }
}
