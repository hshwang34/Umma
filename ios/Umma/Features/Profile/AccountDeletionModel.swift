import Foundation
import Observation

/// Profile → Delete account (brief 010, App Review guideline 5.1.1(v)). The view shows the
/// confirmation; this owns the request and what the row says while it runs and if it fails.
@MainActor
@Observable
final class AccountDeletionModel {
    static let confirmationTitle = "Delete your account?"
    static let confirmationMessage = "This permanently deletes your recipes, drafts, pantry, saved recipes and preferences. It can’t be undone."
    static let confirmButton = "Delete account"
    static let cancelButton = "Keep account"
    static let footer = "Deletes your account and everything in it."
    static let failureMessage = "Couldn’t delete your account. Check your connection and try again."
    /// Shown on the sign-in screen afterwards.
    static let deletedNotice = "Your account was deleted."

    private(set) var isDeleting = false
    /// Inline under the button after a failed attempt; the person stays signed in.
    private(set) var errorMessage: String?

    private let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
    }

    /// Runs after the person confirms. A second tap while one request is in flight does nothing.
    func deleteConfirmed() async {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await auth.deleteAccount()
        } catch APIError.unauthorized {
            // The session was already over; the usual sign-out path says so on the sign-in screen.
        } catch {
            errorMessage = Self.failureMessage
        }
    }
}
