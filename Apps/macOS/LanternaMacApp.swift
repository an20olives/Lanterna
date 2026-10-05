import SwiftUI

@main
struct LanternaMacApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            AppRoot(env: env)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1280, height: 800)
    }
}
