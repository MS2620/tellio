import SwiftUI

/// New episodes of the series in My List: what's on today, then the next
/// episode or two of each series. Nothing that has already aired.
struct CalendarView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var entries: [CalendarEntry] = []
    @State private var loading = false

    struct CalendarEntry: Identifiable, Hashable {
        let show: TMDBItem
        let episode: TVEpisode
        let date: Date
        var id: String { "\(show.id)-\(episode.id)" }
    }

    private var series: [TMDBItem] {
        settings.prefs.myList.filter { $0.kind == .tv }
    }

    private var loadKey: String {
        series.map { String($0.id) }.joined(separator: ",")
            + "|\(settings.tmdbToken.count)|\(settings.prefs.calendarEpisodesPerSeries)|\(settings.prefs.calendarDaysAhead)"
    }

    private var today: [CalendarEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var upcoming: [CalendarEntry] {
        entries.filter { !Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Calendar")
                            .font(.system(size: 44, weight: .heavy))
                        Text("New episodes from series in My List")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 90)
                    .padding(.top, 20)

                    if settings.tmdbToken.isEmpty {
                        message(String(localized: "Add your TMDB token in Settings → Connections to see release dates."))
                    } else if series.isEmpty {
                        message(String(localized: "Add series to My List (the ＋ My List button on a series) to see when their new episodes come out."))
                    } else if loading && entries.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if entries.isEmpty {
                        message(String(localized: "No new episodes coming up for the series in My List."))
                    }

                    if !today.isEmpty {
                        row(String(localized: "Today"), entries: today, showsDate: false)
                    }
                    if !upcoming.isEmpty {
                        row(String(localized: "Coming up"), entries: upcoming, showsDate: true)
                    }
                }
                .padding(.bottom, 60)
            }
            .background(AppBackground())
            .navigationDestination(for: TMDBItem.self) { item in
                DetailView(item: item)
            }
            .task(id: loadKey) { await load() }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 90)
            .padding(.top, 20)
    }

    private func row(_ title: String, entries: [CalendarEntry], showsDate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3).bold()
                .padding(.horizontal, 90)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.show) {
                            CalendarEpisodeCard(entry: entry, showsDate: showsDate)
                        }
                        .buttonStyle(PlainPressStyle())
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 30)
            }
            .focusRow()
            .scrollClipDisabled()
        }
    }

    // MARK: - Loading

    private func load() async {
        guard !settings.tmdbToken.isEmpty, !series.isEmpty else {
            entries = []
            return
        }
        loading = true
        defer { loading = false }

        let tmdb = settings.tmdb
        let perSeries = max(1, settings.prefs.calendarEpisodesPerSeries)
        let today = Calendar.current.startOfDay(for: Date())
        let until = Calendar.current.date(byAdding: .day, value: settings.prefs.calendarDaysAhead, to: today) ?? today

        var found: [CalendarEntry] = []
        await withTaskGroup(of: [CalendarEntry].self) { group in
            for show in series {
                group.addTask {
                    await Self.entries(for: show, tmdb: tmdb, from: today, until: until, limit: perSeries)
                }
            }
            for await list in group { found += list }
        }

        entries = found.sorted { a, b in
            a.date != b.date ? a.date < b.date : a.show.displayTitle < b.show.displayTitle
        }
    }

    /// The next `limit` episodes of one series airing from today onwards.
    private static func entries(for show: TMDBItem, tmdb: TMDBClient,
                                from: Date, until: Date, limit: Int) async -> [CalendarEntry] {
        guard let details = try? await tmdb.tvDetails(id: show.id) else { return [] }

        // TMDB moves today's episode to "last aired" on the day, so check both.
        var seasons = Set<Int>()
        if let next = details.nextEpisodeToAir {
            seasons.insert(next.seasonNumber)
        }
        if let last = details.lastEpisodeToAir,
           let aired = DayFormat.parseDay(last.airDate), aired >= from {
            seasons.insert(last.seasonNumber)
        }
        guard !seasons.isEmpty else { return [] }

        var result: [CalendarEntry] = []
        for season in seasons.sorted() {
            let episodes = (try? await tmdb.episodes(tvID: show.id, season: season)) ?? []
            for episode in episodes {
                if let date = DayFormat.parseDay(episode.airDate), date >= from, date <= until {
                    result.append(CalendarEntry(show: show, episode: episode, date: date))
                }
            }
        }

        // If the season list had no dates, fall back to the next episode itself.
        if result.isEmpty, let next = details.nextEpisodeToAir,
           let date = DayFormat.parseDay(next.airDate), date >= from, date <= until {
            result.append(CalendarEntry(show: show, episode: next, date: date))
        }

        return Array(result.sorted { $0.date < $1.date }.prefix(limit))
    }
}

private struct CalendarEpisodeCard: View {
    let entry: CalendarView.CalendarEntry
    let showsDate: Bool

    private var detail: String {
        let episode = "S\(entry.episode.seasonNumber) E\(entry.episode.episodeNumber)"
        let name = entry.episode.name.map { " · \($0)" } ?? ""
        return showsDate ? "\(episode) · \(DayFormat.label(entry.date))" : episode + name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FocusFrame(cornerRadius: 20) {
                AsyncImage(url: entry.episode.stillURL ?? entry.show.backdropURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.3)
                        Image(systemName: "tv").font(.largeTitle)
                    }
                }
                .frame(width: 440, height: 248)
                .clipped()
            }

            Text(entry.show.displayTitle)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(width: 440, alignment: .leading)
    }
}
