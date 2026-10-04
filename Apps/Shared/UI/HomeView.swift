import LanternaKit
import SwiftUI
import os

struct ContinueItem: Identifiable {
    var snapshot: ProgressSnapshot
    var ref: TitleRef
    var summary: TitleSummary
    var subtitle: String?
    var id: String { snapshot.titleKey }
}

struct HomeShelf: Identifiable {
    var id: String
    var title: String
    var items: [TitleSummary]
}

@MainActor
@Observable
final class HomeModel {
    var continueItems: [ContinueItem] = []
    var shelves: [HomeShelf] = []
    var isLoading = true
    var loadedRevision = -1

    func load(env: AppEnvironment) async {
        isLoading = shelves.isEmpty
        await loadContinue(env: env)
        await loadShelves(env: env)
        loadedRevision = env.revision
        isLoading = false
    }

    func loadContinue(env: AppEnvironment) async {
        let snapshots = await env.progress.continueWatching(limit: 12)
        var items: [ContinueItem] = []
        for snapshot in snapshots {
            guard let ref = TitleRef(key: snapshot.titleKey), let detail = await env.detail(for: ref) else { continue }
            var subtitle: String?
            if ref.kind == .episode, let s = ref.season, let e = ref.episode { subtitle = "S\(s) E\(e)" }
            items.append(ContinueItem(snapshot: snapshot, ref: ref, summary: detail.summary, subtitle: subtitle))
        }
        Logger(subsystem: "lanterna", category: "home").info("continue snapshots=\(snapshots.count) items=\(items.count)")
        continueItems = items
    }

    func loadShelves(env: AppEnvironment) async {
        guard env.tmdb != nil else {
            shelves = DemoData.shelves().map { HomeShelf(id: $0.title, title: $0.title, items: $0.items) }
            return
        }
        let sources = await env.registry.sources(of: .tmdb)
        guard let tmdb = sources.first else { return }
        let descriptors: [CatalogDescriptor]
        if env.config.shelves.isEmpty {
            descriptors = ((try? await tmdb.catalogs()) ?? []).filter { ["trending-movie", "trending-show", "popular-movie", "popular-show", "top_rated-movie"].contains($0.id) }
        } else {
            let all = (try? await tmdb.catalogs()) ?? []
            descriptors = env.config.shelves.filter { !$0.isHidden }.compactMap { shelf in
                if case .preset(let id) = shelf.query { return all.first { $0.id == id } }
                return nil
            }
        }
        var result: [HomeShelf] = []
        await withTaskGroup(of: (Int, HomeShelf?).self) { group in
            for (index, descriptor) in descriptors.enumerated() {
                group.addTask {
                    guard let page = try? await tmdb.catalogPage(descriptor, cursor: nil), !page.items.isEmpty else { return (index, nil) }
                    return (index, HomeShelf(id: descriptor.id, title: descriptor.title, items: page.items))
                }
            }
            var ordered: [(Int, HomeShelf)] = []
            for await (index, shelf) in group { if let shelf { ordered.append((index, shelf)) } }
            result = ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
        shelves = result
    }
}

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayFlow.self) private var flow
    @Environment(PlaybackController.self) private var playback
    @State private var model = HomeModel()
    @State private var path: [TitleSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !env.hasAnySource {
                    FirstRunView()
                } else {
                    content
                }
            }
            .navigationDestination(for: TitleSummary.self) { DetailView(summary: $0) }
        }
        .task(id: env.revision) { await model.load(env: env) }
        .onChange(of: playback.presented == nil) { _, closed in
            if closed { Task { await model.loadContinue(env: env) } }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if env.isDemo {
                    NavigationLink(destination: SettingsView()) {
                        Label("Add a TMDB token in Settings to see real titles", systemImage: "key")
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                if !model.continueItems.isEmpty { continueRow }
                ForEach(model.shelves) { shelf in
                    ShelfRow(title: shelf.title, items: shelf.items) { path.append($0) }
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 20)
        }
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue Watching").font(.title3.bold()).padding(.leading, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.rowSpacing) {
                    ForEach(model.continueItems) { item in
                        Button {
                            Task { await flow.start(ref: item.ref, displayTitle: item.summary.title, forcePicker: false, env: env) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RemoteImage(url: TMDBImage.url(item.summary.backdropPath ?? item.summary.posterPath, .backdrop), placeholder: item.summary.title)
                                    .frame(width: Metrics.still.width, height: Metrics.still.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottom) { ProgressBar(fraction: item.snapshot.fraction).padding(10) }
                                Text(item.summary.title).font(.caption).lineLimit(1)
                                Text([item.subtitle, remaining(item.snapshot)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: Metrics.still.width, alignment: .leading)
                        }
                        .cardButtonStyle()
                        .accessibilityIdentifier("continue.\(item.id)")
                        .contextMenu {
                            Button("Open details") { path.append(item.summary) }
                            Button("Remove from Continue Watching", role: .destructive) {
                                Task {
                                    await env.progress.hide(titleKey: item.id, until: Date().addingTimeInterval(30 * 86_400))
                                    await model.loadContinue(env: env)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 24)
            }
        }
        .focusSectionIfTV()
    }

    private func remaining(_ snapshot: ProgressSnapshot) -> String? {
        let left = Int((snapshot.durationSeconds - snapshot.positionSeconds) / 60)
        return left > 0 ? "\(left)m left" : nil
    }
}

struct FirstRunView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 32) {
            Text("Welcome to Lanterna").font(.largeTitle.bold()).accessibilityIdentifier("firstrun.title")
            Text("Add a source to get started. AIOStreams gives you streams, TMDB gives you titles and artwork.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
            NavigationLink("Open Settings") { SettingsView() }
            NavigationLink("Pair with iPhone") { PairingReceiverView() }
        }
        .padding(Metrics.gutter)
    }
}
