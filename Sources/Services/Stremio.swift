import Foundation

struct AddonManifest: Decodable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let types: [String]?
    let catalogs: [AddonCatalogue]?

    private enum CodingKeys: String, CodingKey { case id, name, version, description, types, catalogs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try? c.decode(String.self, forKey: .version)
        description = try? c.decode(String.self, forKey: .description)
        types = try? c.decode([String].self, forKey: .types)
        // One odd catalogue shouldn't make the whole addon unreadable.
        catalogs = (try? c.decode([Lossy<AddonCatalogue>].self, forKey: .catalogs))?.compactMap(\.value)
    }
}

/// A list an addon offers, e.g. live channels or today's games.
struct AddonCatalogue: Decodable {
    struct Extra: Decodable {
        let name: String
        let isRequired: Bool?
    }

    let type: String
    let id: String
    let name: String?
    let extra: [Extra]?
    /// The older way of listing extras.
    let extraSupported: [String]?
    let extraRequired: [String]?

    var supportsSearch: Bool {
        (extra ?? []).contains { $0.name == "search" } || (extraSupported ?? []).contains("search")
    }

    /// Reading it needs a search or filter, so it can't be listed whole.
    var needsExtra: Bool {
        (extra ?? []).contains { $0.isRequired == true } || !(extraRequired ?? []).isEmpty
    }
}

/// An entry in a catalogue.
struct StremioMeta: Decodable {
    let id: String
    let type: String?
    let name: String?
    let description: String?
}

private struct CatalogResponse: Decodable { let metas: [Lossy<StremioMeta>]? }

/// A stream object as defined by the Stremio addon protocol.
struct StremioStream: Decodable, Hashable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?
    /// Set on torrent-only results. Tellio can't play those, so they are skipped.
    let infoHash: String?
    let behaviorHints: BehaviorHints?

    struct BehaviorHints: Decodable, Hashable {
        struct ProxyHeaders: Decodable, Hashable { let request: [String: String]? }
        let proxyHeaders: ProxyHeaders?
    }

    /// Headers the addon says the link needs (live sports links often want a Referer).
    var requestHeaders: [String: String] { behaviorHints?.proxyHeaders?.request ?? [:] }

    /// A direct web link the player can open, if the addon gave one.
    var playableURL: URL? {
        guard let url, let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return parsed
    }

    var headline: String {
        (name ?? "Stream").replacingOccurrences(of: "\n", with: " · ")
    }

    /// Vertical resolution guessed from the addon's labels (2160, 1440, 1080, 720, 480), or 0 if unknown.
    /// The addon's name is checked first, as that is where most addons put the quality.
    var resolution: Int {
        let details = [title, description].compactMap { $0 }.joined(separator: " ")
        let sources: [String] = [name ?? "", details]
        for text in sources {
            if let found = Self.detectResolution(in: text) { return found }
        }
        return 0
    }

    /// Looks for whole words such as "4K", "UHD", "FHD", "1080p" or "HD". Addons
    /// often style labels with look-alike letters (𝗙𝗛𝗗); those are mapped back first.
    private static func detectResolution(in text: String) -> Int? {
        let plain = text.precomposedStringWithCompatibilityMapping.lowercased()
        let words = Set(plain.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func has(_ labels: String...) -> Bool { labels.contains { words.contains($0) } }
        if has("2160p", "2160", "4k", "uhd", "2160i") { return 2160 }
        if has("1440p", "1440", "2k", "qhd") { return 1440 }
        if has("1080p", "1080", "1080i", "fhd") { return 1080 }
        if has("720p", "720", "hd") { return 720 }
        if has("576p", "576", "480p", "480", "sd") { return 480 }
        return nil
    }

    var detail: String {
        (title ?? description ?? "").replacingOccurrences(of: "\n", with: "  ")
    }
}

private struct StreamResponse: Decodable { let streams: [StremioStream] }

/// A subtitle file from a Stremio subtitles addon (e.g. OpenSubtitles v3).
struct StremioSubtitle: Decodable, Hashable {
    let id: String?
    let url: String
    /// Usually ISO 639-2, e.g. "eng", "por".
    let lang: String?
}

private struct SubtitlesResponse: Decodable { let subtitles: [StremioSubtitle]? }

/// A subtitle offered by one of the user's addons, for the player's Subtitles panel.
struct AddonSubtitle: Identifiable, Hashable {
    let id: String
    let addonName: String
    let url: URL
    let language: String
    /// Display name of the language, e.g. "English".
    let languageName: String
}

struct FoundStream: Identifiable {
    let id = UUID()
    let addonName: String
    let stream: StremioStream
}

/// Talks to any Stremio-compatible addon. The user supplies the manifest URL.
struct StremioAddonClient {
    let manifestURL: URL

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.hasSuffix("/manifest.json") {
            while s.hasSuffix("/") { s.removeLast() }
            s += "/manifest.json"
        }
        return URL(string: s)
    }

    private var base: String {
        String(manifestURL.absoluteString.dropLast("/manifest.json".count))
    }

    func manifest() async throws -> AddonManifest {
        let data = try await URLSession.shared.fetch(URLRequest(url: manifestURL))
        return try JSONDecoder().decode(AddonManifest.self, from: data)
    }

    /// - Parameters:
    ///   - type: "movie" or "series"
    ///   - id: IMDb id, e.g. "tt0111161" or "tt0903747:1:1" for an episode
    func streams(type: String, id: String) async throws -> [StremioStream] {
        guard let url = URL(string: "\(base)/stream/\(type)/\(id.pathEncoded).json") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data = try await URLSession.shared.fetch(request)
        return try JSONDecoder().decode(StreamResponse.self, from: data).streams
    }

    /// A catalogue's entries, or those matching `search` when the catalogue can search.
    func catalog(type: String, id: String, search: String?) async throws -> [StremioMeta] {
        var path = "\(base)/catalog/\(type.pathEncoded)/\(id.pathEncoded)"
        if let search { path += "/search=\(search.pathEncoded)" }
        guard let url = URL(string: path + ".json") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data = try await URLSession.shared.fetch(request)
        return (try JSONDecoder().decode(CatalogResponse.self, from: data).metas ?? []).compactMap(\.value)
    }

    /// Subtitles for a movie or episode. Addons without subtitles answer with an error, which callers ignore.
    func subtitles(type: String, id: String) async throws -> [StremioSubtitle] {
        guard let url = URL(string: "\(base)/subtitles/\(type)/\(id).json") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let data = try await URLSession.shared.fetch(request)
        return try JSONDecoder().decode(SubtitlesResponse.self, from: data).subtitles ?? []
    }

    /// Asks every addon for subtitles at once. The user's language comes first, then by language name.
    static func subtitles(from addons: [AddonEntry], type: String, id: String,
                          preferredLanguage: String) async -> [AddonSubtitle] {
        var found: [AddonSubtitle] = []
        await withTaskGroup(of: [AddonSubtitle].self) { group in
            for addon in addons {
                guard let manifest = URL(string: addon.manifestURL) else { continue }
                group.addTask {
                    let list = (try? await StremioAddonClient(manifestURL: manifest).subtitles(type: type, id: id)) ?? []
                    return list.enumerated().compactMap { index, subtitle in
                        guard let url = URL(string: subtitle.url) else { return nil }
                        let code = subtitle.lang ?? "und"
                        return AddonSubtitle(id: "\(addon.manifestURL)#\(subtitle.id ?? String(index))",
                                             addonName: addon.name, url: url, language: code,
                                             languageName: Self.languageName(code))
                    }
                }
            }
            for await list in group { found += list }
        }
        let preferred = languageName(preferredLanguage)
        return found.sorted { a, b in
            let pa = a.languageName == preferred, pb = b.languageName == preferred
            if pa != pb { return pa }
            return a.languageName.localizedCaseInsensitiveCompare(b.languageName) == .orderedAscending
        }
    }

    /// "eng" or "en" → "English" (in the app's language); unknown codes are shown as they are.
    static func languageName(_ code: String) -> String {
        let lower = code.lowercased()
        // ISO 639-2 codes Locale doesn't know by the three-letter form.
        let common = ["eng": "en", "por": "pt", "pob": "pt-BR", "spa": "es", "fre": "fr", "fra": "fr",
                      "ger": "de", "deu": "de", "ita": "it", "dut": "nl", "nld": "nl", "pol": "pl",
                      "rum": "ro", "ron": "ro", "gre": "el", "ell": "el", "chi": "zh", "zho": "zh",
                      "cze": "cs", "ces": "cs"]
        if let mapped = common[lower] { return LanguageOptions.languageName(mapped) }
        if LanguageOptions.displayLocale.localizedString(forLanguageCode: lower) != nil {
            return LanguageOptions.languageName(lower)
        }
        return code.uppercased()
    }
}
