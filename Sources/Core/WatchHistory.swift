import Foundation

/// What is being watched: a movie, or one episode of a series.
struct WatchContext: Codable, Hashable {
    let item: TMDBItem
    let imdbID: String
    var season: Int? = nil
    var episode: Int? = nil
    var episodeName: String? = nil

    var key: String { WatchHistory.key(item: item, season: season, episode: episode) }

    /// The addon id: "tt0903747" for a movie, "tt0903747:1:2" for an episode.
    var stremioType: String { item.kind == .movie ? "movie" : "series" }
    var stremioID: String {
        guard let season, let episode else { return imdbID }
        return "\(imdbID):\(season):\(episode)"
    }
}

/// Where a movie or episode was left, and whether it has been watched.
struct WatchEntry: Codable, Hashable, Identifiable {
    var context: WatchContext
    var position: Double
    var duration: Double
    var updated: Date
    var watched: Bool

    var id: String { context.key }
    var item: TMDBItem { context.item }
    var remaining: Double { max(duration - position, 0) }
    var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }

    /// Started, not finished: worth offering to resume.
    var isResumable: Bool {
        position >= WatchHistory.minimumProgress && fraction < WatchHistory.watchedFraction
    }

    /// "23 min left", "1 h 12 min left".
    var timeLeftLabel: String {
        let minutes = max(Int((remaining / 60).rounded()), 1)
        return minutes >= 60 ? String(localized: "\(minutes / 60) h \(minutes % 60) min left") : String(localized: "\(minutes) min left")
    }

    /// "S1 · E4".
    var episodeLabel: String? {
        guard let season = context.season, let episode = context.episode else { return nil }
        return "S\(season) · E\(episode)"
    }
}

/// Watch progress and watched marks, kept on this Apple TV.
@MainActor
final class WatchHistory: ObservableObject {
    static let shared = WatchHistory()

    /// Less than this isn't saved: a quick look at a stream isn't "started".
    nonisolated static let minimumProgress: Double = 120
    /// From here on a movie or episode counts as watched.
    nonisolated static let watchedFraction: Double = 0.9

    @Published private(set) var entries: [String: WatchEntry] = [:]
    /// Series marked watched as a whole (their posters get a tick).
    @Published private(set) var watchedSeries: Set<String> = []
    /// Watched elsewhere, from Trakt, as entry keys ("movie-603", "tv-1399:1:2").
    @Published private(set) var externalWatched: Set<String> = []

    private static let entriesKey = "watchHistory.entries"
    private static let seriesKey = "watchHistory.series"
    private static let dismissedKey = "watchHistory.dismissedNextUp"
    private static let externalKey = "watchHistory.externalWatched"
    private static let maxEntries = 600

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.entriesKey),
           let saved = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updated > b.updated ? a : b })
        }
        watchedSeries = Set(defaults.stringArray(forKey: Self.seriesKey) ?? [])
        dismissedNextUp = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
        externalWatched = Set(defaults.stringArray(forKey: Self.externalKey) ?? [])
    }

    nonisolated static func key(item: TMDBItem, season: Int?, episode: Int?) -> String {
        guard let season, let episode else { return item.uid }
        return "\(item.uid):\(season):\(episode)"
    }

    // MARK: Reading

    func entry(for context: WatchContext) -> WatchEntry? { entries[context.key] }

    func entry(item: TMDBItem, season: Int? = nil, episode: Int? = nil) -> WatchEntry? {
        entries[Self.key(item: item, season: season, episode: episode)]
    }

    /// Movie: watched. Series: marked watched as a whole.
    func isWatched(_ item: TMDBItem) -> Bool {
        if item.kind == .movie {
            if let entry = entry(item: item) { return entry.watched }
            return externalWatched.contains(item.uid)
        }
        return watchedSeries.contains(item.uid)
    }

    func isWatched(_ item: TMDBItem, season: Int, episode: Int) -> Bool {
        if let entry = entry(item: item, season: season, episode: episode) { return entry.watched }
        return externalWatched.contains(Self.key(item: item, season: season, episode: episode))
    }

    /// The most recently played episode of a series.
    func latestEpisode(of item: TMDBItem) -> WatchEntry? {
        entries.values
            .filter { $0.item.uid == item.uid && $0.context.season != nil }
            .max { $0.updated < $1.updated }
    }

    /// The newest entry per movie or series, newest first.
    var latestPerTitle: [WatchEntry] {
        var latest: [String: WatchEntry] = [:]
        for entry in entries.values {
            let uid = entry.item.uid
            if let existing = latest[uid], existing.updated >= entry.updated { continue }
            latest[uid] = entry
        }
        return latest.values.sorted { $0.updated > $1.updated }
    }

    // MARK: Writing

    /// Saves where playback is. Called every few seconds and when the player closes.
    func record(_ context: WatchContext, position: Double, duration: Double) {
        guard duration > 0, position.isFinite, duration.isFinite else { return }
        var entry = entries[context.key]
            ?? WatchEntry(context: context, position: 0, duration: duration, updated: Date(), watched: false)
        if position / duration >= Self.watchedFraction {
            if !entry.watched || entry.position > 0 { TraktSync.shared.playbackFinished(context) }
            entry.watched = true
            entry.position = 0
        } else if position >= Self.minimumProgress {
            entry.position = position
        } else if entries[context.key] == nil {
            return
        }
        entry.context = context
        entry.duration = duration
        entry.updated = Date()
        entries[context.key] = entry
        dismissedNextUp.remove(context.item.uid)
        save()
    }

    func setWatched(_ watched: Bool, context: WatchContext) {
        TraktSync.shared.historyChanged([context], watched: watched)
        var entry = entries[context.key]
            ?? WatchEntry(context: context, position: 0, duration: 0, updated: Date(), watched: false)
        entry.watched = watched
        entry.position = 0
        entry.updated = Date()
        entries[context.key] = entry
        save()
    }

    /// Marks every listed episode of a season, e.g. from "Mark season watched".
    func setWatched(_ watched: Bool, item: TMDBItem, imdbID: String, episodes: [TVEpisode]) {
        TraktSync.shared.historyChanged(episodes.map {
            WatchContext(item: item, imdbID: imdbID, season: $0.seasonNumber, episode: $0.episodeNumber)
        }, watched: watched)
        for episode in episodes {
            let context = WatchContext(item: item, imdbID: imdbID, season: episode.seasonNumber,
                                       episode: episode.episodeNumber, episodeName: episode.name)
            var entry = entries[context.key]
                ?? WatchEntry(context: context, position: 0, duration: 0, updated: Date(), watched: false)
            entry.watched = watched
            entry.position = 0
            entries[context.key] = entry
        }
        save()
    }

    /// Series posters: ticked when marked watched as a whole.
    func setSeriesWatched(_ watched: Bool, item: TMDBItem) {
        TraktSync.shared.seriesChanged(item, watched: watched)
        if watched { watchedSeries.insert(item.uid) } else { watchedSeries.remove(item.uid) }
        save()
    }

    struct Snapshot: Codable {
        var entries: [WatchEntry]
        var watchedSeries: [String]
        var dismissedNextUp: [String]
    }

    /// Everything here, for a backup.
    var snapshot: Snapshot {
        Snapshot(entries: Array(entries.values), watchedSeries: Array(watchedSeries),
                 dismissedNextUp: Array(dismissedNextUp))
    }

    /// Replaces everything with a backup's.
    func restore(_ snapshot: Snapshot) {
        entries = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updated > b.updated ? a : b })
        watchedSeries = Set(snapshot.watchedSeries)
        dismissedNextUp = Set(snapshot.dismissedNextUp)
        save()
    }

    /// Trakt's watched list, replacing the previous one.
    func setExternalWatched(_ keys: Set<String>) {
        externalWatched = keys
        save()
    }

    /// Progress from Trakt: taken when it's newer than what this Apple TV has.
    func mergeRemote(_ context: WatchContext, position: Double, duration: Double, updated: Date) {
        guard duration > 0, position >= Self.minimumProgress, position / duration < Self.watchedFraction else { return }
        if let existing = entries[context.key], existing.updated >= updated { return }
        entries[context.key] = WatchEntry(context: context, position: position, duration: duration,
                                          updated: updated, watched: false)
        save()
    }

    /// Drops a title from Continue Watching without marking it watched.
    func remove(_ item: TMDBItem) {
        entries = entries.filter { $0.value.item.uid != item.uid || $0.value.watched }
        for key in entries.keys where entries[key]?.item.uid == item.uid {
            entries[key]?.position = 0
        }
        // Finished episodes stay ticked, but the series no longer offers its next episode.
        dismissedNextUp.insert(item.uid)
        save()
    }

    /// Series whose "next episode" card was removed; cleared when another episode is played.
    @Published private(set) var dismissedNextUp: Set<String> = []

    private func save() {
        if entries.count > Self.maxEntries {
            let keep = entries.values.sorted { $0.updated > $1.updated }.prefix(Self.maxEntries)
            entries = Dictionary(keep.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            defaults.set(data, forKey: Self.entriesKey)
        }
        defaults.set(Array(watchedSeries), forKey: Self.seriesKey)
        defaults.set(Array(dismissedNextUp), forKey: Self.dismissedKey)
        defaults.set(Array(externalWatched), forKey: Self.externalKey)
        TopShelfPublisher.publish()
    }
}
