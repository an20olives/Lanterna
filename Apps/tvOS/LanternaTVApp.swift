import SwiftUI

@main
struct LanternaTVApp: App {
    @State private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            HarnessRoot(model: model)
                .tint(Theme.accent)
        }
    }
}
