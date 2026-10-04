import Foundation

/// What a stream actually is, measured by opening it (not what the source claims).
public struct StreamProbe: Codable, Sendable, Equatable {
    public var container: Container
    public var durationSeconds: Double?
    public var seekIndex: SeekIndex
    public var rangeSupported: Bool
    public var contentLength: Int64?
    public var bitRate: Int?
    public var video: VideoInfo?
    public var audio: [AudioTrackInfo]
    public var subtitles: [SubtitleTrackInfo]
    public var chapters: [Chapter]
    public var probeMillis: Int

    public init(container: Container, durationSeconds: Double?, seekIndex: SeekIndex, rangeSupported: Bool,
                contentLength: Int64?, bitRate: Int?, video: VideoInfo?, audio: [AudioTrackInfo],
                subtitles: [SubtitleTrackInfo], chapters: [Chapter], probeMillis: Int) {
        self.container = container
        self.durationSeconds = durationSeconds
        self.seekIndex = seekIndex
        self.rangeSupported = rangeSupported
        self.contentLength = contentLength
        self.bitRate = bitRate
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
        self.chapters = chapters
        self.probeMillis = probeMillis
    }

    /// One line for logs and the P0 results table. Contains no URL.
    public var summary: String {
        var parts = [container.label]
        if let video {
            parts.append("\(video.codec.label) \(video.profile ?? "") \(video.bitDepth)bit \(video.width)x\(video.height)")
            parts.append(video.dynamicRange.label)
        }
        parts.append(audio.map { $0.codec.label + ($0.hasAtmos ? " Atmos" : "") + " \($0.channels)ch" }.joined(separator: ", "))
        if !subtitles.isEmpty { parts.append("subs: " + subtitles.map(\.format.label).joined(separator: ",")) }
        if case .none = seekIndex { parts.append("no seek index") }
        return parts.joined(separator: " | ")
    }
}

public enum Container: Codable, Sendable, Equatable {
    case matroska, mp4, mpegts
    case other(String)

    public var label: String {
        switch self {
        case .matroska: "MKV"
        case .mp4: "MP4"
        case .mpegts: "TS"
        case .other(let name): name
        }
    }
}

public enum SeekIndex: Codable, Sendable, Equatable {
    /// Keyframe index available up front (Matroska Cues or MP4 sample tables).
    case keyframeIndex(count: Int)
    case none
}

public struct Rational: Codable, Sendable, Equatable {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var value: Double { denominator == 0 ? 0 : Double(numerator) / Double(denominator) }
}

public enum VideoCodec: Codable, Sendable, Equatable, Hashable {
    case h264, hevc, av1, vc1, mpeg2, vp9
    case other(String)

    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .vc1: "VC-1"
        case .mpeg2: "MPEG-2"
        case .vp9: "VP9"
        case .other(let name): name
        }
    }
}

public struct DoviConfig: Codable, Sendable, Equatable, Hashable {
    public var profile: Int
    public var level: Int
    /// 0 none, 1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10.
    public var blSignalCompatibilityID: Int
    public var rpuPresent: Bool
    public var elPresent: Bool

    public init(profile: Int, level: Int, blSignalCompatibilityID: Int, rpuPresent: Bool, elPresent: Bool) {
        self.profile = profile
        self.level = level
        self.blSignalCompatibilityID = blSignalCompatibilityID
        self.rpuPresent = rpuPresent
        self.elPresent = elPresent
    }
}

public enum DynamicRange: Codable, Sendable, Equatable, Hashable {
    case sdr, hdr10, hdr10Plus, hlg
    case dolbyVision(DoviConfig)

    public var label: String {
        switch self {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dolbyVision(let dv): "DV P\(dv.profile).\(dv.blSignalCompatibilityID)"
        }
    }
}

public struct VideoInfo: Codable, Sendable, Equatable {
    public var codec: VideoCodec
    public var profile: String?
    public var level: Int?
    public var bitDepth: Int
    public var width: Int
    public var height: Int
    public var frameRate: Rational
    public var interlaced: Bool
    public var dynamicRange: DynamicRange

    public init(codec: VideoCodec, profile: String?, level: Int?, bitDepth: Int, width: Int, height: Int,
                frameRate: Rational, interlaced: Bool, dynamicRange: DynamicRange) {
        self.codec = codec
        self.profile = profile
        self.level = level
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.interlaced = interlaced
        self.dynamicRange = dynamicRange
    }
}

public enum AudioCodec: Codable, Sendable, Equatable, Hashable {
    case aac, ac3, eac3, truehd, dts, dtsHDMA, dtsHRA, flac, opus, mp3, pcm, alac
    case other(String)

    public var label: String {
        switch self {
        case .aac: "AAC"
        case .ac3: "AC3"
        case .eac3: "EAC3"
        case .truehd: "TrueHD"
        case .dts: "DTS"
        case .dtsHDMA: "DTS-HD MA"
        case .dtsHRA: "DTS-HD HRA"
        case .flac: "FLAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        case .pcm: "PCM"
        case .alac: "ALAC"
        case .other(let name): name
        }
    }
}

public struct AudioTrackInfo: Codable, Sendable, Equatable {
    /// Stream index inside the container.
    public var index: Int
    public var codec: AudioCodec
    public var channels: Int
    public var hasAtmos: Bool
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isCommentary: Bool
    public var isAudioDescription: Bool

    public init(index: Int, codec: AudioCodec, channels: Int, hasAtmos: Bool, language: String?, title: String?,
                isDefault: Bool, isCommentary: Bool, isAudioDescription: Bool) {
        self.index = index
        self.codec = codec
        self.channels = channels
        self.hasAtmos = hasAtmos
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isCommentary = isCommentary
        self.isAudioDescription = isAudioDescription
    }
}

public enum SubtitleFormat: Codable, Sendable, Equatable, Hashable {
    case srt, ass, ssa, webvtt, movText, pgs, vobsub, dvb
    case other(String)

    public var isImageBased: Bool {
        switch self {
        case .pgs, .vobsub, .dvb: true
        default: false
        }
    }

    public var isConvertibleText: Bool {
        switch self {
        case .srt, .ass, .ssa, .webvtt, .movText: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .srt: "SRT"
        case .ass: "ASS"
        case .ssa: "SSA"
        case .webvtt: "WebVTT"
        case .movText: "mov_text"
        case .pgs: "PGS"
        case .vobsub: "VobSub"
        case .dvb: "DVB"
        case .other(let name): name
        }
    }
}

public struct SubtitleTrackInfo: Codable, Sendable, Equatable {
    public var index: Int
    public var format: SubtitleFormat
    public var language: String?
    public var title: String?
    public var isForced: Bool
    public var isDefault: Bool

    public init(index: Int, format: SubtitleFormat, language: String?, title: String?, isForced: Bool, isDefault: Bool) {
        self.index = index
        self.format = format
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isDefault = isDefault
    }
}

public struct Chapter: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var title: String?

    public init(start: Double, end: Double, title: String?) {
        self.start = start
        self.end = end
        self.title = title
    }
}
