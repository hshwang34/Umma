import Foundation
import XCTest
@testable import Umma

/// Brief 020. `servings_scaling.json` is a verbatim copy of the backend's
/// `fixtures/expected_outputs/servings_scaling.json`: the phone's dial and the backend's pantry
/// fit, sessions and coach must agree on every amount.
final class ServingsScalingTests: XCTestCase {
    private struct Contract: Decodable {
        struct Stops: Decodable {
            let originalServings: Int
            let stops: [Int]
        }
        struct Case: Decodable {
            let quantity: Double?
            let unit: String?
            let originalServings: Int
            let servings: Int
            let expected: Double?
        }
        let dialStops: [Stops]
        let cases: [Case]
    }

    private func contract() throws -> Contract { try Fixtures.decode(Contract.self, from: "servings_scaling") }

    func testEveryContractCaseMatchesTheBackend() throws {
        let cases = try contract().cases
        XCTAssertEqual(cases.count, 40, "the whole shared file is checked")
        for item in cases {
            let scaled = ServingsScaling.scale(item.quantity, unit: item.unit,
                                               originalServings: item.originalServings, servings: item.servings)
            XCTAssertEqual(scaled, item.expected,
                           "\(String(describing: item.quantity)) \(item.unit ?? "nil") from \(item.originalServings) to \(item.servings)")
        }
    }

    func testDialStopsMatchTheBackend() throws {
        let stops = try contract().dialStops
        XCTAssertFalse(stops.isEmpty)
        for item in stops {
            XCTAssertEqual(ServingsScaling.dialStops(originalServings: item.originalServings), item.stops)
        }
        XCTAssertTrue(ServingsScaling.isValid(servings: 8, originalServings: 8))
        XCTAssertFalse(ServingsScaling.isValid(servings: 7, originalServings: 8))
        XCTAssertFalse(ServingsScaling.isValid(servings: 0, originalServings: 4))
    }

    func testOriginalServingsAndToTasteAreUntouched() {
        XCTAssertEqual(ServingsScaling.scale(0.17, unit: "tsp", originalServings: 4, servings: 4), 0.17, "exactly what the creator wrote")
        XCTAssertNil(ServingsScaling.scale(nil, unit: "tsp", originalServings: 4, servings: 1), "to taste stays to taste")
        XCTAssertNil(ServingsScaling.scale(nil, unit: nil, originalServings: 4, servings: 6))
    }

    func testNothingScalesToZero() {
        for unit in ["g", "ml", "tsp", "tbsp", "cup", "kg", "clove", nil] as [String?] {
            for original in [4, 6, 12] {
                let scaled = ServingsScaling.scale(0.1, unit: unit, originalServings: original, servings: 1)
                XCTAssertGreaterThan(try XCTUnwrap(scaled), 0, "\(unit ?? "count") from \(original)")
            }
        }
    }

    func testScaledAmountsReadAsKitchenFractions() {
        func shown(_ quantity: Double, _ unit: String, to servings: Int) -> String? {
            RecipeFormatting.quantity(ServingsScaling.scale(quantity, unit: unit, originalServings: 4, servings: servings), unit: unit)
        }
        XCTAssertEqual(shown(400, "g", to: 2), "200 g")
        XCTAssertEqual(shown(2, "tbsp", to: 2), "1 tbsp")
        XCTAssertEqual(shown(1, "tsp", to: 1), "¼ tsp")
        XCTAssertEqual(shown(0.5, "tsp", to: 1), "⅛ tsp")
        XCTAssertEqual(shown(1, "cup", to: 3), "¾ cup")
        XCTAssertEqual(shown(2, "cup", to: 5), "2½ cup")
        XCTAssertEqual(shown(1, "cup", to: 5), "1¼ cup")
        XCTAssertEqual(RecipeFormatting.number(0.333), "⅓")
        XCTAssertEqual(RecipeFormatting.number(1.667), "1⅔")
    }

    // MARK: The dial

    func testDialOpensAtTheRecipesOwnServings() throws {
        let dial = try XCTUnwrap(ServingsDial(original: 4))
        XCTAssertEqual(dial.servings, 4)
        XCTAssertEqual(dial.label, "Serves 4")
        XCTAssertEqual(dial.stops, [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(dial.isScaled)
        XCTAssertNil(dial.scaledFromText)
        XCTAssertNil(dial.notice)
        XCTAssertNil(dial.resetTitle)
        XCTAssertEqual(dial.accessibilityValue, "4 servings")
        XCTAssertEqual(dial.lower, 3)
        XCTAssertEqual(dial.higher, 5)
    }

    func testScaledDialSaysSoAndOffersReset() throws {
        let dial = try XCTUnwrap(ServingsDial(original: 4, chosen: 1))
        XCTAssertEqual(dial.label, "Serves 1")
        XCTAssertEqual(dial.scaledFromText, "Scaled from 4")
        XCTAssertEqual(dial.notice, "Cooking times, pan sizes and step text aren’t scaled. Taste as you go.")
        XCTAssertEqual(dial.resetTitle, "Reset to 4")
        XCTAssertEqual(dial.accessibilityValue, "1 serving, scaled from 4")
        XCTAssertNil(dial.lower)
        XCTAssertEqual(dial.choice, ServingsChoice(servings: 1, original: 4))
    }

    func testRecipeForEightHasItsOriginalAsTheLastStop() throws {
        let dial = try XCTUnwrap(ServingsDial(original: 8))
        XCTAssertEqual(dial.stops, [1, 2, 3, 4, 5, 6, 8])
        XCTAssertEqual(dial.servings, 8, "opens at its original")
        XCTAssertEqual(dial.lower, 6)
        XCTAssertNil(dial.higher)
        XCTAssertEqual(ServingsDial(original: 8, chosen: 6)?.higher, 8)
        XCTAssertEqual(ServingsDial(original: 8, chosen: 7)?.servings, 8, "7 is not a stop")
        XCTAssertNil(ServingsDial(original: 0))
    }
}

@MainActor
final class RecipeServingsViewModelTests: XCTestCase {
    private func makeModel(servings: Int = 4) async throws -> RecipeDetailViewModel {
        let text = String(decoding: try Fixtures.data("recipe_detail"), as: UTF8.self)
            .replacingOccurrences(of: "\"servings\": 4", with: "\"servings\": \(servings)")
        let detail = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(text.utf8))
        XCTAssertEqual(detail.servings, servings)
        let service = FakeRecipeService()
        service.detailHandler = { _ in detail }
        let model = RecipeDetailViewModel(recipeId: detail.recipeId, service: service)
        XCTAssertNil(model.dial, "no control until the recipe has loaded")
        await model.load()
        return model
    }

    func testOpensWithTheCreatorsAmounts() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.dial?.servings, 4)
        XCTAssertEqual(model.ingredients, model.detail?.ingredients)
    }

    func testDialRescalesEveryAmountAtOnceAndResets() async throws {
        let model = try await makeModel()
        let detail = try XCTUnwrap(model.detail)
        model.setServings(2)
        XCTAssertEqual(model.dial?.scaledFromText, "Scaled from 4")
        XCTAssertEqual(model.ingredients.count, detail.ingredients.count)
        for (shown, written) in zip(model.ingredients, detail.ingredients) {
            XCTAssertEqual(shown.quantity, ServingsScaling.scale(written.quantity, unit: written.unit, originalServings: 4, servings: 2))
            XCTAssertEqual(shown.name, written.name)
            XCTAssertEqual(shown.unit, written.unit)
            XCTAssertEqual(shown.quantity == nil, written.quantity == nil, "to taste stays to taste")
        }
        XCTAssertEqual(model.ingredients.first?.quantity, 1, "2 lb chicken for 4 is 1 lb for 2")
        XCTAssertEqual(detail.ingredients.first?.quantity, 2, "the recipe itself is never changed")
        XCTAssertEqual(model.servings, 4, "the creator's servings stay the creator's")

        model.resetServings()
        XCTAssertEqual(model.dial?.isScaled, false)
        XCTAssertEqual(model.ingredients, detail.ingredients)
    }

    func testStepsThroughTheStopsAndIgnoresInvalidValues() async throws {
        let model = try await makeModel(servings: 8)
        model.stepServings(up: true)
        XCTAssertEqual(model.dial?.servings, 8, "already at the last stop")
        model.stepServings(up: false)
        XCTAssertEqual(model.dial?.servings, 6)
        model.stepServings(up: true)
        XCTAssertEqual(model.dial?.servings, 8)
        model.setServings(7)
        XCTAssertEqual(model.dial?.servings, 8)
        model.setServings(1)
        model.stepServings(up: false)
        XCTAssertEqual(model.dial?.servings, 1)
    }
}

@MainActor
final class PantryFitServingsTests: XCTestCase {
    private let versionId = UUID(uuidString: PantryFixtures.versionId)!

    private func makeModel(servings: ServingsChoice?, answered: Int? = nil) throws -> (PantryFitViewModel, FakePantryService) {
        let service = FakePantryService()
        var json = PantryFixtures.fitJSON
        if let answered { json = String(json.dropLast(1)) + #","servings":\#(answered)}"# }
        let fit = try PantryFixtures.decode(PantryFit.self, json)
        service.fitHandler = { _ in fit }
        return (PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "T", servings: servings, service: service), service)
    }

    func testFitIsAskedForTheServingsOnTheDial() async throws {
        let (model, service) = try makeModel(servings: ServingsChoice(servings: 2, original: 4), answered: 2)
        await model.load()
        XCTAssertEqual(service.fitServings, [2])
        XCTAssertEqual(model.servingsText, "For 2 servings · Scaled from 4")
    }

    func testNoChoiceAsksForTheRecipesOwn() async throws {
        let (model, service) = try makeModel(servings: nil)
        await model.load()
        XCTAssertEqual(service.fitServings, [nil])
        XCTAssertNil(model.servingsText)
    }

    func testUnscaledChoiceShowsNoScaledLine() async throws {
        let (model, service) = try makeModel(servings: ServingsChoice(servings: 4, original: 4), answered: 4)
        await model.load()
        XCTAssertEqual(service.fitServings, [4])
        XCTAssertNil(model.servingsText)
    }
}
