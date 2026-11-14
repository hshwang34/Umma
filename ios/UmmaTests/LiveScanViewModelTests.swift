import Foundation
import XCTest
@testable import Umma

enum LiveScanBasketFixtures {
    static let scanID = UUID(uuidString: "7c9e6679-7425-40de-944b-e07fc1f90ae7")!

    static func result(_ name: String, status: LiveScanItemStatus = .new, canonical: String? = nil,
                       confidence: LiveScanConfidence = .high) -> LiveScanItemResult {
        LiveScanItemResult(status: status, key: canonical ?? name, canonicalName: canonical ?? name,
                           displayName: name, confidence: confidence, existingPantryItemId: nil)
    }

    static let itemJSON = """
    {"status":"new","key":"soy sauce","canonical_name":"soy sauce","display_name":"shoyu","confidence":"high",
     "existing_pantry_item_id":null}
    """

    static var finishedJSON: String {
        #"{"saved":["# + PantryFixtures.itemJSON(raw: "eggs", normalized: "egg", source: "live", confidence: "0.9") + """
        ],"review":[
          {"status":"new","key":"gochujang","canonical_name":"gochujang","display_name":"gochujang","confidence":"medium",
           "existing_pantry_item_id":null,"reason":"unsure"},
          {"status":"in_pantry","key":"butter","canonical_name":"butter","display_name":"butter","confidence":"high",
           "existing_pantry_item_id":"\(PantryFixtures.onionId)","reason":"in_pantry"},
          {"status":"merged","key":"x","canonical_name":"x","display_name":"x","confidence":"certain","reason":"later"}
        ]}
        """
    }

    static func rateLimited() -> APIError {
        .server(status: 429, code: "RATE_LIMITED", message: "Too many live scans in the last hour; try again later",
                retryable: true, correlationId: nil)
    }
}

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
        record(.create(demo: demo)); return try createHandler(demo)
    }
    func addLiveScanItem(scanID: UUID, _ item: LiveScanItemReport) async throws -> LiveScanItemResult {
        record(.add(scanID, item)); await suspend?(.add(scanID, item)); return try addHandler(item)
    }
    func removeLiveScanItem(scanID: UUID, key: String) async throws {
        record(.remove(scanID, key)); try removeHandler(key)
    }
    func finishLiveScan(scanID: UUID) async throws -> LiveScanFinished {
        record(.finish(scanID)); return try finishHandler()
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

    func liveScanToken(alreadyInBasket: [String]) async throws -> LiveScanToken {
        let number = lock.withLock { () -> Int in
            _requests.append(alreadyInBasket)
            return _requests.count
        }
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

@MainActor
final class LiveScanViewModelTests: XCTestCase {
    private var camera: FakeFrameStreamingCameraSource!
    private var tokens: FakeLiveScanTokenService!
    private var service: FakeLiveScanBasketService!
    private var factory: FakeLiveScanTransportFactory!
    private var frameSecond = 0.0

    override func setUp() async throws {
        camera = FakeFrameStreamingCameraSource()
        tokens = FakeLiveScanTokenService()
        service = FakeLiveScanBasketService()
        factory = FakeLiveScanTransportFactory()
        frameSecond = 0
    }

    private func makeModel() -> LiveScanViewModel {
        let transports = factory!
        return LiveScanViewModel(camera: camera, tokens: tokens, service: service,
                                 makeTransport: { transports.make($0) },
                                 tickSleep: { try await Task.sleep(for: .seconds(3600)) })
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
        factory.made[0].end(.sessionLimit)
        await waitUntil("the second session") { factory.made.count == 2 && factory.made[1].isOpen }
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"])
        XCTAssertEqual(tokens.requests, [[], ["eggs"]], "the new session is told what was already reported")
        XCTAssertTrue(model.cameraOn)

        XCTAssertTrue(offerFrame())
        await waitUntil("frames on the new session") { factory.made[1].framesSent == 1 }
        XCTAssertEqual(factory.made[0].framesSent, 0)
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

    func testTheWindowStopsAt120SecondsAndKeepScanningStartsAnother() async {
        let model = makeModel()
        await model.start()
        await report("eggs", on: factory.made[0])
        for _ in 0..<119 { await model.tick() }
        XCTAssertEqual(model.secondsRemaining, 1)
        XCTAssertEqual(model.phase, .scanning)
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, 0)
        XCTAssertEqual(model.phase, .timeUp)
        XCTAssertFalse(model.cameraOn)
        XCTAssertFalse(factory.made[0].isOpen)
        XCTAssertFalse(offerFrame(), "frames stop with the window")
        XCTAssertEqual(factory.made[0].framesSent, 0)
        await model.tick()
        XCTAssertEqual(model.secondsRemaining, 0)

        await model.continueScanning()
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertEqual(model.secondsRemaining, 120)
        XCTAssertEqual(model.basket.map(\.key), ["eggs"])
        XCTAssertEqual(factory.made.count, 2)
        XCTAssertEqual(service.createCalls.count, 1)
        XCTAssertEqual(tokens.requests.last, ["eggs"])
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
        service.suspend = { _ in await latch.wait() }
        let model = makeModel()
        await model.start()
        let transport = factory.made[0]
        transport.emit(.itemReported(callID: "late", name: "eggs", kind: nil, confidence: .high))
        await waitUntil("the add call") { service.calls.count == 2 }
        await model.cancel()
        await latch.open()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(model.basket.isEmpty)
        XCTAssertNil(model.cue)
        XCTAssertTrue(transport.responses.isEmpty)
        XCTAssertEqual(model.phase, .cancelled)
    }
}

/// Basket endpoints through the `URLProtocol` stub, and the DTOs' conservative decoding.
final class LiveScanBasketAPITests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(session: StubURLProtocol.makeSession(),
                  baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                  tokenProvider: InMemoryTokenStore(token: "tok"))
    }

    func testBasketEndpointsSendAndDecodeTheContract() async throws {
        let scan = LiveScanBasketFixtures.scanID.uuidString.lowercased()
        let base = "/v1/pantry/live-scans"
        StubURLProtocol.install { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", base):
                return (.stub(request, status: 201), Data(#"{"id":"\#(scan)","demo":true,"expires_at":"2026-11-15T10:00:00Z"}"#.utf8))
            case ("POST", "\(base)/\(scan)/items"):
                return (.stub(request, status: 200), Data(LiveScanBasketFixtures.itemJSON.utf8))
            case ("DELETE", "\(base)/\(scan)/items/soy sauce"):
                return (.stub(request, status: 204), Data())
            case ("POST", "\(base)/\(scan)/finish"):
                return (.stub(request, status: 200), Data(LiveScanBasketFixtures.finishedJSON.utf8))
            default:
                return (.stub(request, status: 404), Data())
            }
        }
        let client = makeClient()

        let created = try await client.createLiveScan(demo: false)
        XCTAssertEqual(created.id, LiveScanBasketFixtures.scanID)
        XCTAssertTrue(created.demo, "the server's demo flag wins")
        XCTAssertEqual(try StubURLProtocol.requests[0].jsonBody()["demo"] as? Bool, false)

        let item = try await client.addLiveScanItem(
            scanID: created.id, LiveScanItemReport(name: "shoyu", kind: nil, confidence: .medium))
        XCTAssertEqual(item, LiveScanItemResult(status: .new, key: "soy sauce", canonicalName: "soy sauce",
                                                displayName: "shoyu", confidence: .high, existingPantryItemId: nil))
        let body = try StubURLProtocol.requests[1].jsonBody()
        XCTAssertEqual(body["name"] as? String, "shoyu")
        XCTAssertEqual(body["confidence"] as? String, "medium")
        XCTAssertNil(body["kind"], "an absent kind is left out (the server forbids unknown keys, not missing ones)")

        try await client.removeLiveScanItem(scanID: created.id, key: "soy sauce")
        XCTAssertEqual(StubURLProtocol.requests[2].httpMethod, "DELETE")

        let finished = try await client.finishLiveScan(scanID: created.id)
        XCTAssertEqual(finished.saved.map(\.rawLabel), ["eggs"])
        XCTAssertEqual(finished.saved.first?.source, .other, "`live` is a source this build shows neutrally")
        XCTAssertEqual(finished.review.map(\.reason), [.unsure, .inPantry, .unknown])
        XCTAssertEqual(finished.review.map(\.status), [.new, .inPantry, .unknown], "an unknown status never crashes")
        XCTAssertEqual(finished.review.last?.confidence, .unknown)
        XCTAssertEqual(StubURLProtocol.requests.count, 4)
    }

    func testTokenRequestCarriesTheBasketAndADemoAnswerDecodes() async throws {
        let demoJSON = """
        {"token":null,"model":"gemini-3.8-live","expires_at":null,"new_session_expires_at":null,"max_session_seconds":30,
         "nudge_text":"Report any new items now visible.","nudge_every_frames":2,"frame_max_fps":1.0,"demo":true,
         "ai_notice":{"reason":"user_live_daily_cap","message":"Today's live scan allowance is used up"}}
        """
        StubURLProtocol.install { request in (.stub(request, status: 200), Data(demoJSON.utf8)) }
        let long = String(repeating: "a", count: 80)
        let token = try await makeClient().liveScanToken(alreadyInBasket: ["eggs", long])
        XCTAssertTrue(token.demo)
        XCTAssertEqual(token.token, "")
        XCTAssertEqual(token.maxSessionSeconds, 30)
        let names = try XCTUnwrap(try StubURLProtocol.requests[0].jsonBody()["already_in_basket"] as? [String])
        XCTAssertEqual(names, ["eggs", String(repeating: "a", count: 60)])

        let missing = demoJSON.replacingOccurrences(of: #""demo":true"#, with: #""demo":false"#)
        XCTAssertThrowsError(try JSONCoding.makeDecoder().decode(LiveScanToken.self, from: Data(missing.utf8)),
                             "a real token without a token is not usable")
    }
}
