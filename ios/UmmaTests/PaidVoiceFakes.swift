import Foundation
@testable import Umma

/// In-memory voice socket: tests push server messages and read what the phone sent.
final class FakeVoiceSocket: VoiceSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [Result<VoiceSocketMessage, Error>] = []
    private var waiters: [CheckedContinuation<VoiceSocketMessage, Error>] = []
    private var _sent: [VoiceSocketMessage] = []
    private var _closed = false

    var sent: [VoiceSocketMessage] { lock.withLock { _sent } }
    var sentText: [String] { sent.compactMap { if case .text(let t) = $0 { t } else { nil } } }
    var sentAudio: [Data] { sent.compactMap { if case .data(let d) = $0 { d } else { nil } } }
    var isClosed: Bool { lock.withLock { _closed } }

    func push(_ json: String) { deliver(.success(.text(json))) }

    /// The connection drops.
    func fail() { deliver(.failure(URLError(.networkConnectionLost))) }

    func send(_ message: VoiceSocketMessage) async throws {
        try lock.withLock {
            if _closed { throw URLError(.cancelled) }
            _sent.append(message)
        }
    }

    func receive() async throws -> VoiceSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            let next: Result<VoiceSocketMessage, Error>? = lock.withLock {
                if !inbound.isEmpty { return inbound.removeFirst() }
                if _closed { return .failure(URLError(.cancelled)) }
                waiters.append(continuation)
                return nil
            }
            if let next { continuation.resume(with: next) }
        }
    }

    func close() {
        let pending = lock.withLock { () -> [CheckedContinuation<VoiceSocketMessage, Error>] in
            _closed = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }

    private func deliver(_ result: Result<VoiceSocketMessage, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<VoiceSocketMessage, Error>? in
            if waiters.isEmpty {
                inbound.append(result)
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume(with: result)
    }
}

/// Scripted backend: one socket per `openStream`, and a scripted `/speak` per call.
final class FakePaidVoiceServer: PaidVoiceServer, @unchecked Sendable {
    private let lock = NSLock()
    let socket = FakeVoiceSocket()
    var openError: Error?
    var speakError: Error?
    /// Chunks the next line streams; `holdLine` keeps the stream open until `finishLine()`.
    var lineChunks: [Data] = [Data(repeating: 1, count: 4800)]
    var holdLine = false
    private var lineContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var spoken: [String] = []
    private(set) var lineCancelled = false

    /// The socket says `ready` as soon as it opens unless this is false.
    var sendsReady = true
    /// When set, the next `openStream` waits for `releaseOpen()` and then throws this.
    var heldOpenError: Error?
    private var openWaiter: CheckedContinuation<Void, Never>?
    var isOpenHeld: Bool { lock.withLock { openWaiter != nil } }

    func releaseOpen() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { openWaiter = nil }
            return openWaiter
        }
        waiter?.resume()
    }

    func openStream() async throws -> any VoiceSocket {
        let held = lock.withLock { () -> Error? in
            defer { heldOpenError = nil }
            return heldOpenError
        }
        if let held {
            await withCheckedContinuation { continuation in
                lock.withLock { openWaiter = continuation }
            }
            throw held
        }
        if let openError { throw openError }
        if sendsReady { socket.push(#"{"type":"ready","sample_rate":16000}"#) }
        return socket
    }

    func speak(_ text: String) async throws -> PaidSpeechAudio {
        lock.withLock { spoken.append(text) }
        if let speakError { throw speakError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.lock.withLock { self?.lineCancelled = true } }
        }
        lineChunks.forEach { continuation.yield($0) }
        if holdLine {
            lock.withLock { lineContinuation = continuation }
        } else {
            continuation.finish()
        }
        return PaidSpeechAudio(sampleRate: 24_000, chunks: stream)
    }

    func finishLine() {
        lock.withLock { lineContinuation }?.finish()
    }
}

/// The phone audio, minus hardware: tests drive gate outputs and voice activity by hand.
@MainActor
final class FakePaidVoiceAudio: PaidVoiceAudio {
    var isAvailable = true
    var inputLabel = "iPhone mic"
    var startError: Error?
    /// Transport ms = audio ms + this (one span starting at `offsetMs`).
    var offsetMs: Int64 = 0
    var openSpanAudioMs: Int64?
    var audioSentMs: Int64 = 0
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var stopCount = 0
    private(set) var flushCount = 0
    private(set) var played: [Data] = []
    private(set) var lineRates: [Double] = []
    private var onOutput: (@Sendable (PaidSpeechGate.Output) -> Void)?
    private var onEvent: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
    private var pendingLine: CheckedContinuation<Void, Never>?
    /// When true, `finishLine` waits for `flushPlayback()` or `endLine()`.
    var holdsPlayback = false

    func start(onOutput: @escaping @Sendable (PaidSpeechGate.Output) -> Void,
               onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        if let startError { throw startError }
        self.onOutput = onOutput
        self.onEvent = onEvent
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
        endLine()
    }

    func setPaused(_ paused: Bool) { isPaused = paused }

    func transportMs(forAudioMs audioMs: Int64) -> Int64 { audioMs + offsetMs }

    func beginLine(sampleRate: Double) { lineRates.append(sampleRate) }

    func enqueue(_ pcm: Data) { played.append(pcm) }

    func finishLine() async {
        guard holdsPlayback else { return }
        await withCheckedContinuation { pendingLine = $0 }
    }

    func flushPlayback() {
        flushCount += 1
        endLine()
    }

    func endLine() {
        let pending = pendingLine
        pendingLine = nil
        pending?.resume()
    }

    var isLineWaiting: Bool { pendingLine != nil }

    func emit(_ output: PaidSpeechGate.Output) { onOutput?(output) }

    func emit(_ event: VoiceTransportEvent) { onEvent?(event) }
}
