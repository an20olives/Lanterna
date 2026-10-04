#if canImport(UIKit)
import AVKit
import EngineA
import PlayerCore
import UIKit

/// Engine A (and A-direct): AVPlayerViewController, so every native tvOS player feature stays intact.
@MainActor
public final class EngineASession: NSObject, PlaybackSession {
    public let engine: EngineID
    public let viewController: UIViewController
    public let events: AsyncStream<PlaybackEvent>
    /// Called when the viewer picks an image subtitle (PGS) that only Engine C can show: (stream index, current time).
    public var onImageSubtitleRequest: ((Int, Double) -> Void)?

    let player: AVPlayer
    let item: AVPlayerItem
    let remux: RemuxSession?
    private let playerController = AVPlayerViewController()
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let created = Date()
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var firstFrameReported = false
    private var startTime: Double
    private var stalls = 0

    public init(prepared: PreparedPlayback, startTime: Double = 0, title: String? = nil) {
        engine = prepared.decision.engine
        remux = prepared.remux
        self.startTime = startTime
        item = AVPlayerItem(url: prepared.playbackURL)
        player = AVPlayer(playerItem: item)
        var continuation: AsyncStream<PlaybackEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        viewController = playerController
        super.init()

        playerController.player = player
        #if os(tvOS)
        playerController.appliesPreferredDisplayCriteriaAutomatically = true
        configureTVMetadata(prepared: prepared, title: title)
        #endif
        observe()
        player.play()
    }

    #if os(tvOS)
    private func configureTVMetadata(prepared: PreparedPlayback, title: String?) {
        if let title {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            item.extendedLanguageTag = "und"
            self.item.externalMetadata = [item]
        }
        if let chapters = prepared.probe?.chapters, !chapters.isEmpty {
            let markers = chapters.map { chapter -> AVTimedMetadataGroup in
                let name = AVMutableMetadataItem()
                name.identifier = .commonIdentifierTitle
                name.value = (chapter.title ?? "Chapter") as NSString
                name.extendedLanguageTag = "und"
                let range = CMTimeRange(start: CMTime(seconds: chapter.start, preferredTimescale: 1000),
                                        end: CMTime(seconds: chapter.end, preferredTimescale: 1000))
                return AVTimedMetadataGroup(items: [name], timeRange: range)
            }
            item.navigationMarkerGroups = [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
        }
        let imageTracks = (prepared.probe?.subtitles ?? []).filter { prepared.decision.imageSubtitleTracks.contains($0.index) }
        if !imageTracks.isEmpty {
            let actions = imageTracks.map { track in
                UIAction(title: [track.language?.uppercased(), track.title, track.format.label].compactMap { $0 }.joined(separator: " ")) { [weak self] _ in
                    guard let self else { return }
                    self.onImageSubtitleRequest?(track.index, self.currentTime)
                }
            }
            playerController.transportBarCustomMenuItems = [
                UIMenu(title: "More subtitles", image: UIImage(systemName: "captions.bubble"), children: actions),
            ]
        }
    }
    #endif

    private func observe() {
        observations.append(playerController.observe(\.isReadyForDisplay, options: [.new]) { [weak self] controller, _ in
            MainActor.assumeIsolated {
                guard let self, controller.isReadyForDisplay, !self.firstFrameReported else { return }
                self.firstFrameReported = true
                self.continuation.yield(.firstFrame(millis: Int(Date().timeIntervalSince(self.created) * 1000)))
            }
        })
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.status {
                case .readyToPlay where self.startTime > 0:
                    let target = CMTime(seconds: self.startTime, preferredTimescale: 1000)
                    self.startTime = 0
                    self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                case .failed:
                    self.continuation.yield(.failed(item.error.map { String(describing: $0) } ?? "AVPlayerItem failed"))
                default:
                    break
                }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing: self.continuation.yield(.playing)
                case .paused: self.continuation.yield(.paused)
                case .waitingToPlayAtSpecifiedRate:
                    if self.firstFrameReported { self.stalls += 1 }
                    self.continuation.yield(.buffering)
                @unknown default: break
                }
            }
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.continuation.yield(.ended) }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).map { String(describing: $0) } ?? "Failed to play to end"
            MainActor.assumeIsolated { _ = self?.continuation.yield(.failed(message)) }
        })
    }

    public var currentTime: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    public var duration: Double? { item.duration.seconds.isFinite ? item.duration.seconds : nil }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func seek(to seconds: Double) async -> Int? {
        let started = Date()
        let finished = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        guard finished else { return nil }
        player.play()
        let deadline = Date().addingTimeInterval(20)
        while player.timeControlStatus != .playing {
            if Date() > deadline { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        observations.removeAll()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        remux?.stop()
        continuation.finish()
    }

    public func diagnostics() async -> PlaybackDiagnostics {
        let event = item.accessLog()?.events.last
        var extra: [String: String] = [:]
        if let remux {
            let stats = await remux.stats()
            extra["segments"] = String(stats.segmentsProduced)
            extra["randomAccesses"] = String(stats.randomAccesses)
            extra["segmentAvgMs"] = String(stats.segmentsProduced > 0 ? stats.totalProductionMillis / stats.segmentsProduced : 0)
            extra["segmentMaxMs"] = String(stats.maxProductionMillis)
            extra["prepareMs"] = String(stats.prepareMillis)
            extra["bytesFetched"] = String(stats.bytesFetched)
            extra["rangeRequests"] = String(stats.rangeRequests)
        }
        return PlaybackDiagnostics(droppedFrames: event.map { $0.numberOfDroppedVideoFrames }, stalls: stalls,
                                   observedBitrate: event?.observedBitrate, extra: extra)
    }
}
#endif
