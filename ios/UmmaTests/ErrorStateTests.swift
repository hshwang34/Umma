import Foundation
import XCTest
@testable import Umma

/// Brief 010 PR 9: what people read when something fails. No raw codes, no dead ends, and a
/// denied permission always comes with the way to Settings.
@MainActor
final class ErrorStateTests: XCTestCase {
    private enum Opaque: Error { case boom }

    private let denied = CaptureError.permissionDenied(
        permission: "Microphone",
        explainer: "Umma listens only while you hold the talk button. Allow microphone access in Settings → Umma."
    )

    // MARK: - Release copy

    func testReleaseMessagesNeverShowAServerAddressOrAnHTTPStatus() {
        let errors: [APIError] = [
            .noServerConfigured,
            .invalidURL("http://10.0.0.2:8000"),
            .unreachable(baseURL: "https://umma-api.fly.dev", underlying: "NSURLErrorDomain -1004"),
            .http(status: 502, correlationId: "c-1"),
            .decoding("keyNotFound(CodingKeys(stringValue: \"id\"))"),
            .server(status: 500, code: "INTERNAL", message: "", retryable: true, correlationId: nil)
        ]
        for error in errors {
            let message = error.userMessage(debug: false)
            XCTAssertFalse(message.isEmpty)
            for leak in ["http", "HTTP", "502", "fly.dev", "10.0.0.2", "backend", "Server settings", "keyNotFound", "NSURLError"] {
                XCTAssertFalse(message.contains(leak), "\(error) leaks \(leak): \(message)")
            }
        }
        XCTAssertEqual(APIError.unreachable(baseURL: "x", underlying: "y").userMessage(debug: false),
                       "Can’t reach Umma right now. Check your connection and try again.")
        XCTAssertEqual(APIError.http(status: 500, correlationId: nil).userMessage(debug: false),
                       "Something went wrong on our side. Try again in a moment.")
    }

    func testReleaseKeepsTheServersOwnSentences() {
        XCTAssertEqual(APIError.unauthorized(message: "Invalid Apple sign-in", correlationId: nil).userMessage(debug: false),
                       "Invalid Apple sign-in")
        XCTAssertEqual(APIError.server(status: 429, code: "RATE_LIMITED", message: "Too many tries. Wait a minute.",
                                       retryable: true, correlationId: nil).userMessage(debug: false),
                       "Too many tries. Wait a minute.")
    }

    func testDebugStillNamesTheServerForDevelopers() {
        XCTAssertEqual(APIError.unreachable(baseURL: "http://localhost:8000", underlying: "x").userMessage(debug: true),
                       "Can’t reach the server at http://localhost:8000. Is the backend running?")
    }

    // MARK: - Any error

    func testAnErrorWithoutItsOwnWordsGetsAPlainLineNotATypeName() {
        XCTAssertEqual(Opaque.boom.userFacingMessage, "Something went wrong. Try again.")
        XCTAssertFalse(Opaque.boom.userFacingMessage.contains("Opaque"))
        XCTAssertEqual(URLError(.notConnectedToInternet).userFacingMessage, APIError.connectionMessage)
    }

    func testErrorsThatExplainThemselvesAreShownAsWritten() {
        XCTAssertEqual(denied.userFacingMessage,
                       "Umma listens only while you hold the talk button. Allow microphone access in Settings → Umma.")
        XCTAssertEqual(APIError.cancelled.userFacingMessage, APIError.cancelled.userMessage)
        let described = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                                userInfo: [NSLocalizedDescriptionKey: "The recording couldn’t be finished."])
        XCTAssertEqual(described.userFacingMessage, "The recording couldn’t be finished.")
    }

    func testOnlyAPermissionDenialAsksForSettings() {
        XCTAssertTrue(denied.isPermissionDenied)
        XCTAssertFalse(CaptureError.unavailable(.phone, reason: "no camera").isPermissionDenied)
        XCTAssertFalse(CaptureError.failed("x").isPermissionDenied)
        XCTAssertFalse(APIError.cancelled.isPermissionDenied)
    }

    // MARK: - Voice

    func testVoiceThatCannotStartForAPermissionExplainsAndOffersSettings() async {
        let transport = FakeVoiceTransport()
        transport.startError = denied
        let session = VoiceSession(transport: transport, clock: FakeVoiceClock())

        do {
            try await session.start()
            XCTFail("expected the start to fail")
        } catch {}

        XCTAssertTrue(session.deniedPermission)
        let bar = VoiceBarPresentation(session: session)
        XCTAssertEqual(bar.mode, .ended)
        XCTAssertTrue(bar.showsOpenSettings)
        XCTAssertEqual(bar.endedText, "Umma listens only while you hold the talk button. Allow microphone access in Settings → Umma.")
        XCTAssertFalse(bar.showsStop, "nothing is listening")
    }

    func testAnyOtherVoiceFailureHasNoSettingsButton() async {
        let transport = FakeVoiceTransport()
        transport.startError = CaptureError.failed("The microphone is in use by another app.")
        let session = VoiceSession(transport: transport, clock: FakeVoiceClock())
        do { try await session.start(); XCTFail("expected the start to fail") } catch {}

        XCTAssertFalse(session.deniedPermission)
        let bar = VoiceBarPresentation(session: session)
        XCTAssertFalse(bar.showsOpenSettings)
        XCTAssertEqual(bar.endedText, "Voice stopped: The microphone is in use by another app.")
    }

    func testAllowingThePermissionAndStartingAgainClearsTheSettingsButton() async throws {
        let transport = FakeVoiceTransport()
        transport.startError = denied
        let session = VoiceSession(transport: transport, clock: FakeVoiceClock())
        do { try await session.start() } catch {}
        XCTAssertTrue(session.deniedPermission)

        transport.startError = nil
        try await session.start()
        XCTAssertFalse(session.deniedPermission)
        XCTAssertFalse(VoiceBarPresentation(session: session).showsOpenSettings)
        session.stop()
    }

    func testALiveBarNeverShowsSettings() {
        let bar = VoiceBarPresentation(state: .listening, userCaptions: [], assistantCaptions: [], partial: nil,
                                       inputLabel: "iPhone mic", notice: nil, deniedPermission: true)
        XCTAssertFalse(bar.showsOpenSettings)
    }

    // MARK: - Recording screen

    func testRecordingScreenExplainsADeniedMicWithoutALeadInAndOffersSettings() {
        XCTAssertEqual(RecordPresentation.listenFailureMessage(denied),
                       "Umma listens only while you hold the talk button. Allow microphone access in Settings → Umma.")
        XCTAssertEqual(RecordPresentation.listenFailureMessage(Opaque.boom),
                       "Couldn’t start listening: Something went wrong. Try again.")

        XCTAssertTrue(RecordPresentation.showsOpenSettings(phase: .failed("x"), deniedPermission: true))
        XCTAssertTrue(RecordPresentation.showsOpenSettings(phase: .voiceStopped("x"), deniedPermission: true))
        XCTAssertFalse(RecordPresentation.showsOpenSettings(phase: .recording, deniedPermission: true))
        XCTAssertFalse(RecordPresentation.showsOpenSettings(phase: .failed("x"), deniedPermission: false))
    }

    func testPantryFailuresUseTheSamePlainFallback() {
        XCTAssertEqual(Opaque.boom.pantryMessage, "Something went wrong. Try again.")
        XCTAssertEqual(OpenSettingsButton.title, "Open Settings")
    }
}
