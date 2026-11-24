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

    /// What the row shows: the game when a channel carries it in brackets, without the
    /// country prefixes and quality tags in front.
    var displayTitle: String { ListingTitle.parts(title).title }
    /// The channel showing it, when the listing named both.
    var channel: String? { ListingTitle.parts(title).channel }

    /// What tells this stream apart: its quality or label, without emoji, tips or the addon's
    /// own name. Nil when the addon gives nothing useful.
    var streamLabel: String? {
        let listing = GuideText.phrase(title)
        func usable(_ text: String?) -> [String] {
            (text ?? "").components(separatedBy: .newlines).compactMap { line in
                let cleaned = Self.cleaned(line, addonName: addonName)
                let phrase = GuideText.phrase(cleaned)
                guard !phrase.isEmpty, phrase != listing, !listing.contains(phrase) || phrase.count < 4,
                      !phrase.hasPrefix("tip ") else { return nil }
                return cleaned
            }
        }
        var lines = usable(stream.name)
        if lines.isEmpty { lines = usable(stream.title) + usable(stream.description) }
        var label = lines.prefix(2).joined(separator: " · ")
        if label.count > 60 { label = String(label.prefix(59)) + "…" }
        if let quality = qualityLabel, !GuideText.normalize(label).contains(" " + GuideText.phrase(quality) + " ") {
            label = label.isEmpty ? quality : quality + " · " + label
        }
        return label.isEmpty ? nil : label
    }

    /// "1080p", from whatever the addon wrote on the stream ("FHD", "1080"), or else in the
    /// listing's name ("(FHD) : Example Sports").
    private var qualityLabel: String? {
        var lines = stream.resolution
        if lines == 0 {
            let words = Set(GuideText.phrase(title).split(separator: " ").map(String.init))
            if !words.isDisjoint(with: ["4k", "uhd", "2160p"]) { lines = 2160 }
            else if !words.isDisjoint(with: ["fhd", "1080p", "1080"]) { lines = 1080 }
            else if !words.isDisjoint(with: ["hd", "720p"]) { lines = 720 }
        }
        return lines > 0 ? (lines == 2160 ? "4K" : "\(lines)p") : nil
    }

    /// A line without emoji or the addon's name, its spaces tidied.
    private static func cleaned(_ line: String, addonName: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            let p = scalar.properties
            let emoji = p.isEmojiPresentation || (p.isEmoji && scalar.value >= 0x2100)
                || scalar.value == 0xFE0F || scalar.value == 0x200D
            if !emoji { scalars.append(scalar) }
        }
        var text = String(scalars)
        if !addonName.isEmpty { text = text.replacingOccurrences(of: addonName, with: " ", options: .caseInsensitive) }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|:·•-–,")))
    }

    /// For the source chooser: "1080p · Addon", or "Source 2 · Addon" when there's no label.
    func chooserLabel(number: Int) -> String {
        "\(streamLabel ?? String(localized: "Source \(number)")) · \(addonName)"
    }
}

/// The same game or channel shown as one row: from different addons, or one addon's several
/// streams of it. Its sources are chosen from when there's more than one.
struct AddonSportsGroup: Identifiable {
    let hits: [AddonSportsHit]

    var id: String { hits[0].id }
    var first: AddonSportsHit { hits[0] }
    var title: String { first.displayTitle }
    var kind: AddonSportsHit.Kind { first.kind }
    /// "Example TV · 1080p · Addon", or "Example TV · 2 sources · Addon, Other addon".
    var subtitle: String {
        var names: [String] = []
        for hit in hits where !names.contains(hit.addonName) { names.append(hit.addonName) }
        let detail = hits.count > 1
            ? String(localized: "\(hits.count) sources · \(names.joined(separator: ", "))")
            : [first.streamLabel, first.addonName].compactMap { $0 }.joined(separator: " · ")
        return [first.channel, detail].compactMap { $0 }.joined(separator: " · ")
    }
}

enum AddonSports {
    /// Puts together results that are the same game or channel (by their tidied names), from
    /// any addon, keeping their order.
    static func grouped(_ hits: [AddonSportsHit]) -> [AddonSportsGroup] {
        func key(_ hit: AddonSportsHit) -> String {
            GuideText.phrase(hit.displayTitle) + "|" + GuideText.phrase(hit.channel ?? "")
        }
        var groups: [[AddonSportsHit]] = []
        for hit in hits {
            let hitKey = key(hit)
            if let index = groups.firstIndex(where: { group in
                group[0].kind == hit.kind && key(group[0]) == hitKey
            }) {
                groups[index].append(hit)
            } else {
                groups.append([hit])
            }
        }
        return groups.map(AddonSportsGroup.init)
    }

    /// The rows for a match's "From your addons": the game and the channels showing it, and,
    /// only when there are none, channels for the sport that may be showing it.
    static func sections(_ hits: [AddonSportsHit]) -> (matches: [AddonSportsGroup], maybe: [AddonSportsGroup]) {
        let matches = grouped(hits.filter { $0.kind != .sportChannel })
        return (matches, matches.isEmpty ? grouped(hits.filter { $0.kind == .sportChannel }) : [])
    }

    /// How long one addon gets for the whole search, so a slow one can't hold up the rest.
    static let addonTimeout: Double = 20
    /// Requests sent to one addon at a time.
    private static let concurrentRequests = 6

    /// Searches every addon at once. After each one finishes (or runs out of time), `progress`
    /// gets everything found so far, best first, and how many addons are still searching.
    /// - Parameter channelNames: channels the TV guide search found the game on.
    static func search(_ fixture: Fixture, addons: [AddonEntry], channelNames: [String],
                       progress: @escaping @MainActor ([AddonSportsHit], Int) -> Void) async {
        let teams = teamNames(fixture)
        let channels = Array(Set((fixture.broadcasts + channelNames).map(GuideText.phrase).filter { $0.count >= 3 }))
        let searched = addons.compactMap { addon in URL(string: addon.manifestURL).map { (addon, $0) } }
        guard (!teams.isEmpty || !channels.isEmpty) && !searched.isEmpty else {
            await progress([], 0)
            return
        }

        var hits: [AddonSportsHit] = []
        var remaining = searched.count
        await withTaskGroup(of: [AddonSportsHit].self) { group in
            for (addon, url) in searched {
                group.addTask {
                    await withTimeout(addonTimeout) {
                        await search(addon: addon, url: url, fixture: fixture, teams: teams, channels: channels)
                    } ?? []
                }
            }
            for await found in group {
                hits += found
                remaining -= 1
                await progress(sorted(hits, addons: addons), remaining)
            }
        }
    }

    /// While a search is repeated (with more channels from the guide), what the last one found
    /// stays listed until the new one has finished.
    static func merged(_ hits: [AddonSportsHit], with earlier: [AddonSportsHit]) -> [AddonSportsHit] {
        let ids = Set(hits.map(\.id))
        return hits + earlier.filter { !ids.contains($0.id) }
    }

    /// Games first (they are the match itself), then channels; addon order within each.
    private static func sorted(_ hits: [AddonSportsHit], addons: [AddonEntry]) -> [AddonSportsHit] {
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

    /// `work`'s result, or nil if it takes longer than `seconds` (it's cancelled then).
    private static func withTimeout<Value>(_ seconds: Double, _ work: @escaping () async -> Value) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Runs the requests a few at a time and puts everything they list together.
    private static func fetch(_ requests: [() async -> [StremioMeta]]) async -> [[StremioMeta]] {
        var results: [[StremioMeta]] = []
        var start = 0
        while start < requests.count && !Task.isCancelled {
            let batch = requests[start..<min(start + concurrentRequests, requests.count)]
            await withTaskGroup(of: (Int, [StremioMeta]).self) { group in
                for (offset, request) in batch.enumerated() {
                    group.addTask { (offset, await request()) }
                }
                var batchResults = Array(repeating: [StremioMeta](), count: batch.count)
                for await (offset, metas) in group { batchResults[offset] = metas }
                results += batchResults
            }
            start += concurrentRequests
        }
        return results
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
                               teams: [Sides], channels: [String]) async -> [AddonSportsHit] {
        guard let manifest = await AddonManifests.shared.manifest(url) else { return [] }
        let catalogues = liveCatalogues(manifest)
        guard !catalogues.isEmpty else { return [] }
        let client = StremioAddonClient(manifestURL: url)

        // Each team's full name, and the first few channels, in every catalogue that searches;
        // and each catalogue that can be read whole. All sent together, a few at a time.
        let names = teams.flatMap { [$0.home.names.first, $0.away.names.first].compactMap { $0 } }
        let queries = Array(Set(names + channels.prefix(4)))
        var requests: [() async -> [StremioMeta]] = []
        var whole: [Int: String] = [:]
        for catalogue in catalogues {
            if catalogue.supportsSearch {
                for query in queries {
                    requests.append { (try? await client.catalog(type: catalogue.type, id: catalogue.id, search: query)) ?? [] }
                }
            }
            if !catalogue.needsExtra {
                whole[requests.count] = "\(catalogue.type)|\(catalogue.id)"
                requests.append { (try? await client.catalog(type: catalogue.type, id: catalogue.id, search: nil)) ?? [] }
            }
        }
        let results = await fetch(requests)
        guard !Task.isCancelled else { return [] }

        // Everything each catalogue offers that might be this game, by meta id.
        var found: [String: (meta: StremioMeta, kind: AddonSportsHit.Kind)] = [:]
        var listed: [String: [StremioMeta]] = [:]
        for (index, metas) in results.enumerated() {
            if let id = whole[index] { listed[id] = metas }
            for meta in metas {
                if let kind = match(meta, teams: teams, channels: channels), found[meta.id] == nil {
                    found[meta.id] = (meta, kind)
                }
            }
        }

        found = narrowGames(found, fixture: fixture)

        // A list for the game's sport ("Cricket") whose channels may be showing it: offered
        // after any real matches, leaving out other games it lists.
        // News channels never show games; channels of the broadcasters ESPN names come first.
        let sportLists = catalogues.filter { isFor(sport: fixture, $0) && !$0.needsExtra }
        let broadcasterWords = Set(fixture.broadcasts.compactMap { GuideText.phrase($0).split(separator: " ").first.map(String.init) }
            .filter { $0.count >= 3 })
        var candidates: [StremioMeta] = []
        for catalogue in sportLists {
            for meta in listed["\(catalogue.type)|\(catalogue.id)"] ?? [] {
                let name = meta.name ?? ""
                let text = GuideText.normalize(name)
                guard found[meta.id] == nil, !GuideText.hasVersus(name), !text.contains(" news "),
                      !candidates.contains(where: { $0.id == meta.id }) else { continue }
                candidates.append(meta)
            }
        }
        func byBroadcaster(_ meta: StremioMeta) -> Bool {
            let text = GuideText.normalize(meta.name ?? "")
            return broadcasterWords.contains { text.contains(" " + $0 + " ") }
        }
        let ordered = candidates.filter(byBroadcaster) + candidates.filter { !byBroadcaster($0) }
        for meta in ordered.prefix(6) {
            found[meta.id] = (meta, .sportChannel)
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
            let found = ListingDates.find(in: text, near: fixture.date)
            let date = found?.date
            // Without a time zone (or a time) a listing is only good to the day.
            let slack: TimeInterval = found?.precise == false ? 24 * 3600 : 0
            if let date, date < from.addingTimeInterval(-slack) || date > until.addingTimeInterval(slack) { continue }
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
    /// The two teams of a game, as listings may name them.
    struct Sides {
        let home: ListingMatcher.Team
        let away: ListingMatcher.Team
    }

    private static func teamNames(_ fixture: Fixture) -> [Sides] {
        func team(_ side: Fixture.Side?) -> ListingMatcher.Team? {
            guard let side else { return nil }
            let full = GuideText.phrase(side.name)
            let others = TeamNames.aliases(side.name, extra: side.aliases).filter { $0 != full }
            let names = ([full] + others.sorted { $0.count > $1.count }).filter { $0.count >= 3 }
            return names.isEmpty ? nil : ListingMatcher.Team(names: names, code: side.code)
        }
        // A game listing has to name both sides; otherwise any game of either team would match.
        guard let home = team(fixture.home), let away = team(fixture.away) else { return [] }
        return [Sides(home: home, away: away)]
    }

    private static func match(_ meta: StremioMeta, teams: [Sides],
                              channels: [String]) -> AddonSportsHit.Kind? {
        let name = meta.name ?? ""
        let text = GuideText.normalize(name + " " + (meta.description ?? ""))
        func has(_ phrase: String) -> Bool { text.contains(" " + phrase + " ") }
        for side in teams where side.home.names.contains(where: has) && side.away.names.contains(where: has) {
            return .game
        }
        // Not word for word: each side of the title compared on its own, by code or closely.
        for side in teams where ListingMatcher.isMatch(name, home: side.home, away: side.away) {
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
