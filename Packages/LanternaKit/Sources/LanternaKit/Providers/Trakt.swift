import Foundation

public struct TraktDeviceCode: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var expiresIn: Int
    public var interval: Int
}

public struct TraktTokens: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public enum TraktPoll: Sendable, Equatable {
    case pending, slowDown, expired, denied, invalid, alreadyUsed
    case signedIn(TraktTokens)
}

public struct TraktPlaybackItem: Sendable, Equatable {
    public var id: Int64
    public var ref: TitleRef
    public var title: String
    /// Percent, 0 to 100.
    public var progress: Double
    public var pausedAt: Date
}

public struct TraktListItem: Sendable, Equatable {
    public var ref: TitleRef
    public var title: String
    public var listedAt: Date
}

public struct TraktHistoryItem: Sendable, Equatable {
    public var historyID: Int64
    public var ref: TitleRef
    public var title: String
    public var watchedAt: Date
}

public struct TraktLastActivities: Sendable, Decodable, Equatable {
    public var all: String?
    public var movies: [String: String]?
    public var episodes: [String: String]?
    public var shows: [String: String]?
}

public enum TraktScrobbleAction: String, Sendable { case start, pause, stop }

enum TraktDates {
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Trakt API v2. Client ID and secret belong to the owner's own Trakt app; user tokens are per device.
public struct TraktClient: Sendable {
    public static let baseURL = URL(string: "https://api.trakt.tv")!

    let clientID: String
    let clientSecret: String
    let accessToken: String?
    let http: HTTPClient
    let transport: any HTTPTransport

    public init(clientID: String, clientSecret: String, accessToken: String? = nil, http: HTTPClient? = nil,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.transport = transport
        self.http = http ?? HTTPClient(transport: transport)
    }

    func request(_ path: String, query: [String: String] = [:], method: String = "GET", json: [String: Any]? = nil, authorized: Bool = true) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try? JSONSerialization.data(withJSONObject: json) }
        return request
    }

    // MARK: Auth (device code)

    public func deviceCode() async throws -> TraktDeviceCode {
        struct DTO: Decodable { let device_code: String; let user_code: String; let verification_url: String; let expires_in: Int; let interval: Int }
        let dto: DTO = try await http.json(request("/oauth/device/code", method: "POST", json: ["client_id": clientID], authorized: false))
        guard let url = URL(string: dto.verification_url) else { throw SourceError.malformedResponse }
        return TraktDeviceCode(deviceCode: dto.device_code, userCode: dto.user_code, verificationURL: url, expiresIn: dto.expires_in, interval: dto.interval)
    }

    struct TokenDTO: Decodable {
        let access_token: String; let refresh_token: String; let expires_in: Int; let created_at: Int
        var tokens: TraktTokens {
            TraktTokens(accessToken: access_token, refreshToken: refresh_token,
                        expiresAt: Date(timeIntervalSince1970: TimeInterval(created_at + expires_in)))
        }
    }

    public func pollDeviceToken(deviceCode: String) async throws -> TraktPoll {
        let body: [String: Any] = ["code": deviceCode, "client_id": clientID, "client_secret": clientSecret]
        let (data, response) = try await transport.data(for: request("/oauth/device/token", method: "POST", json: body, authorized: false))
        switch response.statusCode {
        case 200:
            guard let dto = try? JSONDecoder().decode(TokenDTO.self, from: data) else { throw SourceError.malformedResponse }
            return .signedIn(dto.tokens)
        case 400: return .pending
        case 404: return .invalid
        case 409: return .alreadyUsed
        case 410: return .expired
        case 418: return .denied
        case 429: return .slowDown
        default: throw SourceError.http(status: response.statusCode)
        }
    }

    /// Trakt rotates the refresh token on every refresh: store both returned tokens atomically.
    public func refresh(refreshToken: String) async throws -> TraktTokens {
        let body: [String: Any] = ["refresh_token": refreshToken, "client_id": clientID, "client_secret": clientSecret,
                                   "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]
        let dto: TokenDTO = try await http.json(request("/oauth/token", method: "POST", json: body, authorized: false))
        return dto.tokens
    }

    // MARK: Sync

    public func lastActivities() async throws -> TraktLastActivities {
        try await http.json(request("/sync/last_activities"))
    }

    struct IDs: Decodable { let tmdb: Int?; let imdb: String? }
    struct MediaDTO: Decodable { let title: String?; let year: Int?; let ids: IDs }
    struct EpisodeDTO: Decodable { let season: Int; let number: Int; let title: String? }
    struct EntryDTO: Decodable {
        let id: Int64?
        let type: String
        let progress: Double?
        let paused_at: String?
        let listed_at: String?
        let watched_at: String?
        let movie: MediaDTO?
        let show: MediaDTO?
        let episode: EpisodeDTO?

        var ref: TitleRef? {
            switch type {
            case "movie": return movie?.ids.tmdb.map { .movie(tmdbID: $0, imdbID: movie?.ids.imdb) }
            case "show": return show?.ids.tmdb.map { .show(tmdbID: $0, imdbID: show?.ids.imdb) }
            case "episode":
                guard let tmdb = show?.ids.tmdb, let episode else { return nil }
                return .episode(showTMDBID: tmdb, imdbID: show?.ids.imdb, season: episode.season, episode: episode.number)
            default: return nil
            }
        }
        var displayTitle: String { (type == "movie" ? movie?.title : show?.title) ?? "" }
    }

    public func playback() async throws -> [TraktPlaybackItem] {
        let entries: [EntryDTO] = try await http.json(request("/sync/playback"))
        return entries.compactMap { entry in
            guard let ref = entry.ref, let id = entry.id else { return nil }
            return TraktPlaybackItem(id: id, ref: ref, title: entry.displayTitle, progress: entry.progress ?? 0,
                                     pausedAt: TraktDates.parse(entry.paused_at) ?? .distantPast)
        }
    }

    public func removePlayback(id: Int64) async throws {
        _ = try await http.send(request("/sync/playback/\(id)", method: "DELETE"))
    }

    public func watchlist() async throws -> [TraktListItem] {
        let entries: [EntryDTO] = try await http.json(request("/sync/watchlist"))
        return entries.compactMap { entry in
            guard let ref = entry.ref else { return nil }
            return TraktListItem(ref: ref, title: entry.displayTitle, listedAt: TraktDates.parse(entry.listed_at) ?? .distantPast)
        }
    }

    public func history(since: Date? = nil, limit: Int = 100) async throws -> [TraktHistoryItem] {
        var query = ["limit": String(limit)]
        if let since { query["start_at"] = ISO8601DateFormatter().string(from: since) }
        let entries: [EntryDTO] = try await http.json(request("/sync/history", query: query))
        return entries.compactMap { entry in
            guard let ref = entry.ref, let id = entry.id else { return nil }
            return TraktHistoryItem(historyID: id, ref: ref, title: entry.displayTitle, watchedAt: TraktDates.parse(entry.watched_at) ?? .distantPast)
        }
    }

    static func syncBody(_ ref: TitleRef, extra: [String: Any] = [:]) -> [String: Any] {
        switch ref.kind {
        case .movie: return ["movies": [["ids": ["tmdb": ref.tmdbID]].merging(extra) { $1 }]]
        case .show: return ["shows": [["ids": ["tmdb": ref.tmdbID]].merging(extra) { $1 }]]
        case .episode:
            return ["shows": [["ids": ["tmdb": ref.tmdbID],
                               "seasons": [["number": ref.season ?? 0, "episodes": [["number": ref.episode ?? 0].merging(extra) { $1 }]]]]]]
        }
    }

    public func addToWatchlist(_ ref: TitleRef) async throws {
        _ = try await http.send(request("/sync/watchlist", method: "POST", json: Self.syncBody(ref.showRef)))
    }

    public func removeFromWatchlist(_ ref: TitleRef) async throws {
        _ = try await http.send(request("/sync/watchlist/remove", method: "POST", json: Self.syncBody(ref.showRef)))
    }

    public func addToHistory(_ ref: TitleRef, watchedAt: Date) async throws {
        _ = try await http.send(request("/sync/history", method: "POST",
                                        json: Self.syncBody(ref, extra: ["watched_at": ISO8601DateFormatter().string(from: watchedAt)])))
    }

    public func removeFromHistory(_ ref: TitleRef) async throws {
        _ = try await http.send(request("/sync/history/remove", method: "POST", json: Self.syncBody(ref)))
    }

    // MARK: Scrobble

    /// A 409 means Trakt already has this scrobble (a retried stop): treated as success.
    public func scrobble(_ action: TraktScrobbleAction, title: TitleRef, progress: Double) async throws {
        var body: [String: Any] = ["progress": progress]
        switch title.kind {
        case .movie: body["movie"] = ["ids": ["tmdb": title.tmdbID]]
        case .show: throw SourceError.unsupported
        case .episode:
            body["show"] = ["ids": ["tmdb": title.tmdbID]]
            body["episode"] = ["season": title.season ?? 0, "number": title.episode ?? 0]
        }
        let (_, response) = try await transport.data(for: request("/scrobble/\(action.rawValue)", method: "POST", json: body))
        switch response.statusCode {
        case 200..<300, 409: return
        case 401: throw SourceError.needsCredentials
        case 429: throw SourceError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw SourceError.http(status: response.statusCode)
        }
    }
}
