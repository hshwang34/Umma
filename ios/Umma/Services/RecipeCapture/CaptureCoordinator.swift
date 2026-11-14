import Foundation
import Observation

/// Records one voice recipe capture (brief 014): owns the `VoiceSession`, streams final captions
/// through the `CaptureOutbox`, asks the server's questions at a pause, and runs the answer window.
///
/// Gate (ported from Retrace's Expert Interviewer, ADR-0001): a question the server returns is
/// held until the creator has been quiet for `policy.silenceBeforeAskMs`, Umma isn't speaking,
/// and the session isn't paused. A held question past its `expiresAtMs` is reported expired
/// without ever being spoken.
///
/// Answer window: after Umma speaks the question, the creator's words are the answer (not sent as
/// turns). The window closes as `answered` once she has said something and gone quiet for
/// `answerSettleMs`, as `expired` (live) / `skipped` (wrap-up) after `answerWindowSilenceMs` of
/// silence with no answer, and always just before the live question's expiry. "Skip", "later" and
/// "stop asking" close it straight away.
///
/// Mic: listening only while recording and while a wrap-up question is open. Done, a failure,
/// Stop for now and discard all stop the voice and the ticker.
@MainActor
@Observable
final class CaptureCoordinator {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
        /// Voice is off (a spoken "stop", a transport failure, or Done couldn't reach the server);
        /// Resume or Done again.
        case voiceStopped(String)
        /// Done was tapped: the mic is off while the last words are sent and the recording closes.
        case finishing
        case wrappingUp
        /// Recording and wrap-up are over; the draft can be generated.
        case readyToGenerate
        case failed(String)
    }

    enum QuestionStage: Equatable {
        /// Returned by the server, waiting for a pause.
        case waiting
        case speaking
        case listening
    }

    struct QuestionCard: Equatable {
        let ask: CaptureAsk
        var stage: QuestionStage
        var answer: String = ""
    }

    struct Config: Equatable, Sendable {
        var answerWindowSilenceMs: Int64 = 12_000
        var answerSettleMs: Int64 = 2_000
        /// Close a live window this long before the server would expire the question.
        var expiryMarginMs: Int64 = 500
        var tickIntervalMs: Int64 = 250
        var retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
        /// Done gives up after this many network failures in a row and says so (about 30 s).
        var maxFinishFailures = 5
        /// Umma's one line when recording starts (brief 014 storyboard).
        var introLine: String? = "I'm listening. Just cook and tell me what you're doing."
    }

    private(set) var phase: Phase = .idle
    private(set) var question: QuestionCard?
    /// Everything the creator said (final captions), oldest first.
    private(set) var heard: [CaptureJournalRecord.Line] = []
    private(set) var askingStopped = false
    private(set) var policy: CapturePolicy = .default
    private(set) var wrapUpQuestions: [CaptureAsk] = []
    private(set) var wrapUpIndex = 0

    let voice: VoiceSession
    let config: Config
    let outbox: CaptureOutbox
    var record: CaptureJournalRecord? { outbox.record }
    var sessionId: UUID? { outbox.sessionId }
    var pendingWriteCount: Int { outbox.pendingCount }
    var isRetrying: Bool { outbox.isRetrying }
    var isVoiceAvailable: Bool { voice.transport.isAvailable }

    let api: CaptureService
    private let ticker: any VoiceClock
    private let userId: UUID?
    private let sleep: @Sendable (Duration) async -> Void
    /// Session time added to the voice clock (voice restarts from 0 after a stop or relaunch).
    private var baseMs: Int64 = 0
    private var nextLineId = 0
    /// Bumped by `stopForNow()` and `discard()` in any phase. `start()`, both resumes and Done's
    /// wrap-up check it after every await that can open the mic, so a teardown while the mic is
    /// starting can never leave it open, change the phase or reopen the outbox afterwards.
    private(set) var runToken = 0
    /// Set by `discard()`: a session created after it is deleted, not kept.
    var discardRequested = false

    /// `makeVoice` receives the config to use: silence never ends a capture session.
    init(api: CaptureService,
         makeVoice: (VoiceSessionConfig) -> VoiceSession,
         journal: CaptureJournalStore = .live,
         userId: UUID?,
         ticker: any VoiceClock = SystemVoiceClock(),
         config: Config = .init(),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        var voiceConfig = VoiceSessionConfig()
        voiceConfig.silenceTimeoutMs = nil
        voice = makeVoice(voiceConfig)
        self.api = api
        self.userId = userId
        self.ticker = ticker
        self.config = config
        self.sleep = sleep
        outbox = CaptureOutbox(api: api, journal: journal, retryDelays: config.retryDelays, sleep: sleep)
        voice.onEvent = { [weak self] in self?.handle($0) }
        outbox.onEvent = { [weak self] event in
            switch event {
            case .turns(let response): self?.apply(response)
            case .sessionGone: self?.fail("This recording was deleted.")
            }
        }
    }

    /// Session time now: what every `t_ms` sent to the server uses.
    var nowMs: Int64 { max(record?.lastTMs ?? 0, baseMs + (voice.state.isActive ? voice.elapsedMs : 0)) }

    // MARK: - Lifecycle

    func start(titleHint: String?) async {
        guard phase == .idle || isFailed else { return }
        let token = runToken
        guard voice.transport.isAvailable else {
            phase = .failed("Voice isn’t available on this device, so recording can’t start. You can type the recipe in instead.")
            return
        }
        phase = .starting
        let session: CaptureSession
        do {
            session = try await api.createCaptureSession(CaptureCreateRequest(titleHint: titleHint), idempotencyKey: UUID().uuidString)
        } catch {
            guard token == runToken else { return }
            phase = .failed(Self.message(error))
            return
        }
        guard token == runToken else {
            // Torn down while the session was being created: never open the mic. A discard deletes
            // the new session; Stop for now keeps it resumable from Profile.
            if discardRequested {
                try? await api.deleteCaptureSession(id: session.id)
            } else {
                outbox.open(CaptureJournalRecord(sessionId: session.id, userId: userId, titleHint: titleHint, startedAt: Date()))
                outbox.suspend()
            }
            return
        }
        policy = session.policy
        outbox.open(CaptureJournalRecord(sessionId: session.id, userId: userId, titleHint: titleHint, startedAt: Date()))
        do {
            try await startVoice()
            guard token == runToken else { return silence() }
            phase = .recording
            if let intro = config.introLine {
                Task { [weak self] in await self?.voice.say(intro) }
            }
        } catch {
            guard token == runToken else { return silence() }
            // Nothing was heard: drop the empty session rather than leave it open.
            outbox.forget()
            try? await api.deleteCaptureSession(id: session.id)
            fail("Couldn’t start listening: \(error.localizedDescription)")
        }
    }

    /// After a relaunch: continue (or finish) a journaled session. The mic only reopens on this
    /// explicit call, never on launch, and only for a session still recording.
    func resume(from saved: CaptureJournalRecord) async {
        guard phase == .idle || isFailed else { return }
        let token = runToken
        phase = .starting
        outbox.open(saved)
        heard = saved.lines
        nextLineId = saved.lines.map(\.id).max() ?? 0
        askingStopped = saved.askingStopped
        baseMs = saved.lastTMs + 1
        let session: CaptureSession
        do {
            session = try await api.captureSession(id: saved.sessionId)
        } catch let error as APIError where error.isNotFound {
            guard token == runToken else { return }
            outbox.forget()
            fail("This recording was deleted.")
            return
        } catch {
            guard token == runToken else { return }
            fail(Self.message(error))
            return
        }
        guard token == runToken else { return outbox.suspend() }
        policy = session.policy
        askingStopped = askingStopped || session.askingStopped
        // Words heard before the crash go first, with their original keys.
        outbox.drain()
        guard session.status == .recording else {
            phase = .readyToGenerate
            return
        }
        do {
            try await startVoice()
            guard token == runToken else { return silence() }
            phase = .recording
            flushTurns(silenceMs: 0)
            if session.paused { enqueue(.command(CaptureCommandRequest(command: .resume, tMs: nowMs))) }
        } catch {
            guard token == runToken else { return silence() }
            phase = .voiceStopped("Couldn’t start listening: \(error.localizedDescription)")
        }
    }

    func pause() {
        guard phase == .recording else { return }
        closeWindowForInterruption()
        voice.pause()
        phase = .paused
        enqueue(.command(CaptureCommandRequest(command: .pause, tMs: nowMs)))
    }

    func resume() async {
        switch phase {
        case .paused, .voiceStopped: break
        default: return
        }
        let token = runToken
        let listening = await listen(token: token)
        // Stopped for now (or backgrounded) while the mic was starting: keep it off, keep the
        // "Recording stopped" phase and leave the outbox suspended.
        guard token == runToken else { return silence() }
        guard listening else { return }
        phase = .recording
        outbox.reopen()
        enqueue(.command(CaptureCommandRequest(command: .resume, tMs: nowMs)))
    }

    /// The card's Skip button, or a spoken "skip".
    func skipQuestion() {
        guard question != nil else { return }
        close(.skipped)
    }

    /// The card's "Ask me later" / "Leave it" button.
    func deferQuestion() {
        guard let question else { return }
        close(deferral(for: question.ask))
    }

    func stopAsking() {
        guard !askingStopped else { return }
        askingStopped = true
        outbox.update { $0.askingStopped = true }
        if let question, question.ask.phase == .live { close(deferral(for: question.ask)) }
        enqueue(.command(CaptureCommandRequest(command: .stopAsking, tMs: nowMs)))
    }

    /// Done: the mic goes off, the last words are sent, the recording closes, and the mic reopens
    /// only to ask the wrap-up questions. Offline, it gives up after `maxFinishFailures` network
    /// failures in a row and says so; the words stay journaled and Done can be tapped again.
    func finish() async {
        switch phase {
        case .recording, .paused, .voiceStopped: break
        default: return
        }
        let token = runToken
        closeWindowForInterruption()
        flushTurns(silenceMs: voice.silenceMs)
        phase = .finishing
        outbox.reopen()
        if voice.state.isActive, voice.state != .paused { voice.pause() }
        guard await outbox.flush(maxFailures: config.maxFinishFailures), let sessionId else {
            return finishStalled()
        }
        let key = record?.finishKey ?? UUID().uuidString
        outbox.update { $0.finishKey = key }
        var response: CaptureFinishResponse?
        var failures = 0
        while response == nil {
            do {
                response = try await api.finishCapture(sessionId: sessionId, CaptureFinishRequest(tMs: nowMs), idempotencyKey: key)
            } catch let error as APIError where error.isRetryable {
                failures += 1
                guard failures < config.maxFinishFailures, phase == .finishing else { return finishStalled() }
                await sleep(config.retryDelays.isEmpty ? .seconds(1) : config.retryDelays[min(failures - 1, config.retryDelays.count - 1)])
            } catch {
                return fail(Self.message(error))
            }
        }
        outbox.update { $0.stage = .wrappingUp }
        // Left the screen while finishing: the recording is closed, but the mic stays off.
        guard phase == .finishing else { return }
        wrapUpQuestions = response?.questions ?? []
        wrapUpIndex = 0
        guard !wrapUpQuestions.isEmpty else { return endWrapUp() }
        let listening = await listen(token: token)
        // Torn down while the mic was starting: mic off, no wrap-up, the phase `stopForNow` set
        // stays. The journal says wrapping up, so Profile offers to make the recipe.
        guard token == runToken else { return silence() }
        guard listening else { return endWrapUp() }
        phase = .wrappingUp
        question = QuestionCard(ask: wrapUpQuestions[0], stage: .waiting)
        tryDeliver()
    }

    /// "Make my recipe now": skip what's left of the wrap-up.
    func endWrapUp() {
        if question != nil { close(.skipped, advance: false) }
        // Anything not asked yet is skipped; it becomes "needs review" in the draft.
        for ask in wrapUpQuestions.dropFirst(wrapUpIndex) {
            postOutcome(ask, .skipped, answer: nil)
        }
        wrapUpIndex = wrapUpQuestions.count
        phase = .readyToGenerate
        silence()
    }

    /// Leaving the screen, the app going to the background, sign-out: stop listening and sending,
    /// keep the journal so the session can be resumed or finished later.
    func stopForNow() {
        runToken += 1
        closeWindowForInterruption()
        switch phase {
        case .starting:
            phase = .idle
        case .recording, .paused, .finishing:
            phase = .voiceStopped("Recording stopped. Resume or finish it from Profile.")
        case .wrappingUp:
            endWrapUp()
        default: break
        }
        silence()
        outbox.suspend()
    }

    // MARK: - Voice

    private func startVoice() async throws {
        if case .ended = voice.state { baseMs = nowMs }
        try await voice.start()
        ticker.startTicking(everyMs: config.tickIntervalMs) { [weak self] in self?.tick() }
    }

    /// Opens the mic again (from paused or stopped). False, with the reason shown, if it can't.
    /// Callers check `token` against `runToken` afterwards: a teardown during the await wins.
    private func listen(token: Int) async -> Bool {
        if voice.state == .paused {
            voice.resume()
            return true
        }
        guard !voice.state.isActive else { return true }
        do {
            try await startVoice()
            return true
        } catch {
            // A teardown cancels the start; its message ("Recording stopped…") stays.
            if token == runToken {
                phase = .voiceStopped("Couldn’t start listening: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// Mic and ticker off.
    private func silence() {
        voice.stop()
        ticker.stopTicking()
    }

    /// Invalidates any start or resume still awaiting (see `runToken`).
    func cancelPendingStart() {
        runToken += 1
    }

    /// Every failure turns the mic and the ticker off.
    func fail(_ message: String) {
        closeWindowForInterruption()
        phase = .failed(message)
        silence()
    }

    private func finishStalled() {
        // `stopForNow()` suspended the outbox (so the flush gave up) and already said why.
        guard phase == .finishing else { return }
        phase = .voiceStopped("Couldn’t reach Umma to finish. Everything you said is saved on this phone. Tap Done to try again.")
        silence()
    }

    private func handle(_ event: VoiceSessionEvent) {
        switch event {
        case .userSegment(let segment):
            heardSegment(segment)
        case .pause(let silenceMs):
            if question?.stage == .waiting {
                tryDeliver()
            } else if question == nil, phase == .recording {
                flushTurns(silenceMs: silenceMs)
            }
        case .ended(let reason):
            baseMs = max(baseMs + voice.elapsedMs, record?.lastTMs ?? 0)
            ticker.stopTicking()
            guard phase == .recording || phase == .paused || phase == .wrappingUp else { return }
            closeWindowForInterruption()
            if phase == .wrappingUp {
                endWrapUp()
            } else {
                phase = .voiceStopped(Self.endedText(reason))
            }
        }
    }

    private func heardSegment(_ segment: VoiceSegment) {
        let tMs = baseMs + segment.startMs
        let command = CaptureVoiceCommand.parse(segment.text)
        if let question, question.stage != .waiting, let command {
            switch command {
            case .skip: close(.skipped)
            case .later: close(deferral(for: question.ask))
            case .stopAsking: stopAsking()
            }
            return
        }
        // The server refuses any text over `CaptureLimits.spokenTextMax`: a long caption becomes
        // several lines (and segments), never one too long to send.
        let pieces = CaptureLimits.split(segment.text)
        if let question, question.stage == .listening {
            // Beyond the limit the answer keeps its first words; every word stays in the journal.
            self.question?.answer = CaptureLimits.clamp([question.answer, segment.text].filter { !$0.isEmpty }.joined(separator: " "))
            for piece in pieces { appendLine(tMs: tMs, text: piece, questionId: question.ask.questionId) }
            return
        }
        // Words finished just as Umma started asking are ordinary speech, never lost.
        switch command {
        case .stopAsking: stopAsking(); return
        case .skip, .later:
            // Nothing spoken yet to skip; a held question is dropped the same way.
            if let question { close(command == .skip ? .skipped : deferral(for: question.ask)) }
            return
        case nil: break
        }
        for piece in pieces { appendLine(tMs: tMs, text: piece, questionId: nil) }
        // After Done the recording is closed on the server; the words stay in the journal.
        guard phase == .recording || phase == .paused else { return }
        outbox.update { $0.unsent.append(contentsOf: pieces.map { CaptureSegmentIn(tMs: tMs, text: $0) }) }
        flushTurns(silenceMs: 0)
    }

    private func appendLine(tMs: Int64, text: String, questionId: UUID?) {
        nextLineId += 1
        let line = CaptureJournalRecord.Line(id: nextLineId, tMs: tMs, text: text, questionId: questionId)
        heard.append(line)
        outbox.update { record in
            record.lines.append(line)
            record.lastTMs = max(record.lastTMs, tMs)
        }
    }

    // MARK: - Gate and answer window

    private func tick() {
        guard let question else { return }
        switch question.stage {
        case .waiting:
            tryDeliver()
        case .speaking:
            break
        case .listening:
            if isPastExpiry(question.ask) {
                close(question.answer.isEmpty ? .expired : .answered)
            } else if question.answer.isEmpty, voice.silenceMs >= config.answerWindowSilenceMs {
                close(question.ask.phase == .wrapup ? .skipped : .expired)
            } else if !question.answer.isEmpty, voice.silenceMs >= config.answerSettleMs, voice.partial == nil {
                close(.answered)
            }
        }
    }

    private func tryDeliver() {
        guard let card = question, card.stage == .waiting else { return }
        if isPastExpiry(card.ask) {
            close(.expired)
            return
        }
        let live = card.ask.phase != .wrapup
        guard phase == (live ? .recording : .wrappingUp),
              !(live && askingStopped),
              voice.state == .listening,
              voice.partial == nil,
              voice.silenceMs >= policy.silenceBeforeAskMs || !live
        else { return }
        question?.stage = .speaking
        let id = card.ask.questionId
        Task { [weak self] in
            guard let self else { return }
            await self.voice.say(card.ask.text)
            guard self.question?.ask.questionId == id, self.question?.stage == .speaking else { return }
            guard self.voice.state == .listening else { return }
            self.question?.stage = .listening
        }
    }

    private func isPastExpiry(_ ask: CaptureAsk) -> Bool {
        guard let expiry = ask.expiresAtMs else { return false }
        return nowMs >= expiry - config.expiryMarginMs
    }

    /// Put off without an answer: a live question goes to the wrap-up unless it has already
    /// expired; in the wrap-up "later" counts as skipped.
    private func deferral(for ask: CaptureAsk) -> CaptureOutcome {
        if ask.phase == .wrapup { return .skipped }
        return isPastExpiry(ask) ? .expired : .later
    }

    /// Pause, Done or a voice stop mid-question: keep an answer she gave, defer the rest.
    private func closeWindowForInterruption() {
        guard let question else { return }
        close(question.answer.isEmpty ? deferral(for: question.ask) : .answered, advance: false)
    }

    private func close(_ outcome: CaptureOutcome, advance: Bool = true) {
        guard let card = question else { return }
        question = nil
        if card.stage == .speaking { voice.transport.stopSpeaking() }
        let answer = outcome == .answered ? card.answer : nil
        postOutcome(card.ask, outcome == .answered && card.answer.isEmpty ? .expired : outcome, answer: answer)
        guard advance, card.ask.phase == .wrapup, phase == .wrappingUp else { return }
        wrapUpIndex += 1
        if wrapUpIndex < wrapUpQuestions.count {
            question = QuestionCard(ask: wrapUpQuestions[wrapUpIndex], stage: .waiting)
            tryDeliver()
        } else {
            endWrapUp()
        }
    }

    private func postOutcome(_ ask: CaptureAsk, _ outcome: CaptureOutcome, answer: String?) {
        guard record?.closedQuestionIds.contains(ask.questionId) == false else { return }
        outbox.update { $0.closedQuestionIds.append(ask.questionId) }
        enqueue(.outcome(questionId: ask.questionId, CaptureOutcomeRequest(outcome: outcome, answerText: answer, tMs: nowMs)))
    }

    // MARK: - Turns

    private func flushTurns(silenceMs: Int64) {
        guard let segments = record?.unsent else { return }
        // An empty batch only matters as "a pause started" (the server's ask gate).
        guard !segments.isEmpty || silenceMs >= policy.silenceBeforeAskMs else { return }
        outbox.update { $0.unsent = [] }
        guard !segments.isEmpty else {
            return enqueue(.turns(CaptureTurnsRequest(segments: [], silenceMs: silenceMs,
                                                      assistantSpeaking: voice.state == .speaking, tMs: nowMs)))
        }
        // At most `CaptureLimits.segmentsPerTurn` segments per batch (the server's cap).
        for start in stride(from: 0, to: segments.count, by: CaptureLimits.segmentsPerTurn) {
            let batch = Array(segments[start..<min(start + CaptureLimits.segmentsPerTurn, segments.count)])
            enqueue(.turns(CaptureTurnsRequest(segments: batch, silenceMs: silenceMs,
                                               assistantSpeaking: voice.state == .speaking, tMs: nowMs)))
        }
    }

    private func enqueue(_ body: CaptureWrite.Body) {
        outbox.enqueue(body, at: nowMs)
    }

    private func apply(_ response: CaptureTurnsResponse) {
        if response.askingStopped, !askingStopped {
            askingStopped = true
            outbox.update { $0.askingStopped = true }
        }
        if let closed = response.closedQuestionId, question?.ask.questionId == closed {
            outbox.update { $0.closedQuestionIds.append(closed) }
            question = nil
        }
        guard let ask = response.ask, ask.phase == .live else { return }
        if question != nil || askingStopped || phase != .recording {
            // Already asking, told to stop, or paused meanwhile: never spoken, so defer it.
            postOutcome(ask, deferral(for: ask), answer: nil)
            return
        }
        question = QuestionCard(ask: ask, stage: .waiting)
        tryDeliver()
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    static func message(_ error: Error) -> String {
        (error as? APIError)?.userMessage ?? error.localizedDescription
    }

    private static func endedText(_ reason: VoiceEndReason) -> String {
        switch reason {
        case .stopCommand: "You said “stop”, so Umma stopped listening. Tap Resume to keep recording."
        case .failed(let message): "Listening stopped: \(message)"
        case .stopped, .silenceTimeout: "Umma stopped listening. Tap Resume to keep recording."
        }
    }
}
