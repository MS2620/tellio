import Foundation

// MARK: - Saved favourites

/// A followed team. Saved in Preferences.
struct FavouriteTeam: Codable, Hashable, Identifiable {
    /// ESPN sport path ("soccer", "rugby", "football", "basketball", "hockey",
    /// "baseball"), or "f1" for Formula 1 constructors.
    let sport: String
    /// ESPN league slug or id ("eng.1", "267979", "nfl"), or "f1".
    let league: String
    let leagueName: String
    let teamID: String
    let name: String
    let logo: String?
    /// Team colour as hex ("da020e"), when ESPN gives one.
    var color: String? = nil

    var id: String { "\(sport)/\(league)/\(teamID)" }
    var isF1: Bool { sport == "f1" }
}

struct SportLeague: Hashable, Identifiable {
    let sport: String
    let slug: String
    let name: String
    var id: String { "\(sport)/\(slug)" }
}

/// A competition followed for its games today (Sports › Today in your competitions), such as
/// the Champions League, without following every team in it. Only ESPN competitions: their
/// scoreboards list every game of the day.
struct FavouriteCompetition: Codable, Hashable, Identifiable {
    /// ESPN sport path ("soccer", "rugby", "football"…).
    let sport: String
    /// ESPN league slug or id ("uefa.champions", "267979", "nfl").
    let league: String
    let name: String

    var id: String { "\(sport)/\(league)" }

    init(_ league: SportLeague) {
        sport = league.sport
        self.league = league.slug
        name = league.name
    }

    /// Cricket and the Super League come from other sources, and F1 has its race weekend.
    static func canFollow(_ league: SportLeague) -> Bool {
        !["cricket", "f1", SuperLeagueClient.sport].contains(league.sport)
    }
}

enum SportsCatalog {
    /// ESPN rugby competitions (ids from ESPN's league list).
    static let rugby: [SportLeague] = [
        SportLeague(sport: "rugby", slug: "180659", name: "Six Nations"),
        SportLeague(sport: "rugby", slug: "267979", name: "Premiership Rugby"),
        SportLeague(sport: "rugby", slug: "270557", name: "United Rugby Championship"),
        SportLeague(sport: "rugby", slug: "271937", name: "European Rugby Champions Cup"),
        SportLeague(sport: "rugby", slug: "272073", name: "European Rugby Challenge Cup"),
        SportLeague(sport: "rugby", slug: "270559", name: "French Top 14"),
        SportLeague(sport: "rugby", slug: "244293", name: "The Rugby Championship"),
        SportLeague(sport: "rugby", slug: "242041", name: "Super Rugby Pacific"),
        SportLeague(sport: "rugby", slug: "289234", name: "International Test Matches"),
        SportLeague(sport: "rugby", slug: "164205", name: "Rugby World Cup"),
    ]

    /// Rugby league, shown under Rugby in Browse by league (from TheSportsDB, not ESPN).
    static let rugbyLeague: [SportLeague] = [SuperLeagueClient.league]

    static let us: [SportLeague] = [
        SportLeague(sport: "football", slug: "nfl", name: "NFL"),
        SportLeague(sport: "basketball", slug: "nba", name: "NBA"),
        SportLeague(sport: "hockey", slug: "nhl", name: "NHL"),
        SportLeague(sport: "baseball", slug: "mlb", name: "MLB"),
    ]

    /// Shown first in the football list; every other league follows A–Z.
    static let footballPriority = [
        "eng.1", "sco.1", "uefa.champions", "uefa.europa", "uefa.europa.conf",
        "eng.2", "eng.3", "eng.4", "sco.2", "eng.fa", "eng.league_cup",
        "esp.1", "ger.1", "ita.1", "fra.1", "por.1", "ned.1", "usa.1",
    ]
}

// MARK: - Fixtures

struct Fixture: Identifiable, Hashable {
    struct Side: Hashable {
        let id: String
        let name: String
        let logo: String?
        var color: String? = nil
        /// Other names for the team, e.g. ESPN's short name ("Man United").
        var aliases: [String] = []
        /// ESPN's short code ("MUN"), for listings like "MUN v LIV".
        var code: String? = nil
    }

    struct Session: Hashable {
        let name: String
        let date: Date
    }

    let id: String
    let date: Date
    let competition: String
    let title: String
    let home: Side?
    let away: Side?
    /// Extra line, e.g. the F1 circuit.
    var subtitle: String? = nil
    var broadcasts: [String] = []
    /// F1 weekend sessions, in order.
    var sessions: [Session] = []
    /// Lower-cased words to look for in TV guide listings.
    var keywords: [String] = []
    /// Names of the user's teams involved.
    var followed: [String] = []
    /// Score when the schedule was loaded; `LiveScores` keeps it current.
    var score: FixtureScore? = nil
    /// ESPN's event ID and the league scoreboard that lists it, for live score updates.
    var eventID: String? = nil
    var scoreboardPath: String? = nil
    /// When a game that runs for days (a cricket Test) is due to end; nil for the rest.
    var endDate: Date? = nil

    var isRace: Bool { !sessions.isEmpty }
    /// Kick-off, or the last day of a game that runs for several.
    var lastsUntil: Date { max(date, endDate ?? date) }

    /// When to look for it in the TV guide: the next F1 session, or kick-off.
    var guideTime: Date {
        let soon = Date().addingTimeInterval(-2 * 3600)
        return sessions.first { $0.date > soon }?.date ?? date
    }
}

/// Saved with match reminders (and their backups). Read leniently: fields added later
/// fall back to their defaults, so older saves still load. The score isn't saved.
extension Fixture: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, date, competition, title, home, away, subtitle, broadcasts, sessions, keywords,
             followed, eventID, scoreboardPath, endDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        competition = (try? c.decodeIfPresent(String.self, forKey: .competition)) ?? ""
        title = try c.decode(String.self, forKey: .title)
        home = try? c.decodeIfPresent(Side.self, forKey: .home)
        away = try? c.decodeIfPresent(Side.self, forKey: .away)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        broadcasts = (try? c.decodeIfPresent([String].self, forKey: .broadcasts)) ?? []
        sessions = (try? c.decodeIfPresent([Session].self, forKey: .sessions)) ?? []
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        followed = (try? c.decodeIfPresent([String].self, forKey: .followed)) ?? []
        eventID = try? c.decodeIfPresent(String.self, forKey: .eventID)
        scoreboardPath = try? c.decodeIfPresent(String.self, forKey: .scoreboardPath)
        endDate = try? c.decodeIfPresent(Date.self, forKey: .endDate)
    }
}

extension Fixture.Side: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, logo, color, aliases, code }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        logo = try? c.decodeIfPresent(String.self, forKey: .logo)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        code = try? c.decodeIfPresent(String.self, forKey: .code)
    }
}

extension Fixture.Session: Codable {}

/// A game's score and clock as ESPN reports it.
struct FixtureScore: Hashable {
    enum Phase: Hashable { case live, halfTime, finished }

    let phase: Phase
    let home: String
    let away: String
    /// "67'", "HT", "FT", "AET"…
    let clock: String
    /// "Second Half", "Half-time", "Full time"…
    let period: String?

    /// "2 – 1".
    var line: String { "\(home) – \(away)" }
}

// MARK: - Dates

enum SportsDate {
    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ESPN sends times without seconds ("2026-08-29T11:30Z"), which
    /// ISO8601DateFormatter rejects, so that form gets its own parser.
    private static let noSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return formatter
    }()

    private static let range: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        internet.date(from: string) ?? noSeconds.date(from: string) ?? fractional.date(from: string)
    }

    /// "20261125": ESPN's `dates` parameter for one day (UTC).
    static func dayParameter(_ date: Date) -> String {
        range.string(from: date)
    }

    /// ESPN's `dates` parameter for any two dates.
    static func rangeParameter(from start: Date, to end: Date) -> String {
        "\(range.string(from: start))-\(range.string(from: end))"
    }

    /// "20261114-20270113" for ESPN's `dates` parameter.
    static func rangeParameter(days: Int) -> String {
        let start = Date()
        let end = start.addingTimeInterval(TimeInterval(days) * 86_400)
        return "\(range.string(from: start))-\(range.string(from: end))"
    }
}

// MARK: - ESPN

/// A team as ESPN returns it. Logos come as a `logos` array (teams, schedules)
/// or a single `logo` string (scoreboards), so both are read.
struct ESPNTeam: Decodable, Hashable {
    let id: String
    let displayName: String
    let shortDisplayName: String?
    let location: String?
    let logoURL: String?
    let color: String?
    /// "MUN", "LIV".
    var abbreviation: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, displayName, shortDisplayName, name, location, logo, logos, color, abbreviation
    }

    private struct Logo: Decodable { let href: String? }

    /// A team from somewhere other than ESPN's team lists (cricket, the Super League).
    init(id: String, displayName: String, shortDisplayName: String? = nil, location: String? = nil,
         logoURL: String? = nil, color: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.shortDisplayName = shortDisplayName
        self.location = location
        self.logoURL = logoURL
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? ""
        let name = try? c.decode(String.self, forKey: .name)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? name ?? "Team"
        shortDisplayName = try? c.decode(String.self, forKey: .shortDisplayName)
        location = try? c.decode(String.self, forKey: .location)
        let logos = try? c.decode([Logo].self, forKey: .logos)
        logoURL = logos?.compactMap(\.href).first ?? (try? c.decode(String.self, forKey: .logo))
        color = try? c.decode(String.self, forKey: .color)
        abbreviation = try? c.decode(String.self, forKey: .abbreviation)
    }

    /// Lower-cased names to look for in guide listings ("man united", "liverpool").
    var keywords: [String] {
        var words = [displayName, shortDisplayName, location].compactMap { $0?.lowercased() }
        words += words.map { name in
            name.replacingOccurrences(of: " afc", with: "")
                .replacingOccurrences(of: " fc", with: "")
                .replacingOccurrences(of: "fc ", with: "")
                .replacingOccurrences(of: " cf", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return Array(Set(words.filter { $0.count >= 4 }))
    }
}

private struct ESPNTeamsResponse: Decodable {
    struct Sport: Decodable { let leagues: [League]? }
    struct League: Decodable { let teams: [Wrapper]? }
    struct Wrapper: Decodable { let team: ESPNTeam }
    let sports: [Sport]?
}

private struct ESPNDropdownResponse: Decodable {
    struct League: Decodable {
        let name: String?
        let slug: String?
    }
    let leagues: [League]?
}

private struct ESPNEventsResponse: Decodable {
    let events: [ESPNEvent]?
}

private struct ESPNEvent: Decodable {
    /// Each field decodes on its own, so an unexpected shape in one
    /// (broadcasts differ between endpoints) doesn't drop the fixture.
    struct Competition: Decodable {
        struct Venue: Decodable { let fullName: String? }

        let competitors: [Competitor]?
        let broadcasts: [Broadcast]?
        let status: Status?
        let venue: Venue?

        private enum CodingKeys: String, CodingKey { case competitors, broadcasts, status, venue }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            competitors = try? c.decode([Competitor].self, forKey: .competitors)
            broadcasts = try? c.decode([Broadcast].self, forKey: .broadcasts)
            status = try? c.decode(Status.self, forKey: .status)
            venue = try? c.decode(Venue.self, forKey: .venue)
        }
    }
    struct Competitor: Decodable {
        let homeAway: String?
        let team: ESPNTeam?
        /// Scoreboards send the score as a string, team schedules as an object.
        let score: String?

        private enum CodingKeys: String, CodingKey { case homeAway, team, score }
        private struct ScoreValue: Decodable {
            let value: Double?
            let displayValue: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            homeAway = try? c.decode(String.self, forKey: .homeAway)
            team = try? c.decode(ESPNTeam.self, forKey: .team)
            if let text = try? c.decode(String.self, forKey: .score) {
                score = text
            } else if let value = try? c.decode(ScoreValue.self, forKey: .score) {
                score = value.displayValue ?? value.value.map { String(Int($0)) }
            } else {
                score = nil
            }
        }
    }
    struct Broadcast: Decodable {
        struct Media: Decodable { let shortName: String? }
        let media: Media?
        let names: [String]?
    }
    struct Status: Decodable {
        struct StatusType: Decodable {
            let name: String?
            let state: String?
            let completed: Bool?
            let description: String?
            let shortDetail: String?
            let detail: String?
        }
        let type: StatusType?
        let displayClock: String?

        private enum CodingKeys: String, CodingKey { case type, displayClock }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(StatusType.self, forKey: .type)
            displayClock = try? c.decode(String.self, forKey: .displayClock)
        }
    }

    /// Present on "all competitions" schedules: which competition this game is in.
    struct League: Decodable {
        let name: String?
        let slug: String?
    }

    let id: String
    let date: String
    let name: String?
    let competitions: [Competition]?
    let league: League?

    private enum CodingKeys: String, CodingKey { case id, date, name, competitions, league }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        name = try? c.decode(String.self, forKey: .name)
        competitions = try? c.decode([Competition].self, forKey: .competitions)
        league = try? c.decode(League.self, forKey: .league)
    }
}

/// A team found by searching ESPN (or an F1 constructor).
struct TeamSearchResult: Identifiable, Hashable {
    let sport: String
    let league: String
    let teamID: String
    let name: String
    let logo: String?
    let color: String?

    var id: String { "\(sport)/\(teamID)" }
}

private struct ESPNSearchResponse: Decodable {
    struct Item: Decodable {
        struct Logo: Decodable { let href: String? }
        let id: String?
        let displayName: String?
        let sport: String?
        let league: String?
        let defaultLeagueSlug: String?
        let color: String?
        let logos: [Logo]?

        private enum CodingKeys: String, CodingKey {
            case id, displayName, sport, league, defaultLeagueSlug, color, logos
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.flexString(.id)
            displayName = try? c.decode(String.self, forKey: .displayName)
            sport = try? c.decode(String.self, forKey: .sport)
            league = c.flexString(.league)
            defaultLeagueSlug = c.flexString(.defaultLeagueSlug)
            color = try? c.decode(String.self, forKey: .color)
            logos = try? c.decode([Logo].self, forKey: .logos)
        }
    }
    let items: [Item]?
}

struct ESPNClient {
    private static let base = "https://site.api.espn.com/apis/site/v2"

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        guard let url = URL(string: Self.base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data = try await URLSession.shared.fetch(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Every football competition ESPN covers, popular ones first.
    func footballLeagues() async throws -> [SportLeague] {
        let response = try await fetch(ESPNDropdownResponse.self, "/leagues/dropdown?sport=soccer&limit=500")
        var seen = Set<String>()
        let leagues = (response.leagues ?? []).compactMap { league -> SportLeague? in
            guard let slug = league.slug, let name = league.name, !slug.isEmpty,
                  seen.insert(slug).inserted else { return nil }
            return SportLeague(sport: "soccer", slug: slug, name: name)
        }
        let priority = SportsCatalog.footballPriority
        return leagues.sorted { a, b in
            let ia = priority.firstIndex(of: a.slug) ?? Int.max
            let ib = priority.firstIndex(of: b.slug) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func teams(in league: SportLeague) async throws -> [ESPNTeam] {
        if league.sport == "cricket" { return await CricketClient().teams(in: league) }
        if league.sport == SuperLeagueClient.sport { return try await SuperLeagueClient().teams() }
        let response = try await fetch(ESPNTeamsResponse.self, "/sports/\(league.sport)/\(league.slug)/teams?limit=500")
        let teams = response.sports?.first?.leagues?.first?.teams?.map(\.team) ?? []
        return teams.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Sports the app can show fixtures for, as ESPN names them.
    static let supportedSports: Set<String> = ["soccer", "football", "basketball", "hockey", "baseball", "rugby", "cricket"]

    /// Searches every team ESPN knows, across sports and leagues.
    func searchTeams(_ query: String) async throws -> [TeamSearchResult] {
        guard var components = URLComponents(string: "https://site.web.api.espn.com/apis/common/v3/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: "team"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data = try await URLSession.shared.fetch(request)
        let response = try JSONDecoder().decode(ESPNSearchResponse.self, from: data)

        var seen = Set<String>()
        return (response.items ?? []).compactMap { item -> TeamSearchResult? in
            guard let id = item.id, let name = item.displayName, let sport = item.sport,
                  Self.supportedSports.contains(sport) else { return nil }
            let league = item.defaultLeagueSlug ?? item.league ?? ""
            // US sports need the league to look up a schedule.
            if league.isEmpty && sport != "soccer" && sport != "rugby" && sport != "cricket" { return nil }
            let result = TeamSearchResult(sport: sport, league: league, teamID: id, name: name,
                                          logo: item.logos?.compactMap(\.href).first, color: item.color)
            return seen.insert(result.id).inserted ? result : nil
        }
    }

    /// A team's fixtures in the next `days`, in every competition it plays in.
    /// (Rugby is handled by `rugbyFixtures`, which reads league fixture lists.)
    func upcomingFixtures(for team: FavouriteTeam, days: Int) async -> [Fixture] {
        let league = "/sports/\(team.sport)/\(team.league)"
        var paths: [String] = []
        if team.sport == "soccer" {
            // "all" returns league, cup, European and international games together.
            paths.append("/sports/soccer/all/teams/\(team.teamID)/schedule?fixture=true")
            if !team.league.isEmpty {
                paths.append("\(league)/teams/\(team.teamID)/schedule?fixture=true")
            }
        } else {
            paths.append("\(league)/teams/\(team.teamID)/schedule")
            paths.append("\(league)/scoreboard?dates=\(SportsDate.rangeParameter(days: days))&limit=300")
        }

        for path in paths {
            guard let response = try? await fetch(ESPNEventsResponse.self, path) else { continue }
            let fixtures = Self.window((response.events ?? []).compactMap {
                fixture(from: $0, teams: [team], leagueSlug: team.league)
            }, days: days)
            if !fixtures.isEmpty { return fixtures }
        }
        return []
    }

    /// Fixtures for followed rugby teams, from every rugby competition's fixture list.
    func rugbyFixtures(for teams: [FavouriteTeam], days: Int) async -> [Fixture] {
        guard !teams.isEmpty else { return [] }
        var found: [Fixture] = []
        await withTaskGroup(of: [Fixture].self) { group in
            for league in SportsCatalog.rugby {
                group.addTask {
                    let base = "/sports/rugby/\(league.slug)/scoreboard"
                    let paths = ["\(base)?dates=\(SportsDate.rangeParameter(days: days))&limit=200", base]
                    for path in paths {
                        guard let response = try? await self.fetch(ESPNEventsResponse.self, path) else { continue }
                        let events = response.events ?? []
                        if events.isEmpty { continue }
                        return events.compactMap {
                            self.fixture(from: $0, teams: teams, competition: league.name, leagueSlug: league.slug)
                        }
                    }
                    return []
                }
            }
            for await list in group { found += list }
        }
        return Self.window(found, days: days)
    }

    /// Keeps fixtures that kicked off up to 5 hours ago (on now, or finished and shown with
    /// the final score for a few hours) up to `days` ahead, soonest first.
    static func window(_ fixtures: [Fixture], days: Int) -> [Fixture] {
        let from = Date().addingTimeInterval(-5 * 3600)
        let until = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        return fixtures.filter { $0.lastsUntil > from && $0.date <= until }.sorted { $0.date < $1.date }
    }

    /// Today's games in a competition, from its scoreboard: those kicking off today (local time),
    /// and any from last night still under way. `teams` marks the followed teams playing.
    func todaysGames(in followed: FavouriteCompetition, teams: [FavouriteTeam]) async -> [Fixture] {
        let now = Date()
        let calendar = Calendar.current
        // One request per day: some scoreboards (football's) refuse a range. Yesterday for
        // late games still on; tomorrow because today here can reach into it in UTC.
        let days = Set([-1, 0, 1].map { now.addingTimeInterval(TimeInterval($0) * 86_400) }.map(SportsDate.dayParameter))
        var events: [String: ESPNEvent] = [:]
        await withTaskGroup(of: [ESPNEvent].self) { group in
            for day in days {
                let path = "/sports/\(followed.sport)/\(followed.league)/scoreboard?dates=\(day)&limit=200"
                group.addTask { (try? await self.fetch(ESPNEventsResponse.self, path))?.events ?? [] }
            }
            for await list in group {
                for event in list { events[event.id] = event }
            }
        }
        let underWaySince = now.addingTimeInterval(-4 * 3600)
        return events.values.compactMap { event -> Fixture? in
            guard let fixture = fixture(from: event, sport: followed.sport, competition: followed.name,
                                        leagueSlug: followed.league, teams: teams) else { return nil }
            let onNow = fixture.date <= now && fixture.date > underWaySince && fixture.score?.phase != .finished
            return calendar.isDateInToday(fixture.date) || onNow ? fixture : nil
        }
        .sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
    }

    /// Builds a fixture if any of `teams` is playing in the event.
    private func fixture(from event: ESPNEvent, teams: [FavouriteTeam], competition fallback: String? = nil,
                         leagueSlug: String? = nil) -> Fixture? {
        guard let competitors = event.competitions?.first?.competitors else { return nil }
        let playing = teams.filter { team in competitors.contains { $0.team?.id == team.teamID } }
        guard let first = playing.first else { return nil }
        return fixture(from: event, sport: first.sport, competition: fallback ?? first.leagueName,
                       leagueSlug: leagueSlug, teams: playing)
    }

    /// Builds a fixture for any event; `teams` are the followed ones playing in it (maybe none).
    /// - Parameter fallback: the competition's name when ESPN's event doesn't give one.
    private func fixture(from event: ESPNEvent, sport: String, competition fallback: String,
                         leagueSlug: String?, teams playing: [FavouriteTeam]) -> Fixture? {
        guard let competition = event.competitions?.first,
              let competitors = competition.competitors,
              let date = SportsDate.parse(event.date) else { return nil }
        // Postponed and cancelled games are left out; finished ones stay a while with their score.
        if let name = competition.status?.type?.name,
           name.contains("POSTPONED") || name.contains("CANCELED") || name.contains("CANCELLED") {
            return nil
        }

        func side(_ team: ESPNTeam) -> Fixture.Side {
            let followed = playing.first { $0.teamID == team.id }
            return Fixture.Side(id: team.id, name: team.displayName,
                                logo: team.logoURL ?? followed?.logo,
                                color: team.color ?? followed?.color,
                                aliases: [team.shortDisplayName].compactMap { $0 },
                                code: team.abbreviation)
        }
        let homeTeam = competitors.first { $0.homeAway == "home" }?.team ?? competitors.first?.team
        let awayTeam = competitors.first { $0.homeAway == "away" }?.team ?? competitors.last?.team
        let home = homeTeam.map(side)
        let away = awayTeam.map(side)

        var broadcasts: [String] = []
        for broadcast in competition.broadcasts ?? [] {
            if let name = broadcast.media?.shortName { broadcasts.append(name) }
            broadcasts += broadcast.names ?? []
        }

        let title = [home?.name, away?.name].compactMap { $0 }.joined(separator: " v ")
        return Fixture(
            id: "\(sport)-\(event.id)",
            date: date,
            competition: event.league?.name ?? fallback,
            title: title.isEmpty ? (event.name ?? "Match") : title,
            home: home,
            away: away,
            subtitle: competition.venue?.fullName,
            broadcasts: Array(Set(broadcasts)).sorted(),
            keywords: Array(Set((homeTeam?.keywords ?? []) + (awayTeam?.keywords ?? []))),
            followed: playing.map(\.name),
            score: Self.score(for: event),
            eventID: event.id,
            scoreboardPath: (event.league?.slug ?? leagueSlug).flatMap {
                $0.isEmpty || $0 == "all" ? nil : "/sports/\(sport)/\($0)/scoreboard"
            }
        )
    }

    /// The score and clock of a game that has started, nil before kick-off.
    private static func score(for event: ESPNEvent) -> FixtureScore? {
        guard let competition = event.competitions?.first,
              let status = competition.status?.type,
              let competitors = competition.competitors else { return nil }
        let name = status.name ?? ""
        let home = competitors.first { $0.homeAway == "home" } ?? competitors.first
        let away = competitors.first { $0.homeAway == "away" } ?? competitors.last
        let homeScore = home?.score ?? "0"
        let awayScore = away?.score ?? "0"

        switch status.state {
        case "in":
            if name.contains("HALFTIME") {
                return FixtureScore(phase: .halfTime, home: homeScore, away: awayScore,
                                    clock: "HT", period: "Half-time")
            }
            let clock = status.shortDetail ?? competition.status?.displayClock ?? "LIVE"
            return FixtureScore(phase: .live, home: homeScore, away: awayScore,
                                clock: clock, period: status.description)
        case "post":
            guard status.completed != false, home?.score != nil else { return nil }
            return FixtureScore(phase: .finished, home: homeScore, away: awayScore,
                                clock: status.shortDetail ?? "FT", period: "Full time")
        default:
            return nil
        }
    }

    /// Current scores for games under way, from each league's scoreboard (one request per league).
    func liveScores(for fixtures: [Fixture]) async -> [String: FixtureScore] {
        var groups: [String: [Fixture]] = [:]
        for fixture in fixtures where fixture.scoreboardPath != CricketClient.scorePath {
            guard let path = fixture.scoreboardPath, fixture.eventID != nil else { continue }
            groups[path, default: []].append(fixture)
        }
        var result = await CricketClient().liveScores(for: fixtures.filter { $0.scoreboardPath == CricketClient.scorePath })
        await withTaskGroup(of: [String: FixtureScore].self) { group in
            for (path, list) in groups {
                let dates = list.map(\.date)
                guard let first = dates.min(), let last = dates.max() else { continue }
                let range = SportsDate.rangeParameter(from: first.addingTimeInterval(-86_400),
                                                      to: last.addingTimeInterval(86_400))
                group.addTask {
                    guard let response = try? await self.fetch(ESPNEventsResponse.self, "\(path)?dates=\(range)&limit=300")
                    else { return [:] }
                    var found: [String: FixtureScore] = [:]
                    for event in response.events ?? [] {
                        guard let fixture = list.first(where: { $0.eventID == event.id }),
                              let score = Self.score(for: event) else { continue }
                        found[fixture.id] = score
                    }
                    return found
                }
            }
            for await part in group { result.merge(part) { _, new in new } }
        }
        return result
    }
}

/// Loads every followed team's upcoming fixtures in one go.
enum SportsLoader {
    /// Today's games in each followed competition, in the order they were followed; ones with
    /// no games today are left out. Live scores follow them like the teams' fixtures.
    static func today(in competitions: [FavouriteCompetition],
                      teams: [FavouriteTeam]) async -> [(competition: FavouriteCompetition, fixtures: [Fixture])] {
        guard !competitions.isEmpty else { return [] }
        let espn = ESPNClient()
        var found: [String: [Fixture]] = [:]
        await withTaskGroup(of: (String, [Fixture]).self) { group in
            for competition in competitions {
                group.addTask { (competition.id, await espn.todaysGames(in: competition, teams: teams)) }
            }
            for await (id, fixtures) in group { found[id] = fixtures }
        }
        await LiveScores.shared.track(found.values.flatMap { $0 })
        return competitions.compactMap { competition in
            guard let fixtures = found[competition.id], !fixtures.isEmpty else { return nil }
            return (competition, fixtures)
        }
    }

    static func upcoming(teams: [FavouriteTeam], days: Int) async -> [Fixture] {
        guard !teams.isEmpty else { return [] }
        let espn = ESPNClient()
        let rugby = teams.filter { $0.sport == "rugby" }
        let cricket = teams.filter { $0.sport == "cricket" }
        let rugbyLeague = teams.filter { $0.sport == SuperLeagueClient.sport }
        let f1Names = teams.filter(\.isF1).map(\.name)
        var found: [Fixture] = []

        // Cricket and the Super League have their own sources; the rest are read from ESPN per team.
        let ownSources: Set<String> = ["rugby", "cricket", SuperLeagueClient.sport]
        await withTaskGroup(of: [Fixture].self) { group in
            for team in teams where !team.isF1 && !ownSources.contains(team.sport) {
                group.addTask { await espn.upcomingFixtures(for: team, days: days) }
            }
            if !rugby.isEmpty {
                group.addTask { await espn.rugbyFixtures(for: rugby, days: days) }
            }
            if !cricket.isEmpty {
                group.addTask { await CricketClient().fixtures(for: cricket, days: days) }
            }
            if !rugbyLeague.isEmpty {
                group.addTask { await SuperLeagueClient().fixtures(for: rugbyLeague, days: days) }
            }
            if !f1Names.isEmpty {
                group.addTask {
                    guard let race = try? await F1Client().nextRace(followed: f1Names) else { return [] }
                    // Show the weekend once its first session is inside the window.
                    let starts = race.sessions.first?.date ?? race.date
                    return starts <= Date().addingTimeInterval(TimeInterval(days) * 86_400) ? [race] : []
                }
            }
            for await list in group { found += list }
        }

        // Two followed teams in the same match: show it once, naming both.
        var merged: [String: Fixture] = [:]
        for fixture in found {
            if var existing = merged[fixture.id] {
                existing.followed = Array(Set(existing.followed + fixture.followed)).sorted()
                merged[fixture.id] = existing
            } else {
                merged[fixture.id] = fixture
            }
        }
        // Games under way or just finished that the schedules no longer list
        // (football's fixture lists drop a game once it starts).
        let followedNames = Set(teams.map(\.name))
        for fixture in await LiveScores.shared.recentFixtures(excluding: Set(merged.keys)) {
            if !followedNames.isDisjoint(with: fixture.followed) { merged[fixture.id] = fixture }
        }
        let sorted = merged.values.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
        await LiveScores.shared.track(sorted)
        await ReminderStore.shared.fixturesLoaded(sorted, teams: followedNames)
        return sorted
    }
}

// MARK: - Formula 1 (Jolpica, the Ergast successor)

struct F1Constructor: Hashable, Identifiable {
    let id: String
    let name: String
}

struct F1Client {
    private struct Response: Decodable {
        let data: MRData
        private enum CodingKeys: String, CodingKey { case data = "MRData" }
    }

    private struct MRData: Decodable {
        let raceTable: RaceTable?
        let constructorTable: ConstructorTable?
        private enum CodingKeys: String, CodingKey {
            case raceTable = "RaceTable"
            case constructorTable = "ConstructorTable"
        }
    }

    private struct RaceTable: Decodable {
        let races: [Race]
        private enum CodingKeys: String, CodingKey { case races = "Races" }
    }

    private struct ConstructorTable: Decodable {
        struct Constructor: Decodable { let constructorId: String; let name: String }
        let constructors: [Constructor]
        private enum CodingKeys: String, CodingKey { case constructors = "Constructors" }
    }

    private struct SessionTime: Decodable {
        let date: String
        let time: String?
    }

    private struct Race: Decodable {
        struct Circuit: Decodable {
            struct Location: Decodable { let locality: String?; let country: String? }
            let circuitName: String?
            let location: Location?
            private enum CodingKeys: String, CodingKey { case circuitName, location = "Location" }
        }

        let season: String
        let round: String
        let raceName: String
        let circuit: Circuit?
        let date: String
        let time: String?
        let firstPractice: SessionTime?
        let secondPractice: SessionTime?
        let thirdPractice: SessionTime?
        let sprintQualifying: SessionTime?
        let sprint: SessionTime?
        let qualifying: SessionTime?

        private enum CodingKeys: String, CodingKey {
            case season, round, raceName, date, time
            case circuit = "Circuit"
            case firstPractice = "FirstPractice"
            case secondPractice = "SecondPractice"
            case thirdPractice = "ThirdPractice"
            case sprintQualifying = "SprintQualifying"
            case sprint = "Sprint"
            case qualifying = "Qualifying"
        }
    }

    private static let base = "https://api.jolpi.ca/ergast/f1"

    private func fetch(_ path: String) async throws -> MRData {
        guard let url = URL(string: Self.base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data = try await URLSession.shared.fetch(request)
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    func constructors() async throws -> [F1Constructor] {
        let data = try await fetch("/current/constructors.json")
        return (data.constructorTable?.constructors ?? []).map { F1Constructor(id: $0.constructorId, name: $0.name) }
    }

    /// "2026-03-08" + "04:00:00Z" → a Date (UTC). Without a time, midday UTC.
    private static func date(_ date: String, _ time: String?) -> Date? {
        SportsDate.parse("\(date)T\(time ?? "12:00:00Z")")
    }

    /// The next race weekend that hasn't finished, as a fixture.
    func nextRace(followed: [String]) async throws -> Fixture? {
        let data = try await fetch("/current.json")
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        let races = data.raceTable?.races ?? []
        guard let race = races.first(where: { (Self.date($0.date, $0.time) ?? .distantPast) > cutoff }),
              let raceDate = Self.date(race.date, race.time) else { return nil }

        var sessions: [Fixture.Session] = []
        func add(_ name: String, _ session: SessionTime?) {
            if let session, let date = Self.date(session.date, session.time) {
                sessions.append(Fixture.Session(name: name, date: date))
            }
        }
        add(String(localized: "Practice 1"), race.firstPractice)
        add(String(localized: "Practice 2"), race.secondPractice)
        add(String(localized: "Practice 3"), race.thirdPractice)
        add(String(localized: "Sprint Qualifying"), race.sprintQualifying)
        add(String(localized: "Sprint"), race.sprint)
        add(String(localized: "Qualifying"), race.qualifying)
        sessions.append(Fixture.Session(name: String(localized: "Race"), date: raceDate))
        sessions.sort { $0.date < $1.date }

        let locality = race.circuit?.location?.locality
        let place = [race.circuit?.circuitName, locality, race.circuit?.location?.country]
            .compactMap { $0 }.joined(separator: ", ")
        var keywords = ["formula 1", "formula one", "f1", "grand prix", race.raceName.lowercased()]
        if let locality, locality.count >= 4 { keywords.append(locality.lowercased()) }

        return Fixture(
            id: "f1-\(race.season)-\(race.round)",
            date: raceDate,
            competition: "Formula 1 · Round \(race.round)",
            title: race.raceName,
            home: nil,
            away: nil,
            subtitle: place.isEmpty ? nil : place,
            sessions: sessions,
            keywords: keywords,
            followed: followed
        )
    }
}
