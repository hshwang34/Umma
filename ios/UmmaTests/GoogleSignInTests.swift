import CryptoKit
import Foundation
import XCTest
@testable import Umma

/// Scripted web sign-in sheet: records the URL it was asked to show and answers with a redirect.
@MainActor
final class FakeWebAuthPresenter: WebAuthPresenting {
    private(set) var shown: [(url: URL, scheme: String)] = []
    var respond: (URL) throws -> URL

    init(respond: @escaping (URL) throws -> URL) {
        self.respond = respond
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        shown.append((url, callbackScheme))
        return try respond(url)
    }
}

/// Brief 010 PR 6b: Sign in with Google through the system web sign-in sheet (PKCE, no SDK).
@MainActor
final class GoogleSignInTests: XCTestCase {
    private let clientID = "1234567890-abcdef.apps.googleusercontent.com"
    private var config: GoogleSignInConfig { GoogleSignInConfig(clientID: clientID)! }
    private let attempt = GoogleSignIn.Attempt(
        nonce: SignInNonce(raw: "raw-nonce-0123456789abcdef"),
        state: "state-1",
        // RFC 7636 appendix B.
        codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    )

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? request.httpBodyStream.map(readAll) ?? Data(), encoding: .utf8) ?? ""
        return query(URL(string: "x://x?\(body)")!)
    }

    private func makeAuth() -> (auth: AuthStore, client: APIClient, tokens: InMemoryTokenStore) {
        let tokens = InMemoryTokenStore(token: nil)
        let generation = SessionGeneration()
        let defaults = freshDefaults()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: tokens,
            sessionGeneration: generation
        )
        let auth = AuthStore(api: client, tokenStore: tokens, defaults: defaults, generation: generation)
        AppEnvironment.bind(api: client, auth: auth, settings: ServerSettings(defaults: defaults), recipeCache: InMemoryRecipeCache())
        return (auth, client, tokens)
    }

    // MARK: - Config

    func testNoClientIDMeansNoGoogleSignIn() {
        XCTAssertNil(GoogleSignInConfig(clientID: ""))
        XCTAssertNil(GoogleSignInConfig(clientID: "   "))
        XCTAssertNil(GoogleSignInConfig(clientID: ".apps.googleusercontent.com"))
        XCTAssertNil(GoogleSignInConfig(clientID: "not a client id"))
        XCTAssertNil(GoogleSignInConfig(clientID: "abc.apps.googleusercontent.com/evil"))
    }

    func testTheShippedClientIDIsEitherUnsetOrWellFormed() {
        let shipped = BuildConfig.googleIOSClientID
        XCTAssertTrue(shipped.isEmpty || GoogleSignInConfig(clientID: shipped) != nil)
    }

    func testRedirectIsTheReversedClientID() {
        XCTAssertEqual(config.redirectScheme, "com.googleusercontent.apps.1234567890-abcdef")
        XCTAssertEqual(config.redirectURI, "com.googleusercontent.apps.1234567890-abcdef:/oauth2redirect")
        XCTAssertEqual(GoogleSignInConfig(clientID: "  \(clientID)\n")?.clientID, clientID)
    }

    // MARK: - Attempt

    func testAttemptValuesAreFreshAndLongEnough() {
        let one = GoogleSignIn.Attempt()
        let two = GoogleSignIn.Attempt()
        XCTAssertNotEqual(one.nonce, two.nonce)
        XCTAssertNotEqual(one.state, two.state)
        XCTAssertNotEqual(one.codeVerifier, two.codeVerifier)
        XCTAssertEqual(one.codeVerifier.count, 43, "RFC 7636: 43 to 128 characters")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(one.codeVerifier.unicodeScalars.allSatisfy(unreserved.contains))
        XCTAssertGreaterThanOrEqual(one.nonce.raw.count, 16, "the server's minimum")
    }

    func testCodeChallengeMatchesTheRFC7636Vector() {
        XCTAssertEqual(attempt.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: - Authorization URL

    func testAuthorizationURLCarriesPKCEStateAndTheHashedNonce() throws {
        let url = try GoogleSignIn.authorizationURL(config: config, attempt: attempt)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        let items = query(url)
        XCTAssertEqual(items["client_id"], clientID)
        XCTAssertEqual(items["redirect_uri"], config.redirectURI)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid email profile")
        XCTAssertEqual(items["code_challenge"], attempt.codeChallenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertNil(items["client_secret"])
    }

    /// The backend accepts a token only if its `nonce` claim equals the lowercase hex SHA-256 of
    /// the raw nonce in the request body (`oidc.py`). Google copies the `nonce` parameter into the
    /// token unchanged, so the parameter must be exactly that hash and never the raw value.
    func testNonceSentToGoogleIsWhatTheBackendWillCompareAgainst() throws {
        let sent = try XCTUnwrap(query(try GoogleSignIn.authorizationURL(config: config, attempt: attempt))["nonce"])
        let expectedByBackend = SHA256.hash(data: Data(attempt.nonce.raw.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sent, expectedByBackend)
        XCTAssertEqual(sent, sent.lowercased())
        XCTAssertNotEqual(sent, attempt.nonce.raw)
    }

    // MARK: - Redirect

    func testCodeIsTakenFromARedirectThatAnswersThisAttempt() throws {
        let url = try XCTUnwrap(URL(string: "\(config.redirectURI)?state=state-1&code=4%2F0Abc-def&scope=openid"))
        XCTAssertEqual(try GoogleSignIn.authorizationCode(fromCallback: url, config: config, attempt: attempt), "4/0Abc-def")
    }

    func testRedirectsThatDoNotBelongToThisAttemptAreRefused() throws {
        let cases: [(String, GoogleSignIn.Failure)] = [
            ("\(config.redirectURI)?state=other&code=abc", .stateMismatch),
            ("\(config.redirectURI)?code=abc", .stateMismatch),
            ("umma://oauth2redirect?state=state-1&code=abc", .stateMismatch),
            ("\(config.redirectURI)?state=state-1&error=access_denied", .denied),
            ("\(config.redirectURI)?state=state-1", .missingCode),
            ("\(config.redirectURI)?state=state-1&code=", .missingCode)
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try GoogleSignIn.authorizationCode(fromCallback: url, config: config, attempt: attempt), raw) { error in
                XCTAssertEqual(error as? GoogleSignIn.Failure, expected, raw)
            }
        }
    }

    // MARK: - Token exchange

    func testTokenRequestSendsTheVerifierAndNoSecret() throws {
        let request = try GoogleSignIn.tokenRequest(code: "4/0Abc+def", config: config, attempt: attempt)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let fields = form(request)
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code"], "4/0Abc+def", "a + in the code survives form encoding")
        XCTAssertEqual(fields["client_id"], clientID)
        XCTAssertEqual(fields["redirect_uri"], config.redirectURI)
        XCTAssertEqual(fields["code_verifier"], attempt.codeVerifier)
        XCTAssertNil(fields["client_secret"])
    }

    func testIDTokenIsReadFromTheTokenResponse() throws {
        let ok = Data(#"{"access_token":"a","id_token":"header.payload.sig","expires_in":3599}"#.utf8)
        XCTAssertEqual(try GoogleSignIn.idToken(fromTokenResponse: ok, status: 200), "header.payload.sig")
        XCTAssertThrowsError(try GoogleSignIn.idToken(fromTokenResponse: ok, status: 400)) {
            XCTAssertEqual($0 as? GoogleSignIn.Failure, .tokenExchangeFailed)
        }
        for body in [#"{"access_token":"a"}"#, #"{"id_token":""}"#, "not json"] {
            XCTAssertThrowsError(try GoogleSignIn.idToken(fromTokenResponse: Data(body.utf8), status: 200)) {
                XCTAssertEqual($0 as? GoogleSignIn.Failure, .missingIDToken)
            }
        }
    }

    // MARK: - Flow

    private func makeFlow(_ presenter: FakeWebAuthPresenter) -> GoogleSignInFlow {
        let attempt = attempt
        return GoogleSignInFlow(config: config, presenter: presenter, session: StubURLProtocol.makeSession(), makeAttempt: { attempt })
    }

    func testFlowShowsTheSheetExchangesTheCodeAndReturnsTokenWithTheSameNonce() async throws {
        StubURLProtocol.install { request in
            XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
            return (.stub(request, status: 200), Data(#"{"id_token":"google.id.token"}"#.utf8))
        }
        let redirect = config.redirectURI
        let presenter = FakeWebAuthPresenter { _ in try XCTUnwrap(URL(string: "\(redirect)?state=state-1&code=the-code")) }

        let credential = try await makeFlow(presenter).run()

        XCTAssertEqual(credential, .init(idToken: "google.id.token", nonce: attempt.nonce))
        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(presenter.shown.first?.scheme, config.redirectScheme)
        XCTAssertEqual(query(try XCTUnwrap(presenter.shown.first?.url))["nonce"], attempt.nonce.hashed)
        XCTAssertEqual(form(try XCTUnwrap(StubURLProtocol.requests.first))["code"], "the-code")
    }

    func testClosingTheSheetIsCancelledAndNothingIsSentAnywhere() async {
        StubURLProtocol.install { _ in throw URLError(.badServerResponse) }
        let presenter = FakeWebAuthPresenter { _ in throw GoogleSignIn.Failure.cancelled }
        do {
            _ = try await makeFlow(presenter).run()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleSignIn.Failure, .cancelled)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertNil(GoogleSignInPresentation.message(for: .cancelled), "closing the sheet shows no error")
    }

    func testAForgedRedirectNeverReachesTheTokenEndpoint() async {
        StubURLProtocol.install { _ in throw URLError(.badServerResponse) }
        let redirect = config.redirectURI
        let presenter = FakeWebAuthPresenter { _ in try XCTUnwrap(URL(string: "\(redirect)?state=forged&code=stolen")) }
        do {
            _ = try await makeFlow(presenter).run()
            XCTFail("expected a state mismatch")
        } catch {
            XCTAssertEqual(error as? GoogleSignIn.Failure, .stateMismatch)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAFailedExchangeIsOneCalmMessage() async {
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let redirect = config.redirectURI
        let presenter = FakeWebAuthPresenter { _ in try XCTUnwrap(URL(string: "\(redirect)?state=state-1&code=c")) }
        do {
            _ = try await makeFlow(presenter).run()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? GoogleSignIn.Failure, .tokenExchangeFailed)
        }
        for failure in [GoogleSignIn.Failure.denied, .stateMismatch, .missingCode, .tokenExchangeFailed, .missingIDToken, .invalidConfiguration] {
            XCTAssertEqual(GoogleSignInPresentation.message(for: failure), "Couldn’t sign in with Google. Try again.")
        }
    }

    // MARK: - Our server

    func testSignInSendsOnlyTheIDTokenAndRawNonceThenStartsTheSession() async throws {
        AuthFixtures.installHappyPath()
        let (auth, _, tokens) = makeAuth()
        await auth.restore()

        try await auth.signInWithGoogle(.init(idToken: "google.id.token.long-enough", nonce: attempt.nonce))

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(tokens.currentToken(), "jwt-1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/v1/auth/google" })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try request.jsonBody()
        XCTAssertEqual(json["id_token"] as? String, "google.id.token.long-enough")
        XCTAssertEqual(json["nonce"] as? String, "raw-nonce-0123456789abcdef", "the server gets the raw nonce, Google got the hash")
        XCTAssertEqual(Set(json.keys), ["id_token", "nonce"], "the server refuses any other field")
    }

    func testRefusedTokenStaysSignedOutWithoutTheGlobalSignOutPath() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 401), Data(#"{"error":{"code":"UNAUTHORIZED","message":"Invalid Google sign-in","retryable":false,"correlation_id":"c-google"}}"#.utf8))
        }
        let (auth, client, tokens) = makeAuth()
        await auth.restore()
        client.events.onUnauthorized { _ in
            XCTFail("401 on sign-in must not fire the global unauthorized path")
        }
        do {
            try await auth.signInWithGoogle(.init(idToken: "bad", nonce: SignInNonce()))
            XCTFail("expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error.userMessage, "Invalid Google sign-in")
        }
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(tokens.currentToken())
        XCTAssertNil(auth.banner)
    }

    func testAFailureMidSessionDoesNotSignOutTheCurrentUser() async throws {
        // Signed in already (e.g. the sheet was opened twice): a refused Google token leaves it be.
        AuthFixtures.installHappyPath()
        let (auth, _, tokens) = makeAuth()
        try await auth.signInWithGoogle(.init(idToken: "google.id.token.long-enough", nonce: attempt.nonce))
        StubURLProtocol.install { request in (.stub(request, status: 401), Data()) }
        do {
            try await auth.signInWithGoogle(.init(idToken: "bad", nonce: SignInNonce()))
            XCTFail("expected 401")
        } catch {}
        await Task.yield()
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(tokens.currentToken(), "jwt-1")
    }
}
