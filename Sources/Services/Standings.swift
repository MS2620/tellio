import Foundation

/// One line of a league table or championship.
struct StandingRow: Identifiable, Hashable {
    let id: String
    let rank: Int
    let name: String
    var logo: String? = nil
    /// Small extra line, e.g. an F1 driver's team.
    var detail: String? = nil
    var played: String? = nil
    var difference: String? = nil
    let points: String
    var isFollowed = false
}

/// A table: a league, a conference within one, or an F1 championship.
struct StandingTable: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [StandingRow]
    /// Football-style columns (P, GD); F1 shows wins instead.
    var showsPlayedAndDifference = true
}

/// One tab on the Sports page: everything for one league.
struct StandingTab: Identifiable, Hashable {
    let id: String
    let title: String
    let tables: [StandingTable]
}

// MARK: - ESPN

private struct ESPNStandingsResponse: Decodable {
    struct Group: Decodable {
        let name: String?
        let standings: Standings?
        let children: [Group]?
    }
    struct Standings: Decodable { let entries: [Entry]? }
    struct Entry: Decodable {
        struct Team: Decodable {
            struct Logo: Decodable { let href: String? }
            let id: String?
            let displayName: String?
            let logos: [Logo]?
        }
        struct Stat: Decodable {
            let name: String?
            let displayValue: String?
            let value: Double?
        }
        let team: Team?
        let stats: [Stat]?
    }
    let name: String?
    let children: [Group]?
    let standings: Standings?
}

/// League tables from ESPN and F1 championships from Jolpica (the F1 data the app already uses).
struct StandingsClient {
    private static let espn = "https://site.api.espn.com/apis/v2/sports"
    private static let jolpica = "https://api.jolpi.ca/ergast/f1"

    /// Tabs for the user's teams: one per league they play in, and F1 drivers and constructors.
    func tabs(for teams: [FavouriteTeam]) async -> [StandingTab] {
        var seen = Set<String>()
        var leagues: [FavouriteTeam] = []
        // Cricket and the Super League have no ESPN tables.
        for team in teams where !team.isF1 && team.sport != "cricket" && team.sport != SuperLeagueClient.sport {
            let key = "\(team.sport)/\(team.league)"
            if !seen.contains(key) {
                seen.insert(key)
                leagues.append(team)
            }
        }
        let followedIDs = Set(teams.map(\.teamID))
        var tabs: [StandingTab] = []
        for league in leagues {
            if let tab = try? await espnTab(sport: league.sport, league: league.league,
                                            title: league.leagueName, followed: followedIDs) {
                tabs.append(tab)
            }
        }
        let constructors = teams.filter(\.isF1).map(\.name)
        if !constructors.isEmpty {
            tabs += await f1Tabs(followed: constructors)
        }
        return tabs
    }

    private func espnTab(sport: String, league: String, title: String, followed: Set<String>) async throws -> StandingTab {
        guard let url = URL(string: "\(Self.espn)/\(sport)/\(league)/standings") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data = try await URLSession.shared.fetch(request)
        let response = try JSONDecoder().decode(ESPNStandingsResponse.self, from: data)

        // Leagues come as one table, or split into groups (conferences, pools), sometimes nested.
        var tables: [StandingTable] = []
        func collect(_ group: ESPNStandingsResponse.Group) {
            if let entries = group.standings?.entries, !entries.isEmpty {
                tables.append(table(id: "\(league)-\(tables.count)", title: group.name ?? title,
                                    entries: entries, followed: followed))
            }
            group.children?.forEach(collect)
        }
        response.children?.forEach(collect)
        if tables.isEmpty, let entries = response.standings?.entries {
            tables.append(table(id: league, title: title, entries: entries, followed: followed))
        }
        guard !tables.isEmpty else { throw URLError(.cannotParseResponse) }
        // A league split into groups shows the group with the user's team first.
        tables.sort { a, b in
            let fa = a.rows.contains(where: \.isFollowed), fb = b.rows.contains(where: \.isFollowed)
            return fa && !fb
        }
        return StandingTab(id: "\(sport)/\(league)", title: title, tables: tables)
    }

    private func table(id: String, title: String, entries: [ESPNStandingsResponse.Entry],
                       followed: Set<String>) -> StandingTable {
        let rows = entries.enumerated().map { index, entry -> StandingRow in
            func stat(_ name: String) -> String? {
                entry.stats?.first { $0.name == name }?.displayValue.flatMap { $0.isEmpty ? nil : $0 }
            }
            let rank = stat("rank").flatMap(Int.init) ?? index + 1
            return StandingRow(id: entry.team?.id ?? "\(index)", rank: rank,
                               name: entry.team?.displayName ?? "—",
                               logo: entry.team?.logos?.first?.href,
                               played: stat("gamesPlayed"),
                               difference: stat("pointDifferential"),
                               points: stat("points") ?? stat("wins") ?? "—",
                               isFollowed: entry.team?.id.map(followed.contains) ?? false)
        }
        return StandingTable(id: id, title: title, rows: rows.sorted { $0.rank < $1.rank })
    }

    // MARK: F1

    private struct JolpicaData: Decodable {
        struct Table: Decodable {
            struct List: Decodable {
                struct DriverStanding: Decodable {
                    struct DriverInfo: Decodable { let driverId: String; let givenName: String; let familyName: String }
                    struct ConstructorName: Decodable { let name: String }
                    let position: String?
                    let points: String
                    let wins: String?
                    let Driver: DriverInfo
                    let Constructors: [ConstructorName]?
                }
                struct ConstructorStanding: Decodable {
                    struct ConstructorInfo: Decodable { let constructorId: String; let name: String }
                    let position: String?
                    let points: String
                    let wins: String?
                    let Constructor: ConstructorInfo
                }
                let DriverStandings: [DriverStanding]?
                let ConstructorStandings: [ConstructorStanding]?
            }
            let StandingsLists: [List]
        }
        let StandingsTable: Table
    }

    private struct Envelope: Decodable { let MRData: JolpicaData }

    private func f1(_ path: String) async throws -> JolpicaData.Table.List? {
        guard let url = URL(string: Self.jolpica + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data = try await URLSession.shared.fetch(request)
        return try JSONDecoder().decode(Envelope.self, from: data).MRData.StandingsTable.StandingsLists.first
    }

    private func f1Tabs(followed: [String]) async -> [StandingTab] {
        func matches(_ name: String) -> Bool {
            followed.contains { $0.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0) }
        }
        var tabs: [StandingTab] = []
        if let list = try? await f1("/current/driverStandings.json"), let standings = list.DriverStandings {
            let rows = standings.enumerated().map { index, s in
                StandingRow(id: s.Driver.driverId, rank: s.position.flatMap(Int.init) ?? index + 1,
                            name: "\(s.Driver.givenName) \(s.Driver.familyName)",
                            detail: s.Constructors?.first?.name,
                            played: s.wins.map { "\($0) wins" },
                            points: s.points,
                            isFollowed: s.Constructors?.contains { matches($0.name) } ?? false)
            }
            tabs.append(StandingTab(id: "f1-drivers", title: String(localized: "F1 Drivers"),
                                    tables: [StandingTable(id: "f1-drivers", title: String(localized: "Drivers' championship"),
                                                           rows: rows, showsPlayedAndDifference: false)]))
        }
        if let list = try? await f1("/current/constructorStandings.json"), let standings = list.ConstructorStandings {
            let rows = standings.enumerated().map { index, s in
                StandingRow(id: s.Constructor.constructorId, rank: s.position.flatMap(Int.init) ?? index + 1,
                            name: s.Constructor.name,
                            played: s.wins.map { "\($0) wins" },
                            points: s.points,
                            isFollowed: matches(s.Constructor.name))
            }
            tabs.append(StandingTab(id: "f1-constructors", title: String(localized: "F1 Constructors"),
                                    tables: [StandingTable(id: "f1-constructors", title: String(localized: "Constructors' championship"),
                                                           rows: rows, showsPlayedAndDifference: false)]))
        }
        return tabs
    }
}
