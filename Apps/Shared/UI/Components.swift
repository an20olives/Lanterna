import LanternaKit
import SwiftUI

enum Metrics {
    #if os(tvOS)
    static let poster = CGSize(width: 220, height: 330)
    static let still = CGSize(width: 380, height: 214)
    static let gutter: CGFloat = 80
    static let rowSpacing: CGFloat = 40
    static let sectionSpacing: CGFloat = 50
    static let rowPadding: CGFloat = 24
    #else
    static let poster = CGSize(width: 120, height: 180)
    static let still = CGSize(width: 200, height: 113)
    static let gutter: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    static let rowPadding: CGFloat = 4
    #endif
}

extension View {
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(LanternaCardStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }

    @ViewBuilder func focusSectionIfTV() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}

struct RemoteImage: View {
    let url: URL?
    let placeholder: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
                    Text(placeholder).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(8)
                }
            }
        }
    }
}

struct PosterCard: View {
    let summary: TitleSummary
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: TMDBImage.url(summary.posterPath, .poster), placeholder: summary.title)
                    .frame(width: Metrics.poster.width, height: Metrics.poster.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule()).foregroundStyle(.black).padding(8)
                        }
                    }
                Text(summary.title).font(.caption).lineLimit(1).frame(width: Metrics.poster.width, alignment: .leading)
            }
        }
        .cardButtonStyle()
        .accessibilityIdentifier("poster.\(summary.id)")
    }
}

struct ShelfRow: View {
    let title: String
    let items: [TitleSummary]
    var badges: [String: String] = [:]
    let onSelect: (TitleSummary) -> Void
    var onSeeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold()).padding(.leading, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.rowSpacing) {
                    ForEach(items) { item in
                        PosterCard(summary: item, badge: badges[item.id]) { onSelect(item) }
                    }
                    if let onSeeAll {
                        Button(action: onSeeAll) {
                            VStack { Image(systemName: "chevron.right.circle").font(.largeTitle); Text("See All") }
                                .frame(width: Metrics.poster.width, height: Metrics.poster.height)
                        }
                        .cardButtonStyle()
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.rowPadding)
            }
            .scrollClipDisabled()
        }
        .focusSectionIfTV()
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

struct BadgeStrip: View {
    let badges: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

func formatRuntime(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

func formatSize(_ bytes: Int64?) -> String? {
    guard let bytes else { return nil }
    return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
}

#if os(tvOS)
/// tvOS focus: lift, soft shadow and an amber ring (the system ring cannot be recoloured).
struct LanternaCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CardBody(configuration: configuration) }

    struct CardBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accent, lineWidth: isFocused ? 5 : 0))
                .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.97 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
#endif

/// A horizontally scrolling row inside a padded column. It runs to the screen edge and does not clip
/// focus rings, shadows or the cards scrolling past the gutter.
struct HRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content.padding(.horizontal, Metrics.gutter)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -Metrics.gutter)
    }
}
