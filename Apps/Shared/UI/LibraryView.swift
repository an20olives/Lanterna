import LanternaKit
import SwiftUI

@MainActor
@Observable
final class LibraryModel {
    var watchlist: [TitleSummary] = []
    var favorites: [TitleSummary] = []
    var history: [TitleSummary] = []

    func load(env: AppEnvironment) async {
        watchlist = await summaries(await env.library.titleKeys(.watchlist), env: env)
        favorites = await summaries(await env.library.titleKeys(.favorite), env: env)
        history = await summaries(await env.progress.history(limit: 40).map(\.titleKey), env: env)
    }

    private func summaries(_ keys: [String], env: AppEnvironment) async -> [TitleSummary] {
        var result: [TitleSummary] = []
        var seen = Set<String>()
        for key in keys {
            guard let summary = await env.summary(forKey: key), seen.insert(summary.id).inserted else { continue }
            result.append(summary)
        }
        return result
    }
}

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = LibraryModel()
    @State private var path: [TitleSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if env.hasTorBox || env.config.sources.contains(where: { $0.kind == .jellyfin }) {
                        NavigationLink(destination: MediaLibraryView()) { Label("Media Library", systemImage: "externaldrive") }
                            .padding(.horizontal, Metrics.gutter)
                    }
                    section("Watchlist", model.watchlist, empty: "Add titles with the plus button on a detail page.")
                    section("Favorites", model.favorites, empty: "Tap the heart on a detail page.")
                    section("History", model.history, empty: "Finished titles show up here.")
                    ComingSoonSection(path: $path)
                }
                .padding(.vertical, 20)
            }
            .lanternaDestinations()
        }
        .task(id: env.revision) { await model.load(env: env) }
    }

    @ViewBuilder private func section(_ title: String, _ items: [TitleSummary], empty: String) -> some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.bold())
                Text(empty).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.gutter)
        } else {
            ShelfRow(title: title, items: items) { path.append($0) }
        }
    }
}

/// Episodes airing in the next 14 days for shows on the watchlist or in progress.
struct ComingSoonSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var path: [TitleSummary]
    @State private var upcoming: [(date: Date, label: String, summary: TitleSummary)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coming Soon").font(.title3.bold())
            if upcoming.isEmpty {
                Text("Nothing airing in the next 14 days.").foregroundStyle(.secondary)
            } else {
                ForEach(upcoming.indices, id: \.self) { index in
                    let item = upcoming[index]
                    Button { path.append(item.summary) } label: {
                        HStack {
                            Text(item.date.formatted(.dateTime.weekday(.wide).month().day()))
                            Spacer()
                            Text("\(item.summary.title)  \(item.label)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .task(id: env.revision) { await load() }
    }

    private func load() async {
        guard env.tmdb != nil else { return }
        let watchlistKeys = await env.library.titleKeys(.watchlist)
        let progressKeys = await env.progress.continueWatching(limit: 20).compactMap { $0.showTMDBID.map { "show:\($0)" } }
        let showKeys = Array(Set(watchlistKeys.filter { $0.hasPrefix("show:") } + progressKeys))
        let now = Date()
        let horizon = now.addingTimeInterval(14 * 86_400)
        var found: [(Date, String, TitleSummary)] = []
        for key in showKeys.prefix(15) {
            guard let ref = TitleRef(key: key), let detail = await env.detail(for: ref), let season = detail.seasons.map(\.number).max() else { continue }
            for episode in await env.episodes(showID: ref.tmdbID, season: season) {
                if let air = episode.airDate, air >= now.addingTimeInterval(-86_400), air <= horizon {
                    found.append((air, "S\(episode.season) E\(episode.number)", detail.summary))
                }
            }
        }
        upcoming = found.sorted { $0.0 < $1.0 }.map { (date: $0.0, label: $0.1, summary: $0.2) }
    }
}

struct MediaLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayFlow.self) private var flow
    @State private var items: [(item: OwnedItem, source: SourceKind)] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selected: OwnedItem?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(items, id: \.item.id) { entry in
                Button {
                    if entry.item.files.count == 1 { play(entry.item.files[0], entry.item, entry.source) } else { selected = entry.item }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.item.title).lineLimit(1)
                            if let status = entry.item.statusText { Text(status).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(formatSize(entry.item.sizeBytes) ?? "").foregroundStyle(.secondary)
                    }
                }
                .disabled(!entry.item.isReady || entry.item.files.isEmpty)
            }
            if isLoading { ProgressView() }
        }
        .navigationTitle("Media Library")
        .sheet(item: $selected) { item in
            NavigationStack {
                List(item.files) { file in
                    Button(file.name) { selected = nil; play(file, item, item.id.hasPrefix("jf") ? .jellyfin : .torbox) }
                }
                .navigationTitle(item.title)
            }
        }
        .task(id: env.revision) { await load() }
    }

    private func load() async {
        isLoading = true
        var all: [(OwnedItem, SourceKind)] = []
        for source in await env.registry.sources(with: .library) {
            do {
                var cursor: PageCursor?
                repeat {
                    let page = try await source.libraryPage(cursor: cursor)
                    all += page.items.map { ($0, source.kind) }
                    cursor = page.next
                } while cursor != nil && all.count < 500
            } catch SourceError.needsCredentials {
                error = "\(source.displayName) rejected its login."
            } catch {
                self.error = "\(source.displayName) could not be reached."
            }
        }
        items = all.map { (item: $0.0, source: $0.1) }
        isLoading = false
    }

    private func play(_ file: LibraryFile, _ item: OwnedItem, _ kind: SourceKind) {
        let ref = item.matched ?? syntheticRef(file.id)
        Task {
            await flow.playLibraryFile(file.locatorHint, sourceID: item.sourceID, kind: kind, name: file.name, ref: ref, env: env)
        }
    }

    /// Unmatched files get a negative TMDB ID so their progress never collides with a real title.
    private func syntheticRef(_ id: String) -> TitleRef {
        var hash = 5381
        for scalar in id.unicodeScalars { hash = (hash &* 33) &+ Int(scalar.value) }
        return .movie(tmdbID: -(abs(hash) % 1_000_000_000) - 1, imdbID: nil)
    }
}
