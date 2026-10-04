import Foundation
import PlayerCore

enum Fixtures {
    static func url(_ name: String) -> URL {
        let file = name as NSString
        guard let url = Bundle.module.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension,
                                          subdirectory: "Fixtures") else {
            fatalError("Missing fixture \(name); run scripts/make-player-fixtures.sh")
        }
        return url
    }

    static func data(_ name: String) -> Data {
        (try? Data(contentsOf: url(name))) ?? Data()
    }
}

/// Serves one fixture file over 127.0.0.1 the way a debrid CDN would: with or without Range support.
final class FixtureServer: @unchecked Sendable {
    private var server: TinyHTTPServer?

    func start(_ name: String, honorRange: Bool = true) async throws -> URL {
        let body = Fixtures.data(name)
        let server = TinyHTTPServer(bind: .loopback) { head in
            guard honorRange, let range = head.headers["range"], let bounds = Self.parse(range, length: body.count) else {
                return HTTPResponse(status: 200, contentType: "application/octet-stream", body: body)
            }
            return HTTPResponse(status: 206, contentType: "application/octet-stream",
                                body: body.subdata(in: bounds.lowerBound..<bounds.upperBound + 1),
                                headers: ["Content-Range": "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(body.count)",
                                          "Accept-Ranges": "bytes"])
        }
        self.server = server
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/media/\(name)")!
    }

    func stop() { server?.stop() }

    static func parse(_ header: String, length: Int) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start < length else { return nil }
        let end = Int(parts[1]).map { min($0, length - 1) } ?? length - 1
        return start...end
    }
}

func get(_ url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
}

extension Data {
    func contains(fourCC: String) -> Bool { range(of: Data(fourCC.utf8)) != nil }
}
