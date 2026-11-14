import Foundation
import XCTest
@testable import Umma

/// Brief 014 entry and recording screen, asserted through their presentation structs.
@MainActor
final class CaptureScreensTests: XCTestCase {
    private func ask(_ phase: CapturePhase = .live) -> CaptureAsk {
        CaptureAsk(questionId: UUID(), text: "How long do you let it simmer?", topicKey: "simmer_time",
                   topic: "time", phase: phase, expiresAtMs: phase == .live ? 80_000 : nil)
    }

    func testChooserOffersThreeOptionsWithCameraComingSoon() {
        let options = NewRecipeOption.all
        XCTAssertEqual(options.map(\.title), ["Record while cooking", "Record with camera", "Type it in"])
        let camera = options[1]
        XCTAssertFalse(camera.isEnabled)
        XCTAssertEqual(camera.badge, "Coming soon")
        XCTAssertTrue(camera.detail.hasPrefix("Planned"))
        XCTAssertTrue(camera.accessibilityLabel.contains("Coming soon"))
        XCTAssertTrue(options[0].isEnabled && options[2].isEnabled)
    }

    func testCaptureFlagIsOffUntilSet() {
        let defaults = UserDefaults(suiteName: "capture.flag.\(UUID().uuidString)")!
        XCTAssertFalse(CaptureFeature.isEnabled(defaults))
        defaults.set("YES", forKey: CaptureFeature.flagKey)
        XCTAssertTrue(CaptureFeature.isEnabled(defaults), "a launch argument arrives as a string")
    }

    func testBeforeStartNothingIsLiveAndTheScreenMaySleep() {
        let p = RecordPresentation(phase: .idle, question: nil, heard: [], elapsedMs: 0, askingStopped: false, isRetrying: false)
        XCTAssertEqual(p.title, "Record while cooking")
        XCTAssertTrue(p.statusLine.contains("only after you tap Start"))
        XCTAssertFalse(p.showsVoiceBar)
        XCTAssertFalse(p.showsDone)
        XCTAssertFalse(p.keepsScreenAwake)
        XCTAssertNil(p.heardCountText)
    }

    func testRecordingShowsTimerControlsAndKeepsTheScreenAwake() {
        let heard = (1...6).map { "line \($0)" }
        let p = RecordPresentation(phase: .recording, question: nil, heard: heard, elapsedMs: 754_400, askingStopped: false, isRetrying: false)
        XCTAssertEqual(p.elapsedText, "12:34")
        XCTAssertEqual(p.elapsedAccessibility, "Recording time 12 minutes 34 seconds")
        XCTAssertTrue(p.showsVoiceBar)
        XCTAssertTrue(p.showsDone)
        XCTAssertEqual(p.pauseToggleTitle, "Pause")
        XCTAssertTrue(p.keepsScreenAwake)
        XCTAssertTrue(p.showsStopAsking)
        XCTAssertEqual(p.heardLines, ["line 3", "line 4", "line 5", "line 6"], "a quiet list: the newest few")
        XCTAssertEqual(p.heardCountText, "Heard so far · 6 lines")
    }

    func testLongCookFormatsHours() {
        let p = RecordPresentation(phase: .recording, question: nil, heard: [], elapsedMs: 3_725_000, askingStopped: false, isRetrying: false)
        XCTAssertEqual(p.elapsedText, "1:02:05")
    }

    func testPausedOffersResumeAndSaysItIsNotListening() {
        let p = RecordPresentation(phase: .paused, question: nil, heard: [], elapsedMs: 1000, askingStopped: false, isRetrying: false)
        XCTAssertEqual(p.pauseToggleTitle, "Resume")
        XCTAssertEqual(p.pauseToggleSymbol, "play.fill")
        XCTAssertEqual(p.statusLine, "Paused. Umma isn’t listening.")
        XCTAssertFalse(p.showsStopAsking)
        XCTAssertFalse(p.keepsScreenAwake, "the mic is off, so the screen may sleep")
    }

    func testScreenStaysAwakeOnlyWhileCaptureIsLive() {
        let phases: [(CaptureCoordinator.Phase, Bool)] = [
            (.idle, false), (.starting, false), (.recording, true), (.paused, false),
            (.voiceStopped("Recording stopped."), false), (.finishing, false), (.wrappingUp, true),
            (.readyToGenerate, false), (.failed("No."), false),
        ]
        for (phase, awake) in phases {
            let p = RecordPresentation(phase: phase, question: nil, heard: [], elapsedMs: 0, askingStopped: false, isRetrying: false, wrapUp: (0, 0))
            XCTAssertEqual(p.keepsScreenAwake, awake, "\(phase)")
        }
    }

    func testQuestionCardFollowsTheAskStages() {
        var card = CaptureCoordinator.QuestionCard(ask: ask(), stage: .speaking)
        var p = RecordPresentation(phase: .recording, question: card, heard: [], elapsedMs: 0, askingStopped: false, isRetrying: false)
        XCTAssertEqual(p.card?.eyebrow, "Umma asks")
        XCTAssertEqual(p.card?.question, "How long do you let it simmer?")
        XCTAssertEqual(p.card?.status, "Umma is asking…")
        XCTAssertEqual(p.card?.deferTitle, "Ask me later")
        card.stage = .listening
        p = RecordPresentation(phase: .recording, question: card, heard: [], elapsedMs: 0, askingStopped: false, isRetrying: false)
        XCTAssertTrue(p.card?.status.contains("skip") == true)
        XCTAssertNil(p.card?.answer)
        card.answer = "About fifteen minutes"
        p = RecordPresentation(phase: .recording, question: card, heard: [], elapsedMs: 0, askingStopped: false, isRetrying: false)
        XCTAssertEqual(p.card?.answer, "About fifteen minutes")
    }

    func testWrapUpCardCountsQuestions() {
        let card = CaptureCoordinator.QuestionCard(ask: ask(.wrapup), stage: .listening)
        let p = RecordPresentation(phase: .wrappingUp, question: card, heard: [], elapsedMs: 0, askingStopped: false,
                                   isRetrying: false, wrapUp: (1, 3))
        XCTAssertEqual(p.title, "A few last questions")
        XCTAssertEqual(p.card?.eyebrow, "Question 2 of 3")
        XCTAssertEqual(p.card?.deferTitle, "Leave it")
        XCTAssertFalse(p.showsDone)
        XCTAssertFalse(p.showsStopAsking)
        XCTAssertTrue(p.keepsScreenAwake)
    }

    func testStopAskingAndOfflineAreSaidPlainly() {
        let p = RecordPresentation(phase: .recording, question: nil, heard: [], elapsedMs: 0, askingStopped: true, isRetrying: true)
        XCTAssertFalse(p.showsStopAsking)
        XCTAssertTrue(p.statusLine.contains("No more questions"))
        XCTAssertTrue(p.notice?.contains("saved on this phone") == true)
    }

    func testRecordingVoiceBarHidesItsOwnControlsButNamesTheMic() {
        let bar = VoiceBarPresentation(state: .listening, userCaptions: [], assistantCaptions: [], partial: nil,
                                       inputLabel: "iPhone mic", notice: nil, showsControls: false)
        XCTAssertFalse(bar.showsPauseToggle)
        XCTAssertFalse(bar.showsStop)
        XCTAssertEqual(bar.input?.text, "Mic: iPhone mic")
    }

    func testOpenQuestionShowsOnceOnTheCardNotAlsoInCaptions() {
        let question = VoiceSegment(id: 2, speaker: .assistant, text: "How long do you let it simmer?", startMs: 5000, endMs: 6000, isFinal: true)
        let intro = VoiceSegment(id: 1, speaker: .assistant, text: "I'm listening.", startMs: 0, endMs: 900, isFinal: true)
        XCTAssertEqual(RecordPresentation.assistantCaptions([intro, question], hidingQuestion: question.text), [intro])
        XCTAssertEqual(RecordPresentation.assistantCaptions([intro, question], hidingQuestion: nil), [intro, question],
                       "once answered or closed it joins the captions")
    }
}
