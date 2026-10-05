import LanternaKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class DetailModel {
    var detail: TitleDetail?
    var isLoading = true
    var selectedSeason = 1
    var episodes: [EpisodeSummary] = []
    var episodeProgress: [String: ProgressSnapshot] = [:]
    var resume: (ref: TitleRef, progress: ProgressSnapshot?)?
    var inWatchlist = false
    var isFavorite = false
    var offers: [ProviderOffer] = []

    func load(summary: TitleSummary, env: AppEnvironment) async {
        let ref = summary.ref
        detail = await env.detail(for: ref)
        isLoading = false
        let key = ref.key
        inWatchlist = await env.library.contains(.watchlist, titleKey: key)
        isFavorite = await env.library.contains(.favorite, titleKey: key)
        offers = await env.availability(for: ref)
        if ref.kind == .show, let detail {
            let imdb = detail.summary.ref.imdbID
            resume = await env.resumeTarget(showID: ref.tmdbID, imdbID: imdb)
            selectedSeason = resume?.ref.season ?? detail.seasons.map(\.number).filter { $0 > 0 }.min() ?? 1
            await loadEpisodes(env: env)
        }
    }

    func loadEpisodes(env: AppEnvironment) async {
        guard let detail else { return }
        let showID = detail.summary.ref.tmdbID
        episodes = await env.episodes(showID: showID, season: selectedSeason)
        var map: [String: ProgressSnapshot] = [:]
        for episode in episodes {
            let key = TitleRef.episode(showTMDBID: showID, imdbID: nil, season: episode.season, episode: episode.number).key
            if let snapshot = await env.progress.progress(for: key) { map[key] = snapshot }
        }
        episodeProgress = map
    }

    func markWatched(_ refs: [TitleRef], runtimeMinutes: Int?, env: AppEnvironment) async {
        for ref in refs {
            let duration = Double(runtimeMinutes ?? 45) * 60
            await env.progress.markWatched(titleKey: ref.key, showTMDBID: ref.kind == .episode ? ref.tmdbID : nil, duration: duration)
            await env.enqueueListOp("historyAdd", ref: ref)
        }
        if detail?.summary.ref.kind == .show { await loadEpisodes(env: env) }
    }

    func toggle(_ kind: LibraryKind, ref: TitleRef, env: AppEnvironment) async {
        let key = ref.showRef.key
        let has = await env.library.contains(kind, titleKey: key)
        if has { await env.library.remove(kind, titleKey: key) } else { await env.library.add(kind, titleKey: key) }
        if kind == .watchlist {
            inWatchlist = !has
            await env.enqueueListOp(has ? "watchlistRemove" : "watchlistAdd", ref: ref.showRef)
        } else {
            isFavorite = !has
        }
    }
}

struct DetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayFlow.self) private var flow
    let summary: TitleSummary
    @State private var model = DetailModel()
    @State private var trailerMessage: String?

    private var ref: TitleRef { summary.ref }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    header
                    actions
                    if ref.kind == .show { episodesSection }
                    if !model.offers.isEmpty { providersRow }
                    if let trailers = model.detail?.trailers, !trailers.isEmpty { trailersRow(trailers) }
                    if let cast = model.detail?.cast, !cast.isEmpty { castRow(cast) }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 30)
            }
        }
        .task { await model.load(summary: summary, env: env) }
        .navigationTitle(summary.title)
        #if os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var backdrop: some View {
        RemoteImage(url: TMDBImage.url(summary.backdropPath, .backdrop), placeholder: "")
            .ignoresSafeArea()
            .overlay(LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.55), .black.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
            .overlay(LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let logo = model.detail?.logoPath, let url = TMDBImage.url(logo, .poster) {
                AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { titleText }
                    .frame(maxWidth: 520, maxHeight: 140, alignment: .leading)
            } else {
                titleText
            }
            let detail = model.detail
            let line = [summary.year.map(String.init), detail?.certification, formatRuntime(detail?.runtimeMinutes)].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty { Text(line).foregroundStyle(.secondary) }
            if let genres = detail?.genres, !genres.isEmpty { Text(genres.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary) }
            if let overview = detail?.summary.overview ?? summary.overview {
                Text(overview).lineLimit(4).frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    private var titleText: some View { Text(summary.title).font(.largeTitle.bold()) }

    private var actions: some View {
        HStack(spacing: 20) {
            Button {
                Task { await play() }
            } label: {
                Label(playLabel, systemImage: "play.fill")
            }
            .accessibilityIdentifier("detail.play")
            Button { Task { await model.toggle(.watchlist, ref: ref, env: env) } } label: {
                Image(systemName: model.inWatchlist ? "checkmark" : "plus")
            }
            .accessibilityLabel(model.inWatchlist ? "Remove from watchlist" : "Add to watchlist")
            Button { Task { await model.toggle(.favorite, ref: ref, env: env) } } label: {
                Image(systemName: model.isFavorite ? "heart.fill" : "heart")
            }
            .accessibilityLabel("Favorite")
            if ref.kind == .movie || model.resume != nil {
                Button("Choose Stream") { Task { await play(forcePicker: true) } }
            }
            if ref.kind == .movie {
                Button("Mark Watched") { Task { await model.markWatched([ref], runtimeMinutes: model.detail?.runtimeMinutes, env: env) } }
            }
        }
    }

    private var playLabel: String {
        if ref.kind == .movie { return "Play" }
        if let resume = model.resume?.ref, let s = resume.season, let e = resume.episode {
            return (model.resume?.progress != nil ? "Resume" : "Play") + " S\(s) E\(e)"
        }
        return "Play"
    }

    private func play(forcePicker: Bool = false) async {
        if ref.kind == .movie {
            await flow.start(ref: ref, displayTitle: summary.title, forcePicker: forcePicker, env: env)
        } else if let target = model.resume?.ref {
            await flow.start(ref: target, displayTitle: "\(summary.title) S\(target.season ?? 0) E\(target.episode ?? 0)", forcePicker: forcePicker, env: env)
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let seasons = model.detail?.seasons, seasons.count > 1 {
                HRow {
                    HStack {
                        ForEach(seasons) { season in
                            Button(season.name) {
                                model.selectedSeason = season.number
                                Task { await model.loadEpisodes(env: env) }
                            }
                            .tint(season.number == model.selectedSeason ? Theme.accent : nil)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .focusSectionIfTV()
            }
            HRow {
                LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                    ForEach(model.episodes) { episode in
                        episodeCard(episode)
                    }
                }
                .padding(.vertical, Metrics.rowPadding)
            }
            .focusSectionIfTV()
        }
    }

    private func episodeCard(_ episode: EpisodeSummary) -> some View {
        let key = TitleRef.episode(showTMDBID: ref.tmdbID, imdbID: nil, season: episode.season, episode: episode.number).key
        let progress = model.episodeProgress[key]
        let unaired = (episode.airDate ?? .distantPast) > Date()
        return Button {
            let target = TitleRef.episode(showTMDBID: ref.tmdbID, imdbID: model.detail?.summary.ref.imdbID, season: episode.season, episode: episode.number)
            Task { await flow.start(ref: target, displayTitle: "\(summary.title) S\(episode.season) E\(episode.number)", forcePicker: false, env: env) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: TMDBImage.url(episode.stillPath, .still), placeholder: episode.name)
                    .frame(width: Metrics.still.width, height: Metrics.still.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) { if let progress, !progress.isCompleted { ProgressBar(fraction: progress.fraction).padding(8) } }
                    .overlay(alignment: .topTrailing) { if progress?.isCompleted == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).padding(8) } }
                Text("\(episode.number). \(episode.name)").font(.caption).lineLimit(1)
                Text(unaired ? "Airs \(episode.airDate?.formatted(date: .abbreviated, time: .omitted) ?? "soon")" : (formatRuntime(episode.runtimeMinutes) ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: Metrics.still.width, alignment: .leading)
        }
        .cardButtonStyle()
        .disabled(unaired)
        .contextMenu {
            Button("Mark as watched") {
                let target = TitleRef.episode(showTMDBID: ref.tmdbID, imdbID: model.detail?.summary.ref.imdbID, season: episode.season, episode: episode.number)
                Task { await model.markWatched([target], runtimeMinutes: episode.runtimeMinutes, env: env) }
            }
            Button("Mark up to here") {
                let targets = model.episodes.filter { $0.number <= episode.number && ($0.airDate ?? .distantPast) <= Date() }.map {
                    TitleRef.episode(showTMDBID: ref.tmdbID, imdbID: model.detail?.summary.ref.imdbID, season: $0.season, episode: $0.number)
                }
                Task { await model.markWatched(targets, runtimeMinutes: episode.runtimeMinutes, env: env) }
            }
            if progress != nil {
                Button("Mark as unwatched", role: .destructive) {
                    Task { await env.progress.markUnwatched(titleKey: key); await model.loadEpisodes(env: env) }
                }
            }
        }
    }

    private var providersRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to watch").font(.title3.bold())
            ServiceCards(ref: ref)
        }
    }

    private func castRow(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast").font(.title3.bold())
            HRow {
                LazyHStack(spacing: Metrics.rowSpacing) {
                    ForEach(cast.prefix(12)) { member in
                        NavigationLink(value: PersonRoute(id: member.id, name: member.name, profilePath: member.profilePath)) {
                            VStack {
                                RemoteImage(url: TMDBImage.url(member.profilePath, .profile), placeholder: member.name)
                                    .frame(width: 110, height: 110).clipShape(Circle())
                                Text(member.name).font(.caption).lineLimit(1)
                                Text(member.character ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 130)
                        }
                        .cardButtonStyle()
                    }
                }
            }
        }
    }

    private func trailersRow(_ trailers: [Trailer]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trailers").font(.title3.bold())
            HRow {
                LazyHStack(spacing: Metrics.rowSpacing) {
                    ForEach(trailers.prefix(6)) { trailer in
                        Button { openTrailer(trailer) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RemoteImage(url: URL(string: "https://img.youtube.com/vi/\(trailer.youtubeKey)/hqdefault.jpg"), placeholder: trailer.name)
                                    .frame(width: Metrics.still.width, height: Metrics.still.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.9)))
                                Text(trailer.name).font(.caption).lineLimit(1).frame(width: Metrics.still.width, alignment: .leading)
                            }
                        }
                        .cardButtonStyle()
                    }
                }
                .padding(.vertical, Metrics.rowPadding)
            }
            .focusSectionIfTV()
            if let trailerMessage { Text(trailerMessage).font(.callout).foregroundStyle(.orange) }
        }
    }

    /// Trailers live on YouTube. tvOS has no browser, so it hands off to the YouTube app when it is installed.
    private func openTrailer(_ trailer: Trailer) {
        let app = URL(string: "youtube://www.youtube.com/watch?v=\(trailer.youtubeKey)")!
        let web = URL(string: "https://www.youtube.com/watch?v=\(trailer.youtubeKey)")!
        Task {
            if await UIApplication.shared.open(app) { trailerMessage = nil; return }
            #if os(tvOS)
            trailerMessage = "Install the YouTube app on this Apple TV to watch trailers."
            #else
            if !(await UIApplication.shared.open(web)) { trailerMessage = "Could not open the trailer." }
            #endif
        }
    }
}
