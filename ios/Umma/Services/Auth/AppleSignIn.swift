import CryptoKit
import Foundation

/// One-time value that binds an identity token to the sign-in request that asked for it
/// (brief 010). The provider is given `hashed`; our server gets `raw` and checks the pair.
struct SignInNonce: Equatable, Sendable {
    let raw: String

    init() {
        var generator = SystemRandomNumberGenerator()
        raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    init(raw: String) {
        self.raw = raw
    }

    /// Lowercase hex SHA-256 of `raw`.
    var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the sign-in screen takes out of Apple's authorization result. Kept free of
/// `AuthenticationServices` types so tests can build it.
enum AppleSignIn {
    struct Credential: Equatable, Sendable {
        let identityToken: String
        /// Only present on a person's first sign-in with this Apple ID.
        let displayName: String?
    }

    enum Failure: Error, Equatable {
        case missingIdentityToken
    }

    static func credential(identityToken: Data?, fullName: PersonNameComponents?) throws -> Credential {
        guard let identityToken, let token = String(data: identityToken, encoding: .utf8), !token.isEmpty else {
            throw Failure.missingIdentityToken
        }
        return Credential(identityToken: token, displayName: displayName(from: fullName))
    }

    /// "Mina Cho" from the name Apple shares, or nil when it shares none.
    static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(120))
    }
}
