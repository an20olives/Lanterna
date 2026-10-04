import AVFoundation
import Foundation
import Testing
@testable import EngineA
import PlayerCore

/// End to end: fixture over HTTP with Range -> probe -> route -> localhost HLS -> fetch like AVPlayer would.
final class Harness: @unchecked Sendable {
    let server = FixtureServer()
    var session: RemuxSession?

    func start(_ name: String, target: AudioTranscodeTarget = .alac) async throws -> URL {
        let url = try await server.start(name)
        let source = try await RemoteByteSource.open(url)
        let result = try await FFmpegProber.probe(source)
        let context = RoutingContext(
            preferences: PlayerPreferences(audioLanguages: ["eng"], subtitleLanguages: ["eng"],
                                           subtitlesEnabled: false, showForcedSubtitles: true),
            hardware: HardwareCapabilities(av1HardwareDecode: false), transcodeTarget: target, forcedEngine: .aRemux)
        let decision = DefaultRoutingPolicy().decide(result.probe, context: context)
        let session = try RemuxSession(source: source, probe: result, decision: decision)
        self.session = session
        return try await session.start()
    }

    func stop() {
        session?.stop()
        server.stop()
    }
}

func relative(_ master: URL, _ path: String) -> URL {
    master.deletingLastPathComponent().appending(path: path)
}

func segmentCount(_ playlist: String, ext: String) -> Int {
    playlist.split(separator: "\n").filter { $0.hasSuffix(".\(ext)") }.count
}

func trunSampleCount(_ fragment: Data) throws -> Int {
    let trun = try #require(try MP4Box.find(path: ["moof", "traf", "trun"], in: fragment))
    return Int(trun.payload.readUInt32(at: 4))
}

func tfdt(_ fragment: Data) throws -> UInt64 {
    let box = try #require(try MP4Box.find(path: ["moof", "traf", "tfdt"], in: fragment))
    return box.payload.readUInt64(at: 4)
}

@Suite(.serialized)
struct RemuxSessionTests {
    @Test func masterPlaylistDescribesEveryRendition() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = String(decoding: try await get(try await harness.start("hevc10-ac3-srt.mkv")), as: UTF8.self)
        #expect(master.contains(#"CODECS="hvc1.2.4.L"#))
        #expect(master.contains(#"TYPE=AUDIO,GROUP-ID="aud""#))
        #expect(master.contains(#"CHANNELS="6""#))
        #expect(master.contains("ac-3"))
        #expect(master.contains(#"TYPE=SUBTITLES"#))
        #expect(master.contains("RESOLUTION=320x180"))
        #expect(master.contains("VIDEO-RANGE=SDR"))
    }

    @Test func videoInitIsHvc1AndSegmentsCoverEveryFrameWithAbsoluteTfdt() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("hevc10-ac3-srt.mkv")
        let initSegment = try await get(relative(master, "v/init.mp4"))
        #expect(try MP4Box.parse(initSegment).map(\.type) == ["ftyp", "moov"])
        #expect(initSegment.contains(fourCC: "hvc1"))
        let timescale = try MP4Box.mediaTimescale(initSegment: initSegment)

        let playlist = String(decoding: try await get(relative(master, "v/index.m3u8")), as: UTF8.self)
        let count = segmentCount(playlist, ext: "m4s")
        #expect(count == 2)
        var frames = 0
        var previousEnd: UInt64 = 0
        for n in 0..<count {
            let fragment = try await get(relative(master, "v/\(n).m4s"))
            frames += try trunSampleCount(fragment)
            let start = try tfdt(fragment)
            if n > 0 { #expect(start == previousEnd) }
            let trun = try #require(try MP4Box.find(path: ["moof", "traf", "trun"], in: fragment))
            var duration: UInt64 = 0
            for i in 0..<Int(trun.payload.readUInt32(at: 4)) { duration += UInt64(trun.payload.readUInt32(at: 12 + i * 16)) }
            previousEnd = start + duration
        }
        #expect(frames == 288)
        #expect(Double(previousEnd) / Double(timescale) > 11.9)
    }

    @Test func outOfOrderSegmentIsIdenticalToSequentialOne() async throws {
        let first = Harness()
        let masterA = try await first.start("h264-dts-ass.mkv")
        let late = try await get(relative(masterA, "v/1.m4s"))
        first.stop()

        let second = Harness()
        defer { second.stop() }
        let masterB = try await second.start("h264-dts-ass.mkv")
        _ = try await get(relative(masterB, "v/0.m4s"))
        let sequential = try await get(relative(masterB, "v/1.m4s"))
        #expect(late == sequential)
    }

    @Test func dtsIsTranscodedToALAC() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("h264-dts-ass.mkv")
        let masterText = String(decoding: try await get(master), as: UTF8.self)
        #expect(masterText.contains("alac"))
        let initSegment = try await get(relative(master, "a/1/init.mp4"))
        #expect(initSegment.contains(fourCC: "alac"))
        let timescale = try MP4Box.mediaTimescale(initSegment: initSegment)
        #expect(timescale == 48_000)

        let playlist = String(decoding: try await get(relative(master, "a/1/index.m3u8")), as: UTF8.self)
        var samples: UInt64 = 0
        for n in 0..<segmentCount(playlist, ext: "m4s") {
            let fragment = try await get(relative(master, "a/1/\(n).m4s"))
            let trun = try #require(try MP4Box.find(path: ["moof", "traf", "trun"], in: fragment))
            for i in 0..<Int(trun.payload.readUInt32(at: 4)) { samples += UInt64(trun.payload.readUInt32(at: 12 + i * 16)) }
        }
        #expect(abs(Double(samples) / 48_000 - 12) < 0.2)
    }

    @Test func trueHDIsTranscodedAndEAC3IsCopied() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("hevc-truehd-eac3.mkv")
        #expect(try await get(relative(master, "a/1/init.mp4")).contains(fourCC: "alac"))
        let eac3Init = try await get(relative(master, "a/2/init.mp4"))
        #expect(eac3Init.contains(fourCC: "ec-3"))
        #expect(eac3Init.contains(fourCC: "dec3"))
        #expect(try await get(relative(master, "a/2/0.m4s")).count > 1000)
    }

    @Test func aacFallbackTargetWorks() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("h264-dts-ass.mkv", target: .aac51)
        #expect(try await get(relative(master, "a/1/init.mp4")).contains(fourCC: "mp4a"))
        #expect(try await get(relative(master, "a/1/0.m4s")).count > 1000)
    }

    @Test func srtBecomesSegmentedWebVTT() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("hevc10-ac3-srt.mkv")
        let first = String(decoding: try await get(relative(master, "s/2/0.vtt")), as: UTF8.self)
        #expect(first.hasPrefix("WEBVTT"))
        #expect(first.contains("<i>Hello</i> from Lanterna"))
        let second = String(decoding: try await get(relative(master, "s/2/1.vtt")), as: UTF8.self)
        #expect(second.contains("Second cue &amp; more"))
    }

    @Test func assBecomesWebVTT() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("h264-dts-ass.mkv")
        let vtt = String(decoding: try await get(relative(master, "s/2/0.vtt")), as: UTF8.self)
        #expect(vtt.contains("<i>Styled</i> line\nsecond row"))
    }

    @Test func unknownPathsAre404() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("h264-dts-ass.mkv")
        let wrongToken = URL(string: "http://127.0.0.1:\(master.port!)/nottoken/master.m3u8")!
        let (_, response) = try await URLSession.shared.data(from: wrongToken)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func avFoundationLoadsTheSessionDuration() async throws {
        let harness = Harness()
        defer { harness.stop() }
        let master = try await harness.start("h264-dts-ass.mkv")
        let asset = AVURLAsset(url: master)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 12) < 0.5)
        #expect(try await asset.load(.isPlayable))
    }
}

@Suite(.serialized)
struct DolbyVisionInitTests {
    func videoParameters() async throws -> (CodecParameters, FixtureServer) {
        let server = FixtureServer()
        let url = try await server.start("hevc10-ac3-srt.mkv")
        let source = try await RemoteByteSource.open(url)
        let params = try await FFmpegProber.videoParameters(source)
        return (params, server)
    }

    @Test func profile8KeepsDvvCOnHvc1() async throws {
        let (params, server) = try await videoParameters()
        defer { server.stop() }
        params.attachDolbyVision(profile: 8, level: 6, compatibilityID: 1)
        let initSegment = try InitSegmentBuilder.video(params, treatment: .dolbyVision(profile: 8))
        #expect(initSegment.contains(fourCC: "hvc1"))
        #expect(initSegment.contains(fourCC: "dvvC"))
    }

    @Test func profile5UsesDvh1AndDvcC() async throws {
        let (params, server) = try await videoParameters()
        defer { server.stop() }
        params.attachDolbyVision(profile: 5, level: 6, compatibilityID: 0)
        let initSegment = try InitSegmentBuilder.video(params, treatment: .dolbyVision(profile: 5))
        #expect(initSegment.contains(fourCC: "dvh1"))
        #expect(initSegment.contains(fourCC: "dvcC"))
    }

    @Test func stripRemovesTheConfigurationRecord() async throws {
        let (params, server) = try await videoParameters()
        defer { server.stop() }
        params.attachDolbyVision(profile: 7, level: 6, compatibilityID: 6)
        let initSegment = try InitSegmentBuilder.video(params, treatment: .stripDolbyVision)
        #expect(!initSegment.contains(fourCC: "dvcC"))
        #expect(!initSegment.contains(fourCC: "dvvC"))
        #expect(initSegment.contains(fourCC: "hvc1"))
    }
}
