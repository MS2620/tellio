import Foundation

enum MediaType: String, Codable, Hashable {
    case movie, tv
}

struct TMDBItem: Codable, Hashable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genreIds: [Int]?
    var mediaType: String?

    var kind: MediaType { MediaType(rawValue: mediaType ?? "") ?? (title != nil ? .movie : .tv) }
    var uid: String { "\(kind.rawValue)-\(id)" }
    var displayTitle: String { title ?? name ?? String(localized: "Untitled") }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
    var rating: String? {
        guard let voteAverage, voteAverage > 0 else { return nil }
        return String(format: "%.1f", voteAverage)
    }
    var backdropURL: URL? { backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280\($0)") } }

    /// Up to two genre names, from TMDB's fixed genre ids.
    var genreNames: [String] {
        (genreIds ?? []).compactMap { TMDBGenres.names[$0] }.prefix(2).map { $0 }
    }
}

enum TMDBGenres {
    static let names: [Int: String] = [
        28: String(localized: "Action"),
        12: String(localized: "Adventure"),
        16: String(localized: "Animation"),
        35: String(localized: "Comedy"),
        80: String(localized: "Crime"),
        99: String(localized: "Documentary"),
        18: String(localized: "Drama"),
        10751: String(localized: "Family"),
        14: String(localized: "Fantasy"),
        36: String(localized: "History"),
        27: String(localized: "Horror"),
        10402: String(localized: "Music"),
        9648: String(localized: "Mystery"),
        10749: String(localized: "Romance"),
        878: String(localized: "Sci-Fi"),
        10770: String(localized: "TV Movie"),
        53: String(localized: "Thriller"),
        10752: String(localized: "War"),
        37: String(localized: "Western"),
        10759: String(localized: "Action & Adventure"),
        10762: String(localized: "Kids"),
        10763: String(localized: "News"),
        10764: String(localized: "Reality"),
        10765: String(localized: "Sci-Fi & Fantasy"),
        10766: String(localized: "Soap"),
        10767: String(localized: "Talk"),
        10768: String(localized: "War & Politics"),
    ]
}

struct TMDBPage<T: Decodable>: Decodable { let results: [T] }
struct TMDBExternalIDs: Decodable { let imdbId: String? }
struct TVDetails: Decodable { let seasons: [TVSeasonSummary] }

struct TVSeasonSummary: Decodable, Hashable, Identifiable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let episodeCount: Int?
}

struct TVSeason: Decodable { let episodes: [TVEpisode] }

struct TVEpisode: Decodable, Hashable, Identifiable {
    let id: Int
    let episodeNumber: Int
    let seasonNumber: Int
    let name: String?
    let overview: String?
    let stillPath: String?
    let runtime: Int?
    let airDate: String?

    var stillURL: URL? { stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
}

/// Full details for a movie or series, with IMDb id, cast and recommendations in one request.
struct TMDBDetails: Decodable {
    struct Genre: Decodable, Hashable { let id: Int; let name: String }
    struct CastMember: Decodable, Hashable { let name: String }
    struct Credits: Decodable { let cast: [CastMember] }

    let genres: [Genre]?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let numberOfSeasons: Int?
    let tagline: String?
    let seasons: [TVSeasonSummary]?
    let externalIds: TMDBExternalIDs?
    let credits: Credits?
    let recommendations: TMDBPage<TMDBItem>?
    // Series only
    let nextEpisodeToAir: TVEpisode?
    let lastEpisodeToAir: TVEpisode?
    let status: String?
}

/// Uses a TMDB "API Read Access Token" (v4 bearer token).
struct TMDBClient {
    let token: String
    var language: String = ""
    var region: String = ""

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard var comps = URLComponents(string: "https://api.themoviedb.org/3/\(path)") else { throw URLError(.badURL) }
        var query = query
        if !language.isEmpty, query["language"] == nil { query["language"] = language }
        if !region.isEmpty, query["region"] == nil { query["region"] = region }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await URLSession.shared.fetch(request)
        return try JSONDecoder.snake.decode(T.self, from: data)
    }

    /// True when the token is accepted.
    func validate() async throws -> Bool {
        struct Reply: Decodable { let success: Bool? }
        let reply: Reply = try await get("authentication")
        return reply.success ?? false
    }

    func trending(_ type: MediaType) async throws -> [TMDBItem] {
        let page: TMDBPage<TMDBItem> = try await get("trending/\(type.rawValue)/week")
        return page.results.map { var item = $0; item.mediaType = type.rawValue; return item }
    }

    /// Movies and series together, keeping each item's own media type.
    func trendingAll() async throws -> [TMDBItem] {
        let page: TMDBPage<TMDBItem> = try await get("trending/all/week")
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    func popular(_ type: MediaType) async throws -> [TMDBItem] {
        let page: TMDBPage<TMDBItem> = try await get("\(type.rawValue)/popular")
        return page.results.map { var item = $0; item.mediaType = type.rawValue; return item }
    }

    /// Any TMDB list endpoint, e.g. "movie/now_playing" or "tv/top_rated".
    func list(_ path: String, type: MediaType, _ query: [String: String] = [:]) async throws -> [TMDBItem] {
        let page: TMDBPage<TMDBItem> = try await get(path, query)
        return page.results.map { var item = $0; item.mediaType = type.rawValue; return item }
    }

    func discover(_ type: MediaType, genre: Int) async throws -> [TMDBItem] {
        try await list("discover/\(type.rawValue)", type: type, [
            "with_genres": String(genre),
            "sort_by": "popularity.desc",
            "include_adult": "false",
        ])
    }

    func search(_ query: String) async throws -> [TMDBItem] {
        let page: TMDBPage<TMDBItem> = try await get("search/multi", ["query": query])
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    func details(for item: TMDBItem) async throws -> TMDBDetails {
        try await get("\(item.kind.rawValue)/\(item.id)",
                      ["append_to_response": "external_ids,credits,recommendations"])
    }

    /// Lightweight series details (no cast or recommendations), used by the Calendar.
    func tvDetails(id: Int) async throws -> TMDBDetails {
        try await get("tv/\(id)")
    }

    func imdbID(for item: TMDBItem) async throws -> String? {
        let ids: TMDBExternalIDs = try await get("\(item.kind.rawValue)/\(item.id)/external_ids")
        return ids.imdbId
    }

    func seasons(tvID: Int) async throws -> [TVSeasonSummary] {
        let details: TVDetails = try await get("tv/\(tvID)")
        return details.seasons.filter { $0.seasonNumber > 0 }
    }

    /// A movie or series by its TMDB id, e.g. one that came from Trakt.
    func item(_ kind: MediaType, id: Int) async throws -> TMDBItem {
        var item: TMDBItem = try await get("\(kind.rawValue)/\(id)")
        item.mediaType = kind.rawValue
        return item
    }

    func episodes(tvID: Int, season: Int) async throws -> [TVEpisode] {
        let s: TVSeason = try await get("tv/\(tvID)/season/\(season)")
        return s.episodes
    }
}
