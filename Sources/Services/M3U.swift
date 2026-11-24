import Compression
import Foundation

/// M3U playlists: an IPTV account that's a playlist link (and optionally an XMLTV guide link)
/// instead of an Xtream Codes login. `XtreamClient` reads one when the account has a playlist,
/// so Live TV, the guide, favourites, folders and Sports use it the same way.
struct M3UEntry: Hashable {
    let id: Int
    let number: Int?
    let name: String
    let logo: String?
    let group: String
    /// The channel's id in the XMLTV guide (tvg-id).
    let guideID: String?
    let url: URL
}

struct M3UPlaylist {
    var entries: [M3UEntry] = []
    /// Groups in the order the playlist first uses them.
    var groups: [String] = []
    /// The guide link the playlist names itself (url-tvg / x-tvg-url).
    var guideURL: URL?

    static func parse(_ text: String) -> M3UPlaylist {
        var playlist = M3UPlaylist()
        var seenGroups = Set<String>()
        var seenIDs = Set<Int>()
        var pending: (name: String, attributes: [String: String], group: String?)?
        var index = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") {
                let attributes = Self.attributes(in: Substring(line))
                let guide = attributes["url-tvg"] ?? attributes["x-tvg-url"]
                // Several guides can be listed, comma-separated; the first is used.
                if let first = guide?.split(separator: ",").first {
                    playlist.guideURL = URL(string: first.trimmingCharacters(in: .whitespaces))
                }
            } else if line.hasPrefix("#EXTINF") {
                // #EXTINF:-1 tvg-id="…" tvg-logo="…" group-title="…",Channel name
                let comma = Self.nameSeparator(in: Substring(line))
                let head = comma.map { line[..<$0] } ?? Substring(line)
                let name = comma.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                pending = (name, Self.attributes(in: head), nil)
            } else if line.hasPrefix("#EXTGRP:") {
                pending?.group = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                continue
            } else if let info = pending {
                pending = nil
                guard let url = URL(string: line), Self.isLive(url) else { continue }
                index += 1
                let attributes = info.attributes
                var group = attributes["group-title"] ?? info.group ?? ""
                if group.isEmpty { group = String(localized: "Other") }
                let name = info.name.isEmpty ? (attributes["tvg-name"] ?? line) : info.name
                // The same link listed twice is one channel.
                let id = Self.stableID(line)
                guard seenIDs.insert(id).inserted else { continue }
                if seenGroups.insert(group).inserted { playlist.groups.append(group) }
                let logo = attributes["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 }
                let guideID = (attributes["tvg-id"] ?? "").trimmingCharacters(in: .whitespaces)
                playlist.entries.append(M3UEntry(
                    id: id, number: attributes["tvg-chno"].flatMap { Int($0) } ?? index,
                    name: name, logo: logo, group: group,
                    guideID: guideID.isEmpty ? nil : guideID, url: url))
            }
        }
        return playlist
    }

    /// Films and episodes in the playlist are left out: this covers live channels.
    private static func isLive(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("/movie/") || path.contains("/series/") { return false }
        return !["mp4", "mkv", "avi", "mov", "m4v", "wmv"].contains(url.pathExtension.lowercased())
    }

    /// The comma that starts the channel name: the first one outside quotes.
    private static func nameSeparator(in line: Substring) -> String.Index? {
        var quoted = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted { return index }
        }
        return nil
    }

    /// key="value" pairs, with lower-cased keys.
    private static func attributes(in text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = text[...]
        while let equals = rest.range(of: "=\"") {
            let before = rest[..<equals.lowerBound]
            let key = before.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).last.map(String.init) ?? ""
            let valueStart = equals.upperBound
            guard let close = rest[valueStart...].firstIndex(of: "\"") else { break }
            if !key.isEmpty { result[key.lowercased()] = String(rest[valueStart..<close]) }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// The same number on every launch for the same link (Swift's own hashes change), so
    /// favourites, folders and hidden channels stay put.
    static func stableID(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Positive and well inside Int, so it reads like a provider's stream id.
        return Int(hash % 9_000_000_000_000) + 1
    }
}

/// Downloaded playlists, kept for 10 minutes like Xtream channel lists.
actor M3UPlaylists {
    static let shared = M3UPlaylists()

    private var cache: [String: (date: Date, value: M3UPlaylist)] = [:]
    private var loading: [String: Task<M3UPlaylist, Error>] = [:]

    func playlist(_ account: XtreamAccount, headers: [String: String]) async throws -> M3UPlaylist {
        let key = account.playlistURL
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < 600 { return cached.value }
        if let running = loading[key] { return try await running.value }
        let task = Task<M3UPlaylist, Error> {
            guard let url = URL(string: key.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let data = try await URLSession.shared.fetch(request)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            guard text.contains("#EXTINF") else { throw M3UError.notAPlaylist }
            return M3UPlaylist.parse(text)
        }
        loading[key] = task
        defer { loading[key] = nil }
        let playlist = try await task.value
        cache[key] = (Date(), playlist)
        M3ULinks.shared.store(playlist, for: key)
        return playlist
    }
}

enum M3UError: LocalizedError {
    case notAPlaylist

    var errorDescription: String? {
        String(localized: "That link isn't an M3U playlist.")
    }
}

/// Channel links by id, readable without waiting, for starting playback.
final class M3ULinks: @unchecked Sendable {
    static let shared = M3ULinks()
    private let lock = NSLock()
    private var links: [String: [Int: M3UEntry]] = [:]

    func store(_ playlist: M3UPlaylist, for key: String) {
        let byID = Dictionary(playlist.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lock.lock()
        links[key] = byID
        lock.unlock()
    }

    func entry(_ id: Int, in key: String) -> M3UEntry? {
        lock.lock()
        defer { lock.unlock() }
        return links[key]?[id]
    }
}

/// The XMLTV guide for M3U accounts, read once into listings per guide channel id.
actor M3UGuide {
    static let shared = M3UGuide()

    private var loaded: (key: String, date: Date, value: [String: [XtreamEPGEntry]])?
    private var loading: (key: String, task: Task<[String: [XtreamEPGEntry]], Never>)?
    private var lastFailure: (key: String, date: Date)?
    private var refreshHours = 6
    private let launch = Date()

    func configure(refreshHours: Int) {
        self.refreshHours = refreshHours
    }

    func clear() {
        loaded = nil
        if let folder = Self.folder { try? FileManager.default.removeItem(at: folder) }
    }

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("m3u-guide", isDirectory: true)
    }

    private func isFresh(_ date: Date) -> Bool {
        if refreshHours < 0 { return true }
        if refreshHours == 0 { return date >= launch }
        return Date().timeIntervalSince(date) < TimeInterval(refreshHours) * 3600
    }

    /// A channel's listings, by its tvg-id.
    func entries(_ client: XtreamClient, guideID: String) async -> [XtreamEPGEntry] {
        await listings(client)[guideID.lowercased()] ?? []
    }

    private func listings(_ client: XtreamClient) async -> [String: [XtreamEPGEntry]] {
        guard let url = await client.m3uGuideURL() else { return [:] }
        let key = url.absoluteString
        if let loaded, loaded.key == key, isFresh(loaded.date) { return loaded.value }
        if let loading, loading.key == key { return await loading.task.value }

        let file = Self.folder?.appendingPathComponent("\(M3UPlaylist.stableID(key)).xml")
        let saved = file.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        let recentlyFailed = lastFailure.map { $0.key == key && Date().timeIntervalSince($0.date) < 600 } ?? false
        let headers = client.requestHeaders
        let needsDownload = saved.map { !isFresh($0) } ?? true

        let task = Task<[String: [XtreamEPGEntry]], Never> {
            guard let file else { return [:] }
            if needsDownload && !recentlyFailed {
                // When the download fails, an older copy is better than nothing.
                try? await GuideDownload.fetch(url, headers: headers, to: file)
            }
            return (try? XMLTVReader.readAll(file)) ?? [:]
        }
        loading = (key, task)
        let value = await task.value
        loading = nil
        if value.isEmpty {
            lastFailure = (key, Date())
        } else {
            loaded = (key, Date(), value)
        }
        return value
    }
}

/// Downloads a guide file, unpacking it when it's gzip-compressed (many .xml.gz guides).
enum GuideDownload {
    static func fetch(_ url: URL, headers: [String: String], to file: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw HTTPError.status(http.statusCode, "")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        if Gzip.isCompressed(temporary) {
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Gzip.unpack(temporary, to: file)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
    }
}

/// Unpacks gzip files a piece at a time, so a large guide never sits in memory whole.
enum Gzip {
    static func isCompressed(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let start = (try? handle.read(upToCount: 2)) ?? Data()
        return start.count == 2 && start[start.startIndex] == 0x1f && start[start.startIndex + 1] == 0x8b
    }

    static func unpack(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        let header = try input.read(upToCount: 10) ?? Data()
        guard header.count == 10, header[header.startIndex + 2] == 8 else { throw GuideError.compressed }
        let flags = header[header.startIndex + 3]
        var offset = 10
        if flags & 0x04 != 0 {
            let extra = try input.read(upToCount: 2) ?? Data()
            guard extra.count == 2 else { throw GuideError.compressed }
            let length = Int(extra[extra.startIndex]) | Int(extra[extra.startIndex + 1]) << 8
            _ = try input.read(upToCount: length)
            offset += 2 + length
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            // A zero-terminated file name or comment.
            while let byte = try input.read(upToCount: 1), let value = byte.first {
                offset += 1
                if value == 0 { break }
            }
        }
        if flags & 0x02 != 0 {
            _ = try input.read(upToCount: 2)
            offset += 2
        }
        // The deflate data, without the 8-byte checksum and length at the end.
        var remaining = max(size - offset - 8, 0)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let filter = try OutputFilter(.decompress, using: .zlib) { data in
            if let data { output.write(data) }
        }
        while remaining > 0 {
            let chunk = try input.read(upToCount: min(remaining, 1 << 20)) ?? Data()
            if chunk.isEmpty { break }
            remaining -= chunk.count
            try filter.write(chunk)
        }
        try filter.finalize()
    }
}
