import Foundation

public enum PlaybackEvent: Sendable, Equatable {
    /// First frame is on screen. Milliseconds since the session was created.
    case firstFrame(millis: Int)
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

public struct PlaybackDiagnostics: Codable, Sendable, Equatable {
    public var droppedFrames: Int?
    public var stalls: Int
    public var observedBitrate: Double?
    public var extra: [String: String]

    public init(droppedFrames: Int? = nil, stalls: Int = 0, observedBitrate: Double? = nil, extra: [String: String] = [:]) {
        self.droppedFrames = droppedFrames
        self.stalls = stalls
        self.observedBitrate = observedBitrate
        self.extra = extra
    }
}

#if canImport(UIKit)
import UIKit

/// One playing stream, whichever engine renders it.
@MainActor
public protocol PlaybackSession: AnyObject {
    var engine: EngineID { get }
    var viewController: UIViewController { get }
    var events: AsyncStream<PlaybackEvent> { get }
    var currentTime: Double { get }
    var duration: Double? { get }
    func play()
    func pause()
    /// Seeks and waits until playback resumes. Returns the latency in milliseconds, or nil on timeout.
    func seek(to seconds: Double) async -> Int?
    func stop()
    func diagnostics() async -> PlaybackDiagnostics
}
#endif
