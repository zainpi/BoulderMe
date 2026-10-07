import Observation
import SwiftUI

/// The observable root of app state. Built once by `BoulderMeApp` (the
/// composition root) and injected into the environment.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable {
        /// Restoring a stored session at launch.
        case launching
        /// Signed out: the Welcome screen.
        case welcome
        /// Local fixtures, no account, nothing leaves the device.
        case demo
        /// Signed in, onboarding not finished.
        case onboarding
        /// Signed in against the Worker.
        case account
    }

    let config: AppConfig
    private(set) var mode: Mode = .launching
    private(set) var services: ServiceContainer
    let router = Router()

    private(set) var pendingInviteCount = 0
    private(set) var unreadChatCount = 0
    private(set) var accountId: EntityID?
    /// Set while `mode == .onboarding`.
    private(set) var onboarding: OnboardingModel?

    private(set) var isSigningIn = false
    /// Shown on Welcome after a failed sign-in.
    var signInError: AppError?
    /// One-off note shown on Welcome (signed out by the server, account deleted).
    var notice: String?

    private let auth: any AuthService
    private let liveServices: ServiceContainer
    private let makeDemoServices: () -> ServiceContainer
    private let appleSignIn: any AppleSignInProviding
    private let defaults: UserDefaults
    /// Apple only shares the given name on the first authorization; kept for the onboarding draft.
    private var appleGivenName: String?

    init(
        config: AppConfig,
        auth: any AuthService,
        liveServices: ServiceContainer,
        makeDemoServices: @escaping () -> ServiceContainer = { DemoBackend().container },
        appleSignIn: any AppleSignInProviding = SystemAppleSignIn(),
        defaults: UserDefaults = .standard
    ) {
        self.config = config
        self.auth = auth
        self.liveServices = liveServices
        self.makeDemoServices = makeDemoServices
        self.appleSignIn = appleSignIn
        self.defaults = defaults
        self.services = liveServices

        let events = auth.sessionEnded
        Task { [weak self] in
            for await reason in events {
                self?.sessionEnded(reason)
            }
        }

        if config.startInDemo {
            enterDemo()
        } else {
            Task { await restore() }
        }
    }

    /// The app as shipped: Keychain session, URLSession client.
    static func live(config: AppConfig) -> AppModel {
        let defaults = UserDefaults.standard
        let store = KeychainSessionStore()
        Installation.clearStaleSession(store: store, defaults: defaults)
        let client = APIClient(baseURL: config.apiBaseURL, store: store)
        return AppModel(config: config, auth: client, liveServices: LiveServices(client: client).container,
                        defaults: defaults)
    }

    var isDemo: Bool { mode == .demo }

    /// The member using the app: the fixture account in demo, the session's account when signed in.
    var currentAccountId: EntityID? {
        switch mode {
        case .demo: DemoFixtures.meId
        case .onboarding, .account: accountId
        case .launching, .welcome: nil
        }
    }

    var accountCache: AccountCache? {
        accountId.map { AccountCache(defaults: defaults, accountId: $0) }
    }

    // MARK: Demo

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

    // MARK: Session

    /// Launch: resume a stored session, or show Welcome.
    func restore() async {
        guard let stored = await auth.storedAccountId() else {
            if mode == .launching { mode = .welcome }
            return
        }
        guard mode == .launching else { return }
        accountId = stored
        services = liveServices
        await routeSignedIn()
    }

    /// Nonce from the Worker, Apple's sheet, then the session exchange.
    func signInWithApple() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        notice = nil
        defer { isSigningIn = false }
        do {
            let nonce = try await auth.nonce()
            let credential = try await appleSignIn.authorize(hashedNonce: Nonce.sha256Hex(nonce.nonce))
            let session = try await auth.signInWithApple(AppleSignInRequest(
                identityToken: credential.identityToken, authorizationCode: credential.authorizationCode,
                nonce: nonce.nonce, givenName: credential.givenName,
                clientInstallationId: Installation.id(in: defaults)))
            if accountId != session.accountId { AccountCache.wipeAll(in: defaults) }
            accountId = session.accountId
            appleGivenName = credential.givenName
            services = liveServices
            router.reset()
            await routeSignedIn()
        } catch is CancellationError {
            // Closed Apple's sheet: stay where we were.
        } catch {
            signInError = error.asAppError
        }
    }

    /// Reads `GET /v1/me` and opens onboarding or the tabs.
    func routeSignedIn() async {
        let cache = accountCache
        do {
            let me = try await services.account.me()
            cache?.set(me, for: "me")
            apply(me)
        } catch {
            let appError = error.asAppError
            if mode == .welcome { return } // The session ended while loading.
            if appError == .offline, let cached: Me = cache?.value("me") {
                apply(cached)
            } else {
                // Tabs show their own offline/error states and retry.
                onboarding = nil
                mode = .account
            }
        }
    }

    private func apply(_ me: Me) {
        guard let cache = accountCache else { return }
        if let step = OnboardingPlan.resumeStep(me: me, progress: cache.value("onboarding.progress") ?? OnboardingProgress()) {
            onboarding = OnboardingModel(me: me, start: step, services: services, cache: cache, givenName: appleGivenName)
            mode = .onboarding
        } else {
            onboarding = nil
            pendingInviteCount = me.pendingIncomingInvitationCount
            unreadChatCount = me.unreadChatCount
            mode = .account
        }
    }

    func finishOnboarding() {
        onboarding = nil
        appleGivenName = nil
        router.reset()
        mode = .account
        Task { await refreshBadges() }
    }

    /// Revokes the session on the server when reachable, then clears everything local.
    func signOut() async {
        await auth.signOut()
        finishSignedOut(notice: nil)
    }

    /// `DELETE /v1/me`. Throws so the confirmation screen can show what went wrong.
    func deleteAccount() async throws {
        try await services.account.deleteAccount()
        finishSignedOut(notice: "Your account and profile have been deleted.")
    }

    private func sessionEnded(_ reason: SessionEndReason) {
        guard mode != .demo, accountId != nil else { return }
        finishSignedOut(notice: reason == .accountDeleted
            ? "This account has been deleted."
            : "You were signed out. Sign in again to keep climbing.")
    }

    /// Full cleanup: account caches, navigation, badges, in-memory account state.
    private func finishSignedOut(notice: String?) {
        AccountCache.wipeAll(in: defaults)
        accountId = nil
        onboarding = nil
        appleGivenName = nil
        services = liveServices
        router.reset()
        pendingInviteCount = 0
        unreadChatCount = 0
        self.notice = notice
        mode = .welcome
    }

    // MARK: Badges

    /// Re-reads tab badge counts from `GET /v1/me`.
    func refreshBadges() async {
        guard mode == .demo || mode == .account, let me = try? await services.account.me() else { return }
        pendingInviteCount = me.pendingIncomingInvitationCount
        unreadChatCount = me.unreadChatCount
        if mode == .account { accountCache?.set(me, for: "me") }
    }

    /// Call when a demo user taps something that needs a real account.
    func requireAccount() {
        router.sheet = .signInRequired
    }

    static func preview(demo: Bool = true) -> AppModel {
        let client = APIClient(baseURL: AppConfig.preview.apiBaseURL, store: InMemorySessionStore())
        return AppModel(
            config: AppConfig(environment: .debug, apiBaseURL: AppConfig.preview.apiBaseURL,
                              version: "0.1.0", build: "1", startInDemo: demo),
            auth: client, liveServices: PendingLiveServices(baseURL: client.baseURL).container,
            defaults: UserDefaults(suiteName: "preview") ?? .standard)
    }
}
