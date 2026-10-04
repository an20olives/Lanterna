import EngineA
import Foundation
import os
import PlayerCore
import VideoToolbox

/// What was decided for one stream, safe to log and to export in P0 results (no URL, no secrets).
public struct RouteRecord: Codable, Sendable {
    public var date: Date
    public var probe: StreamProbe?
    public var probeSummary: String?
    public var decision: RoutingDecision
    public var prepareMillis: Int
    public var failure: String?
}

/// A routed stream, ready to hand to a player session.
public struct PreparedPlayback: @unchecked Sendable {
    public var decision: RoutingDecision
    public var record: RouteRecord
    /// What the engine opens: the source for A-direct and C, the localhost master playlist for A.
    public var playbackURL: URL
    /// The original stream URL, kept in memory for rerouting to C. Never logged.
    public var sourceURL: URL
    public var remux: RemuxSession?
    public var probe: StreamProbe? { record.probe }
}

/// Probes each stream, picks an engine, logs the decision with the probe, and starts Engine A when chosen.
public final class PlaybackRouter: Sendable {
    static let log = Logger(subsystem: "lanterna", category: "routing")
    let policy: any RoutingPolicy

    public init(policy: any RoutingPolicy = DefaultRoutingPolicy()) {
        self.policy = policy
    }

    public static func hardwareCapabilities() -> HardwareCapabilities {
        HardwareCapabilities(av1HardwareDecode: VTIsHardwareDecodeSupported(0x6176_3031)) // 'av01'
    }

    public func prepare(url: URL, context: RoutingContext) async throws -> PreparedPlayback {
        let started = Date()
        var source: RemoteByteSource?
        var result: ProbeResult?
        var failure: String?
        do {
            let opened = try await RemoteByteSource.open(url)
            source = opened
            result = try await FFmpegProber.probe(opened)
        } catch {
            failure = "probe: \(error)"
        }

        var decision = policy.decide(result?.probe, context: context)
        var playbackURL = url
        var remux: RemuxSession?
        if decision.engine == .aRemux, let source, let result {
            do {
                let session = try RemuxSession(source: source, probe: result, decision: decision)
                playbackURL = try await session.start()
                remux = session
            } catch {
                decision.engine = .c
                decision.reasons.append(.engineAFailedOpen)
                failure = "engine A: \(error)"
            }
        } else if decision.engine == .aRemux {
            decision.engine = .c
            decision.reasons.append(.engineAFailedOpen)
        }

        let record = RouteRecord(date: Date(), probe: result?.probe, probeSummary: result?.probe.summary, decision: decision,
                                 prepareMillis: Int(Date().timeIntervalSince(started) * 1000), failure: failure)
        let reasons = decision.reasons.map(\.rawValue).joined(separator: ",")
        Self.log.info("route engine=\(decision.engine.rawValue, privacy: .public) reasons=\(reasons, privacy: .public) probe=\(record.probeSummary ?? "none", privacy: .public) prepare_ms=\(record.prepareMillis)")
        if let failure { Self.log.error("route failure: \(failure, privacy: .public)") }
        return PreparedPlayback(decision: decision, record: record, playbackURL: playbackURL, sourceURL: url, remux: remux)
    }
}
