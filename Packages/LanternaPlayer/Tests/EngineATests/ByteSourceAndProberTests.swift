import Foundation
import Testing
@testable import EngineA
import PlayerCore

@Suite(.serialized)
struct RemoteByteSourceTests {
    @Test func readsExactRangesAndKnowsTheLength() async throws {
        let server = FixtureServer()
        let url = try await server.start("hevc10-ac3-srt.mkv")
        defer { server.stop() }
        let expected = Fixtures.data("hevc10-ac3-srt.mkv")

        let source = try await RemoteByteSource.open(url, configuration: .init(blockSize: 64 * 1024, readAheadBlocks: 2))
        #expect(source.contentLength == Int64(expected.count))
        #expect(source.rangeSupported)
        let middle = try await source.readAsync(at: 100_000, count: 200_000)
        #expect(middle == expected.subdata(in: 100_000..<300_000))
        let tail = try await source.readAsync(at: Int64(expected.count - 10), count: 100)
        #expect(tail == expected.suffix(10))
    }

    @Test func reportsWhenTheServerIgnoresRange() async throws {
        let server = FixtureServer()
        let url = try await server.start("h264-aac.mp4", honorRange: false)
        defer { server.stop() }
        let source = try await RemoteByteSource.open(url, configuration: .init(blockSize: 64 * 1024, readAheadBlocks: 0))
        #expect(!source.rangeSupported)
    }
}

@Suite(.serialized)
struct ProberTests {
    func probe(_ name: String) async throws -> ProbeResult {
        let server = FixtureServer()
        let url = try await server.start(name)
        defer { server.stop() }
        let source = try await RemoteByteSource.open(url)
        return try await FFmpegProber.probe(source)
    }

    @Test func matroskaHEVC10WithAC3SRTAndChapters() async throws {
        let result = try await probe("hevc10-ac3-srt.mkv")
        let probe = result.probe
        #expect(probe.container == .matroska)
        #expect(probe.rangeSupported)
        #expect(abs((probe.durationSeconds ?? 0) - 12) < 0.2)
        let video = try #require(probe.video)
        #expect(video.codec == .hevc)
        #expect(video.profile == "Main 10")
        #expect(video.bitDepth == 10)
        #expect(video.width == 320 && video.height == 180)
        #expect(abs(video.frameRate.value - 23.976) < 0.01)
        #expect(video.dynamicRange == .sdr)
        #expect(probe.audio.map(\.codec) == [.ac3])
        #expect(probe.audio.first?.channels == 6)
        #expect(probe.audio.first?.language == "eng")
        #expect(probe.subtitles.map(\.format) == [.srt])
        #expect(probe.chapters.map(\.title) == ["Opening", "Ending"])
        guard case .keyframeIndex(let count) = probe.seekIndex else { Issue.record("expected a keyframe index"); return }
        #expect(count >= 5)
    }

    @Test func keyframeTimesFollowTheTwoSecondGOP() async throws {
        let times = try await probe("hevc10-ac3-srt.mkv").keyframeTimes
        #expect(times.count == 6)
        #expect(abs(times[1] - 2.002) < 0.01)
    }

    @Test func matroskaWrittenToAPipeHasNoSeekIndex() async throws {
        #expect(try await probe("h264-nocues.mkv").probe.seekIndex == .none)
    }

    @Test func mp4ControlCase() async throws {
        let probe = try await probe("h264-aac.mp4").probe
        #expect(probe.container == .mp4)
        #expect(probe.video?.codec == .h264)
        #expect(probe.audio.map(\.codec) == [.aac])
    }

    @Test func trueHDAndEAC3() async throws {
        #expect(try await probe("hevc-truehd-eac3.mkv").probe.audio.map(\.codec) == [.truehd, .eac3])
    }

    @Test func dtsAndASS() async throws {
        let probe = try await probe("h264-dts-ass.mkv").probe
        #expect(probe.audio.map(\.codec) == [.dts])
        #expect(probe.subtitles.map(\.format) == [.ass])
    }
}
