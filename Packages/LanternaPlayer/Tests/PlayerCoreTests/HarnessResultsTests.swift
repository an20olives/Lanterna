import Foundation
import Testing
@testable import PlayerCore

struct HarnessResultsTests {
    private func sampleRun(failure: String? = nil, notes: [String] = []) -> HarnessRun {
        var run = HarnessRun(fileName: "Movie.2160p.mkv", mode: .seekTest, requested: nil,
                             probeSummary: "mkv hevc 4K", probe: nil,
                             decision: RoutingDecision(engine: .aRemux, reasons: [.audioTranscodeTrueHD]),
                             enginePlayed: .aRemux, prepareMillis: 900)
        run.ttffMillis = 1800
        run.failure = failure
        run.notes = notes
        run.recordSeeks(latencies: [400, 900, 1200, 300, 2500, 700, 650, 800, 1100, 5000], timeouts: 0)
        run.peakMemoryMB = 412.5
        run.diagnostics = PlaybackDiagnostics(droppedFrames: 3, stalls: 1, observedBitrate: 1_000, extra: ["segments": "12"])
        var observations = HarnessObservations()
        observations.notes = "looked fine"
        run.observations = observations
        return run
    }

    @Test func seekPlanIsSeededAndInRange() {
        let a = SeekPlan.fractions()
        let b = SeekPlan.fractions()
        #expect(a == b)
        #expect(a.count == 10)
        #expect(a.allSatisfy { $0 >= 0.05 && $0 <= 0.90 })
        #expect(SeekPlan.fractions(seed: 1) != SeekPlan.fractions(seed: 2))
        let positions = SeekPlan.positions(duration: 7200)
        #expect(positions == a.map { $0 * 7200 })
    }

    @Test func recordSeeksComputesMedianAndP90() {
        let run = sampleRun()
        // sorted: 300 400 650 700 800 900 1100 1200 2500 5000
        #expect(run.seekMedianMillis == 850)
        #expect(run.seekP90Millis == 2500)
        #expect(run.seekLatenciesMillis.count == 10)
    }

    @Test func recordSeeksWithNoSamplesLeavesStatsNil() {
        var run = sampleRun()
        run.recordSeeks(latencies: [], timeouts: 10)
        #expect(run.seekMedianMillis == nil)
        #expect(run.seekP90Millis == nil)
        #expect(run.seekTimeouts == 10)
    }

    @Test func exportRoundTripsAndIsSorted() throws {
        let run = sampleRun()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = HarnessExport.json(runs: [run], now: now, scrub: { $0 })
        let decoded = try HarnessExport.decode(data)
        #expect(decoded.runs.count == 1)
        #expect(decoded.runs[0].fileName == "Movie.2160p.mkv")
        #expect(decoded.runs[0].seekP90Millis == 2500)
        #expect(decoded.runs[0].decision.engine == .aRemux)
        #expect(decoded.generatedAt == now)
    }

    @Test func exportScrubsEveryFreeTextField() throws {
        var run = sampleRun(failure: "probe: SECRET failed", notes: ["note SECRET"])
        run.fileName = "SECRET.mkv"
        run.probeSummary = "SECRET summary"
        run.diagnostics?.extra["x"] = "SECRET"
        run.observations?.notes = "SECRET"
        let probe = StreamProbe(container: .matroska, durationSeconds: 10, seekIndex: .none, rangeSupported: true,
                                contentLength: 1, bitRate: 1, video: nil,
                                audio: [AudioTrackInfo(index: 1, codec: .aac, channels: 2, hasAtmos: false, language: "eng",
                                                       title: "SECRET", isDefault: true, isCommentary: false, isAudioDescription: false)],
                                subtitles: [SubtitleTrackInfo(index: 2, format: .srt, language: "eng", title: "SECRET", isForced: false, isDefault: false)],
                                chapters: [Chapter(start: 0, end: 1, title: "SECRET")], probeMillis: 5)
        run.probe = probe
        let data = HarnessExport.json(runs: [run], now: Date(), scrub: { $0.replacingOccurrences(of: "SECRET", with: "<redacted>") })
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SECRET"))
        #expect(text.contains("<redacted>"))
    }

    @Test func exportHasNoURLsWhenInputsHaveNone() {
        let data = HarnessExport.json(runs: [sampleRun()], now: Date(), scrub: { $0 })
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("http://"))
        #expect(!text.contains("https://"))
        #expect(!text.contains("token="))
    }
}
