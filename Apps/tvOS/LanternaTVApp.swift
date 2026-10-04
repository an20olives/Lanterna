import SwiftUI

@main
struct LanternaTVApp: App {
    @State private var env: AppEnvironment = {
        let env = AppEnvironment()
        env.labView = { AnyView(HarnessRoot(model: HarnessModel())) }
        return env
    }()

    var body: some Scene {
        WindowGroup { AppRoot(env: env) }
    }
}
