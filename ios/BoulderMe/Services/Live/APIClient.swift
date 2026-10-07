import Foundation

/// Sends one HTTP request. `URLSessionTransport` in the app, a fake in tests.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    /// Ephemeral: no shared disk cache or cookies, so nothing from one account
    /// is left on disk for the next.
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

/// One call to a `/v1` route.
struct Endpoint: Sendable {
    var method: HTTPMethod
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var authenticated = true
    var idempotencyKey: UUID?

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: .get, path: path, query: query)
    }

    static func delete(_ path: String) -> Endpoint {
        Endpoint(method: .delete, path: path)
    }

    static func write(_ method: HTTPMethod, _ path: String, body: some Encodable,
                      authenticated: Bool = true, idempotencyKey: UUID? = nil) throws -> Endpoint {
        Endpoint(method: method, path: path, body: try APICoding.makeEncoder().encode(body),
                 authenticated: authenticated, idempotencyKey: idempotencyKey)
    }
}

/// Why a session ended without the member asking.
enum SessionEndReason: Sendable, Equatable {
    /// The refresh token was rejected (expired, reused or revoked elsewhere).
    case expired
    case accountDeleted
}

/// The Worker client. Adds the bearer token, maps the `Error` envelope to
/// `AppError`, and refreshes the access token at most once at a time: every
/// request that finds the token stale joins the same in-flight refresh.
actor APIClient {
    nonisolated let baseURL: URL
    private let transport: any HTTPTransport
    private let store: any SessionStore
    private let now: @Sendable () -> Date
    /// Sent as `X-Client-Installation-Id` so the Worker can rate limit per install.
    private let installationId: EntityID?
    private var session: Session?
    private var refreshTask: Task<Session, Error>?
    private let decoder = APICoding.makeDecoder()

    /// Emits when the server ends the session (refresh rejected, account deleted).
    nonisolated let sessionEnded: AsyncStream<SessionEndReason>
    private let sessionEndedContinuation: AsyncStream<SessionEndReason>.Continuation

    /// Codes on `/v1/auth/refresh` that mean the session is gone for good.
    static let sessionEndingCodes: Set<APIErrorCode> = [.unauthorized, .tokenExpired, .refreshTokenReused, .accountDeleted]

    /// Refresh this long before the access token's stated expiry.
    static let refreshLeeway: TimeInterval = 30

    init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport(),
         store: any SessionStore, installationId: EntityID? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.installationId = installationId
        self.transport = transport
        self.store = store
        self.now = now
        self.session = store.load()
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEndReason.self)
        sessionEnded = stream
        sessionEndedContinuation = continuation
    }

    var accountId: EntityID? { session?.accountId }
    var currentRefreshToken: String? { session?.refreshToken }

    // MARK: Session lifecycle

    func adopt(_ newSession: Session) throws {
        try store.save(newSession)
        session = newSession
    }

    /// Forgets the session locally. `reason` is set when the member didn't ask for it.
    func endSession(reason: SessionEndReason? = nil) {
        refreshTask?.cancel()
        refreshTask = nil
        let hadSession = session != nil
        session = nil
        store.clear()
        if hadSession, let reason { sessionEndedContinuation.yield(reason) }
    }

    // MARK: Requests

    func send<Response: Decodable>(_ endpoint: Endpoint, as type: Response.Type = Response.self) async throws -> Response {
        let data = try await sendForData(endpoint)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw AppError.api(.internalError, requestId: nil)
        }
    }

    /// For routes that answer 202 or 204.
    func sendNoContent(_ endpoint: Endpoint) async throws {
        _ = try await sendForData(endpoint)
    }

    func sendForData(_ endpoint: Endpoint) async throws -> Data {
        guard endpoint.authenticated else { return try await perform(endpoint, token: nil) }
        let token = try await validAccessToken()
        do {
            return try await perform(endpoint, token: token)
        } catch AppError.api(let code, _) where code == .tokenExpired || code == .unauthorized {
            // The token was rejected early (clock skew, revoked). Refresh once and retry.
            let fresh = try await refresh(replacing: token)
            do {
                return try await perform(endpoint, token: fresh.accessToken)
            } catch AppError.api(let code, let requestId) where code == .unauthorized || code == .tokenExpired {
                endSession(reason: .expired)
                throw AppError.api(code, requestId: requestId)
            }
        }
    }

    private func validAccessToken() async throws -> String {
        guard let session else { throw AppError.api(.unauthorized, requestId: nil) }
        if session.accessTokenExpiresAt.timeIntervalSince(now()) > Self.refreshLeeway {
            return session.accessToken
        }
        return try await refresh(replacing: session.accessToken).accessToken
    }

    /// Single-flight refresh. `replacing` is the access token the caller found
    /// stale; if another caller already swapped it, that newer session is used.
    private func refresh(replacing staleToken: String) async throws -> Session {
        if let session, session.accessToken != staleToken,
           session.accessTokenExpiresAt.timeIntervalSince(now()) > Self.refreshLeeway {
            return session
        }
        if let refreshTask { return try await refreshTask.value }
        guard let current = session else { throw AppError.api(.unauthorized, requestId: nil) }
        let task = Task { try await self.performRefresh(using: current.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(using refreshToken: String) async throws -> Session {
        let endpoint = try Endpoint.write(.post, "/v1/auth/refresh", body: RefreshRequest(refreshToken: refreshToken),
                                          authenticated: false)
        do {
            let data = try await perform(endpoint, token: nil)
            let fresh = try decoder.decode(Session.self, from: data)
            try adopt(fresh)
            return fresh
        } catch AppError.api(let code, let requestId) where Self.sessionEndingCodes.contains(code) {
            endSession(reason: .expired)
            throw AppError.api(code, requestId: requestId)
        } catch is DecodingError {
            throw AppError.api(.internalError, requestId: nil)
        }
    }

    private func perform(_ endpoint: Endpoint, token: String?) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)!
        if !endpoint.query.isEmpty { components.queryItems = endpoint.query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let installationId { request.setValue(installationId.description, forHTTPHeaderField: "X-Client-Installation-Id") }
        if let key = endpoint.idempotencyKey {
            request.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }

        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.send(request)
        } catch {
            throw error.asAppError
        }
        let (data, response) = result
        if (200..<300).contains(response.statusCode) { return data }

        let requestId = response.value(forHTTPHeaderField: "X-Request-Id")
        let error: AppError
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
            error = .api(envelope.error.code, requestId: envelope.error.requestId)
        } else {
            error = .api(Self.fallbackCode(status: response.statusCode), requestId: requestId)
        }
        if error.code == .accountDeleted { endSession(reason: .accountDeleted) }
        throw error
    }

    static func fallbackCode(status: Int) -> APIErrorCode {
        switch status {
        case 400: .validationFailed
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 409: .revisionConflict
        case 413: .bodyTooLarge
        case 429: .rateLimited
        case 502, 503, 504: .unavailable
        default: .internalError
        }
    }
}
