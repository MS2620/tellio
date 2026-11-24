import Foundation

struct XtreamCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.categoryID) ?? ""
        name = (try? c.decode(String.self, forKey: .categoryName)) ?? "Unknown"
    }
}

struct XtreamChannel: Decodable, Identifiable, Hashable {
    let id: Int
    let number: Int?
    /// The name shown everywhere; tidied when its group is sorted by quality.
    var name: String
    let icon: String?
    let categoryID: String?
    /// The channel's id in the provider's XMLTV guide; several streams can share one.
    let epgChannelID: String?

    // Set only for channels in a group sorted by quality (QualitySort).
    /// The provider's own name, before tidying.
    var originalName: String? = nil
    var quality: ChannelQuality? = nil
    /// The group leading its merged quality folders (itself, or its twin without HEVC).
    var folderGroupID: String? = nil
    /// The quality folder it's in, "UK | Sports FHD", shown where groups are mixed.
    var folderName: String? = nil
    /// Country tag and tidied name: versions of the same channel share guide listings.
    var guideKey: String? = nil

    /// The provider's name, even when the shown one is tidied (for matching and ranking).
    var providerName: String { originalName ?? name }

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case num
        case name
        case streamIcon = "stream_icon"
        case categoryID = "category_id"
        case epgChannelID = "epg_channel_id"
    }

    /// A channel known only by its basics, e.g. from a saved reminder.
    init(id: Int, number: Int? = nil, name: String, icon: String? = nil,
         categoryID: String? = nil, epgChannelID: String? = nil) {
        self.id = id
        self.number = number
        self.name = name
        self.icon = icon
        self.categoryID = categoryID
        self.epgChannelID = epgChannelID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.streamID) ?? -1
        number = c.flexInt(.num)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Channel"
        let rawIcon = try? c.decode(String.self, forKey: .streamIcon)
        icon = (rawIcon?.isEmpty ?? true) ? nil : rawIcon
        categoryID = c.flexString(.categoryID)
        let epg = c.flexString(.epgChannelID)?.trimmingCharacters(in: .whitespaces)
        epgChannelID = (epg?.isEmpty ?? true) ? nil : epg
    }
}

struct XtreamEPGEntry: Decodable, Hashable {
    let title: String
    let description: String
    let start: Date?
    let end: Date?

    private enum CodingKeys: String, CodingKey {
        case title
        case description
        case startTimestamp = "start_timestamp"
        case stopTimestamp = "stop_timestamp"
    }

    init(title: String, description: String, start: Date?, end: Date?) {
        self.title = title
        self.description = description
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Xtream returns EPG text base64-encoded.
        title = Self.decodeBase64((try? c.decode(String.self, forKey: .title)) ?? "")
        description = Self.decodeBase64((try? c.decode(String.self, forKey: .description)) ?? "")
        start = c.flexInt(.startTimestamp).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        end = c.flexInt(.stopTimestamp).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private static func decodeBase64(_ raw: String) -> String {
        Data(base64Encoded: raw).map { String(decoding: $0, as: UTF8.self) } ?? raw
    }
}

/// A film in the provider's own library (VOD).
struct XtreamVOD: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let fileExtension: String
    let added: Int

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case containerExtension = "container_extension"
        case added
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.streamID) ?? -1
        name = (try? c.decode(String.self, forKey: .name)) ?? "Movie"
        let rawIcon = try? c.decode(String.self, forKey: .streamIcon)
        icon = (rawIcon?.isEmpty ?? true) ? nil : rawIcon
        let ext = try? c.decode(String.self, forKey: .containerExtension)
        fileExtension = (ext?.isEmpty ?? true) ? "mp4" : (ext ?? "mp4")
        added = c.flexInt(.added) ?? 0
    }
}

/// A series in the provider's own library.
struct XtreamSeries: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let cover: String?
    let plot: String?
    let lastModified: Int

    private enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case name, cover, plot
        case lastModified = "last_modified"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.seriesID) ?? -1
        name = (try? c.decode(String.self, forKey: .name)) ?? "Series"
        let rawCover = try? c.decode(String.self, forKey: .cover)
        cover = (rawCover?.isEmpty ?? true) ? nil : rawCover
        plot = try? c.decode(String.self, forKey: .plot)
        lastModified = c.flexInt(.lastModified) ?? 0
    }
}

struct XtreamEpisode: Identifiable, Hashable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let fileExtension: String
    let plot: String?
    let image: String?
}

private struct ShortEPGResponse: Decodable {
    let epgListings: [XtreamEPGEntry]
    private enum CodingKeys: String, CodingKey { case epgListings = "epg_listings" }
}

struct XtreamAccountInfo: Equatable {
    var signedIn: Bool
    var status: String
    var expires: Date? = nil
    var activeConnections: Int? = nil
    var maxConnections: Int? = nil

    var isActive: Bool { signedIn && status.lowercased() == "active" }

    /// "0 of 1 in use", when the provider says.
    var connectionsText: String? {
        guard let maxConnections else { return nil }
        return String(localized: "\(activeConnections ?? 0) of \(maxConnections) in use")
    }
}

struct XtreamClient {
    let account: XtreamAccount
    /// Optional User-Agent override; some providers only accept specific players.
    var userAgent: String = ""

    var requestHeaders: [String: String] {
        userAgent.isEmpty ? [:] : ["User-Agent": userAgent]
    }

    private func api(_ action: String?, _ extra: [String: String] = [:]) async throws -> Data {
        guard var comps = URLComponents(string: "\(account.normalizedServer)/player_api.php") else { throw URLError(.badURL) }
        var items = [
            URLQueryItem(name: "username", value: account.username),
            URLQueryItem(name: "password", value: account.password),
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        items += extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return try await URLSession.shared.fetch(request)
    }

    /// The account's state as the provider reports it.
    func accountInfo() async throws -> XtreamAccountInfo {
        if account.isM3U {
            // A playlist has no login: it works if it lists channels.
            let playlist = try await m3u()
            return XtreamAccountInfo(signedIn: !playlist.entries.isEmpty,
                                     status: playlist.entries.isEmpty ? String(localized: "No channels") : "Active")
        }
        let data = try await api(nil)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user_info"] as? [String: Any] else {
            return XtreamAccountInfo(signedIn: false, status: String(localized: "Login failed"))
        }
        func text(_ key: String) -> String? {
            guard let value = user[key], !(value is NSNull) else { return nil }
            return "\(value)"
        }
        guard text("auth") == "1" else {
            return XtreamAccountInfo(signedIn: false, status: String(localized: "Login failed"))
        }
        return XtreamAccountInfo(
            signedIn: true,
            status: text("status") ?? "Active",
            expires: text("exp_date").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) },
            activeConnections: text("active_cons").flatMap { Int($0) },
            maxConnections: text("max_connections").flatMap { Int($0) }
        )
    }

    /// Returns a short status string, e.g. "Active · expires 12 Mar 2027".
    func authenticate() async throws -> String {
        let info = try await accountInfo()
        guard info.signedIn else { return info.status }
        var status = info.status
        if let expires = info.expires {
            status += " · " + String(localized: "expires \(expires.formatted(date: .abbreviated, time: .omitted))")
        }
        return status
    }

    func liveCategories() async throws -> [XtreamCategory] {
        if account.isM3U { return try await m3u().groups.map { XtreamCategory(id: $0, name: $0) } }
        return try JSONDecoder().decode([XtreamCategory].self, from: try await api("get_live_categories"))
    }

    func liveStreams(categoryID: String?) async throws -> [XtreamChannel] {
        if account.isM3U {
            return try await m3u().entries
                .filter { categoryID == nil || $0.group == categoryID }
                .map { XtreamChannel(id: $0.id, number: $0.number, name: $0.name, icon: $0.logo,
                                     categoryID: $0.group, epgChannelID: $0.guideID) }
        }
        let extra = categoryID.map { ["category_id": $0] } ?? [:]
        return try JSONDecoder().decode([XtreamChannel].self, from: try await api("get_live_streams", extra))
    }

    func shortEPG(streamID: Int, limit: Int = 4) async throws -> [XtreamEPGEntry] {
        if account.isM3U {
            let from = Date()
            return Array(await m3uListings(streamID: streamID).filter { ($0.end ?? .distantPast) > from }.prefix(limit))
        }
        let data = try await api("get_short_epg", ["stream_id": String(streamID), "limit": String(limit)])
        return try JSONDecoder().decode(ShortEPGResponse.self, from: data).epgListings
    }

    /// The provider's whole guide for one channel (usually several days).
    func fullEPG(streamID: Int) async throws -> [XtreamEPGEntry] {
        try Self.decodeEPG(try await fullEPGData(streamID: streamID))
    }

    /// The raw guide response, so it can be saved and decoded again later.
    func fullEPGData(streamID: Int) async throws -> Data {
        try await api("get_simple_data_table", ["stream_id": String(streamID)])
    }

    static func decodeEPG(_ data: Data) throws -> [XtreamEPGEntry] {
        try JSONDecoder().decode(ShortEPGResponse.self, from: data).epgListings
    }

    // MARK: Provider library (VOD)

    func vodStreams() async throws -> [XtreamVOD] {
        // Playlists are read for live channels only.
        if account.isM3U { return [] }
        return try JSONDecoder().decode([XtreamVOD].self, from: try await api("get_vod_streams"))
    }

    func seriesList() async throws -> [XtreamSeries] {
        if account.isM3U { return [] }
        return try JSONDecoder().decode([XtreamSeries].self, from: try await api("get_series"))
    }

    /// Episodes of a provider series, sorted by season then episode.
    /// Panels return `episodes` keyed by season, or as a list of lists.
    func seriesEpisodes(seriesID: Int) async throws -> [XtreamEpisode] {
        let data = try await api("get_series_info", ["series_id": String(seriesID)])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var groups: [[Any]] = []
        if let bySeason = json["episodes"] as? [String: Any] {
            groups = bySeason.values.compactMap { $0 as? [Any] }
        } else if let list = json["episodes"] as? [Any] {
            groups = list.compactMap { $0 as? [Any] }
        }
        var result: [XtreamEpisode] = []
        for group in groups {
            for item in group {
                guard let raw = item as? [String: Any], let id = Self.text(raw["id"]) else { continue }
                let info = raw["info"] as? [String: Any]
                let ext = Self.text(raw["container_extension"]) ?? ""
                result.append(XtreamEpisode(
                    id: id,
                    season: Self.number(raw["season"]) ?? 0,
                    number: Self.number(raw["episode_num"]) ?? 0,
                    title: Self.text(raw["title"]) ?? "Episode",
                    fileExtension: ext.isEmpty ? "mp4" : ext,
                    plot: info?["plot"] as? String,
                    image: info?["movie_image"] as? String
                ))
            }
        }
        return result.sorted { a, b in
            a.season != b.season ? a.season < b.season : a.number < b.number
        }
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        if let string = value as? String { return Int(string) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    func movieURL(for movie: XtreamVOD) -> URL? {
        let user = account.username.formEncoded
        let pass = account.password.formEncoded
        return URL(string: "\(account.normalizedServer)/movie/\(user)/\(pass)/\(movie.id).\(movie.fileExtension)")
    }

    func episodeURL(for episode: XtreamEpisode) -> URL? {
        let user = account.username.formEncoded
        let pass = account.password.formEncoded
        return URL(string: "\(account.normalizedServer)/series/\(user)/\(pass)/\(episode.id).\(episode.fileExtension)")
    }

    /// The provider's whole TV guide as one XMLTV file.
    var xmltvURL: URL? {
        guard var comps = URLComponents(string: "\(account.normalizedServer)/xmltv.php") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "username", value: account.username),
            URLQueryItem(name: "password", value: account.password),
        ]
        return comps.url
    }

    func liveURL(for channel: XtreamChannel, format: LiveStreamFormat = .hls) -> URL? {
        // A playlist gives each channel's link as it is; the format setting doesn't apply.
        if account.isM3U { return M3ULinks.shared.entry(channel.id, in: account.playlistURL)?.url }
        let user = account.username.formEncoded
        let pass = account.password.formEncoded
        return URL(string: "\(account.normalizedServer)/live/\(user)/\(pass)/\(channel.id).\(format.fileExtension)")
    }
}

// MARK: - M3U playlists

extension XtreamClient {
    func m3u() async throws -> M3UPlaylist {
        try await M3UPlaylists.shared.playlist(account, headers: requestHeaders)
    }

    /// The guide link entered with the account, or else the one the playlist names.
    func m3uGuideURL() async -> URL? {
        let typed = account.guideURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return URL(string: typed) }
        return (try? await m3u())?.guideURL
    }

    /// A playlist channel's listings, from the guide file, by the channel's tvg-id.
    func m3uListings(streamID: Int) async -> [XtreamEPGEntry] {
        if M3ULinks.shared.entry(streamID, in: account.playlistURL) == nil { _ = try? await m3u() }
        guard let guideID = M3ULinks.shared.entry(streamID, in: account.playlistURL)?.guideID else { return [] }
        return await M3UGuide.shared.entries(self, guideID: guideID)
    }
}

/// Caches the channel list and guide data so Search, Home, Live TV and Sports
/// don't re-download them every time. Guide data is also saved on the Apple TV
/// and re-downloaded as often as Settings → Content says.
actor XtreamCache {
    static let shared = XtreamCache()

    private var streams: (key: String, date: Date, value: [XtreamChannel])?
    private var categories: (key: String, date: Date, value: [XtreamCategory])?
    private var tidied: (key: String, chosen: Set<String>, names: [Int: String], count: Int, date: Date,
                         value: [XtreamChannel])?
    private var guideTwins: [Int: [Int]] = [:]
    private var guides: [String: (date: Date, value: [XtreamEPGEntry])] = [:]
    private var failures: [String: Date] = [:]
    private var movieCache: (key: String, value: [XtreamVOD])?
    private var seriesCache: (key: String, value: [XtreamSeries])?

    /// Hours between guide downloads; 0 = once per launch, below 0 = only manually.
    private var refreshHours = 6
    private let launch = Date()

    private static let listLifetime: TimeInterval = 10 * 60
    private static let failureLifetime: TimeInterval = 5 * 60

    func configure(refreshHours: Int) {
        self.refreshHours = refreshHours
    }

    private func accountKey(_ client: XtreamClient) -> String {
        client.account.cacheKey
    }

    /// Guide listings already downloaded this session, by channel, for searching.
    func cachedListings(_ client: XtreamClient) -> [Int: [XtreamEPGEntry]] {
        let prefix = accountKey(client) + "|"
        var result: [Int: [XtreamEPGEntry]] = [:]
        for (key, entry) in guides where key.hasPrefix(prefix) {
            if let id = Int(key.dropFirst(prefix.count)) { result[id] = entry.value }
        }
        return result
    }

    /// Every live channel of the account, with names tidied in the groups sorted by quality.
    func liveStreams(_ client: XtreamClient) async throws -> [XtreamChannel] {
        let raw = try await rawLiveStreams(client)
        let chosen = QualitySort.activeCategoryIDs
        let names = QualitySort.activeCustomNames
        guard !chosen.isEmpty || !names.isEmpty else {
            guideTwins = [:]
            return raw
        }
        let key = accountKey(client)
        if let tidied, tidied.key == key, tidied.chosen == chosen, tidied.names == names, tidied.count == raw.count,
           tidied.date >= (streams?.date ?? .distantPast) {
            return tidied.value
        }
        let categories = (try? await liveCategories(client)) ?? []
        let value = QualitySort.apply(raw, chosen: chosen, customNames: names, categories: categories)
        tidied = (key, chosen, names, raw.count, Date(), value)
        guideTwins = QualitySort.guideTwins(value)
        return value
    }

    /// A channel's listings; when it has nothing from an hour ago onwards, those of another
    /// version of the same channel (Sort by quality), since providers often leave the guide off
    /// their HEVC copies or only send old listings for them.
    func guide(_ client: XtreamClient, streamID: Int) async -> [XtreamEPGEntry] {
        let own = await fullEPG(client, streamID: streamID)
        guard !Self.isCurrent(own), let twins = guideTwins[streamID] else { return own }
        for twin in twins {
            let entries = await fullEPG(client, streamID: twin)
            if Self.isCurrent(entries) { return entries }
        }
        return own
    }

    /// Whether listings reach from an hour ago onwards (what the guide shows).
    private static func isCurrent(_ entries: [XtreamEPGEntry]) -> Bool {
        let from = Date().addingTimeInterval(-3600)
        return entries.contains { ($0.end ?? .distantPast) > from }
    }

    /// The channels exactly as the provider names them.
    func rawLiveStreams(_ client: XtreamClient) async throws -> [XtreamChannel] {
        let key = accountKey(client)
        if let streams, streams.key == key, Date().timeIntervalSince(streams.date) < Self.listLifetime {
            return streams.value
        }
        let value = try await client.liveStreams(categoryID: nil)
        streams = (key, Date(), value)
        return value
    }

    func liveCategories(_ client: XtreamClient) async throws -> [XtreamCategory] {
        let key = accountKey(client)
        if let categories, categories.key == key, Date().timeIntervalSince(categories.date) < Self.listLifetime {
            return categories.value
        }
        let value = try await client.liveCategories()
        categories = (key, Date(), value)
        return value
    }

    // MARK: Guide

    private func isFresh(_ date: Date) -> Bool {
        if refreshHours < 0 { return true }
        if refreshHours == 0 { return date >= launch }
        return Date().timeIntervalSince(date) < TimeInterval(refreshHours) * 3600
    }

    private static var guideFolder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("guide", isDirectory: true)
    }

    /// A stable file name (Swift's own hashes change every launch).
    private func guideFile(_ cacheKey: String) -> URL? {
        var hash: UInt64 = 5381
        for byte in cacheKey.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Self.guideFolder?.appendingPathComponent("\(hash).json")
    }

    /// Never throws: a channel whose guide can't be read just has no listings.
    func fullEPG(_ client: XtreamClient, streamID: Int) async -> [XtreamEPGEntry] {
        let cacheKey = accountKey(client) + "|\(streamID)"
        // A playlist's guide is one file, already kept by M3UGuide.
        if client.account.isM3U {
            let entries = await client.m3uListings(streamID: streamID)
            guides[cacheKey] = (Date(), entries)
            return entries
        }
        if let cached = guides[cacheKey], isFresh(cached.date) {
            return cached.value
        }

        let file = guideFile(cacheKey)
        var saved: [XtreamEPGEntry]?
        if let file,
           let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date,
           let data = try? Data(contentsOf: file),
           let entries = try? XtreamClient.decodeEPG(data) {
            if isFresh(modified) {
                guides[cacheKey] = (modified, entries)
                return entries
            }
            saved = entries
        }

        // Don't retry a channel that just failed on every scroll.
        if let failed = failures[cacheKey], Date().timeIntervalSince(failed) < Self.failureLifetime {
            return guides[cacheKey]?.value ?? saved ?? []
        }

        guard let data = try? await client.fullEPGData(streamID: streamID),
              let entries = try? XtreamClient.decodeEPG(data) else {
            failures[cacheKey] = Date()
            // Out-of-date listings are better than none.
            return guides[cacheKey]?.value ?? saved ?? []
        }
        guides[cacheKey] = (Date(), entries)
        failures[cacheKey] = nil
        if let file, let folder = Self.guideFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return entries
    }

    /// Forgets all guide data so it is downloaded again.
    func clearGuide() async {
        await M3UGuide.shared.clear()
        guides.removeAll()
        failures.removeAll()
        if let folder = Self.guideFolder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Provider library

    /// The provider's most recently added films.
    func recentMovies(_ client: XtreamClient, limit: Int = 40) async throws -> [XtreamVOD] {
        let key = accountKey(client)
        if let movieCache, movieCache.key == key { return movieCache.value }
        let all = try await client.vodStreams()
        let value = Array(all.sorted { $0.added > $1.added }.prefix(limit))
        movieCache = (key, value)
        return value
    }

    /// The provider's most recently updated series.
    func recentSeries(_ client: XtreamClient, limit: Int = 40) async throws -> [XtreamSeries] {
        let key = accountKey(client)
        if let seriesCache, seriesCache.key == key { return seriesCache.value }
        let all = try await client.seriesList()
        let value = Array(all.sorted { $0.lastModified > $1.lastModified }.prefix(limit))
        seriesCache = (key, value)
        return value
    }
}
