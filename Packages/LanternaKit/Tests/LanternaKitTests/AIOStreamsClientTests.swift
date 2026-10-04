import Foundation
import Testing
@testable import LanternaKit

/// Stremio addon protocol: https://github.com/Stremio/stremio-addon-sdk (manifest.json, /stream/{type}/{id}.json).
struct AIOStreamsClientTests {
    static let manifest = URL(string: "https://aio.example.com/stremio/UUID/ENCRYPTEDCONFIG/manifest.json")!

    private struct Recorder: HTTPTransport {
        let body: String
        let status: Int
        let seen: Seen

        final class Seen: @unchecked Sendable { var url: URL? }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            seen.url = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func rejectsURLsThatAreNotAManifest() {
        #expect(AIOStreamsClient(manifestURL: URL(string: "https://aio.example.com/stremio/x")!) == nil)
        #expect(AIOStreamsClient(manifestURL: URL(string: "ftp://aio.example.com/manifest.json")!) == nil)
        #expect(AIOStreamsClient(manifestURL: Self.manifest) != nil)
    }

    @Test func streamRequestIsBuiltFromTheManifestBase() throws {
        let client = try #require(AIOStreamsClient(manifestURL: Self.manifest))
        #expect(client.streamURL(type: "movie", id: "tt0133093").absoluteString
                == "https://aio.example.com/stremio/UUID/ENCRYPTEDCONFIG/stream/movie/tt0133093.json")
        #expect(client.streamURL(type: "series", id: "tt0903747:1:2").path.hasSuffix("/stream/series/tt0903747:1:2.json"))
    }

    @Test func decodesStreamsAndSkipsTorrentOnlyEntries() async throws {
        let json = """
        {"streams": [
          {"name": "TorBox ⚡ 4K", "description": "Movie.2160p.DV.mkv\\n12.3 GB",
           "url": "https://cdn.example.com/dl/abc?token=SECRET",
           "behaviorHints": {"filename": "Movie.2160p.DV.mkv", "videoSize": 13200000000}},
          {"name": "P2P", "infoHash": "abcdef", "fileIdx": 1},
          {"name": "Plain", "url": "https://cdn.example.com/x.mp4"}
        ]}
        """
        let seen = Recorder.Seen()
        let client = try #require(AIOStreamsClient(manifestURL: Self.manifest, transport: Recorder(body: json, status: 200, seen: seen)))
        let streams = try await client.streams(type: "movie", id: "tt0133093")
        #expect(streams.count == 2)
        #expect(streams[0].filename == "Movie.2160p.DV.mkv")
        #expect(streams[0].videoSize == 13_200_000_000)
        #expect(streams[0].summary.contains("TorBox"))
        #expect(streams[1].filename == nil)
        #expect(seen.url?.path.hasSuffix("/stream/movie/tt0133093.json") == true)
    }

    @Test func httpErrorsSurface() async throws {
        let client = try #require(AIOStreamsClient(manifestURL: Self.manifest, transport: Recorder(body: "nope", status: 500, seen: .init())))
        await #expect(throws: AIOStreamsError.http(status: 500)) { try await client.streams(type: "movie", id: "tt1") }
    }

    @Test func manifestDecodesNameAndVersion() async throws {
        let body = #"{"id": "aio", "name": "AIOStreams", "version": "2.1.0", "resources": ["stream"]}"#
        let client = try #require(AIOStreamsClient(manifestURL: Self.manifest, transport: Recorder(body: body, status: 200, seen: .init())))
        let manifest = try await client.manifest()
        #expect(manifest.name == "AIOStreams")
        #expect(manifest.version == "2.1.0")
    }
}
