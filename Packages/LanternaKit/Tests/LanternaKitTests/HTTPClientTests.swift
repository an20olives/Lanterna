import Foundation
import os
import Testing
@testable import LanternaKit

struct HTTPClientTests {
    final class Counter: Sendable {
        private let n = OSAllocatedUnfairLock(initialState: 0)
        func next() -> Int { n.withLock { $0 += 1; return $0 } }
    }

    private func client(_ transport: ScriptedTransport, retries: Int = 2) -> HTTPClient {
        HTTPClient(transport: transport, maxRetries: retries, sleep: { _ in })
    }

    @Test func retriesTransientServerErrors() async throws {
        let counter = Counter()
        let transport = ScriptedTransport { _ in
            counter.next() < 3 ? .init(status: 503) : .init(body: "ok")
        }
        let (data, response) = try await client(transport).send(URLRequest(url: URL(string: "https://api.example.com/x")!))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(transport.requests.count == 3)
    }

    @Test func givesUpAfterMaxRetries() async {
        let transport = ScriptedTransport { _ in .init(status: 502) }
        await #expect(throws: SourceError.http(status: 502)) {
            try await client(transport, retries: 1).send(URLRequest(url: URL(string: "https://api.example.com/x")!))
        }
        #expect(transport.requests.count == 2)
    }

    @Test func mapsStatusCodes() async {
        let url = URL(string: "https://api.example.com/x")!
        let limited = ScriptedTransport { _ in .init(status: 429, headers: ["Retry-After": "7"]) }
        await #expect(throws: SourceError.rateLimited(retryAfter: 7)) { try await client(limited).send(URLRequest(url: url)) }
        let unauthorized = ScriptedTransport { _ in .init(status: 401) }
        await #expect(throws: SourceError.needsCredentials) { try await client(unauthorized).send(URLRequest(url: url)) }
        let missing = ScriptedTransport { _ in .init(status: 404) }
        await #expect(throws: SourceError.notFound) { try await client(missing).send(URLRequest(url: url)) }
        #expect(limited.requests.count == 1)
    }

    @Test func networkFailuresBecomeUnreachable() async {
        struct Failing: HTTPTransport {
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        }
        let client = HTTPClient(transport: Failing(), maxRetries: 0, sleep: { _ in })
        do {
            _ = try await client.send(URLRequest(url: URL(string: "https://api.example.com/x")!))
            Issue.record("expected throw")
        } catch let error as SourceError {
            guard case .unreachable(let reason) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!reason.contains("api.example.com"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func decodesJSONAndFlagsMalformed() async throws {
        struct Box: Decodable, Equatable { let a: Int }
        let good = ScriptedTransport { _ in .init(body: #"{"a": 1}"#) }
        let value: Box = try await client(good).json(URLRequest(url: URL(string: "https://api.example.com/x")!))
        #expect(value == Box(a: 1))
        let bad = ScriptedTransport { _ in .init(body: "nope") }
        await #expect(throws: SourceError.malformedResponse) {
            let _: Box = try await client(bad).json(URLRequest(url: URL(string: "https://api.example.com/x")!))
        }
    }
}
