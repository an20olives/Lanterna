import Foundation

public enum TorBoxKind: String, Sendable, CaseIterable, Codable {
    case torrents, usenet, webDownloads

    var pathComponent: String {
        switch self {
        case .torrents: "torrents"
        case .usenet: "usenet"
        case .webDownloads: "webdl"
        }
    }

    var idParameter: String {
        switch self {
        case .torrents: "torrent_id"
        case .usenet: "usenet_id"
        case .webDownloads: "web_id"
        }
    }
}

public enum TorBoxError: Error, Equatable {
    case api(code: String, detail: String)
    case http(status: Int)
    case malformedResponse
}

public struct TorBoxFile: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let name: String
    public let shortName: String?
    public let size: Int64?
    public let mimetype: String?

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm"]

    public var isVideo: Bool {
        if let mimetype, mimetype.hasPrefix("video/") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.videoExtensions.contains(ext)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, size, mimetype
        case shortName = "short_name"
    }
}

public struct TorBoxItem: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let name: String
    public let size: Int64?
    public let downloadState: String?
    public let downloadFinished: Bool?
    public let cached: Bool?
    public let files: [TorBoxFile]?
    public var kind: TorBoxKind = .torrents

    public var isReady: Bool { downloadFinished == true || cached == true }
    public var videoFiles: [TorBoxFile] { (files ?? []).filter(\.isVideo) }

    enum CodingKeys: String, CodingKey {
        case id, name, size, cached, files
        case downloadState = "download_state"
        case downloadFinished = "download_finished"
    }
}

/// What TorBox says about the account behind a key. The email is never read.
public struct TorBoxAccountStatus: Sendable, Equatable {
    public var plan: Int
    public var premiumExpires: Date?
    public var isSubscribed: Bool

    public init(plan: Int, premiumExpires: Date?, isSubscribed: Bool) {
        self.plan = plan
        self.premiumExpires = premiumExpires
        self.isSubscribed = isSubscribed
    }

    public var planName: String {
        switch plan {
        case 0: "Free"
        case 1: "Essential"
        case 2: "Pro"
        case 3: "Standard"
        default: "Plan \(plan)"
        }
    }

    public func isPremium(now: Date = Date()) -> Bool {
        guard plan > 0 else { return false }
        if let premiumExpires { return premiumExpires > now }
        return isSubscribed
    }

    public var isPremium: Bool { isPremium() }

    public func summary(now: Date = Date()) -> String {
        if plan == 0 { return "Free plan. TorBox will not serve downloads on a free plan." }
        if let premiumExpires, premiumExpires <= now { return "\(planName) plan expired on \(premiumExpires.formatted(date: .abbreviated, time: .omitted))." }
        if let premiumExpires { return "\(planName) plan, active until \(premiumExpires.formatted(date: .abbreviated, time: .omitted))." }
        return isSubscribed ? "\(planName) plan, subscribed." : "\(planName) plan, but not subscribed."
    }
}

/// TorBox API v1 (https://api-docs.torbox.app). The key lives in Keychain; this type only holds it in memory.
public struct TorBoxClient: Sendable {
    public static let baseURL = URL(string: "https://api.torbox.app/v1/api")!

    let apiKey: String
    let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    /// GET /user/me: plan and expiry for the account that owns this key.
    public func account() async throws -> TorBoxAccountStatus {
        struct DTO: Decodable {
            struct User: Decodable { let plan: Int?; let premium_expires_at: String?; let is_subscribed: Bool? }
            let success: Bool; let error: String?; let data: User?
        }
        var request = URLRequest(url: Self.baseURL.appending(path: "user/me"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw TorBoxError.api(code: "BAD_TOKEN", detail: "TorBox rejected this key") }
            throw TorBoxError.http(status: response.statusCode)
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data), dto.success, let user = dto.data else { throw TorBoxError.malformedResponse }
        let expires = user.premium_expires_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return TorBoxAccountStatus(plan: user.plan ?? 0, premiumExpires: expires, isSubscribed: user.is_subscribed ?? false)
    }

    public func list(_ kind: TorBoxKind) async throws -> [TorBoxItem] {
        let (data, response) = try await transport.data(for: listRequest(kind))
        try Self.check(response, data: data)
        return try Self.decodeList(data, kind: kind)
    }

    /// Returns a CDN link valid for roughly three hours. Treat it as a secret: never persist or log it.
    public func downloadLink(kind: TorBoxKind, itemID: Int, fileID: Int) async throws -> URL {
        let (data, response) = try await transport.data(for: downloadLinkRequest(kind: kind, itemID: itemID, fileID: fileID))
        try Self.check(response, data: data)
        return try Self.decodeLink(data)
    }

    func listRequest(_ kind: TorBoxKind) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: "\(kind.pathComponent)/mylist"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func downloadLinkRequest(kind: TorBoxKind, itemID: Int, fileID: Int) -> URLRequest {
        // requestdl only accepts the key as the `token` query parameter (per TorBox docs).
        let url = Self.baseURL.appending(path: "\(kind.pathComponent)/requestdl").appending(queryItems: [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: kind.idParameter, value: String(itemID)),
            URLQueryItem(name: "file_id", value: String(fileID)),
        ])
        return URLRequest(url: url)
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let success: Bool
        let error: String?
        let detail: String?
        let data: Payload?
    }

    static func decodeList(_ data: Data, kind: TorBoxKind) throws -> [TorBoxItem] {
        let envelope = try JSONDecoder().decode(Envelope<[TorBoxItem]>.self, from: data)
        guard envelope.success else {
            throw TorBoxError.api(code: envelope.error ?? "UNKNOWN", detail: envelope.detail ?? "")
        }
        return (envelope.data ?? []).map { item in
            var item = item
            item.kind = kind
            return item
        }
    }

    static func decodeLink(_ data: Data) throws -> URL {
        let envelope = try JSONDecoder().decode(Envelope<String>.self, from: data)
        guard envelope.success else {
            throw TorBoxError.api(code: envelope.error ?? "UNKNOWN", detail: envelope.detail ?? "")
        }
        guard let string = envelope.data, let url = URL(string: string) else { throw TorBoxError.malformedResponse }
        return url
    }

    private static func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            if let envelope = try? JSONDecoder().decode(Envelope<String>.self, from: data), let code = envelope.error {
                throw TorBoxError.api(code: code, detail: envelope.detail ?? "")
            }
            throw TorBoxError.http(status: response.statusCode)
        }
    }
}
