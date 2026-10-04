import Foundation
import os
@testable import LanternaKit

/// Routes requests to a closure and records them. Fixtures are hand-written from each service's public docs
/// (no live keys were available); replace with scrubbed recordings when they exist.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: [URLRequest]())
    private let handler: @Sendable (URLRequest) -> Reply

    init(_ handler: @escaping @Sendable (URLRequest) -> Reply) { self.handler = handler }

    var requests: [URLRequest] { state.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.append(request) }
        let reply = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    /// Replies by URL path (and optionally query) substring; first match wins.
    static func routes(_ table: [(match: String, body: String)]) -> ScriptedTransport {
        ScriptedTransport { request in
            let url = request.url?.absoluteString ?? ""
            if let hit = table.first(where: { url.contains($0.match) }) { return Reply(body: hit.body) }
            return Reply(status: 404, body: "{}")
        }
    }
}
