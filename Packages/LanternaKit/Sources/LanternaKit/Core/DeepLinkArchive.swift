import Foundation

/// Hand-maintained map from TMDB watch-provider IDs to app-launch strategies. There is no subscription API and
/// no public content-ID mapping for most services, so most rows are app-only or search. The gaps are logged here.
public struct DeepLinkArchive: Sendable {
    public enum Level: String, Codable, Sendable { case appOnly = "app-only", search, title, episode }

    public struct Entry: Codable, Sendable, Equatable {
        public var providerID: Int
        public var name: String
        public var scheme: String?
        public var level: Level
        public var template: String?
        public var verifiedOn: String?
        public var notes: String
    }

    public struct Link: Sendable, Equatable {
        public var url: URL
        public var level: Level
        public var serviceName: String
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public static func decode(_ data: Data) throws -> DeepLinkArchive {
        DeepLinkArchive(entries: try JSONDecoder().decode([Entry].self, from: data))
    }

    /// Schemes to list under LSApplicationQueriesSchemes.
    public var schemes: [String] { Array(Set(entries.compactMap(\.scheme))).sorted() }

    public func entry(for providerID: Int) -> Entry? { entries.first { $0.providerID == providerID } }

    public func link(providerID: Int, title: String, ref: TitleRef) -> Link? {
        guard let entry = entry(for: providerID) else { return nil }
        if let template = entry.template {
            let filled = template
                .replacingOccurrences(of: "{title}", with: Self.escape(title))
                .replacingOccurrences(of: "{tmdb}", with: String(ref.tmdbID))
                .replacingOccurrences(of: "{imdb}", with: ref.imdbID ?? "")
                .replacingOccurrences(of: "{season}", with: String(ref.season ?? 1))
                .replacingOccurrences(of: "{episode}", with: String(ref.episode ?? 1))
            if let url = URL(string: filled) { return Link(url: url, level: entry.level, serviceName: entry.name) }
        }
        guard let scheme = entry.scheme, let url = URL(string: "\(scheme)://") else { return nil }
        return Link(url: url, level: .appOnly, serviceName: entry.name)
    }

    static func escape(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
