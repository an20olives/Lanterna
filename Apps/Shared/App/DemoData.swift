import Foundation
import LanternaKit

/// Placeholder content for a build with no TMDB token, so every screen can be seen and tested.
enum DemoData {
    static func summary(_ id: Int, _ kind: TitleRef.Kind, _ title: String, _ year: Int) -> TitleSummary {
        TitleSummary(ref: TitleRef(kind: kind, tmdbID: id, imdbID: nil), title: title, year: year,
                     overview: "A placeholder title shown until a TMDB token is added in Settings.", rating: 7.5)
    }

    static let movies: [TitleSummary] = [
        summary(900_001, .movie, "The Lantern Keeper", 2024), summary(900_002, .movie, "Night Ferry", 2023),
        summary(900_003, .movie, "Amber Hour", 2022), summary(900_004, .movie, "Small Orbit", 2021),
        summary(900_005, .movie, "Glass Harbor", 2020), summary(900_006, .movie, "Paper Cities", 2019),
        summary(900_007, .movie, "Low Tide", 2018), summary(900_008, .movie, "Second Dawn", 2017),
    ]

    static let shows: [TitleSummary] = [
        summary(910_001, .show, "Signal Fires", 2024), summary(910_002, .show, "The Long Quiet", 2023),
        summary(910_003, .show, "Harbor Lights", 2022), summary(910_004, .show, "Echo Road", 2021),
        summary(910_005, .show, "Northbound", 2020), summary(910_006, .show, "Dim Sum Diaries", 2019),
    ]

    static func shelves() -> [(title: String, items: [TitleSummary])] {
        [("Trending Movies", movies), ("Trending Shows", shows), ("Popular Movies", movies.reversed()), ("Popular Shows", shows.reversed())]
    }

    static func detail(_ ref: TitleRef) -> TitleDetail? {
        let all = movies + shows
        guard let base = all.first(where: { $0.ref.tmdbID == ref.tmdbID }) else { return nil }
        return TitleDetail(summary: base, tagline: "Placeholder", runtimeMinutes: ref.kind == .movie ? 112 : 48, certification: "PG-13",
                           genres: ["Drama", "Mystery"], cast: [CastMember(id: 1, name: "A. Placeholder", character: "Lead")],
                           seasons: ref.kind == .movie ? [] : (1...3).map { SeasonSummary(number: $0, name: "Season \($0)", episodeCount: 8) })
    }

    static func episodes(season: Int) -> [EpisodeSummary] {
        (1...8).map { EpisodeSummary(season: season, number: $0, name: "Episode \($0)", overview: "Placeholder episode.", runtimeMinutes: 48) }
    }
}
