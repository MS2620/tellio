import SwiftUI

/// Search with its own on-screen keyboard on the left, so results never sit
/// underneath it and the tab bar stays reachable. Selecting the search field
/// opens the system keyboard instead (useful for typing from an iPhone).
struct SearchView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var query = ""
    @State private var numbers = false
    @State private var movies: [TMDBItem] = []
    @State private var series: [TMDBItem] = []
    @State private var channels: [XtreamChannel] = []
    @State private var trendingMovies: [TMDBItem] = []
    @State private var trendingSeries: [TMDBItem] = []
    @State private var searching = false
    @State private var playback: PlaybackRequest?

    private static let letters: [String] = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
    private static let digits: [String] = "1234567890".map { String($0) } + ["-", "'", "&", ":", ".", "!"]

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasResults: Bool {
        !movies.isEmpty || !series.isEmpty || !channels.isEmpty
    }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 60) {
                keyboard
                    .frame(width: 480)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        results
                    }
                    .padding(.bottom, 60)
                }
            }
            .padding(.leading, 90)
            .padding(.top, 20)
            .background(AppBackground())
            .navigationDestination(for: TMDBItem.self) { item in
                DetailView(item: item)
            }
            .task(id: settings.tmdbToken) { await loadTrending() }
            .task(id: trimmed) { await search() }
            .fullScreenCover(item: $playback) { request in
                PlayerView(request: request).ignoresSafeArea()
            }
        }
    }

    // MARK: - Keyboard

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Search channels, movies and series", text: $query)
                .autocorrectionDisabled()

            HStack(spacing: 12) {
                Button {
                    numbers = false
                } label: {
                    PillLabel(title: "abc", selected: !numbers)
                }
                .buttonStyle(PlainPressStyle())
                Button {
                    numbers = true
                } label: {
                    PillLabel(title: "123", selected: numbers)
                }
                .buttonStyle(PlainPressStyle())
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 8), count: 6),
                      alignment: .leading, spacing: 8) {
                ForEach(numbers ? Self.digits : Self.letters, id: \.self) { key in
                    Button {
                        query.append(key)
                    } label: {
                        KeyLabel(text: key)
                    }
                    .buttonStyle(PlainPressStyle())
                }
            }

            HStack(spacing: 12) {
                Button {
                    query.append(" ")
                } label: {
                    PillLabel(title: String(localized: "Space"))
                }
                .buttonStyle(PlainPressStyle())
                Button {
                    if !query.isEmpty { query.removeLast() }
                } label: {
                    PillLabel(title: String(localized: "Delete"), icon: "delete.left")
                }
                .buttonStyle(PlainPressStyle())
                Button {
                    query = ""
                } label: {
                    PillLabel(title: String(localized: "Clear"))
                }
                .buttonStyle(PlainPressStyle())
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if trimmed.count < 2 {
            if !settings.prefs.recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent").font(.title3).bold()
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(settings.prefs.recentSearches, id: \.self) { recent in
                                Button {
                                    query = recent
                                } label: {
                                    PillLabel(title: recent, selected: true)
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                            Button {
                                settings.prefs.recentSearches = []
                            } label: {
                                PillLabel(title: String(localized: "Clear"), icon: "xmark")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                        .padding(.vertical, 10)
                    }
                    .focusRow()
                    .scrollClipDisabled()
                }
            }
            if !trendingMovies.isEmpty {
                RailView(title: String(localized: "Trending Movies"), items: trendingMovies, inset: 0)
            }
            if !trendingSeries.isEmpty {
                RailView(title: String(localized: "Trending Series"), items: trendingSeries, inset: 0)
            }
        } else if hasResults {
            if !movies.isEmpty { RailView(title: String(localized: "Movies"), items: movies, inset: 0) }
            if !series.isEmpty { RailView(title: String(localized: "Series"), items: series, inset: 0) }
            if !channels.isEmpty { channelRow }
        } else if searching {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            Text("No results for “\(trimmed)”")
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    private var channelRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Channels")
                .font(.title3).bold()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                        Button {
                            play(index)
                        } label: {
                            ChannelTile(channel: channel)
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }
                .padding(.vertical, 30)
            }
            .focusRow()
            .scrollClipDisabled()
        }
    }

    // MARK: - Loading

    private func loadTrending() async {
        guard !settings.tmdbToken.isEmpty else { return }
        let tmdb = settings.tmdb
        async let films = tmdb.trending(.movie)
        async let shows = tmdb.trending(.tv)
        trendingMovies = (try? await films) ?? []
        trendingSeries = (try? await shows) ?? []
    }

    private func search() async {
        let text = trimmed
        // Clearing (or a single letter) empties the old results straight away.
        guard text.count >= 2 else {
            movies = []
            series = []
            channels = []
            searching = false
            return
        }
        searching = true
        // Debounce typing; a newer keystroke cancels this task.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        async let catalogue = searchCatalogue(text)
        async let live = searchChannels(text)
        let (items, foundChannels) = await (catalogue, live)

        // Ignore results for a query the user has already changed.
        guard !Task.isCancelled, text == trimmed else { return }
        movies = items.filter { $0.kind == .movie }
        series = items.filter { $0.kind == .tv }
        channels = foundChannels
        searching = false

        // Remember searches that found something, once typing has stopped.
        guard hasResults, text.count >= 3 else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, text == trimmed else { return }
        var recent = settings.prefs.recentSearches.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        recent.insert(text, at: 0)
        settings.prefs.recentSearches = Array(recent.prefix(6))
    }

    private func searchCatalogue(_ text: String) async -> [TMDBItem] {
        guard !settings.tmdbToken.isEmpty else { return [] }
        return (try? await settings.tmdb.search(text)) ?? []
    }

    private func searchChannels(_ text: String) async -> [XtreamChannel] {
        guard settings.xtream.isConfigured else { return [] }
        let all = (try? await XtreamCache.shared.liveStreams(settings.xtreamClient)) ?? []
        return Array(all.filter { settings.isVisible($0) && $0.name.localizedCaseInsensitiveContains(text) }.prefix(40))
    }

    private func play(_ index: Int) {
        let client = settings.xtreamClient
        let channel = channels[index]
        guard let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { return }
        playback = PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            sourceName: String(localized: "Search"),
            isLive: true,
            httpHeaders: client.requestHeaders,
            live: LiveContext(channels: channels, index: index)
        )
    }
}

/// One key of the search keyboard.
private struct KeyLabel: View {
    let text: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(.system(size: 38, weight: .medium))
            .foregroundStyle(isFocused ? Theme.ink : Color.white)
            .frame(width: 72, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
