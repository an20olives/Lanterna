import Foundation

public enum AIOStreamsError: Error, Equatable {
    case http(status: Int)
    case malformedResponse
}

public struct StremioManifest: Sendable, Codable, Equatable {
    public let id: String?
    public let name: String
    public let version: String?
}

/// One playable entry from a Stremio addon `/stream` response. The URL is a short-lived credential:
/// keep it in memory, never log or persist it.
public struct StremioStream: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let name: String?
    public let description: String?
    public let url: URL
    public let filename: String?
    public let videoSize: Int64?

    public init(name: String?, description: String?, url: URL, filename: String?, videoSize: Int64?) {
        self.name = name
        self.description = description
        self.url = url
        self.filename = filename
        self.videoSize = videoSize
    }

    /// First lines of name and description for pickers. Contains no URL.
    public var summary: String {
        let head = (name ?? "Stream").replacingOccurrences(of: "\n", with: " ")
        let detail = (description ?? "").split(separator: "\n").prefix(2).joined(separator: " | ")
        return detail.isEmpty ? head : "\(head): \(detail)"
    }

    public var title: String { filename ?? name ?? "Stream" }
}

/// Stremio addon protocol client for one AIOStreams manifest URL. The manifest URL embeds the encrypted
/// config (including the debrid key), so it is a secret: Keychain only, redacted in logs.
public struct AIOStreamsClient: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport
    let manifestURL: URL

    public init?(manifestURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        guard let scheme = manifestURL.scheme, scheme == "https" || scheme == "http",
              manifestURL.lastPathComponent == "manifest.json" else { return nil }
        self.manifestURL = manifestURL
        self.baseURL = manifestURL.deletingLastPathComponent()
        self.transport = transport
    }

    public func manifest() async throws -> StremioManifest {
        let (data, response) = try await transport.data(for: URLRequest(url: manifestURL))
        try Self.check(response)
        guard let manifest = try? JSONDecoder().decode(StremioManifest.self, from: data) else { throw AIOStreamsError.malformedResponse }
        return manifest
    }

    /// - Parameters:
    ///   - type: `movie` or `series`.
    ///   - id: IMDb ID, or `tt…:season:episode` for series.
    public func streams(type: String, id: String) async throws -> [StremioStream] {
        var request = URLRequest(url: streamURL(type: type, id: id))
        request.timeoutInterval = 60
        let (data, response) = try await transport.data(for: request)
        try Self.check(response)
        return try Self.decodeStreams(data)
    }

    func streamURL(type: String, id: String) -> URL {
        baseURL.appending(path: "stream/\(type)/\(id).json")
    }

    private struct Envelope: Decodable {
        struct Entry: Decodable {
            struct Hints: Decodable {
                let filename: String?
                let videoSize: Int64?
            }
            let name: String?
            let description: String?
            let title: String?
            let url: String?
            let behaviorHints: Hints?
        }
        let streams: [Entry]
    }

    static func decodeStreams(_ data: Data) throws -> [StremioStream] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw AIOStreamsError.malformedResponse }
        // Entries with only an infoHash need a torrent client; the debrid ones carry a URL.
        return envelope.streams.compactMap { entry in
            guard let string = entry.url, let url = URL(string: string) else { return nil }
            return StremioStream(name: entry.name, description: entry.description ?? entry.title, url: url,
                                 filename: entry.behaviorHints?.filename, videoSize: entry.behaviorHints?.videoSize)
        }
    }

    private static func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw AIOStreamsError.http(status: response.statusCode) }
    }
}
