import Foundation
import Network

public enum Rendition: Hashable, Sendable {
    case video
    case audio(Int)
}

/// Every path Engine A's localhost server answers. Anything else is a 404.
public enum LocalRoute: Hashable, Sendable {
    case master
    case mediaPlaylist(Rendition)
    case initSegment(Rendition)
    case segment(Rendition, Int)
    case subtitlePlaylist(Int)
    case subtitleSegment(Int, Int)
    case thumbnailPlaylist
    case thumbnailSheet(Int)

    public init?(path: String, token: String) {
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        guard pathOnly.hasPrefix("/") else { return nil }
        let parts = pathOnly.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == token else { return nil }
        let rest = Array(parts.dropFirst())

        func number(_ name: String, suffix: String) -> Int? {
            guard name.hasSuffix(suffix) else { return nil }
            let digits = name.dropLast(suffix.count)
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
            return Int(digits)
        }

        switch rest.count {
        case 1 where rest[0] == "master.m3u8":
            self = .master
        case 2 where rest[0] == "v":
            if rest[1] == "index.m3u8" { self = .mediaPlaylist(.video) }
            else if rest[1] == "init.mp4" { self = .initSegment(.video) }
            else if let n = number(rest[1], suffix: ".m4s") { self = .segment(.video, n) }
            else { return nil }
        case 3 where rest[0] == "a":
            guard let id = Int(rest[1]), id >= 0 else { return nil }
            if rest[2] == "index.m3u8" { self = .mediaPlaylist(.audio(id)) }
            else if rest[2] == "init.mp4" { self = .initSegment(.audio(id)) }
            else if let n = number(rest[2], suffix: ".m4s") { self = .segment(.audio(id), n) }
            else { return nil }
        case 2 where rest[0] == "t":
            if rest[1] == "index.m3u8" { self = .thumbnailPlaylist }
            else if let n = number(rest[1], suffix: ".jpg") { self = .thumbnailSheet(n) }
            else { return nil }
        case 3 where rest[0] == "s":
            guard let id = Int(rest[1]), id >= 0 else { return nil }
            if rest[2] == "index.m3u8" { self = .subtitlePlaylist(id) }
            else if let n = number(rest[2], suffix: ".vtt") { self = .subtitleSegment(id, n) }
            else { return nil }
        default:
            return nil
        }
    }
}

public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Lowercased header names.
    public var headers: [String: String]
    /// Bytes consumed, including the blank line.
    public var byteCount: Int

    public static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequestHead(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                               byteCount: end.upperBound - data.startIndex)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
    }

    public func serialized() -> Data {
        let reason = switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 404: "Not Found"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A small HTTP/1.1 GET server on Network.framework. Used for Engine A's 127.0.0.1 HLS session and the
/// P0 harness results endpoint. One request at a time per connection; keep-alive supported.
public final class TinyHTTPServer: @unchecked Sendable {
    public enum Bind: Sendable {
        case loopback
        case allInterfaces(port: UInt16)
    }

    public typealias Handler = @Sendable (HTTPRequestHead) async -> HTTPResponse

    private let bind: Bind
    private let handler: Handler
    private let queue = DispatchQueue(label: "lanterna.http")
    private var listener: NWListener?

    public init(bind: Bind, handler: @escaping Handler) {
        self.bind = bind
        self.handler = handler
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        switch bind {
        case .loopback:
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        case .allInterfaces(let port):
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let head = HTTPRequestHead.parse(buffer) {
                let remainder = buffer.dropFirst(head.byteCount)
                let handler = self.handler
                Task {
                    let response = head.method == "GET" || head.method == "HEAD"
                        ? await handler(head)
                        : HTTPResponse(status: 405, contentType: "text/plain", body: Data())
                    var bytes = response.serialized()
                    if head.method == "HEAD" { bytes = bytes.prefix(bytes.count - response.body.count) }
                    connection.send(content: bytes, completion: .contentProcessed { [weak self] sendError in
                        if sendError != nil || head.headers["connection"]?.lowercased() == "close" {
                            connection.cancel()
                        } else {
                            self?.receive(on: connection, buffer: Data(remainder))
                        }
                    })
                }
                return
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
