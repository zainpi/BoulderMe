import XCTest
@testable import BoulderMe

final class APIClientTests: XCTestCase {
    private let base = URL(string: "http://localhost:8787")!

    func testConcurrentRequestsShareOneRefresh() async throws {
        let fresh = Wire.session("new")
        let transport = FakeTransport { request in
            switch request.url?.path {
            case "/v1/auth/refresh":
                try await Task.sleep(for: .milliseconds(50))
                return (200, Wire.json(fresh))
            case "/v1/me":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-new")
                return (200, Wire.json(Wire.me()))
            default:
                return (404, Wire.error("not_found"))
            }
        }
        let store = InMemorySessionStore(Wire.session("old", expiresIn: -60))
        let client = APIClient(baseURL: base, transport: transport, store: store)
        let services = LiveServices(client: client)

        try await withThrowingTaskGroup(of: Me.self) { group in
            for _ in 0..<5 { group.addTask { try await services.me() } }
            for try await _ in group {}
        }

        XCTAssertEqual(transport.count(path: "/v1/auth/refresh"), 1)
        XCTAssertEqual(transport.count(path: "/v1/me"), 5)
        XCTAssertEqual(store.load()?.accessToken, "access-new")
    }

    func testRejectedAccessTokenRefreshesAndRetriesOnce() async throws {
        let transport = FakeTransport { request in
            switch (request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/v1/me", "Bearer access-old"): return (401, Wire.error("token_expired"))
            case ("/v1/me", "Bearer access-new"): return (200, Wire.json(Wire.me()))
            case ("/v1/auth/refresh", _): return (200, Wire.json(Wire.session("new")))
            default: return (500, Data())
            }
        }
        let client = APIClient(baseURL: base, transport: transport, store: InMemorySessionStore(Wire.session("old")))
        let me = try await LiveServices(client: client).me()
        XCTAssertEqual(me.accountId, Wire.accountId)
        XCTAssertEqual(transport.count(path: "/v1/me"), 2)
    }

    func testReusedRefreshTokenEndsTheSession() async throws {
        let transport = FakeTransport { request in
            request.url?.path == "/v1/auth/refresh" ? (401, Wire.error("refresh_token_reused")) : (401, Wire.error("token_expired"))
        }
        let store = InMemorySessionStore(Wire.session("old", expiresIn: -60))
        let client = APIClient(baseURL: base, transport: transport, store: store)
        var events = client.sessionEnded.makeAsyncIterator()

        do {
            _ = try await LiveServices(client: client).me()
            XCTFail("Expected the request to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.refreshTokenReused, requestId: "r1"))
        }
        XCTAssertNil(store.load())
        let accountId = await client.accountId
        XCTAssertNil(accountId)
        let event = await events.next()
        XCTAssertEqual(event, .expired)
    }

    func testOfflineRefreshKeepsTheSession() async throws {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let store = InMemorySessionStore(Wire.session("old", expiresIn: -60))
        let client = APIClient(baseURL: base, transport: transport, store: store)
        do {
            _ = try await LiveServices(client: client).me()
            XCTFail("Expected offline")
        } catch {
            XCTAssertEqual(error as? AppError, .offline)
        }
        XCTAssertNotNil(store.load(), "Being offline must not sign the member out")
    }

    func testErrorsWithoutEnvelopeFallBackToStatus() async throws {
        let transport = FakeTransport { _ in (503, Data("<html>".utf8)) }
        let client = APIClient(baseURL: base, transport: transport, store: InMemorySessionStore(Wire.session("a")))
        do {
            _ = try await LiveServices(client: client).me()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.unavailable, requestId: "test"))
        }
    }

    func testWritesSendJSONIdempotencyKeyAndLowercaseIds() async throws {
        let transport = FakeTransport { request in
            if request.url?.path == "/v1/me/availability" {
                let slot = AvailabilitySlot(slotId: EntityID(), weekday: .tuesday, startMinute: 1020, endMinute: 1320,
                                            timeZone: "America/Toronto", gymId: nil)
                return (201, Wire.json(slot))
            }
            return (204, Data())
        }
        let client = APIClient(baseURL: base, transport: transport, store: InMemorySessionStore(Wire.session("a")))
        let services = LiveServices(client: client)
        _ = try await services.addSlot(AvailabilityWindow.input(weekday: .tuesday, timeOfDay: .evening,
                                                               timeZone: TimeZone(identifier: "America/Toronto")!))
        let gymId = EntityID(UUID(uuidString: "ABCDEF00-0000-4000-8000-000000000001")!)
        try await services.removeGym(gymId: gymId)

        let add = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(add.httpMethod, "POST")
        XCTAssertEqual(add.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let key = try XCTUnwrap(add.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(key, key.lowercased())
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(add.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["start_minute"] as? Int, 1020)
        XCTAssertEqual(body?["time_zone"] as? String, "America/Toronto")

        let remove = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(remove.httpMethod, "DELETE")
        XCTAssertEqual(remove.url?.path, "/v1/me/gyms/abcdef00-0000-4000-8000-000000000001")
    }

    func testSignInStoresSessionAndSignOutClearsItEvenOffline() async throws {
        let session = Wire.session("a")
        let transport = FakeTransport { request in
            switch request.url?.path {
            case "/v1/auth/apple":
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                XCTAssertEqual(body?["nonce"] as? String, "raw-nonce")
                XCTAssertTrue(body?.keys.contains("given_name") ?? false)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Wire.json(session))
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = InMemorySessionStore()
        let client = APIClient(baseURL: base, transport: transport, store: store)
        _ = try await client.signInWithApple(AppleSignInRequest(
            identityToken: "t", authorizationCode: "c", nonce: "raw-nonce", givenName: nil, clientInstallationId: EntityID()))
        // The wire drops fractional seconds, so compare fields rather than the whole value.
        XCTAssertEqual(store.load()?.accessToken, session.accessToken)
        XCTAssertEqual(store.load()?.accountId, session.accountId)

        await client.signOut()
        XCTAssertNil(store.load())
        XCTAssertEqual(transport.count(path: "/v1/auth/sign-out"), 1)
    }

    func testNonceHashIsLowercaseHexSHA256() {
        XCTAssertEqual(Nonce.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
