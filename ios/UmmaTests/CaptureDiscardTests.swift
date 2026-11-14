import Foundation
import XCTest
@testable import Umma

/// Brief 014: discarding deletes on the server first; the journal goes only once that succeeds.
@MainActor
final class CaptureDiscardTests: XCTestCase {
    private var api: FakeCaptureService!
    private var journal: CaptureJournalStore!

    override func setUp() async throws {
        api = FakeCaptureService()
        journal = CaptureJournalStore(directory: FileManager.default.temporaryDirectory.appending(path: "capture-discard-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: journal.directory)
    }

    private func started() async -> CaptureCoordinator {
        let transport = FakeVoiceTransport()
        let coordinator = CaptureCoordinator(api: api, makeVoice: { VoiceSession(transport: transport, clock: FakeVoiceClock(), config: $0) },
                                             journal: journal, userId: nil, ticker: FakeVoiceClock(),
                                             config: .init(introLine: nil), sleep: { _ in await Task.yield() })
        await coordinator.start(titleHint: nil)
        return coordinator
    }

    func testDiscardDeletesTheSessionAndJournal() async {
        let coordinator = await started()
        await coordinator.discard()
        XCTAssertTrue(api.calls.contains(.delete))
        XCTAssertNil(journal.load(api.sessionId))
        XCTAssertFalse(coordinator.voice.state.isActive)
    }

    func testDiscardKeepsAPendingEntryUntilTheServerDeleteSucceeds() async {
        api.deleteError = .unreachable(baseURL: "http://x", underlying: "offline")
        let coordinator = await started()
        await coordinator.discard()
        XCTAssertFalse(coordinator.voice.state.isActive)
        XCTAssertEqual(journal.load(api.sessionId)?.discardPending, true, "kept until the server agrees")
        await CaptureCoordinator.retryPendingDiscards(api: api, journal: journal, userId: nil)
        XCTAssertNotNil(journal.load(api.sessionId))
        api.deleteError = .server(status: 404, code: "NOT_FOUND", message: "gone", retryable: false, correlationId: nil)
        await CaptureCoordinator.retryPendingDiscards(api: api, journal: journal, userId: nil)
        XCTAssertNil(journal.load(api.sessionId), "already gone counts as deleted")
    }

    func testDiscardWhileStartingDeletesTheNewSessionAndNeverOpensTheMic() async {
        let release = LockedFlag()
        api.createGate = { while !release.isSet { try await Task.sleep(for: .milliseconds(5)) } }
        let transport = FakeVoiceTransport()
        let coordinator = CaptureCoordinator(api: api, makeVoice: { VoiceSession(transport: transport, clock: FakeVoiceClock(), config: $0) },
                                             journal: journal, userId: nil, ticker: FakeVoiceClock(),
                                             config: .init(introLine: nil), sleep: { _ in await Task.yield() })
        let starting = Task { await coordinator.start(titleHint: nil) }
        while !api.calls.contains(.create) { await Task.yield() }
        let discarding = Task { await coordinator.discard() }
        for _ in 0..<50 { await Task.yield() }
        _ = release.setOnce()
        await starting.value
        await discarding.value
        XCTAssertEqual(transport.startCount, 0)
        XCTAssertFalse(coordinator.voice.state.isActive)
        XCTAssertTrue(api.calls.contains(.delete), "the just-created session is deleted")
        XCTAssertNil(journal.load(api.sessionId))
    }
}
