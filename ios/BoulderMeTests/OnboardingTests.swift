import XCTest
@testable import BoulderMe

final class OnboardingPlanTests: XCTestCase {
    private func state(profile: Bool = true, gym: Bool = true, availability: Bool = true,
                       adult: Bool = true, explained: Bool = true) -> OnboardingState {
        OnboardingState(hasProfile: profile, hasGym: gym, hasAvailability: availability,
                        adultConfirmed: adult, discoveryExplained: explained)
    }

    func testResumesAtFirstUnfinishedStep() {
        let none = OnboardingProgress()
        XCTAssertEqual(OnboardingPlan.resumeStep(me: Wire.me(), progress: none), .basics)
        let profile = Wire.profile()
        XCTAssertEqual(OnboardingPlan.resumeStep(
            me: Wire.me(profile: profile, onboarding: state(gym: false, availability: false, explained: false)), progress: none), .gyms)
        XCTAssertEqual(OnboardingPlan.resumeStep(
            me: Wire.me(profile: profile, onboarding: state(availability: false, explained: false)), progress: none), .availability)
        XCTAssertEqual(OnboardingPlan.resumeStep(
            me: Wire.me(profile: profile, onboarding: state(explained: false)), progress: none), .visibility)
        XCTAssertEqual(OnboardingPlan.resumeStep(me: Wire.me(profile: profile, onboarding: state()), progress: none), .discovery)
    }

    func testSkippedAvailabilityAndDiscoveryChoiceAreRemembered() {
        let profile = Wire.profile(explained: true)
        var progress = OnboardingProgress(skippedAvailability: true)
        XCTAssertEqual(OnboardingPlan.resumeStep(
            me: Wire.me(profile: profile, onboarding: state(availability: false)), progress: progress), .discovery)
        progress.discoveryDecided = true
        XCTAssertNil(OnboardingPlan.resumeStep(me: Wire.me(profile: profile, onboarding: state(availability: false)), progress: progress))
    }

    func testDiscoverableMemberIsDone() {
        let me = Wire.me(profile: Wire.profile(discoverable: true, explained: true), onboarding: state())
        XCTAssertNil(OnboardingPlan.resumeStep(me: me, progress: OnboardingProgress()))
    }

    func testDraftValidationAndStyleLimit() {
        var draft = ProfileDraft()
        XCTAssertFalse(draft.nameIsValid)
        draft.displayName = "   "
        XCTAssertFalse(draft.nameIsValid)
        draft.displayName = String(repeating: "a", count: 41)
        XCTAssertFalse(draft.nameIsValid)
        draft.displayName = " Sam "
        XCTAssertTrue(draft.isValid)
        for style in ClimbingStyle.allCases { draft.toggle(style) }
        XCTAssertEqual(draft.styles.count, ClimbingStyle.maxSelected)
        draft.toggle(draft.styles[0])
        XCTAssertEqual(draft.styles.count, ClimbingStyle.maxSelected - 1)
        draft.intro = "  "
        let input = draft.input(revision: 0, discoveryExplained: false)
        XCTAssertEqual(input.displayName, "Sam")
        XCTAssertNil(input.intro)
    }
}

/// Sign-in, routing and sign-out against a scripted Worker.
@MainActor
final class AppSessionTests: XCTestCase {
    private func makeApp(store: InMemorySessionStore, defaults: UserDefaults,
                         transport: FakeTransport) -> (AppModel, APIClient) {
        let client = APIClient(baseURL: URL(string: "http://localhost:8787")!, transport: transport, store: store)
        let app = AppModel(config: AppConfig(environment: .debug, apiBaseURL: client.baseURL, version: "1", build: "1",
                                             startInDemo: false),
                           auth: client, liveServices: LiveServices(client: client).container,
                           appleSignIn: FakeAppleSignIn(), defaults: defaults)
        return (app, client)
    }

    private func worker(me: @escaping @Sendable () -> Me) -> FakeTransport {
        FakeTransport { request in
            switch request.url?.path {
            case "/v1/auth/nonce":
                return (201, Wire.json(AuthNonce(nonce: String(repeating: "n", count: 32), expiresAt: Date().addingTimeInterval(600))))
            case "/v1/auth/apple":
                return (200, Wire.json(Wire.session("a")))
            case "/v1/me":
                return (200, Wire.json(me()))
            case "/v1/auth/sign-out":
                return (204, Data())
            default:
                return (404, Wire.error("not_found"))
            }
        }
    }

    func testNewMemberSignsInIntoOnboardingWithAppleName() async throws {
        let store = InMemorySessionStore()
        let defaults = makeDefaults()
        let transport = worker { Wire.me() }
        let (app, _) = makeApp(store: store, defaults: defaults, transport: transport)
        await app.restore()
        XCTAssertEqual(app.mode, .welcome)

        await app.signInWithApple()

        XCTAssertNil(app.signInError)
        XCTAssertEqual(app.mode, .onboarding)
        XCTAssertEqual(app.onboarding?.step, .basics)
        XCTAssertEqual(app.onboarding?.draft.displayName, "Sam")
        XCTAssertEqual(app.currentAccountId, Wire.accountId)
        XCTAssertNotNil(store.load())
        let apple = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/auth/apple" })
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(apple.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["nonce"] as? String, String(repeating: "n", count: 32))
        XCTAssertNotNil(body?["client_installation_id"] as? String)
    }

    func testStoredSessionResumesStraightIntoTheTabs() async {
        let done = Wire.me(profile: Wire.profile(discoverable: true, explained: true), gyms: [Wire.gymAccess],
                           onboarding: OnboardingState(hasProfile: true, hasGym: true, hasAvailability: true,
                                                       adultConfirmed: true, discoveryExplained: true))
        let (app, _) = makeApp(store: InMemorySessionStore(Wire.session("a")), defaults: makeDefaults(),
                               transport: worker { done })
        await app.restore()
        XCTAssertEqual(app.mode, .account)
        XCTAssertEqual(app.pendingInviteCount, 2)
    }

    func testCancelledAppleSheetStaysOnWelcomeQuietly() async {
        let client = APIClient(baseURL: URL(string: "http://localhost:8787")!, transport: worker { Wire.me() },
                               store: InMemorySessionStore())
        let app = AppModel(config: .preview, auth: client, liveServices: LiveServices(client: client).container,
                           appleSignIn: FakeAppleSignIn(result: .failure(CancellationError())), defaults: makeDefaults())
        app.leaveDemo()
        await app.signInWithApple()
        XCTAssertEqual(app.mode, .welcome)
        XCTAssertNil(app.signInError)
    }

    func testSignOutClearsSessionCachesAndNavigation() async {
        let store = InMemorySessionStore(Wire.session("a"))
        let defaults = makeDefaults()
        let transport = worker { Wire.me() }
        let (app, _) = makeApp(store: store, defaults: defaults, transport: transport)
        await app.restore()
        XCTAssertEqual(app.mode, .onboarding)
        app.onboarding?.draft.displayName = "Draft name"
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(AccountCache.keyPrefix) }.isEmpty)
        app.router.profile = [.settings]

        await app.signOut()

        XCTAssertEqual(app.mode, .welcome)
        XCTAssertNil(store.load())
        XCTAssertNil(app.onboarding)
        XCTAssertTrue(app.router.profile.isEmpty)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(AccountCache.keyPrefix) }.isEmpty)
        XCTAssertEqual(transport.count(path: "/v1/auth/sign-out"), 1)
    }

    func testServerEndingTheSessionReturnsToWelcome() async {
        let store = InMemorySessionStore(Wire.session("a"))
        let transport = FakeTransport { request in
            switch request.url?.path {
            case "/v1/me": return (401, Wire.error("unauthorized"))
            case "/v1/auth/refresh": return (401, Wire.error("refresh_token_reused"))
            default: return (404, Wire.error("not_found"))
            }
        }
        let (app, _) = makeApp(store: store, defaults: makeDefaults(), transport: transport)
        await app.restore()
        await eventually { app.mode == .welcome }
        XCTAssertEqual(app.mode, .welcome)
        XCTAssertNotNil(app.notice)
        XCTAssertNil(store.load())
    }

    func testOnboardingSavesProfileAndFinishes() async throws {
        let backend = DemoBackend()
        let services = backend.container
        let me = Wire.me(profile: Wire.profile(), gyms: [Wire.gymAccess],
                         onboarding: OnboardingState(hasProfile: true, hasGym: true, hasAvailability: true,
                                                     adultConfirmed: true, discoveryExplained: false))
        let cache = AccountCache(defaults: makeDefaults(), accountId: Wire.accountId)
        let start = try XCTUnwrap(OnboardingPlan.resumeStep(me: me, progress: OnboardingProgress()))
        XCTAssertEqual(start, .visibility)

        // Same revision (1) as the demo backend's own profile.
        let model = OnboardingModel(me: me, start: start, services: services, cache: cache, givenName: nil)
        await model.advance()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.step, .discovery)
        let finished = await model.chooseDiscovery(true)
        XCTAssertTrue(finished)
        XCTAssertEqual(model.profile?.discoverable, true)
        let progress: OnboardingProgress? = cache.value("onboarding.progress")
        XCTAssertEqual(progress, OnboardingProgress(discoveryDecided: true))
    }
}
