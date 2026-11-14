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
        XCTAssertEqual(h.auth.banner, "You’ve been signed out. Sign in again to continue.")
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

    func testDeleteIsSentWithoutABodyAndA204WithNoBodyIsSuccess() async throws {
        let h = try await makeSignedIn()
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }
        await h.model.deleteConfirmed()
        let request = try XCTUnwrap(deleteRequests.first)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertNil(h.model.errorMessage)
    }

    // MARK: - What the account left on the phone

    private struct WipeHarness {
        let environment: AppEnvironment
        let journal: CaptureJournalStore
        let settings: ServerSettings
        @MainActor var auth: AuthStore { environment.auth }
    }

    /// The real wiring (`AppEnvironment`), signed in, with a recorded-recipe transcript on disk.
    private func makeEnvironmentWithATranscript(authService: AuthService? = nil) async throws -> WipeHarness {
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
        let auth = AuthStore(api: authService ?? client, tokenStore: tokens, defaults: defaults, recipeCache: cache, generation: generation)
        let settings = ServerSettings(defaults: defaults)
        AppEnvironment.bind(api: client, auth: auth, settings: settings, recipeCache: cache)
        let journal = CaptureJournalStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "UmmaTests-journal-\(UUID().uuidString)", directoryHint: .isDirectory))
        addTeardownBlock { try? FileManager.default.removeItem(at: journal.directory) }
        let environment = AppEnvironment(
            serverSettings: settings, api: client, auth: auth,
            recipeCache: RecipeCache(directory: FileManager.default.temporaryDirectory.appending(path: "UmmaTests-cache-\(UUID().uuidString)")),
            captureFlags: .allOn, camera: FakeCameraSource(), speech: FakeSpeechInput(), audio: FakeAudioOutput(),
            captureJournal: journal
        )
        AuthFixtures.installHappyPath()
        try await auth.requestCode(email: "tester@example.com")
        try await auth.verify(challengeId: "chal-1", code: "123456")
        var record = CaptureJournalRecord(sessionId: UUID(), userId: auth.user?.id, startedAt: Date())
        record.lines = [.init(id: 1, tMs: 0, text: "Now the kimchi, the old sour one.")]
        journal.save(record)
        XCTAssertEqual(transcriptFiles(journal).count, 1)
        XCTAssertEqual(environment.pendingCaptures().count, 1)
        return WipeHarness(environment: environment, journal: journal, settings: settings)
    }

    private func transcriptFiles(_ journal: CaptureJournalStore) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)) ?? []
    }

    func testADeletedAccountLeavesNoTranscriptFileBehind() async throws {
        let h = try await makeEnvironmentWithATranscript()
        h.environment.requestNewRecipe = true
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }

        await AccountDeletionModel(auth: h.auth).deleteConfirmed()

        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertTrue(transcriptFiles(h.journal).isEmpty, "the recorded words are gone from the phone")
        XCTAssertFalse(h.environment.requestNewRecipe, "onboarding leftovers don't reach the next account")
        XCTAssertTrue(h.environment.onboardingEnabled)
    }

    func testAFailedDeletionKeepsTheTranscript() async throws {
        let h = try await makeEnvironmentWithATranscript()
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        await AccountDeletionModel(auth: h.auth).deleteConfirmed()
        XCTAssertTrue(h.auth.isSignedIn)
        XCTAssertEqual(transcriptFiles(h.journal).count, 1)
    }

    func testSigningOutAndChangingServerAlsoRemoveTheTranscript() async throws {
        var h = try await makeEnvironmentWithATranscript()
        h.auth.signOut()
        XCTAssertTrue(transcriptFiles(h.journal).isEmpty)

        h = try await makeEnvironmentWithATranscript()
        h.settings.baseURLText = "http://10.0.0.9:8000"
        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertTrue(transcriptFiles(h.journal).isEmpty)
    }

    func testAnExpiredSessionKeepsTheTranscriptForTheSamePersonButNotForSomeoneElse() async throws {
        let h = try await makeEnvironmentWithATranscript()
        let me = try XCTUnwrap(h.auth.user?.id)
        h.auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: nil),
                                                    generation: h.auth.generation.current()))
        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertEqual(transcriptFiles(h.journal).count, 1, "an unfinished recording survives an expired session")

        AuthFixtures.installHappyPath()
        try await h.auth.requestCode(email: "tester@example.com")
        try await h.auth.verify(challengeId: "chal-1", code: "123456")
        XCTAssertEqual(h.auth.user?.id, me)
        XCTAssertEqual(h.environment.pendingCaptures().count, 1, "the same person finds it again")

        h.auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: nil),
                                                    generation: h.auth.generation.current()))
        let other = AuthFixtures.loginJSON.replacingOccurrences(of: "c1a2b3c4", with: "d9e8f7a6")
        StubURLProtocol.install { request in (.stub(request, status: request.url?.path == "/v1/auth/dev-login" ? 202 : 200),
                                              Data((request.url?.path == "/v1/auth/dev-login" ? AuthFixtures.challengeJSON : other).utf8)) }
        try await h.auth.requestCode(email: "other@example.com")
        try await h.auth.verify(challengeId: "chal-1", code: "123456")
        XCTAssertNotEqual(h.auth.user?.id, me)
        XCTAssertTrue(transcriptFiles(h.journal).isEmpty, "a different account never inherits it")
    }

    // MARK: - The session changes while DELETE is in flight

    func testAnExpiredSessionDuringDeletionStillForgetsTheDeletedAccount() async throws {
        let service = HeldDeleteAuthService()
        let h = try await makeEnvironmentWithATranscript(authService: service)
        let auth = h.auth
        let deletion = Task { @MainActor in try await auth.deleteAccount() }
        await service.waitUntilDeleteIsInFlight()

        auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: nil),
                                                  generation: auth.generation.current()))
        XCTAssertEqual(transcriptFiles(h.journal).count, 1, "an expiry alone keeps it")
        service.finishDelete()
        try await deletion.value

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(transcriptFiles(h.journal).isEmpty, "the 204 says the account is gone, so its words go too")
        XCTAssertEqual(auth.notice, "Your account was deleted.")
        XCTAssertNil(auth.banner, "not also \"your session ended\"")
    }

    func testSomeoneElseSigningInDuringDeletionIsNeverWiped() async throws {
        let service = HeldDeleteAuthService()
        let h = try await makeEnvironmentWithATranscript(authService: service)
        let deleted = try XCTUnwrap(h.auth.user?.id)
        let auth = h.auth
        let deletion = Task { @MainActor in try await auth.deleteAccount() }
        await service.waitUntilDeleteIsInFlight()
        service.nextLoginJSON = AuthFixtures.loginJSON.replacingOccurrences(of: "c1a2b3c4", with: "d9e8f7a6")

        // The first account's session expires and another person signs in before the 204 lands.
        auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: nil),
                                                  generation: auth.generation.current()))
        try await auth.requestCode(email: "other@example.com")
        try await auth.verify(challengeId: "chal-1", code: "123456")
        let other = try XCTUnwrap(auth.user?.id)
        XCTAssertNotEqual(other, deleted)
        var theirs = CaptureJournalRecord(sessionId: UUID(), userId: other, startedAt: Date())
        theirs.lines = [.init(id: 1, tMs: 0, text: "Mine.")]
        h.journal.save(theirs)

        service.finishDelete()
        try await deletion.value

        XCTAssertEqual(auth.user?.id, other, "the newer session is untouched")
        XCTAssertNil(auth.notice)
        XCTAssertEqual(h.journal.pending(userId: other).count, 1)
        XCTAssertTrue(h.journal.pending(userId: deleted).isEmpty)
    }

    func testConfirmationCopySaysWhatIsLostAndThatItIsPermanent() {
        XCTAssertEqual(AccountDeletionModel.confirmationTitle, "Delete your account?")
        XCTAssertTrue(AccountDeletionModel.confirmationMessage.contains("permanently"))
        XCTAssertTrue(AccountDeletionModel.confirmationMessage.contains("can’t be undone"))
        XCTAssertEqual(AccountDeletionModel.confirmButton, "Delete account")
        XCTAssertEqual(AccountDeletionModel.cancelButton, "Keep account")
    }
}

/// `AuthService` whose `DELETE /v1/me` stays in flight until the test finishes it (always 204).
final class HeldDeleteAuthService: AuthService, @unchecked Sendable {
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var _nextLoginJSON = AuthFixtures.loginJSON
    var nextLoginJSON: String {
        get { lock.withLock { _nextLoginJSON } }
        set { lock.withLock { _nextLoginJSON = newValue } }
    }

    private func login() throws -> AuthResponse {
        try JSONCoding.makeDecoder().decode(AuthResponse.self, from: Data(nextLoginJSON.utf8))
    }

    func requestDevCode(email: String) async throws -> DevLoginChallenge {
        try JSONCoding.makeDecoder().decode(DevLoginChallenge.self, from: Data(AuthFixtures.challengeJSON.utf8))
    }
    func verifyDevCode(challengeId: String, code: String) async throws -> AuthResponse { try login() }
    func signInWithApple(identityToken: String, nonce: String, authorizationCode: String?, displayName: String?) async throws -> AuthResponse { try login() }
    func signInWithGoogle(idToken: String, nonce: String) async throws -> AuthResponse { try login() }
    func signInWithReviewCode(_ code: String) async throws -> AuthResponse { try login() }
    func me() async throws -> User { try login().user }

    func deleteAccount() async throws {
        await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
    }

    func waitUntilDeleteIsInFlight() async {
        while lock.withLock({ held == nil }) { await Task.yield() }
    }

    func finishDelete() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}
