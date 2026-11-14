import Foundation
import XCTest
@testable import Umma

/// Brief 010: Sign in with Apple. The nonce pair, what is taken from Apple's result, the request
/// the server sees, and that a refused token leaves the app signed out.
@MainActor
final class AppleSignInTests: XCTestCase {
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

    // MARK: - Nonce

    func testNonceIsRandomAndLongEnoughForTheServer() {
        let one = SignInNonce()
        let two = SignInNonce()
        XCTAssertNotEqual(one.raw, two.raw)
        XCTAssertEqual(one.raw.count, 64)
        XCTAssertTrue(one.raw.allSatisfy { $0.isHexDigit })
    }

    func testHashedNonceIsLowercaseHexSHA256OfRaw() {
        // SHA-256("abc"), FIPS 180-2 test vector.
        XCTAssertEqual(SignInNonce(raw: "abc").hashed,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Apple's result

    func testCredentialTakesTokenAndName() throws {
        var name = PersonNameComponents()
        name.givenName = "Mina"
        name.familyName = "Cho"
        let credential = try AppleSignIn.credential(identityToken: Data("header.payload.sig".utf8), fullName: name)
        XCTAssertEqual(credential.identityToken, "header.payload.sig")
        XCTAssertEqual(credential.displayName, "Mina Cho")
    }

    func testNameIsNilWhenAppleSharesNone() throws {
        XCTAssertNil(AppleSignIn.displayName(from: nil))
        XCTAssertNil(AppleSignIn.displayName(from: PersonNameComponents()))
        let credential = try AppleSignIn.credential(identityToken: Data("t".utf8), fullName: nil)
        XCTAssertNil(credential.displayName)
    }

    func testMissingOrUnreadableTokenIsRefused() {
        for token in [nil, Data(), Data([0xFF, 0xFE])] {
            XCTAssertThrowsError(try AppleSignIn.credential(identityToken: token, fullName: nil)) { error in
                XCTAssertEqual(error as? AppleSignIn.Failure, .missingIdentityToken)
            }
        }
    }

    // MARK: - Sign-in

    func testSignInSendsTokenRawNonceAndNameThenStartsTheSession() async throws {
        AuthFixtures.installHappyPath()
        let (auth, _, tokens) = makeAuth()
        await auth.restore()
        let nonce = SignInNonce(raw: "raw-nonce-0123456789abcdef")

        try await auth.signInWithApple(.init(identityToken: "apple.identity.token", displayName: "Mina Cho"), nonce: nonce)

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.user?.displayName, "Tester")
        XCTAssertEqual(tokens.currentToken(), "jwt-1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/v1/auth/apple" })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try request.jsonBody()
        XCTAssertEqual(json["identity_token"] as? String, "apple.identity.token")
        XCTAssertEqual(json["nonce"] as? String, "raw-nonce-0123456789abcdef", "the server gets the raw nonce, Apple got the hash")
        XCTAssertEqual(json["display_name"] as? String, "Mina Cho")
    }

    func testNameIsLeftOutOfTheRequestWhenAppleSharesNone() async throws {
        AuthFixtures.installHappyPath()
        let (auth, _, _) = makeAuth()
        await auth.restore()
        try await auth.signInWithApple(.init(identityToken: "apple.identity.token", displayName: nil), nonce: SignInNonce())
        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/v1/auth/apple" })
        XCTAssertNil(try request.jsonBody()["display_name"], "the server refuses unknown or null extras")
    }

    func testRefusedTokenStaysSignedOutWithoutTheGlobalSignOutPath() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 401), Data(AuthFixtures.badAppleJSON.utf8))
        }
        let (auth, client, tokens) = makeAuth()
        await auth.restore()
        client.events.onUnauthorized { _ in
            XCTFail("401 on sign-in must not fire the global unauthorized path")
        }
        do {
            try await auth.signInWithApple(.init(identityToken: "bad", displayName: nil), nonce: SignInNonce())
            XCTFail("expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error.userMessage, "Invalid Apple sign-in")
        }
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(tokens.currentToken())
    }
}
