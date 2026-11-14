import Foundation
import XCTest
@testable import Umma

/// Scriptable `LiveScanBasketService`.
final class FakeLiveScanBasketService: LiveScanBasketService, @unchecked Sendable {
    enum Call: Equatable {
        case create(demo: Bool)
        case add(UUID, LiveScanItemReport)
        case remove(UUID, String)
        case finish(UUID)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    /// Optional suspension per call (after it is recorded); lets tests hold a response back.
    var suspend: (@Sendable (Call) async -> Void)?

    var createHandler: @Sendable (Bool) throws -> LiveScanCreated = { demo in
        LiveScanCreated(id: LiveScanBasketFixtures.scanID, demo: demo, expiresAt: .distantFuture)
    }
    var addHandler: @Sendable (LiveScanItemReport) throws -> LiveScanItemResult = { LiveScanBasketFixtures.result($0.name) }
    var removeHandler: @Sendable (String) throws -> Void = { _ in }
    var finishHandler: @Sendable () throws -> LiveScanFinished = { LiveScanFinished(saved: [], review: []) }

    func createLiveScan(demo: Bool) async throws -> LiveScanCreated {
        record(.create(demo: demo)); await suspend?(.create(demo: demo)); return try createHandler(demo)
    }
    func addLiveScanItem(scanID: UUID, _ item: LiveScanItemReport) async throws -> LiveScanItemResult {
        record(.add(scanID, item)); await suspend?(.add(scanID, item)); return try addHandler(item)
    }
    func removeLiveScanItem(scanID: UUID, key: String) async throws {
        record(.remove(scanID, key)); try removeHandler(key)
    }
    /// Holds the finish request open (after it is recorded).
    var finishSuspend: (@Sendable () async -> Void)?

    func finishLiveScan(scanID: UUID) async throws -> LiveScanFinished {
        record(.finish(scanID)); await finishSuspend?(); return try finishHandler()
    }

    var removeCalls: [String] {
        calls.compactMap { if case .remove(_, let key) = $0 { return key } else { return nil } }
    }
    var createCalls: [Call] {
        calls.filter { if case .create = $0 { return true } else { return false } }
    }
    var finishCalls: [Call] {
        calls.filter { if case .finish = $0 { return true } else { return false } }
    }
}

/// Scriptable token minting: `handler` gets the 1-based request number.
final class FakeLiveScanTokenService: LiveScanService, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[String]] = []
    /// `already_in_basket` of every request, in order.
    var requests: [[String]] { lock.withLock { _requests } }
    var handler: @Sendable (Int) throws -> LiveScanToken = { _ in LiveScanFixtures.token() }
    /// Optional suspension per request (after it is recorded).
    var suspend: (@Sendable () async -> Void)?

    func liveScanToken(alreadyInBasket: [String]) async throws -> LiveScanToken {
        let number = lock.withLock { () -> Int in
            _requests.append(alreadyInBasket)
            return _requests.count
        }
        await suspend?()
        return try handler(number)
    }
}

/// Hands out one silent `FakeLiveScanTransport` per session and keeps them for the test.
@MainActor
final class FakeLiveScanTransportFactory {
    private(set) var made: [FakeLiveScanTransport] = []
    var connectError: Error?

    func make(_ token: LiveScanToken) -> any LiveScanTransport {
        let transport = FakeLiveScanTransport(script: [])
        transport.connectError = connectError
        made.append(transport)
        return transport
    }
}

/// A transport whose `close()` never ends `events` and never reports `.closed`.
@MainActor
final class StuckLiveScanTransport: LiveScanTransport {
    let events: AsyncStream<LiveScanEvent>
    private let continuation: AsyncStream<LiveScanEvent>.Continuation
    private(set) var closeCount = 0

    init() {
        (events, continuation) = AsyncStream.makeStream(of: LiveScanEvent.self)
    }

    func connect(token: LiveScanToken) async throws {}
    func send(frame jpeg: Data) {}
    func respond(callID: String, name: String, status: String, canonical: String?) {}
    func close() { closeCount += 1 }
}

@MainActor
final class LiveScanViewModelTests: XCTestCase {
    private var camera: FakeFrameStreamingCameraSource!
    private var tokens: FakeLiveScanTokenService!
    private var service: FakeLiveScanBasketService!
    private var factory: FakeLiveScanTransportFactory!
    private var frameSecond = 0.0
    /// The model's monotonic clock, in seconds; tests move it by hand.
    private var clock: TestBox<TimeInterval>!

    override func setUp() async throws {
        camera = FakeFrameStreamingCameraSource()
        tokens = FakeLiveScanTokenService()
        service = FakeLiveScanBasketService()
        factory = FakeLiveScanTransportFactory()
        frameSecond = 0
        clock = TestBox(1000)
    }

    private func makeModel() -> LiveScanViewModel {
        let transports = factory!
        let clock = clock!
        return LiveScanViewModel(camera: camera, tokens: tokens, service: service,
                                 makeTransport: { transports.make($0) },
                                 tickSleep: { try await Task.sleep(for: .seconds(3600)) },
                                 uptime: { clock.value })
    }

    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }

    /// Reports one item on `transport` and waits until the model answered it.
    private func report(_ name: String, on transport: FakeLiveScanTransport, confidence: LiveScanConfidence = .high,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let answered = transport.responses.count
        transport.emit(.itemReported(callID: "call-\(answered)", name: name, kind: "sauce", confidence: confidence))
        await waitUntil("an answer for \(name)", file: file, line: line) { transport.responses.count == answered + 1 }
    }

    /// Offers one camera frame, a second after the previous one. True if the stream took it.
    private func offerFrame() -> Bool {
        frameSecond += 1
        return camera.send(CapturedFrame(jpegData: Data([0xFF, 0xD8]), capturedAt: Date(timeIntervalSinceReferenceDate: frameSecond)))
    }

    // MARK: - Start

    func testStartOpensCameraScanAndSessionAndForwardsFrames() async {
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertTrue(model.cameraOn)
        XCTAssertFalse(model.isDemo)
        XCTAssertEqual(model.scanID, LiveScanBasketFixtures.scanID)
        XCTAssertEqual(model.secondsRemaining, 120)
        XCTAssertEqual(service.calls, [.create(demo: false)])
        XCTAssertEqual(tokens.requests, [[]])
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertTrue(factory.made[0].isOpen)
        XCTAssertTrue(offerFrame())
        await waitUntil("the frame to reach the transport") { factory.made[0].framesSent == 1 }
    }

    func testDemoTokenMakesADemoScan() async {
        tokens.handler = { _ in LiveScanFixtures.token(demo: true) }
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(service.calls, [.create(demo: true)])
    }

    func testFailuresBeforeScanningLeaveTheCameraOffAndCanBeRetried() async {
        camera.startError = .permissionDenied(permission: "camera", explainer: "Umma needs the camera.")
        let denied = makeModel()
        await denied.start()
        XCTAssertEqual(denied.phase, .failed)
        XCTAssertEqual(denied.message, "Umma needs the camera.")
        XCTAssertFalse(denied.cameraOn)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(tokens.requests.isEmpty)

        camera.startError = nil
        tokens.handler = { _ in throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let offline = makeModel()
        await offline.start()
        XCTAssertEqual(offline.phase, .failed)
        XCTAssertFalse(offline.cameraOn)
        XCTAssertTrue(factory.made.isEmpty)

        tokens.handler = { _ in LiveScanFixtures.token() }
        factory.connectError = LiveScanError.setupFailed("no setup")
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.message, LiveScanViewModel.connectFailedMessage)
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(factory.made[0].isOpen)
        XCTAssertFalse(offerFrame(), "no frames flow after a failed start")

        factory.connectError = nil
        await model.continueScanning()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertTrue(factory.made[1].isOpen)
        XCTAssertEqual(service.createCalls.count, 1, "the retry reuses the scan")
    }

    func testHourlyLimitAtStartIsALimitState() async {
        tokens.handler = { _ in throw LiveScanBasketFixtures.rateLimited() }
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .limitReached)
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(model.canFinish, "nothing was scanned")
    }

    // MARK: - Items

    func testNewItemAddsOneEntryAndEmitsAChip() async throws {
        service.addHandler = { LiveScanBasketFixtures.result($0.name, canonical: "soy sauce") }
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        await report("shoyu", on: transport, confidence: .unknown)

        XCTAssertEqual(model.basket.map(\.name), ["soy sauce"])
        let entry = try XCTUnwrap(model.basket.first)
        XCTAssertEqual(entry.key, "soy sauce")
        XCTAssertEqual(entry.confidence, .high)
        XCTAssertEqual(model.cue, LiveScanCue(id: 1, kind: .added(entryID: entry.id), key: "soy sauce", name: "soy sauce"))
        XCTAssertEqual(transport.responses, [.init(callID: "call-0", name: "add_item", status: "new", canonical: "soy sauce")])
        let sent = LiveScanItemReport(name: "shoyu", kind: "sauce", confidence: .unknown)
        XCTAssertEqual(sent.confidence, "low", "the server only accepts high, medium or low")
        XCTAssertEqual(service.calls.last, .add(LiveScanBasketFixtures.scanID, sent))
    }

    func testRepeatsAndPantryItemsPulseAndAddNothing() async {
        service.addHandler = { item in
            switch item.name {
            case "shoyu": return LiveScanBasketFixtures.result("shoyu", status: .alreadyInBasket, canonical: "soy sauce")
            case "butter": return LiveScanBasketFixtures.result("butter", status: .inPantry)
            case "mystery": return LiveScanBasketFixtures.result("mystery", status: .unknown)
            default: return LiveScanBasketFixtures.result(item.name)
            }
        }
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        await report("soy sauce", on: transport)
        await report("shoyu", on: transport)
        XCTAssertEqual(model.cue, LiveScanCue(id: 2, kind: .alreadyHave, key: "soy sauce", name: "soy sauce"))
        await report("butter", on: transport)
        XCTAssertEqual(model.cue, LiveScanCue(id: 3, kind: .alreadyHave, key: "butter", name: "butter"))
        // The server says "new" twice for the same key: the local guard still adds it once.
        await report("eggs", on: transport)
        await report("eggs", on: transport)
        XCTAssertEqual(model.cue?.kind, .alreadyHave)
        // A status this build doesn't know adds nothing and shows nothing.
        await report("mystery", on: transport)
        XCTAssertEqual(model.cue?.id, 5)

        XCTAssertEqual(model.basket.map(\.key), ["soy sauce", "eggs"])
        XCTAssertEqual(transport.responses.map(\.status),
                       ["new", "already_in_basket", "in_pantry", "new", "already_in_basket", "ignored"])
        XCTAssertEqual(transport.responses.map(\.callID), (0..<6).map { "call-\($0)" }, "exactly one answer per call")
    }

    func testBackendFailureStillAnswersTheModel() async {
        service.addHandler = { item in
            if item.name == "glass jar" {
                throw APIError.server(status: 422, code: "VALIDATION_ERROR", message: "name must name an ingredient",
                                      retryable: false, correlationId: nil)
            }
            throw APIError.unreachable(baseURL: "http://x", underlying: "down")
        }
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        await report("eggs", on: transport)
        await report("glass jar", on: transport)
        XCTAssertTrue(model.basket.isEmpty)
        XCTAssertNil(model.cue)
        XCTAssertEqual(transport.responses.map(\.status), ["error", "ignored"])
        XCTAssertEqual(transport.responses.map(\.callID), ["call-0", "call-1"])
        XCTAssertEqual(model.phase, .scanning, "one failed item doesn't end the scan")
    }

    func testRemoveDropsTheItemAndARepeatNeverBringsItBack() async throws {
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        await report("eggs", on: transport)
        await report("rice", on: transport)
        let eggs = try XCTUnwrap(model.basket.first)
        await model.remove(eggs)
        XCTAssertEqual(model.basket.map(\.key), ["rice"])
        XCTAssertEqual(service.removeCalls, ["eggs"])
        XCTAssertNil(model.message)

        // The server no longer holds it, so it answers "new" again.
        await report("eggs", on: transport)
        XCTAssertEqual(model.basket.map(\.key), ["rice"])
        XCTAssertEqual(service.removeCalls, ["eggs", "eggs"], "taken out of the server basket again")
        XCTAssertEqual(transport.responses.last?.status, "already_in_basket")
    }

    func testFailedRemoveRestoresTheEntry() async throws {
        service.removeHandler = { _ in throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        await report("rice", on: factory.made[0])
        let eggs = try XCTUnwrap(model.basket.first)
        await model.remove(eggs)
        XCTAssertEqual(model.basket.map(\.id), [eggs.id, model.basket[1].id])
        XCTAssertEqual(model.basket.map(\.key), ["eggs", "rice"])
        XCTAssertEqual(model.message?.contains("Couldn’t remove eggs"), true)
    }

    // MARK: - Sessions

    func testSessionRotationKeepsTheBasketAndTheScan() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        XCTAssertTrue(offerFrame())
        await waitUntil("a frame on the first session") { factory.made[0].framesSent == 1 }
        factory.made[0].end(.sessionLimit)
        await waitUntil("the second session") { factory.made.count == 2 && factory.made[1].isOpen }
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"])
        XCTAssertEqual(tokens.requests, [[], ["eggs"]], "the new session is told what was already reported")
        XCTAssertTrue(model.cameraOn)

        XCTAssertTrue(offerFrame())
        await waitUntil("frames on the new session") { factory.made[1].framesSent == 1 }
        XCTAssertEqual(factory.made[0].framesSent, 1, "a frame after rotation goes only to the new session")
        await report("rice", on: factory.made[1])
        XCTAssertEqual(model.basket.map(\.key), ["eggs", "rice"])

        factory.made[1].emit(.goAway)
        await waitUntil("the third session") { factory.made.count == 3 && factory.made[2].isOpen }
        XCTAssertFalse(factory.made[1].isOpen, "the old session is closed")
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(service.createCalls.count, 1, "one backend scan for every session")
        XCTAssertEqual(model.scanID, LiveScanBasketFixtures.scanID)
    }

    func testBudgetRefusalOnRotationEndsGracefullyAndDoneStillWorks() async {
        tokens.handler = { number in LiveScanFixtures.token(demo: number > 1) }
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        factory.made[0].end(.sessionLimit)
        await waitUntil("the limit state") { model.phase == .limitReached }
        XCTAssertEqual(model.message, LiveScanViewModel.limitMessage)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"])
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(model.isDemo, "a real scan never turns into a demo")
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertFalse(model.canContinue)

        await model.finish()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(service.finishCalls, [.finish(LiveScanBasketFixtures.scanID)])
    }

    func testHourlyTokenLimitOnRotationIsTheSameLimitState() async {
        tokens.handler = { number in
            if number > 1 { throw LiveScanBasketFixtures.rateLimited() }
            return LiveScanFixtures.token()
        }
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        factory.made[0].emit(.goAway)
        await waitUntil("the limit state") { model.phase == .limitReached }
        XCTAssertEqual(model.basket.count, 1)
        XCTAssertTrue(model.canFinish)
    }

    func testReconnectsOnceThenStopsWithARecoverableError() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        factory.made[0].end(.server(code: 1011, reason: "internal"))
        await waitUntil("the automatic reconnect") { factory.made.count == 2 && factory.made[1].isOpen }
        XCTAssertEqual(model.phase, .scanning)

        factory.made[1].emit(.error("socket dropped"))
        factory.made[1].end(.connectionLost)
        await waitUntil("the interrupted state") { model.phase == .interrupted }
        XCTAssertEqual(factory.made.count, 2, "only one automatic reconnect")
        XCTAssertEqual(model.message, LiveScanViewModel.connectionMessage)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"])
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(offerFrame())

        await model.continueScanning()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(factory.made.count, 3)
        XCTAssertEqual(service.createCalls.count, 1)
    }

    func testAHealthySessionEarnsAnotherReconnect() async {
        let model = makeModel()
        await model.start()
        factory.made[0].end(.connectionLost)
        await waitUntil("the first reconnect") { factory.made.count == 2 && factory.made[1].isOpen }
        // Open for 15 s: the next drop reconnects again.
        clock.value += LiveScanViewModel.healthySessionSeconds
        factory.made[1].end(.connectionLost)
        await waitUntil("the second reconnect") { factory.made.count == 3 && factory.made[2].isOpen }
        // An item is a sign of health too.
        await report("eggs", on: factory.made[2])
        factory.made[2].end(.server(code: 1011, reason: nil))
        await waitUntil("the third reconnect") { factory.made.count == 4 && factory.made[3].isOpen }
        XCTAssertEqual(model.phase, .scanning)
        // A drop straight after a reconnect, with no item, ends the scan.
        factory.made[3].end(.connectionLost)
        await waitUntil("the interrupted state") { model.phase == .interrupted }
        XCTAssertEqual(factory.made.count, 4)
    }

    func testTheWindowStopsAt120SecondsAndKeepScanningStartsAnother() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        clock.value += 119
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, 1)
        XCTAssertEqual(model.phase, .scanning)
        clock.value += 0.5
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, 1, "half a second left still shows 1")
        clock.value += 0.5
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, 0)
        XCTAssertEqual(model.phase, .timeUp)
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(factory.made[0].isOpen)
        XCTAssertFalse(offerFrame(), "frames stop with the window")
        XCTAssertEqual(factory.made[0].framesSent, 0)

        await model.continueScanning()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(model.secondsRemaining, 120)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"])
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertEqual(service.createCalls.count, 1)
        XCTAssertEqual(tokens.requests.last, ["eggs"])

        // One late tick ends the window at once: it can't stretch past 120 s.
        clock.value += 500
        await model.tick()
        XCTAssertEqual(model.phase, .timeUp)
        XCTAssertEqual(model.secondsRemaining, 0)
    }

    func testAStaleTickAfterStopChangesNothing() async {
        let model = makeModel()
        await model.start()
        clock.value += 30
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, 90)
        await model.cancel()
        clock.value += 500
        await model.tick()
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(model.secondsRemaining, 90)
        XCTAssertNil(model.message)
    }

    // MARK: - Finish, cancel

    func testFinishStopsEverythingAndPresentsAutoAddedAndReviewItems() async throws {
        let finished = try PantryFixtures.decode(LiveScanFinished.self, LiveScanBasketFixtures.finishedJSON)
        service.finishHandler = { finished }
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        await model.finish()

        XCTAssertEqual(model.phase, .finished)
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(factory.made[0].isOpen)
        XCTAssertFalse(offerFrame(), "no frames flow after Done")
        XCTAssertEqual(service.calls.last, .finish(LiveScanBasketFixtures.scanID))
        let result = try XCTUnwrap(model.result)
        XCTAssertEqual(result.autoAddedNames, ["eggs"])
        XCTAssertEqual(result.review.map(\.name), ["gochujang", "butter", "x"])
        XCTAssertEqual(result.review.map(\.reasonText), ["Not sure", "Already in your pantry", "Needs a check"])
        XCTAssertEqual(result.review[1].existingPantryItemId, UUID(uuidString: PantryFixtures.onionId))

        await model.finish()
        await model.cancel()
        XCTAssertEqual(service.finishCalls.count, 1)
        XCTAssertEqual(model.phase, .finished)
    }

    func testFailedFinishKeepsTheBasketAndCanBeRetried() async {
        service.finishHandler = { throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        await model.finish()
        XCTAssertEqual(model.phase, .interrupted)
        XCTAssertNil(model.result)
        XCTAssertEqual(model.basket.count, 1)
        XCTAssertFalse(model.cameraOn)

        service.finishHandler = { LiveScanFinished(saved: [], review: []) }
        await model.finish()
        XCTAssertEqual(model.phase, .finished)
    }

    // MARK: - Lifecycle (review fixes)

    func testBackgroundingStopsTheScanAndNothingResumesOnItsOwn() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        await model.pauseForBackground()

        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.cameraOn, "camera off")
        XCTAssertFalse(factory.made[0].isOpen, "transport closed")
        XCTAssertFalse(offerFrame(), "no frames flow")
        XCTAssertEqual(model.basket.map(\.name), ["eggs"], "the basket is kept")
        XCTAssertEqual(model.message, LiveScanViewModel.pausedMessage)
        let remaining = model.secondsRemaining
        clock.value += 60
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, remaining, "the timer is stopped")
        XCTAssertEqual(model.phase, .paused, "still paused after the app is back")
        XCTAssertEqual(factory.made.count, 1, "no new session opens by itself")
        XCTAssertEqual(tokens.requests.count, 1)

        let shown = LiveScanScreenPresentation(phase: model.phase, cameraOn: model.cameraOn, secondsRemaining: model.secondsRemaining,
                                               isDemo: false, message: model.message, permissionDenied: false,
                                               basketCount: 1, canContinue: model.canContinue, canFinish: model.canFinish)
        XCTAssertEqual(shown.title, "Scanning paused")
        XCTAssertEqual(shown.continueTitle, "Keep scanning")
        XCTAssertNil(shown.indicatorText)
        XCTAssertNil(shown.countdownText)
        XCTAssertTrue(shown.canFinish, "Done still saves the basket")
        XCTAssertFalse(shown.isWarning)
    }

    func testKeepScanningAfterBackgroundIsTheCooksTapOnTheSameScan() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        await model.pauseForBackground()
        await model.continueScanning()

        XCTAssertEqual(model.phase, .scanning)
        XCTAssertTrue(model.cameraOn)
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertEqual(service.createCalls.count, 1, "the same scan and basket")
        XCTAssertEqual(model.basket.map(\.name), ["eggs"])
        XCTAssertEqual(model.secondsRemaining, 120)
    }

    func testBackgroundingWhileStartingLeavesNothingRunning() async {
        let latch = TestLatch()
        tokens.suspend = { await latch.wait() }
        let model = makeModel()
        let starting = Task { await model.start() }
        await waitUntil("the token request") { tokens.requests.count == 1 }
        await model.pauseForBackground()
        await latch.open()
        await starting.value

        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.cameraOn)
        XCTAssertTrue(factory.made.isEmpty)
        XCTAssertTrue(model.canContinue)
    }

    func testBackgroundingOnlyTouchesARunningScan() async {
        let model = makeModel()
        await model.pauseForBackground()
        XCTAssertEqual(model.phase, .idle)
        await model.start()
        clock.value += 121
        await model.tick()
        XCTAssertEqual(model.phase, .timeUp)
        await model.pauseForBackground()
        XCTAssertEqual(model.phase, .timeUp)
        await model.cancel()
        await model.pauseForBackground()
        XCTAssertEqual(model.phase, .cancelled)
    }

    func testASaveThatFinishesAfterTheSheetClosedStillReachesThePantry() async throws {
        let finished = try PantryFixtures.decode(LiveScanFinished.self, LiveScanBasketFixtures.finishedJSON)
        service.finishHandler = { finished }
        let latch = TestLatch()
        service.finishSuspend = { await latch.wait() }
        let model = makeModel()
        let delivered = TestBox<[[String]]>([])
        model.onFinished = { result in delivered.value.append(result.autoAddedNames) }
        await model.start()
        await report("eggs", on: factory.made[0])

        let saving = Task { await model.finish() }
        await waitUntil("the finish request") { service.finishCalls.count == 1 }
        XCTAssertEqual(model.phase, .finishing)
        XCTAssertTrue(model.blocksDismissal, "Cancel and swipe-down are off while saving")
        // What the sheet's onDisappear does, if it were closed anyway.
        await model.cancel()
        XCTAssertTrue(delivered.value.isEmpty)
        await latch.open()
        await saving.value

        XCTAssertEqual(model.phase, .finished)
        XCTAssertFalse(model.blocksDismissal)
        XCTAssertEqual(delivered.value, [["eggs"]], "the pantry hears about the save exactly once")
    }

    func testAFailedSaveDeliversNothing() async {
        service.finishHandler = { throw APIError.http(status: 500, correlationId: nil) }
        let model = makeModel()
        let delivered = TestBox(0)
        model.onFinished = { _ in delivered.value += 1 }
        await model.start()
        await model.finish()
        XCTAssertEqual(model.phase, .interrupted)
        XCTAssertEqual(delivered.value, 0)
        XCTAssertFalse(model.blocksDismissal)
    }

    func testCancelStopsEverythingAndSavesNothing() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        await model.cancel()
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertTrue(model.basket.isEmpty)
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(factory.made[0].isOpen)
        XCTAssertFalse(offerFrame())
        XCTAssertTrue(service.finishCalls.isEmpty)
        await model.finish()
        XCTAssertTrue(service.finishCalls.isEmpty, "nothing to finish after a cancel")
    }

    func testAnItemThatLandsAfterStopIsIgnored() async {
        let latch = TestLatch()
        service.suspend = { call in
            if case .add = call { await latch.wait() }
        }
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        transport.emit(.itemReported(callID: "late", name: "eggs", kind: nil, confidence: .high))
        await waitUntil("the add call") { service.calls.count == 2 }
        let events = model.eventTask
        XCTAssertNotNil(events)
        await model.cancel()
        await latch.open()
        // The event task ends only after it has dealt with the late answer.
        await events?.value

        XCTAssertTrue(model.basket.isEmpty)
        XCTAssertNil(model.cue)
        XCTAssertTrue(transport.responses.isEmpty)
        XCTAssertEqual(model.phase, .cancelled)
        await model.remove(LiveScanBasketEntry(id: UUID(), key: "eggs", name: "eggs", confidence: .high))
        XCTAssertTrue(service.removeCalls.isEmpty)
    }

    func testDoneWaitsForAnAddInFlight() async {
        let latch = TestLatch()
        service.suspend = { call in
            if case .add = call { await latch.wait() }
        }
        let model = makeModel()
        await model.start()
        factory.made[0].emit(.itemReported(callID: "c", name: "eggs", kind: nil, confidence: .high))
        await waitUntil("the add call") { service.calls.count == 2 }
        let events = model.eventTask
        let done = Task { await model.finish() }
        await waitUntil("finishing") { model.phase == .finishing }
        XCTAssertTrue(service.finishCalls.isEmpty, "finish waits for the add")
        await latch.open()
        await done.value
        await events?.value

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(service.calls.count, 3)
        XCTAssertEqual(service.calls.last, .finish(LiveScanBasketFixtures.scanID), "the add reached the server first")
        XCTAssertTrue(factory.made[0].responses.isEmpty, "the closed session gets no answer")
        let entry = LiveScanBasketEntry(id: UUID(), key: "eggs", name: "eggs", confidence: .high)
        await model.remove(model.basket.first ?? entry)
        XCTAssertTrue(service.removeCalls.isEmpty, "nothing is removed after Done")
    }

    func testCancelDuringTheTokenRequestLeavesNothingRunning() async {
        let latch = TestLatch()
        tokens.suspend = { await latch.wait() }
        let model = makeModel()
        let starting = Task { await model.start() }
        await waitUntil("the token request") { tokens.requests.count == 1 }
        await model.cancel()
        await latch.open()
        await starting.value

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertFalse(model.cameraOn)
        XCTAssertTrue(service.calls.isEmpty, "no scan is created after a cancel")
        XCTAssertTrue(factory.made.isEmpty)
        XCTAssertNil(model.scanID)
    }

    func testCancelDuringCreateScanLeavesNothingRunning() async {
        let latch = TestLatch()
        service.suspend = { _ in await latch.wait() }
        let model = makeModel()
        let starting = Task { await model.start() }
        await waitUntil("the create call") { service.calls == [.create(demo: false)] }
        await model.cancel()
        await latch.open()
        await starting.value

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertFalse(model.cameraOn)
        XCTAssertNil(model.scanID)
        XCTAssertTrue(factory.made.isEmpty, "no session opens after a cancel")
        XCTAssertFalse(offerFrame())
    }

    func testFinishReturnsWhenTheTransportNeverEndsItsEvents() async {
        let stuck = StuckLiveScanTransport()
        let clock = clock!
        let model = LiveScanViewModel(camera: camera, tokens: tokens, service: service,
                                      makeTransport: { _ in stuck },
                                      tickSleep: { try await Task.sleep(for: .seconds(3600)) },
                                      uptime: { clock.value })
        await model.start()
        XCTAssertEqual(model.phase, .scanning)
        let events = model.eventTask
        await model.finish()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(stuck.closeCount, 1)
        XCTAssertFalse(model.cameraOn)
        await events?.value
        XCTAssertNil(model.eventTask)
    }

    // MARK: - Scan-level and item-level failures

    func testAFailedReRemoveShowsTheItemAgain() async throws {
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        await report("eggs", on: transport)
        await model.remove(try XCTUnwrap(model.basket.first))
        XCTAssertTrue(model.basket.isEmpty)

        // The model reports it again, and taking it back out of the server basket fails.
        service.removeHandler = { _ in throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        await report("eggs", on: transport)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"], "the server would save it, so the cook sees it")
        XCTAssertEqual(model.message?.contains("Couldn’t remove eggs"), true)
        XCTAssertEqual(transport.responses.last?.status, "new")
        XCTAssertEqual(service.removeCalls, ["eggs", "eggs"])

        // Not stuck: once the server answers, the cook can remove it for good.
        service.removeHandler = { _ in }
        await model.remove(try XCTUnwrap(model.basket.first))
        await report("eggs", on: transport)
        XCTAssertTrue(model.basket.isEmpty)
        XCTAssertEqual(transport.responses.last?.status, "already_in_basket")
    }

    func testScanLevelAddErrorsStopTheScanAndItemLevelOnesDoNot() async {
        func conflict(_ message: String) -> APIError {
            .server(status: 409, code: "STATE_CONFLICT", message: message, retryable: false, correlationId: nil)
        }
        let gone = APIError.server(status: 404, code: "NOT_FOUND", message: "Live scan not found",
                                   retryable: false, correlationId: nil)
        for closed in [gone, conflict("This scan is finished"), APIError.unauthorized(message: nil, correlationId: nil)] {
            factory = FakeLiveScanTransportFactory()
            service = FakeLiveScanBasketService()
            let model = makeModel()
            await model.start()
            let transport = factory.made[0]
            await report("eggs", on: transport)
            service.addHandler = { _ in throw closed }
            await report("rice", on: transport)
            XCTAssertEqual(transport.responses.map(\.status), ["new", "error"], "the model is still answered")
            await waitUntil("the scan to stop") { model.phase == .interrupted }
            XCTAssertEqual(model.message, LiveScanViewModel.scanClosedMessage)
            XCTAssertEqual(model.basket.map(\.key), ["eggs"])
            XCTAssertFalse(model.cameraOn)
            XCTAssertFalse(transport.isOpen)
            XCTAssertTrue(model.canFinish)
        }

        factory = FakeLiveScanTransportFactory()
        service = FakeLiveScanBasketService()
        let full = conflict("The basket is full; finish this scan and start another")
        service.addHandler = { _ in throw full }
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        XCTAssertEqual(factory.made[0].responses.map(\.status), ["ignored"])
        XCTAssertEqual(model.phase, .scanning, "a full basket refuses the item, not the scan")
        XCTAssertNil(model.message)
    }
}
