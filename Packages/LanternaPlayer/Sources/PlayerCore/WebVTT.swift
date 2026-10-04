import Foundation

public struct WebVTTCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Text subtitle conversion for Engine A's WebVTT renditions.
public enum WebVTT {
    // Private-use placeholders keep our own tags safe while escaping everything else.
    private static let tagPlaceholders: [(tag: String, mark: String)] = [
        ("<i>", "\u{E000}"), ("</i>", "\u{E001}"), ("<b>", "\u{E002}"), ("</b>", "\u{E003}"),
        ("<u>", "\u{E004}"), ("</u>", "\u{E005}"),
    ]

    public static func cueText(fromSRT text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = value.replacing(/\{\\[^}]*\}/, with: "")
        value = value.replacing(/(?i)<\/?font[^>]*>/, with: "")
        for (tag, mark) in tagPlaceholders {
            value = value.replacingOccurrences(of: tag, with: mark, options: .caseInsensitive)
        }
        return finish(value)
    }

    /// FFmpeg's Matroska ASS packets: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    public static func cueText(fromASSPacket packet: String) -> String? {
        let fields = packet.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let raw = fields.count == 9 ? String(fields[8]) : packet
        if raw.contains(/\{[^}]*\\p[1-9]/) { return nil } // vector drawing, not text

        var value = raw.replacing(/\{([^}]*)\}/) { match -> String in
            let block = String(match.output.1)
            var tags = ""
            for override in block.split(separator: "\\") {
                switch override {
                case "i1": tags += "\u{E000}"
                case "i0": tags += "\u{E001}"
                case "b1": tags += "\u{E002}"
                case "b0": tags += "\u{E003}"
                case "u1": tags += "\u{E004}"
                case "u0": tags += "\u{E005}"
                default: break
                }
            }
            return tags
        }
        value = value.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        let result = finish(value)
        return result.isEmpty ? nil : result
    }

    public static func segment(cues: [WebVTTCue]) -> String {
        var text = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        for cue in cues {
            text += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n\n"
        }
        return text
    }

    static func timestamp(_ seconds: Double) -> String {
        let millis = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
    }

    private static func finish(_ text: String) -> String {
        var value = text.replacing(/<[^>]*>/, with: "") // any other markup
        value = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        for (tag, mark) in tagPlaceholders { value = value.replacingOccurrences(of: mark, with: tag) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
