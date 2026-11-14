import AuthenticationServices
import UIKit
import os

/// The system web sign-in sheet (`ASWebAuthenticationSession`). It shares Safari's cookies, so a
/// person already signed in to Google there is not asked for a password again; iOS shows its own
/// "Umma wants to use google.com to sign in" confirmation first.
@MainActor
final class SystemWebAuthPresenter: NSObject, WebAuthPresenting, ASWebAuthenticationPresentationContextProviding {
    /// Non-nil while a sheet is up; also the start gate (one sheet at a time).
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard session == nil else { throw GoogleSignIn.Failure.cancelled }
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    once.resume(.success(callback))
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    once.resume(.failure(GoogleSignIn.Failure.cancelled))
                } else {
                    once.resume(.failure(GoogleSignIn.Failure.denied))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                once.resume(.failure(GoogleSignIn.Failure.denied))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}

/// Resumes a continuation exactly once, whichever of "could not start" and the completion
/// handler gets there first.
private final class ResumeOnce: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<URL, Error>?>

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ result: Result<URL, Error>) {
        let pending = continuation.withLock { value -> CheckedContinuation<URL, Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }
}
