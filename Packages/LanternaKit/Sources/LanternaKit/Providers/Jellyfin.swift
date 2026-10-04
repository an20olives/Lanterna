import Foundation

public struct JellyfinDevice: Sendable, Hashable {
    public var deviceID: String
    public var deviceName: String
    public var version: String
    public init(deviceID: String, deviceName: String, version: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.version = version
    }
}

public struct JellyfinAuth: Sendable, Equatable {
    public var accessToken: String
    public var userID: String
    public var serverID: String?
}

public struct JellyfinQuickConnect: Sendable, Equatable {
    public var code: String
    public var secret: String
}

public struct JellyfinPublicInfo: Sendable, Equatable {
    public var id: String
    public var serverName: String
    public var version: String?
}

struct JellyfinItem: Decodable {
    struct MediaSource: Decodable {
        struct Stream: Decodable {
            let `Type`: String?
            let Codec: String?
            let Width: Int?
            let Height: Int?
            let VideoRangeType: String?
            let DisplayTitle: String?
            let Channels: Int?
        }
        let Id: String
        let Size: Int64?
        let Container: String?
        let Name: String?
        let MediaStreams: [Stream]?
    }
    let Id: String
    let Name: String
    let `Type`: String?
    let ProductionYear: Int?
    let ProviderIds: [String: String]?
    let DateCreated: String?
    let RunTimeTicks: Int64?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let MediaSources: [MediaSource]?

    var tmdbID: Int? { ProviderIds?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) } }
    var imdbID: String? { ProviderIds?.first { $0.key.lowercased() == "imdb" }?.value }
}

/// Jellyfin REST client. Each device authenticates for its own token (Jellyfin binds tokens to DeviceId).
public struct JellyfinClient: Sendable {
    let baseURL: URL
    let device: JellyfinDevice
    let token: String?
    let userID: String?
    let http: HTTPClient

    public init(baseURL: URL, device: JellyfinDevice, token: String?, userID: String?, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.device = device
        self.token = token
        self.userID = userID
        self.http = http
    }

    var authorizationValue: String {
        var parts = ["Client=\"Lanterna\"", "Device=\"\(device.deviceName)\"", "DeviceId=\"\(device.deviceID)\"", "Version=\"\(device.version)\""]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    func request(_ path: String, query: [String: String] = [:], method: String = "GET", json: [String: Any]? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func publicInfo() async throws -> JellyfinPublicInfo {
        struct DTO: Decodable { let Id: String; let ServerName: String; let Version: String? }
        let dto: DTO = try await http.json(request("/System/Info/Public"))
        return JellyfinPublicInfo(id: dto.Id, serverName: dto.ServerName, version: dto.Version)
    }

    struct AuthDTO: Decodable {
        struct User: Decodable { let Id: String }
        let AccessToken: String
        let User: User
        let ServerId: String?
    }

    public func authenticateByName(username: String, password: String) async throws -> JellyfinAuth {
        let dto: AuthDTO = try await http.json(request("/Users/AuthenticateByName", method: "POST", json: ["Username": username, "Pw": password]))
        return JellyfinAuth(accessToken: dto.AccessToken, userID: dto.User.Id, serverID: dto.ServerId)
    }

    public func quickConnectInitiate() async throws -> JellyfinQuickConnect {
        struct DTO: Decodable { let Code: String; let Secret: String }
        let dto: DTO = try await http.json(request("/QuickConnect/Initiate", method: "POST"))
        return JellyfinQuickConnect(code: dto.Code, secret: dto.Secret)
    }

    public func quickConnectAuthenticated(secret: String) async throws -> Bool {
        struct DTO: Decodable { let Authenticated: Bool }
        let dto: DTO = try await http.json(request("/QuickConnect/Connect", query: ["secret": secret]))
        return dto.Authenticated
    }

    public func authenticateWithQuickConnect(secret: String) async throws -> JellyfinAuth {
        let dto: AuthDTO = try await http.json(request("/Users/AuthenticateWithQuickConnect", method: "POST", json: ["Secret": secret]))
        return JellyfinAuth(accessToken: dto.AccessToken, userID: dto.User.Id, serverID: dto.ServerId)
    }

    /// Called from an already signed-in device to approve another device's Quick Connect code.
    public func quickConnectAuthorize(code: String) async throws {
        _ = try await http.send(request("/QuickConnect/Authorize", query: ["code": code], method: "POST"))
    }

    func items(_ query: [String: String]) async throws -> (items: [JellyfinItem], total: Int) {
        struct DTO: Decodable { let Items: [JellyfinItem]; let TotalRecordCount: Int? }
        var query = query
        if let userID { query["userId"] = userID }
        let dto: DTO = try await http.json(request("/Items", query: query))
        return (dto.Items, dto.TotalRecordCount ?? dto.Items.count)
    }

    func episodes(seriesID: String, season: Int) async throws -> [JellyfinItem] {
        struct DTO: Decodable { let Items: [JellyfinItem] }
        var query = ["season": String(season), "Fields": "MediaSources,ProviderIds"]
        if let userID { query["userId"] = userID }
        let dto: DTO = try await http.json(request("/Shows/\(seriesID)/Episodes", query: query))
        return dto.Items
    }

    func report(path: String, itemID: String, mediaSourceID: String?, positionSeconds: Double, sessionID: String) async throws {
        var body: [String: Any] = ["ItemId": itemID, "PositionTicks": Int(positionSeconds * 10_000_000), "PlaySessionId": sessionID]
        if let mediaSourceID { body["MediaSourceId"] = mediaSourceID }
        _ = try await http.send(request(path, method: "POST", json: body))
    }

    func streamURL(itemID: String, mediaSourceID: String?) -> URL {
        var query = ["static": "true"]
        if let mediaSourceID { query["mediaSourceId"] = mediaSourceID }
        if let token { query["api_key"] = token }
        var components = URLComponents(url: baseURL.appending(path: "/Videos/\(itemID)/stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
}

public struct JellyfinSource: MediaSource {
    public let id: SourceID
    public let kind = SourceKind.jellyfin
    public let displayName: String
    public let capabilities: SourceCapabilities = [.library, .streams, .progressSync]
    let client: JellyfinClient

    public init(id: SourceID, displayName: String, client: JellyfinClient) {
        self.id = id
        self.displayName = displayName
        self.client = client
    }

    public func health() async -> SourceHealth {
        do {
            _ = try await client.publicInfo()
            return .ok
        } catch SourceError.needsCredentials {
            return .needsCredentials
        } catch {
            return .unreachable("The server did not answer")
        }
    }

    static func ref(for item: JellyfinItem) -> TitleRef? {
        guard let tmdb = item.tmdbID else { return nil }
        switch item.Type {
        case "Movie": return .movie(tmdbID: tmdb, imdbID: item.imdbID)
        case "Series": return .show(tmdbID: tmdb, imdbID: item.imdbID)
        default: return nil
        }
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        // Jellyfin writes 7 fractional digits, which ISO8601DateFormatter rejects.
        let trimmed = string.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }

    public func libraryPage(cursor: PageCursor?) async throws -> Page<OwnedItem> {
        let start = cursor.flatMap { Int($0.value) } ?? 0
        let result = try await client.items([
            "Recursive": "true", "IncludeItemTypes": "Movie,Series", "Fields": "ProviderIds,DateCreated,MediaSources",
            "SortBy": "DateCreated", "SortOrder": "Descending", "StartIndex": String(start), "Limit": "100",
        ])
        let items = result.items.map { item in
            OwnedItem(id: item.Id, sourceID: id, title: item.Name, year: item.ProductionYear,
                        sizeBytes: item.MediaSources?.first?.Size, dateAdded: Self.date(item.DateCreated),
                        matched: Self.ref(for: item))
        }
        let next = start + result.items.count
        return Page(items: items, next: next < result.total ? PageCursor(String(next)) : nil)
    }

    public func streams(for request: StreamRequest) async throws -> [StreamCandidate] {
        let title = request.title
        let sources: [(JellyfinItem, JellyfinItem.MediaSource)]
        switch title.kind {
        case .movie:
            let found = try await client.items(["Recursive": "true", "IncludeItemTypes": "Movie", "anyProviderIdEquals": "tmdb.\(title.tmdbID)", "Fields": "MediaSources,ProviderIds"])
            sources = found.items.flatMap { item in (item.MediaSources ?? []).map { (item, $0) } }
        case .episode, .show:
            guard title.kind == .episode, let season = title.season, let number = title.episode else { return [] }
            let series = try await client.items(["Recursive": "true", "IncludeItemTypes": "Series", "anyProviderIdEquals": "tmdb.\(title.tmdbID)"])
            guard let seriesItem = series.items.first else { return [] }
            let episodes = try await client.episodes(seriesID: seriesItem.Id, season: season)
            sources = episodes.filter { $0.IndexNumber == number }.flatMap { item in (item.MediaSources ?? []).map { (item, $0) } }
        }
        return sources.map { item, source in
            var format = Self.claimed(source)
            format.isCachedClaim = true
            return StreamCandidate(id: "jf:\(id.rawValue.uuidString):\(item.Id):\(source.Id)", sourceID: id, sourceKind: .jellyfin, title: title,
                                   displayName: source.Name ?? item.Name, sizeBytes: source.Size, claimed: format, isCached: true,
                                   locatorHint: .jellyfin(itemID: item.Id, mediaSourceID: source.Id))
        }
    }

    static func claimed(_ source: JellyfinItem.MediaSource) -> ClaimedFormat {
        let streams = source.MediaStreams ?? []
        let description = streams.compactMap { [$0.Codec, $0.DisplayTitle].compactMap { $0 }.joined(separator: " ") }.joined(separator: "\n")
        var format = ClaimedFormat.parse(name: source.Name, description: description, filename: nil)
        if let video = streams.first(where: { $0.Type == "Video" }) {
            if let height = video.Height {
                format.resolution = height >= 1800 ? .r2160 : height >= 900 ? .r1080 : height >= 600 ? .r720 : .r480
            }
            let range = (video.VideoRangeType ?? "").uppercased()
            format.hdr = []
            if range.contains("DOVI") { format.hdr.insert(.dolbyVision) }
            if range.contains("HDR10PLUS") { format.hdr.insert(.hdr10plus) }
            else if range.contains("HDR10") { format.hdr.insert(.hdr10) }
            if range.contains("HLG") { format.hdr.insert(.hlg) }
            switch (video.Codec ?? "").lowercased() {
            case "hevc", "h265": format.videoCodec = "HEVC"
            case "h264", "avc": format.videoCodec = "H.264"
            case "av1": format.videoCodec = "AV1"
            default: break
            }
        }
        return format
    }

    public func resolve(_ hint: LocatorHint) async throws -> PlaybackLocator {
        guard case .jellyfin(let itemID, let mediaSourceID) = hint else { throw SourceError.unsupported }
        // The token rides in the URL too because the player's byte source cannot add headers.
        return PlaybackLocator(url: client.streamURL(itemID: itemID, mediaSourceID: mediaSourceID),
                               headers: ["Authorization": client.authorizationValue])
    }

    /// Reports to the server's play session. `itemID` comes from the candidate's locator hint.
    public func reportPlayback(_ report: PlaybackReport, itemID: String, mediaSourceID: String?) async throws {
        let path: String
        switch report.phase {
        case .start: path = "/Sessions/Playing"
        case .progress, .pause: path = "/Sessions/Playing/Progress"
        case .stop: path = "/Sessions/Playing/Stopped"
        }
        try await client.report(path: path, itemID: itemID, mediaSourceID: mediaSourceID, positionSeconds: report.positionSeconds, sessionID: report.sessionID)
    }
}
