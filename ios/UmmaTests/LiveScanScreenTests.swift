import Foundation
import XCTest
@testable import Umma

/// Brief 016 PR 6: what the live scan screen shows, and the short review after Done.
@MainActor
final class LiveScanScreenTests: XCTestCase {
    private func shown(_ phase: LiveScanViewModel.Phase, cameraOn: Bool = false, seconds: Int = 120, demo: Bool = false,
                       message: String? = nil, denied: Bool = false, basket: Int = 0, canContinue: Bool = false,
                       canFinish: Bool = false) -> LiveScanScreenPresentation {
        LiveScanScreenPresentation(phase: phase, cameraOn: cameraOn, secondsRemaining: seconds, isDemo: demo, message: message,
                                   permissionDenied: denied, basketCount: basket, canContinue: canContinue, canFinish: canFinish)
    }

    // MARK: - Screen states

    func testScanningShowsTheLookingIndicatorAndCountdown() {
        let scanning = shown(.scanning, cameraOn: true, seconds: 105, basket: 3, canFinish: true)
        XCTAssertEqual(scanning.indicatorText, "Umma is looking")
        XCTAssertEqual(scanning.countdownText, "1:45 left")
        XCTAssertEqual(scanning.title, "Point at your ingredients")
        XCTAssertEqual(scanning.basketCountText, "3 items")
        XCTAssertFalse(scanning.isWarning)
        XCTAssertNil(scanning.continueTitle)
        XCTAssertNil(scanning.demoLabel)
        XCTAssertEqual(shown(.scanning, cameraOn: true, seconds: 9, basket: 1).countdownText, "0:09 left")
        XCTAssertEqual(shown(.scanning, basket: 1).basketCountText, "1 item")
    }

    func testIndicatorFollowsTheCameraNotThePhase() {
        XCTAssertNil(shown(.scanning, cameraOn: false).indicatorText, "never claims to look while the camera is off")
        XCTAssertNil(shown(.starting).indicatorText)
        XCTAssertNil(shown(.starting).countdownText)
        XCTAssertTrue(shown(.starting).isBusy)
        XCTAssertEqual(shown(.starting, cameraOn: true).indicatorText, "Umma is looking")
    }

    func testTimeUpOffersKeepScanningAndDone() {
        let timeUp = shown(.timeUp, basket: 4, canContinue: true, canFinish: true)
        XCTAssertNil(timeUp.indicatorText)
        XCTAssertNil(timeUp.countdownText)
        XCTAssertEqual(timeUp.title, "Two minutes are up")
        XCTAssertEqual(timeUp.continueTitle, "Keep scanning")
        XCTAssertTrue(timeUp.canFinish)
        XCTAssertFalse(timeUp.isWarning)
    }

    func testLimitReachedKeepsDoneButNotKeepScanning() {
        let limit = shown(.limitReached, message: LiveScanViewModel.limitMessage, basket: 2, canFinish: true)
        XCTAssertEqual(limit.title, "That’s all the live scanning for today")
        XCTAssertEqual(limit.message, LiveScanViewModel.limitMessage)
        XCTAssertTrue(limit.isWarning)
        XCTAssertNil(limit.continueTitle)
        XCTAssertFalse(limit.showsSettings)
    }

    func testInterruptedOffersKeepScanning() {
        let lost = shown(.interrupted, message: LiveScanViewModel.connectionMessage, basket: 2, canContinue: true, canFinish: true)
        XCTAssertEqual(lost.title, "The scan stopped")
        XCTAssertEqual(lost.continueTitle, "Keep scanning")
        XCTAssertTrue(lost.isWarning)
    }

    func testCameraDeniedOffersSettingsAndTryAgain() {
        let denied = shown(.failed, message: "Umma needs the camera.", denied: true, canContinue: true)
        XCTAssertEqual(denied.title, "Umma can’t use the camera")
        XCTAssertTrue(denied.showsSettings)
        XCTAssertEqual(denied.continueTitle, "Try again")
        XCTAssertFalse(denied.canFinish)
        let failed = shown(.failed, message: LiveScanViewModel.connectFailedMessage, canContinue: true)
        XCTAssertEqual(failed.title, "The scan didn’t start")
        XCTAssertFalse(failed.showsSettings)
    }

    func testDemoIsLabelled() {
        XCTAssertEqual(shown(.scanning, cameraOn: true, demo: true).demoLabel, "Demo mode — not a real detection")
    }

    func testModelReportsADeniedCameraAndClearsItOnRetry() async {
        let camera = FakeFrameStreamingCameraSource()
        camera.startError = .permissionDenied(permission: "camera", explainer: "Umma needs the camera.")
        let model = LiveScanViewModel(camera: camera, tokens: FakeLiveScanTokenService(), service: FakeLiveScanBasketService(),
                                      makeTransport: { _ in FakeLiveScanTransport(script: []) },
                                      tickSleep: { try await Task.sleep(for: .seconds(3600)) })
        await model.start()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.permissionDenied)
        XCTAssertTrue(model.canContinue)
        camera.startError = nil
        await model.continueScanning()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertFalse(model.permissionDenied)
        await model.cancel()
        XCTAssertFalse(model.cameraOn)
    }

    func testScanOptionsFollowTheFlag() {
        XCTAssertEqual(PantryScanOption.options(liveScan: false), [.photo])
        XCTAssertEqual(PantryScanOption.options(liveScan: true), [.liveScan, .photo])
        XCTAssertEqual(PantryScanOption.liveScan.title, "Live scan")
    }

    // MARK: - Review after Done

    private func finished() throws -> LiveScanResultPresentation {
        LiveScanResultPresentation(try PantryFixtures.decode(LiveScanFinished.self, LiveScanBasketFixtures.finishedJSON))
    }

    func testReviewStartsUntickedAndDoneSendsNothing() async throws {
        let service = FakePantryService()
        let review = LiveScanReviewModel(result: try finished(), isDemo: false, service: service)
        XCTAssertEqual(review.headline, "Added 1 item to your pantry")
        XCTAssertEqual(review.autoAddedNames, ["eggs"])
        XCTAssertEqual(review.rows.map(\.name), ["gochujang", "butter", "x"])
        XCTAssertTrue(review.rows.allSatisfy { $0.decision == nil })
        XCTAssertEqual(review.primaryTitle, "Done")
        let done = await review.confirm()
        XCTAssertTrue(done)
        XCTAssertTrue(service.calls.isEmpty, "nothing in the review is saved without a tap")
        XCTAssertEqual(review.saved.map(\.rawLabel), ["eggs"])
    }

    func testTickedAndMergedRowsAreSavedOnConfirm() async throws {
        let service = FakePantryService()
        service.addHandler = { _, _ in [PantryFixtures.item(raw: "gochujang")] }
        let review = LiveScanReviewModel(result: try finished(), isDemo: false, service: service)
        review.toggle("gochujang")
        review.toggle("butter")
        XCTAssertNil(review.rows[1].decision, "a match in the pantry needs Merge or Keep both, not a tick")
        review.choose("butter", .merge)
        XCTAssertEqual(review.primaryTitle, "Add 2 items")
        let done = await review.confirm()
        XCTAssertTrue(done)
        let sent = try XCTUnwrap(service.addCalls.first)
        XCTAssertEqual(sent.map(\.rawLabel), ["gochujang", "butter"])
        XCTAssertEqual(sent.map(\.source), [.photo, .photo])
        XCTAssertNil(sent[0].resolution)
        XCTAssertEqual(sent[1].resolution, .mergeInto(try XCTUnwrap(UUID(uuidString: PantryFixtures.onionId))))
        XCTAssertEqual(review.saved.map(\.rawLabel), ["eggs", "gochujang"])
    }

    func testChoosingTheSameAnswerAgainClearsIt() throws {
        let review = LiveScanReviewModel(result: try finished(), isDemo: false, service: FakePantryService())
        review.choose("butter", .keepBoth)
        XCTAssertEqual(review.rows[1].decision, .keepBoth)
        review.choose("butter", .keepBoth)
        XCTAssertNil(review.rows[1].decision)
        review.toggle("gochujang")
        review.toggle("gochujang")
        XCTAssertEqual(review.selectedCount, 0)
    }

    func testADuplicateFoundOnSaveAsksInsteadOfDeciding() async throws {
        let service = FakePantryService()
        let conflict = try PantryFixtures.duplicateError()
        service.addHandler = { _, _ in throw conflict }
        let review = LiveScanReviewModel(result: try finished(), isDemo: false, service: service)
        review.toggle("gochujang")
        let done = await review.confirm()
        XCTAssertFalse(done)
        XCTAssertTrue(review.rows[0].isDuplicate)
        XCTAssertNil(review.rows[0].decision)
        XCTAssertEqual(review.error, "Some of these are already in your pantry. Choose Merge or Keep both, then add again.")
        XCTAssertEqual(review.saved.map(\.rawLabel), ["eggs"])
    }

    func testAFailedSaveKeepsTheChoices() async throws {
        let service = FakePantryService()
        service.addHandler = { _, _ in throw APIError.http(status: 500, correlationId: nil) }
        let review = LiveScanReviewModel(result: try finished(), isDemo: false, service: service)
        review.toggle("gochujang")
        let done = await review.confirm()
        XCTAssertFalse(done)
        XCTAssertEqual(review.rows[0].decision, .add)
        XCTAssertTrue(review.error?.hasPrefix("Couldn’t add:") ?? false)
    }

    func testHeadlines() {
        let empty = LiveScanResultPresentation(LiveScanFinished(saved: [], review: []))
        let nothing = LiveScanReviewModel(result: empty, isDemo: false, service: FakePantryService())
        XCTAssertEqual(nothing.headline, "Nothing new was found")
        XCTAssertNotNil(nothing.detail)
        let demo = LiveScanReviewModel(result: empty, isDemo: true, service: FakePantryService())
        XCTAssertEqual(demo.headline, "Demo scan. Nothing was saved")
    }
}
