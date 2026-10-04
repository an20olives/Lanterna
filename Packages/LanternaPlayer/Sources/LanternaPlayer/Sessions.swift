#if canImport(UIKit)
import EngineC
import Foundation
import PlayerCore

public extension PlaybackRouter {
    /// Builds the player session for a prepared stream.
    @MainActor
    func makeSession(for prepared: PreparedPlayback, startTime: Double = 0, title: String? = nil) -> PlaybackSession {
        switch prepared.decision.engine {
        case .aDirect, .aRemux:
            return EngineASession(prepared: prepared, startTime: startTime, title: title)
        case .c:
            return EngineCSession(url: prepared.sourceURL, startTime: startTime, title: title)
        }
    }

    /// Reroutes to Engine C at a position, for A failures or a PGS pick. Logged.
    @MainActor
    func reroute(_ prepared: PreparedPlayback, to reason: RouteReason, at time: Double, subtitleTrack: Int? = nil,
                 title: String? = nil) -> (PreparedPlayback, PlaybackSession) {
        prepared.remux?.stop()
        var next = prepared
        next.decision.engine = .c
        next.decision.reasons.append(reason)
        next.record.decision = next.decision
        next.remux = nil
        next.playbackURL = prepared.sourceURL
        Self.log.info("reroute to C reason=\(reason.rawValue, privacy: .public) at=\(time)")
        return (next, EngineCSession(url: prepared.sourceURL, startTime: time, title: title, subtitleTrack: subtitleTrack))
    }
}
#endif
