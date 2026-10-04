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

/// TorBox API v1 (https://api-docs.torbox.app). The key lives in Keychain; this type only holds it in memory.
public struct TorBoxClient: Sendable {
    public static let baseURL = URL(string: "https://api.torbox.app/v1/api")!

    let apiKey: String
    let transport: any HTTPTransport

    public init(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
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
