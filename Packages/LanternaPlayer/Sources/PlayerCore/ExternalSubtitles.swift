import Foundation

/// A subtitle file fetched from a source (AIOStreams, OpenSubtitles-style addons), already parsed.
/// Engine A serves it as one more WebVTT rendition; Engine C is handed `sourceURL` and parses it itself.
public struct ExternalSubtitle: Sendable, Equatable, Identifiable {
    public var id: String
    public var language: String
    public var label: String
    public var cues: [WebVTTCue]
    public var sourceURL: URL?

    public init(id: String, language: String, label: String, cues: [WebVTTCue], sourceURL: URL?) {
        self.id = id
        self.language = language
        self.label = label
        self.cues = cues
        self.sourceURL = sourceURL
    }

    /// Cues that show at some point inside [start, end). A cue still on screen at the boundary appears in both segments.
    public func cues(from start: Double, to end: Double) -> [WebVTTCue] {
        cues.filter { $0.end > start && $0.start < end }
    }
}

extension WebVTTCue {
    public func shifted(by seconds: Double) -> WebVTTCue {
        WebVTTCue(start: max(0, start + seconds), end: max(0, end + seconds), text: text)
    }
}

/// How subtitles look. Engine A applies it as AVTextStyleRules, Engine C through KSPlayer's subtitle model.
public struct SubtitleAppearance: Sendable, Equatable {
    public enum Color: String, Sendable { case white, yellow }
    public var sizePercent = 100
    public var color: Color = .white
    public var background = false
    /// Engine C only.
    public var delaySeconds = 0.0
    /// Percent of the picture height to lift subtitles off the bottom edge. 0 leaves the player's default.
    public var raisePercent = 0

    public init(sizePercent: Int = 100, color: Color = .white, background: Bool = false, delaySeconds: Double = 0, raisePercent: Int = 0) {
        self.raisePercent = raisePercent
        self.sizePercent = sizePercent
        self.color = color
        self.background = background
        self.delaySeconds = delaySeconds
    }

    public var relativeFontSize: Int { sizePercent }

    /// Line position for CoreMedia text markup: 0 is the top, 100 the bottom. Nil keeps the default.
    public var linePositionPercent: Int? { raisePercent > 0 ? max(40, 90 - raisePercent) : nil }

    /// Alpha, red, green, blue in 0...1, the layout CoreMedia text markup expects.
    public var foregroundARGB: [Double] {
        switch color {
        case .white: [1, 1, 1, 1]
        case .yellow: [1, 1, 0.92, 0.2]
        }
    }

    public var backgroundARGB: [Double]? { background ? [0.6, 0, 0, 0] : nil }
}

/// SRT and WebVTT text to cues. Tolerant by design: subtitle files in the wild are messy.
public enum SubtitleParser {
    public static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ raw: String) -> [WebVTTCue] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var cues: [WebVTTCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(String(parts[1].split(separator: " ", omittingEmptySubsequences: true).first ?? "")) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(WebVTTCue(start: start, end: end, text: WebVTT.cueText(fromSRT: body)))
        }
        return cues
    }

    /// 00:01:02,250, 00:01:02.250 or 01:02.250.
    static func seconds(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
