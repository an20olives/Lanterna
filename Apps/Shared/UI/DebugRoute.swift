import LanternaKit
import SwiftUI

/// QA aid: `-route <name>` opens one screen directly, inside the real tab bar, so screenshots can be taken without driving the remote.
/// Names: tab/home, tab/library, tab/settings, tab/search, settings/<sources|services|pairing|streams|player|home|trakt|diagnostics>,
/// detail/movie/<tmdbID>, detail/show/<tmdbID>, person/<id>, picker/<movie tmdbID>.
enum DebugRoute {
    static var current: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-route"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func tab(_ route: String) -> AppTab? {
        switch route {
        case "tab/home": .home
        case "tab/library": .library
        case "tab/settings": .settings
        case "tab/search": .search
        default: nil
        }
    }
}

enum AppTab: Hashable { case home, library, settings, search, debug }

struct DebugRouteView: View {
    @Environment(AppEnvironment.self) private var env
    let route: String
    @State private var summary: TitleSummary?

    var body: some View {
        let parts = route.split(separator: "/").map(String.init)
        Group {
            switch (parts.first, parts.dropFirst().first) {
            case ("settings", "sources"?): SourcesSettingsView()
            case ("settings", "services"?): YourServicesView()
            case ("settings", "pairing"?): PairingReceiverView()
            case ("settings", "streams"?): StreamsSettingsView()
            case ("settings", "player"?): PlayerSettingsView()
            case ("settings", "home"?): HomeScreenSettingsView()
            case ("settings", "trakt"?): TraktSettingsView()
            case ("settings", "diagnostics"?): DiagnosticsView()
            case ("marquee", _):
                HStack(alignment: .top, spacing: 40) {
                    Button { } label: {
                        VStack(alignment: .leading) {
                            Color.gray.frame(width: Metrics.poster.width, height: Metrics.poster.height)
                            MarqueeText(text: "Come Home Love: Lo and Behold, The Very Long Title").frame(width: Metrics.poster.width, alignment: .leading)
                        }
                    }
                    .cardButtonStyle()
                    VStack(alignment: .leading) {
                        Color.gray.opacity(0.5).frame(width: Metrics.poster.width, height: Metrics.poster.height)
                        Text("Neighbour title that is also long enough").font(.caption).lineLimit(1).frame(width: Metrics.poster.width, alignment: .leading)
                    }
                }
                .padding(Metrics.gutter)
            case ("person", let id?): PersonView(route: PersonRoute(id: Int(id) ?? 0, name: "", profilePath: nil))
            case ("detail", let kind?):
                if let summary { DetailView(summary: summary) } else { ProgressView() }
            default: Text("Unknown route \(route)")
            }
        }
        .lanternaDestinations()
        .task {
            guard parts.first == "detail", parts.count == 3, let id = Int(parts[2]) else { return }
            let ref = parts[1] == "show" ? TitleRef.show(tmdbID: id, imdbID: nil) : TitleRef.movie(tmdbID: id, imdbID: nil)
            summary = await env.detail(for: ref)?.summary
        }
    }
}
