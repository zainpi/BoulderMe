import SwiftUI

/// Composition root: builds config, services and the app model once, then
/// hands them down through the environment.
@main
struct BoulderMeApp: App {
    @State private var app = AppModel.live(config: .load())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Palette.accent)
        }
    }
}
