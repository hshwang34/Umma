import CryptoKit
import Foundation

/// The iOS OAuth client the PM creates in Google Cloud (brief 010, DECISIONS #33). Nil when no
/// client ID is configured, and then the Google button is not shown at all.
struct GoogleSignInConfig: Equatable, Sendable {
    private static let suffix = ".apps.googleusercontent.com"
    let clientID: String

    init?(clientID: String) {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(Self.suffix), trimmed.count > Self.suffix.count,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        self.clientID = trimmed
    }

    /// Google's redirect scheme for an iOS client: the client ID with its dot-parts reversed.
    var redirectScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
}

/// Sign in with Google through the system web sign-in sheet: authorization code + PKCE, no
/// Google SDK and no client secret. The pieces here are pure so tests can check every value.
///
/// Nonce: Google copies the `nonce` request parameter into the ID token unchanged. The app
/// sends the SHA-256 of its raw nonce, and our server (which gets the raw one) checks the pair,
/// exactly as with Sign in with Apple.
enum GoogleSignIn {
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let scope = "openid email profile"

    enum Failure: Error, Equatable {
        /// The person closed the sheet. Not worth a message.
        case cancelled
        /// Google said no (`error=access_denied`, ...).
        case denied
        /// The redirect does not belong to this attempt.
        case stateMismatch
        case missingCode
        case tokenExchangeFailed
        case missingIDToken
        case invalidConfiguration
    }

    /// The one-time values of a single sign-in attempt.
    struct Attempt: Equatable, Sendable {
        let nonce: SignInNonce
        let state: String
        let codeVerifier: String

        init() {
            self.init(nonce: SignInNonce(), state: GoogleSignIn.randomURLSafe(bytes: 16),
                      codeVerifier: GoogleSignIn.randomURLSafe(bytes: 32))
        }

        init(nonce: SignInNonce, state: String, codeVerifier: String) {
            self.nonce = nonce
            self.state = state
            self.codeVerifier = codeVerifier
        }

        /// PKCE S256 (RFC 7636): base64url(SHA-256(verifier)), no padding.
        var codeChallenge: String {
            GoogleSignIn.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        }
    }

    static func authorizationURL(config: GoogleSignInConfig, attempt: Attempt) throws -> URL {
        guard var components = URLComponents(string: authorizationEndpoint) else { throw Failure.invalidConfiguration }
        components.percentEncodedQuery = APIClient.percentEncodedQuery([
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: attempt.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: attempt.state),
            // The hash, never the raw nonce: the raw value only ever goes to our server.
            URLQueryItem(name: "nonce", value: attempt.nonce.hashed)
        ])
        guard let url = components.url else { throw Failure.invalidConfiguration }
        return url
    }

    /// The authorization code from the redirect, once it is proven to answer this attempt.
    static func authorizationCode(fromCallback url: URL, config: GoogleSignInConfig, attempt: Attempt) throws -> String {
        guard url.scheme?.lowercased() == config.redirectScheme.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw Failure.stateMismatch }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == attempt.state else { throw Failure.stateMismatch }
        if value("error") != nil { throw Failure.denied }
        guard let code = value("code"), !code.isEmpty else { throw Failure.missingCode }
        return code
    }

    static func tokenRequest(code: String, config: GoogleSignInConfig, attempt: Attempt) throws -> URLRequest {
        guard let url = URL(string: tokenEndpoint) else { throw Failure.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(APIClient.percentEncodedQuery([
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "code_verifier", value: attempt.codeVerifier)
        ]).utf8)
        return request
    }

    static func idToken(fromTokenResponse data: Data, status: Int) throws -> String {
        guard (200...299).contains(status) else { throw Failure.tokenExchangeFailed }
        struct TokenResponse: Decodable { let id_token: String? }
        guard let token = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.id_token, !token.isEmpty else {
            throw Failure.missingIDToken
        }
        return token
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Shows a web sign-in page and returns the URL it redirects to. The real one is the system
/// sheet (`SystemWebAuthPresenter`); tests use a fake.
@MainActor
protocol WebAuthPresenting {
    /// Throws `GoogleSignIn.Failure.cancelled` when the person closes the sheet.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// One Google sign-in: sheet → authorization code → ID token. The ID token and the raw nonce go
/// to our server, which is what actually signs the person in (`AuthStore.signInWithGoogle`).
@MainActor
final class GoogleSignInFlow {
    struct Credential: Equatable, Sendable {
        let idToken: String
        let nonce: SignInNonce
    }

    let config: GoogleSignInConfig
    private let presenter: any WebAuthPresenting
    private let session: URLSessionProtocol
    private let makeAttempt: () -> GoogleSignIn.Attempt

    init(config: GoogleSignInConfig,
         presenter: any WebAuthPresenting,
         session: URLSessionProtocol = URLSession.shared,
         makeAttempt: @escaping () -> GoogleSignIn.Attempt = { GoogleSignIn.Attempt() }) {
        self.config = config
        self.presenter = presenter
        self.session = session
        self.makeAttempt = makeAttempt
    }

    func run() async throws -> Credential {
        let attempt = makeAttempt()
        let url = try GoogleSignIn.authorizationURL(config: config, attempt: attempt)
        let callback = try await presenter.authenticate(url: url, callbackScheme: config.redirectScheme)
        let code = try GoogleSignIn.authorizationCode(fromCallback: callback, config: config, attempt: attempt)
        let request = try GoogleSignIn.tokenRequest(code: code, config: config, attempt: attempt)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleSignIn.Failure.tokenExchangeFailed
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return Credential(idToken: try GoogleSignIn.idToken(fromTokenResponse: data, status: status), nonce: attempt.nonce)
    }
}

/// What the sign-in screen says when Google sign-in does not finish.
enum GoogleSignInPresentation {
    static let failureMessage = "Couldn’t sign in with Google. Try again."

    /// Nil when there is nothing to say (the person closed the sheet).
    static func message(for failure: GoogleSignIn.Failure) -> String? {
        failure == .cancelled ? nil : failureMessage
    }
}
