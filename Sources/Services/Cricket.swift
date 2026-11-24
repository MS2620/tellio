import Foundation

/// Cricket, from ESPN. Cricket has no league scoreboards or team schedules there; instead ESPN's
/// all-cricket feed lists every game on one day, international tours included, so fixtures are
/// read a day at a time.
struct CricketClient {
    /// `Fixture.scoreboardPath` for cricket games: their live scores come from today's feed.
    static let scorePath = "cricket"
    /// The "league" of national sides in Browse by league.
    static let internationalSlug = "international"

    /// National sides, by ESPN id (the same ids team search returns).
    static let nations: [(id: String, name: String)] = [
        ("1", "England"), ("2", "Australia"), ("6", "India"), ("7", "Pakistan"),
        ("3", "South Africa"), ("5", "New Zealand"), ("4", "West Indies"), ("8", "Sri Lanka"),
        ("25", "Bangladesh"), ("40", "Afghanistan"), ("29", "Ireland"), ("9", "Zimbabwe"),
        ("30", "Scotland"), ("15", "Netherlands"),
    ]

    static func logo(teamID: String) -> String {
        "https://a.espncdn.com/i/teamlogos/cricket/500/\(teamID).png"
    }

    /// Followed teams' games under way or starting in the next `days`, soonest first.
    func fixtures(for teams: [FavouriteTeam], days: Int) async -> [Fixture] {
        guard !teams.isEmpty else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dates = (0..<max(days, 1)).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        var found: [String: Fixture] = [:]
        await withTaskGroup(of: [CricketLeague].self) { group in
            for date in dates {
                group.addTask { await CricketFeed.shared.leagues(on: date) }
            }
            for await leagues in group {
                for league in leagues {
                    for event in league.games {
                        if let fixture = Self.fixture(event, league: league, teams: teams) {
                            found[fixture.id] = fixture
                        }
                    }
                }
            }
        }
        let from = Date().addingTimeInterval(-5 * 3600)
        let until = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        return found.values
            .filter { $0.lastsUntil > from && $0.date <= until }
            .sorted { $0.date < $1.date }
    }

    /// For Browse by league: international sides first, then every competition with games
    /// in the next 30 days (franchise leagues appear once their fixtures are out).
    func leagues() async -> [SportLeague] {
        var names: [String: String] = [:]
        for league in await upcomingLeagues() {
            names[league.id] = league.name ?? league.id
        }
        let competitions = names
            .map { SportLeague(sport: "cricket", slug: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [SportLeague(sport: "cricket", slug: Self.internationalSlug,
                            name: String(localized: "International teams"))] + competitions
    }

    /// The sides in a competition, from its games in the next 30 days.
    func teams(in league: SportLeague) async -> [ESPNTeam] {
        if league.slug == Self.internationalSlug {
            return Self.nations.map {
                ESPNTeam(id: $0.id, displayName: $0.name, logoURL: Self.logo(teamID: $0.id))
            }
        }
        var teams: [String: ESPNTeam] = [:]
        for found in await upcomingLeagues() where found.id == league.slug {
            for event in found.games {
                for side in event.competitors ?? [] {
                    guard let name = side.displayName ?? side.name else { continue }
                    teams[side.id] = ESPNTeam(id: side.id, displayName: name,
                                              logoURL: side.logo ?? Self.logo(teamID: side.id))
                }
            }
        }
        return teams.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func upcomingLeagues() async -> [CricketLeague] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var all: [CricketLeague] = []
        await withTaskGroup(of: [CricketLeague].self) { group in
            for offset in 0..<30 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                group.addTask { await CricketFeed.shared.leagues(on: date) }
            }
            for await leagues in group { all += leagues }
        }
        return all
    }

    /// Current scores for cricket games under way, from today's feed.
    func liveScores(for fixtures: [Fixture]) async -> [String: FixtureScore] {
        let ids = Dictionary(fixtures.compactMap { f in f.eventID.map { ($0, f.id) } }, uniquingKeysWith: { a, _ in a })
        guard !ids.isEmpty else { return [:] }
        var result: [String: FixtureScore] = [:]
        for league in await CricketFeed.shared.leagues(on: Date(), maxAge: 25) {
            for event in league.games {
                if let id = ids[event.id], let score = Self.score(event) { result[id] = score }
            }
        }
        return result
    }

    // MARK: Building fixtures

    private static func fixture(_ event: CricketEvent, league: CricketLeague, teams: [FavouriteTeam]) -> Fixture? {
        guard let sides = event.competitors, let date = SportsDate.parse(event.date) else { return nil }
        let playing = teams.filter { team in sides.contains { $0.id == team.teamID } }
        guard !playing.isEmpty else { return nil }
        let state = event.state
        let status = (event.fullStatus?.type?.description ?? "").lowercased()
        if state != "in", ["abandon", "cancel", "postpone"].contains(where: { status.contains($0) }) { return nil }

        func side(_ competitor: CricketEvent.Competitor?) -> Fixture.Side? {
            guard let competitor, let name = competitor.displayName ?? competitor.name else { return nil }
            let followed = playing.first { $0.teamID == competitor.id }
            return Fixture.Side(id: competitor.id, name: name,
                                logo: competitor.logo ?? followed?.logo ?? logo(teamID: competitor.id),
                                color: followed?.color)
        }
        let home = side(event.home)
        let away = side(event.away)
        let keywords = [home?.name, away?.name].compactMap { $0?.lowercased() }.filter { $0.count >= 4 }
        let title = [home?.name, away?.name].compactMap { $0 }.joined(separator: " v ")
        let subtitle = [event.title, event.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")

        var fixture = Fixture(
            id: "cricket-\(event.id)",
            date: date,
            competition: league.name ?? String(localized: "Cricket"),
            title: title.isEmpty ? (event.name ?? "Match") : title,
            home: home,
            away: away,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            keywords: keywords,
            followed: playing.map(\.name),
            score: score(event),
            eventID: event.id,
            scoreboardPath: scorePath
        )
        // A Test runs for days; finished games drop off like any other.
        if state != "post" { fixture.endDate = event.endDate.flatMap(SportsDate.parse) }
        return fixture
    }

    /// The score of a game that has started, nil before the first ball.
    static func score(_ event: CricketEvent) -> FixtureScore? {
        let home = runs(event.home?.score)
        let away = runs(event.away?.score)
        let summary = event.fullStatus?.summary ?? event.summary
        switch event.state {
        case "in":
            return FixtureScore(phase: .live, home: home, away: away,
                                clock: event.fullStatus?.type?.description ?? String(localized: "LIVE"),
                                period: summary)
        case "post":
            return FixtureScore(phase: .finished, home: home, away: away,
                                clock: String(localized: "Result"), period: summary)
        default:
            return nil
        }
    }

    /// "278 & 106/2 (32.4 ov)" → "278 & 106/2"; a side yet to bat shows a dash.
    private static func runs(_ score: String?) -> String {
        guard var text = score?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return "–" }
        if let bracket = text.firstIndex(of: "(") {
            text = String(text[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// One day of ESPN's cricket feed, kept a while so Sports, Home and Browse share it.
actor CricketFeed {
    static let shared = CricketFeed()
    private static let url = "https://site.web.api.espn.com/apis/v2/scoreboard/header?sport=cricket"

    private var days: [String: (fetched: Date, leagues: [CricketLeague])] = [:]
    private var loading: [String: Task<[CricketLeague], Never>] = [:]

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// Every competition with games on `date`'s day. Today is kept for 2 minutes (scores
    /// change), later days for 3 hours.
    func leagues(on date: Date, maxAge: TimeInterval? = nil) async -> [CricketLeague] {
        let key = Self.dayFormat.string(from: date)
        let isToday = Calendar.current.isDateInToday(date)
        let age = maxAge ?? (isToday ? 120 : 3 * 3600)
        if let cached = days[key], Date().timeIntervalSince(cached.fetched) < age { return cached.leagues }
        if let running = loading[key] { return await running.value }
        let task = Task { await Self.fetch(day: key) ?? [] }
        loading[key] = task
        let leagues = await task.value
        loading[key] = nil
        days[key] = (Date(), leagues)
        return leagues
    }

    private static func fetch(day: String) async -> [CricketLeague]? {
        guard let url = URL(string: "\(Self.url)&dates=\(day)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let data = try? await URLSession.shared.fetch(request),
              let response = try? JSONDecoder().decode(CricketFeedResponse.self, from: data) else { return nil }
        return (response.sports ?? []).flatMap { $0.leagues ?? [] }.compactMap(\.value)
    }
}

// MARK: - Feed models

/// Decodes what it can, so one odd entry doesn't lose the rest of the feed.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct CricketFeedResponse: Decodable {
    struct Sport: Decodable { let leagues: [Lossy<CricketLeague>]? }
    let sports: [Sport]?
}

struct CricketLeague: Decodable {
    let id: String
    let name: String?
    let events: [Lossy<CricketEvent>]?

    var games: [CricketEvent] { (events ?? []).compactMap(\.value) }
}

struct CricketEvent: Decodable {
    struct Competitor: Decodable {
        let id: String
        let displayName: String?
        let name: String?
        let logo: String?
        let homeAway: String?
        let score: String?
    }
    struct FullStatus: Decodable {
        struct Kind: Decodable {
            let state: String?
            let description: String?
        }
        let type: Kind?
        let summary: String?
    }

    let id: String
    let date: String
    let endDate: String?
    let name: String?
    /// "2nd Test".
    let title: String?
    let location: String?
    /// "pre", "in" or "post".
    let status: String?
    let summary: String?
    let fullStatus: FullStatus?
    let competitors: [Competitor]?

    var state: String { fullStatus?.type?.state ?? status ?? "pre" }
    var home: Competitor? { competitors?.first { $0.homeAway == "home" } ?? competitors?.first }
    var away: Competitor? { competitors?.first { $0.homeAway == "away" } ?? competitors?.last }
}
