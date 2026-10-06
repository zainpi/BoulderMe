import Observation
import SwiftUI

/// The observable root of app state. Built once by `BoulderMeApp` (the
/// composition root) and injected into the environment.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable {
        /// Signed out: the Welcome screen.
        case welcome
        /// Local fixtures, no account, nothing leaves the device.
        case demo
        /// Signed in against the Worker. Reached once T6 adds Sign in with Apple.
        case account
    }

    let config: AppConfig
    private(set) var mode: Mode = .welcome
    private(set) var services: ServiceContainer
    let router = Router()

    private(set) var pendingInviteCount = 0
    private(set) var unreadChatCount = 0

    private let liveServices: ServiceContainer
    private let makeDemoServices: () -> ServiceContainer

    init(
        config: AppConfig,
        liveServices: ServiceContainer? = nil,
        makeDemoServices: @escaping () -> ServiceContainer = { DemoBackend().container }
    ) {
        self.config = config
        let live = liveServices ?? PendingLiveServices(baseURL: config.apiBaseURL).container
        self.liveServices = live
        self.makeDemoServices = makeDemoServices
        self.services = live
        if config.startInDemo { enterDemo() }
    }

    var isDemo: Bool { mode == .demo }

    /// The member using the app: the fixture account in demo. T6 sets it from the session.
    var currentAccountId: EntityID? {
        switch mode {
        case .demo: DemoFixtures.meId
        case .welcome, .account: nil
        }
    }

    /// Demo gets a fresh backend every time, so its data never carries over and
    /// never mixes with an account's cache.
    func enterDemo() {
        services = makeDemoServices()
        router.reset()
        mode = .demo
        Task { await refreshBadges() }
    }

    func leaveDemo() {
        services = liveServices
        router.reset()
        pendingInviteCount = 0
        unreadChatCount = 0
        mode = .welcome
    }

    /// Re-reads tab badge counts from `GET /v1/me`.
    func refreshBadges() async {
        guard mode != .welcome, let me = try? await services.account.me() else { return }
        pendingInviteCount = me.pendingIncomingInvitationCount
        unreadChatCount = me.unreadChatCount
    }

    /// Call when a demo user taps something that needs a real account.
    func requireAccount() {
        router.sheet = .signInRequired
    }

    static func preview(demo: Bool = true) -> AppModel {
        AppModel(config: AppConfig(
            environment: .debug, apiBaseURL: AppConfig.preview.apiBaseURL,
            version: "0.1.0", build: "1", startInDemo: demo))
    }
}
