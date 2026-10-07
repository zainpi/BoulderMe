import AuthenticationServices
import CryptoKit
import UIKit

/// What the app needs back from Apple's sheet.
struct AppleCredential: Sendable, Equatable {
    var identityToken: String
    var authorizationCode: String
    /// Only present the first time this Apple ID authorizes the app.
    var givenName: String?
}

/// Presents Sign in with Apple. Throws `CancellationError` when the member
/// closes the sheet.
@MainActor
protocol AppleSignInProviding {
    func authorize(hashedNonce: String) async throws -> AppleCredential
}

enum Nonce {
    /// `SHA256(nonce)` as lowercase hex, the form Apple puts in the token's `nonce` claim.
    static func sha256Hex(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class SystemAppleSignIn: NSObject, AppleSignInProviding, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var controller: ASAuthorizationController?

    func authorize(hashedNonce: String) async throws -> AppleCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        request.nonce = hashedNonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<AppleCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        let givenName = credential?.fullName?.givenName
        MainActor.assumeIsolated {
            if let token, let code {
                finish(.success(AppleCredential(identityToken: token, authorizationCode: code, givenName: givenName)))
            } else {
                finish(.failure(AppError.api(.appleTokenInvalid, requestId: nil)))
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let canceled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated {
            finish(.failure(canceled ? CancellationError() : AppError.api(.appleTokenInvalid, requestId: nil)))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
