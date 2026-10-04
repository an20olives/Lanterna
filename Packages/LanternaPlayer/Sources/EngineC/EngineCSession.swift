#if canImport(UIKit)
@preconcurrency import KSPlayer
import PlayerCore
import os
import SwiftUI
import UIKit

/// Engine C: KSPlayer's FFmpeg renderer (MEPlayer) with its SwiftUI controls.
///
/// KSPlayer already sets tvOS display criteria and Now Playing. For P0 its stock controls stand in for
/// the hand-built native transport bar, which is P2 work.
@MainActor
public final class EngineCSession: PlaybackSession {
    public let engine: EngineID = .c
    public let viewController: UIViewController
    public let events: AsyncStream<PlaybackEvent>

    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let coordinator = KSVideoPlayer.Coordinator()
    private let created = Date()
    private var firstFrameReported = false
    private var lastState: KSPlayerState = .initialized
    private var stalls = 0
    private var statePoller: Task<Void, Never>?
    private var stateWaiters: [(KSPlayerState) -> Bool] = []

    /// - Parameter subtitleTrack: container stream index to select once playing (PGS reroute from Engine A).
    public init(url: URL, startTime: Double = 0, title: String? = nil, subtitleTrack: Int? = nil) {
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        let options = KSOptions()
        options.startPlayTime = startTime
        options.registerRemoteControll = true

        var continuation: AsyncStream<PlaybackEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation

        let view = KSVideoPlayerView(coordinator: coordinator, url: url, options: options, title: title)
        viewController = UIHostingController(rootView: view)

        // KSVideoPlayerView installs its own onStateChanged on the shared coordinator and would replace ours,
        // so watch the layer's state directly.
        statePoller = Task { @MainActor [weak self] in
            var last = KSPlayerState.initialized
            while !Task.isCancelled {
                if let self, let layer = self.coordinator.playerLayer, layer.state != last {
                    last = layer.state
                    self.handle(last, layer: layer, subtitleTrack: subtitleTrack)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        coordinator.onFinish = { [weak self] _, error in
            MainActor.assumeIsolated {
                if let error { self?.continuation.yield(.failed(String(describing: error))) }
                else { self?.continuation.yield(.ended) }
            }
        }
    }

    private static let log = Logger(subsystem: "lanterna", category: "engineC")

    private func handle(_ state: KSPlayerState, layer: KSPlayerLayer, subtitleTrack: Int?) {
        Self.log.info("state \(state.description, privacy: .public) t=\(Int(Date().timeIntervalSince(self.created) * 1000))ms")
        lastState = state
        switch state {
        case .bufferFinished:
            if !firstFrameReported {
                firstFrameReported = true
                continuation.yield(.firstFrame(millis: Int(Date().timeIntervalSince(created) * 1000)))
                if let subtitleTrack { select(subtitleTrack: subtitleTrack, on: layer) }
            }
            continuation.yield(.playing)
        case .buffering:
            if firstFrameReported { stalls += 1 }
            continuation.yield(.buffering)
        case .paused:
            continuation.yield(.paused)
        case .playedToTheEnd:
            continuation.yield(.ended)
        case .error:
            continuation.yield(.failed("KSPlayer reported an error"))
        default:
            break
        }
        stateWaiters.removeAll { $0(state) }
    }

    private func select(subtitleTrack index: Int, on layer: KSPlayerLayer) {
        if let track = layer.player.tracks(mediaType: .subtitle).first(where: { Int($0.trackID) == index }) {
            layer.player.select(track: track)
        }
    }

    public var currentTime: Double { coordinator.playerLayer?.player.currentPlaybackTime ?? 0 }
    public var duration: Double? { coordinator.playerLayer.map { $0.player.duration } }

    public func play() { coordinator.playerLayer?.play() }
    public func pause() { coordinator.playerLayer?.pause() }

    /// Latency from the call until playback has advanced past the target, so it reflects frames on screen
    /// and not just KSPlayer reporting the seek as done.
    public func seek(to seconds: Double) async -> Int? {
        guard let layer = coordinator.playerLayer else { return nil }
        let started = Date()
        let accepted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var finished = false
            let finish: (Bool) -> Void = { value in
                guard !finished else { return }
                finished = true
                done.resume(returning: value)
            }
            layer.seek(time: seconds, autoPlay: true) { ok in
                MainActor.assumeIsolated { finish(ok) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                finish(false)
            }
        }
        guard accepted else { return nil }
        let deadline = started.addingTimeInterval(20)
        while Date() < deadline {
            let now = currentTime
            if now >= seconds + 0.1, now < seconds + 10 { return Int(Date().timeIntervalSince(started) * 1000) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    public func stop() {
        statePoller?.cancel()
        coordinator.playerLayer?.stop()
        coordinator.resetPlayer()
        continuation.finish()
    }

    public func diagnostics() async -> PlaybackDiagnostics {
        let info = coordinator.playerLayer?.player.dynamicInfo
        return PlaybackDiagnostics(droppedFrames: info.map { Int($0.droppedVideoFrameCount) }, stalls: stalls,
                                   observedBitrate: info.map { Double($0.videoBitrate + $0.audioBitrate) },
                                   extra: ["displayFPS": info.map { String(format: "%.2f", $0.displayFPS) } ?? "",
                                           "avSyncDiff": info.map { String(format: "%.3f", $0.audioVideoSyncDiff) } ?? ""])
    }
}
#endif
