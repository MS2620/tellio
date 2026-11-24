import Foundation

/// Rugby league's Super League, which ESPN doesn't cover, from TheSportsDB. This uses the
/// site's shared free key: it answers slowly, limits how many requests can be made a minute
/// and returns only part of a season, so fixtures here are best effort. Answers are kept on
/// the Apple TV for a few hours so Tellio asks as little as possible.
struct SuperLeagueClient {
    static let sport = "rugbyleague"
    static let leagueID = "4415"
    static let league = SportLeague(sport: sport, slug: leagueID, name: "Super League")

    /// This season's clubs. The free key lists only the first 10 of a league's teams, A–Z,
    /// so any it leaves out are looked up one by one by name.
    static let clubs = [
        "Bradford Bulls", "Castleford Tigers", "Catalans Dragons", "Huddersfield Giants", "Hull FC",
        "Hull Kingston Rovers", "Leeds Rhinos", "Leigh Leopards", "St Helens", "Toulouse Olympique",
        "Wakefield Trinity", "Warrington Wolves", "Wigan Warriors", "York Knights",
    ]

    func teams() async throws -> [ESPNTeam] {
        let response: TeamsResponse = try await SportsDBCache.shared.get(
            "search_all_teams.php?l=English_Rugby_League_Super_League", maxAge: 7 * 86_400)
        var found = (response.teams ?? []).filter { $0.idLeague == nil || $0.idLeague == Self.leagueID }
        let listed = Set(found.map { Self.simplified($0.strTeam) })
        for club in Self.clubs where !listed.contains(Self.simplified(club)) {
            let query = club.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? club
            let result: TeamsResponse? = try? await SportsDBCache.shared.get("searchteams.php?t=\(query)", maxAge: 7 * 86_400)
            // Same-named clubs in other sports (Wakefield, Bradford…) are skipped.
            if let team = result?.teams?.first(where: { $0.idLeague == Self.leagueID }) { found.append(team) }
        }
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.idTeam).inserted }
            .map { ESPNTeam(id: $0.idTeam, displayName: $0.strTeam, shortDisplayName: $0.strTeamShort,
                            logoURL: $0.strBadge, color: $0.strColour1?.replacingOccurrences(of: "#", with: "")) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// "Hull F.C." and "Hull FC" are the same club.
    private static func simplified(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Followed Super League teams' games in the next `days`.
    func fixtures(for teams: [FavouriteTeam], days: Int) async -> [Fixture] {
        guard !teams.isEmpty else { return [] }
        var events: [String: SportsDBEvent] = [:]
        // Each team's next games, and the season's list: the free key cuts both short,
        // so between them they cover as much as it allows.
        for team in teams {
            let next: EventsResponse? = try? await SportsDBCache.shared.get("eventsnext.php?id=\(team.teamID)", maxAge: 6 * 3600)
            for event in next?.events ?? [] { events[event.idEvent] = event }
        }
        let year = Calendar.current.component(.year, from: Date())
        for season in [year, year + 1] {
            let list: EventsResponse? = try? await SportsDBCache.shared.get(
                "eventsseason.php?id=\(Self.leagueID)&s=\(season)", maxAge: 12 * 3600)
            for event in list?.events ?? [] { events[event.idEvent] = event }
        }
        return ESPNClient.window(events.values.compactMap { Self.fixture($0, teams: teams) }, days: days)
    }

    private static func fixture(_ event: SportsDBEvent, teams: [FavouriteTeam]) -> Fixture? {
        let playing = teams.filter { $0.teamID == event.idHomeTeam || $0.teamID == event.idAwayTeam }
        guard !playing.isEmpty, let date = event.date else { return nil }
        let status = (event.strStatus ?? "").lowercased()
        if status.contains("postponed") || status.contains("cancel") { return nil }

        func side(id: String?, name: String?, badge: String?) -> Fixture.Side? {
            guard let id, let name else { return nil }
            let followed = playing.first { $0.teamID == id }
            return Fixture.Side(id: id, name: name, logo: badge ?? followed?.logo, color: followed?.color)
        }
        let home = side(id: event.idHomeTeam, name: event.strHomeTeam, badge: event.strHomeTeamBadge)
        let away = side(id: event.idAwayTeam, name: event.strAwayTeam, badge: event.strAwayTeamBadge)

        var score: FixtureScore?
        if let homeScore = event.intHomeScore, let awayScore = event.intAwayScore,
           status.contains("finished") || status == "ft" || status == "aet" {
            score = FixtureScore(phase: .finished, home: homeScore, away: awayScore,
                                 clock: "FT", period: String(localized: "Full time"))
        }
        let names = [home?.name, away?.name].compactMap { $0 }
        return Fixture(
            id: "\(sport)-\(event.idEvent)",
            date: date,
            competition: league.name,
            title: names.isEmpty ? (event.strEvent ?? "Match") : names.joined(separator: " v "),
            home: home,
            away: away,
            subtitle: event.strVenue,
            broadcasts: (event.strTVStation ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            keywords: names.map { $0.lowercased() }.filter { $0.count >= 4 },
            followed: playing.map(\.name),
            score: score,
            eventID: event.idEvent
        )
    }
}

/// TheSportsDB answers, kept in memory and on disk for `maxAge` so the free key's
/// request limit is rarely reached. A stale answer is used when a new one can't be had.
actor SportsDBCache {
    static let shared = SportsDBCache()
    private static let base = "https://www.thesportsdb.com/api/v1/json/123/"

    private var memory: [String: (fetched: Date, data: Data)] = [:]

    func get<T: Decodable>(_ path: String, maxAge: TimeInterval) async throws -> T {
        let saved = memory[path] ?? load(path)
        if let saved, Date().timeIntervalSince(saved.fetched) < maxAge {
            return try JSONDecoder().decode(T.self, from: saved.data)
        }
        do {
            guard let url = URL(string: Self.base + path) else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let data = try await URLSession.shared.fetch(request)
            let decoded = try JSONDecoder().decode(T.self, from: data)
            memory[path] = (Date(), data)
            store(path, data)
            return decoded
        } catch {
            if let saved, let decoded = try? JSONDecoder().decode(T.self, from: saved.data) { return decoded }
            throw error
        }
    }

    private func file(_ path: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let name = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        return caches.appendingPathComponent("sportsdb-\(name).json")
    }

    private func load(_ path: String) -> (fetched: Date, data: Data)? {
        guard let url = file(path), let data = try? Data(contentsOf: url),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return (date, data)
    }

    private func store(_ path: String, _ data: Data) {
        guard let url = file(path) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Models

private struct TeamsResponse: Decodable {
    struct Team: Decodable {
        let idTeam: String
        let strTeam: String
        let strTeamShort: String?
        let strBadge: String?
        let strColour1: String?
        let idLeague: String?
    }
    let teams: [Team]?
}

private struct EventsResponse: Decodable {
    let events: [SportsDBEvent]?
}

private struct SportsDBEvent: Decodable {
    let idEvent: String
    let strEvent: String?
    /// UTC, "2026-02-21T18:00:00".
    let strTimestamp: String?
    let dateEvent: String?
    let strTime: String?
    let idHomeTeam: String?
    let idAwayTeam: String?
    let strHomeTeam: String?
    let strAwayTeam: String?
    let strHomeTeamBadge: String?
    let strAwayTeamBadge: String?
    let intHomeScore: String?
    let intAwayScore: String?
    let strStatus: String?
    let strVenue: String?
    let strTVStation: String?

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    var date: Date? {
        if let stamp = strTimestamp, let date = Self.parser.date(from: String(stamp.prefix(19))) { return date }
        guard let day = dateEvent else { return nil }
        return Self.parser.date(from: "\(day)T\(strTime?.prefix(8) ?? "00:00:00")")
    }
}
