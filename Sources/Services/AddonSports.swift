import Foundation

/// Finds a fixture in the user's Stremio addons. Sports addons come in two kinds: some list
/// games ("Wigan Warriors vs Leeds Rhinos"), found by both team names; others list channels
/// ("Sky Sports Main Event"), found by the broadcasters ESPN names for the game or the
/// channels Tellio found it on in the TV guide. Only catalogues that aren't movies or series
/// are read.
struct AddonSportsHit: Identifiable {
    /// The game itself; a channel showing it; or a channel from the addon's list for the
    /// game's sport, which may be showing it (shown last, when nothing else says so).
    enum Kind { case game, channel, sportChannel }

    let id: String
    let addonName: String
    /// The game or channel as the addon names it.
    let title: String
    let kind: Kind
    let stream: StremioStream
}

enum AddonSports {
    /// - Parameter channelNames: channels the TV guide search found the game on.
    static func search(_ fixture: Fixture, addons: [AddonEntry], channelNames: [String]) async -> [AddonSportsHit] {
        let teams = teamNames(fixture)
        let channels = Array(Set((fixture.broadcasts + channelNames).map(GuideText.phrase).filter { $0.count >= 3 }))
        guard !teams.isEmpty || !channels.isEmpty else { return [] }

        var hits: [AddonSportsHit] = []
        await withTaskGroup(of: [AddonSportsHit].self) { group in
            for addon in addons {
                guard let url = URL(string: addon.manifestURL) else { continue }
                group.addTask {
                    await search(addon: addon, url: url, fixture: fixture, teams: teams, channels: channels)
                }
            }
            for await found in group { hits += found }
        }
        // Games first (they are the match itself), then channels; addon order within each.
        let order = Dictionary(addons.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        func rank(_ kind: AddonSportsHit.Kind) -> Int {
            switch kind {
            case .game: return 0
            case .channel: return 1
            case .sportChannel: return 2
            }
        }
        return hits.sorted { a, b in
            if a.kind != b.kind { return rank(a.kind) < rank(b.kind) }
            return (order[a.addonName] ?? 0) < (order[b.addonName] ?? 0)
        }
    }

    /// Whether any addon has a catalogue that could hold sports (anything but movies and series).
    static func hasLiveCatalogues(_ addons: [AddonEntry]) async -> Bool {
        for addon in addons {
            guard let url = URL(string: addon.manifestURL),
                  let manifest = await AddonManifests.shared.manifest(url) else { continue }
            if !liveCatalogues(manifest).isEmpty { return true }
        }
        return false
    }

    // MARK: One addon

    private static func search(addon: AddonEntry, url: URL, fixture: Fixture,
                               teams: [(home: [String], away: [String])], channels: [String]) async -> [AddonSportsHit] {
        guard let manifest = await AddonManifests.shared.manifest(url) else { return [] }
        let catalogues = liveCatalogues(manifest)
        guard !catalogues.isEmpty else { return [] }
        let client = StremioAddonClient(manifestURL: url)

        // Everything each catalogue offers that might be this game, by meta id.
        var found: [String: (meta: StremioMeta, kind: AddonSportsHit.Kind)] = [:]
        for catalogue in catalogues {
            var metas: [StremioMeta] = []
            if catalogue.supportsSearch {
                // Each team's full name, and the first few channels.
                let names = teams.flatMap { [$0.home.first, $0.away.first].compactMap { $0 } }
                for query in Set(names + channels.prefix(4)) {
                    metas += (try? await client.catalog(type: catalogue.type, id: catalogue.id, search: query)) ?? []
                }
            }
            if !catalogue.needsExtra {
                metas += (try? await client.catalog(type: catalogue.type, id: catalogue.id, search: nil)) ?? []
            }
            for meta in metas {
                if let kind = match(meta, teams: teams, channels: channels), found[meta.id] == nil {
                    found[meta.id] = (meta, kind)
                }
            }
        }

        found = narrowGames(found, fixture: fixture)

        // A list for the game's sport ("Cricket") whose channels may be showing it: offered
        // after any real matches, leaving out other games it lists.
        let sportLists = catalogues.filter { isFor(sport: fixture, $0) && !$0.needsExtra }
        var offered = 0
        for catalogue in sportLists where offered < 6 {
            let metas = (try? await client.catalog(type: catalogue.type, id: catalogue.id, search: nil)) ?? []
            for meta in metas where offered < 6 && found[meta.id] == nil && !GuideText.hasVersus(meta.name ?? "") {
                found[meta.id] = (meta, .sportChannel)
                offered += 1
            }
        }

        var hits: [AddonSportsHit] = []
        await withTaskGroup(of: [AddonSportsHit].self) { group in
            for (id, entry) in found.prefix(12) {
                group.addTask {
                    let streams = (try? await client.streams(type: entry.meta.type ?? "tv", id: id)) ?? []
                    return streams.enumerated().compactMap { index, stream in
                        guard stream.playableURL != nil else { return nil }
                        return AddonSportsHit(id: "\(addon.manifestURL)|\(id)|\(index)", addonName: addon.name,
                                              title: entry.meta.name ?? id, kind: entry.kind, stream: stream)
                    }
                }
            }
            for await list in group { hits += list }
        }
        return hits
    }

    /// Catalogues for anything other than movies and series, that can be read without a
    /// genre or other filter (search excepted).
    private static func liveCatalogues(_ manifest: AddonManifest) -> [AddonCatalogue] {
        (manifest.catalogs ?? []).filter { catalogue in
            !["movie", "series", "anime"].contains(catalogue.type.lowercased())
                && (catalogue.supportsSearch || !catalogue.needsExtra)
        }
    }

    // MARK: Matching

    /// Addons list each day of a Test, and the same two teams' other games, separately. Only
    /// listings dated within this game's days are kept, and of those the one on now, or else
    /// the soonest (later days only say when they start).
    private static func narrowGames(_ found: [String: (meta: StremioMeta, kind: AddonSportsHit.Kind)],
                                    fixture: Fixture) -> [String: (meta: StremioMeta, kind: AddonSportsHit.Kind)] {
        let games = found.filter { $0.value.kind == .game }
        guard !games.isEmpty else { return found }
        let from = fixture.date.addingTimeInterval(-12 * 3600)
        let until = fixture.lastsUntil.addingTimeInterval(12 * 3600)

        var dated: [(id: String, date: Date?, live: Bool)] = []
        for (id, entry) in games {
            let text = (entry.meta.name ?? "") + " " + (entry.meta.description ?? "")
            let date = listedDate(text)
            if let date, date < from || date > until { continue }
            if date == nil && !(from...until).contains(Date()) && text.lowercased().contains("live now") { continue }
            // "LIVE NOW" has no date, so it only counts while this game is on (not another
            // game between the same teams on a different day).
            let onNow = (from...until).contains(Date())
            dated.append((id, date, onNow && text.lowercased().contains("live now")))
        }
        let keep: Set<String>
        if dated.contains(where: { $0.live }) {
            keep = Set(dated.filter { $0.live }.map { $0.id })
        } else if let soonest = dated.compactMap({ $0.date }).min() {
            // The soonest dated listing, plus any that give no date at all.
            keep = Set(dated.filter { $0.date == nil || $0.date == soonest }.map { $0.id })
        } else {
            keep = Set(dated.map { $0.id })
        }
        return found.filter { $0.value.kind != .game || keep.contains($0.key) }
    }

    private static let listedDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()

    /// "25 Nov 2026 · 08:00 UTC", as sports addons often write a start time.
    private static func listedDate(_ text: String) -> Date? {
        guard let range = text.range(of: #"\d{1,2} [A-Za-z]{3} \d{4} · \d{1,2}:\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return listedDateFormat.date(from: text[range].replacingOccurrences(of: " · ", with: " "))
    }

    /// Whether a catalogue is the addon's list for the fixture's sport, by its name or id.
    private static func isFor(sport fixture: Fixture, _ catalogue: AddonCatalogue) -> Bool {
        let sport = fixture.id.split(separator: "-").first.map(String.init) ?? ""
        let words: [String]
        switch sport {
        case "soccer": words = ["football", "soccer"]
        case "cricket": words = ["cricket"]
        case "rugby", SuperLeagueClient.sport: words = ["rugby"]
        case "football": words = ["american football", "nfl"]
        case "basketball": words = ["basketball", "nba"]
        case "hockey": words = ["hockey", "nhl"]
        case "baseball": words = ["baseball", "mlb"]
        case "f1": words = ["motor", "f1", "formula"]
        default: return false
        }
        let text = GuideText.normalize((catalogue.name ?? "") + " " + catalogue.id.replacingOccurrences(of: "_", with: " "))
        // Football's list isn't American football's.
        if sport == "soccer" && text.contains(" american ") { return false }
        return words.contains { text.contains(" " + $0 + " ") }
    }

    /// Each team's names, normalized: the full name first, then the other names the TV guide
    /// search uses ("Man City", "Wigan"), which never shorten to a word two clubs share.
    private static func teamNames(_ fixture: Fixture) -> [(home: [String], away: [String])] {
        func names(_ side: Fixture.Side?) -> [String] {
            guard let side else { return [] }
            let full = GuideText.phrase(side.name)
            let others = TeamNames.aliases(side.name, extra: side.aliases).filter { $0 != full }
            return ([full] + others.sorted { $0.count > $1.count }).filter { $0.count >= 3 }
        }
        let home = names(fixture.home), away = names(fixture.away)
        // A game listing has to name both sides; otherwise any game of either team would match.
        return home.isEmpty || away.isEmpty ? [] : [(home, away)]
    }

    private static func match(_ meta: StremioMeta, teams: [(home: [String], away: [String])],
                              channels: [String]) -> AddonSportsHit.Kind? {
        let name = meta.name ?? ""
        let text = GuideText.normalize(name + " " + (meta.description ?? ""))
        func has(_ phrase: String) -> Bool { text.contains(" " + phrase + " ") }
        for side in teams where side.home.contains(where: has) && side.away.contains(where: has) {
            return .game
        }
        let title = GuideText.phrase(name)
        for channel in channels {
            // "Sky Sports Main Event" matches "Sky Sports Main Event HD" and "UK: Sky Sports Main Event".
            if title == channel || GuideText.normalize(name).contains(" " + channel + " ") { return .channel }
        }
        return nil
    }
}

/// Addon manifests, kept for an hour: catalogues don't change often.
actor AddonManifests {
    static let shared = AddonManifests()
    private var cache: [URL: (date: Date, value: AddonManifest)] = [:]

    func manifest(_ url: URL) async -> AddonManifest? {
        if let cached = cache[url], Date().timeIntervalSince(cached.date) < 3600 { return cached.value }
        guard let manifest = try? await StremioAddonClient(manifestURL: url).manifest() else { return cache[url]?.value }
        cache[url] = (Date(), manifest)
        return manifest
    }
}
