import Foundation
import XCTest
@testable import Umma

/// Brief 010: review access. `POST /v1/auth/review` with `{"code": "<text>"}` answers with the
/// usual sign-in response; 401 = wrong code, 429 = too many tries, 404 = no review login here.
@MainActor
final class ReviewSignInTests: XCTestCase {
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

    private func envelope(_ code: String, _ message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)","retryable":false,"correlation_id":"c-review"}}"#.utf8)
    }

    func testCopy() {
        XCTAssertEqual(ReviewSignIn.linkTitle, "Have a review code?")
        XCTAssertEqual(ReviewSignIn.submitTitle, "Sign in")
        XCTAssertFalse(ReviewSignIn.canSubmit(""))
        XCTAssertFalse(ReviewSignIn.canSubmit("  \n"))
        XCTAssertTrue(ReviewSignIn.canSubmit("abc"))
    }

    func testSignInSendsOnlyTheCodeAndStartsTheSession() async throws {
        StubURLProtocol.install { request in (.stub(request, status: 200), Data(AuthFixtures.loginJSON.utf8)) }
        let (auth, _, tokens) = makeAuth()
        await auth.restore()

        try await auth.signInWithReviewCode("  review-code-value \n")

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(tokens.currentToken(), "jwt-1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/v1/auth/review" })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.url?.query, "the code is never in the URL, which is what gets logged")
        let json = try request.jsonBody()
        XCTAssertEqual(json["code"] as? String, "review-code-value", "pasted spaces are dropped")
        XCTAssertEqual(Set(json.keys), ["code"])
    }

    func testEachRefusalHasItsOwnPlainMessageAndNeverTheGlobalSignOutPath() async throws {
        let cases: [(Int, Data, String)] = [
            (401, envelope("UNAUTHORIZED", "Invalid review code"), "That code didn’t work."),
            (429, envelope("RATE_LIMITED", "rate limit exceeded: 5 per 1 minute"), "Too many tries. Wait a minute and try again."),
            (429, Data(), "Too many tries. Wait a minute and try again."),
            (404, envelope("NOT_FOUND", "Not found"), "Review sign-in isn’t available right now."),
            (404, Data(), "Review sign-in isn’t available right now.")
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.install { request in (.stub(request, status: status), body) }
            let (auth, client, tokens) = makeAuth()
            await auth.restore()
            client.events.onUnauthorized { _ in
                XCTFail("a refused review code must not fire the global unauthorized path")
            }
            do {
                try await auth.signInWithReviewCode("wrong")
                XCTFail("expected \(status)")
            } catch {
                XCTAssertEqual(ReviewSignIn.message(for: error), expected, "\(status)")
            }
            XCTAssertEqual(auth.state, .signedOut)
            XCTAssertNil(tokens.currentToken())
            XCTAssertNil(auth.banner)
        }
    }

    func testOtherFailuresFallBackToThePlainErrorCopy() {
        XCTAssertEqual(ReviewSignIn.message(for: URLError(.notConnectedToInternet)), APIError.connectionMessage)
        XCTAssertEqual(ReviewSignIn.message(for: APIError.http(status: 500, correlationId: nil)),
                       APIError.http(status: 500, correlationId: nil).userMessage)
    }

    func testARefusedCodeWhileSomeoneIsSignedInLeavesThemSignedIn() async throws {
        AuthFixtures.installHappyPath()
        let (auth, _, tokens) = makeAuth()
        try await auth.requestCode(email: "tester@example.com")
        try await auth.verify(challengeId: "chal-1", code: "123456")
        StubURLProtocol.install { request in (.stub(request, status: 401), Data()) }
        do { try await auth.signInWithReviewCode("wrong"); XCTFail("expected 401") } catch {}
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(tokens.currentToken(), "jwt-1")
    }
}
