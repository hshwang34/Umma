import Foundation
import XCTest
@testable import Umma

/// Brief 014 delivery layer: the ordered outbox, its keys, retries, cancellation and the journal.
@MainActor
final class CaptureOutboxTests: XCTestCase {
    private var api: FakeCaptureService!
    private var journal: CaptureJournalStore!
    private var events: [String] = []

    override func setUp() async throws {
        api = FakeCaptureService()
        journal = CaptureJournalStore(directory: FileManager.default.temporaryDirectory.appending(path: "capture-outbox-\(UUID().uuidString)"))
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: journal.directory)
    }

    private func makeOutbox() -> CaptureOutbox {
        let outbox = CaptureOutbox(api: api, journal: journal, retryDelays: [.zero], sleep: { _ in await Task.yield() })
        outbox.onEvent = { [weak self] event in
            switch event {
            case .turns(let response): self?.events.append("turns:\(response.stored)")
            case .sessionGone: self?.events.append("gone")
            }
        }
        return outbox
    }

    private func opened() -> CaptureOutbox {
        let outbox = makeOutbox()
        outbox.open(CaptureJournalRecord(sessionId: api.sessionId, userId: nil, titleHint: nil, startedAt: Date()))
        return outbox
    }

    private func turn(_ text: String, at tMs: Int64 = 1000) -> CaptureWrite.Body {
        .turns(CaptureTurnsRequest(segments: [CaptureSegmentIn(tMs: tMs, text: text)], silenceMs: 0, assistantSpeaking: false, tMs: tMs))
    }

    private func settle(_ condition: @MainActor () -> Bool = { false }) async {
        for _ in 0..<300 where !condition() { await Task.yield() }
    }

    func testWritesGoInOrderWithOneKeyEachAndReportResponses() async {
        api.turnsHandler = { CaptureTurnsResponse(ask: nil, stored: $0.segments.count, closedQuestionId: nil, askingStopped: false) }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        outbox.enqueue(.command(CaptureCommandRequest(command: .pause, tMs: 2000)), at: 2000)
        await settle { outbox.pendingCount == 0 }
        XCTAssertEqual(api.spokenWords, ["pork belly"])
        XCTAssertEqual(api.commands, [.pause])
        XCTAssertEqual(events, ["turns:1"])
        XCTAssertEqual(journal.load(api.sessionId)?.outbox, [], "acknowledged writes leave the journal")
        XCTAssertEqual(journal.load(api.sessionId)?.lastTMs, 2000)
    }

    func testNetworkBlipRetriesTheSameKeyThenMovesOn() async {
        let failures = LockedCounter(3)
        api.turnsHandler = { request in
            if failures.take() { throw APIError.unreachable(baseURL: "http://x", underlying: "offline") }
            return CaptureTurnsResponse(ask: nil, stored: request.segments.count, closedQuestionId: nil, askingStopped: false)
        }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        outbox.enqueue(turn("kimchi", at: 2000), at: 2000)
        await settle { outbox.pendingCount == 0 }
        let keys = api.turnKeys
        XCTAssertEqual(keys.count, 5, "3 failed tries + 2 successes")
        XCTAssertEqual(Set(keys.prefix(4)).count, 1, "retries replay the first write's key")
        XCTAssertNotEqual(keys[3], keys[4])
        XCTAssertFalse(outbox.isRetrying)
        XCTAssertEqual(outbox.failureStreak, 0)
    }

    func testCancelledWriteStaysAtTheHeadAndIsResentWithItsKey() async throws {
        api.turnsGate = { try await Task.sleep(for: .seconds(30)) }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        await settle { self.api.turnKeys.count == 1 }
        let key = try XCTUnwrap(api.turnKeys.first)
        outbox.suspend()
        await settle()
        XCTAssertEqual(journal.load(api.sessionId)?.outbox.first?.key, key, "a cancelled request is never dropped")

        api.turnsGate = nil
        let relaunched = makeOutbox()
        relaunched.open(try XCTUnwrap(journal.load(api.sessionId)))
        relaunched.drain()
        await settle { relaunched.pendingCount == 0 }
        XCTAssertEqual(api.turnKeys, [key, key])
    }

    func testWritesWaitWhileSuspendedAndGoOnReopen() async {
        let outbox = opened()
        outbox.suspend()
        outbox.enqueue(turn("pork belly"), at: 1000)
        await settle()
        XCTAssertTrue(api.turns.isEmpty)
        XCTAssertEqual(journal.load(api.sessionId)?.outbox.count, 1)
        outbox.reopen()
        await settle { outbox.pendingCount == 0 }
        XCTAssertEqual(api.spokenWords, ["pork belly"])
    }

    func testRefusedWriteIsDroppedAndTheQueueContinues() async {
        let outbox = opened()
        api.outcomeHandler = { _, _ in throw APIError.server(status: 409, code: "STATE_CONFLICT", message: "closed", retryable: false, correlationId: nil) }
        outbox.enqueue(.outcome(questionId: UUID(), CaptureOutcomeRequest(outcome: .skipped, tMs: 1000)), at: 1000)
        outbox.enqueue(turn("kimchi"), at: 1000)
        await settle { outbox.pendingCount == 0 }
        XCTAssertEqual(api.spokenWords, ["kimchi"])
    }

    func testDeletedSessionForgetsTheJournal() async {
        api.turnsHandler = { _ in throw APIError.server(status: 404, code: "NOT_FOUND", message: "gone", retryable: false, correlationId: nil) }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        await settle { self.events == ["gone"] }
        XCTAssertEqual(events, ["gone"])
        XCTAssertNil(journal.load(api.sessionId))
        XCTAssertNil(outbox.record)
    }

    func testLateAnswerIsResentAsSpeech() async {
        api.outcomeHandler = { _, _ in .expired }
        let questionId = UUID()
        let outbox = opened()
        outbox.update { $0.lines = [.init(id: 1, tMs: 9000, text: "about fifteen minutes", questionId: questionId)] }
        outbox.enqueue(.outcome(questionId: questionId, CaptureOutcomeRequest(outcome: .answered, answerText: "about fifteen minutes", tMs: 9500)), at: 9500)
        await settle { outbox.pendingCount == 0 }
        XCTAssertEqual(api.spokenWords, ["about fifteen minutes"], "nothing she said is lost")
    }

    func testLateAnswerLeavesTheOutboxInTheSameSaveThatQueuesItsWords() async throws {
        api.outcomeHandler = { _, _ in .expired }
        api.turnsGate = { try await Task.sleep(for: .seconds(30)) }
        let questionId = UUID()
        let outbox = opened()
        outbox.update { $0.lines = [.init(id: 1, tMs: 9000, text: "about fifteen minutes", questionId: questionId)] }
        outbox.enqueue(.outcome(questionId: questionId, CaptureOutcomeRequest(outcome: .answered, answerText: "about fifteen minutes", tMs: 9500)), at: 9500)
        await settle { self.api.turns.count == 1 }
        // A crash now replays the journal: only the derived words, never the outcome again.
        let saved = try XCTUnwrap(journal.load(api.sessionId))
        XCTAssertEqual(saved.outbox.count, 1)
        guard case .turns(let request) = saved.outbox.first?.body else { return XCTFail("expected the words, got \(saved.outbox)") }
        XCTAssertEqual(request.segments.map(\.text), ["about fifteen minutes"])
        XCTAssertEqual(api.outcomes.count, 1)
        outbox.suspend()
    }

    func testSignedOutWriteStaysQueuedWithItsKeyAndSendingStops() async throws {
        let stillSignedOut = LockedCounter(1)
        api.turnsHandler = { request in
            if stillSignedOut.take() { throw APIError.unauthorized(message: nil, correlationId: nil) }
            return CaptureTurnsResponse(ask: nil, stored: request.segments.count, closedQuestionId: nil, askingStopped: false)
        }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        let sent = await outbox.flush(maxFailures: 3)
        XCTAssertFalse(sent, "flush stops instead of spinning on a 401")
        XCTAssertTrue(outbox.isSuspended)
        let key = try XCTUnwrap(api.turnKeys.first)
        XCTAssertEqual(api.turnKeys.count, 1, "no retry loop while signed out")
        XCTAssertEqual(journal.load(api.sessionId)?.outbox.first?.key, key, "her words are never dropped")

        outbox.reopen()
        await settle { outbox.pendingCount == 0 }
        XCTAssertEqual(api.turnKeys, [key, key], "resent with the same key after signing in")
    }

    func testStalePauseTurnsBehindABlockedQueueAreDropped() async {
        api.turnsGate = { try await Task.sleep(for: .seconds(30)) }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        let pause = CaptureWrite.Body.turns(CaptureTurnsRequest(segments: [], silenceMs: 1600, assistantSpeaking: false, tMs: 2600))
        outbox.enqueue(pause, at: 2600)
        outbox.enqueue(turn("kimchi", at: 3000), at: 3000)
        XCTAssertEqual(outbox.record?.outbox.count, 2, "head + the newer words; the stale pause is gone")
        outbox.suspend()
    }

    func testFlushGivesUpAfterRepeatedNetworkFailures() async {
        api.turnsHandler = { _ in throw APIError.unreachable(baseURL: "http://x", underlying: "offline") }
        let outbox = opened()
        outbox.enqueue(turn("pork belly"), at: 1000)
        let sent = await outbox.flush(maxFailures: 3)
        XCTAssertFalse(sent)
        XCTAssertEqual(journal.load(api.sessionId)?.outbox.count, 1, "the words stay journaled")
        outbox.suspend()
    }

    func testJournalListsOnlyThisUsersSessionsNewestFirst() {
        let me = UUID()
        journal.save(CaptureJournalRecord(sessionId: UUID(), userId: me, titleHint: "old", startedAt: Date(timeIntervalSince1970: 1)))
        journal.save(CaptureJournalRecord(sessionId: UUID(), userId: me, titleHint: "new", startedAt: Date(timeIntervalSince1970: 2)))
        journal.save(CaptureJournalRecord(sessionId: UUID(), userId: UUID(), titleHint: "someone else", startedAt: Date()))
        XCTAssertEqual(journal.pending(userId: me).map(\.titleHint), ["new", "old"])
    }

    func testVoiceCommandsMirrorTheServer() {
        XCTAssertEqual(CaptureVoiceCommand.parse("Skip."), .skip)
        XCTAssertEqual(CaptureVoiceCommand.parse("umma, I don’t know"), .skip)
        XCTAssertEqual(CaptureVoiceCommand.parse("not now"), .later)
        XCTAssertEqual(CaptureVoiceCommand.parse("okay no more questions thanks"), .stopAsking)
        XCTAssertNil(CaptureVoiceCommand.parse("don't skip the kimchi"))
        XCTAssertNil(CaptureVoiceCommand.parse("later we add tofu"))
    }
}
