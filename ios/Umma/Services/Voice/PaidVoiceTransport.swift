import Foundation
import Observation
import os

/// Paid tier (brief 012 PR 2): server speech-to-text and turn detection (Deepgram, via our
/// backend) and Umma's server voice (ElevenLabs), with echo cancellation and voice activity on
/// the phone.
///
/// - Mic: the echo-cancelled tap sends audio only while someone speaks (`PaidSpeechGate`), and
///   asks the server to finalize when a span ends. Server transcripts are stamped on the server's
///   audio clock and mapped back onto this transport's clock.
/// - Voice: `/v1/voice/speak` audio plays on the same engine (the echo reference). Barge-in: voice
///   activity while Umma speaks cuts playback at once and cancels the stream; the words keep
///   flowing to the server, so what the cook said is heard.
/// - Fallback: a network failure, `ai_resting`, a Free entitlement or a missing server key
///   switches to the on-device transport for the rest of the session, with `notice` saying why.
///
/// Races: a start gate makes `stop()` during `start` win; a run generation drops socket
/// messages from an earlier run; a speech generation keeps a cut-off line from resuming.
@MainActor
@Observable
final class PaidVoiceTransport: VoiceTransport {
    nonisolated static let fallbackNotice = "Server voice isn't available, so voice runs on this iPhone."
    nonisolated static let offlineNotice = "No connection to Umma's server, so voice runs on this iPhone."
    nonisolated static let restingNotice = "AI is resting, so voice runs on this iPhone for now."
    /// `/speak` refusals that mean server voice is off for this session (not just this line).
    nonisolated static let fallbackCodes: Set<String> = [
        "VOICE_NOT_ENTITLED", "VOICE_UNAVAILABLE", "AI_RESTING", "UNAUTHORIZED",
    ]
    /// Whether a `/speak` refusal ends server voice for the session (the line is then said
    /// on-device): the codes above, and any 5xx, 401 or 403 that came without one of them
    /// (`HTTP_<status>`, e.g. a proxy's bare 502). Only line-level refusals skip a line.
    nonisolated static func endsServerVoice(code: String) -> Bool {
        if fallbackCodes.contains(code) { return true }
        guard code.hasPrefix("HTTP_"), let status = Int(code.dropFirst(5)) else { return false }
        return (500...599).contains(status) || status == 401 || status == 403
    }
    nonisolated static let stopGrace: Duration = .milliseconds(500)

    private(set) var tier: VoiceTier = .paid
    private(set) var notice: String?
    private(set) var usingFallback = false

    @ObservationIgnored private let server: any PaidVoiceServer
    @ObservationIgnored private let audio: any PaidVoiceAudio
    @ObservationIgnored private let fallback: any VoiceTransport
    @ObservationIgnored private let readyTimeout: Duration
    @ObservationIgnored private let keepaliveInterval: Duration
    @ObservationIgnored private var onEvent: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
    @ObservationIgnored private var socket: (any VoiceSocket)?
    @ObservationIgnored private var outgoing: AsyncStream<PaidSpeechGate.Output>.Continuation?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var startGate = CaptureStartGate()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isInputPaused = false
    @ObservationIgnored private var speakGeneration = 0
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isSpeaking = false
    /// Server-clock cut: transcripts for audio before this are dropped (`flushHypothesis`).
    @ObservationIgnored private var dropBeforeAudioMs: Int64 = 0
    @ObservationIgnored private var partial: (text: String, startMs: Int64, endMs: Int64)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.umma.ios", category: "voice")

    init(server: any PaidVoiceServer,
         audio: any PaidVoiceAudio,
         fallback: any VoiceTransport,
         readyTimeout: Duration = .seconds(5),
         keepaliveInterval: Duration = .seconds(20)) {
        self.server = server
        self.audio = audio
        self.fallback = fallback
        self.readyTimeout = readyTimeout
        self.keepaliveInterval = keepaliveInterval
    }

    var isAvailable: Bool { audio.isAvailable || fallback.isAvailable }
    var inputLabel: String { usingFallback ? fallback.inputLabel : audio.inputLabel }

    // MARK: - Lifecycle

    func start(onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        if isRunning || usingFallback { stop() }
        let token = startGate.begin()
        generation += 1
        self.onEvent = onEvent
        notice = nil
        tier = .paid
        usingFallback = false
        dropBeforeAudioMs = 0
        partial = nil
        guard audio.isAvailable else {
            try await startFallback(reason: Self.fallbackNotice, token: token)
            return
        }
        do {
            let socket = try await server.openStream()
            guard startGate.isCurrent(token) else {
                socket.close()
                throw CaptureError.cancelled
            }
            try await awaitReady(socket)
            guard startGate.isCurrent(token) else {
                socket.close()
                throw CaptureError.cancelled
            }
            self.socket = socket
            let (stream, continuation) = AsyncStream.makeStream(of: PaidSpeechGate.Output.self,
                                                                bufferingPolicy: .bufferingNewest(600))
            outgoing = continuation
            let run = generation
            try await audio.start(onOutput: { continuation.yield($0) },
                                  onEvent: { [weak self] event in self?.audioEvent(event, run: run) })
            guard startGate.isCurrent(token) else {
                teardownPaid()
                throw CaptureError.cancelled
            }
            isRunning = true
            isInputPaused = false
            startPumps(socket: socket, outgoing: stream, run: run)
        } catch let error as CaptureError {
            // A superseded start owns nothing now: a newer run may be live, so touch nothing.
            guard startGate.isCurrent(token) else { throw CaptureError.cancelled }
            teardownPaid()
            if case .permissionDenied = error { throw error }
            if case .cancelled = error { throw error }
            try await startFallback(reason: Self.fallbackNotice, token: token)
        } catch let PaidVoiceError.server(_, message) {
            guard startGate.isCurrent(token) else { throw CaptureError.cancelled }
            teardownPaid()
            try await startFallback(reason: message, token: token)
        } catch {
            guard startGate.isCurrent(token) else { throw CaptureError.cancelled }
            teardownPaid()
            try await startFallback(reason: Self.offlineNotice, token: token)
        }
    }

    func stop() {
        startGate.supersede()
        generation += 1
        // Tell the server first (it finalizes and settles), then close; never wait long.
        let closing = socket
        socket = nil
        if let closing {
            Task { await Self.sendStopThenClose(closing) }
        }
        teardownPaid()
        if usingFallback { fallback.stop() }
        isRunning = false
        onEvent = nil
    }

    func setInputPaused(_ paused: Bool) {
        if usingFallback { return fallback.setInputPaused(paused) }
        guard isRunning, paused != isInputPaused else { return }
        isInputPaused = paused
        audio.setPaused(paused)
    }

    func flushHypothesis() {
        if usingFallback { return fallback.flushHypothesis() }
        // A span still going (a barge-in) keeps its words; everything before it is dropped.
        dropBeforeAudioMs = audio.openSpanAudioMs ?? audio.audioSentMs
        partial = nil
    }

    func speak(_ text: String) async {
        if usingFallback { return await fallback.speak(text) }
        guard isRunning else { return }
        stopSpeaking()
        speakGeneration += 1
        let mine = speakGeneration
        isSpeaking = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.playLine(text, generation: mine)
        }
        speakTask = task
        await task.value
        if mine == speakGeneration {
            isSpeaking = false
            speakTask = nil
        }
    }

    func stopSpeaking() {
        if usingFallback { return fallback.stopSpeaking() }
        speakGeneration += 1
        isSpeaking = false
        speakTask?.cancel()
        speakTask = nil
        audio.flushPlayback()
    }

    // MARK: - Server voice

    private func playLine(_ text: String, generation mine: Int) async {
        let run = generation
        do {
            let line = try await server.speak(text)
            guard mine == speakGeneration, !usingFallback else { return }
            audio.beginLine(sampleRate: line.sampleRate)
            for try await chunk in line.chunks {
                guard mine == speakGeneration else { return }
                audio.enqueue(chunk)
            }
            guard mine == speakGeneration else { return }
            await audio.finishLine()
        } catch {
            guard mine == speakGeneration, !Task.isCancelled, !(error is CancellationError) else { return }
            if case let PaidVoiceError.server(code, message) = error {
                guard Self.endsServerVoice(code: code) else {
                    // A refusal of this line only (too long, too many this minute): skip it and
                    // stay on server voice. Its caption is already on screen.
                    logger.info("paid voice line skipped: \(code, privacy: .public)")
                    return
                }
                fallBack(reason: message)
            } else {
                fallBack(reason: Self.offlineNotice)
            }
            // Say the line anyway, in the on-device voice, once it is up (unless stopped since).
            await fallbackStarted?.value
            if run == generation, usingFallback { await fallback.speak(text) }
        }
    }

    // MARK: - Socket

    private func awaitReady(_ socket: any VoiceSocket) async throws {
        let timeout = readyTimeout
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { socket.close() }
        }
        defer { watchdog.cancel() }
        guard case .text(let text) = try await socket.receive(),
              let message = PaidVoiceServerMessage.parse(text) else { throw PaidVoiceError.unreachable }
        switch message {
        case .ready: return
        case .aiResting(let message): throw PaidVoiceError.server(code: "AI_RESTING", message: message)
        case let .error(code, message): throw PaidVoiceError.server(code: code, message: message)
        default: throw PaidVoiceError.unreachable
        }
    }

    private func startPumps(socket: any VoiceSocket, outgoing: AsyncStream<PaidSpeechGate.Output>, run: Int) {
        let sender = Task { [weak self] in
            for await output in outgoing {
                do {
                    switch output {
                    case .audio(let data): try await socket.send(.data(data))
                    case .spanEnded: try await socket.send(.text(PaidVoiceServerMessage.finalize))
                    }
                } catch {
                    self?.socketFailed(run: run)
                    return
                }
            }
        }
        let receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .text(let text) = message, let parsed = PaidVoiceServerMessage.parse(text) else { continue }
                    self?.handle(parsed, run: run)
                } catch {
                    self?.socketFailed(run: run)
                    return
                }
            }
        }
        let interval = keepaliveInterval
        let keepalive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                try? await socket.send(.text(PaidVoiceServerMessage.keepalive))
            }
        }
        tasks = [sender, receiver, keepalive]
    }

    private func handle(_ message: PaidVoiceServerMessage, run: Int) {
        guard run == generation, isRunning, !usingFallback else { return }
        switch message {
        case let .transcript(text, isFinal, startMs, endMs):
            guard endMs > dropBeforeAudioMs else { return }  // heard before the last flush
            let start = audio.transportMs(forAudioMs: startMs)
            let end = max(start, audio.transportMs(forAudioMs: endMs))
            if isFinal {
                partial = nil
            } else if !text.isEmpty {
                partial = (text, start, end)
            }
            post(.transcript(text: text, isFinal: isFinal, startMs: start, endMs: end))
        case .utteranceEnd:
            // Turn over with words still unconfirmed: close them as said.
            if let pending = partial {
                partial = nil
                post(.transcript(text: pending.text, isFinal: true, startMs: pending.startMs, endMs: pending.endMs))
            }
        case .aiResting(let message):
            fallBack(reason: message)
        case .error(_, let message):
            fallBack(reason: message)
        case .closed:
            fallBack(reason: Self.fallbackNotice)
        case .ready, .speechStarted:
            break  // voice activity comes from the phone's own detector
        }
    }

    private func socketFailed(run: Int) {
        guard run == generation, isRunning, !usingFallback else { return }
        fallBack(reason: Self.offlineNotice)
    }

    // MARK: - Audio events

    private func audioEvent(_ event: VoiceTransportEvent, run: Int) {
        guard run == generation, isRunning, !usingFallback else { return }
        if case .voiceActivity(true) = event, isSpeaking {
            // Barge-in: the cook talks over Umma. Cut the line now; their words go to the server.
            logger.info("paid voice barge-in")
            stopSpeaking()
        }
        post(event)
    }

    // MARK: - Fallback

    @ObservationIgnored private var fallbackStarted: Task<Void, Never>?

    /// Mid-session: drop the server path and carry on with on-device voice.
    private func fallBack(reason: String) {
        guard !usingFallback else { return }
        logger.info("paid voice fell back to on-device")
        // Words the server heard but never confirmed are kept as said (the server already
        // finalized what it had before an ai_resting or closed message).
        if let pending = partial {
            partial = nil
            post(.transcript(text: pending.text, isFinal: true, startMs: pending.startMs, endMs: pending.endMs))
        }
        let wasPaused = isInputPaused
        stopSpeaking()
        teardownPaid()
        usingFallback = true
        tier = .free
        notice = reason
        let run = generation
        fallbackStarted = Task { [weak self] in
            guard let self, let onEvent = self.onEvent else { return }
            guard self.fallback.isAvailable else {
                onEvent(.failed(reason))
                return
            }
            do {
                try await self.fallback.start(onEvent: onEvent)
                guard run == self.generation else { return }
                if wasPaused { self.fallback.setInputPaused(true) }
                onEvent(.inputChanged(label: self.fallback.inputLabel))
            } catch {
                guard run == self.generation else { return }
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    private func startFallback(reason: String, token: Int) async throws {
        guard fallback.isAvailable else {
            throw CaptureError.unavailable(.phone, reason: reason)
        }
        usingFallback = true
        tier = .free
        notice = reason
        guard let onEvent else { throw CaptureError.cancelled }
        try await fallback.start(onEvent: onEvent)
        guard startGate.isCurrent(token) else {
            fallback.stop()
            throw CaptureError.cancelled
        }
    }

    private func teardownPaid() {
        tasks.forEach { $0.cancel() }
        tasks = []
        outgoing?.finish()
        outgoing = nil
        speakGeneration += 1
        speakTask?.cancel()
        speakTask = nil
        isSpeaking = false
        socket?.close()
        socket = nil
        if isRunning || !usingFallback { audio.stop() }
        isRunning = false
    }

    nonisolated private static func sendStopThenClose(_ socket: any VoiceSocket) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await socket.send(.text(PaidVoiceServerMessage.stop)) }
            group.addTask { try? await Task.sleep(for: stopGrace) }
            await group.next()
            group.cancelAll()
        }
        socket.close()
    }

    private func post(_ event: VoiceTransportEvent) {
        onEvent?(event)
    }
}
