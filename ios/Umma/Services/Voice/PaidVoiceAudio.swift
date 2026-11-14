import AVFoundation
import Foundation
import os

/// Decides which mic audio goes to the server (only while someone speaks) and maps the server's
/// audio clock back to the transport clock. Pure, so it is tested without audio hardware.
///
/// - Voice activity (`VoiceActivityDetector`) opens a span; the last `preRollMs` before the onset
///   go first, so the first syllable isn't clipped. The span closes when activity ends.
/// - Audio is batched into `batchMs` chunks (fewer socket messages) and flushed at span end.
/// - The server stamps transcripts in milliseconds of audio *received*, which skips every
///   silence; `transportMs(forAudioMs:)` turns that back into transport time using each span's
///   anchor.
struct PaidSpeechGate: Sendable {
    struct Config: Sendable, Equatable {
        var preRollMs: Int64 = 300
        var batchMs: Int64 = 100
    }

    enum Output: Sendable, Equatable {
        case audio(Data)
        /// A speech span ended: the server should finalize its transcript now.
        case spanEnded
    }

    static let bytesPerMs = 32  // 16 kHz s16le mono

    let config: Config
    private var detector: VoiceActivityDetector
    private var preRoll: [(data: Data, atMs: Int64)] = []
    private var pending = Data()
    private(set) var isOpen = false
    /// Audio handed to the server so far, in ms.
    private(set) var audioSentMs: Int64 = 0
    /// Server audio clock (ms received) where the open span's audio starts; nil when closed.
    private(set) var spanStartAudioMs: Int64?
    private var anchors: [(audioMs: Int64, atMs: Int64)] = []

    init(config: Config = .init(), detector: VoiceActivityDetector = .init()) {
        self.config = config
        self.detector = detector
    }

    /// One mic frame (16 kHz s16le) starting at transport time `atMs`. Returns the activity
    /// change, if any, and what to send.
    mutating func process(_ frame: Data, levelDb: Float, atMs: Int64) -> (activity: Bool?, outputs: [Output]) {
        let activity = detector.process(levelDb: levelDb, atMs: atMs)
        var outputs: [Output] = []
        if !isOpen, activity == true {
            isOpen = true
            let start = preRoll.first?.atMs ?? atMs
            let audioStart = audioSentMs + Int64(pending.count / Self.bytesPerMs)
            spanStartAudioMs = audioStart
            anchors.append((audioStart, start))
            if anchors.count > 256 { anchors.removeFirst(anchors.count - 256) }
            for piece in preRoll { append(piece.data, to: &outputs) }
            preRoll = []
        }
        if isOpen {
            append(frame, to: &outputs)
            if activity == false {
                flush(to: &outputs)
                outputs.append(.spanEnded)
                isOpen = false
                spanStartAudioMs = nil
            }
        } else {
            preRoll.append((frame, atMs))
            while let first = preRoll.first, atMs - first.atMs > config.preRollMs {
                preRoll.removeFirst()
            }
        }
        return (activity, outputs)
    }

    /// Closes an open span (pause, stop): what's pending goes out and the server finalizes.
    mutating func close() -> [Output] {
        var outputs: [Output] = []
        preRoll = []
        guard isOpen else { return outputs }
        flush(to: &outputs)
        outputs.append(.spanEnded)
        isOpen = false
        spanStartAudioMs = nil
        return outputs
    }

    func transportMs(forAudioMs audioMs: Int64) -> Int64 {
        guard let anchor = anchors.last(where: { $0.audioMs <= audioMs }) ?? anchors.first else { return audioMs }
        return anchor.atMs + max(0, audioMs - anchor.audioMs)
    }

    private mutating func append(_ data: Data, to outputs: inout [Output]) {
        pending.append(data)
        if Int64(pending.count) >= config.batchMs * Int64(Self.bytesPerMs) { flush(to: &outputs) }
    }

    private mutating func flush(to outputs: inout [Output]) {
        guard !pending.isEmpty else { return }
        audioSentMs += Int64(pending.count / Self.bytesPerMs)
        outputs.append(.audio(pending))
        pending = Data()
    }
}

/// The phone side of Paid voice: echo-cancelled mic in, server voice out, on one engine.
@MainActor
protocol PaidVoiceAudio: AnyObject {
    var isAvailable: Bool { get }
    /// The honest input name ("iPhone mic", "Bluetooth mic (…)"); never "glasses" here.
    var inputLabel: String { get }
    /// Starts the mic and player. `onOutput` runs on the audio thread; `onEvent` (voice
    /// activity, route, interruption, failure) on the main actor.
    func start(onOutput: @escaping @Sendable (PaidSpeechGate.Output) -> Void,
               onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws
    func stop()
    func setPaused(_ paused: Bool)
    func transportMs(forAudioMs: Int64) -> Int64
    /// Server audio clock where the open speech span started (nil when closed), so a flush
    /// keeps the words of a barge-in that is still going.
    var openSpanAudioMs: Int64? { get }
    var audioSentMs: Int64 { get }
    /// Plays one line: schedule chunks, then wait for the end (or a flush).
    func beginLine(sampleRate: Double)
    func enqueue(_ pcm: Data)
    func finishLine() async
    func flushPlayback()
}

/// `AVAudioEngine` with iOS voice processing: the server voice plays through the engine, so
/// echo cancellation removes it from the mic and barge-in hears only the cook.
@MainActor
final class EnginePaidVoiceAudio: PaidVoiceAudio {
    let isAvailable: Bool
    private(set) var inputLabel = VoiceInputLabel.builtIn

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tap = PaidMicTap()
    private var playFormat: AVAudioFormat?
    private var lineGeneration = 0
    private var scheduled = 0
    private var lineEnded = false
    private var pendingLine: CheckedContinuation<Void, Never>?
    private var onEvent: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
    private var isRunning = false
    /// Input paused by the session, or taken by an interruption (a call, Siri). Either way the
    /// mic stays off until `setPaused(false)`; an interruption never ends on its own (privacy).
    private var isInputPaused = false
    private var isInterrupted = false
    private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private let observers = NotificationObserverBag()
    private let logger = Logger(subsystem: "com.umma.ios", category: "voice")

    init() {
        #if targetEnvironment(simulator)
        isAvailable = false
        #else
        isAvailable = true
        #endif
        observeAudioSession()
    }

    var openSpanAudioMs: Int64? { tap.openSpanAudioMs }
    var audioSentMs: Int64 { tap.audioSentMs }

    func transportMs(forAudioMs audioMs: Int64) -> Int64 { tap.transportMs(forAudioMs: audioMs) }

    func start(onOutput: @escaping @Sendable (PaidSpeechGate.Output) -> Void,
               onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        guard isAvailable else { throw CaptureError.unavailable(.phone, reason: "Server voice needs a real iPhone.") }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CaptureError.permissionDenied(
                permission: "Microphone",
                explainer: "Voice mode listens only while it's on, and you can see it on screen. Allow microphone access in Settings → Umma."
            )
        }
        self.onEvent = onEvent
        do {
            let session = AVAudioSession.sharedInstance()
            previousAudio = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try engine.inputNode.setVoiceProcessingEnabled(true)
            if player.engine == nil { engine.attach(player) }
            tap.reset(originSeconds: VoiceInputTap.nowSeconds(), output: onOutput, activity: makeActivitySink())
            installTap()
            engine.prepare()
            try engine.start()
        } catch {
            logger.error("paid voice audio start failed: \(error.localizedDescription, privacy: .public)")
            stop()
            throw error
        }
        isRunning = true
        isInputPaused = false
        isInterrupted = false
        refreshInputLabel()
    }

    func stop() {
        isRunning = false
        isInputPaused = false
        isInterrupted = false
        flushPlayback()
        tap.close()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previous = previousAudio {
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        previousAudio = nil
        onEvent = nil
    }

    func setPaused(_ paused: Bool) {
        guard isRunning else { return }
        isInputPaused = paused
        // Resuming by hand is the only way back from an interruption; this restarts the engine
        // (and picks up any configuration change skipped while the mic was off).
        if !paused { isInterrupted = false }
        tap.setPaused(paused)
        if paused {
            engine.pause()
        } else {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                installTap()
                try engine.start()
            } catch {
                onEvent?(.failed("The microphone could not restart."))
            }
            refreshInputLabel()
        }
    }

    // MARK: - Playback

    func beginLine(sampleRate: Double) {
        flushPlayback()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        if playFormat != format {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playFormat = format
        }
        lineGeneration += 1
        scheduled = 0
        lineEnded = false
    }

    func enqueue(_ pcm: Data) {
        guard let format = playFormat, engine.isRunning,
              let buffer = Self.floatBuffer(pcm, format: format) else { return }
        let generation = lineGeneration
        scheduled += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(generation: generation) }
        }
        if !player.isPlaying { player.play() }
    }

    func finishLine() async {
        lineEnded = true
        guard scheduled > 0 else { return }
        await withCheckedContinuation { pendingLine = $0 }
    }

    func flushPlayback() {
        lineGeneration += 1
        scheduled = 0
        player.stop()
        let pending = pendingLine
        pendingLine = nil
        pending?.resume()
    }

    private func played(generation: Int) {
        guard generation == lineGeneration else { return }
        scheduled -= 1
        guard scheduled <= 0, lineEnded, let pending = pendingLine else { return }
        pendingLine = nil
        pending.resume()
    }

    // MARK: - Plumbing

    private func installTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        tap.prepareConverter(from: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(tap: tap))
    }

    private func makeActivitySink() -> @Sendable (Bool) -> Void {
        { [weak self] speaking in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.onEvent?(.voiceActivity(speaking))
            }
        }
    }

    private func refreshInputLabel() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        let label = VoiceInputLabel.label(portType: input?.portType, portName: input?.portName)
        guard label != inputLabel else { return }
        inputLabel = label
        if isRunning { onEvent?(.inputChanged(label: label)) }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if began { self.isInterrupted = true }
                self.onEvent?(.interruption(began: began))
            }
        })
        observers.add(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshInputLabel() }
        })
        observers.add(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Paused or interrupted: restarting now would bring the mic hardware back live.
                // `setPaused(false)` reinstalls the tap and starts the engine on resume instead.
                guard EnginePaidVoiceAudio.restartsOnConfigurationChange(isRunning: self.isRunning,
                                                                        isInputPaused: self.isInputPaused,
                                                                        isInterrupted: self.isInterrupted) else { return }
                self.installTap()
                do { try self.engine.start() } catch { self.onEvent?(.failed("The microphone changed and could not restart.")) }
            }
        })
    }

    /// Whether an engine configuration change restarts the mic now (see the observer above).
    nonisolated static func restartsOnConfigurationChange(isRunning: Bool, isInputPaused: Bool,
                                                          isInterrupted: Bool) -> Bool {
        isRunning && !isInputPaused && !isInterrupted
    }

    nonisolated private static func makeTapBlock(tap: PaidMicTap) -> AVAudioNodeTapBlock {
        { buffer, when in
            let seconds = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : VoiceInputTap.nowSeconds()
            tap.process(buffer, atSeconds: seconds)
        }
    }

    /// s16le mono → the player's Float32 format.
    nonisolated static func floatBuffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return nil }
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

/// Mic tap state shared with the audio thread: 16 kHz conversion, the speech gate and the
/// clock, under one lock. Audio is never kept beyond the gate's few hundred ms of pre-roll.
final class PaidMicTap: @unchecked Sendable {
    private struct State {
        var gate = PaidSpeechGate()
        var converter: AVAudioConverter?
        var paused = false
        var originSeconds: Double = 0
        var output: (@Sendable (PaidSpeechGate.Output) -> Void)?
        var activity: (@Sendable (Bool) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)

    var openSpanAudioMs: Int64? { state.withLockUnchecked { $0.gate.spanStartAudioMs } }
    var audioSentMs: Int64 { state.withLockUnchecked { $0.gate.audioSentMs } }

    func transportMs(forAudioMs audioMs: Int64) -> Int64 {
        state.withLockUnchecked { $0.gate.transportMs(forAudioMs: audioMs) }
    }

    func reset(originSeconds: Double, output: @escaping @Sendable (PaidSpeechGate.Output) -> Void,
               activity: @escaping @Sendable (Bool) -> Void) {
        state.withLockUnchecked {
            $0 = State()
            $0.originSeconds = originSeconds
            $0.output = output
            $0.activity = activity
        }
    }

    func prepareConverter(from format: AVAudioFormat) {
        guard let target = Self.target else { return }
        let converter = AVAudioConverter(from: format, to: target)
        state.withLockUnchecked { $0.converter = converter }
    }

    func setPaused(_ paused: Bool) {
        let (outputs, sink) = state.withLockUnchecked { state -> ([PaidSpeechGate.Output], (@Sendable (PaidSpeechGate.Output) -> Void)?) in
            state.paused = paused
            return (paused ? state.gate.close() : [], state.output)
        }
        outputs.forEach { sink?($0) }
    }

    func close() {
        let (outputs, sink) = state.withLockUnchecked { state -> ([PaidSpeechGate.Output], (@Sendable (PaidSpeechGate.Output) -> Void)?) in
            defer { state.output = nil; state.activity = nil }
            return (state.gate.close(), state.output)
        }
        outputs.forEach { sink?($0) }
    }

    /// Audio thread.
    func process(_ buffer: AVAudioPCMBuffer, atSeconds: Double) {
        let level = buffer.floatChannelData.map {
            VoiceActivityDetector.levelDb(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength)))
        } ?? -160
        let result = state.withLockUnchecked { state -> (Bool?, [PaidSpeechGate.Output], (@Sendable (PaidSpeechGate.Output) -> Void)?, (@Sendable (Bool) -> Void)?)? in
            guard !state.paused, let converter = state.converter, let frame = Self.convert(buffer, with: converter) else { return nil }
            let atMs = Int64((max(0, atSeconds - state.originSeconds) * 1000).rounded())
            let (activity, outputs) = state.gate.process(frame, levelDb: level, atMs: atMs)
            return (activity, outputs, state.output, state.activity)
        }
        guard let (activity, outputs, output, activitySink) = result else { return }
        outputs.forEach { output?($0) }
        if let activity { activitySink?(activity) }
    }

    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        guard let target else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        // The converter calls the block synchronously, inside `convert`.
        nonisolated(unsafe) let source = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            let first = supplied.withLock { done in
                defer { done = true }
                return !done
            }
            status.pointee = first ? .haveData : .noDataNow
            return first ? source : nil
        }
        guard error == nil, let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
