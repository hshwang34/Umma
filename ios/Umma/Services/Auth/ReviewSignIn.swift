import Foundation

/// Review access (brief 010): App Review signs in to one sandbox account with a code instead of
/// an Apple or Google account. The code is a server secret; the app only passes it on and never
/// stores or logs it.
enum ReviewSignIn {
    static let linkTitle = "Have a review code?"
    static let fieldLabel = "Review code"
    static let submitTitle = "Sign in"
    static let cancelTitle = "Cancel"
    static let wrongCodeMessage = "That code didn’t work."
    static let tooManyTriesMessage = "Too many tries. Wait a minute and try again."
    static let unavailableMessage = "Review sign-in isn’t available right now."

    /// The code as it is sent: surrounding spaces from a paste are dropped.
    static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canSubmit(_ code: String) -> Bool {
        !normalized(code).isEmpty
    }

    /// What the sign-in screen says when the server does not accept the code.
    static func message(for error: Error) -> String {
        switch (error as? APIError)?.status {
        case 401: wrongCodeMessage
        case 429: tooManyTriesMessage
        case 404: unavailableMessage
        default: error.userFacingMessage
        }
    }
}
