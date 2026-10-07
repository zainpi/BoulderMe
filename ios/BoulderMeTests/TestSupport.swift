import Foundation
import XCTest
@testable import BoulderMe

/// Scripted HTTP: each request goes to `handler`, and every request is recorded.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func count(path: String) -> Int {
        requests.filter { $0.url?.path == path }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let (status, body) = try await handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["X-Request-Id": "test"])!
        return (body, response)
    }
}

enum Wire {
    static func json(_ value: some Encodable) -> Data {
        try! APICoding.makeEncoder().encode(value)
    }

    static func error(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"x","request_id":"r1","details":null}}"#.utf8)
    }

    static let accountId = EntityID(UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!)

    static func session(_ suffix: String, expiresIn: TimeInterval = 900, now: Date = Date()) -> Session {
        Session(accessToken: "access-\(suffix)", accessTokenExpiresAt: now.addingTimeInterval(expiresIn),
                refreshToken: "refresh-\(suffix)-0123456789abcdef0123456789abcdef",
                refreshTokenExpiresAt: now.addingTimeInterval(60 * 86_400),
                accountId: accountId, isNewAccount: false)
    }

    static func me(profile: OwnProfile? = nil, gyms: [GymAccess] = [],
                   onboarding: OnboardingState = OnboardingState(hasProfile: false, hasGym: false, hasAvailability: false,
                                                                 adultConfirmed: false, discoveryExplained: false)) -> Me {
        Me(accountId: accountId, createdAt: Date(timeIntervalSince1970: 1_791_284_400), profile: profile, gyms: gyms,
           onboarding: onboarding, unreadChatCount: 0, pendingIncomingInvitationCount: 2)
    }

    static func profile(discoverable: Bool = false, explained: Bool = false) -> OwnProfile {
        OwnProfile(accountId: accountId, revision: 1, displayName: "Sam", gradeMin: 2, gradeMax: 5, styles: [.slab],
                   intro: nil, discoverable: discoverable, adultConfirmed: true, discoveryExplained: explained,
                   updatedAt: Date(timeIntervalSince1970: 1_791_284_400))
    }

    static var gymAccess: GymAccess {
        GymAccess(gym: DemoFixtures.cozyCrimp, accessType: .membership, selfReported: true,
                  updatedAt: Date(timeIntervalSince1970: 1_791_284_400))
    }
}

@MainActor
struct FakeAppleSignIn: AppleSignInProviding {
    var result: Result<AppleCredential, Error> = .success(
        AppleCredential(identityToken: "id-token", authorizationCode: "auth-code", givenName: "Sam"))

    func authorize(hashedNonce: String) async throws -> AppleCredential {
        try result.get()
    }
}

/// Waits up to a second for something an async stream will cause.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async {
    var tries = 0
    while !condition() && tries < 100 {
        tries += 1
        try? await Task.sleep(for: .milliseconds(10))
    }
}

func makeDefaults() -> UserDefaults {
    let name = "test-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
}
