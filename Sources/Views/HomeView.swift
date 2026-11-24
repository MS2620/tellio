import SwiftUI

enum RailStyle { case poster, landscape, ranked }

/// One titled row, fetched lazily when it scrolls into view.
struct CatalogSection: Identifiable {
    let id: String
    var style: RailStyle = .poster
    let fetch: (TMDBClient) async throws -> [TMDBItem]
}

enum Catalog {
    /// The TMDB-backed Home rows (My List, channels and teams are built separately).
    static func homeSection(_ row: HomeRow) -> CatalogSection? {
        switch row {
        case .trending:
            return CatalogSection(id: row.title, style: .landscape) { try await $0.trendingAll() }
        case .popularMovies:
            return CatalogSection(id: row.title) { try await $0.popular(.movie) }
        case .popularSeries:
            return CatalogSection(id: row.title) { try await $0.popular(.tv) }
        case .cinemas:
            return CatalogSection(id: row.title, style: .landscape) { try await $0.list("movie/now_playing", type: .movie) }
        case .airingToday:
            return CatalogSection(id: row.title) { try await $0.list("tv/airing_today", type: .tv) }
        case .topRated:
            return CatalogSection(id: row.title) { try await $0.list("movie/top_rated", type: .movie) }
        case .myList, .channels, .teams:
            return nil
        }
    }

    private static let movieGenres: [(String, Int)] = [
        (String(localized: "Action"), 28), (String(localized: "Comedy"), 35), (String(localized: "Thriller"), 53), (String(localized: "Horror"), 27),
        (String(localized: "Science Fiction"), 878), (String(localized: "Drama"), 18), (String(localized: "Animation"), 16), (String(localized: "Family"), 10751),
        (String(localized: "Crime"), 80), (String(localized: "Romance"), 10749), (String(localized: "Documentary"), 99),
    ]

    private static let seriesGenres: [(String, Int)] = [
        (String(localized: "Drama"), 18), (String(localized: "Comedy"), 35), (String(localized: "Crime"), 80), (String(localized: "Action & Adventure"), 10759),
        (String(localized: "Sci-Fi & Fantasy"), 10765), (String(localized: "Mystery"), 9648), (String(localized: "Animation"), 16),
        (String(localized: "Documentary"), 99), (String(localized: "Reality"), 10764), (String(localized: "Kids"), 10762),
    ]

    static let trendingMovies = CatalogSection(id: String(localized: "Trending Movies"), style: .ranked) { try await $0.trending(.movie) }
    static let trendingSeries = CatalogSection(id: String(localized: "Trending Series"), style: .ranked) { try await $0.trending(.tv) }

    static let movies: [CatalogSection] = [
        CatalogSection(id: String(localized: "Popular")) { try await $0.popular(.movie) },
        CatalogSection(id: String(localized: "Now Playing"), style: .landscape) { try await $0.list("movie/now_playing", type: .movie) },
        CatalogSection(id: String(localized: "Upcoming")) { try await $0.list("movie/upcoming", type: .movie) },
        CatalogSection(id: String(localized: "Top Rated")) { try await $0.list("movie/top_rated", type: .movie) },
    ] + movieGenres.map { name, id in
        CatalogSection(id: name) { try await $0.discover(.movie, genre: id) }
    }

    static let series: [CatalogSection] = [
        CatalogSection(id: String(localized: "Popular")) { try await $0.popular(.tv) },
        CatalogSection(id: String(localized: "Airing Today"), style: .landscape) { try await $0.list("tv/airing_today", type: .tv) },
        CatalogSection(id: String(localized: "On The Air")) { try await $0.list("tv/on_the_air", type: .tv) },
        CatalogSection(id: String(localized: "Top Rated")) { try await $0.list("tv/top_rated", type: .tv) },
    ] + seriesGenres.map { name, id in
        CatalogSection(id: name) { try await $0.discover(.tv, genre: id) }
    }
}

// MARK: - Hero

/// What the big banner at the top shows: always the card that has focus.
struct HeroContent: Equatable {
    var key: String
    var kicker: String
    var title: String
    var chips: [String] = []
    var overview: String = ""
    var imageURL: URL? = nil
}

extension HeroContent {
    init(item: TMDBItem, row: String) {
        var chips: [String] = []
        if let year = item.year { chips.append(year) }
        chips += item.genreNames
        if let rating = item.rating { chips.append("★ \(rating)") }
        self.init(key: "\(row)|\(item.uid)",
                  kicker: (item.kind == .movie ? String(localized: "MOVIE") : String(localized: "SERIES")) + " · " + row.uppercased(),
                  title: item.displayTitle,
                  chips: chips,
                  overview: item.overview ?? "",
                  imageURL: item.backdropURL)
    }
}

/// Used by the Home, Movies and Series tabs. The banner follows focus: moving
/// along a row swaps its artwork, title and details to the focused card.
struct CatalogView: View {
    enum Mode { case home, movies, series }

    @EnvironmentObject var settings: AppSettings
    let mode: Mode

    @State private var hero: HeroContent?
    @State private var pending: HeroContent?

    /// Height of the banner's text area; the rows scroll underneath it.
    private static let heroHeight: CGFloat = 590

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.base.ignoresSafeArea()

                if settings.tmdbToken.isEmpty {
                    ContentUnavailableView("Add a TMDB token", systemImage: "key",
                                           description: Text("Open Settings → Connections and paste your TMDB API Read Access Token."))
                } else {
                    HeroBackdrop(hero: hero)

                    VStack(alignment: .leading, spacing: 0) {
                        HeroInfo(hero: hero)
                            .frame(height: Self.heroHeight)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                rows
                            }
                            .padding(.bottom, 90)
                        }
                        .contentMargins(.horizontal, 0, for: .scrollContent)
                        .ignoresSafeArea()
                        // Rows scrolled past are cut off at the banner instead of running under its text.
                        .clipShape(Rectangle())
                    }
                    .ignoresSafeArea()
                }
            }
            .navigationDestination(for: TMDBItem.self) { item in
                DetailView(item: item)
            }
            .navigationDestination(for: Fixture.self) { fixture in
                FixtureDetailView(fixture: fixture)
            }
            .navigationDestination(for: StreamTarget.self) { target in
                StreamListView(target: target)
            }
            .navigationDestination(for: XtreamSeries.self) { series in
                ProviderSeriesView(series: series)
            }
            .task(id: defaultHeroKey) { await showFirstItem() }
            .task(id: pending?.key) {
                guard let next = pending else { return }
                // Wait a moment so skimming along a row doesn't flash every backdrop.
                if hero != nil {
                    try? await Task.sleep(for: .milliseconds(180))
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { hero = next }
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch mode {
        case .home:
            ContinueWatchingRow(onFocus: focus(in: "home:continue"))
                .id("home:continue")
            ForEach(settings.visibleHomeRows) { row in
                homeRow(row)
                    .id("home:" + row.rawValue)
            }
        case .movies:
            LazyRail(section: Catalog.trendingMovies, onFocus: focus(in: "trending"), onLoaded: loaded)
                .id("trending")
            MyListRow(kind: .movie, onFocus: focus(in: "mylist"))
                .id("mylist")
            if settings.prefs.showProviderMovies {
                ProviderMoviesRow(onFocus: focus(in: "provider"))
                    .id("provider")
            }
            ForEach(Catalog.movies) { section in
                LazyRail(section: section, onFocus: focus(in: "section:" + section.id), onLoaded: loaded)
                    .id("section:" + section.id)
            }
        case .series:
            MyListRow(kind: .tv, onFocus: focus(in: "mylist"))
                .id("mylist")
            LazyRail(section: Catalog.trendingSeries, onFocus: focus(in: "trending"), onLoaded: loaded)
                .id("trending")
            if settings.prefs.showProviderSeries {
                ProviderSeriesRow(onFocus: focus(in: "provider"))
                    .id("provider")
            }
            ForEach(Catalog.series) { section in
                LazyRail(section: section, onFocus: focus(in: "section:" + section.id), onLoaded: loaded)
                    .id("section:" + section.id)
            }
        }
    }

    @ViewBuilder
    private func homeRow(_ row: HomeRow) -> some View {
        let rowID = "home:" + row.rawValue
        switch row {
        case .myList:
            MyListRow(kind: nil, onFocus: focus(in: rowID))
        case .channels:
            FavouriteChannelsRow(onFocus: focus(in: rowID))
        case .teams:
            UpcomingFixturesRow(onFocus: focus(in: rowID))
        default:
            if let section = Catalog.homeSection(row) {
                LazyRail(section: section, onFocus: focus(in: rowID), onLoaded: loaded)
            }
        }
    }

    /// The focus handler for a row: the banner follows the focused card.
    private func focus(in row: String) -> (HeroContent) -> Void {
        { content in pending = content }
    }

    /// The first row to load fills the banner until something is focused.
    private func loaded(_ content: HeroContent) {
        if hero == nil && pending == nil { pending = content }
    }

    // MARK: Banner on open

    private var defaultHeroKey: String {
        "\(mode)|\(settings.tmdbToken.count)|\(settings.prefs.catalogueLanguageInUse)|\(settings.homeRowOrder.map(\.rawValue))"
    }

    private func myListItems(_ kind: MediaType?) -> [TMDBItem] {
        settings.prefs.myList.reversed().filter { kind == nil || $0.kind == kind }
    }

    /// Fills the banner with the first title of the first row as soon as the page
    /// opens, even when that row is below the visible area or not a catalogue row.
    private func showFirstItem() async {
        guard hero == nil, pending == nil, !settings.tmdbToken.isEmpty else { return }

        var sections: [CatalogSection] = []
        switch mode {
        case .home:
            if let entry = WatchHistory.shared.latestPerTitle.first(where: \.isResumable) {
                pending = ContinueWatchingRow.hero(for: entry)
                return
            }
            for row in settings.visibleHomeRows {
                if row == .myList, let first = myListItems(nil).first {
                    pending = HeroContent(item: first, row: String(localized: "My List"))
                    return
                }
                if let section = Catalog.homeSection(row) { sections.append(section) }
            }
        case .movies:
            sections = [Catalog.trendingMovies]
        case .series:
            if let first = myListItems(.tv).first {
                pending = HeroContent(item: first, row: String(localized: "My List"))
                return
            }
            sections = [Catalog.trendingSeries]
        }

        for section in sections {
            guard let items = try? await section.fetch(settings.tmdb), let first = items.first else { continue }
            if hero == nil, pending == nil {
                pending = HeroContent(item: first, row: section.id)
            }
            return
        }
    }
}

private struct HeroBackdrop: View {
    let hero: HeroContent?

    private static let height: CGFloat = 860

    var body: some View {
        ZStack(alignment: .top) {
            if let url = hero?.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .clipped()
                .id(url)
                .transition(.opacity)
            }

            // Fades the artwork into the page background at the bottom…
            LinearGradient(
                stops: [
                    .init(color: Theme.base.opacity(0), location: 0.3),
                    .init(color: Theme.base.opacity(0.78), location: 0.7),
                    .init(color: Theme.base, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Self.height)

            // …and darkens the left so the text stays readable.
            LinearGradient(colors: [Theme.base.opacity(0.85), Theme.base.opacity(0)],
                           startPoint: .leading, endPoint: .center)
                .frame(height: Self.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

private struct HeroInfo: View {
    let hero: HeroContent?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let hero {
                Text(hero.kicker)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                Text(hero.title)
                    .font(.system(size: 84, weight: .black))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 1300, alignment: .leading)
                if !hero.chips.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(hero.chips.enumerated()), id: \.offset) { _, chip in
                            Chip(text: chip)
                        }
                    }
                }
                if !hero.overview.isEmpty {
                    Text(hero.overview)
                        .font(.system(size: 26, weight: .medium))
                        .lineLimit(3)
                        .frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
        .padding(.leading, 90)
        .padding(.top, 150)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .id(hero?.key)
        .transition(.opacity)
    }
}

// MARK: - Rows

/// Saved titles, newest first.
private struct MyListRow: View {
    @EnvironmentObject var settings: AppSettings
    let kind: MediaType?
    let onFocus: (HeroContent) -> Void

    private var items: [TMDBItem] {
        settings.prefs.myList.reversed().filter { kind == nil || $0.kind == kind }
    }

    var body: some View {
        if items.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            RailView(title: String(localized: "My List"), items: items, onFocus: { item in
                onFocus(HeroContent(item: item, row: String(localized: "My List")))
            })
        }
    }
}

private struct LazyRail: View {
    @EnvironmentObject var settings: AppSettings
    let section: CatalogSection
    let onFocus: (HeroContent) -> Void
    var onLoaded: ((HeroContent) -> Void)? = nil

    @State private var items: [TMDBItem]?

    private var reloadKey: String {
        settings.tmdbToken + settings.prefs.catalogueLanguageInUse + settings.prefs.tmdbRegion
    }

    var body: some View {
        Group {
            if let items, !items.isEmpty {
                RailView(title: section.id, items: items, style: section.style, onFocus: { item in
                    onFocus(HeroContent(item: item, row: section.id))
                })
            } else if items == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.id).font(.title3).bold()
                    ProgressView().frame(height: section.style == .landscape ? 248 : 330)
                }
                .padding(.horizontal, 90)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: reloadKey) {
            do {
                let loaded = try await section.fetch(settings.tmdb)
                items = loaded
                if let first = loaded.first {
                    onLoaded?(HeroContent(item: first, row: section.id))
                }
            } catch {
                items = []
            }
        }
    }
}

/// A horizontal row of titles. Reports the focused title through `onFocus`.
/// Every card in a row carries this much empty space above it, and the row's
/// title is drawn there. Because the space belongs to the card, the Apple TV
/// scrolls it into view with the focused card, so the title can't end up
/// hidden under the banner.
enum RowLayout {
    static let titleSpace: CGFloat = 64
}

/// A row's heading, drawn in the space above its cards.
struct RowTitle: View {
    let text: String
    var inset: CGFloat = 90

    var body: some View {
        Text(text)
            .font(.title3).bold()
            .lineLimit(1)
            .padding(.leading, inset)
            .padding(.top, 4)
            .allowsHitTesting(false)
    }
}

struct RailView: View {
    let title: String
    let items: [TMDBItem]
    let style: RailStyle
    /// Left and right padding; smaller where the row sits inside a narrower pane.
    let inset: CGFloat
    let onFocus: ((TMDBItem) -> Void)?

    @FocusState private var focusedID: String?

    init(title: String, items: [TMDBItem], style: RailStyle = .poster, inset: CGFloat = 90,
         onFocus: ((TMDBItem) -> Void)? = nil) {
        self.title = title
        self.items = items
        self.style = style
        self.inset = inset
        self.onFocus = onFocus
    }

    @ViewBuilder
    private func card(_ item: TMDBItem, index: Int) -> some View {
        switch style {
        case .poster:
            PosterTile(item: item)
        case .landscape:
            BackdropCard(item: item)
        case .ranked:
            HStack(alignment: .bottom, spacing: 0) {
                Text("\(index + 1)")
                    .font(.system(size: 150, weight: .black))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 24)
                PosterTile(item: item)
            }
        }
    }

    var body: some View {
        Group {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(items.enumerated()), id: \.element.uid) { index, item in
                        NavigationLink(value: item) {
                            card(item, index: index)
                                .padding(.top, RowLayout.titleSpace)
                        }
                        .buttonStyle(PlainPressStyle())
                        .focused($focusedID, equals: item.uid)
                        .contextMenu { WatchedMenuItems(item: item) }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.bottom, 30)
            }
            .focusRow()
            .scrollClipDisabled()
            .overlay(alignment: .topLeading) {
                RowTitle(text: title, inset: inset)
            }
        }
        .onChange(of: focusedID) { _, id in
            guard let id, let item = items.first(where: { $0.uid == id }) else { return }
            onFocus?(item)
        }
    }
}

/// Long-press menu for a poster: mark a movie or a whole series watched or unwatched.
struct WatchedMenuItems: View {
    let item: TMDBItem
    @ObservedObject private var history = WatchHistory.shared

    var body: some View {
        let watched = history.isWatched(item)
        Button(watched ? "Mark as unwatched" : "Mark as watched") {
            if item.kind == .movie {
                // The IMDb id is filled in properly the next time the movie is played.
                let context = history.entry(item: item)?.context ?? WatchContext(item: item, imdbID: "")
                history.setWatched(!watched, context: context)
            } else {
                history.setSeriesWatched(!watched, item: item)
            }
        }
    }
}

/// Poster artwork only.
struct PosterCard: View {
    let item: TMDBItem
    @ObservedObject private var history = WatchHistory.shared

    var body: some View {
        poster
            .overlay(alignment: .topTrailing) {
                if history.isWatched(item) { WatchedTick(size: 36).padding(12) }
            }
    }

    private var poster: some View {
        AsyncImage(url: item.posterURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.gray.opacity(0.3)
                Text(item.displayTitle)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(width: 220, height: 330)
        .clipped()
    }
}

/// A poster with its title underneath; outlined while focused.
struct PosterTile: View {
    let item: TMDBItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusFrame {
                PosterCard(item: item)
            }
            Text(item.displayTitle)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
        }
    }
}

/// A wide 16:9 card with the title underneath, for headline rows.
struct BackdropCard: View {
    let item: TMDBItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusFrame(cornerRadius: 20) {
                AsyncImage(url: item.backdropURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.3)
                        Text(item.displayTitle).font(.caption).padding()
                    }
                }
                .frame(width: 440, height: 248)
                .clipped()
            }
            Text(item.displayTitle)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .frame(width: 440, alignment: .leading)
        }
    }
}

/// Any poster-shaped artwork with a title (provider films and series).
struct ArtTile: View {
    let imageURL: URL?
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusFrame {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.3)
                        Text(title).font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: 220, height: 330)
                .clipped()
            }
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
        }
    }
}

/// A channel logo card with its name underneath.
struct ChannelTile: View {
    let channel: XtreamChannel

    var body: some View {
        VStack(spacing: 12) {
            FocusFrame {
                ZStack {
                    Rectangle().fill(Theme.glass)
                    AsyncImage(url: channel.icon.flatMap { URL(string: $0) }) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "tv").font(.largeTitle)
                    }
                    .padding(28)
                }
                .frame(width: 300, height: 170)
            }
            Text(channel.name)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)
                .frame(width: 300)
        }
    }
}

// MARK: - Favourite channels (Home)

private struct FavouriteChannelsRow: View {
    @EnvironmentObject var settings: AppSettings
    let onFocus: (HeroContent) -> Void

    @State private var channels: [XtreamChannel] = []
    @State private var playback: PlaybackRequest?
    @FocusState private var focusedID: Int?

    var body: some View {
        Group {
            if !channels.isEmpty {
                ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                                Button {
                                    play(index)
                                } label: {
                                    ChannelTile(channel: channel)
                                        .padding(.top, RowLayout.titleSpace)
                                }
                                .buttonStyle(PlainPressStyle())
                                .focused($focusedID, equals: channel.id)
                            }
                        }
                        .padding(.horizontal, 90)
                        .padding(.bottom, 30)
                    }
                    .focusRow()
                    .scrollClipDisabled()
                    .overlay(alignment: .topLeading) {
                        RowTitle(text: String(localized: "Favourite Channels"), inset: 90)
                    }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: settings.prefs.favouriteChannelIDs) { await load() }
        .onChange(of: focusedID) { _, id in
            guard let id, let channel = channels.first(where: { $0.id == id }) else { return }
            onFocus(HeroContent(key: "channel-\(id)", kicker: String(localized: "LIVE TV · FAVOURITE CHANNEL"), title: channel.name))
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request).ignoresSafeArea()
        }
    }

    private func load() async {
        let favourites = settings.prefs.favouriteChannelIDs
        guard settings.xtream.isConfigured, !favourites.isEmpty else {
            channels = []
            return
        }
        let all = (try? await XtreamCache.shared.liveStreams(settings.xtreamClient)) ?? []
        channels = all.filter { favourites.contains($0.id) && settings.isVisible($0) }
    }

    private func play(_ index: Int) {
        let client = settings.xtreamClient
        let channel = channels[index]
        guard let url = client.liveURL(for: channel, format: settings.prefs.liveFormat) else { return }
        playback = PlaybackRequest(
            url: url,
            title: channel.name,
            artworkURL: channel.icon.flatMap { URL(string: $0) },
            sourceName: String(localized: "Favourites"),
            isLive: true,
            httpHeaders: client.requestHeaders,
            live: LiveContext(channels: channels, index: index)
        )
    }
}

// MARK: - My teams' next fixtures (Home)

private struct UpcomingFixturesRow: View {
    @EnvironmentObject var settings: AppSettings
    let onFocus: (HeroContent) -> Void

    @State private var fixtures: [Fixture] = []
    @FocusState private var focusedID: String?

    private var loadKey: String {
        settings.prefs.favouriteTeams.map(\.id).joined(separator: ",") + "|\(settings.prefs.sportsDaysAhead)"
    }

    var body: some View {
        Group {
            if !fixtures.isEmpty {
                ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(fixtures) { fixture in
                                NavigationLink(value: fixture) {
                                    FixtureTile(fixture: fixture, width: 440)
                                        .padding(.top, RowLayout.titleSpace)
                                }
                                .buttonStyle(PlainPressStyle())
                                .focused($focusedID, equals: fixture.id)
                            }
                        }
                        .padding(.horizontal, 90)
                        .padding(.bottom, 30)
                    }
                    .focusRow()
                    .scrollClipDisabled()
                    .overlay(alignment: .topLeading) {
                        RowTitle(text: String(localized: "My Teams"), inset: 90)
                    }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: loadKey) {
            let teams = settings.prefs.favouriteTeams
            let all = await SportsLoader.upcoming(teams: teams, days: settings.prefs.sportsDaysAhead)
            fixtures = Array(all.prefix(12))
        }
        .task { await LiveScores.shared.run() }
        .onChange(of: focusedID) { _, id in
            guard let id, let fixture = fixtures.first(where: { $0.id == id }) else { return }
            onFocus(HeroContent(key: "fixture-\(id)",
                                kicker: fixture.competition.uppercased(),
                                title: fixture.title,
                                chips: [DayFormat.label(fixture.guideTime), DayFormat.time(fixture.guideTime)],
                                overview: fixture.subtitle ?? ""))
        }
    }
}

// MARK: - Provider library rows

/// Recently added films from the IPTV provider's own library.
private struct ProviderMoviesRow: View {
    @EnvironmentObject var settings: AppSettings
    let onFocus: (HeroContent) -> Void

    @State private var movies: [XtreamVOD] = []
    @State private var playback: PlaybackRequest?
    @FocusState private var focusedID: Int?

    var body: some View {
        Group {
            if !movies.isEmpty {
                ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(movies) { movie in
                                Button {
                                    play(movie)
                                } label: {
                                    ArtTile(imageURL: movie.icon.flatMap { URL(string: $0) }, title: movie.name)
                                        .padding(.top, RowLayout.titleSpace)
                                }
                                .buttonStyle(PlainPressStyle())
                                .focused($focusedID, equals: movie.id)
                            }
                        }
                        .padding(.horizontal, 90)
                        .padding(.bottom, 30)
                    }
                    .focusRow()
                    .scrollClipDisabled()
                    .overlay(alignment: .topLeading) {
                        RowTitle(text: String(localized: "From Your Provider · Recently Added"), inset: 90)
                    }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: settings.xtream) {
            guard settings.xtream.isConfigured else { return }
            movies = (try? await XtreamCache.shared.recentMovies(settings.xtreamClient)) ?? []
        }
        .onChange(of: focusedID) { _, id in
            guard let id, let movie = movies.first(where: { $0.id == id }) else { return }
            onFocus(HeroContent(key: "vod-\(id)", kicker: String(localized: "MOVIE · FROM YOUR PROVIDER"), title: movie.name))
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request).ignoresSafeArea()
        }
    }

    private func play(_ movie: XtreamVOD) {
        let client = settings.xtreamClient
        guard let url = client.movieURL(for: movie) else { return }
        playback = PlaybackRequest(url: url, title: movie.name, sourceName: String(localized: "Provider"),
                                   httpHeaders: client.requestHeaders)
    }
}

/// Recently updated series from the IPTV provider's own library.
private struct ProviderSeriesRow: View {
    @EnvironmentObject var settings: AppSettings
    let onFocus: (HeroContent) -> Void

    @State private var series: [XtreamSeries] = []
    @FocusState private var focusedID: Int?

    var body: some View {
        Group {
            if !series.isEmpty {
                ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(series) { show in
                                NavigationLink(value: show) {
                                    ArtTile(imageURL: show.cover.flatMap { URL(string: $0) }, title: show.name)
                                        .padding(.top, RowLayout.titleSpace)
                                }
                                .buttonStyle(PlainPressStyle())
                                .focused($focusedID, equals: show.id)
                            }
                        }
                        .padding(.horizontal, 90)
                        .padding(.bottom, 30)
                    }
                    .focusRow()
                    .scrollClipDisabled()
                    .overlay(alignment: .topLeading) {
                        RowTitle(text: String(localized: "From Your Provider · Recently Updated"), inset: 90)
                    }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: settings.xtream) {
            guard settings.xtream.isConfigured else { return }
            series = (try? await XtreamCache.shared.recentSeries(settings.xtreamClient)) ?? []
        }
        .onChange(of: focusedID) { _, id in
            guard let id, let show = series.first(where: { $0.id == id }) else { return }
            onFocus(HeroContent(key: "pseries-\(id)", kicker: String(localized: "SERIES · FROM YOUR PROVIDER"),
                                title: show.name, overview: show.plot ?? ""))
        }
    }
}

/// Seasons and episodes of a series from the provider's library.
struct ProviderSeriesView: View {
    @EnvironmentObject var settings: AppSettings
    let series: XtreamSeries

    @State private var episodes: [XtreamEpisode] = []
    @State private var loading = true
    @State private var season: Int?
    @State private var playback: PlaybackRequest?

    private var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted()
    }

    private var shown: [XtreamEpisode] {
        episodes.filter { $0.season == season }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 40) {
                    AsyncImage(url: series.cover.flatMap { URL(string: $0) }) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.gray.opacity(0.3)
                    }
                    .frame(width: 220, height: 330)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 16) {
                        Text("SERIES · FROM YOUR PROVIDER")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.62))
                        Text(series.name)
                            .font(.system(size: 60, weight: .black))
                            .lineLimit(2)
                        if let plot = series.plot, !plot.isEmpty {
                            Text(plot)
                                .font(.system(size: 24, weight: .medium))
                                .lineLimit(5)
                                .frame(maxWidth: 1100, alignment: .leading)
                        }
                    }
                }

                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if episodes.isEmpty {
                    Text("No episodes found for this series.")
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(seasons, id: \.self) { number in
                                Button {
                                    season = number
                                } label: {
                                    PillLabel(title: String(localized: "Season \(number)"), selected: number == season)
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .focusRow()
                    .scrollClipDisabled()

                    GlassPanel("Episodes") {
                        ForEach(shown) { episode in
                            Button {
                                play(episode)
                            } label: {
                                ListRowLabel(title: "E\(episode.number) · \(episode.title)",
                                             subtitle: episode.plot,
                                             trailingIcon: "play.fill")
                            }
                            .buttonStyle(PlainPressStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .background(AppBackground())
        .task {
            episodes = (try? await settings.xtreamClient.seriesEpisodes(seriesID: series.id)) ?? []
            season = seasons.first
            loading = false
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request).ignoresSafeArea()
        }
    }

    private func play(_ episode: XtreamEpisode) {
        let client = settings.xtreamClient
        guard let url = client.episodeURL(for: episode) else { return }
        playback = PlaybackRequest(
            url: url,
            title: series.name,
            subtitle: "S\(episode.season)E\(episode.number) · \(episode.title)",
            overview: episode.plot,
            sourceName: String(localized: "Provider"),
            httpHeaders: client.requestHeaders
        )
    }
}


// MARK: - Continue Watching

/// Movies and episodes in progress, and the next episode of series being followed. First row on Home.
struct ContinueWatchingRow: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var history = WatchHistory.shared
    let onFocus: (HeroContent) -> Void

    @State private var nextEpisodes: [String: NextEpisode] = [:]
    @FocusState private var focusedID: String?

    struct NextEpisode: Hashable {
        let season: Int
        let episode: Int
        let name: String?
        let overview: String?
        let stillURL: URL?
        let isNew: Bool
    }

    struct Card: Identifiable {
        let id: String
        let entry: WatchEntry
        let target: StreamTarget
        let line: String
        let fraction: Double?
        let badge: String?
        let imageURL: URL?
        let hero: HeroContent
    }

    private var cards: [Card] {
        history.latestPerTitle.prefix(30).compactMap { entry -> Card? in
            let item = entry.item
            let imdbID = entry.context.imdbID
            guard !imdbID.isEmpty else { return nil }
            if entry.isResumable {
                let target: StreamTarget
                if let season = entry.context.season, let episode = entry.context.episode {
                    target = .episode(item: item, imdbID: imdbID, season: season, episode: episode,
                                      name: entry.context.episodeName, overview: nil)
                } else {
                    target = .movie(item: item, imdbID: imdbID)
                }
                let line = [entry.episodeLabel, entry.timeLeftLabel].compactMap { $0 }.joined(separator: " · ")
                return Card(id: entry.id, entry: entry, target: target, line: line, fraction: entry.fraction,
                            badge: nil, imageURL: item.backdropURL, hero: Self.hero(for: entry))
            }
            // A finished episode: offer the next one, once it has aired.
            guard entry.watched, entry.context.season != nil,
                  !history.dismissedNextUp.contains(item.uid),
                  let next = nextEpisodes[entry.id] else { return nil }
            let target = StreamTarget.episode(item: item, imdbID: imdbID, season: next.season, episode: next.episode,
                                              name: next.name, overview: next.overview)
            let hero = HeroContent(key: "continue|\(item.uid)|next",
                                   kicker: String(localized: "CONTINUE WATCHING · UP NEXT"),
                                   title: item.displayTitle,
                                   chips: ["S\(next.season) · E\(next.episode)"] + [next.name].compactMap { $0 },
                                   overview: next.overview ?? item.overview ?? "",
                                   imageURL: item.backdropURL)
            return Card(id: "next-\(item.uid)", entry: entry, target: target,
                        line: String(localized: "Next: S\(next.season) · E\(next.episode)"), fraction: nil,
                        badge: next.isNew ? String(localized: "NEW EPISODE") : String(localized: "UP NEXT"),
                        imageURL: next.stillURL ?? item.backdropURL, hero: hero)
        }
        .prefix(20)
        .map { $0 }
    }

    static func hero(for entry: WatchEntry) -> HeroContent {
        var chips = [entry.episodeLabel, entry.timeLeftLabel].compactMap { $0 }
        if let name = entry.context.episodeName { chips.append(name) }
        return HeroContent(key: "continue|\(entry.id)",
                           kicker: String(localized: "CONTINUE WATCHING"),
                           title: entry.item.displayTitle,
                           chips: chips,
                           overview: entry.item.overview ?? "",
                           imageURL: entry.item.backdropURL)
    }

    /// The finished episodes whose next episode needs looking up.
    private var finishedKey: String {
        history.latestPerTitle.prefix(30)
            .filter { $0.watched && $0.context.season != nil }
            .map(\.id).joined(separator: ",")
    }

    var body: some View {
        let list = self.cards
        Group {
            if list.isEmpty {
                Color.clear.frame(height: 1)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(list) { card in
                            NavigationLink(value: card.target) {
                                ContinueCard(card: card)
                                    .padding(.top, RowLayout.titleSpace)
                            }
                            .buttonStyle(PlainPressStyle())
                            .focused($focusedID, equals: card.id)
                            .contextMenu {
                                if card.fraction != nil {
                                    Button("Mark as watched") {
                                        history.setWatched(true, context: card.entry.context)
                                    }
                                }
                                Button("Remove from Continue Watching", role: .destructive) {
                                    history.remove(card.entry.item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.bottom, 30)
                }
                .focusRow()
                .scrollClipDisabled()
                .overlay(alignment: .topLeading) {
                    RowTitle(text: String(localized: "Continue Watching"), inset: 90)
                }
            }
        }
        .onChange(of: focusedID) { _, id in
            guard let id, let card = list.first(where: { $0.id == id }) else { return }
            onFocus(card.hero)
        }
        .task(id: finishedKey) { await loadNextEpisodes() }
    }

    /// Looks up the episode after each finished one: the rest of its season, then the next season's first.
    private func loadNextEpisodes() async {
        let finished = history.latestPerTitle.prefix(30).filter { $0.watched && $0.context.season != nil }
        guard !finished.isEmpty, !settings.tmdbToken.isEmpty else { return }
        let tmdb = settings.tmdb
        var found: [String: NextEpisode] = [:]
        let today = Self.dayFormatter.string(from: Date())
        let fortnightAgo = Self.dayFormatter.string(from: Date().addingTimeInterval(-14 * 86_400))
        for entry in finished.prefix(12) {
            guard let season = entry.context.season, let episode = entry.context.episode else { continue }
            func aired(_ ep: TVEpisode) -> Bool { (ep.airDate ?? "9999") <= today && !(ep.airDate ?? "").isEmpty }
            let thisSeason: [TVEpisode] = (try? await tmdb.episodes(tvID: entry.item.id, season: season)) ?? []
            var upcoming: TVEpisode? = thisSeason.first { $0.episodeNumber == episode + 1 }
            if upcoming == nil {
                let nextSeason: [TVEpisode] = (try? await tmdb.episodes(tvID: entry.item.id, season: season + 1)) ?? []
                upcoming = nextSeason.first { $0.episodeNumber == 1 }
            }
            guard let found1 = upcoming, aired(found1) else { continue }
            found[entry.id] = NextEpisode(season: found1.seasonNumber, episode: found1.episodeNumber,
                                          name: found1.name, overview: found1.overview, stillURL: found1.stillURL,
                                          isNew: (found1.airDate ?? "") >= fortnightAgo)
        }
        nextEpisodes = found
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// A wide card with a progress bar (or "UP NEXT"), the title and what's left.
private struct ContinueCard: View {
    let card: ContinueWatchingRow.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FocusFrame(cornerRadius: 20) {
                AsyncImage(url: card.imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.3)
                        Text(card.entry.item.displayTitle).font(.caption).padding()
                    }
                }
                .frame(width: 440, height: 248)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if let fraction = card.fraction {
                        ProgressStrip(fraction: fraction).padding(16)
                    } else if let badge = card.badge {
                        Text(badge)
                            .font(.system(size: 17, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(16)
                    }
                }
            }
            Text(card.entry.item.displayTitle)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1)
                .frame(width: 440, alignment: .leading)
            Text(card.line)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .frame(width: 440, alignment: .leading)
        }
    }
}
