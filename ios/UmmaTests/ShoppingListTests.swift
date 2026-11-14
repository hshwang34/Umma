import Foundation
import XCTest
@testable import Umma

final class FakeShoppingService: ShoppingService, @unchecked Sendable {
    enum Call: Equatable {
        case list
        case add(String, ShoppingReason, UUID?)
        case check(UUID)
        case uncheck(UUID)
        case delete(UUID)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    var listHandler: @Sendable () throws -> [ShoppingItem] = { [] }
    var addHandler: @Sendable (String) throws -> ShoppingItem = { ShoppingFixtures.item(id: UUID(), name: $0, reason: "manual") }
    var checkHandler: @Sendable (UUID) throws -> ShoppingItem = {
        ShoppingFixtures.item(id: $0, checkedAt: "2026-11-14T10:00:00Z", checkedBy: "user")
    }
    var uncheckHandler: @Sendable (UUID) throws -> ShoppingItem = { ShoppingFixtures.item(id: $0) }
    var deleteHandler: @Sendable (UUID) throws -> Void = { _ in }

    func shoppingList() async throws -> [ShoppingItem] { record(.list); return try listHandler() }
    func addShoppingItem(name: String, reason: ShoppingReason, recipeVersionId: UUID?) async throws -> ShoppingItem {
        record(.add(name, reason, recipeVersionId)); return try addHandler(name)
    }
    func checkShoppingItem(id: UUID) async throws -> ShoppingItem { record(.check(id)); return try checkHandler(id) }
    func uncheckShoppingItem(id: UUID) async throws -> ShoppingItem { record(.uncheck(id)); return try uncheckHandler(id) }
    func deleteShoppingItem(id: UUID) async throws { record(.delete(id)); try deleteHandler(id) }
}

/// Brief 017 PR 8: the Shopping list screen, the finish summary, and the key-ingredient card's add.
@MainActor
final class ShoppingListTests: XCTestCase {
    private let milk = ShoppingFixtures.milkId
    private let eggs = ShoppingFixtures.eggsId

    private func loaded(_ service: FakeShoppingService) async -> ShoppingListViewModel {
        let eggs = eggs
        service.listHandler = {
            [ShoppingFixtures.item(), ShoppingFixtures.item(id: eggs, name: "eggs", reason: "ran_out",
                                                            checkedAt: "2026-11-14T10:00:00Z", checkedBy: "receipt")]
        }
        let model = ShoppingListViewModel(service: service)
        await model.load()
        return model
    }

    func testRowsShowTheServersOrderAndState() async {
        let model = await loaded(FakeShoppingService())
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.rows.map(\.name), ["milk", "eggs"])
        XCTAssertEqual(model.rows.map(\.isChecked), [false, true])
        XCTAssertEqual(model.rows.map(\.detail), ["Missing for a recipe", "Bought. Ticked off by a receipt"])
        XCTAssertEqual(model.summary, "1 item to buy")
        XCTAssertEqual(model.rows[0].accessibilityLabel, "milk, Missing for a recipe, To buy")
    }

    func testAddSendsTheTypedNameOnceAndClearsTheField() async {
        let service = FakeShoppingService()
        let model = await loaded(service)
        XCTAssertFalse(model.canAdd)
        model.newName = "  olive   oil "
        XCTAssertTrue(model.canAdd)
        await model.add()
        XCTAssertEqual(service.calls.last, .add("olive oil", .manual, nil))
        XCTAssertEqual(model.rows.map(\.name), ["milk", "eggs", "olive oil"])
        XCTAssertEqual(model.newName, "")
        XCTAssertNil(model.rows[2].detail)
    }

    func testAddingANameAlreadyOnTheListDoesNotAddASecondRow() async {
        let service = FakeShoppingService()
        service.addHandler = { _ in ShoppingFixtures.item() }
        let model = await loaded(service)
        model.newName = "Milk"
        await model.add()
        XCTAssertEqual(model.rows.map(\.name), ["milk", "eggs"])
    }

    func testTickAndUntickFollowTheRowState() async {
        let service = FakeShoppingService()
        let model = await loaded(service)
        await model.toggle(id: milk)
        XCTAssertEqual(service.calls.last, .check(milk))
        XCTAssertEqual(model.rows[0].detail, "Bought")
        XCTAssertEqual(model.summary, "Everything is ticked off")
        await model.toggle(id: milk)
        XCTAssertEqual(service.calls.last, .uncheck(milk))
        XCTAssertFalse(model.rows[0].isChecked)
        await model.toggle(id: eggs)
        XCTAssertEqual(service.calls.last, .uncheck(eggs), "a receipt's tick can be undone by hand")
    }

    func testDeleteRemovesTheRowAndAFailureKeepsIt() async {
        let service = FakeShoppingService()
        let model = await loaded(service)
        await model.delete(id: milk)
        XCTAssertEqual(service.calls.last, .delete(milk))
        XCTAssertEqual(model.rows.map(\.name), ["eggs"])
        service.deleteHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        await model.delete(id: eggs)
        XCTAssertEqual(model.rows.map(\.name), ["eggs"])
        XCTAssertTrue(model.actionError?.hasPrefix("Couldn’t delete eggs:") ?? false)
    }

    func testEmptyAndFailedLoads() async {
        let service = FakeShoppingService()
        let empty = ShoppingListViewModel(service: service)
        await empty.load()
        XCTAssertEqual(empty.summary, "Nothing on your list")
        service.listHandler = { throw APIError.http(status: 500, correlationId: nil) }
        let failed = ShoppingListViewModel(service: service)
        await failed.load()
        if case .error = failed.phase {} else { XCTFail("expected the error state") }
    }

    // MARK: - Finish screen

    func testFinishSummaryCountsWhatWasAdded() {
        XCTAssertNil(ShoppingAddedSummary(names: []))
        XCTAssertEqual(ShoppingAddedSummary(names: ["honey"])?.title, "Added to your shopping list: 1 item")
        let four = ShoppingAddedSummary(names: ["a", "b", "c", "d"])
        XCTAssertEqual(four?.title, "Added to your shopping list: 4 items")
        XCTAssertEqual(four?.names, ["a", "b", "c", "d"])
    }

    func testCompletingACookKeepsWhatWentOnTheShoppingList() async throws {
        let service = FakeCookingService()
        let active = try CookingFixtures.session(stepIndex: 6, revision: 9)
        let json = try CookingFixtures.sessionJSON(status: "completed", stepIndex: 6, revision: 10)
        let end = try XCTUnwrap(json.lastIndex(of: "}"))
        let completed = try CookingFixtures.decode(CookingSession.self, String(json[..<end]) + #","shopping_added":["soy sauce","honey"]}"#)
        service.sessionHandler = { _ in active }
        service.commandHandler = { _, _ in completed }
        let model = CookingViewModel(sessionId: CookingFixtures.sessionUUID, service: service, audio: FakeAudioOutput())
        await model.load()
        XCTAssertNil(model.shoppingSummary)
        let endModel = SessionEndViewModel(cooking: model)
        endModel.result = OutcomeResult.allCases[0]
        let done = await endModel.finish()
        XCTAssertTrue(done)
        XCTAssertEqual(endModel.shoppingSummary?.title, "Added to your shopping list: 2 items")
        XCTAssertEqual(endModel.shoppingSummary?.names, ["soy sauce", "honey"])
    }

    // MARK: - Key-ingredient card

    func testIDontHaveThatAlsoPutsTheKeyIngredientOnTheShoppingList() async throws {
        let pantry = FakePantryService()
        let shopping = FakeShoppingService()
        let versionId = UUID(uuidString: PantryFixtures.versionId)!
        let json = TestBox(Self.keyFitJSON(inPantry: true))
        pantry.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json.value) }
        let model = PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "T", service: pantry, shopping: shopping)
        await model.load()
        XCTAssertTrue(shopping.calls.isEmpty)
        await model.removeKeyIngredient()
        XCTAssertEqual(shopping.calls, [.add("Chicken thighs", .ranOut, versionId)])
        json.value = Self.keyFitJSON(inPantry: false)
        await model.load()
        XCTAssertEqual(model.keyIngredient?.detail, "It’s on your shopping list now. You can look for a swap for tonight.")
    }

    func testAFailedShoppingAddStillRemovesAndSaysSo() async throws {
        let pantry = FakePantryService()
        let shopping = FakeShoppingService()
        shopping.addHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let json = Self.keyFitJSON(inPantry: true)
        pantry.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json) }
        let model = PantryFitViewModel(recipeVersionId: UUID(uuidString: PantryFixtures.versionId)!, recipeTitle: "T",
                                       service: pantry, shopping: shopping)
        var changed = 0
        model.onPantryChanged = { changed += 1 }
        await model.load()
        await model.removeKeyIngredient()
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(model.actionError?.hasPrefix("Removed Chicken thighs, but couldn’t add it to your shopping list:") ?? false)
    }

    func testTheInCookSwapOfferIsNotBuiltYet() {
        XCTAssertFalse(MissingIngredientOffer.isAvailable)
    }

    private static func keyFitJSON(inPantry: Bool) -> String {
        let item = inPantry ? "\"\(PantryFixtures.gochujangId)\"" : "null"
        let seen = inPantry ? "\"2026-11-08T09:00:00Z\"" : "null"
        return """
        {"recipe_version_id":"\(PantryFixtures.versionId)","can_make":false,"coverage":0.5,
         "counts":{"available":1,"uncertain":0,"missing":0,"optional_missing":0},
         "items":[{"ingredient_ref":"ing-1","name":"Chicken thighs","optional":false,"status":"\(inPantry ? "available" : "missing")",
                   "reason":"r","required":null,"pantry_item_id":\(item),"pantry_quantity":null,"conversion_note":null,
                   "is_key":true,"last_confirmed_at":\(seen)}],
         "computed_at":"2026-11-14T12:00:00Z"}
        """
    }
}
