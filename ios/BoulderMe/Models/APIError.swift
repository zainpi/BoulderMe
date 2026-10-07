import Foundation

/// Stable error codes from `ErrorCode` in docs/api/openapi.yaml.
enum APIErrorCode: String, Codable, Sendable {
    case validationFailed = "validation_failed"
    case bodyTooLarge = "body_too_large"
    case invalidCursor = "invalid_cursor"
    case unauthorized
    case tokenExpired = "token_expired"
    case refreshTokenReused = "refresh_token_reused"
    case appleTokenInvalid = "apple_token_invalid"
    case nonceInvalid = "nonce_invalid"
    case accountDeleted = "account_deleted"
    case forbidden
    case notFound = "not_found"
    case revisionConflict = "revision_conflict"
    case invalidState = "invalid_state"
    case idempotencyMismatch = "idempotency_mismatch"
    case invitationAlreadyOpen = "invitation_already_open"
    case profileIncomplete = "profile_incomplete"
    case gymNotShared = "gym_not_shared"
    case gymLimitReached = "gym_limit_reached"
    case availabilityLimitReached = "availability_limit_reached"
    case invalidTime = "invalid_time"
    case chatClosed = "chat_closed"
    case rateLimited = "rate_limited"
    case unavailable
    case internalError = "internal_error"
    /// A code this build doesn't know yet. Never sent by the server as-is.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = APIErrorCode(rawValue: raw) ?? .unknown
    }
}

/// The `Error` envelope's inner object.
struct APIErrorBody: Codable, Sendable, Hashable {
    var code: APIErrorCode
    var message: String
    var requestId: String
}

struct APIErrorEnvelope: Codable, Sendable {
    var error: APIErrorBody
}

/// What services throw. Screens map it to friendly copy with `userMessage`;
/// the server's `message` is for logs, never the only UI.
enum AppError: Error, Equatable, Sendable {
    case api(APIErrorCode, requestId: String?)
    case offline
    /// Needs a real account (e.g. an action tapped in demo mode).
    case requiresAccount
    /// Wired in a later task; the screen shows a friendly placeholder.
    case notImplemented

    var code: APIErrorCode? {
        if case let .api(code, _) = self { return code }
        return nil
    }

    var title: String {
        switch self {
        case .offline: "You're offline"
        case .requiresAccount: "Sign in to do that"
        case .notImplemented: "Coming soon"
        case .api(.notFound, _): "This climber isn't available"
        case .api(.rateLimited, _): "Slow down a little"
        default: "Something slipped"
        }
    }

    var userMessage: String {
        switch self {
        case .offline:
            "Check your connection. We'll keep showing what we already have."
        case .requiresAccount:
            "You're exploring the demo. Sign in with Apple to make it real."
        case .notImplemented:
            "This part of BoulderMe is still on the wall. Check back soon."
        case let .api(code, _):
            switch code {
            case .notFound: "They may have paused discovery or left BoulderMe."
            case .rateLimited: "That was a lot of taps. Try again in a minute."
            case .invitationAlreadyOpen: "You already have an open invite with this climber."
            case .invalidState: "This invite changed in the meantime, so that didn't go through."
            case .idempotencyMismatch: "That didn't go through. Please try again."
            case .chatClosed: "This chat is closed, so new messages can't be sent."
            case .gymNotShared: "Pick a gym you both climb at."
            case .gymLimitReached: "You can add up to 10 gyms."
            case .availabilityLimitReached: "You can add up to 21 time slots."
            case .invalidTime: "Pick a time between an hour and 60 days from now."
            case .profileIncomplete: "Finish your profile first."
            case .revisionConflict: "Your profile changed somewhere else."
            case .unauthorized, .tokenExpired, .refreshTokenReused: "Please sign in again."
            case .accountDeleted: "This account has been deleted."
            case .unavailable: "BoulderMe is taking a breather. Try again shortly."
            default: "Please try again. If it keeps happening, let us know."
            }
        }
    }
}

extension Error {
    /// Any error as an `AppError`, treating URL connectivity failures as offline.
    var asAppError: AppError {
        if let appError = self as? AppError { return appError }
        if let urlError = self as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(urlError.code) {
            return .offline
        }
        return .api(.internalError, requestId: nil)
    }
}
