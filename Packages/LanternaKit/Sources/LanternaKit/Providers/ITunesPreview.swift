import Foundation

/// Apple's public iTunes Search API returns a direct preview (trailer) video URL for most movies and shows.
/// TMDB only has YouTube links, which cannot be played in Lanterna's own player.
public struct ITunesPreviewClient: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    struct DTO: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let collectionName: String?
            let releaseDate: String?
            let previewUrl: String?
        }
        let results: [Result]
    }

    /// A preview only when the title (and year, for movies) matches. No match means nil, never a different film.
    public func previewURL(title: String, year: Int?, kind: TitleRef.Kind, country: String = "US") async throws -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        let isMovie = kind == .movie
        components.queryItems = [
            URLQueryItem(name: "term", value: title), URLQueryItem(name: "media", value: isMovie ? "movie" : "tvShow"),
            URLQueryItem(name: "entity", value: isMovie ? "movie" : "tvSeason"), URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url else { return nil }
        let dto: DTO = try await http.json(URLRequest(url: url))
        let wanted = Self.normalize(title)

        if isMovie {
            let hit = dto.results.first { result in
                guard Self.normalize(result.trackName ?? "") == wanted, result.previewUrl != nil else { return false }
                guard let year, let released = result.releaseDate.flatMap({ Int($0.prefix(4)) }) else { return true }
                return abs(released - year) <= 1
            }
            return hit?.previewUrl.flatMap(URL.init(string:))
        }
        // "Breaking Bad, Season 1": the show's earliest season with a preview.
        let seasons: [(Int, URL)] = dto.results.compactMap { result in
            guard let name = result.collectionName, let preview = result.previewUrl.flatMap(URL.init(string:)),
                  let range = name.range(of: ", Season ", options: .caseInsensitive),
                  Self.normalize(String(name[..<range.lowerBound])) == wanted,
                  let number = Int(name[range.upperBound...].prefix { $0.isNumber }) else { return nil }
            return (number, preview)
        }
        return seasons.min { $0.0 < $1.0 }?.1
    }

    /// Lowercase, letters and digits only, single spaces.
    static func normalize(_ text: String) -> String {
        let cleaned = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
