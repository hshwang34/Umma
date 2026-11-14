import Foundation
import XCTest
@testable import Umma

/// Scriptable `CaptureService`: records every write with its idempotency key.
final class FakeCaptureService: CaptureService, @unchecked Sendable {
    enum Call: Equatable {
        case create
        case get
        case delete
        case turns(CaptureTurnsRequest, key: String)
        case outcome(UUID, CaptureOutcomeRequest, key: String)
        case command(CaptureCommand, key: String)
        case finish(key: String)
        case generate(key: String)
        case job(UUID)
    }

    let sessionId = UUID()
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    var turnsHandler: @Sendable (CaptureTurnsRequest) throws -> CaptureTurnsResponse = { _ in
        CaptureTurnsResponse(ask: nil, stored: 0, closedQuestionId: nil, askingStopped: false)
    }
    var outcomeHandler: @Sendable (UUID, CaptureOutcomeRequest) throws -> CaptureOutcome = { _, request in request.outcome }
    var finishQuestions: [CaptureAsk] = []
    var sessionStatus: CaptureSessionStatus = .recording
    var getError: APIError?
    var deleteError: APIError?
    /// Runs inside the create call before it answers (a slow network while `.starting`).
    var createGate: (@Sendable () async throws -> Void)?
    var getGate: (@Sendable () async throws -> Void)?
    /// Runs inside the turns call before it answers (an in-flight request a test can cancel).
    var turnsGate: (@Sendable () async throws -> Void)?
    /// Runs inside the finish call before it answers; throw to fail it.
    var finishGate: (@Sendable () async throws -> Void)?
    /// Runs inside the job poll before it answers (an in-flight poll a test can cancel).
    var jobGate: (@Sendable () async throws -> Void)?
    var generateHandler: @Sendable () throws -> ExtractionJob = { throw APIError.http(status: 599, correlationId: nil) }
    var jobHandler: @Sendable (UUID) throws -> ExtractionJob = { _ in throw APIError.http(status: 599, correlationId: nil) }

    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    func session(status: CaptureSessionStatus? = nil, wrapup: [CaptureAsk] = []) -> CaptureSession {
        CaptureSession(id: sessionId, mode: "voice", status: status ?? sessionStatus, titleHint: nil, draftId: nil, extractionJobId: nil,
                       askingStopped: false, paused: false, liveAsksUsed: 0, pendingQuestion: nil, wrapupQuestions: wrapup,
                       transcriptDeleted: false, policy: .default, startedAt: Date(), endedAt: nil, createdAt: Date(),
                       updatedAt: Date(), events: nil)
    }

    func createCaptureSession(_ request: CaptureCreateRequest, idempotencyKey: String?) async throws -> CaptureSession {
        record(.create)
        try await createGate?()
        return session()
    }
    func captureSession(id: UUID) async throws -> CaptureSession {
        record(.get)
        try await getGate?()
        if let getError { throw getError }
        return session()
    }
    func deleteCaptureSession(id: UUID) async throws {
        record(.delete)
        if let deleteError { throw deleteError }
    }
    func postCaptureTurns(sessionId: UUID, _ request: CaptureTurnsRequest, idempotencyKey: String) async throws -> CaptureTurnsResponse {
        record(.turns(request, key: idempotencyKey))
        try await turnsGate?()
        return try turnsHandler(request)
    }
    func postCaptureOutcome(sessionId: UUID, questionId: UUID, _ request: CaptureOutcomeRequest, idempotencyKey: String) async throws -> CaptureOutcomeResponse {
        record(.outcome(questionId, request, key: idempotencyKey))
        return CaptureOutcomeResponse(questionId: questionId, topicKey: "t", outcome: try outcomeHandler(questionId, request))
    }
    func postCaptureCommand(sessionId: UUID, _ request: CaptureCommandRequest, idempotencyKey: String) async throws -> CaptureSession {
        record(.command(request.command, key: idempotencyKey)); return session()
    }
    func finishCapture(sessionId: UUID, _ request: CaptureFinishRequest, idempotencyKey: String) async throws -> CaptureFinishResponse {
        record(.finish(key: idempotencyKey))
        try await finishGate?()
        return CaptureFinishResponse(questions: finishQuestions, session: session(status: .wrappingUp, wrapup: finishQuestions))
    }
    func generateCaptureDraft(sessionId: UUID, idempotencyKey: String) async throws -> ExtractionJob {
        record(.generate(key: idempotencyKey)); return try generateHandler()
    }
    func extractionJob(id: UUID) async throws -> ExtractionJob {
        record(.job(id))
        try await jobGate?()
        return try jobHandler(id)
    }

    var turns: [CaptureTurnsRequest] { calls.compactMap { if case .turns(let r, _) = $0 { r } else { nil } } }
    var turnKeys: [String] { calls.compactMap { if case .turns(_, let k) = $0 { k } else { nil } } }
    var outcomes: [CaptureOutcomeRequest] { calls.compactMap { if case .outcome(_, let r, _) = $0 { r } else { nil } } }
    var commands: [CaptureCommand] { calls.compactMap { if case .command(let c, _) = $0 { c } else { nil } } }
    var spokenWords: [String] { turns.flatMap { $0.segments.map(\.text) } }
}

/// One timeline driving several tickers (the voice session and the coordinator each own one).
@MainActor
final class TestTimeline {
    var nowMs: Int64 = 1_000_000
    private(set) var clocks: [TimelineClock] = []

    func makeClock() -> TimelineClock {
        let clock = TimelineClock(timeline: self)
        clocks.append(clock)
        return clock
    }

    func advance(byMs delta: Int64) {
        var remaining = delta
        while remaining > 0 {
            let step = min(250, remaining)
            nowMs += step
            remaining -= step
            for clock in clocks { clock.tick?() }
        }
    }
}

@MainActor
final class TimelineClock: VoiceClock {
    private unowned let timeline: TestTimeline
    private(set) var tick: (@MainActor () -> Void)?

    init(timeline: TestTimeline) { self.timeline = timeline }

    var nowMs: Int64 { timeline.nowMs }
    func startTicking(everyMs interval: Int64, _ tick: @escaping @MainActor () -> Void) { self.tick = tick }
    func stopTicking() { tick = nil }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// True the first time only.
    func setOnce() -> Bool { lock.withLock { defer { set = true }; return !set } }
    var isSet: Bool { lock.withLock { set } }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ count: Int) { remaining = count }
    /// True while the count lasts.
    func take() -> Bool { lock.withLock { guard remaining > 0 else { return false }; remaining -= 1; return true } }
}
