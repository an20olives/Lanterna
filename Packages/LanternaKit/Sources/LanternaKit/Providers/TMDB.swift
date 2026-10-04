import Foundation

public enum TMDBImage {
    public enum Size: String { case poster = "w500", backdrop = "w1280", still = "w780", profile = "w185", original = "original", providerLogo = "w92" }
    public static func url(_ path: String?, _ size: Size) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }
}

public struct SearchResults: Sendable {
    public var titles: [TitleSummary]
    public var people: [CastMember]
}

/// TMDB API v3 with a v4 read token (Bearer). The token lives in Keychain; this type holds it in memory only.
public struct TMDBClient: Sendable {
    public enum Window: String, Sendable { case day, week }
    public static let baseURL = URL(string: "https://api.themoviedb.org/3")!

    let readToken: String
    let http: HTTPClient

    public init(readToken: String, http: HTTPClient = HTTPClient()) {
        self.readToken = readToken
        self.http = http
    }

    func request(_ path: String, _ query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: DTOs

    struct ListDTO: Decodable {
        let page: Int?
        let total_pages: Int?
        let results: [ItemDTO]
    }

    struct ItemDTO: Decodable {
        let id: Int
        let media_type: String?
        let title: String?
        let name: String?
        let release_date: String?
        let first_air_date: String?
        let poster_path: String?
        let backdrop_path: String?
        let overview: String?
        let vote_average: Double?
        let profile_path: String?
    }

    struct GenreDTO: Decodable { let name: String }
    struct DetailDTO: Decodable {
        struct External: Decodable { let imdb_id: String? }
        struct Videos: Decodable {
            struct Video: Decodable { let key: String; let name: String; let site: String; let type: String }
            let results: [Video]
        }
        struct Credits: Decodable {
            struct Cast: Decodable { let id: Int; let name: String; let character: String?; let profile_path: String? }
            let cast: [Cast]
        }
        struct Images: Decodable {
            struct Logo: Decodable { let file_path: String; let iso_639_1: String? }
            let logos: [Logo]
        }
        struct ReleaseDates: Decodable {
            struct Country: Decodable {
                struct Release: Decodable { let certification: String?; let type: Int? }
                let iso_3166_1: String
                let release_dates: [Release]
            }
            let results: [Country]
        }
        struct ContentRatings: Decodable {
            struct Rating: Decodable { let iso_3166_1: String; let rating: String }
            let results: [Rating]
        }
        struct Season: Decodable { let season_number: Int; let name: String; let episode_count: Int; let poster_path: String? }

        let id: Int
        let title: String?
        let name: String?
        let tagline: String?
        let runtime: Int?
        let episode_run_time: [Int]?
        let release_date: String?
        let first_air_date: String?
        let overview: String?
        let poster_path: String?
        let backdrop_path: String?
        let vote_average: Double?
        let genres: [GenreDTO]?
        let external_ids: External?
        let videos: Videos?
        let credits: Credits?
        let images: Images?
        let release_dates: ReleaseDates?
        let content_ratings: ContentRatings?
        let seasons: [Season]?
    }

    // MARK: Mapping

    static func year(_ date: String?) -> Int? { date.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }

    static func summary(_ item: ItemDTO, defaultKind: TitleRef.Kind? = nil) -> TitleSummary? {
        let kind: TitleRef.Kind
        switch item.media_type {
        case "movie": kind = .movie
        case "tv": kind = .show
        case nil: guard let defaultKind else { return nil }; kind = defaultKind
        default: return nil
        }
        let title = kind == .movie ? item.title : item.name
        guard let title else { return nil }
        return TitleSummary(ref: TitleRef(kind: kind, tmdbID: item.id), title: title,
                            year: year(kind == .movie ? item.release_date : item.first_air_date),
                            overview: item.overview, posterPath: item.poster_path, backdropPath: item.backdrop_path,
                            rating: item.vote_average)
    }

    func page(_ list: ListDTO, defaultKind: TitleRef.Kind?) -> Page<TitleSummary> {
        let items = list.results.compactMap { Self.summary($0, defaultKind: defaultKind) }
        let next: PageCursor? = {
            guard let page = list.page, let total = list.total_pages, page < total else { return nil }
            return PageCursor(String(page + 1))
        }()
        return Page(items: items, next: next)
    }

    // MARK: Lists

    public func trending(window: Window, cursor: PageCursor? = nil) async throws -> Page<TitleSummary> {
        let list: ListDTO = try await http.json(request("trending/all/\(window.rawValue)", ["page": cursor?.value ?? "1"]))
        return page(list, defaultKind: nil)
    }

    public func trending(kind: TitleRef.Kind, window: Window, cursor: PageCursor? = nil) async throws -> Page<TitleSummary> {
        let type = kind == .movie ? "movie" : "tv"
        let list: ListDTO = try await http.json(request("trending/\(type)/\(window.rawValue)", ["page": cursor?.value ?? "1"]))
        return page(list, defaultKind: kind)
    }

    /// `endpoint` is `popular`, `top_rated`, `now_playing`, `upcoming` (movies) or `popular`, `top_rated`, `on_the_air` (shows).
    public func list(kind: TitleRef.Kind, endpoint: String, cursor: PageCursor? = nil) async throws -> Page<TitleSummary> {
        let type = kind == .movie ? "movie" : "tv"
        let list: ListDTO = try await http.json(request("\(type)/\(endpoint)", ["page": cursor?.value ?? "1"]))
        return page(list, defaultKind: kind)
    }

    public func discover(kind: TitleRef.Kind, filters: [String: String], cursor: PageCursor? = nil) async throws -> Page<TitleSummary> {
        let type = kind == .movie ? "movie" : "tv"
        var query = filters
        query["page"] = cursor?.value ?? "1"
        let list: ListDTO = try await http.json(request("discover/\(type)", query))
        return page(list, defaultKind: kind)
    }

    // MARK: Detail

    public func detail(_ ref: TitleRef, region: String) async throws -> TitleDetail {
        let isMovie = ref.kind == .movie
        let append = isMovie ? "external_ids,videos,credits,images,release_dates" : "external_ids,videos,credits,images,content_ratings"
        let dto: DetailDTO = try await http.json(request("\(isMovie ? "movie" : "tv")/\(ref.tmdbID)",
                                                          ["append_to_response": append, "include_image_language": "en,null"]))
        let imdb = dto.external_ids?.imdb_id
        let kind: TitleRef.Kind = isMovie ? .movie : .show
        let title = (isMovie ? dto.title : dto.name) ?? ""
        let summary = TitleSummary(ref: TitleRef(kind: kind, tmdbID: dto.id, imdbID: imdb), title: title,
                                   year: Self.year(isMovie ? dto.release_date : dto.first_air_date), overview: dto.overview,
                                   posterPath: dto.poster_path, backdropPath: dto.backdrop_path, rating: dto.vote_average)
        let certification: String? = {
            if isMovie {
                let country = dto.release_dates?.results.first { $0.iso_3166_1 == region }
                let releases = country?.release_dates.filter { !($0.certification ?? "").isEmpty } ?? []
                return (releases.first { $0.type == 3 } ?? releases.first)?.certification
            }
            return dto.content_ratings?.results.first { $0.iso_3166_1 == region }?.rating
        }()
        let logo = dto.images?.logos.first { $0.iso_639_1 == "en" } ?? dto.images?.logos.first { $0.iso_639_1 == nil }
        return TitleDetail(
            summary: summary,
            tagline: (dto.tagline ?? "").isEmpty ? nil : dto.tagline,
            runtimeMinutes: isMovie ? dto.runtime : dto.episode_run_time?.first,
            certification: certification,
            genres: (dto.genres ?? []).map(\.name),
            logoPath: logo?.file_path,
            cast: (dto.credits?.cast ?? []).prefix(20).map { CastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profile_path) },
            trailers: (dto.videos?.results ?? []).filter { $0.site == "YouTube" && $0.type == "Trailer" }.map { Trailer(youtubeKey: $0.key, name: $0.name) },
            seasons: (dto.seasons ?? []).map { SeasonSummary(number: $0.season_number, name: $0.name, episodeCount: $0.episode_count, posterPath: $0.poster_path) })
    }

    public func season(showID: Int, number: Int) async throws -> [EpisodeSummary] {
        struct SeasonDTO: Decodable {
            struct Episode: Decodable {
                let season_number: Int; let episode_number: Int; let name: String; let overview: String?
                let air_date: String?; let still_path: String?; let runtime: Int?; let vote_average: Double?
            }
            let episodes: [Episode]
        }
        let dto: SeasonDTO = try await http.json(request("tv/\(showID)/season/\(number)"))
        return dto.episodes.map {
            EpisodeSummary(season: $0.season_number, number: $0.episode_number, name: $0.name, overview: $0.overview,
                           airDate: Self.date($0.air_date), stillPath: $0.still_path, runtimeMinutes: $0.runtime, rating: $0.vote_average)
        }
    }

    static func date(_ string: String?) -> Date? {
        guard let string, string.count == 10 else { return nil }
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: Search, find, providers

    public func search(_ query: String, cursor: PageCursor? = nil) async throws -> SearchResults {
        let list: ListDTO = try await http.json(request("search/multi", ["query": query, "page": cursor?.value ?? "1", "include_adult": "false"]))
        let people = list.results.filter { $0.media_type == "person" }.map {
            CastMember(id: $0.id, name: $0.name ?? "", profilePath: $0.profile_path)
        }
        return SearchResults(titles: list.results.compactMap { Self.summary($0) }, people: people)
    }

    /// Maps an IMDb ID (from a Stremio source) to a TMDB title.
    public func find(imdbID: String) async throws -> TitleSummary? {
        struct FindDTO: Decodable { let movie_results: [ItemDTO]; let tv_results: [ItemDTO] }
        let dto: FindDTO = try await http.json(request("find/\(imdbID)", ["external_source": "imdb_id"]))
        if let movie = dto.movie_results.first, var summary = Self.summary(movie, defaultKind: .movie) {
            summary.ref.imdbID = imdbID
            return summary
        }
        if let show = dto.tv_results.first, var summary = Self.summary(show, defaultKind: .show) {
            summary.ref.imdbID = imdbID
            return summary
        }
        return nil
    }

    public func watchProviders(for ref: TitleRef, region: String) async throws -> [ProviderOffer] {
        struct DTO: Decodable {
            struct Provider: Decodable { let provider_id: Int; let provider_name: String; let logo_path: String? }
            struct Region: Decodable {
                let flatrate: [Provider]?; let free: [Provider]?; let ads: [Provider]?; let rent: [Provider]?; let buy: [Provider]?
            }
            let results: [String: Region]
        }
        let dto: DTO = try await http.json(request("\(ref.kind == .movie ? "movie" : "tv")/\(ref.tmdbID)/watch/providers"))
        guard let region = dto.results[region] else { return [] }
        func offers(_ providers: [DTO.Provider]?, _ type: ProviderOffer.OfferType) -> [ProviderOffer] {
            (providers ?? []).map { ProviderOffer(providerID: $0.provider_id, name: $0.provider_name, type: type, logoPath: $0.logo_path) }
        }
        return offers(region.flatrate, .flatrate) + offers(region.free, .free) + offers(region.ads, .ads)
            + offers(region.rent, .rent) + offers(region.buy, .buy)
    }

    /// All providers TMDB knows for a region, for the Your Services picker.
    public func providerCatalog(region: String) async throws -> [ProviderOffer] {
        struct DTO: Decodable {
            struct Provider: Decodable { let provider_id: Int; let provider_name: String; let logo_path: String?; let display_priority: Int? }
            let results: [Provider]
        }
        async let movies: DTO = http.json(request("watch/providers/movie", ["watch_region": region]))
        async let shows: DTO = http.json(request("watch/providers/tv", ["watch_region": region]))
        var seen = Set<Int>()
        let all = try await movies.results + shows.results
        return all.filter { seen.insert($0.provider_id).inserted }
            .sorted { ($0.display_priority ?? 999) < ($1.display_priority ?? 999) }
            .map { ProviderOffer(providerID: $0.provider_id, name: $0.provider_name, type: .flatrate, logoPath: $0.logo_path) }
    }
}

public struct TMDBSource: MediaSource {
    public let id: SourceID
    public let kind = SourceKind.tmdb
    public let displayName = "TMDB"
    public let capabilities: SourceCapabilities = [.catalogs, .metadata, .watchProviders]
    let client: TMDBClient
    let region: String

    public init(id: SourceID, client: TMDBClient, region: String) {
        self.id = id
        self.client = client
        self.region = region
    }

    static let catalogTable: [(id: String, title: String, kind: TitleRef.Kind)] = [
        ("trending-movie", "Trending Movies", .movie), ("trending-show", "Trending Shows", .show),
        ("popular-movie", "Popular Movies", .movie), ("popular-show", "Popular Shows", .show),
        ("top_rated-movie", "Top Rated Movies", .movie), ("top_rated-show", "Top Rated Shows", .show),
        ("now_playing-movie", "In Theaters", .movie), ("on_the_air-show", "On the Air", .show),
    ]

    public func catalogs() async throws -> [CatalogDescriptor] {
        Self.catalogTable.map { CatalogDescriptor(id: $0.id, title: $0.title, kind: $0.kind) }
    }

    public func catalogPage(_ catalog: CatalogDescriptor, cursor: PageCursor?) async throws -> Page<TitleSummary> {
        let endpoint = catalog.id.split(separator: "-").first.map(String.init) ?? "popular"
        if endpoint == "trending" { return try await client.trending(kind: catalog.kind, window: .week, cursor: cursor) }
        return try await client.list(kind: catalog.kind, endpoint: endpoint, cursor: cursor)
    }

    public func metadata(for title: TitleRef) async throws -> TitleDetail { try await client.detail(title.showRef, region: region) }

    public func watchProviders(for title: TitleRef, region: String) async throws -> [ProviderOffer] {
        try await client.watchProviders(for: title.showRef, region: region)
    }
}
