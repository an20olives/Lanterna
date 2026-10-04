import LanternaKit
import SwiftUI

/// Optional featured strip at the top of Home. Cycles every eight seconds; on tvOS move left or right to change.
struct HeroCarousel: View {
    let items: [TitleSummary]
    let onDetails: (TitleSummary) -> Void
    let onPlay: (TitleSummary) -> Void
    @State private var index = 0
    @State private var paused = false

    #if os(tvOS)
    private let height: CGFloat = 560
    #else
    private let height: CGFloat = 320
    #endif

    var body: some View {
        if let item = items.indices.contains(index) ? items[index] : items.first {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: TMDBImage.url(item.backdropPath ?? item.posterPath, .backdrop), placeholder: "")
                    .frame(height: height).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                    .overlay(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center))
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.largeTitle.bold()).lineLimit(1)
                    if let overview = item.overview { Text(overview).lineLimit(2).frame(maxWidth: 800, alignment: .leading).foregroundStyle(.secondary) }
                    HStack(spacing: 16) {
                        if item.ref.kind == .movie { Button { onPlay(item) } label: { Label("Play", systemImage: "play.fill") } }
                        Button("Details") { onDetails(item) }
                        Spacer().frame(width: 20)
                        HStack(spacing: 8) {
                            ForEach(items.indices, id: \.self) { dot in
                                Circle().fill(dot == index ? Theme.accent : .white.opacity(0.4)).frame(width: 10, height: 10)
                            }
                        }
                    }
                }
                .padding(Metrics.gutter)
            }
            .id(item.id)
            .transition(.opacity)
            .accessibilityIdentifier("hero")
            #if os(tvOS)
            .onMoveCommand { direction in
                switch direction {
                case .left: step(-1)
                case .right: step(1)
                default: break
                }
            }
            #else
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in step(value.translation.width < 0 ? 1 : -1) })
            #endif
            .task(id: index) {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { step(1) }
            }
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index = (index + delta + items.count) % items.count }
    }
}
