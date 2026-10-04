import SwiftUI

@main
struct LanternaIOSApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup { AppRoot(env: env) }
    }
}
