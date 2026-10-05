import Foundation

/// Serves one local file over 127.0.0.1 with Range support, so downloaded files go through the same
/// byte-source and remux path as remote streams. Each response is capped so a 30 GB file is never held in memory.
public final class LocalFileServer: @unchecked Sendable {
    public static let maxChunk: Int64 = 8 << 20

    let file: URL
    let token: String
    private var server: TinyHTTPServer?

    public init(file: URL) {
        self.file = file
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func start() async throws -> URL {
        let server = TinyHTTPServer(bind: .loopback) { [weak self] head in await self?.respond(head) ?? .notFound() }
        let port = try await server.start()
        self.server = server
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(file.pathExtension.isEmpty ? "file" : "file." + file.pathExtension)")!
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    /// `bytes=a-b`, `bytes=a-` and `bytes=-n`, clamped to the file and to `maxChunk`. Nil when unsatisfiable.
    public static func parseRange(_ header: String?, size: Int64) -> ClosedRange<Int64>? {
        guard size > 0 else { return nil }
        guard let header, header.hasPrefix("bytes=") else { return 0...min(size - 1, maxChunk - 1) }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        var start: Int64
        var end: Int64
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            start = max(size - suffix, 0)
            end = size - 1
        } else {
            guard let s = Int64(parts[0]), s < size else { return nil }
            start = s
            end = Int64(parts[1]) ?? (size - 1)
        }
        end = min(end, size - 1, start + maxChunk - 1)
        return start <= end ? start...end : nil
    }

    private func respond(_ head: HTTPRequestHead) async -> HTTPResponse {
        let parts = head.path.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        guard parts.first == token, let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else { return .notFound() }
        guard let range = Self.parseRange(head.headers["range"], size: size) else {
            return HTTPResponse(status: 416, contentType: "text/plain", body: Data(), headers: ["Content-Range": "bytes */\(size)"])
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .notFound() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let body = try handle.read(upToCount: Int(range.count)) ?? Data()
            return HTTPResponse(status: 206, contentType: "application/octet-stream", body: body,
                                headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.lowerBound + Int64(body.count) - 1)/\(size)", "Accept-Ranges": "bytes"])
        } catch {
            return HTTPResponse(status: 500, contentType: "text/plain", body: Data())
        }
    }
}
