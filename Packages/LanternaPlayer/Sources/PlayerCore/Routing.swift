import Foundation

public enum EngineID: String, Codable, Sendable, CaseIterable {
    /// AVPlayer opens the remote file itself (MP4 with Apple-native codecs).
    case aDirect = "A-direct"
    /// On-device remux to fMP4 HLS, played in AVPlayerViewController.
    case aRemux = "A"
    /// FFmpeg renderer (KSPlayer MEPlayer).
    case c = "C"
}

public enum RouteReason: String, Codable, Sendable {
    // Reasons that send a stream to C.
    case noSeekIndex, noRangeSupport, unsupportedContainer
    case hi10p, av1NoHardwareDecode, vc1, mpeg2, vp9, interlaced, unsupportedVideo
    case imageSubtitleRequired, userSelectedImageSubtitle
    case engineAFailedOpen, engineAFailedMidstream
    case probeFailed, noPlayableAudio
    case forcedByHarness
    // Informational: still A.
    case audioTranscodeDTS, audioTranscodeTrueHD, audioTranscodeOther
    case dvProfile7AsHDR10, dvProfile82AsSDR
    case textSubtitlesToWebVTT
}

/// Lossless codecs keep every channel; AAC 5.1 is the fallback. EAC3 is not available because the shared
/// FFmpeg build (KSPlayer's FFmpegKit 6.1.4) ships no AC3/EAC3 encoder.
public enum AudioTranscodeTarget: String, Codable, Sendable, CaseIterable {
    case alac, flac, aac51
}

public struct AudioPlan: Codable, Sendable, Equatable {
    public enum Action: Codable, Sendable, Equatable {
        case copy
        case transcode(AudioTranscodeTarget)
        case drop
    }

    public var trackIndex: Int
    public var action: Action

    public init(trackIndex: Int, action: Action) {
        self.trackIndex = trackIndex
        self.action = action
    }
}

public enum VideoTreatment: Codable, Sendable, Equatable {
    case passthrough
    /// Keep the Dolby Vision configuration record (dvcC/dvvC) in the fMP4 init segment.
    case dolbyVision(profile: Int)
    /// Drop Dolby Vision metadata and play the base layer (P7 as HDR10, P8.2 as SDR).
    case stripDolbyVision
}

public struct RoutingDecision: Codable, Sendable, Equatable {
    public var engine: EngineID
    public var reasons: [RouteReason]
    public var audioPlan: [AudioPlan]
    public var webVTTTracks: [Int]
    public var imageSubtitleTracks: [Int]
    public var videoTreatment: VideoTreatment

    public init(engine: EngineID, reasons: [RouteReason], audioPlan: [AudioPlan] = [], webVTTTracks: [Int] = [],
                imageSubtitleTracks: [Int] = [], videoTreatment: VideoTreatment = .passthrough) {
        self.engine = engine
        self.reasons = reasons
        self.audioPlan = audioPlan
        self.webVTTTracks = webVTTTracks
        self.imageSubtitleTracks = imageSubtitleTracks
        self.videoTreatment = videoTreatment
    }
}

public struct PlayerPreferences: Codable, Sendable, Equatable {
    public var audioLanguages: [String]
    public var subtitleLanguages: [String]
    public var subtitlesEnabled: Bool
    public var showForcedSubtitles: Bool

    public init(audioLanguages: [String], subtitleLanguages: [String], subtitlesEnabled: Bool, showForcedSubtitles: Bool) {
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.subtitlesEnabled = subtitlesEnabled
        self.showForcedSubtitles = showForcedSubtitles
    }
}

public struct HardwareCapabilities: Codable, Sendable, Equatable {
    public var av1HardwareDecode: Bool

    public init(av1HardwareDecode: Bool) {
        self.av1HardwareDecode = av1HardwareDecode
    }
}

public struct RoutingContext: Sendable, Equatable {
    public var preferences: PlayerPreferences
    public var hardware: HardwareCapabilities
    public var transcodeTarget: AudioTranscodeTarget
    /// P0 harness and diagnostics only.
    public var forcedEngine: EngineID?

    public init(preferences: PlayerPreferences, hardware: HardwareCapabilities,
                transcodeTarget: AudioTranscodeTarget, forcedEngine: EngineID? = nil) {
        self.preferences = preferences
        self.hardware = hardware
        self.transcodeTarget = transcodeTarget
        self.forcedEngine = forcedEngine
    }
}

public protocol RoutingPolicy: Sendable {
    func decide(_ probe: StreamProbe?, context: RoutingContext) -> RoutingDecision
}

/// The v1 policy from replica/architecture.md. Pure, so P0 can change it with tests alongside.
public struct DefaultRoutingPolicy: RoutingPolicy {
    public init() {}

    public func decide(_ probe: StreamProbe?, context: RoutingContext) -> RoutingDecision {
        guard let probe else {
            return RoutingDecision(engine: .c, reasons: [.probeFailed])
        }

        var toC: [RouteReason] = []
        var info: [RouteReason] = []

        if !probe.rangeSupported { toC.append(.noRangeSupport) }
        switch probe.container {
        case .matroska:
            if case .none = probe.seekIndex { toC.append(.noSeekIndex) }
        case .mp4:
            break
        case .mpegts, .other:
            toC.append(.unsupportedContainer)
        }

        var treatment = VideoTreatment.passthrough
        if let video = probe.video {
            toC.append(contentsOf: videoReasons(video, hardware: context.hardware))
            switch video.dynamicRange {
            case .dolbyVision(let dv):
                switch (dv.profile, dv.blSignalCompatibilityID) {
                case (5, _): treatment = .dolbyVision(profile: 5)
                case (8, 2): treatment = .stripDolbyVision; info.append(.dvProfile82AsSDR)
                case (8, _): treatment = .dolbyVision(profile: 8)
                case (7, _): treatment = .stripDolbyVision; info.append(.dvProfile7AsHDR10)
                default: treatment = .stripDolbyVision
                }
            default:
                break
            }
        } else {
            toC.append(.unsupportedVideo)
        }

        let audioPlan = probe.audio.map { track -> AudioPlan in
            let action: AudioPlan.Action
            switch track.codec {
            case .aac, .ac3, .eac3, .alac:
                action = .copy
            case .truehd:
                action = .transcode(context.transcodeTarget); info.append(.audioTranscodeTrueHD)
            case .dts, .dtsHDMA, .dtsHRA:
                action = .transcode(context.transcodeTarget); info.append(.audioTranscodeDTS)
            case .flac, .opus, .mp3, .pcm:
                action = .transcode(context.transcodeTarget); info.append(.audioTranscodeOther)
            case .other:
                action = .drop
            }
            return AudioPlan(trackIndex: track.index, action: action)
        }
        if !audioPlan.isEmpty, audioPlan.allSatisfy({ $0.action == .drop }) {
            toC.append(.noPlayableAudio)
        }

        let webVTT = probe.subtitles.filter(\.format.isConvertibleText).map(\.index)
        let image = probe.subtitles.filter(\.format.isImageBased).map(\.index)
        if !webVTT.isEmpty { info.append(.textSubtitlesToWebVTT) }
        if requiresImageSubtitle(probe.subtitles, preferences: context.preferences) {
            toC.append(.imageSubtitleRequired)
        }

        var decision: RoutingDecision
        if !toC.isEmpty {
            decision = RoutingDecision(engine: .c, reasons: toC, audioPlan: audioPlan, webVTTTracks: webVTT,
                                       imageSubtitleTracks: image, videoTreatment: treatment)
        } else if probe.container == .mp4, audioPlan.allSatisfy({ $0.action == .copy }), image.isEmpty {
            decision = RoutingDecision(engine: .aDirect, reasons: [], audioPlan: audioPlan,
                                       webVTTTracks: [], imageSubtitleTracks: [], videoTreatment: treatment)
        } else {
            decision = RoutingDecision(engine: .aRemux, reasons: unique(info), audioPlan: audioPlan,
                                       webVTTTracks: webVTT, imageSubtitleTracks: image, videoTreatment: treatment)
        }

        if let forced = context.forcedEngine {
            decision.engine = forced
            decision.reasons.append(.forcedByHarness)
        }
        return decision
    }

    private func videoReasons(_ video: VideoInfo, hardware: HardwareCapabilities) -> [RouteReason] {
        var reasons: [RouteReason] = []
        switch video.codec {
        case .h264:
            if video.bitDepth > 8 || (video.profile?.contains("10") ?? false) { reasons.append(.hi10p) }
        case .hevc:
            break
        case .av1:
            if !hardware.av1HardwareDecode { reasons.append(.av1NoHardwareDecode) }
        case .vc1:
            reasons.append(.vc1)
        case .mpeg2:
            reasons.append(.mpeg2)
        case .vp9:
            reasons.append(.vp9)
        case .other:
            reasons.append(.unsupportedVideo)
        }
        if video.interlaced { reasons.append(.interlaced) }
        return reasons
    }

    /// True when the subtitle the viewer would see by default exists only as an image track.
    private func requiresImageSubtitle(_ tracks: [SubtitleTrackInfo], preferences: PlayerPreferences) -> Bool {
        if preferences.showForcedSubtitles {
            let forced = tracks.filter(\.isForced)
            for language in Set(forced.compactMap(\.language)) {
                let inLanguage = forced.filter { $0.language == language }
                if inLanguage.contains(where: \.format.isImageBased),
                   !inLanguage.contains(where: \.format.isConvertibleText) {
                    return true
                }
            }
        }
        guard preferences.subtitlesEnabled else { return false }
        for language in preferences.subtitleLanguages {
            let inLanguage = tracks.filter { $0.language == language && !$0.isForced }
            if inLanguage.contains(where: \.format.isConvertibleText) { return false }
            if inLanguage.contains(where: \.format.isImageBased) { return true }
        }
        return false
    }

    private func unique(_ reasons: [RouteReason]) -> [RouteReason] {
        var seen = Set<RouteReason>()
        return reasons.filter { seen.insert($0).inserted }
    }
}
