import Foundation

/// Canonical title identity. TMDB-first; the IMDb ID rides along for Stremio-protocol sources.
public struct TitleRef: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case movie, show, episode }

    public var kind: Kind
    /// For `.episode` this is the show's TMDB ID.
    public var tmdbID: Int
    public var imdbID: String?
    public var season: Int?
    public var episode: Int?

    public static func movie(tmdbID: Int, imdbID: String?) -> TitleRef {
        TitleRef(kind: .movie, tmdbID: tmdbID, imdbID: imdbID)
    }

    public static func show(tmdbID: Int, imdbID: String?) -> TitleRef {
        TitleRef(kind: .show, tmdbID: tmdbID, imdbID: imdbID)
    }

    public static func episode(showTMDBID: Int, imdbID: String?, season: Int, episode: Int) -> TitleRef {
        TitleRef(kind: .episode, tmdbID: showTMDBID, imdbID: imdbID, season: season, episode: episode)
    }

    public var key: String {
        switch kind {
        case .movie: "movie:\(tmdbID)"
        case .show: "show:\(tmdbID)"
        case .episode: "episode:\(tmdbID):\(season ?? 0):\(episode ?? 0)"
        }
    }

    /// The show this episode belongs to (or self for movies and shows).
    public var showRef: TitleRef {
        kind == .episode ? .show(tmdbID: tmdbID, imdbID: imdbID) : self
    }

    public var stremioType: String { kind == .movie ? "movie" : "series" }

    /// `tt…` for movies, `tt…:S:E` for episodes. Nil when the IMDb ID is not known yet.
    public var stremioID: String? {
        guard let imdbID else { return nil }
        switch kind {
        case .movie, .show: return imdbID
        case .episode: return "\(imdbID):\(season ?? 0):\(episode ?? 0)"
        }
    }

    public init(kind: Kind, tmdbID: Int, imdbID: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.kind = kind
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.season = season
        self.episode = episode
    }

    /// Parses `movie:603`, `show:1399`, `episode:1399:1:2`.
    public init?(key: String, imdbID: String? = nil) {
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count >= 2, let id = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "movie" where parts.count == 2: self = .movie(tmdbID: id, imdbID: imdbID)
        case "show" where parts.count == 2: self = .show(tmdbID: id, imdbID: imdbID)
        case "episode" where parts.count == 4:
            guard let season = Int(parts[2]), let episode = Int(parts[3]) else { return nil }
            self = .episode(showTMDBID: id, imdbID: imdbID, season: season, episode: episode)
        default: return nil
        }
    }
}
