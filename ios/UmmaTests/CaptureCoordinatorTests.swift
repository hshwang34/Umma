import Foundation
import XCTest
@testable import Umma

/// Brief 014: the coordinator's gate, answer window, Done and the mic's lifetime.
@MainActor
final class CaptureCoordinatorTests: XCTestCase {
    private var api: FakeCaptureService!
    private var transport: FakeVoiceTransport!
    private var timeline: TestTimeline!
    private var journal: CaptureJournalStore!
    private var voiceConfig: VoiceSessionConfig?

    override func setUp() async throws {
        api = FakeCaptureService()
        transport = FakeVoiceTransport()
        timeline = TestTimeline()
        journal = CaptureJournalStore(directory: FileManager.default.temporaryDirectory.appending(path: "capture-journal-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: journal.directory)
    }

    private func makeCoordinator(transport: FakeVoiceTransport? = nil, intro: String? = nil) -> CaptureCoordinator {
        let transport = transport ?? self.transport!
        let voiceClock = timeline.makeClock()
        return CaptureCoordinator(
            api: api,
            makeVoice: { [weak self] config in
                self?.voiceConfig = config
                return VoiceSession(transport: transport, clock: voiceClock, config: config)
            },
            journal: journal,
            userId: nil,
            ticker: timeline.makeClock(),
            config: CaptureCoordinator.Config(introLine: intro),
            sleep: { _ in await Task.yield() }
        )
    }

    private func started() async -> CaptureCoordinator {
        let coordinator = makeCoordinator()
        await coordinator.start(titleHint: "Mum's Kimchi Jjigae")
        return coordinator
    }

    private func settle(_ condition: @MainActor () -> Bool = { false }) async {
        for _ in 0..<300 where !condition() { await Task.yield() }
    }

    private func say(_ text: String, after ms: Int64 = 500) async {
        timeline.advance(byMs: ms)
        transport.emit(.transcript(text: text, isFinal: true))
        await settle()
    }

    private func ask(_ text: String = "How long do you let it simmer?", expiresAt: Int64? = nil, phase: CapturePhase = .live) -> CaptureAsk {
        CaptureAsk(questionId: UUID(), text: text, topicKey: "simmer_time", topic: "time", phase: phase, expiresAtMs: expiresAt)
    }

    /// The next pause turn returns `ask` (once).
    private func askOnNextPause(_ ask: CaptureAsk) {
        let given = LockedFlag()
        api.turnsHandler = { request in
            let first = request.segments.isEmpty && request.silenceMs >= 1500 && given.setOnce()
            return CaptureTurnsResponse(ask: first ? ask : nil, stored: request.segments.count, closedQuestionId: nil, askingStopped: false)
        }
    }

    // MARK: - Recording

    func testStartCreatesSessionListensWithSilenceEndOffAndJournals() async throws {
        let coordinator = await started()
        XCTAssertEqual(coordinator.phase, .recording)
        XCTAssertNil(voiceConfig?.silenceTimeoutMs, "a 45-minute cook never ends on silence")
        XCTAssertEqual(api.calls.first, .create)
        XCTAssertNotNil(journal.load(api.sessionId))
        timeline.advance(byMs: 11 * 60 * 1000)
        XCTAssertEqual(coordinator.voice.state, .listening)
    }

    func testIntroLineIsSpokenOnceRecordingStarts() async {
        let coordinator = makeCoordinator(intro: "I'm listening.")
        await coordinator.start(titleHint: nil)
        await settle { !self.transport.spoken.isEmpty }
        XCTAssertEqual(transport.spoken, ["I'm listening."])
        XCTAssertEqual(coordinator.voice.state, .listening)
    }

    func testUnavailableVoiceFailsHonestlyWithoutCreatingASession() async {
        let coordinator = makeCoordinator(transport: FakeVoiceTransport(isAvailable: false))
        await coordinator.start(titleHint: nil)
        guard case .failed(let message) = coordinator.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("type the recipe"))
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testFinalSegmentsGoToTurnsOnTheSessionClockAndPausesSendSilence() async {
        let coordinator = await started()
        await say("Three hundred grams of pork belly goes in, no oil", after: 2000)
        await say("Now two cups of the old sour kimchi", after: 3000)
        timeline.advance(byMs: 1500)
        await settle { self.api.turns.count >= 4 }
        XCTAssertEqual(api.spokenWords, ["Three hundred grams of pork belly goes in, no oil", "Now two cups of the old sour kimchi"])
        let withWords = api.turns.filter { !$0.segments.isEmpty }
        XCTAssertEqual(withWords.map { $0.segments.first?.tMs }, [2000, 5000], "session-clock times")
        // Each 1.5 s silence after speech sends one empty batch with the silence (the ask gate).
        let pauses = api.turns.filter(\.segments.isEmpty)
        XCTAssertEqual(pauses.count, 2)
        XCTAssertTrue(pauses.allSatisfy { $0.silenceMs >= 1500 && !$0.assistantSpeaking })
        XCTAssertEqual(Set(api.turnKeys).count, api.turnKeys.count, "one key per write")
        XCTAssertEqual(coordinator.heard.map(\.text).count, 2)
    }

    func testAskIsSpokenAtAPauseAndAnswerPostedAfterSettle() async {
        let question = ask(expiresAt: 40_000)
        askOnNextPause(question)
        let coordinator = await started()
        await say("Now we let it simmer", after: 10_000)
        timeline.advance(byMs: 1500)
        await settle { coordinator.question?.stage == .listening }
        XCTAssertEqual(transport.spoken, ["How long do you let it simmer?"])
        XCTAssertEqual(coordinator.question?.stage, .listening)

        await say("About fifteen minutes", after: 1500)
        XCTAssertEqual(coordinator.question?.answer, "About fifteen minutes")
        timeline.advance(byMs: 2000)
        await settle { !self.api.outcomes.isEmpty }
        XCTAssertNil(coordinator.question)
        XCTAssertEqual(api.outcomes.first?.outcome, .answered)
        XCTAssertEqual(api.outcomes.first?.answerText, "About fifteen minutes")
        XCTAssertFalse(api.spokenWords.contains("About fifteen minutes"), "an answer is not a turn")
    }

    func testAskIsHeldWhileTheCreatorTalksAndNeverSpokenAfterExpiry() async {
        let coordinator = await started()
        api.turnsHandler = { _ in CaptureTurnsResponse(ask: nil, stored: 1, closedQuestionId: nil, askingStopped: false) }
        // The ask arrives while she is mid-sentence.
        let late = ask(expiresAt: 25_000)
        api.turnsHandler = { request in
            CaptureTurnsResponse(ask: request.segments.isEmpty ? nil : late, stored: 1, closedQuestionId: nil, askingStopped: false)
        }
        await say("then the tofu", after: 1000)
        transport.emit(.transcript(text: "and some", isFinal: false))
        await settle { coordinator.question != nil }
        XCTAssertEqual(coordinator.question?.stage, .waiting)
        XCTAssertTrue(transport.spoken.isEmpty, "never talks over her")
        // She keeps talking past the question's expiry.
        for _ in 0..<30 {
            timeline.advance(byMs: 1000)
            transport.emit(.transcript(text: "and some more", isFinal: false))
        }
        await settle { !self.api.outcomes.isEmpty }
        XCTAssertTrue(transport.spoken.isEmpty)
        XCTAssertEqual(api.outcomes.first?.outcome, .expired)
        XCTAssertNil(coordinator.question)
    }

    func testNoAnswerExpiresAfterTwelveSecondsOfSilence() async {
        askOnNextPause(ask(expiresAt: 60_000))
        let coordinator = await started()
        await say("Now we let it simmer", after: 5000)
        timeline.advance(byMs: 1500)
        await settle { coordinator.question?.stage == .listening }
        timeline.advance(byMs: 11_000)
        await settle()
        XCTAssertTrue(api.outcomes.isEmpty)
        timeline.advance(byMs: 1250)
        await settle { !self.api.outcomes.isEmpty }
        XCTAssertEqual(api.outcomes.first?.outcome, .expired)
    }

    func testSpokenSkipLaterAndStopAsking() async {
        for (spoken, expected) in [("skip", CaptureOutcome.skipped), ("Ask me later", .later), ("stop asking please", .later)] {
            api = FakeCaptureService()
            askOnNextPause(ask(expiresAt: 60_000))
            let coordinator = await started()
            await say("Now we let it simmer", after: 5000)
            timeline.advance(byMs: 1500)
            await settle { coordinator.question?.stage == .listening }
            await say(spoken)
            await settle { !self.api.outcomes.isEmpty }
            XCTAssertEqual(api.outcomes.first?.outcome, expected, spoken)
            XCTAssertNil(api.outcomes.first?.answerText)
            XCTAssertFalse(api.spokenWords.contains(spoken), "a command is not a turn")
            if expected == .later, spoken.contains("stop") {
                await settle { self.api.commands.contains(.stopAsking) }
                XCTAssertEqual(api.commands, [.stopAsking])
                XCTAssertTrue(coordinator.askingStopped)
            }
            coordinator.voice.stop()
        }
    }

    func testAskArrivingAfterStopAskingIsDeferredNotSpoken() async {
        let coordinator = await started()
        coordinator.stopAsking()
        let stray = ask(expiresAt: 60_000)
        api.turnsHandler = { _ in CaptureTurnsResponse(ask: stray, stored: 1, closedQuestionId: nil, askingStopped: true) }
        await say("now we let it simmer", after: 3000)
        await settle { self.api.outcomes.count == 1 }
        XCTAssertTrue(transport.spoken.isEmpty)
        XCTAssertEqual(api.outcomes.first?.outcome, .later)
    }

    func testPauseKeepsAGivenAnswerAndSendsCommands() async {
        askOnNextPause(ask(expiresAt: 60_000))
        let coordinator = await started()
        await say("Now we let it simmer", after: 5000)
        timeline.advance(byMs: 1500)
        await settle { coordinator.question?.stage == .listening }
        await say("fifteen minutes or so")
        coordinator.pause()
        XCTAssertEqual(coordinator.phase, .paused)
        XCTAssertEqual(coordinator.voice.state, .paused)
        await coordinator.resume()
        XCTAssertEqual(coordinator.phase, .recording)
        await settle { self.api.commands.count == 2 }
        XCTAssertEqual(api.outcomes.first?.outcome, .answered)
        XCTAssertEqual(api.commands, [.pause, .resume])
    }

    // MARK: - Delivery

    func testNetworkBlipRetriesWithTheSameKeyInOrder() async {
        let failures = LockedCounter(3)
        api.turnsHandler = { request in
            if failures.take() { throw APIError.unreachable(baseURL: "http://x", underlying: "offline") }
            return CaptureTurnsResponse(ask: nil, stored: request.segments.count, closedQuestionId: nil, askingStopped: false)
        }
        let coordinator = await started()
        await say("first the pork belly")
        await say("now the kimchi")
        await settle { coordinator.pendingWriteCount == 0 }
        let keys = api.turnKeys
        XCTAssertEqual(keys.count, 5, "3 failed tries + 2 successes")
        XCTAssertEqual(Set(keys.prefix(4)).count, 1, "retries replay the first write's key")
        XCTAssertNotEqual(keys[3], keys[4])
        XCTAssertEqual(api.turns.last?.segments.first?.text, "now the kimchi")
        XCTAssertFalse(coordinator.isRetrying)
    }

    func testLateAnswerIsKeptAsSpeechWhenTheServerExpiredIt() async {
        askOnNextPause(ask(expiresAt: 60_000))
        api.outcomeHandler = { _, _ in .expired }
        let coordinator = await started()
        await say("Now we let it simmer", after: 5000)
        timeline.advance(byMs: 1500)
        await settle { coordinator.question?.stage == .listening }
        await say("about fifteen minutes")
        timeline.advance(byMs: 2000)
        await settle { self.api.spokenWords.contains("about fifteen minutes") }
        XCTAssertTrue(api.spokenWords.contains("about fifteen minutes"), "nothing she said is lost")
    }

    func testJournalResumeReplaysUnsentWritesAndContinuesTheClock() async throws {
        api.turnsHandler = { _ in throw APIError.unreachable(baseURL: "http://x", underlying: "offline") }
        let first = makeCoordinator()
        await first.start(titleHint: nil)
        await say("first the pork belly", after: 4000)
        await settle { self.api.turnKeys.count > 2 }
        first.stopForNow()
        let saved = try XCTUnwrap(journal.load(api.sessionId))
        XCTAssertEqual(saved.lines.map(\.text), ["first the pork belly"])
        let unsentKey = try XCTUnwrap(saved.outbox.first?.key)

        // Relaunch: a new coordinator, the network is back.
        api.turnsHandler = { request in CaptureTurnsResponse(ask: nil, stored: request.segments.count, closedQuestionId: nil, askingStopped: false) }
        transport = FakeVoiceTransport()
        let resumed = makeCoordinator()
        await resumed.resume(from: saved)
        XCTAssertEqual(resumed.phase, .recording)
        XCTAssertEqual(resumed.heard.map(\.text), ["first the pork belly"])
        await settle { resumed.pendingWriteCount == 0 }
        XCTAssertEqual(api.turnKeys.last, unsentKey, "the journaled write keeps its key")
        await say("now the kimchi", after: 1000)
        await settle { self.api.spokenWords.last == "now the kimchi" }
        let resumedT = try XCTUnwrap(api.turns.last?.segments.first?.tMs)
        XCTAssertGreaterThan(resumedT, saved.lastTMs, "time continues after the relaunch")
    }

    func testResumeOfADeletedSessionForgetsTheJournal() async throws {
        let coordinator = await started()
        coordinator.voice.stop()
        let saved = try XCTUnwrap(journal.load(api.sessionId))
        api.getError = .server(status: 404, code: "NOT_FOUND", message: "gone", retryable: false, correlationId: nil)
        let resumed = makeCoordinator()
        await resumed.resume(from: saved)
        XCTAssertEqual(resumed.phase, .failed("This recording was deleted."))
        XCTAssertNil(journal.load(api.sessionId))
    }

    // MARK: - Done and wrap-up

    func testFinishDrainsThenAsksWrapUpQuestionsEachSkippable() async {
        api.finishQuestions = [ask("How many people does this feed?", phase: .wrapup), ask("What heat do you use?", phase: .wrapup)]
        let coordinator = await started()
        await say("Serve it with rice")
        await coordinator.finish()
        XCTAssertEqual(coordinator.phase, .wrappingUp)
        XCTAssertEqual(api.spokenWords, ["Serve it with rice"], "words are sent before finish")
        await settle { coordinator.question?.stage == .listening }
        XCTAssertEqual(transport.spoken.last, "How many people does this feed?")

        await say("Four people", after: 1000)
        timeline.advance(byMs: 2000)
        await settle { coordinator.question?.ask.text == "What heat do you use?" && coordinator.question?.stage == .listening }
        await say("skip")
        await settle { coordinator.phase == .readyToGenerate }
        XCTAssertEqual(api.outcomes.map(\.outcome), [.answered, .skipped])
        XCTAssertEqual(api.outcomes.first?.answerText, "Four people")
        XCTAssertFalse(coordinator.voice.state.isActive, "the mic closes after the wrap-up")
        XCTAssertEqual(journal.load(api.sessionId)?.stage, .wrappingUp)
    }

    func testMakeRecipeNowSkipsTheRestOfTheWrapUp() async {
        api.finishQuestions = [ask("How many people does this feed?", phase: .wrapup), ask("What heat?", phase: .wrapup)]
        let coordinator = await started()
        await coordinator.finish()
        coordinator.endWrapUp()
        await settle { self.api.outcomes.count == 2 }
        XCTAssertEqual(coordinator.phase, .readyToGenerate)
        XCTAssertEqual(api.outcomes.map(\.outcome), [.skipped, .skipped])
    }

    // MARK: - Review round 1: the mic never outlives the recording

    func testFailedDoneStopsTheMicAndTheTicker() async {
        let coordinator = await started()
        api.finishGate = { throw APIError.server(status: 409, code: "STATE_CONFLICT", message: "Already finished elsewhere.", retryable: false, correlationId: nil) }
        await coordinator.finish()
        XCTAssertEqual(coordinator.phase, .failed("Already finished elsewhere."))
        XCTAssertFalse(coordinator.voice.state.isActive, "mic off after a failed Done")
        XCTAssertFalse(transport.isRunning)
        XCTAssertNil(timeline.clocks.last?.tick, "the coordinator's ticker is stopped")
    }

    func testStopForNowDuringAnInFlightTurnResendsItWithTheSameKey() async throws {
        api.turnsGate = { try await Task.sleep(for: .seconds(30)) }
        let coordinator = await started()
        await say("first the pork belly", after: 2000)
        await settle { self.api.turnKeys.count == 1 }
        let key = try XCTUnwrap(api.turnKeys.first)
        coordinator.stopForNow()
        await settle()
        XCTAssertFalse(coordinator.voice.state.isActive)
        let saved = try XCTUnwrap(journal.load(api.sessionId))
        XCTAssertEqual(saved.outbox.first?.key, key)

        api.turnsGate = nil
        transport = FakeVoiceTransport()
        let resumed = makeCoordinator()
        await resumed.resume(from: saved)
        await settle { resumed.pendingWriteCount == 0 }
        XCTAssertEqual(api.turnKeys, [key, key], "the cancelled batch is resent, same key")
        XCTAssertEqual(api.spokenWords, ["first the pork belly", "first the pork belly"])
    }

    func testDoneTurnsTheMicOffAndReopensItOnlyForWrapUp() async {
        let gate = LockedFlag()
        api.finishQuestions = [ask("How many people does this feed?", phase: .wrapup)]
        api.finishGate = { while !gate.isSet { try await Task.sleep(for: .milliseconds(5)) } }
        let coordinator = await started()
        let finishing = Task { await coordinator.finish() }
        await settle { coordinator.phase == .finishing && self.api.calls.contains(.finish(key: self.finishKey ?? "")) }
        XCTAssertEqual(coordinator.phase, .finishing)
        XCTAssertEqual(coordinator.voice.state, .paused, "nothing is heard while the recording closes")
        XCTAssertTrue(transport.isInputPaused)
        _ = gate.setOnce()
        await finishing.value
        XCTAssertEqual(coordinator.phase, .wrappingUp)
        XCTAssertTrue(coordinator.voice.state.isActive && coordinator.voice.state != .paused, "listening for the wrap-up answer")
    }

    func testDoneOfflineStallsVisiblyWithTheMicOffAndCanBeRetried() async {
        api.finishGate = { throw APIError.unreachable(baseURL: "http://x", underlying: "offline") }
        let coordinator = await started()
        await coordinator.finish()
        guard case .voiceStopped(let message) = coordinator.phase else { return XCTFail("expected a stall, got \(coordinator.phase)") }
        XCTAssertTrue(message.contains("Tap Done to try again"))
        XCTAssertFalse(coordinator.voice.state.isActive)
        let keys = api.calls.compactMap { if case .finish(let key) = $0 { key } else { nil } }
        XCTAssertEqual(keys.count, coordinator.config.maxFinishFailures)
        api.finishGate = nil
        await coordinator.finish()
        XCTAssertEqual(coordinator.phase, .readyToGenerate)
        let all = api.calls.compactMap { if case .finish(let key) = $0 { key } else { nil } }
        XCTAssertEqual(Set(all).count, 1, "a retried Done reuses its key")
    }

    func testAnAskThatArrivesAlreadyExpiredIsReportedExpiredNotLater() async {
        let coordinator = await started()
        coordinator.stopAsking()
        // A question the server queued before "stop asking" lands after its expiry.
        let stale = ask(expiresAt: 1000)
        api.turnsHandler = { _ in CaptureTurnsResponse(ask: stale, stored: 0, closedQuestionId: nil, askingStopped: true) }
        await say("now we let it simmer", after: 5000)
        await settle { !self.api.outcomes.isEmpty }
        XCTAssertEqual(api.outcomes.first?.outcome, .expired)
    }

    private var finishKey: String? { journal.load(api.sessionId)?.finishKey }

    // MARK: - Teardown while starting

    func testStopForNowWhileStartingNeverOpensTheMic() async {
        let release = LockedFlag()
        api.createGate = { while !release.isSet { try await Task.sleep(for: .milliseconds(5)) } }
        let coordinator = makeCoordinator()
        let starting = Task { await coordinator.start(titleHint: nil) }
        await settle { self.api.calls.contains(.create) }
        XCTAssertEqual(coordinator.phase, .starting)
        coordinator.stopForNow()
        _ = release.setOnce()
        await starting.value
        XCTAssertFalse(coordinator.voice.state.isActive, "no mic after teardown")
        XCTAssertEqual(transport.startCount, 0)
        XCTAssertFalse(api.calls.contains(.delete), "Stop for now keeps the new session resumable")
        XCTAssertNotNil(journal.load(api.sessionId))
    }

    func testStopForNowWhileResumingNeverOpensTheMic() async throws {
        let coordinator = await started()
        coordinator.stopForNow()
        let saved = try XCTUnwrap(journal.load(api.sessionId))
        let release = LockedFlag()
        api.getGate = { while !release.isSet { try await Task.sleep(for: .milliseconds(5)) } }
        transport = FakeVoiceTransport()
        let resumed = makeCoordinator()
        let resuming = Task { await resumed.resume(from: saved) }
        await settle { self.api.calls.filter { $0 == .get }.count == 1 }
        resumed.stopForNow()
        _ = release.setOnce()
        await resuming.value
        XCTAssertEqual(transport.startCount, 0)
        XCTAssertFalse(resumed.voice.state.isActive)
    }

    // MARK: - Review round 2: teardown while the mic restarts

    private func holdMicStart(until release: LockedFlag) {
        transport.beforeStart = { while !release.isSet { try? await Task.sleep(for: .milliseconds(5)) } }
    }

    func testStopForNowWhileResumeStartsTheMicKeepsItOff() async {
        let coordinator = await started()
        coordinator.stopForNow()
        let stopped = coordinator.phase
        let release = LockedFlag()
        holdMicStart(until: release)
        let resuming = Task { await coordinator.resume() }
        await settle { self.transport.startCount == 2 }
        XCTAssertEqual(transport.startCount, 2, "Resume is starting the mic")
        coordinator.stopForNow()
        _ = release.setOnce()
        await resuming.value
        await settle()
        XCTAssertEqual(coordinator.phase, stopped, "the Stop for now message stays")
        XCTAssertFalse(coordinator.voice.state.isActive, "no mic after teardown")
        XCTAssertFalse(transport.isRunning)
        XCTAssertTrue(coordinator.outbox.isSuspended, "the outbox is not reopened")
        XCTAssertFalse(api.commands.contains(.resume))
    }

    func testStopForNowWhileDoneStartsTheMicForWrapUpKeepsItOff() async {
        api.finishQuestions = [ask("How many people does this feed?", phase: .wrapup)]
        let coordinator = await started()
        coordinator.stopForNow()
        let stopped = coordinator.phase
        let release = LockedFlag()
        holdMicStart(until: release)
        let finishing = Task { await coordinator.finish() }
        await settle { self.transport.startCount == 2 }
        XCTAssertEqual(transport.startCount, 2, "Done is starting the mic for the wrap-up")
        coordinator.stopForNow()
        _ = release.setOnce()
        await finishing.value
        await settle()
        XCTAssertEqual(coordinator.phase, stopped, "not wrapping up, not ready to generate")
        XCTAssertNil(coordinator.question)
        XCTAssertFalse(coordinator.voice.state.isActive, "no mic after teardown")
        XCTAssertFalse(transport.isRunning)
        XCTAssertTrue(coordinator.outbox.isSuspended)
        XCTAssertEqual(coordinator.record?.closedQuestionIds.isEmpty, true, "the wrap-up question isn't skipped")
        XCTAssertEqual(journal.load(api.sessionId)?.stage, .wrappingUp, "Profile can still make the recipe")
    }

    func testDoneStalledAfterStopForNowKeepsTheStopMessage() async {
        api.turnsGate = { try await Task.sleep(for: .seconds(30)) }
        let coordinator = await started()
        await say("first the pork belly", after: 2000)
        let finishing = Task { await coordinator.finish() }
        await settle { coordinator.phase == .finishing }
        coordinator.stopForNow()
        await finishing.value
        XCTAssertEqual(coordinator.phase, .voiceStopped("Recording stopped. Resume or finish it from Profile."))
    }

    // MARK: - Review round 2: server text limits

    func testLongSpeechIsSplitIntoSegmentsTheServerAccepts() async {
        let coordinator = await started()
        let long = String(repeating: "then you stir it slowly ", count: 120)
        await say(long, after: 2000)
        await settle { self.api.spokenWords.count >= 2 }
        XCTAssertGreaterThanOrEqual(api.spokenWords.count, 2)
        XCTAssertTrue(api.spokenWords.allSatisfy { $0.unicodeScalars.count <= CaptureLimits.spokenTextMax })
        XCTAssertEqual(coordinator.heard.count, api.spokenWords.count, "every word is kept")
    }

    func testALongAnswerIsClampedToTheServerLimit() async {
        let question = ask(expiresAt: 400_000)
        askOnNextPause(question)
        let coordinator = await started()
        await say("Now we let it simmer", after: 10_000)
        timeline.advance(byMs: 1500)
        await settle { coordinator.question?.stage == .listening }
        let long = String(repeating: "about fifteen minutes ", count: 60)
        await say(long, after: 1000)
        await say(long, after: 500)
        timeline.advance(byMs: 2000)
        await settle { !self.api.outcomes.isEmpty }
        let answer = api.outcomes.first?.answerText ?? ""
        XCTAssertEqual(api.outcomes.first?.outcome, .answered)
        XCTAssertLessThanOrEqual(answer.unicodeScalars.count, CaptureLimits.spokenTextMax)
        XCTAssertTrue(answer.hasPrefix("about fifteen minutes"))
        let words = Set(answer.split(separator: " ").map(String.init))
        XCTAssertTrue(words.isSubset(of: ["about", "fifteen", "minutes"]), "cut on a word boundary")
    }
}
