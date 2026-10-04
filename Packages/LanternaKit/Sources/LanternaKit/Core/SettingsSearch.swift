import Foundation

/// Plain matching for the Settings search field.
public enum SettingsSearch {
    public struct Entry: Hashable, Sendable {
        public var title: String
        public var section: String
        public var keywords: [String]
        public init(title: String, section: String, keywords: [String]) {
            self.title = title
            self.section = section
            self.keywords = keywords
        }
    }

    /// Every word of the query must appear somewhere in the title, section or keywords.
    public static func matches(_ query: String, _ entry: Entry) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([entry.title, entry.section] + entry.keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    public static func filter(_ query: String, _ entries: [Entry]) -> [Entry] { entries.filter { matches(query, $0) } }
}
