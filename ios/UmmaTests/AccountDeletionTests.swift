import Foundation
import XCTest
@testable import Umma

/// Brief 010 PR 7: Profile → Delete account. `DELETE /v1/me` answers 204; afterwards the phone
/// holds nothing of the account, exactly as after a server change.
@MainActor
final class AccountDeletionTests: XCTestCase {
    private struct Harness {
        let client: APIClient
        let tokens: InMemoryTokenStore
        let defaults: UserDefaults
        let cache: InMemoryRecipeCache
        let auth: AuthStore
        let model: AccountDeletionModel
    }

    /// Signed in through the stubbed dev sign-in, with a cached recipe list.
    private func makeSignedIn() async throws -> Harness {
        let tokens = InMemoryTokenStore(token: nil)
        let generation = SessionGeneration()
        let defaults = freshDefaults()
        let cache = InMemoryRecipeCache()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: tokens,
            sessionGeneration: generation
        )
        let auth = AuthStore(api: client, tokenStore: tokens, defaults: defaults, recipeCache: cache, generation: generation)
        AppEnvironment.bind(api: client, auth: auth, settings: ServerSettings(defaults: defaults), recipeCache: cache)
        AuthFixtures.installHappyPath()
        try await auth.requestCode(email: "tester@example.com")
        try await auth.verify(challengeId: "chal-1", code: "123456")
        try cache.save([])
        XCTAssertTrue(auth.isSignedIn)
        return Harness(client: client, tokens: tokens, defaults: defaults, cache: cache, auth: auth,
                       model: AccountDeletionModel(auth: auth))
    }

    private var deleteRequests: [URLRequest] {
        StubURLProtocol.requests.filter { $0.httpMethod == "DELETE" && $0.url?.path == "/v1/me" }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testDeletingSendsAnAuthenticatedDeleteThenWipesTheLocalAccount() async throws {
        let h = try await makeSignedIn()
        var cleared = 0
        let previous = h.auth.onCredentialsCleared
        h.auth.onCredentialsCleared = { previous?(); cleared += 1 }
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }

        await h.model.deleteConfirmed()

        let request = try XCTUnwrap(deleteRequests.first)
        XCTAssertEqual(deleteRequests.count, 1)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-1")
        XCTAssertEqual(h.auth.state, .signedOut, "back to sign-in")
        XCTAssertNil(h.tokens.currentToken())
        XCTAssertNil(h.defaults.data(forKey: AuthStore.cachedUserKey))
        XCTAssertNil(h.cache.load())
        XCTAssertNil(h.auth.pendingChallenge)
        XCTAssertNil(h.auth.pendingEmail)
        XCTAssertGreaterThanOrEqual(cleared, 1, "cooking state and other account-scoped data go too")
        XCTAssertNil(h.auth.banner, "a deletion the person asked for is not an error")
        XCTAssertEqual(h.auth.notice, "Your account was deleted.")
        XCTAssertNil(h.model.errorMessage)
        XCTAssertFalse(h.model.isDeleting)
    }

    func testServerFailureLeavesThePersonSignedInWithAnInlineError() async throws {
        let h = try await makeSignedIn()
        StubURLProtocol.install { request in
            (.stub(request, status: 503), Data(#"{"error":{"code":"PROVIDER_UNAVAILABLE","message":"apple revoke failed: upstream 503","retryable":true,"correlation_id":"c-del"}}"#.utf8))
        }

        await h.model.deleteConfirmed()

        XCTAssertTrue(h.auth.isSignedIn)
        XCTAssertEqual(h.tokens.currentToken(), "jwt-1")
        XCTAssertNotNil(h.defaults.data(forKey: AuthStore.cachedUserKey))
        XCTAssertNotNil(h.cache.load())
        XCTAssertNil(h.auth.notice)
        XCTAssertEqual(h.model.errorMessage, "Couldn’t delete your account. Check your connection and try again.",
                       "plain copy, not the server's internals")
        XCTAssertFalse(h.model.isDeleting)
    }

    func testNetworkFailureLeavesThePersonSignedInAndARetryCanSucceed() async throws {
        let h = try await makeSignedIn()
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        await h.model.deleteConfirmed()
        XCTAssertTrue(h.auth.isSignedIn)
        XCTAssertEqual(h.model.errorMessage, AccountDeletionModel.failureMessage)

        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }
        await h.model.deleteConfirmed()
        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertNil(h.model.errorMessage, "the earlier error is gone")
    }

    func testAnEndedSessionGoesThroughTheUsualSignOutNotAnInlineError() async throws {
        let h = try await makeSignedIn()
        StubURLProtocol.install { request in (.stub(request, status: 401), Data(AuthFixtures.expiredTokenJSON.utf8)) }

        await h.model.deleteConfirmed()
        await settle()

        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertEqual(h.auth.banner, "Your session ended. Please sign in again.")
        XCTAssertNil(h.auth.notice, "nothing claims the account was deleted")
        XCTAssertNil(h.model.errorMessage)
    }

    func testASecondConfirmWhileDeletingSendsNothing() async throws {
        let h = try await makeSignedIn()
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }

        let model = h.model
        let first = Task { @MainActor in await model.deleteConfirmed() }
        let second = Task { @MainActor in await model.deleteConfirmed() }
        await first.value
        await second.value

        XCTAssertEqual(deleteRequests.count, 1)
        XCTAssertEqual(h.auth.state, .signedOut)
    }

    func testDeletingWhileSignedOutDoesNothing() async throws {
        let h = try await makeSignedIn()
        h.auth.signOut()
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }
        try await h.auth.deleteAccount()
        XCTAssertTrue(deleteRequests.isEmpty)
        XCTAssertNil(h.auth.notice)
    }

    func testTheNoticeIsGoneOnceSomeoneSignsInAgain() async throws {
        let h = try await makeSignedIn()
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }
        await h.model.deleteConfirmed()
        XCTAssertNotNil(h.auth.notice)

        AuthFixtures.installHappyPath()
        try await h.auth.requestCode(email: "tester@example.com")
        try await h.auth.verify(challengeId: "chal-1", code: "123456")
        XCTAssertNil(h.auth.notice)
    }

    func testConfirmationCopySaysWhatIsLostAndThatItIsPermanent() {
        XCTAssertEqual(AccountDeletionModel.confirmationTitle, "Delete your account?")
        XCTAssertTrue(AccountDeletionModel.confirmationMessage.contains("permanently"))
        XCTAssertTrue(AccountDeletionModel.confirmationMessage.contains("can’t be undone"))
        XCTAssertEqual(AccountDeletionModel.confirmButton, "Delete account")
        XCTAssertEqual(AccountDeletionModel.cancelButton, "Keep account")
    }
}
