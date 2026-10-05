import Foundation
import LanternaKit
import PlayerCore

extension AppEnvironment {
    var subtitleAppearance: SubtitleAppearance {
        let prefs = config.playerPrefs
        return SubtitleAppearance(sizePercent: prefs.subtitleSizePercent, color: prefs.subtitleColor == .yellow ? .yellow : .white,
                                  background: prefs.subtitleBackground, delaySeconds: prefs.subtitleDelaySeconds, raisePercent: prefs.subtitleRaisePercent)
    }

    /// Downloads a few subtitle files in the owner's languages from sources that offer them. Never blocks playback for long.
    func externalSubtitles(for ref: TitleRef) async -> [ExternalSubtitle] {
        guard ref.stremioID != nil else { return [] }
        let wanted = config.playerPrefs.subtitleLanguages.map { Self.languageKey($0) }
        let request = StreamRequest(title: ref, preferredLanguages: config.playerPrefs.subtitleLanguages, region: config.watchRegion)
        let sources = await registry.sources(with: .subtitles)
        let found: [ExternalSubtitle] = (try? await SourceRegistry.withTimeout(8) { () async throws -> [ExternalSubtitle] in
            var results: [ExternalSubtitle] = []
            for source in sources {
                guard let candidates = try? await source.subtitles(for: request) else { continue }
                for candidate in candidates.filter({ wanted.contains(Self.languageKey($0.language)) }).prefix(3) {
                    var urlRequest = URLRequest(url: candidate.url)
                    urlRequest.timeoutInterval = 8
                    guard let (data, response) = try? await URLSession.shared.data(for: urlRequest), data.count < 3_000_000,
                          (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    let cues = SubtitleParser.parse(SubtitleParser.decode(data))
                    guard !cues.isEmpty else { continue }
                    results.append(ExternalSubtitle(id: candidate.id, language: candidate.language,
                                                    label: "\(candidate.label) (download \(results.count + 1))", cues: cues, sourceURL: candidate.url))
                }
            }
            return results
        }) ?? []
        return Array(found.prefix(4))
    }

    /// "eng", "en" and "en-US" all compare equal.
    nonisolated static func languageKey(_ code: String) -> String {
        let table = ["eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt", "jpn": "ja",
                     "kor": "ko", "chi": "zh", "zho": "zh", "rus": "ru", "dut": "nl", "nld": "nl", "swe": "sv", "pol": "pl"]
        let lower = code.lowercased()
        if let mapped = table[lower] { return mapped }
        return String(lower.prefix(2))
    }
}
