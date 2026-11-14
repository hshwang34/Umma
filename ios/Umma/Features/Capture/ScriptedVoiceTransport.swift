#if DEBUG
import Foundation

/// DEBUG only: a `VoiceTransport` that "hears" a scripted cook, so the capture walkthrough
/// (`UmmaSmokeTests.testCaptureRecordWalkthrough`) runs on the simulator, which has no recognizer.
/// Enabled with the launch argument `-capture.script kimchi`; never compiled into release builds.
///
/// It plays its lines with real pauses, answers each question Umma speaks after a short delay
/// (so the question card can be seen), and holds still while paused.
@MainActor
final class ScriptedVoiceTransport: VoiceTransport {
    enum Step {
        case say(String)
        case wait(milliseconds: Int)
        /// Wait until Umma's intro line has been spoken (words said over it would be dropped).
        case waitForIntro
        /// Wait for Umma's next question, then answer it after `afterMs`.
        case answerNextQuestion(String, afterMs: Int)
    }

    let tier: VoiceTier = .free
    let isAvailable = true
    let inputLabel = "Demo script (no mic)"
    let notice: String? = "Demo: a scripted cook stands in for the microphone."

    private var steps: [Step]
    /// Answers for questions after the script ends (the wrap-up), then "skip".
    private var laterAnswers: [String]
    private var handler: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
    private var runner: Task<Void, Never>?
    private var paused = false
    private var spokenCount = 0
    private var questionsHeard = 0
    private var speaking: Task<Void, Never>?
    private var isSpeaking = false

    init(steps: [Step], laterAnswers: [String]) {
        self.steps = steps
        self.laterAnswers = laterAnswers
    }

    static func named(_ name: String) -> ScriptedVoiceTransport? {
        switch name {
        case "kimchi": .kimchiJjigae
        default: nil
        }
    }

    /// "Mum's Kimchi Jjigae": every amount is said (in digits, which the mock rules read) but the
    /// simmer time isn't, so Umma asks. She skips the servings question in the wrap-up, so the
    /// draft shows servings as "needs review".
    static var kimchiJjigae: ScriptedVoiceTransport {
        ScriptedVoiceTransport(steps: [
            .waitForIntro,
            .say("First 300 grams of pork belly goes in, no oil."),
            .wait(milliseconds: 3000),
            .say("Now 2 cups of kimchi, the old sour one, and 1 spoon of gochugaru."),
            .wait(milliseconds: 3000),
            .say("Pour in 2 cups of anchovy stock and let it simmer."),
            .answerNextQuestion("About fifteen minutes, until the kimchi goes soft.", afterMs: 5000),
            .wait(milliseconds: 9000),
            .say("Add 1 block of tofu and 2 spring onions right at the end."),
        ], laterAnswers: [])
    }

    func start(onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        handler = onEvent
        paused = false
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.play() }
    }

    func stop() {
        handler = nil
        stopSpeaking()
    }

    func setInputPaused(_ paused: Bool) { self.paused = paused }
    func flushHypothesis() {}

    func speak(_ text: String) async {
        spokenCount += 1
        // The first line is Umma's intro; every later one is a question.
        if spokenCount > 1 { questionsHeard += 1 }
        let duration = max(1200, text.split(separator: " ").count * 300)
        let task = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(duration)) }
        speaking = task
        isSpeaking = true
        await task.value
        isSpeaking = false
        if spokenCount > 1, steps.isEmpty { answerLater() }
    }

    func stopSpeaking() {
        speaking?.cancel()
    }

    // MARK: - Script

    private func play() async {
        var answered = 0
        while !steps.isEmpty, !Task.isCancelled {
            let step = steps.removeFirst()
            switch step {
            case .say(let text):
                await hear(text)
            case .wait(let ms):
                await sleepWhileRunning(ms)
            case .waitForIntro:
                while spokenCount == 0 || isSpeaking, !Task.isCancelled { await sleepWhileRunning(250) }
                await sleepWhileRunning(1000)
            case .answerNextQuestion(let text, let delay):
                while questionsHeard <= answered, !Task.isCancelled { await sleepWhileRunning(250) }
                answered += 1
                await sleepWhileRunning(delay)
                await hear(text)
            }
        }
    }

    /// After the script: wrap-up answers, then "skip".
    private func answerLater() {
        let text = laterAnswers.isEmpty ? "skip" : laterAnswers.removeFirst()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.hear(text)
        }
    }

    private func hear(_ text: String) async {
        while paused || handler == nil { try? await Task.sleep(for: .milliseconds(250)) }
        let words = text.split(separator: " ")
        handler?(.transcript(text: words.prefix(max(1, words.count / 2)).joined(separator: " "), isFinal: false))
        try? await Task.sleep(for: .milliseconds(900))
        handler?(.transcript(text: text, isFinal: true))
    }

    private func sleepWhileRunning(_ ms: Int) async {
        var left = ms
        while left > 0 {
            try? await Task.sleep(for: .milliseconds(250))
            if !paused { left -= 250 }
        }
    }
}
#endif
