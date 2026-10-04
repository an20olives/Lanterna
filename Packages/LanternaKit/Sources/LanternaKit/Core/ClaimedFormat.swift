import Foundation

public enum Resolution: Int, Codable, Sendable, Comparable, CaseIterable {
    case r480 = 480, r720 = 720, r1080 = 1080, r2160 = 2160

    public static func < (lhs: Resolution, rhs: Resolution) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .r480: "480p"
        case .r720: "720p"
        case .r1080: "1080p"
        case .r2160: "4K"
        }
    }
}

public enum HDRFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case hdr10, hdr10plus, dolbyVision, hlg

    public var label: String {
        switch self {
        case .hdr10: "HDR10"
        case .hdr10plus: "HDR10+"
        case .dolbyVision: "DV"
        case .hlg: "HLG"
        }
    }
}

/// What a source says a stream is, parsed from its name, description and file name. Claims, not facts:
/// the playback probe is the ground truth.
public struct ClaimedFormat: Hashable, Codable, Sendable {
    public var resolution: Resolution?
    public var hdr: Set<HDRFormat> = []
    public var videoCodec: String?
    public var audioCodecs: Set<String> = []
    public var hasAtmos = false
    public var source: String?
    /// Debrid cache claim: true when the text says ready or cached, false when it says otherwise, nil when silent.
    public var isCachedClaim: Bool?

    public init() {}

    public static func parse(name: String?, description: String?, filename: String?) -> ClaimedFormat {
        // Swift Regex has no lookbehind and its \b treats "02.1080p" as one number, so tokenise instead:
        // punctuation becomes a space and needles carry their own space boundaries.
        let separators = CharacterSet(charactersIn: ".-_:/|,()[]{}\n\r\t")
        let joined = [name, description, filename].compactMap { $0 }.joined(separator: " \n ").lowercased()
        let spaced = joined.unicodeScalars.map { separators.contains($0) ? " " : Character($0) }
        let text = " " + String(spaced).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") + " "
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        var format = ClaimedFormat()
        if has(" 2160p ", " 4k ", " uhd ") { format.resolution = .r2160 }
        else if has(" 1080p ", " 1080i ") { format.resolution = .r1080 }
        else if has(" 720p ") { format.resolution = .r720 }
        else if has(" 480p ", " sd ") { format.resolution = .r480 }

        if has(" dv ", "dolby vision", "dolbyvision", " dovi ") { format.hdr.insert(.dolbyVision) }
        if has(" hdr10+ ", "hdr10plus") { format.hdr.insert(.hdr10plus) }
        if has(" hdr10 ", " hdr ") { format.hdr.insert(.hdr10) }
        if has(" hlg ") { format.hdr.insert(.hlg) }

        if has("hevc", " h 265 ", " h265 ", "x265") { format.videoCodec = "HEVC" }
        else if has(" h 264 ", " h264 ", "x264", " avc ") { format.videoCodec = "H.264" }
        else if has(" av1 ") { format.videoCodec = "AV1" }
        else if has(" vc 1 ", " vc1 ") { format.videoCodec = "VC-1" }

        if has("truehd") { format.audioCodecs.insert("TrueHD") }
        if has("dts hd ma", "dts hdma") || (has("dts hd ") && !has("dts hd hra")) { format.audioCodecs.insert("DTS-HD MA") }
        if has("dts hd hra") { format.audioCodecs.insert("DTS-HD HRA") }
        if has("dts x ", "dtsx") { format.audioCodecs.insert("DTS:X") }
        if has(" dts ") { format.audioCodecs.insert("DTS") }
        if has(" ddp", " dd+", " eac3 ", " e ac 3 ") { format.audioCodecs.insert("EAC3") }
        if has(" dd ", " dd5", " dd2", " ac3 ", " ac 3 ") { format.audioCodecs.insert("AC3") }
        if has(" aac") { format.audioCodecs.insert("AAC") }
        if has(" flac") { format.audioCodecs.insert("FLAC") }
        if has(" opus") { format.audioCodecs.insert("Opus") }
        format.hasAtmos = has("atmos")

        if has("remux") { format.source = "REMUX" }
        else if has("web dl", " webdl ") { format.source = "WEB-DL" }
        else if has("webrip") { format.source = "WEBRip" }
        else if has("blu ray", "bluray", "bdrip", "brrip") { format.source = "BluRay" }
        else if has("hdtv") { format.source = "HDTV" }

        if has("⚡", " ready ", "(ready", " cached ") { format.isCachedClaim = true }
        if has("uncached", "not cached", "⏳", "❌") { format.isCachedClaim = false }
        return format
    }

    /// Short badge strip for stream cards: "4K · DV · HDR10 · Atmos".
    public var badges: [String] {
        var result: [String] = []
        if let resolution { result.append(resolution.label) }
        result += hdr.sorted { $0.rawValue < $1.rawValue }.map(\.label)
        if hasAtmos { result.append("Atmos") }
        else if let codec = audioCodecs.sorted().first { result.append(codec) }
        return result
    }
}
