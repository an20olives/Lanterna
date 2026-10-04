import SwiftUI

@main
struct LanternaIOSApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Lanterna").font(.largeTitle.bold())
                Text("Player spike runs on Apple TV").foregroundStyle(.secondary)
            }
            .tint(Theme.accent)
        }
    }
}
