import Foundation

/// Brief 014 "New recipe" chooser: three ways in, one of them planned but not built yet.
struct NewRecipeOption: Identifiable, Equatable {
    enum Kind: String { case recordVoice, recordCamera, typeIn }

    let kind: Kind
    let title: String
    let detail: String
    let symbolName: String
    let isEnabled: Bool
    let badge: String?

    var id: String { kind.rawValue }
    var accessibilityIdentifier: String { "newRecipe.\(kind.rawValue)" }
    var accessibilityLabel: String {
        [title, badge, detail].compactMap { $0 }.joined(separator: ". ")
    }

    static let all: [NewRecipeOption] = [
        NewRecipeOption(kind: .recordVoice, title: "Record while cooking",
                        detail: "Cook and talk. Umma listens, asks the odd question at a pause, and writes the recipe for you to check.",
                        symbolName: "waveform", isEnabled: true, badge: nil),
        NewRecipeOption(kind: .recordCamera, title: "Record with camera",
                        detail: "Planned: film the cook so Umma can see the steps too.",
                        symbolName: "video", isEnabled: false, badge: "Coming soon"),
        NewRecipeOption(kind: .typeIn, title: "Type it in",
                        detail: "Write the title, ingredients and steps yourself.",
                        symbolName: "square.and.pencil", isEnabled: true, badge: nil),
    ]
}

extension RecordPresentation {
    /// Umma's lines minus the open question: while its card is up the question shows once, on
    /// the card; it joins the captions once answered or closed.
    static func assistantCaptions(_ captions: [VoiceSegment], hidingQuestion question: String?) -> [VoiceSegment] {
        guard let question else { return captions }
        return captions.filter { $0.text != question }
    }

    @MainActor
    static func voiceBar(_ session: VoiceSession, hidingQuestion question: String?) -> VoiceBarPresentation {
        VoiceBarPresentation(state: session.state,
                             userCaptions: session.userCaptions,
                             assistantCaptions: assistantCaptions(session.assistantCaptions, hidingQuestion: question),
                             partial: session.partial,
                             inputLabel: session.inputLabel,
                             notice: session.notice,
                             showsControls: false)
    }
}

/// What the recording screen shows for one moment of a `CaptureCoordinator`. Pure, so tests assert
/// the copy and controls without inspecting views.
struct RecordPresentation: Equatable {
    struct Card: Equatable {
        let eyebrow: String
        let question: String
        let status: String
        let answer: String?
        let showsDefer: Bool
        let deferTitle: String
    }

    let title: String
    let elapsedText: String
    let elapsedAccessibility: String
    /// Under the timer: what is happening, in plain words.
    let statusLine: String
    let card: Card?
    /// The newest few lines, oldest first.
    let heardLines: [String]
    let heardCountText: String?
    let notice: String?
    let showsVoiceBar: Bool
    let showsPauseToggle: Bool
    let pauseToggleTitle: String
    let pauseToggleSymbol: String
    let showsDone: Bool
    let isBusy: Bool
    let showsStopAsking: Bool
    /// Recording, paused or asking wrap-up questions: the screen must not sleep.
    let keepsScreenAwake: Bool

    init(phase: CaptureCoordinator.Phase,
         question: CaptureCoordinator.QuestionCard?,
         heard: [String],
         elapsedMs: Int64,
         askingStopped: Bool,
         isRetrying: Bool,
         wrapUp: (index: Int, count: Int) = (0, 0),
         heardLimit: Int = 4) {
        let seconds = max(0, elapsedMs / 1000)
        elapsedText = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let minutes = seconds / 60
        elapsedAccessibility = "Recording time \(minutes) minute\(minutes == 1 ? "" : "s") \(seconds % 60) second\(seconds % 60 == 1 ? "" : "s")"

        switch phase {
        case .idle: title = "Record while cooking"
        case .wrappingUp: title = "A few last questions"
        default: title = "Recording"
        }

        switch phase {
        case .idle: statusLine = "Umma listens only after you tap Start, and only on this screen."
        case .starting: statusLine = "Starting…"
        case .recording: statusLine = askingStopped ? "Listening. No more questions until you tap Done." : "Listening. Just cook and talk."
        case .paused: statusLine = "Paused. Umma isn’t listening."
        case .voiceStopped(let message): statusLine = message
        case .finishing: statusLine = "Saving the last of what you said…"
        case .wrappingUp: statusLine = "Answer, or say “skip”. Nothing is guessed."
        case .readyToGenerate: statusLine = "Recording saved."
        case .failed(let message): statusLine = message
        }

        if let question {
            let wrapup = question.ask.phase == .wrapup
            let eyebrow = wrapup && wrapUp.count > 0 ? "Question \(min(wrapUp.index + 1, wrapUp.count)) of \(wrapUp.count)" : "Umma asks"
            let status: String
            switch question.stage {
            case .waiting: status = "Waiting for a pause…"
            case .speaking: status = "Umma is asking…"
            case .listening: status = question.answer.isEmpty ? "Listening for your answer. Say “skip” to move on." : "Got it. Keep going or pause."
            }
            card = Card(eyebrow: eyebrow, question: question.ask.text, status: status,
                        answer: question.answer.isEmpty ? nil : question.answer,
                        showsDefer: true, deferTitle: wrapup ? "Leave it" : "Ask me later")
        } else {
            card = nil
        }

        heardLines = Array(heard.suffix(max(heardLimit, 0)))
        heardCountText = heard.isEmpty ? nil : "Heard so far · \(heard.count) line\(heard.count == 1 ? "" : "s")"
        notice = isRetrying ? "No connection. Your words are saved on this phone and will be sent when it’s back." : nil

        let live: Bool
        switch phase {
        case .recording, .paused, .voiceStopped: live = true
        default: live = false
        }
        showsVoiceBar = live || phase == .wrappingUp || phase == .starting
        showsPauseToggle = live
        let resumes = phase != .recording
        pauseToggleTitle = resumes ? "Resume" : "Pause"
        pauseToggleSymbol = resumes ? "play.fill" : "pause.fill"
        showsDone = live
        isBusy = phase == .starting || phase == .finishing
        showsStopAsking = phase == .recording && !askingStopped && question?.ask.phase != .wrapup
        // Awake only while capture is live: the mic is listening while recording and while a
        // wrap-up question is open. Paused, stopped, starting and finishing (Done pauses the mic
        // while the last words are sent) let the screen sleep.
        keepsScreenAwake = phase == .recording || phase == .wrappingUp
    }
}
