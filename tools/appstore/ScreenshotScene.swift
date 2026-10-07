import Foundation

/// App Store screenshots only. Copied into the app by tools/appstore/patch_app.py in the
/// `appstore-screenshots` workflow; it never ships. `-BMScreenshot <scene>` opens demo mode
/// on one screen without the Demo badge.
enum ScreenshotScene {
    static var name: String? { UserDefaults.standard.string(forKey: "BMScreenshot") }
    static var isActive: Bool { name != nil }

    @MainActor
    static func apply(to app: AppModel) {
        guard let name, name != "welcome" else { return }
        app.enterDemo()
        let router = app.router
        switch name {
        case "profile":
            router.selectedTab = .discover
            router.discover = [.profile(DemoFixtures.id(12))]
        case "invites":
            router.selectedTab = .invites
        case "invitation":
            router.selectedTab = .invites
            router.invites = [.invitation(DemoFixtures.id(301))]
        case "chat":
            router.openChat(DemoFixtures.id(401))
        case "me":
            router.selectedTab = .profile
        default:
            router.selectedTab = .discover
        }
    }
}
