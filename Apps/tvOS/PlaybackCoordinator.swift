import Foundation
import LanternaKit
import LanternaPlayer
import PlayerCore
import UIKit

/// One play or seek-test run: prepare, present, watch events, reroute to C on failure, measure, tear down.
@MainActor
final class PlaybackCoordinator {
    struct Request {
        var url: URL
        var forced: EngineID?
        var seekTest: Bool
        var target: AudioTranscodeTarget
        var title: String
    }

    private enum Signal: Sendable {
        case event(PlaybackEvent, generation: Int)
        case imageSubtitle(track: Int, at: Double, generation: Int)
        case seekTestDone(generation: Int)
        case close
    }

    static let preferences = PlayerPreferences(audioLanguages: ["eng"], subtitleLanguages: ["eng"],
                                               subtitlesEnabled: false, showForcedSubtitles: true)

    private let router = PlaybackRouter()
    private let signals: AsyncStream<Signal>
    private let continuation: AsyncStream<Signal>.Continuation
    private var run: HarnessRun!
    private var peakMemoryMB = 0.0
    private var generation = 0
    private var pump: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?

    init() {
        var continuation: AsyncStream<Signal>.Continuation!
        signals = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Ends the run from outside (Menu pressed, cover dismissed). Safe to call more than once.
    func requestClose() { continuation.yield(.close) }

    /// - Parameters:
    ///   - present: shows a view controller full screen, or dismisses when nil.
    ///   - scrub: redacts free text before it is stored.
    func run(_ request: Request, scrub: @escaping (String) -> String,
             present: @escaping (UIViewController?) -> Void) async -> HarnessRun {
        let context = RoutingContext(preferences: Self.preferences, hardware: PlaybackRouter.hardwareCapabilities(),
                                     transcodeTarget: request.target, forcedEngine: request.forced)
        let mode: HarnessRun.Mode = request.seekTest ? .seekTest : .play
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let mb = MemoryProbe.footprintMB() { peakMemoryMB = max(peakMemoryMB, mb) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { sampler.cancel() }
        if let mb = MemoryProbe.footprintMB() { peakMemoryMB = mb }

        var prepared: PreparedPlayback
        do {
            prepared = try await router.prepare(url: request.url, context: context)
        } catch {
            var failed = HarnessRun(fileName: request.title, mode: mode, requested: request.forced, probeSummary: nil, probe: nil,
                                    decision: RoutingDecision(engine: .c, reasons: [.probeFailed]), enginePlayed: nil, prepareMillis: 0)
            failed.failure = scrub("Could not start: \(error)")
            return failed
        }

        run = HarnessRun(fileName: request.title, mode: mode, requested: request.forced, probeSummary: prepared.record.probeSummary,
                         probe: prepared.probe, decision: prepared.record.decision, enginePlayed: prepared.decision.engine,
                         prepareMillis: prepared.record.prepareMillis)
        run.failure = prepared.record.failure.map(scrub)

        var session = router.makeSession(for: prepared, title: request.title)
        var firstFrame = false
        attach(session, present: present)

        loop: for await signal in signals {
            switch signal {
            case .close:
                break loop
            case .seekTestDone(let g) where g == generation:
                break loop
            case .event(let event, let g) where g == generation:
                switch event {
                case .firstFrame(let ms):
                    firstFrame = true
                    run.ttffMillis = ms
                    if request.seekTest, seekTask == nil {
                        let current = session, g = generation
                        seekTask = Task { [continuation] in
                            await self.seekTest(on: current, generation: g)
                            continuation.yield(.seekTestDone(generation: g))
                        }
                    }
                case .failed(let message):
                    run.notes.append(scrub("\(session.engine.rawValue) failed: \(message)"))
                    if !firstFrame, session.engine != .c {
                        reroute(&prepared, &session, reason: .engineAFailedOpen, at: 0, track: nil, title: request.title, present: present)
                        firstFrame = false
                    }
                case .ended:
                    break loop
                case .playing, .paused, .buffering:
                    break
                }
            case .imageSubtitle(let track, let time, let g) where g == generation:
                reroute(&prepared, &session, reason: .userSelectedImageSubtitle, at: time, track: track, title: request.title, present: present)
                firstFrame = false
            default:
                break
            }
        }

        seekTask?.cancel()
        pump?.cancel()
        run.playedSeconds = session.currentTime
        // Diagnostics first: stop() releases the item and the renderer, which empties them.
        run.diagnostics = await session.diagnostics()
        session.stop()
        present(nil)
        run.peakMemoryMB = peakMemoryMB
        run.notes = run.notes.map(scrub)
        return run
    }

    private func attach(_ session: PlaybackSession, present: (UIViewController?) -> Void) {
        let g = generation
        pump?.cancel()
        pump = Task { [continuation] in
            for await event in session.events { continuation.yield(.event(event, generation: g)) }
        }
        if let engineA = session as? EngineASession {
            engineA.onImageSubtitleRequest = { [continuation] track, time in
                continuation.yield(.imageSubtitle(track: track, at: time, generation: g))
            }
        }
        present(session.viewController)
    }

    private func reroute(_ prepared: inout PreparedPlayback, _ session: inout PlaybackSession, reason: RouteReason, at time: Double,
                         track: Int?, title: String, present: (UIViewController?) -> Void) {
        seekTask?.cancel()
        seekTask = nil
        if run.mode == .seekTest { run.recordSeeks(latencies: [], timeouts: 0) }
        let from = session.engine
        session.stop()
        let (next, nextSession) = router.reroute(prepared, to: reason, at: time, subtitleTrack: track, title: title)
        prepared = next
        session = nextSession
        generation += 1
        run.reroutes.append(Reroute(from: from, reason: reason, atSeconds: time))
        run.enginePlayed = .c
        run.ttffMillis = nil
        attach(nextSession, present: present)
    }

    /// Waits for the first frame (caller), lets playback settle, then seeks to the same seeded positions for every engine.
    private func seekTest(on session: PlaybackSession, generation g: Int) async {
        var duration = run.probe?.durationSeconds ?? session.duration
        var waited = 0
        while (duration ?? 0) <= 60, waited < 10 {
            try? await Task.sleep(for: .seconds(1))
            waited += 1
            duration = session.duration
        }
        guard let duration, duration > 60 else {
            run.notes.append("Seek test skipped: duration unknown")
            return
        }
        try? await Task.sleep(for: .seconds(3))
        var latencies: [Int] = []
        var timeouts = 0
        for position in SeekPlan.positions(duration: duration) {
            if Task.isCancelled || g != generation { return }
            if let ms = await session.seek(to: position) { latencies.append(ms) } else { timeouts += 1 }
            guard g == generation else { return }
            run.recordSeeks(latencies: latencies, timeouts: timeouts)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
