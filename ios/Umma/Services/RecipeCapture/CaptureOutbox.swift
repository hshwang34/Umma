import Foundation
import Observation
import os

/// The capture session's delivery layer (brief 014): an ordered outbox of writes to the server,
/// kept in the session's journal with each write's `Idempotency-Key`.
///
/// - One write in flight at a time, in order. A network blip retries the same write with the same
///   key after a backoff; a refusal for one write (a question already closed) drops only that
///   write; a 404 on the session forgets the journal and reports `.sessionGone`.
/// - Cancellation (leaving the screen, the app going away) leaves the write at the head of the
///   outbox, so the next drain (or a relaunch) resends it with the same key.
/// - A 401 (signed out, token expired) also keeps the head with its key and suspends sending:
///   retrying can't help until she signs in again and reopens the session.
/// - An answer the server recorded too late to count is re-sent as ordinary speech, so nothing
///   she said is lost.
@MainActor
@Observable
final class CaptureOutbox {
    enum Event {
        case turns(CaptureTurnsResponse)
        /// The session was deleted on the server; the journal is gone.
        case sessionGone
    }

    private(set) var record: CaptureJournalRecord?
    /// The last write failed on the network and is being retried.
    private(set) var isRetrying = false
    /// Network failures in a row (reset by any success).
    private(set) var failureStreak = 0
    /// Receives server responses and session loss, in order.
    var onEvent: ((Event) -> Void)?

    var pendingCount: Int { record?.outbox.count ?? 0 }
    var sessionId: UUID? { record?.sessionId }

    private let api: CaptureService
    private let journal: CaptureJournalStore
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async -> Void
    private let logger = Logger(subsystem: "com.umma.ios", category: "capture-outbox")
    private var drainTask: Task<Void, Never>?
    private var drainGeneration = 0
    /// Set by `suspend()`: writes are still journaled but nothing is sent until `reopen()`.
    private(set) var isSuspended = false

    init(api: CaptureService,
         journal: CaptureJournalStore,
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)],
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.api = api
        self.journal = journal
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    /// Starts journaling `record` (a new session, or one loaded after a relaunch).
    func open(_ record: CaptureJournalRecord) {
        self.record = record
        isSuspended = false
        journal.save(record)
    }

    /// Changes the journal and saves it.
    func update(_ change: (inout CaptureJournalRecord) -> Void) {
        guard var current = record else { return }
        change(&current)
        record = current
        journal.save(current)
    }

    /// Queues a write (with a fresh key) and starts sending.
    func enqueue(_ body: CaptureWrite.Body, at tMs: Int64) {
        update { record in
            // A stale pause-only turn waiting behind a blocked queue is dropped for the newer
            // write; the head may be in flight, so it stays.
            if record.outbox.count > 1 {
                record.outbox = [record.outbox[0]] + record.outbox.dropFirst().filter { !$0.isPauseOnlyTurn }
            }
            record.outbox.append(CaptureWrite(body: body))
            record.lastTMs = max(record.lastTMs, tMs)
        }
        drain()
    }

    func drain() {
        guard drainTask == nil, record != nil, !isSuspended else { return }
        drainGeneration += 1
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drainLoop()
            if self?.drainGeneration == generation { self?.drainTask = nil }
        }
    }

    /// Sends everything queued. False when the network failed `maxFailures` times in a row (the
    /// writes stay journaled and keep retrying in the background).
    func flush(maxFailures: Int) async -> Bool {
        failureStreak = 0
        drain()
        while pendingCount > 0, record != nil {
            if failureStreak >= maxFailures || isSuspended { return false }
            await sleep(.milliseconds(200))
            if drainTask == nil { drain() }
        }
        return true
    }

    /// Stops sending; the journal keeps every unsent write for a later drain or relaunch.
    func suspend() {
        isSuspended = true
        drainTask?.cancel()
        drainTask = nil
    }

    /// Sending again after `suspend()` (Resume on the same screen).
    func reopen() {
        isSuspended = false
        drain()
    }

    /// The session is over (a draft exists, or it was discarded): nothing left to resume.
    func forget() {
        suspend()
        if let sessionId { journal.remove(sessionId) }
        record = nil
    }

    // MARK: - Sending

    private func drainLoop() async {
        var attempt = 0
        while let write = record?.outbox.first, let sessionId, !Task.isCancelled {
            do {
                try await send(write, sessionId: sessionId)
                update { if $0.outbox.first == write { $0.outbox.removeFirst() } }
                isRetrying = false
                failureStreak = 0
                attempt = 0
            } catch let error as APIError where error == .cancelled {
                return  // the head stays queued with its key
            } catch is CancellationError {
                return
            } catch let error as APIError where error.status == 401 {
                // Never drop her words over an expired sign-in: keep the head and stop sending
                // (a later `open`/`reopen` after signing in resends it with the same key).
                logger.info("capture write paused: signed out")
                suspend()
                return
            } catch let error as APIError where error.isRetryable {
                isRetrying = true
                failureStreak += 1
                logger.info("capture write retry \(attempt, privacy: .public): \(error.userMessage, privacy: .public)")
                await sleep(retryDelays.isEmpty ? .seconds(1) : retryDelays[min(attempt, retryDelays.count - 1)])
                attempt += 1
            } catch let error as APIError where error.isNotFound && !write.isOutcome {
                journal.remove(sessionId)
                record = nil
                onEvent?(.sessionGone)
                return
            } catch {
                // The server refused this one write (a question already closed, …): drop it.
                logger.error("capture write dropped: \((error as? APIError)?.userMessage ?? error.localizedDescription, privacy: .public)")
                update { if $0.outbox.first == write { $0.outbox.removeFirst() } }
            }
        }
    }

    private func send(_ write: CaptureWrite, sessionId: UUID) async throws {
        switch write.body {
        case .turns(let request):
            let response = try await api.postCaptureTurns(sessionId: sessionId, request, idempotencyKey: write.key)
            onEvent?(.turns(response))
        case .outcome(let questionId, let request):
            let response = try await api.postCaptureOutcome(sessionId: sessionId, questionId: questionId, request, idempotencyKey: write.key)
            if request.outcome == .answered, response.outcome != .answered {
                // Recorded too late to count as the answer: keep her words as ordinary speech. The
                // outcome leaves the outbox in the same journal save that queues the words, so a
                // crash can't replay the outcome and queue them twice.
                update { record in
                    guard record.outbox.first == write else { return }
                    record.outbox.removeFirst()
                    let words = record.lines.filter { $0.questionId == questionId }.map { CaptureSegmentIn(tMs: $0.tMs, text: $0.text) }
                    for start in stride(from: 0, to: words.count, by: CaptureLimits.segmentsPerTurn) {
                        let batch = Array(words[start..<min(start + CaptureLimits.segmentsPerTurn, words.count)])
                        record.outbox.append(CaptureWrite(body: .turns(CaptureTurnsRequest(segments: batch, silenceMs: 0, assistantSpeaking: false, tMs: nil))))
                    }
                }
            }
        case .command(let request):
            _ = try await api.postCaptureCommand(sessionId: sessionId, request, idempotencyKey: write.key)
        }
    }
}

private extension CaptureWrite {
    var isOutcome: Bool {
        if case .outcome = body { return true }
        return false
    }
}
