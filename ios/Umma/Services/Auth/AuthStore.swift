import Foundation
import Observation
import os

/// Owns the signed-in user and the Keychain token. Drives `RootView`.
@MainActor
@Observable
final class AuthStore {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(User)
    }

    private(set) var state: State = .restoring
    /// Message shown on the sign-in screen (restore failure, forced sign-out, ...).
    var banner: String?
    /// Something that went as intended and is worth saying once on the sign-in screen
    /// ("Your account was deleted."). Not an error; cleared by the next sign-in.
    private(set) var notice: String?
    /// Set after `requestCode`; the sign-in screen shows the code step while this is non-nil.
    private(set) var pendingChallenge: DevLoginChallenge?
    private(set) var pendingEmail: String?

    var user: User? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    var isSignedIn: Bool { user != nil }

    private let api: AuthService
    private let tokenStore: TokenStore
    private let defaults: UserDefaults
    private let recipeCache: RecipeCaching?
    /// Shared with `APIClient`; bumped on every sign-in/out so late 401s from an old session are ignored.
    let generation: SessionGeneration
    private let logger = Logger(subsystem: "com.umma.ios", category: "auth")
    /// Fired whenever account-scoped local data must go (brief 005: the cooking session store
    /// resets its cache and bumps its epoch). Called from `clearCredentials()`, from a restore that
    /// ends signed out, and when a sign-in completes for a different user than the cached one.
    var onCredentialsCleared: (@MainActor () -> Void)?
    /// Fired when what an account left on this phone must go for good (brief 010): recorded-recipe
    /// transcripts and their unsent writes, onboarding leftovers. The argument is the account to
    /// forget, or nil for everything on the phone.
    ///
    /// Fired by a tapped sign-out, account deletion, a server change, a fresh install and a
    /// different account signing in. Not by an expired session (401): the same person signing in
    /// again finds their unfinished recording, which is what the capture outbox is built for.
    var onAccountDataCleared: (@MainActor (UUID?) -> Void)?
    nonisolated static let cachedUserKey = "auth.cachedUser"
    /// Who last signed in on this phone. It outlives an expired session, so the next sign-in
    /// can tell "the same person again" from "someone else".
    nonisolated static let lastUserIdKey = "auth.lastUserId"
    nonisolated static let hasLaunchedKey = "auth.hasLaunched"

    init(api: AuthService,
         tokenStore: TokenStore,
         defaults: UserDefaults = .standard,
         recipeCache: RecipeCaching? = nil,
         generation: SessionGeneration = SessionGeneration()) {
        self.api = api
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.recipeCache = recipeCache
        self.generation = generation
    }

    /// Called once at launch. A cached user + token signs in immediately (offline-friendly), then
    /// `/v1/me` refreshes in the background; a 401 on that refresh clears everything.
    func restore() async {
        // The Keychain survives an app reinstall but UserDefaults does not: a missing launch flag
        // means a fresh install, so any token left over from the previous install is discarded.
        if !defaults.bool(forKey: Self.hasLaunchedKey) {
            defaults.set(true, forKey: Self.hasLaunchedKey)
            clearCredentials()
            clearAccountData(of: nil)
        }
        guard tokenStore.currentToken() != nil else {
            state = .signedOut
            onCredentialsCleared?()
            return
        }
        if let cached = cachedUser() {
            state = .signedIn(cached)
        }
        do {
            let user = try await api.me()
            cache(user)
            state = .signedIn(user)
            banner = nil
        } catch let error as APIError {
            switch error {
            case .unauthorized:
                forceSignOut(reason: "Your session ended. Please sign in again.")
            default:
                if case .signedIn = state {
                    logger.info("restore: kept cached user; refresh failed: \(error.userMessage, privacy: .public)")
                } else {
                    state = .signedOut
                    banner = error.userMessage
                    onCredentialsCleared?()
                }
            }
        } catch {
            if case .signedIn = state { return }
            state = .signedOut
            banner = error.localizedDescription
            onCredentialsCleared?()
        }
    }

    /// Step 1 of dev sign-in. The backend logs a 6-digit code; nothing is stored yet.
    @discardableResult
    func requestCode(email: String) async throws -> DevLoginChallenge {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let challenge = try await api.requestDevCode(email: trimmed)
        pendingEmail = trimmed
        pendingChallenge = challenge
        banner = nil
        return challenge
    }

    /// Step 2. A wrong or expired code throws `APIError.unauthorized` with the server's message and
    /// leaves `pendingChallenge` in place so the user can retry; no session exists to tear down.
    func verify(challengeId: String, code: String) async throws {
        let response = try await api.verifyDevCode(challengeId: challengeId, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        try startSession(response)
    }

    /// Sign in with Apple (brief 010). A token the server refuses throws `APIError.unauthorized`
    /// and leaves the store signed out; no session exists to tear down.
    func signInWithApple(_ credential: AppleSignIn.Credential, nonce: SignInNonce) async throws {
        let response = try await api.signInWithApple(
            identityToken: credential.identityToken, nonce: nonce.raw,
            authorizationCode: credential.authorizationCode, displayName: credential.displayName)
        try startSession(response)
    }

    /// Sign in with Google (brief 010). Same contract as `signInWithApple`: a refused token
    /// throws `APIError.unauthorized` and leaves the store signed out.
    func signInWithGoogle(_ credential: GoogleSignInFlow.Credential) async throws {
        let response = try await api.signInWithGoogle(idToken: credential.idToken, nonce: credential.nonce.raw)
        try startSession(response)
    }

    private func startSession(_ response: AuthResponse) throws {
        if cachedUser()?.id != response.user.id {
            // A different account: nothing of the previous one's may survive.
            onCredentialsCleared?()
        }
        if let last = defaults.string(forKey: Self.lastUserIdKey), last != response.user.id.uuidString {
            clearAccountData(of: nil)
        }
        generation.advance()
        try tokenStore.save(token: response.accessToken)
        cache(response.user)
        defaults.set(response.user.id.uuidString, forKey: Self.lastUserIdKey)
        pendingChallenge = nil
        pendingEmail = nil
        banner = nil
        notice = nil
        state = .signedIn(response.user)
    }

    /// A fresh copy of the signed-in user from the server (brief 015: role, onboarding done).
    /// Ignored unless it is the same account that is signed in now.
    func updateUser(_ user: User) {
        guard self.user?.id == user.id else { return }
        cache(user)
        state = .signedIn(user)
    }

    /// "Use a different email": back to step 1.
    func cancelPendingChallenge() {
        pendingChallenge = nil
        pendingEmail = nil
    }

    func signOut(reason: String? = nil) {
        forceSignOut(reason: reason)
        clearAccountData(of: nil)
    }

    /// Invoked by `APIClient` on any 401. A 401 issued under an older generation belongs to a
    /// session that is already gone and must not end the current one.
    func handleUnauthorized(_ event: UnauthorizedEvent) {
        guard isSignedIn, event.generation == generation.current() else { return }
        forceSignOut(reason: "Your session ended. Please sign in again.")
    }

    /// The server address changed: every credential belonged to the old server, so drop them all
    /// whatever `state` says (a token can linger in the Keychain while signed out after a failed
    /// restore). Only a user who was actually signed in sees a banner.
    func serverChanged(to newValue: String) {
        let wasSignedIn = isSignedIn
        dropEverything(reason: wasSignedIn ? "Server changed to \(newValue). Sign in again." : nil)
    }

    /// Delete the signed-in account (brief 010). On success the local state goes exactly as it
    /// does for a server change (token, cached user, recipe cache, pending code) and the app is
    /// back on sign-in. On failure this throws and nothing local changes: still signed in.
    ///
    /// The session can change while the request is in flight (an expired token signs the person
    /// out; someone signs in). The account that was deleted is always forgotten; a newer session
    /// that belongs to someone else is never touched.
    func deleteAccount() async throws {
        guard let deleted = user?.id else { return }
        let issued = generation.current()
        try await api.deleteAccount()
        if generation.current() == issued || user?.id == deleted {
            // Still the deleted account's session (or the same account signed in again).
            dropEverything(reason: nil)
            notice = AccountDeletionModel.deletedNotice
        } else if !isSignedIn {
            // Signed out meanwhile: the credentials are gone already; forget the rest and say so.
            clearAccountData(of: nil)
            banner = nil
            notice = AccountDeletionModel.deletedNotice
        } else {
            // Someone else is signed in now. Only the deleted account's leftovers go.
            clearAccountData(of: deleted)
        }
    }

    /// Everything that belongs to the session and its server: the pending sign-in code, the
    /// token, the cached user, the cached recipes, and what the account left on the phone.
    private func dropEverything(reason: String?) {
        cancelPendingChallenge()
        forceSignOut(reason: reason)
        clearAccountData(of: nil)
    }

    private func clearAccountData(of userId: UUID?) {
        if userId == nil || userId?.uuidString == defaults.string(forKey: Self.lastUserIdKey) {
            defaults.removeObject(forKey: Self.lastUserIdKey)
        }
        onAccountDataCleared?(userId)
    }

    #if DEBUG
    /// Tests only.
    func forceSignedInForTests() {
        state = .signedIn(User(id: UUID(), displayName: "Tester", preferenceUnits: .us, createdAt: Date(), onboardedAt: Date()))
    }
    #endif

    private func forceSignOut(reason: String?) {
        generation.advance()
        clearCredentials()
        banner = reason
        state = .signedOut
    }

    /// Token, cached user, and cached recipes — everything tied to the signed-in session/server.
    private func clearCredentials() {
        do {
            try tokenStore.clear()
        } catch {
            logger.error("keychain clear failed: \(String(describing: error), privacy: .public)")
        }
        defaults.removeObject(forKey: Self.cachedUserKey)
        do {
            try recipeCache?.clear()
        } catch {
            logger.error("recipe cache clear failed: \(String(describing: error), privacy: .public)")
        }
        onCredentialsCleared?()
    }

    private func cache(_ user: User) {
        if let data = try? JSONCoding.makeEncoder().encode(user) {
            defaults.set(data, forKey: Self.cachedUserKey)
        }
    }

    private func cachedUser() -> User? {
        guard let data = defaults.data(forKey: Self.cachedUserKey) else { return nil }
        return try? JSONCoding.makeDecoder().decode(User.self, from: data)
    }
}
