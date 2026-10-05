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

struct LocalFileServerTests {
    @Test func rangeParsing() {
        #expect(LocalFileServer.parseRange("bytes=0-0", size: 100) == 0...0)
        #expect(LocalFileServer.parseRange("bytes=10-", size: 100) == 10...99)
        #expect(LocalFileServer.parseRange("bytes=-20", size: 100) == 80...99)
        #expect(LocalFileServer.parseRange("bytes=90-500", size: 100) == 90...99)
        #expect(LocalFileServer.parseRange("bytes=100-", size: 100) == nil)
        #expect(LocalFileServer.parseRange(nil, size: 100) == 0...99)
        let big: Int64 = 1 << 33
        #expect(LocalFileServer.parseRange("bytes=0-", size: big) == 0...(LocalFileServer.maxChunk - 1))
    }

    @Test func servesRangesOfAFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lfs-\(UUID().uuidString).bin")
        try Data((0..<255).map(UInt8.init)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = LocalFileServer(file: url)
        let served = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: served)
        request.setValue("bytes=5-9", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 5-9/255")
        #expect(Array(data) == [5, 6, 7, 8, 9])
        var wrong = URLRequest(url: URL(string: served.absoluteString.replacingOccurrences(of: served.pathComponents[1], with: "nope"))!)
        wrong.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (_, missing) = try await URLSession.shared.data(for: wrong)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }
}
