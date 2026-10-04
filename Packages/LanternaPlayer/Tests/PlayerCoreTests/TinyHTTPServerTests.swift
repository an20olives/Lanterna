import Foundation
import Testing
@testable import PlayerCore

struct TinyHTTPServerTests {
    @Test func servesHandlerResponsesOverLoopbackWithKeepAlive() async throws {
        let server = TinyHTTPServer(bind: .loopback) { head in
            head.path == "/hello"
                ? HTTPResponse(status: 200, contentType: "text/plain", body: Data("hi".utf8))
                : HTTPResponse(status: 404, contentType: "text/plain", body: Data())
        }
        let port = try await server.start()
        defer { server.stop() }

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/hello")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hi")

        // Second request on the same session reuses the connection.
        let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }
}
