import Foundation
import LanternaKit
import LanternaPlayer
import Observation
import PlayerCore
import UIKit
import os

struct NextEpisode: Equatable {
    var ref: TitleRef
    var title: String
}

/// Opens a chosen stream in the right engine, keeps progress, and handles failures and Up Next.
/// Used by Home, detail and Library alike; the P0 harness has its own measuring coordinator.
@MainActor
@Observable
final class PlaybackController {
    struct Request {
        var candidate: StreamCandidate
        var ref: TitleRef
        var displayTitle: String
        var startAt: Double
        var next: NextEpisode?
        /// Plays this URL directly (a trailer) instead of resolving the candidate through its source.
        var directURL: URL?
        /// Trailers leave no progress, history or scrobble behind.
        var persists = true
    }

    struct UpNext: Equatable {
        var title: String
        var secondsLeft: Int
    }

    var presented: UIViewController?
    var upNext: UpNext?
    var errorMessage: String?
    var isBusy = false
    /// Called when the current item ends (or the Up Next countdown finishes) and a next episode exists.
    @ObservationIgnored var onAdvance: ((NextEpisode) -> Void)?

    @ObservationIgnored private let router = PlaybackRouter()
    @ObservationIgnored private var session: PlaybackSession?
    @ObservationIgnored private var prepared: PreparedPlayback?
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var env: AppEnvironment?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private var scrobbleCount = 0
    @ObservationIgnored private var firstFrame = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var segments: [MediaSegment] = []
    @ObservationIgnored private var offeredSegmentStart: Double?
    @ObservationIgnored private var autoSkipped = Set<Double>()

    private static let log = Logger(subsystem: "lanterna", category: "playback")

    var isPlaying: Bool { session != nil }

    /// A trailer preview, played in the normal player with no progress kept.
    func playTrailer(url: URL, title: String, ref: TitleRef, env: AppEnvironment) async {
        let candidate = StreamCandidate(id: "trailer:\(ref.key)", sourceID: AppEnvironment.sourceID(.tmdb), sourceKind: .tmdb, title: ref,
                                        displayName: "Trailer", locatorHint: .url(url))
        await play(Request(candidate: candidate, ref: ref, displayTitle: "\(title) (Trailer)", startAt: 0, next: nil, directURL: url, persists: false), env: env)
    }

    func play(_ request: Request, env: AppEnvironment) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        await closeCurrent(advance: false)
        self.env = env
        self.request = request
        sessionID = UUID().uuidString
        scrobbleCount = 0
        finishing = false
        segments = []
        offeredSegmentStart = nil
        autoSkipped = []

        let source = await env.registry.source(for: request.candidate.sourceID)
        guard request.directURL != nil || source != nil else {
            errorMessage = "That source is not available any more."
            return
        }
        do {
            let locator: PlaybackLocator
            if let direct = request.directURL { locator = PlaybackLocator(url: direct) }
            else if let source { locator = try await source.resolve(request.candidate.locatorHint) }
            else { return }
            let prefs = env.config.playerPrefs
            let context = RoutingContext(
                preferences: PlayerPreferences(audioLanguages: prefs.audioLanguages, subtitleLanguages: prefs.subtitleLanguages,
                                               subtitlesEnabled: prefs.subtitlesEnabled, showForcedSubtitles: prefs.showForcedSubtitles),
                hardware: PlaybackRouter.hardwareCapabilities(),
                transcodeTarget: AudioTranscodeTarget(rawValue: prefs.audioTranscode) ?? .alac)
            async let subtitles = request.persists ? env.externalSubtitles(for: request.ref) : []
            if request.persists, case .jellyfin(let itemID, _) = request.candidate.locatorHint, let jellyfin = source as? JellyfinSource {
                segments = await jellyfin.segments(itemID: itemID)
            }
            let external = await subtitles
            var current = locator
            var prepared = try await router.prepare(url: current.url, context: context, externalSubtitles: external)
            // A dead CDN node answers "could not connect". A fresh link can land on another node, so try again before giving up.
            var attempts = 0
            while prepared.record.probe == nil, Self.isNetworkFailure(prepared.record.failure), attempts < 2 {
                attempts += 1
                try await Task.sleep(for: .seconds(1.5))
                if let source, request.directURL == nil, let fresh = try? await source.resolve(request.candidate.locatorHint) { current = fresh }
                prepared = try await router.prepare(url: current.url, context: context, externalSubtitles: external)
            }
            if prepared.record.probe == nil, Self.isNetworkFailure(prepared.record.failure) {
                // Engine C would hit the same wall, so say what happened instead of opening a second failure.
                self.prepared = prepared
                await logRoute(prepared, outcome: "unreachable")
                errorMessage = "Could not reach the stream server. Try another stream, or try again in a moment."
                return
            }
            await logRoute(prepared, outcome: "opening")
            let session = router.makeSession(for: prepared, startTime: request.startAt, title: request.displayTitle, appearance: env.subtitleAppearance)
            attach(session)
            startTicker()
        } catch is CancellationError {
            return
        } catch let error as SourceError where error == .needsCredentials {
            errorMessage = "The source rejected the login. Check it in Settings."
        } catch {
            errorMessage = "Could not open that stream."
        }
    }

    /// Connection-level failures (could not connect, timed out, offline, connection lost) in an error string.
    static func isNetworkFailure(_ failure: String?) -> Bool {
        guard let failure else { return false }
        return ["Code=-1004", "Code=-1001", "Code=-1009", "Code=-1005", "Code=-1003"].contains { failure.contains($0) }
    }

    /// One readable line for the routing log instead of a raw NSError dump.
    static func shortFailure(_ failure: String?) -> String? {
        guard let failure else { return nil }
        if failure.contains("Code=-1004") { return "Could not connect to the stream server." }
        if failure.contains("Code=-1001") { return "The stream server took too long to answer." }
        if failure.contains("Code=-1009") { return "No internet connection." }
        if failure.contains("Code=-1005") { return "The connection to the stream server dropped." }
        if failure.contains("Code=-1003") { return "The stream server's address could not be found." }
        return failure.count > 160 ? String(failure.prefix(160)) + "…" : failure
    }

    private func attach(_ newSession: PlaybackSession) {
        generation += 1
        let g = generation
        session = newSession
        firstFrame = false
        pump?.cancel()
        pump = Task { [weak self] in
            for await event in newSession.events {
                guard let self, g == self.generation else { return }
                await self.handle(event, generation: g)
            }
        }
        if let engineA = newSession as? EngineASession {
            engineA.onImageSubtitleRequest = { [weak self] track, time in
                MainActor.assumeIsolated { self?.reroute(reason: .userSelectedImageSubtitle, at: time, track: track) }
            }
        }
        presented = newSession.viewController
    }

    private func handle(_ event: PlaybackEvent, generation g: Int) async {
        switch event {
        case .firstFrame:
            firstFrame = true
            await persist(.start)
        case .playing:
            if firstFrame { await persist(.start) }
        case .paused:
            await persist(.pause)
        case .failed(let message):
            if !firstFrame, session?.engine != .c {
                reroute(reason: .engineAFailedOpen, at: request?.startAt ?? 0, track: nil)
            } else if firstFrame, session?.engine != .c {
                reroute(reason: .engineAFailedMidstream, at: session?.currentTime ?? 0, track: nil)
            } else {
                errorMessage = "Playback stopped. \(Redactor.text(message))"
                await closeCurrent(advance: false)
            }
        case .ended:
            await closeCurrent(advance: true, completed: true)
        case .buffering:
            break
        }
    }

    private func reroute(reason: RouteReason, at time: Double, track: Int?) {
        guard let prepared, let old = session else { return }
        old.stop()
        let (next, newSession) = router.reroute(prepared, to: reason, at: time, subtitleTrack: track, title: request?.displayTitle,
                                                appearance: env?.subtitleAppearance ?? SubtitleAppearance())
        offeredSegmentStart = nil
        self.prepared = next
        Task { await logRoute(next, outcome: "rerouted") }
        attach(newSession)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                seconds += 1
                self.tick(seconds)
                if seconds % 15 == 0 { await self.persist(.progress) }
            }
        }
    }

    /// Skip Intro: a native player button on Engine A, or an automatic seek, from the server's media segments.
    private func updateSkip(session: PlaybackSession, env: AppEnvironment) {
        let mode = env.config.playerPrefs.skipIntro
        guard mode != .off, !segments.isEmpty, firstFrame else { return }
        let engineA = session as? EngineASession
        guard let segment = SegmentTracker.active(at: session.currentTime, in: segments) else {
            if offeredSegmentStart != nil { offeredSegmentStart = nil; engineA?.setSkipAction(title: nil, handler: nil) }
            return
        }
        if mode == .auto || engineA == nil {
            // Credits are left to Up Next; the button-less engine skips intros and recaps only when asked to auto-skip.
            guard mode == .auto, segment.kind != .outro, autoSkipped.insert(segment.start).inserted else { return }
            Task { _ = await session.seek(to: segment.end) }
        } else if offeredSegmentStart != segment.start {
            offeredSegmentStart = segment.start
            engineA?.setSkipAction(title: segment.skipLabel) { [weak self] in
                self?.offeredSegmentStart = nil
                Task { _ = await session.seek(to: segment.end) }
            }
        }
    }

    private func tick(_ seconds: Int) {
        if let session, let env { updateSkip(session: session, env: env) }
        guard let session, let request, let next = request.next, let env else { upNext = nil; return }
        let duration = session.duration ?? prepared?.probe?.durationSeconds ?? 0
        let lead = Double(env.config.playerPrefs.nextEpisodeLeadSeconds)
        guard duration > 0, firstFrame else { return }
        let remaining = duration - session.currentTime
        if remaining <= lead, remaining > 0 {
            let left = Int(remaining.rounded(.up))
            upNext = UpNext(title: next.title, secondsLeft: left)
            if left <= 1 { Task { await closeCurrent(advance: true, completed: true) } }
        } else if upNext != nil {
            upNext = nil
        }
    }

    /// Progress is written locally every time, and queued for Trakt on start, pause and stop.
    private func persist(_ phase: PlaybackReport.Phase) async {
        guard let session, let request, let env, request.persists else { return }
        let duration = session.duration ?? prepared?.probe?.durationSeconds ?? 0
        let position = session.currentTime
        Self.log.info("persist phase=\(phase.rawValue, privacy: .public) pos=\(position) dur=\(duration)")
        guard duration > 0 else { return }
        let ref = request.ref
        await env.progress.record(titleKey: ref.key, showTMDBID: ref.kind == .episode ? ref.tmdbID : nil, position: position, duration: duration,
                                  streamID: request.candidate.id, deviceName: env.deviceName)
        let report = PlaybackReport(title: ref, phase: phase, positionSeconds: position, durationSeconds: duration, sessionID: sessionID)
        if phase != .progress {
            scrobbleCount += 1
            let action = phase == .start ? "start" : phase == .pause ? "pause" : "stop"
            let payload = ScrobblePayload(titleKey: ref.key, imdbID: ref.imdbID, action: action, progress: report.fraction * 100)
            if let data = try? JSONEncoder().encode(payload) {
                let key = "scrobble-\(action):\(ref.key):\(sessionID):\(phase == .stop ? 0 : scrobbleCount)"
                await env.outbox.enqueue(idempotencyKey: key, target: .trakt, op: "scrobble", payload: data)
            }
            env.syncKick?()
        }
        if let source = await env.registry.source(for: request.candidate.sourceID) as? JellyfinSource, case .jellyfin(let itemID, let mediaSourceID) = request.candidate.locatorHint {
            try? await source.reportPlayback(report, itemID: itemID, mediaSourceID: mediaSourceID)
        }
    }

    private func logRoute(_ prepared: PreparedPlayback, outcome: String) async {
        guard let env, let request, request.persists else { return }
        await env.cache.recordProbe(streamID: request.candidate.id, titleKey: request.ref.key, record: prepared.record, outcome: outcome)
    }

    /// Menu pressed or the cover went away.
    func dismissed() {
        Task { await closeCurrent(advance: false) }
    }

    func closeCurrent(advance: Bool, completed: Bool = false) async {
        guard let session, !finishing else { return }
        finishing = true
        ticker?.cancel()
        pump?.cancel()
        if completed, let request, let env, request.persists {
            let duration = session.duration ?? prepared?.probe?.durationSeconds ?? 0
            if duration > 0 {
                await env.progress.record(titleKey: request.ref.key, showTMDBID: request.ref.kind == .episode ? request.ref.tmdbID : nil,
                                          position: duration, duration: duration, streamID: request.candidate.id, deviceName: env.deviceName)
            }
        } else {
            await persist(.progress)
        }
        await persistStop(completed: completed)
        session.stop()
        self.session = nil
        presented = nil
        upNext = nil
        let next = advance ? request?.next : nil
        prepared?.remux?.stop()
        prepared = nil
        finishing = false
        if let next { onAdvance?(next) }
    }

    private func persistStop(completed: Bool) async {
        guard let session, let request, let env, request.persists else { return }
        let duration = session.duration ?? prepared?.probe?.durationSeconds ?? 0
        guard duration > 0 else { return }
        let position = completed ? duration : session.currentTime
        let report = PlaybackReport(title: request.ref, phase: .stop, positionSeconds: position, durationSeconds: duration, sessionID: sessionID)
        let payload = ScrobblePayload(titleKey: request.ref.key, imdbID: request.ref.imdbID, action: "stop", progress: report.fraction * 100)
        if let data = try? JSONEncoder().encode(payload) {
            await env.outbox.enqueue(idempotencyKey: "scrobble-stop:\(request.ref.key):\(sessionID):0", target: .trakt, op: "scrobble", payload: data)
        }
        if let source = await env.registry.source(for: request.candidate.sourceID) as? JellyfinSource, case .jellyfin(let itemID, let mediaSourceID) = request.candidate.locatorHint {
            try? await source.reportPlayback(report, itemID: itemID, mediaSourceID: mediaSourceID)
        }
        env.syncKick?()
    }
}

extension CacheStore {
    func recordProbe(streamID: String, titleKey: String, record: RouteRecord, outcome: String) async {
        let data = (try? JSONEncoder().encode(record.probe)) ?? Data()
        await recordProbe(streamID: streamID, titleKey: titleKey, probeJSON: data, engine: record.decision.engine.rawValue,
                          reasons: record.decision.reasons.map(\.rawValue), outcome: outcome,
                          failure: PlaybackController.shortFailure(record.failure).map { Redactor.text($0) })
    }
}
