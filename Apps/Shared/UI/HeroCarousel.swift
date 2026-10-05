import LanternaKit
import SwiftUI

/// Optional featured strip at the top of Home.
/// The buttons stay put when the slide changes (rebuilding them dropped focus). On tvOS, pressing left on the first
/// button or right on the last one changes the slide; the slide also advances by itself unless a button has focus.
struct HeroCarousel: View {
    let items: [TitleSummary]
    var scope: Namespace.ID
    let onDetails: (TitleSummary) -> Void
    let onPlay: (TitleSummary) -> Void
    @State private var index = 0
    @FocusState private var focus: Field?

    private enum Field { case play, details }

    #if os(tvOS)
    private let height: CGFloat = 560
    #else
    private let height: CGFloat = 320
    #endif

    private var item: TitleSummary? { items.indices.contains(index) ? items[index] : items.first }

    var body: some View {
        if let item {
            let hasPlay = item.ref.kind == .movie
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: TMDBImage.url(item.backdropPath ?? item.posterPath, .backdrop), placeholder: "")
                    .id(item.id)
                    .transition(.opacity)
                    .frame(height: height).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                    .overlay(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center))
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.largeTitle.bold()).lineLimit(1)
                    Text(item.overview ?? " ").lineLimit(2).frame(maxWidth: 800, alignment: .leading).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        if hasPlay {
                            Button { onPlay(item) } label: { Label("Play", systemImage: "play.fill") }
                                .focused($focus, equals: .play)
                                .accessibilityIdentifier("hero.play")
                        }
                        Button("Details") { onDetails(item) }
                            .focused($focus, equals: .details)
                            .accessibilityIdentifier("hero.details")
                        Spacer().frame(width: 20)
                        HStack(spacing: 8) {
                            ForEach(items.indices, id: \.self) { dot in
                                Circle().fill(dot == index ? Theme.accent : .white.opacity(0.4)).frame(width: 10, height: 10)
                            }
                        }
                    }
                }
                .padding(36)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, Metrics.gutter)
            .focusSectionIfTV()
            .defaultFocus($focus, hasPlay ? .play : .details)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hero")
            #if os(tvOS)
            .onMoveCommand { direction in
                let firstButton: Field = hasPlay ? .play : .details
                if direction == .left, focus == firstButton { step(-1) }
                else if direction == .right, focus == .details { step(1) }
            }
            #else
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in step(value.translation.width < 0 ? 1 : -1) })
            #endif
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    if focus == nil { step(1) }
                }
            }
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index = (index + delta + items.count) % items.count }
    }
}
