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

struct HomeShelf: Identifiable, Hashable {
    var id: String
    var title: String
    var items: [TitleSummary]
    /// Set for TMDB preset shelves so See All can page the same catalog.
    var seeAllCatalog: String?
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

    var heroItems: [TitleSummary] = []

    func loadShelves(env: AppEnvironment) async {
        guard env.tmdb != nil, let tmdb = env.tmdb, let source = await env.registry.sources(of: .tmdb).first else {
            shelves = DemoData.shelves().map { HomeShelf(id: $0.title, title: $0.title, items: $0.items) }
            heroItems = Array((shelves.first?.items ?? []).prefix(5))
            return
        }
        let catalogs = (try? await source.catalogs()) ?? []
        let configs = env.effectiveShelves.filter { !$0.isHidden }
        var loaded: [(Int, HomeShelf)] = []
        await withTaskGroup(of: (Int, HomeShelf?).self) { group in
            for (index, shelf) in configs.enumerated() {
                switch shelf.query {
                case .preset(let id):
                    guard let descriptor = catalogs.first(where: { $0.id == id }) else { continue }
                    group.addTask {
                        guard let page = try? await source.catalogPage(descriptor, cursor: nil), !page.items.isEmpty else { return (index, nil) }
                        return (index, HomeShelf(id: shelf.id.uuidString, title: shelf.title, items: page.items, seeAllCatalog: id))
                    }
                case .discover(let filters):
                    group.addTask {
                        guard let page = try? await tmdb.discover(kind: filters.kind, filters: filters.parameters), !page.items.isEmpty else { return (index, nil) }
                        return (index, HomeShelf(id: shelf.id.uuidString, title: shelf.title, items: page.items))
                    }
                case .tmdbList(let id):
                    group.addTask {
                        guard let items = try? await tmdb.list(id: id), !items.isEmpty else { return (index, nil) }
                        return (index, HomeShelf(id: shelf.id.uuidString, title: shelf.title, items: items))
                    }
                default:
                    continue
                }
            }
            for await (index, shelf) in group { if let shelf { loaded.append((index, shelf)) } }
        }
        // Trakt lists need the signed-in client, which lives on the main actor.
        for (index, shelf) in configs.enumerated() {
            guard case .traktList(let path) = shelf.query else { continue }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2, let client = env.traktClient(authorized: env.secret(.traktAccessToken) != nil),
                  let entries = try? await client.listItems(user: parts[0], slug: parts[1]) else { continue }
            var items: [TitleSummary] = []
            for entry in entries.prefix(24) { if let summary = await env.summary(forKey: entry.ref.key) { items.append(summary) } }
            if !items.isEmpty { loaded.append((index, HomeShelf(id: shelf.id.uuidString, title: shelf.title, items: items))) }
        }
        shelves = loaded.sorted { $0.0 < $1.0 }.map(\.1)
        heroItems = Array((shelves.first?.items ?? []).filter { $0.backdropPath != nil }.prefix(6))
    }
}

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayFlow.self) private var flow
    @Environment(PlaybackController.self) private var playback
    @State private var model = HomeModel()
    @State private var path: [TitleSummary] = []
    @State private var seeAll: HomeShelf?
    @State private var atTop = true
    #if os(tvOS)
    @Namespace private var homeScope
    @Environment(\.resetFocus) private var resetFocus
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !env.hasAnySource {
                    FirstRunView()
                } else {
                    content
                }
            }
            .lanternaDestinations()
            .navigationDestination(item: $seeAll) { SeeAllView(shelf: $0) }
        }
        .task(id: env.revision) { await model.load(env: env) }
        .onChange(of: playback.presented == nil) { _, closed in
            if closed { Task { await model.loadContinue(env: env) } }
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            scrollContent
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y < 24 } action: { _, new in atTop = new }
                #if os(tvOS)
                .focusScope(homeScope)
                // Menu deep in a shelf goes back to the top of Home; at the top it falls through and leaves the app.
                .onExitCommand(perform: atTop ? nil : {
                    withAnimation { proxy.scrollTo("home.top", anchor: .top) }
                    resetFocus(in: homeScope)
                })
                #endif
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                Color.clear.frame(height: 1).id("home.top")
                if env.isDemo {
                    NavigationLink(destination: SettingsView()) {
                        Label("Add a TMDB token in Settings to see real titles", systemImage: "key")
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                if env.config.heroEnabled, !model.heroItems.isEmpty {
                    HeroCarousel(items: model.heroItems, onDetails: { path.append($0) }, onPlay: { item in
                        Task { await flow.start(ref: item.ref, displayTitle: item.title, forcePicker: false, env: env) }
                    })
                }
                if !model.continueItems.isEmpty { continueRow }
                ForEach(model.shelves) { shelf in
                    ShelfRow(title: shelf.title, items: shelf.items, onSelect: { path.append($0) }, onSeeAll: shelf.seeAllCatalog == nil ? nil : { seeAll = shelf })
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
                .padding(.vertical, Metrics.rowPadding)
            }
            .scrollClipDisabled()
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
