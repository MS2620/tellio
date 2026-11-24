import Foundation

/// Live scores for the followed teams' games. Fixtures loaded by `SportsLoader` are tracked
/// here; while one is under way, screens showing them call `run()` to refresh every 30 seconds.
@MainActor
final class LiveScores: ObservableObject {
    static let shared = LiveScores()

    @Published private(set) var scores: [String: FixtureScore] = [:]
    /// Fixtures seen recently, so a game the schedules stop listing once it starts stays on screen.
    private var tracked: [String: Fixture] = [:]
    private var lastRefresh = Date.distantPast

    private static let refreshInterval: TimeInterval = 30
    /// How long after kick-off a game is kept: long enough to finish and show the result for a while.
    private static let keepFor: TimeInterval = 5 * 3600

    private init() {}

    /// The newest score for `fixture`, nil before kick-off.
    func score(for fixture: Fixture) -> FixtureScore? {
        scores[fixture.id] ?? fixture.score
    }

    func track(_ fixtures: [Fixture]) {
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        tracked = tracked.filter { $0.value.lastsUntil > cutoff }
        for fixture in fixtures where fixture.lastsUntil > cutoff {
            tracked[fixture.id] = fixture
            // A fresher score from a refresh wins over the one the schedule had.
            if let score = fixture.score, scores[fixture.id] == nil { scores[fixture.id] = score }
        }
        TopShelfPublisher.publish()
    }

    /// Followed teams' games and race sessions that start later today or tomorrow, soonest first.
    var upcomingFixtures: [Fixture] {
        let now = Date()
        let calendar = Calendar.current
        guard let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return [] }
        return tracked.values
            .filter { $0.guideTime > now && $0.guideTime < endOfTomorrow }
            .sorted { $0.guideTime < $1.guideTime }
    }

    func recentFixtures(excluding ids: Set<String>) -> [Fixture] {
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        return tracked.values.filter { !ids.contains($0.id) && $0.lastsUntil > cutoff && $0.date <= Date() }
    }

    /// Games on now, soonest kick-off first (for the Top Shelf).
    var liveFixtures: [Fixture] {
        underWay.filter { score(for: $0)?.phase != nil || $0.date <= Date() }.sorted { $0.date < $1.date }
    }

    func fixture(id: String) -> Fixture? { tracked[id] }

    /// Games that have kicked off and haven't finished.
    private var underWay: [Fixture] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.keepFor)
        return tracked.values.filter { fixture in
            !fixture.isRace && fixture.date <= now.addingTimeInterval(60) && fixture.lastsUntil > cutoff
                && score(for: fixture)?.phase != .finished
        }
    }

    /// Refreshes while a game is under way. Call from a view's `.task`; it stops when the view goes.
    func run() async {
        while !Task.isCancelled {
            await refreshIfDue()
            try? await Task.sleep(for: .seconds(Self.refreshInterval))
        }
    }

    private func refreshIfDue() async {
        let games = underWay
        // Several screens can run this at once; only one fetch per interval.
        guard !games.isEmpty, Date().timeIntervalSince(lastRefresh) >= Self.refreshInterval - 2 else { return }
        lastRefresh = Date()
        let fresh = await ESPNClient().liveScores(for: games)
        for (id, score) in fresh { scores[id] = score }
        TopShelfPublisher.publish()
    }
}
