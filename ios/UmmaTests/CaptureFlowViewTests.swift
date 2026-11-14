import Foundation
import XCTest
@testable import Umma

/// Brief 014: the capture flow's teardown rules and the Profile resume row.
@MainActor
final class CaptureFlowViewTests: XCTestCase {
    func testOnlyLiveMicPhasesAreStoppedOnBackground() {
        XCTAssertTrue(CaptureFlowView.micMayBeOn(.recording))
        XCTAssertTrue(CaptureFlowView.micMayBeOn(.wrappingUp))
        XCTAssertTrue(CaptureFlowView.micMayBeOn(.finishing))
        XCTAssertFalse(CaptureFlowView.micMayBeOn(.readyToGenerate))
        XCTAssertTrue(CaptureFlowView.micMayBeOn(.voiceStopped("Recording stopped.")))
    }

    func testResumeRowSaysWhatIsLeft() {
        var record = CaptureJournalRecord(sessionId: UUID(), userId: nil, titleHint: nil, startedAt: Date())
        record.lines = [.init(id: 1, tMs: 0, text: "pork belly", questionId: nil)]
        XCTAssertEqual(CaptureResumeRow(record: record) {}.subtitleForTests, "Not finished · 1 line heard. Tap to continue.")
        record.stage = .wrappingUp
        XCTAssertEqual(CaptureResumeRow(record: record) {}.subtitleForTests, "Recorded · 1 line heard. Tap to make the recipe.")
        record.discardPending = true
        XCTAssertTrue(CaptureResumeRow(record: record) {}.subtitleForTests.hasPrefix("Discard pending"))
    }
}
