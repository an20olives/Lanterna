import Foundation
import LanternaKit

extension AppEnvironment {
    /// Cache first (30 days), then TMDB, then demo content.
    func detail(for ref: TitleRef) async -> TitleDetail? {
        let show = ref.showRef
        if let cached = await cache.detail(for: show.key, maxAge: 30 * 86_400) { return cached }
        guard let tmdb else { return DemoData.detail(show) }
        do {
            let detail = try await tmdb.detail(show, region: config.watchRegion)
            await cache.save(detail)
            return detail
        } catch {
            return nil
        }
    }

    /// Adds the IMDb ID (needed by AIOStreams) to a ref that came from a TMDB list.
    func withIMDb(_ ref: TitleRef) async -> TitleRef {
        guard ref.imdbID == nil, let detail = await detail(for: ref) else { return ref }
        var copy = ref
        copy.imdbID = detail.summary.ref.imdbID
        return copy
    }

    func episodes(showID: Int, season: Int) async -> [EpisodeSummary] {
        guard let tmdb else { return DemoData.episodes(season: season) }
        return (try? await tmdb.season(showID: showID, number: season)) ?? []
    }

    /// The episode after `ref`, skipping episodes that have not aired yet.
    func nextEpisode(after ref: TitleRef, now: Date = Date()) async -> NextEpisode? {
        guard ref.kind == .episode, let season = ref.season, let number = ref.episode else { return nil }
        let current = await episodes(showID: ref.tmdbID, season: season)
        var candidate = current.first { $0.number > number }
        var nextSeason = season
        if candidate == nil, let detail = await detail(for: ref) {
            let seasons = detail.seasons.map(\.number).filter { $0 > season }.sorted()
            if let following = seasons.first {
                nextSeason = following
                candidate = await episodes(showID: ref.tmdbID, season: following).first
            }
        }
        guard let candidate, (candidate.airDate ?? .distantPast) <= now else { return nil }
        let next = TitleRef.episode(showTMDBID: ref.tmdbID, imdbID: ref.imdbID, season: candidate.season, episode: candidate.number)
        _ = nextSeason
        return NextEpisode(ref: next, title: "S\(candidate.season) E\(candidate.number)  \(candidate.name)")
    }

    /// Summary for a stored title key (watchlist, history, Continue Watching).
    func summary(forKey key: String) async -> TitleSummary? {
        guard let ref = TitleRef(key: key) else { return nil }
        return await detail(for: ref)?.summary
    }

    /// Smart Resume: the unfinished episode, else the one after the last finished, else S1E1.
    func resumeTarget(showID: Int, imdbID: String?) async -> (ref: TitleRef, progress: ProgressSnapshot?)? {
        if let latest = await progress.latestEpisode(forShow: showID), let ref = TitleRef(key: latest.titleKey, imdbID: imdbID) {
            if !latest.isCompleted { return (ref, latest) }
            if let next = await nextEpisode(after: ref) { return (next.ref, nil) }
            return nil
        }
        let detail = await detail(for: .show(tmdbID: showID, imdbID: imdbID))
        let first = detail?.seasons.map(\.number).filter { $0 > 0 }.min() ?? 1
        guard let episode = await episodes(showID: showID, season: first).first else { return nil }
        return (.episode(showTMDBID: showID, imdbID: imdbID, season: episode.season, episode: episode.number), nil)
    }
}
