import SwiftUI

@main
struct LanternaTVApp: App {
    @State private var env: AppEnvironment = {
        let env = AppEnvironment()
        env.labView = { AnyView(HarnessRoot(model: HarnessModel())) }
        return env
    }()
    @State private var lab = HarnessModel()

    var body: some Scene {
        WindowGroup {
            // `-lab` boots straight into the P0 harness (used for headless simulator runs).
            if ProcessInfo.processInfo.arguments.contains("-lab") {
                HarnessRoot(model: lab)
            } else {
                AppRoot(env: env)
            }
        }
    }
}
