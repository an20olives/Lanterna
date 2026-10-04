import LanternaKit
import SwiftUI

struct PersonRoute: Hashable {
    var id: Int
    var name: String
    var profilePath: String?
}

extension View {
    /// Titles and people open from anywhere in a tab's stack.
    func lanternaDestinations() -> some View {
        self
            .navigationDestination(for: TitleSummary.self) { DetailView(summary: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
    }
}

struct PersonView: View {
    @Environment(AppEnvironment.self) private var env
    let route: PersonRoute
    @State private var person: PersonDetail?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                HStack(alignment: .top, spacing: 30) {
                    RemoteImage(url: TMDBImage.url(person?.profilePath ?? route.profilePath, .profile), placeholder: route.name)
                        .frame(width: 200, height: 300).clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(route.name).font(.largeTitle.bold())
                        let facts = [person?.birthday.map { "Born \($0)" }, person?.birthplace].compactMap { $0 }.joined(separator: " · ")
                        if !facts.isEmpty { Text(facts).foregroundStyle(.secondary) }
                        if let bio = person?.biography { Text(bio).lineLimit(8).frame(maxWidth: 1000, alignment: .leading) }
                        else if !loading { Text(env.isDemo ? "Add a TMDB token to load profiles." : "No biography available.").foregroundStyle(.secondary) }
                    }
                }
                if let credits = person?.credits, !credits.isEmpty {
                    Text("Known for").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.poster.width), spacing: Metrics.rowSpacing)], alignment: .leading, spacing: Metrics.rowSpacing) {
                        ForEach(credits.prefix(60)) { item in
                            NavigationLink(value: item) { PosterGridCell(summary: item) }.cardButtonStyle()
                        }
                    }
                    .focusSectionIfTV()
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 30)
        }
        .task {
            if let tmdb = env.tmdb { person = try? await tmdb.person(id: route.id) }
            loading = false
        }
    }
}
