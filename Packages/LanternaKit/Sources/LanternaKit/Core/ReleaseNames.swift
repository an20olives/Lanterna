import Foundation

public struct ParsedRelease: Sendable, Equatable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
}

/// Conservative release-name parser for library matching. It only extracts what it is sure about.
public enum ReleaseNameParser {
    public static func parse(_ rawName: String) -> ParsedRelease {
        var name = (rawName as NSString).lastPathComponent
        for ext in ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts"] where name.lowercased().hasSuffix("." + ext) {
            name = String(name.dropLast(ext.count + 1))
        }
        let tokens = name.replacingOccurrences(of: "_", with: ".").split(whereSeparator: { $0 == "." || $0 == " " }).map(String.init)

        var season: Int?
        var episode: Int?
        var year: Int?
        var cut = tokens.count
        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            if let (s, e) = seasonEpisode(lower) {
                season = s; episode = e; cut = min(cut, index); break
            }
            // A year counts only when it is not the first token (titles like "2012").
            if index > 0, token.count == 4, let value = Int(token), (1900...2100).contains(value) {
                year = value; cut = min(cut, index); break
            }
            if ["2160p", "1080p", "720p", "480p", "4k", "uhd", "bluray", "web-dl", "webrip", "hdtv", "remux"].contains(lower) {
                cut = min(cut, index); break
            }
        }
        let title = tokens.prefix(cut).joined(separator: " ")
        return ParsedRelease(title: title, year: year, season: season, episode: episode)
    }

    private static func seasonEpisode(_ token: String) -> (Int, Int)? {
        // s01e02
        if token.hasPrefix("s"), let eIndex = token.firstIndex(of: "e") {
            let s = token[token.index(after: token.startIndex)..<eIndex]
            let e = token[token.index(after: eIndex)...]
            if let s = Int(s), let e = Int(e) { return (s, e) }
        }
        // 2x05
        let parts = token.split(separator: "x")
        if parts.count == 2, let s = Int(parts[0]), let e = Int(parts[1]), token.count <= 5 { return (s, e) }
        return nil
    }
}

public enum MatchResult: Sendable, Equatable {
    case matched(TitleRef)
    case ambiguous
    case unmatched
}

/// Matches parsed releases to TMDB. Exactly one result (with the same year when known) matches; anything else stays unmatched.
public struct LibraryMatcher: Sendable {
    public typealias Search = @Sendable (_ query: String, _ year: Int?) async -> [TitleSummary]
    let search: Search

    public init(search: @escaping Search) { self.search = search }

    public func match(_ release: ParsedRelease) async -> MatchResult {
        guard !release.title.isEmpty else { return .unmatched }
        var results = await search(release.title, release.year)
        if let year = release.year { results = results.filter { $0.year == nil || $0.year == year } }
        let wantsShow = release.season != nil
        results = results.filter { wantsShow ? $0.ref.kind == .show : $0.ref.kind == .movie }
        switch results.count {
        case 0: return .unmatched
        case 1:
            let ref = results[0].ref
            if wantsShow, let season = release.season, let episode = release.episode {
                return .matched(.episode(showTMDBID: ref.tmdbID, imdbID: ref.imdbID, season: season, episode: episode))
            }
            return .matched(ref)
        default: return .ambiguous
        }
    }
}
