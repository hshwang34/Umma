import Foundation
import XCTest
@testable import Umma

final class FakeReceiptService: ReceiptService, @unchecked Sendable {
    private let lock = NSLock()
    private var _undone: [UUID] = []
    private var _photos: [PantryPhotoUpload] = []
    var undone: [UUID] { lock.withLock { _undone } }
    var photos: [PantryPhotoUpload] { lock.withLock { _photos } }
    var readHandler: @Sendable (PantryPhotoUpload) throws -> ReceiptResult = { _ in ReceiptResult(receiptId: nil) }
    var undoHandler: @Sendable (UUID) throws -> ReceiptUndoResult = { ReceiptUndoResult(receiptId: $0) }

    func readReceipt(_ photo: PantryPhotoUpload) async throws -> ReceiptResult {
        lock.withLock { _photos.append(photo) }
        return try readHandler(photo)
    }

    func undoReceipt(id: UUID) async throws -> ReceiptUndoResult {
        lock.withLock { _undone.append(id) }
        return try undoHandler(id)
    }
}

enum ReceiptFixtures {
    static let receiptId = UUID(uuidString: "3f2b6c1e-9d4a-4f6e-8b1a-7c5d2e9f0a11")!

    static var resultJSON: String {
        #"{"receipt_id":"\#(receiptId.uuidString.lowercased())","duplicate":false,"demo":false,"purchased_on":"2026-11-12","# +
        #""store":"Trader Joe's","added":["# + PantryFixtures.itemJSON(raw: "Milk", normalized: "milk", source: "receipt") +
        #"],"merged":["# + PantryFixtures.itemJSON(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion", source: "voice") +
        #"],"skipped":[{"raw_text":"CHKN THGH BNLS","reason":"unknown_item"},{"raw_text":"??? 2.99","reason":"unreadable"}],"# +
        #""would_add":[],"shopping_checked":["milk"]}"#
    }

    static func result() throws -> ReceiptResult { try PantryFixtures.decode(ReceiptResult.self, resultJSON) }
}

/// Brief 017 PR 3: the receipt endpoints, the result banner, and whole-receipt Undo.
@MainActor
final class ReceiptTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])

    // MARK: - API

    func testReceiptEndpointsSendAndDecodeTheContract() async throws {
        let id = ReceiptFixtures.receiptId.uuidString.lowercased()
        StubURLProtocol.install { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/v1/pantry/receipts"):
                return (.stub(request, status: 200), Data(ReceiptFixtures.resultJSON.utf8))
            case ("POST", "/v1/pantry/receipts/\(id)/undo"):
                return (.stub(request, status: 200), Data(#"{"receipt_id":"\#(id)","removed":1,"restored":1,"unchanged":["eggs"]}"#.utf8))
            default:
                return (.stub(request, status: 404), Data())
            }
        }
        let client = APIClient(session: StubURLProtocol.makeSession(),
                               baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                               tokenProvider: InMemoryTokenStore(token: "tok"))
        let result = try await client.readReceipt(PantryPhotoUpload(jpegData: jpeg, pixelWidth: 10, pixelHeight: 10))
        XCTAssertEqual(result.receiptId, ReceiptFixtures.receiptId)
        XCTAssertEqual(result.added.map(\.source), [.receipt])
        XCTAssertEqual(result.added.first?.source.badge, "From receipt")
        XCTAssertEqual(result.merged.map(\.rawLabel), ["Onions"])
        XCTAssertEqual(result.skipped.map(\.rawText), ["CHKN THGH BNLS", "??? 2.99"])
        XCTAssertEqual(result.shoppingChecked, ["milk"])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let raw = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(readAll))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"image\"; filename=\"receipt.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertFalse(text.contains("name=\"mode\""), "the receipt endpoint takes the image only")
        XCTAssertNotNil(raw.range(of: jpeg))

        let undone = try await client.undoReceipt(id: ReceiptFixtures.receiptId)
        XCTAssertEqual(undone, ReceiptUndoResult(receiptId: ReceiptFixtures.receiptId, removed: 1, restored: 1, unchanged: ["eggs"]))
    }

    func testResultToleratesMissingKeys() throws {
        let result = try PantryFixtures.decode(ReceiptResult.self, #"{"receipt_id":null,"purchased_on":null,"store":null}"#)
        XCTAssertEqual(result, ReceiptResult(receiptId: nil))
    }

    func testFlagIsOffByDefaultAndGatesTheMenu() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "receipt.\(UUID().uuidString)"))
        XCTAssertFalse(CaptureFeatureFlags.load(from: defaults).receipt)
        XCTAssertFalse(CaptureFeatureFlags.allOn.receipt)
        defaults.set(true, forKey: "feature.capture.receipt")
        XCTAssertTrue(CaptureFeatureFlags.load(from: defaults).receipt)
        XCTAssertEqual(PantryScanOption.options(liveScan: false, receipt: true), [.photo, .receipt])
        XCTAssertEqual(PantryScanOption.options(liveScan: true, receipt: true), [.liveScan, .photo, .receipt])
        XCTAssertEqual(PantryScanOption.options(liveScan: false, receipt: false), [.photo])
    }

    // MARK: - Banner

    func testBannerSaysWhatWasAddedAndWhatWasNotRead() throws {
        let banner = ReceiptBannerPresentation(try ReceiptFixtures.result())
        XCTAssertEqual(banner.title, "Added 1 item from your receipt")
        XCTAssertEqual(banner.details, ["1 item you already had was refreshed", "Ticked 1 item off your shopping list", "2 lines not read"])
        XCTAssertEqual(banner.skippedLines, ["CHKN THGH BNLS", "??? 2.99"])
        XCTAssertNil(banner.moreSkippedText)
        XCTAssertEqual(banner.undoReceiptId, ReceiptFixtures.receiptId)
        XCTAssertTrue(banner.canUndo)
        XCTAssertEqual(ReceiptBannerPresentation.addedTitle(12), "Added 12 items from your receipt")
    }

    func testBannerForARepeatADemoAndNothingRead() {
        let repeated = ReceiptBannerPresentation(ReceiptResult(receiptId: ReceiptFixtures.receiptId, duplicate: true))
        XCTAssertEqual(repeated.title, "You’ve already added this receipt")
        XCTAssertEqual(repeated.details, ["Nothing changed."])
        XCTAssertFalse(repeated.canUndo)

        let demo = ReceiptBannerPresentation(ReceiptResult(receiptId: nil, demo: true,
                                                           wouldAdd: [ReceiptWouldAdd(name: "milk"), ReceiptWouldAdd(name: "eggs")]))
        XCTAssertEqual(demo.title, "Demo receipt. Nothing was saved")
        XCTAssertEqual(demo.details, ["A real receipt like this would add: milk, eggs"])
        XCTAssertTrue(demo.isDemo)
        XCTAssertFalse(demo.canUndo)

        let lines = (1...8).map { ReceiptSkippedLine(rawText: "LINE \($0)", reason: "unreadable") }
        let nothing = ReceiptBannerPresentation(ReceiptResult(receiptId: nil, skipped: lines))
        XCTAssertEqual(nothing.title, "Nothing was added from that receipt")
        XCTAssertEqual(nothing.details.last, "8 lines not read")
        XCTAssertEqual(nothing.skippedLines.count, 6)
        XCTAssertEqual(nothing.moreSkippedText, "and 2 more")
        XCTAssertFalse(nothing.canUndo)
    }

    func testUndoneBanner() {
        let undone = ReceiptBannerPresentation(undone: ReceiptUndoResult(receiptId: ReceiptFixtures.receiptId, removed: 3,
                                                                         restored: 1, unchanged: ["eggs", "milk"]))
        XCTAssertEqual(undone.title, "Receipt undone")
        XCTAssertEqual(undone.details, ["Removed 3 items", "1 item put back as it was",
                                        "Left alone because you changed them since: eggs, milk"])
        XCTAssertFalse(undone.canUndo)
    }

    // MARK: - Pantry list

    func testReceiptItemsJoinTheListWithTheirChip() throws {
        let model = PantryViewModel(service: FakePantryService(), receipts: FakeReceiptService())
        var changed = 0
        model.onChanged = { changed += 1 }
        model.noteReceipt(try ReceiptFixtures.result())
        XCTAssertEqual(model.rows.map(\.name), ["Milk", "Onions"])
        XCTAssertEqual(model.rows.map(\.badge), ["From receipt", "Voice"], "a rebought item keeps its own source")
        XCTAssertEqual(model.receiptBanner?.title, "Added 1 item from your receipt")
        XCTAssertEqual(changed, 1)
    }

    func testUndoIsOnlyOnTapAndRereadsThePantry() async throws {
        let pantry = FakePantryService()
        let onion = PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion")
        pantry.listHandler = { [onion] }
        let receipts = FakeReceiptService()
        receipts.undoHandler = { ReceiptUndoResult(receiptId: $0, removed: 1, restored: 1) }
        let model = PantryViewModel(service: pantry, receipts: receipts)
        model.noteReceipt(try ReceiptFixtures.result())
        XCTAssertTrue(receipts.undone.isEmpty, "nothing is undone until the cook taps")
        await model.undoReceipt()
        XCTAssertEqual(receipts.undone, [ReceiptFixtures.receiptId])
        XCTAssertEqual(model.items.map(\.rawLabel), ["Onions"])
        XCTAssertEqual(model.receiptBanner?.title, "Receipt undone")
        await model.undoReceipt()
        XCTAssertEqual(receipts.undone.count, 1, "a receipt is undone once")
        model.dismissReceiptBanner()
        XCTAssertNil(model.receiptBanner)
    }

    func testAFailedUndoKeepsTheBannerAndSaysSo() async throws {
        let receipts = FakeReceiptService()
        receipts.undoHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let model = PantryViewModel(service: FakePantryService(), receipts: receipts)
        model.noteReceipt(try ReceiptFixtures.result())
        await model.undoReceipt()
        XCTAssertTrue(model.receiptBanner?.canUndo ?? false)
        XCTAssertTrue(model.actionError?.hasPrefix("Couldn’t undo the receipt:") ?? false)
        XCTAssertEqual(model.items.count, 2)
    }

    func testADemoOrRepeatChangesNothingInTheList() {
        let model = PantryViewModel(service: FakePantryService(), receipts: FakeReceiptService())
        var changed = 0
        model.onChanged = { changed += 1 }
        model.noteReceipt(ReceiptResult(receiptId: nil, demo: true, wouldAdd: [ReceiptWouldAdd(name: "milk")]))
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(model.receiptBanner?.isDemo, true)
    }

    // MARK: - Capture

    func testReceiptModeSendsThePhotoToTheReceiptReaderAndDropsIt() async throws {
        let pantry = FakePantryService()
        let receipts = FakeReceiptService()
        let expected = try ReceiptFixtures.result()
        receipts.readHandler = { _ in expected }
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: pantry, receipts: receipts,
                                         encode: { PantryPhotoUpload(jpegData: $0, pixelWidth: 1, pixelHeight: 1) })
        XCTAssertEqual(model.copy, .receipt)
        XCTAssertEqual(model.copy.submitTitle, "Read receipt")
        await model.usePickedPhoto(jpeg)
        await model.findItems()
        XCTAssertEqual(receipts.photos.map(\.jpegData), [jpeg])
        XCTAssertTrue(pantry.calls.isEmpty, "a receipt never goes to the shelf-scan endpoint")
        XCTAssertEqual(model.receipt, expected)
        XCTAssertNil(model.observation)
        XCTAssertNil(model.photoData, "the photo is not kept after the request")
        XCTAssertEqual(ScanCaptureViewModel(camera: FakeCameraSource(), service: pantry).copy, .shelf)
    }

    func testAFailedReceiptReadKeepsThePhotoForRetry() async {
        let receipts = FakeReceiptService()
        receipts.readHandler = { _ in throw APIError.server(status: 503, code: "PROVIDER_UNAVAILABLE", message: "x",
                                                            retryable: true, correlationId: nil) }
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), receipts: receipts,
                                         encode: { PantryPhotoUpload(jpegData: $0, pixelWidth: 1, pixelHeight: 1) })
        await model.usePickedPhoto(jpeg)
        await model.findItems()
        XCTAssertNil(model.receipt)
        XCTAssertTrue(model.canRetry)
        XCTAssertNotNil(model.photoData)
    }
}
