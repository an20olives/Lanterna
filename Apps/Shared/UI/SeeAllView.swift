import LanternaKit
import SwiftUI

struct SeeAllView: View {
    enum Sort: String, CaseIterable { case standard = "Default", title = "Title", year = "Year", rating = "Rating" }

    @Environment(AppEnvironment.self) private var env
    let shelf: HomeShelf
    @State private var items: [TitleSummary] = []
    @State private var cursor: PageCursor?
    @State private var loading = false
    @State private var sort: Sort = .standard
    @State private var path: [TitleSummary] = []

    private var sorted: [TitleSummary] {
        switch sort {
        case .standard: items
        case .title: items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .year: items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: items.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(shelf.title).font(.title2.bold())
                    Spacer()
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                }
                .padding(.horizontal, Metrics.gutter)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.poster.width), spacing: Metrics.rowSpacing)], alignment: .leading, spacing: Metrics.rowSpacing) {
                    ForEach(sorted) { item in
                        NavigationLink(value: item) { PosterGridCell(summary: item) }
                            .cardButtonStyle()
                            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 20)
        }
        .navigationDestination(for: TitleSummary.self) { DetailView(summary: $0) }
        .task { items = shelf.items; await loadMore(first: true) }
    }

    private func loadMore(first: Bool = false) async {
        guard !loading else { return }
        if !first, cursor == nil { return }
        loading = true
        defer { loading = false }
        guard let tmdb = await env.registry.sources(of: .tmdb).first,
              let descriptor = (try? await tmdb.catalogs())?.first(where: { $0.id == shelf.id }) else { return }
        let start = first ? PageCursor("2") : cursor
        guard let page = try? await tmdb.catalogPage(descriptor, cursor: start) else { return }
        let known = Set(items.map(\.id))
        items += page.items.filter { !known.contains($0.id) }
        cursor = page.next
    }
}

struct PosterGridCell: View {
    let summary: TitleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: TMDBImage.url(summary.posterPath, .poster), placeholder: summary.title)
                .frame(width: Metrics.poster.width, height: Metrics.poster.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(summary.title).font(.caption).lineLimit(1).frame(width: Metrics.poster.width, alignment: .leading)
        }
    }
}
