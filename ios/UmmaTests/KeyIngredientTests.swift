import Foundation
import XCTest
@testable import Umma

/// Brief 017 PR 5: the key-ingredient card on Pantry fit.
@MainActor
final class KeyIngredientTests: XCTestCase {
    private let versionId = UUID(uuidString: PantryFixtures.versionId)!
    private let chickenId = UUID(uuidString: PantryFixtures.gochujangId)!
    private let now = ISO8601Flexible.parse("2026-11-14T12:00:00Z")!

    private func fitJSON(pantryItem: Bool = true, seen: String? = "2026-11-08T09:00:00Z", status: String = "available") -> String {
        let item = pantryItem ? "\"\(PantryFixtures.gochujangId)\"" : "null"
        let confirmed = seen.map { "\"\($0)\"" } ?? "null"
        return """
        {"recipe_version_id":"\(PantryFixtures.versionId)","can_make":false,"coverage":0.5,
         "counts":{"available":1,"uncertain":0,"missing":1,"optional_missing":0},
         "key_ingredient_ref":"ing-1",
         "items":[
           {"ingredient_ref":"ing-1","name":"Chicken thighs","optional":false,"status":"\(status)","reason":"r",
            "required":null,"pantry_item_id":\(item),"pantry_quantity":null,"conversion_note":null,
            "is_key":true,"last_confirmed_at":\(confirmed)},
           {"ingredient_ref":"ing-2","name":"soy sauce","optional":false,"status":"missing","reason":"Not in your pantry.",
            "required":null,"pantry_item_id":null,"pantry_quantity":null,"conversion_note":null,"is_key":false,"last_confirmed_at":null}
         ],
         "computed_at":"2026-11-14T12:00:00Z"}
        """
    }

    private func fit(_ json: String) throws -> PantryFit { try PantryFixtures.decode(PantryFit.self, json) }

    private func makeModel(_ service: FakePantryService, cooking: CookingService? = nil) -> PantryFitViewModel {
        let now = now
        return PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "Gochujang Chicken", service: service,
                                  cooking: cooking, now: { now })
    }

    func testCardAsksAboutTheKeyIngredientWithWhenItWasLastSeen() throws {
        let card = try XCTUnwrap(KeyIngredientCard(fit: try fit(fitJSON()), now: now, swapsEnabled: true))
        XCTAssertEqual(card.state, .ask)
        XCTAssertEqual(card.title, "Do you still have chicken thighs?")
        XCTAssertEqual(card.detail, "The main ingredient of this dish. Last seen 6 days ago.")
        XCTAssertEqual(card.pantryItemId, chickenId)
        XCTAssertFalse(card.canFindSwap)
        XCTAssertEqual(KeyIngredientCard.lastSeen(1), "Last seen yesterday")
    }

    func testSeenTodayDoesNotAskAgain() throws {
        let card = try XCTUnwrap(KeyIngredientCard(fit: try fit(fitJSON(seen: "2026-11-14T08:00:00Z")), now: now, swapsEnabled: true))
        XCTAssertEqual(card.state, .seenToday)
        XCTAssertEqual(card.title, "You have chicken thighs")
        XCTAssertEqual(card.detail, "The main ingredient of this dish. Last seen today.")
    }

    func testKeyIngredientNotInThePantryOffersASwap() throws {
        let missing = try fit(fitJSON(pantryItem: false, seen: nil, status: "missing"))
        let card = try XCTUnwrap(KeyIngredientCard(fit: missing, now: now, swapsEnabled: true))
        XCTAssertEqual(card.state, .notInPantry)
        XCTAssertEqual(card.title, "No chicken thighs in your pantry")
        XCTAssertTrue(card.canFindSwap)
        XCTAssertFalse(try XCTUnwrap(KeyIngredientCard(fit: missing, now: now, swapsEnabled: false)).canFindSwap)
    }

    func testNoCardWhenTheServerNamesNoKeyIngredient() throws {
        let old = try fit(PantryFixtures.fitJSON)
        XCTAssertNil(old.items[0].isKey, "an older server sends no is_key")
        XCTAssertNil(KeyIngredientCard(fit: old, now: now, swapsEnabled: true))
    }

    func testStillHaveItConfirmsAndRemovesNothing() async throws {
        let service = FakePantryService()
        let json = fitJSON()
        service.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json) }
        service.confirmHandler = { _ in PantryFixtures.item() }
        let model = makeModel(service)
        var changed = 0
        model.onPantryChanged = { changed += 1 }
        await model.load()
        let card = try XCTUnwrap(model.keyIngredient)
        await model.confirmStillHave(pantryItemId: try XCTUnwrap(card.pantryItemId))
        XCTAssertTrue(service.calls.contains(.confirm(chickenId)))
        XCTAssertFalse(service.calls.contains(.delete(chickenId)))
        XCTAssertEqual(changed, 1)
    }

    func testIDontHaveThatRemovesThePantryItemOnlyOnThatTap() async throws {
        let service = FakePantryService()
        let json = TestBox(fitJSON())
        service.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json.value) }
        let model = makeModel(service)
        var changed = 0
        model.onPantryChanged = { changed += 1 }
        await model.load()
        XCTAssertFalse(service.calls.contains(.delete(chickenId)), "loading the screen removes nothing")

        await model.removeKeyIngredient()
        XCTAssertEqual(service.calls.filter { $0 == .delete(chickenId) }.count, 1)
        XCTAssertEqual(changed, 1)

        // The revision bump re-reads the fit: the item is gone, and the card says what happened.
        json.value = fitJSON(pantryItem: false, seen: nil, status: "missing")
        await model.load()
        let card = try XCTUnwrap(model.keyIngredient)
        XCTAssertEqual(card.state, .notInPantry)
        XCTAssertEqual(card.title, "Removed chicken thighs from your pantry")
        await model.removeKeyIngredient()
        XCTAssertEqual(service.calls.filter { $0 == .delete(chickenId) }.count, 1, "nothing left to remove")
    }

    func testRemovedTextIsDroppedOnALaterReload() async throws {
        let service = FakePantryService()
        let json = TestBox(fitJSON())
        service.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json.value) }
        let model = makeModel(service)
        await model.load()
        await model.removeKeyIngredient()
        json.value = fitJSON(pantryItem: false, seen: nil, status: "missing")
        await model.load()
        XCTAssertEqual(model.keyIngredient?.title, "Removed chicken thighs from your pantry", "shown through the reload the tap caused")

        await model.load()
        XCTAssertEqual(model.keyIngredient?.title, "No chicken thighs in your pantry", "a later reload no longer says it was just removed")
    }

    func testRemovedTextIsDroppedWhenTheIngredientIsBack() async throws {
        let service = FakePantryService()
        let json = TestBox(fitJSON())
        service.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json.value) }
        let model = makeModel(service)
        await model.load()
        await model.removeKeyIngredient()
        // The reload finds it in the pantry again (added back elsewhere), then it goes missing later.
        await model.load()
        XCTAssertEqual(model.keyIngredient?.state, .ask)
        json.value = fitJSON(pantryItem: false, seen: nil, status: "missing")
        await model.load()
        XCTAssertEqual(model.keyIngredient?.title, "No chicken thighs in your pantry")
    }

    func testAFailedRemoveSaysSoAndKeepsTheCard() async throws {
        let service = FakePantryService()
        let json = fitJSON()
        service.fitHandler = { _ in try PantryFixtures.decode(PantryFit.self, json) }
        service.deleteHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let model = makeModel(service)
        var changed = 0
        model.onPantryChanged = { changed += 1 }
        await model.load()
        await model.removeKeyIngredient()
        XCTAssertTrue(model.actionError?.hasPrefix("Couldn’t remove Chicken thighs:") ?? false)
        XCTAssertEqual(model.keyIngredient?.state, .ask)
        XCTAssertEqual(changed, 0)
    }
}
