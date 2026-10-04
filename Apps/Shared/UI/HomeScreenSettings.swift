import LanternaKit
import SwiftUI

extension AppEnvironment {
    static let defaultShelves: [ShelfConfig] = [
        ShelfConfig(title: "Trending Movies", query: .preset("trending-movie")),
        ShelfConfig(title: "Trending Shows", query: .preset("trending-show")),
        ShelfConfig(title: "Popular Movies", query: .preset("popular-movie")),
        ShelfConfig(title: "Popular Shows", query: .preset("popular-show")),
        ShelfConfig(title: "Top Rated Movies", query: .preset("top_rated-movie")),
    ]

    /// The shelves Home actually shows: the owner's list, or the defaults.
    var effectiveShelves: [ShelfConfig] { config.shelves.isEmpty ? Self.defaultShelves : config.shelves }
}

struct HomeScreenSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                Toggle("Featured strip at the top", isOn: Binding(get: { env.config.heroEnabled }, set: { v in env.updateConfig { $0.heroEnabled = v } }))
            }
            Section("Shelves (\(env.effectiveShelves.count) of \(DeviceConfig.maxShelves))") {
                ForEach(env.effectiveShelves) { shelf in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(shelf.title).foregroundStyle(shelf.isHidden ? .secondary : .primary)
                            Text(describe(shelf.query)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(shelf, -1) } label: { Image(systemName: "arrow.up") }
                        Button { move(shelf, 1) } label: { Image(systemName: "arrow.down") }
                        Button { toggleHidden(shelf) } label: { Image(systemName: shelf.isHidden ? "eye.slash" : "eye") }
                        Button(role: .destructive) { remove(shelf) } label: { Image(systemName: "trash") }
                    }
                }
                if env.effectiveShelves.count < DeviceConfig.maxShelves {
                    NavigationLink("Add a shelf") { AddShelfView() }
                } else {
                    Text("Twenty shelves is the limit. Remove one to add another.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset to the default shelves") { env.updateConfig { $0.shelves = [] } }
            }
        }
        .navigationTitle("Home screen")
    }

    private func describe(_ query: ShelfQuery) -> String {
        switch query {
        case .preset: "TMDB list"
        case .discover(let filters): "Filtered \(filters.kind == .movie ? "movies" : "shows")"
        case .tmdbList(let id): "TMDB list \(id)"
        case .traktList(let path): "Trakt list \(path)"
        case .jellyfinCollection: "Jellyfin collection"
        case .aiostreamsCatalog: "AIOStreams catalog"
        }
    }

    /// Edits start from the visible list so the defaults become the owner's own on first change.
    private func edit(_ change: (inout [ShelfConfig]) -> Void) {
        var shelves = env.effectiveShelves
        change(&shelves)
        env.updateConfig { $0.shelves = shelves }
    }

    private func move(_ shelf: ShelfConfig, _ delta: Int) {
        edit { shelves in
            guard let index = shelves.firstIndex(where: { $0.id == shelf.id }), shelves.indices.contains(index + delta) else { return }
            shelves.swapAt(index, index + delta)
        }
    }

    private func toggleHidden(_ shelf: ShelfConfig) {
        edit { shelves in
            if let index = shelves.firstIndex(where: { $0.id == shelf.id }) { shelves[index].isHidden.toggle() }
        }
    }

    private func remove(_ shelf: ShelfConfig) { edit { $0.removeAll { $0.id == shelf.id } } }
}

struct AddShelfView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var catalogs: [CatalogDescriptor] = []
    @State private var genres: [TMDBClient.Genre] = []
    @State private var title = ""
    @State private var filters = DiscoverFilters(kind: .movie)
    @State private var genre: Int?
    @State private var yearFrom = ""
    @State private var yearTo = ""
    @State private var rating = 0.0
    @State private var language = ""
    @State private var listID = ""
    @State private var traktPath = ""
    @State private var message: String?

    private let sorts = [("Popularity", "popularity.desc"), ("Rating", "vote_average.desc"), ("Newest", "primary_release_date.desc")]

    var body: some View {
        List {
            Section("From TMDB") {
                ForEach(catalogs) { catalog in
                    Button(catalog.title) { add(ShelfConfig(title: catalog.title, query: .preset(catalog.id))) }
                }
                if env.tmdb == nil { Text("Add a TMDB token in Settings to see the lists.").foregroundStyle(.secondary) }
            }
            Section("Filtered shelf") {
                TextField("Shelf name", text: $title)
                Picker("Kind", selection: $filters.kind) { Text("Movies").tag(TitleRef.Kind.movie); Text("Shows").tag(TitleRef.Kind.show) }.settingsPicker()
                Picker("Genre", selection: $genre) {
                    Text("Any").tag(Int?.none)
                    ForEach(genres) { Text($0.name).tag(Int?.some($0.id)) }
                }
                .settingsPicker()
                TextField("From year (optional)", text: $yearFrom)
                TextField("To year (optional)", text: $yearTo)
                Picker("Minimum rating", selection: $rating) {
                    Text("Any").tag(0.0)
                    ForEach([6.0, 7.0, 7.5, 8.0], id: \.self) { Text("\($0, specifier: "%.1f")+").tag($0) }
                }
                .settingsPicker()
                TextField("Original language, e.g. ja (optional)", text: $language).autocorrectionDisabled()
                Picker("Sort", selection: $filters.sort) { ForEach(sorts, id: \.1) { Text($0.0).tag($0.1) } }.settingsPicker()
                Button("Add filtered shelf") { addFiltered() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("From a public list") {
                TextField("TMDB list number", text: $listID)
                Button("Add TMDB list") {
                    guard let id = Int(listID) else { message = "Enter the list number."; return }
                    add(ShelfConfig(title: "TMDB list \(id)", query: .tmdbList(id)))
                }
                .disabled(listID.isEmpty)
                TextField("Trakt list as user/list-name", text: $traktPath).autocorrectionDisabled()
                Button("Add Trakt list") {
                    guard traktPath.split(separator: "/").count == 2 else { message = "Use the form user/list-name."; return }
                    add(ShelfConfig(title: traktPath, query: .traktList(traktPath)))
                }
                .disabled(traktPath.isEmpty)
            }
            if let message { Text(message).foregroundStyle(.orange) }
        }
        .navigationTitle("Add a shelf")
        .task {
            if let tmdb = await env.registry.sources(of: .tmdb).first { catalogs = (try? await tmdb.catalogs()) ?? [] }
            genres = (try? await env.tmdb?.genres(kind: filters.kind)) ?? []
        }
        .task(id: filters.kind) { genres = (try? await env.tmdb?.genres(kind: filters.kind)) ?? []; genre = nil }
    }

    private func addFiltered() {
        var f = filters
        f.genre = genre
        f.yearFrom = Int(yearFrom)
        f.yearTo = Int(yearTo)
        f.minRating = rating > 0 ? rating : nil
        f.language = language.isEmpty ? nil : language.lowercased()
        if f.kind == .show, f.sort == "primary_release_date.desc" { f.sort = "first_air_date.desc" }
        add(ShelfConfig(title: title, query: .discover(f)))
    }

    private func add(_ shelf: ShelfConfig) {
        var shelves = env.effectiveShelves
        guard shelves.count < DeviceConfig.maxShelves else { message = "Twenty shelves is the limit."; return }
        shelves.append(shelf)
        env.updateConfig { $0.shelves = shelves }
        dismiss()
    }
}
