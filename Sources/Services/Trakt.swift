import Foundation
import CryptoKit

// MARK: - API models

struct TraktTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let createdAt: Int

    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn)) }
}

struct TraktDeviceCode: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int
    /// PKCE: the secret half kept on the Apple TV, sent when polling. Not part of Trakt's answer.
    var codeVerifier = ""

    private enum CodingKeys: String, CodingKey {
        case deviceCode, userCode, verificationUrl, expiresIn, interval
    }
}

struct TraktIDs: Codable, Hashable {
    let trakt: Int?
    let tmdb: Int?
    let imdb: String?
}

struct TraktMovie: Decodable {
    let title: String?
    let ids: TraktIDs
    let runtime: Int?
}

struct TraktShow: Decodable {
    let title: String?
    let ids: TraktIDs
}

struct TraktEpisode: Decodable {
    let season: Int
    let number: Int
    let title: String?
    let runtime: Int?
}

struct TraktPlayback: Decodable {
    let progress: Double
    let pausedAt: String?
    let type: String
    let movie: TraktMovie?
    let episode: TraktEpisode?
    let show: TraktShow?
}

private struct TraktWatchedMovie: Decodable { let movie: TraktMovie }

private struct TraktWatchedShow: Decodable {
    struct Season: Decodable {
        struct Episode: Decodable { let number: Int }
        let number: Int
        let episodes: [Episode]?
    }
    let show: TraktShow
    let seasons: [Season]?
}

private struct TraktListItem: Decodable {
    let type: String
    let movie: TraktMovie?
    let show: TraktShow?
}

private struct TraktUserSettings: Decodable {
    struct User: Decodable { let username: String }
    let user: User
}

enum TraktPoll {
    case approved(TraktTokens)
    case pending
    case slowDown
    case expired
    case denied
    case failed(String)
}

// MARK: - Client

/// Trakt's REST API. Apps made since October 2026 have no client secret and sign in with
/// PKCE; older apps still send their secret.
struct TraktClient {
    let clientID: String
    let clientSecret: String
    var accessToken: String? = nil

    private static let base = "https://api.trakt.tv"
    private static let redirect = "urn:ietf:wg:oauth:2.0:oob"
    /// Sign-in host. Trakt's newer docs use auth.trakt.tv; the first sign-in tries it and
    /// falls back to api.trakt.tv, and whichever answered is used from then on.
    private static let oauthHosts = ["https://auth.trakt.tv", "https://api.trakt.tv"]
    private static var oauthBase: String {
        get { UserDefaults.standard.string(forKey: "traktOAuthHost") ?? oauthHosts[0] }
        set { UserDefaults.standard.set(newValue, forKey: "traktOAuthHost") }
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         base: String = TraktClient.base) -> URLRequest {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await URLSession.shared.fetch(request(path))
        return try JSONDecoder.snake.decode(T.self, from: data)
    }

    private func send(_ path: String, _ body: [String: Any]) async throws {
        _ = try await URLSession.shared.fetch(request(path, method: "POST", body: body))
    }

    // Sign-in

    func deviceCode() async throws -> TraktDeviceCode {
        let verifier = PKCE.verifier()
        let body: [String: Any] = ["client_id": clientID,
                                   "code_challenge": PKCE.challenge(for: verifier),
                                   "code_challenge_method": "S256"]
        var lastError: Error = URLError(.cannotConnectToHost)
        // Saved host first, then the other one.
        let hosts = [Self.oauthBase] + Self.oauthHosts.filter { $0 != Self.oauthBase }
        for host in hosts {
            do {
                let data = try await URLSession.shared.fetch(request("/oauth/device/code", method: "POST",
                                                                     body: body, base: host))
                var code = try JSONDecoder.snake.decode(TraktDeviceCode.self, from: data)
                code.codeVerifier = verifier
                Self.oauthBase = host
                return code
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Adds the secret only for older apps that have one.
    private func withSecret(_ body: [String: Any]) -> [String: Any] {
        var body = body
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        return body
    }

    func poll(_ code: TraktDeviceCode) async -> TraktPoll {
        var body: [String: Any] = ["code": code.deviceCode, "client_id": clientID]
        if !code.codeVerifier.isEmpty { body["code_verifier"] = code.codeVerifier }
        let req = request("/oauth/device/token", method: "POST", body: withSecret(body), base: Self.oauthBase)
        guard let result = try? await URLSession.shared.data(for: req),
              let status = (result.1 as? HTTPURLResponse)?.statusCode else { return .pending }
        let data = result.0
        switch status {
        case 200:
            if let tokens = try? JSONDecoder.snake.decode(TraktTokens.self, from: data) { return .approved(tokens) }
            return .failed(String(localized: "Trakt sent an answer Tellio couldn't read."))
        case 400: return .pending
        case 429: return .slowDown
        case 401, 403, 404: return .failed(String(localized: "Trakt didn't accept this sign-in. Check the Trakt app's client ID."))
        case 409: return .failed(String(localized: "That code was already used. Start again."))
        case 410: return .expired
        case 418: return .denied
        default: return .failed(String(localized: "Trakt answered \(status)."))
        }
    }

    func refresh(_ tokens: TraktTokens) async throws -> TraktTokens {
        let data = try await URLSession.shared.fetch(request("/oauth/token", method: "POST", body: withSecret([
            "refresh_token": tokens.refreshToken, "client_id": clientID,
            "redirect_uri": Self.redirect, "grant_type": "refresh_token",
        ]), base: Self.oauthBase))
        return try JSONDecoder.snake.decode(TraktTokens.self, from: data)
    }

    func username() async throws -> String {
        let settings: TraktUserSettings = try await get("/users/settings")
        return settings.user.username
    }

    // Reading

    func playback() async throws -> [TraktPlayback] {
        try await get("/sync/playback?extended=full")
    }

    /// Keys in WatchHistory's format: "movie-603" and "tv-1399:1:2".
    func watchedKeys() async throws -> Set<String> {
        let movies: [TraktWatchedMovie] = try await get("/sync/watched/movies")
        let shows: [TraktWatchedShow] = try await get("/sync/watched/shows")
        var keys = Set<String>()
        for item in movies {
            if let tmdb = item.movie.ids.tmdb { keys.insert("movie-\(tmdb)") }
        }
        for item in shows {
            guard let tmdb = item.show.ids.tmdb else { continue }
            for season in item.seasons ?? [] where season.number > 0 {
                for episode in season.episodes ?? [] {
                    keys.insert("tv-\(tmdb):\(season.number):\(episode.number)")
                }
            }
        }
        return keys
    }

    /// The watchlist as (kind, TMDB id) pairs.
    func watchlist() async throws -> [(MediaType, Int)] {
        let movies: [TraktListItem] = try await get("/sync/watchlist/movies")
        let shows: [TraktListItem] = try await get("/sync/watchlist/shows")
        var result: [(MediaType, Int)] = []
        for item in movies { if let id = item.movie?.ids.tmdb { result.append((MediaType.movie, id)) } }
        for item in shows { if let id = item.show?.ids.tmdb { result.append((MediaType.tv, id)) } }
        return result
    }

    // Writing

    /// Adds to (or removes from) watched history. `episodes` are (show TMDB id, season, episode).
    func setHistory(added: Bool, movies: [Int], episodes: [(Int, Int, Int)], shows: [Int] = []) async throws {
        var byShow: [Int: [Int: [Int]]] = [:]
        for (show, season, episode) in episodes { byShow[show, default: [:]][season, default: []].append(episode) }
        var showBodies: [[String: Any]] = []
        for (show, seasons) in byShow {
            var seasonBodies: [[String: Any]] = []
            for (season, numbers) in seasons {
                let episodeBodies: [[String: Any]] = numbers.map { ["number": $0] }
                seasonBodies.append(["number": season, "episodes": episodeBodies])
            }
            showBodies.append(["ids": ["tmdb": show], "seasons": seasonBodies])
        }
        for show in shows { showBodies.append(["ids": ["tmdb": show]]) }
        let movieBodies: [[String: Any]] = movies.map { ["ids": ["tmdb": $0]] }
        let body: [String: Any] = ["movies": movieBodies, "shows": showBodies]
        try await send(added ? "/sync/history" : "/sync/history/remove", body)
    }

    func setWatchlist(added: Bool, kind: MediaType, tmdbID: Int) async throws {
        let entry: [String: Any] = ["ids": ["tmdb": tmdbID]]
        let body: [String: Any] = kind == .movie ? ["movies": [entry]] : ["shows": [entry]]
        try await send(added ? "/sync/watchlist" : "/sync/watchlist/remove", body)
    }

    /// "start", "pause" or "stop" for a movie or episode at `progress` percent.
    func scrobble(_ action: String, context: WatchContext, progress: Double) async throws {
        var body: [String: Any] = ["progress": min(max(progress, 0), 100)]
        if let season = context.season, let episode = context.episode {
            body["show"] = ["ids": ["tmdb": context.item.id]]
            body["episode"] = ["season": season, "number": episode]
        } else {
            body["movie"] = ["ids": ["tmdb": context.item.id]]
        }
        try await send("/scrobble/\(action)", body)
    }
}

// MARK: - Sync

/// The Trakt account and syncing. Credentials and tokens live in the Keychain;
/// what to sync is in Preferences (Settings › Connections › Trakt).
@MainActor
final class TraktSync: ObservableObject {
    static let shared = TraktSync()

    @Published var clientID: String { didSet { Keychain.set(clientID, for: "traktClientID") } }
    @Published var clientSecret: String { didSet { Keychain.set(clientSecret, for: "traktClientSecret") } }
    @Published private(set) var tokens: TraktTokens?
    @Published private(set) var username: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?

    private weak var settings: AppSettings?
    private var itemCache: [String: TMDBItem] = [:]

    private init() {
        clientID = Keychain.string(for: "traktClientID") ?? ""
        clientSecret = Keychain.string(for: "traktClientSecret") ?? ""
        tokens = Keychain.codable(TraktTokens.self, for: "traktTokens")
        username = UserDefaults.standard.string(forKey: "traktUsername")
    }

    /// The Client ID built into this copy (GitHub secret TRAKT_CLIENT_ID), if any.
    static let builtInClientID: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("$(") ? "" : value
    }()

    /// The app in use: your own if you've entered one, otherwise the built-in one.
    var usingOwnApp: Bool { !clientID.isEmpty }
    var hasBuiltInApp: Bool { !Self.builtInClientID.isEmpty }
    private var activeClientID: String { usingOwnApp ? clientID : Self.builtInClientID }
    private var activeSecret: String { usingOwnApp ? clientSecret : "" }
    private var api: TraktClient { TraktClient(clientID: activeClientID, clientSecret: activeSecret) }

    /// Only a Client ID is needed: Trakt apps made since October 2026 have no secret.
    var hasApp: Bool { !activeClientID.isEmpty }
    var isSignedIn: Bool { tokens != nil }

    private var prefs: Preferences? { settings?.prefs }

    /// Called once from the root view so syncing can read preferences and TMDB.
    func attach(_ settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Sign-in

    func startSignIn() async throws -> TraktDeviceCode {
        try await api.deviceCode()
    }

    func poll(_ code: TraktDeviceCode) async -> TraktPoll {
        let result = await api.poll(code)
        if case .approved(let tokens) = result {
            store(tokens)
            username = try? await TraktClient(clientID: activeClientID, clientSecret: activeSecret,
                                              accessToken: tokens.accessToken).username()
            UserDefaults.standard.set(username, forKey: "traktUsername")
            await sync()
        }
        return result
    }

    struct Backup: Codable {
        var clientID: String
        var clientSecret: String
        var tokens: TraktTokens?
        var username: String?
    }

    var backup: Backup {
        Backup(clientID: clientID, clientSecret: clientSecret, tokens: tokens, username: username)
    }

    func restore(_ backup: Backup) {
        clientID = backup.clientID
        clientSecret = backup.clientSecret
        store(backup.tokens)
        username = backup.username
        UserDefaults.standard.set(backup.username, forKey: "traktUsername")
    }

    func signOut() {
        store(nil)
        username = nil
        lastSync = nil
        UserDefaults.standard.removeObject(forKey: "traktUsername")
        WatchHistory.shared.setExternalWatched([])
    }

    private func store(_ tokens: TraktTokens?) {
        self.tokens = tokens
        if let tokens { Keychain.setCodable(tokens, for: "traktTokens") } else { Keychain.setData(nil, for: "traktTokens") }
    }

    /// A client with a fresh token, refreshing it when it's within a day of expiring.
    private func client() async -> TraktClient? {
        guard hasApp, var tokens else { return nil }
        if tokens.expiresAt < Date().addingTimeInterval(86_400) {
            guard let fresh = try? await api.refresh(tokens) else {
                lastError = String(localized: "Trakt sign-in expired. Sign in again.")
                return nil
            }
            store(fresh)
            tokens = fresh
        }
        return TraktClient(clientID: activeClientID, clientSecret: activeSecret, accessToken: tokens.accessToken)
    }

    // MARK: Syncing

    /// Syncs when the app opens and every 10 minutes while it's open.
    func run() async {
        while !Task.isCancelled {
            if isSignedIn { await sync() }
            try? await Task.sleep(for: .seconds(600))
        }
    }

    func sync() async {
        guard !syncing, let prefs, let client = await client() else { return }
        syncing = true
        defer { syncing = false }
        lastError = nil
        do {
            if prefs.traktHistory {
                let keys = try await client.watchedKeys()
                WatchHistory.shared.setExternalWatched(keys)
                try await pushLocalWatched(client, known: keys)
            }
            if prefs.traktProgress {
                try await pullProgress(client)
            }
            if prefs.traktWatchlist {
                try await syncWatchlist(client)
            }
            lastSync = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Things marked watched on this Apple TV that Trakt doesn't have yet.
    private func pushLocalWatched(_ client: TraktClient, known: Set<String>) async throws {
        let local = WatchHistory.shared.entries.values.filter { $0.watched && !known.contains($0.id) }
        let movies = local.filter { $0.context.season == nil }.map(\.item.id)
        let episodes = local.compactMap { entry -> (Int, Int, Int)? in
            guard let season = entry.context.season, let episode = entry.context.episode else { return nil }
            return (entry.item.id, season, episode)
        }
        guard !movies.isEmpty || !episodes.isEmpty else { return }
        try await client.setHistory(added: true, movies: movies, episodes: episodes)
        var keys = known
        for entry in local { keys.insert(entry.id) }
        WatchHistory.shared.setExternalWatched(keys)
    }

    /// Paused movies and episodes from Trakt become Continue Watching entries.
    private func pullProgress(_ client: TraktClient) async throws {
        let items = try await client.playback()
        for playback in items.prefix(30) {
            let paused = playback.pausedAt.flatMap { SportsDate.parse($0) } ?? Date()
            if let movie = playback.movie, let tmdb = movie.ids.tmdb, let imdb = movie.ids.imdb,
               let item = await lookUp(.movie, tmdb) {
                let duration = Double((movie.runtime ?? 0) > 0 ? movie.runtime! : 110) * 60
                WatchHistory.shared.mergeRemote(WatchContext(item: item, imdbID: imdb),
                                                position: duration * playback.progress / 100,
                                                duration: duration, updated: paused)
            } else if let show = playback.show, let episode = playback.episode,
                      let tmdb = show.ids.tmdb, let imdb = show.ids.imdb, let item = await lookUp(.tv, tmdb) {
                let duration = Double((episode.runtime ?? 0) > 0 ? episode.runtime! : 45) * 60
                let context = WatchContext(item: item, imdbID: imdb, season: episode.season,
                                           episode: episode.number, episodeName: episode.title)
                WatchHistory.shared.mergeRemote(context, position: duration * playback.progress / 100,
                                                duration: duration, updated: paused)
            }
        }
    }

    /// Trakt's watchlist and My List end up the same: each side gets what the other has.
    private func syncWatchlist(_ client: TraktClient) async throws {
        guard let settings else { return }
        let remote = try await client.watchlist()
        let remoteKeys = Set(remote.map { "\($0.0.rawValue)-\($0.1)" })
        for item in settings.prefs.myList where !remoteKeys.contains(item.uid) {
            try await client.setWatchlist(added: true, kind: item.kind, tmdbID: item.id)
        }
        let localKeys = Set(settings.prefs.myList.map(\.uid))
        for (kind, id) in remote where !localKeys.contains("\(kind.rawValue)-\(id)") {
            if let found = await lookUp(kind, id) { settings.prefs.myList.append(found) }
        }
    }

    private func lookUp(_ kind: MediaType, _ id: Int) async -> TMDBItem? {
        let key = "\(kind.rawValue)-\(id)"
        if let cached = itemCache[key] { return cached }
        guard let settings, !settings.tmdbToken.isEmpty,
              let item = try? await settings.tmdb.item(kind, id: id) else { return nil }
        itemCache[key] = item
        return item
    }

    // MARK: Changes made in Tellio

    /// Marked watched or unwatched by hand.
    func historyChanged(_ contexts: [WatchContext], watched: Bool) {
        guard prefs?.traktHistory == true, isSignedIn, !contexts.isEmpty else { return }
        Task {
            guard let client = await client() else { return }
            let movies = contexts.filter { $0.season == nil }.map(\.item.id)
            let episodes = contexts.compactMap { c -> (Int, Int, Int)? in
                guard let s = c.season, let e = c.episode else { return nil }
                return (c.item.id, s, e)
            }
            try? await client.setHistory(added: watched, movies: movies, episodes: episodes)
        }
    }

    /// A whole series marked watched or unwatched from its poster.
    func seriesChanged(_ item: TMDBItem, watched: Bool) {
        guard prefs?.traktHistory == true, isSignedIn else { return }
        Task {
            guard let client = await client() else { return }
            try? await client.setHistory(added: watched, movies: [], episodes: [], shows: [item.id])
        }
    }

    /// Finished by playing to the end. With scrobbling on, Trakt records it from the scrobble instead.
    func playbackFinished(_ context: WatchContext) {
        guard prefs?.traktScrobble != true else { return }
        historyChanged([context], watched: true)
    }

    func watchlistChanged(_ item: TMDBItem, added: Bool) {
        guard prefs?.traktWatchlist == true, isSignedIn else { return }
        Task {
            guard let client = await client() else { return }
            try? await client.setWatchlist(added: added, kind: item.kind, tmdbID: item.id)
        }
    }

    /// Tells Trakt what's playing ("Watching now"); stopping saves progress or marks it watched at 80%.
    func scrobble(_ action: String, context: WatchContext, progress: Double) {
        guard prefs?.traktScrobble == true, isSignedIn else { return }
        Task {
            guard let client = await client() else { return }
            try? await client.scrobble(action, context: context, progress: progress)
        }
    }
}

// MARK: - PKCE

/// Proof Key for Code Exchange (S256): a random verifier kept on the Apple TV and its
/// SHA-256 challenge sent with the sign-in request.
enum PKCE {
    private static let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 64 characters from the allowed set (Trakt accepts 43 to 128).
    static func verifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in characters[Int(generator.next(upperBound: UInt(characters.count)))] })
    }

    /// base64url of SHA-256(verifier), without padding.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
