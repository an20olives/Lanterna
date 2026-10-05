import Foundation

/// Public lists from MDBList (keyless JSON) and Letterboxd (list page HTML). Both resolve to TMDB titles in the app.
public struct ExternalListClient: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    public struct Entry: Sendable, Hashable {
        public var tmdbID: Int?
        public var kind: TitleRef.Kind
        public var title: String
        public var year: Int?
    }

    /// `path` is `user/list-slug`, as in mdblist.com/lists/user/list-slug.
    public func mdblist(path: String, limit: Int = 40) async throws -> [Entry] {
        guard let url = URL(string: "https://mdblist.com/lists/\(path)/json") else { throw SourceError.notFound }
        let rows: [MDBRow] = try await http.json(URLRequest(url: url))
        return rows.prefix(limit).map {
            Entry(tmdbID: $0.id, kind: $0.mediatype == "show" ? .show : .movie, title: $0.title ?? "", year: $0.release_year)
        }
    }

    struct MDBRow: Decodable {
        let id: Int?
        let title: String?
        let mediatype: String?
        let release_year: Int?
    }

    /// `path` is `user/list-slug`, as in letterboxd.com/user/list/list-slug.
    public func letterboxd(path: String, limit: Int = 40) async throws -> [Entry] {
        guard let url = URL(string: "https://letterboxd.com/\(path.split(separator: "/").joined(separator: "/list/"))/") else { throw SourceError.notFound }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await http.send(request)
        return Self.parseLetterboxd(String(decoding: data, as: UTF8.self), limit: limit)
    }

    /// Reads `data-item-name="Title (Year)"` from the poster components of a list page.
    static func parseLetterboxd(_ html: String, limit: Int) -> [Entry] {
        var entries: [Entry] = []
        var rest = html[...]
        let marker = "data-item-name=\""
        while entries.count < limit, let range = rest.range(of: marker) {
            rest = rest[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let raw = Self.unescape(String(rest[..<end]))
            rest = rest[end...]
            var title = raw
            var year: Int?
            if raw.hasSuffix(")"), let open = raw.lastIndex(of: "("), let y = Int(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]), (1870...2100).contains(y) {
                year = y
                title = String(raw[..<open]).trimmingCharacters(in: .whitespaces)
            }
            if !title.isEmpty, !entries.contains(where: { $0.title == title && $0.year == year }) {
                entries.append(Entry(tmdbID: nil, kind: .movie, title: title, year: year))
            }
        }
        return entries
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
