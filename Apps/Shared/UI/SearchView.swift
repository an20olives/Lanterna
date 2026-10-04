import LanternaKit
import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var results = SearchResults(titles: [], people: [])
    @State private var isSearching = false
    @State private var recents: [String] = SearchView.loadRecents()
    @State private var path: [TitleSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if env.isDemo {
                        Text("Search needs a TMDB token. Add one in Settings.").foregroundStyle(.secondary).padding(.horizontal, Metrics.gutter)
                    } else if query.trimmingCharacters(in: .whitespaces).count < 3 {
                        recentsView
                    } else if isSearching && results.titles.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if results.titles.isEmpty && results.people.isEmpty {
                        Text("No results").foregroundStyle(.secondary).padding(.horizontal, Metrics.gutter)
                    } else {
                        let movies = results.titles.filter { $0.ref.kind == .movie }
                        let shows = results.titles.filter { $0.ref.kind == .show }
                        if !movies.isEmpty { ShelfRow(title: "Movies", items: movies) { select($0) } }
                        if !shows.isEmpty { ShelfRow(title: "Shows", items: shows) { select($0) } }
                        if !results.people.isEmpty { peopleRow }
                    }
                }
                .padding(.vertical, 20)
            }
            .searchable(text: $query, prompt: "Movies, shows and people")
            .lanternaDestinations()
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, let tmdb = env.tmdb else { results = SearchResults(titles: [], people: []); return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            results = (try? await tmdb.search(trimmed)) ?? SearchResults(titles: [], people: [])
            isSearching = false
        }
    }

    private var recentsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !recents.isEmpty {
                Text("Recent").font(.title3.bold())
                ForEach(recents, id: \.self) { term in
                    Button(term) { query = term }
                }
            } else {
                Text("Type at least three letters.").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast").font(.title3.bold()).padding(.leading, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.rowSpacing) {
                    ForEach(results.people) { person in
                        NavigationLink(value: PersonRoute(id: person.id, name: person.name, profilePath: person.profilePath)) {
                            VStack {
                                RemoteImage(url: TMDBImage.url(person.profilePath, .profile), placeholder: person.name)
                                    .frame(width: 110, height: 110).clipShape(Circle())
                                Text(person.name).font(.caption).lineLimit(1)
                            }
                            .frame(width: 130)
                        }
                        .cardButtonStyle()
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
        }
    }

    private func select(_ summary: TitleSummary) {
        remember(query)
        path.append(summary)
    }

    private func remember(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return }
        recents = Array(([trimmed] + recents.filter { $0 != trimmed }).prefix(8))
        UserDefaults.standard.set(recents, forKey: "lanterna.recentSearches")
    }

    static func loadRecents() -> [String] { UserDefaults.standard.stringArray(forKey: "lanterna.recentSearches") ?? [] }
}
