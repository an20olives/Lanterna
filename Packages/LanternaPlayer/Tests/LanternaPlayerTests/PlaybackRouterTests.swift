import Foundation
import Testing
@testable import LanternaPlayer
import PlayerCore

/// Router decisions end to end over a local HTTP server (fixtures shared with EngineATests).
@Suite(.serialized)
struct PlaybackRouterTests {
    let context = RoutingContext(
        preferences: PlayerPreferences(audioLanguages: ["eng"], subtitleLanguages: ["eng"],
                                       subtitlesEnabled: false, showForcedSubtitles: true),
        hardware: HardwareCapabilities(av1HardwareDecode: false), transcodeTarget: .alac)

    func serve(_ name: String) async throws -> (URL, TinyHTTPServer) {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        let body = try Data(contentsOf: url)
        let server = TinyHTTPServer(bind: .loopback) { head in
            guard let range = head.headers["range"], range.hasPrefix("bytes=") else {
                return HTTPResponse(status: 200, contentType: "application/octet-stream", body: body)
            }
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts[0]) ?? 0
            let end = min(Int(parts[1]) ?? body.count - 1, body.count - 1)
            return HTTPResponse(status: 206, contentType: "application/octet-stream", body: body.subdata(in: start..<end + 1),
                                headers: ["Content-Range": "bytes \(start)-\(end)/\(body.count)"])
        }
        let port = try await server.start()
        return (URL(string: "http://127.0.0.1:\(port)/\(name)")!, server)
    }

    @Test func matroskaWithDTSIsRemuxedOnLocalhost() async throws {
        let (url, server) = try await serve("h264-dts-ass.mkv")
        defer { server.stop() }
        let prepared = try await PlaybackRouter().prepare(url: url, context: context)
        defer { prepared.remux?.stop() }
        #expect(prepared.decision.engine == .aRemux)
        #expect(prepared.playbackURL.host() == "127.0.0.1")
        #expect(prepared.playbackURL.lastPathComponent == "master.m3u8")
        #expect(prepared.record.probeSummary?.contains("DTS") == true)
    }

    @Test func mp4PlaysDirectFromTheSourceURL() async throws {
        let (url, server) = try await serve("h264-aac.mp4")
        defer { server.stop() }
        let prepared = try await PlaybackRouter().prepare(url: url, context: context)
        #expect(prepared.decision.engine == .aDirect)
        #expect(prepared.playbackURL == url)
        #expect(prepared.remux == nil)
    }

    @Test func matroskaWithoutCuesGoesToC() async throws {
        let (url, server) = try await serve("h264-nocues.mkv")
        defer { server.stop() }
        let prepared = try await PlaybackRouter().prepare(url: url, context: context)
        #expect(prepared.decision.engine == .c)
        #expect(prepared.decision.reasons.contains(.noSeekIndex))
        #expect(prepared.playbackURL == url)
    }

    @Test func unreachableSourceStillRoutesToCWithProbeFailed() async throws {
        let url = URL(string: "http://127.0.0.1:9/missing.mkv")!
        let prepared = try await PlaybackRouter().prepare(url: url, context: context)
        #expect(prepared.decision.engine == .c)
        #expect(prepared.decision.reasons == [.probeFailed])
    }

    @Test func routeRecordNeverContainsTheURL() async throws {
        let (url, server) = try await serve("h264-aac.mp4")
        defer { server.stop() }
        let prepared = try await PlaybackRouter().prepare(url: url, context: context)
        let json = String(decoding: try JSONEncoder().encode(prepared.record), as: UTF8.self)
        #expect(!json.contains("127.0.0.1"))
        #expect(!json.contains("h264-aac"))
    }
}
