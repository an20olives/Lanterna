import Foundation

public enum VideoRange: String, Codable, Sendable {
    case sdr = "SDR", pq = "PQ", hlg = "HLG"
}

public struct MasterPlaylist: Sendable, Equatable {
    public struct Video: Sendable, Equatable {
        public var codecs: String
        public var supplementalCodecs: String?
        public var width: Int
        public var height: Int
        public var frameRate: Double
        public var videoRange: VideoRange
        public var bandwidth: Int
        public var uri: String

        public init(codecs: String, supplementalCodecs: String?, width: Int, height: Int, frameRate: Double,
                    videoRange: VideoRange, bandwidth: Int, uri: String) {
            self.codecs = codecs
            self.supplementalCodecs = supplementalCodecs
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.videoRange = videoRange
            self.bandwidth = bandwidth
            self.uri = uri
        }
    }

    public struct Audio: Sendable, Equatable {
        public var id: Int
        public var name: String
        public var language: String?
        public var codecs: String
        public var channels: String
        public var isDefault: Bool
        public var uri: String

        public init(id: Int, name: String, language: String?, codecs: String, channels: String, isDefault: Bool, uri: String) {
            self.id = id
            self.name = name
            self.language = language
            self.codecs = codecs
            self.channels = channels
            self.isDefault = isDefault
            self.uri = uri
        }
    }

    public struct Subtitle: Sendable, Equatable {
        public var id: Int
        public var name: String
        public var language: String?
        public var isDefault: Bool
        public var isForced: Bool
        public var uri: String

        public init(id: Int, name: String, language: String?, isDefault: Bool, isForced: Bool, uri: String) {
            self.id = id
            self.name = name
            self.language = language
            self.isDefault = isDefault
            self.isForced = isForced
            self.uri = uri
        }
    }

    public var video: Video
    public var audio: [Audio]
    public var subtitles: [Subtitle]

    public init(video: Video, audio: [Audio], subtitles: [Subtitle]) {
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
    }
}

public enum PlaylistWriter {
    public static func mediaPlaylist(plan: SegmentPlan, initURI: String?, segmentExtension: String) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(plan.targetDurationSeconds)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if let initURI { lines.append("#EXT-X-MAP:URI=\"\(initURI)\"") }
        for segment in plan.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("\(segment.index).\(segmentExtension)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func masterPlaylist(_ master: MasterPlaylist) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for audio in master.audio {
            var attrs = ["TYPE=AUDIO", "GROUP-ID=\"aud\"", "NAME=\(quoted(audio.name))"]
            if let language = audio.language, !language.isEmpty { attrs.append("LANGUAGE=\(quoted(language))") }
            attrs += ["DEFAULT=\(audio.isDefault ? "YES" : "NO")", "AUTOSELECT=YES",
                      "CHANNELS=\(quoted(audio.channels))", "URI=\(quoted(audio.uri))"]
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }
        for sub in master.subtitles {
            var attrs = ["TYPE=SUBTITLES", "GROUP-ID=\"subs\"", "NAME=\(quoted(sub.name))"]
            if let language = sub.language, !language.isEmpty { attrs.append("LANGUAGE=\(quoted(language))") }
            attrs += ["DEFAULT=\(sub.isDefault ? "YES" : "NO")", "AUTOSELECT=YES",
                      "FORCED=\(sub.isForced ? "YES" : "NO")", "URI=\(quoted(sub.uri))"]
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }
        var codecs = [master.video.codecs]
        for audio in master.audio where !codecs.contains(audio.codecs) { codecs.append(audio.codecs) }
        var attrs = ["BANDWIDTH=\(master.video.bandwidth)", "CODECS=\(quoted(codecs.joined(separator: ",")))"]
        if let supplemental = master.video.supplementalCodecs { attrs.append("SUPPLEMENTAL-CODECS=\(quoted(supplemental))") }
        attrs += ["RESOLUTION=\(master.video.width)x\(master.video.height)",
                  String(format: "FRAME-RATE=%.3f", master.video.frameRate),
                  "VIDEO-RANGE=\(master.video.videoRange.rawValue)"]
        if !master.audio.isEmpty { attrs.append("AUDIO=\"aud\"") }
        if !master.subtitles.isEmpty { attrs.append("SUBTITLES=\"subs\"") }
        lines.append("#EXT-X-STREAM-INF:" + attrs.joined(separator: ","))
        lines.append(master.video.uri)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}

/// RFC 6381 codec strings for the HLS CODECS attribute.
public enum CodecString {
    /// From an HEVCDecoderConfigurationRecord (ISO/IEC 14496-15, Annex E).
    public static func hevc(hvcC: [UInt8], tag: String) -> String? {
        guard hvcC.count >= 13 else { return nil }
        let space = Int(hvcC[1] >> 6)
        let tier = (hvcC[1] >> 5) & 1
        let profile = Int(hvcC[1] & 0x1F)
        let compat = UInt32(hvcC[2]) << 24 | UInt32(hvcC[3]) << 16 | UInt32(hvcC[4]) << 8 | UInt32(hvcC[5])
        var reversed: UInt32 = 0
        for bit in 0..<32 where compat & (1 << bit) != 0 { reversed |= 1 << (31 - bit) }
        var constraints = Array(hvcC[6..<12])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var string = "\(tag).\(["", "A", "B", "C"][space])\(profile).\(String(reversed, radix: 16, uppercase: true))"
        string += ".\(tier == 1 ? "H" : "L")\(hvcC[12])"
        for byte in constraints { string += "." + String(byte, radix: 16, uppercase: true) }
        return string
    }

    /// From an AVCDecoderConfigurationRecord.
    public static func avc(avcC: [UInt8]) -> String? {
        guard avcC.count >= 4 else { return nil }
        return String(format: "avc1.%02X%02X%02X", avcC[1], avcC[2], avcC[3])
    }

    public static func dolbyVision(profile: Int, level: Int, tag: String) -> String {
        String(format: "%@.%02d.%02d", tag, profile, level)
    }

    /// Profile 8 rides on an HEVC sample entry; the DV signal goes in SUPPLEMENTAL-CODECS.
    public static func dolbyVisionSupplemental(profile: Int, level: Int, compatibilityID: Int) -> String? {
        let brand: String
        switch compatibilityID {
        case 1: brand = "db1p"
        case 4: brand = "db4h"
        default: return nil
        }
        return String(format: "dvh1.%02d.%02d/%@", profile, level, brand)
    }
}
