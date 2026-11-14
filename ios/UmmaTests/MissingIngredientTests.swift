import Foundation
import XCTest
@testable import Umma

private enum MissingFixtures {
    static let pantryItemId = PantryFixtures.gochujangId

    static func swapJSON(inPantry: Bool = true, allergy: String = "null", ref: String = "ing-3") -> String {
        """
        {"candidate":"tamari","ratio_or_amount":"2 tbsp","kind":"close_equivalent","in_pantry":\(inPantry),
         "risks":["Slightly less salty."],"allergy_warning":\(allergy),
         "adaptation":{"ingredient_ref":"\(ref)","replacement":"tamari","ratio_or_amount":"2 tbsp","source":"rule"}}
        """
    }

    static func offerJSON(swap: String? = swapJSON(), noSwap: String = "null", onList: Bool = false, inPantry: Bool = true) -> String {
        """
        {"status":"offer","ingredient_ref":"ing-3","name":"soy sauce","optional":false,"candidates":[],
         "swap":\(swap ?? "null"),"no_swap_reason":\(noSwap),"shopping_name":"soy sauce","on_shopping_list":\(onList),
         "pantry_item_id":\(inPantry ? "\"\(pantryItemId)\"" : "null"),"requires_confirmation":true}
        """
    }

    static let whichJSON = """
    {"status":"which","candidates":[{"ingredient_ref":"ing-2","name":"gochujang"},{"ingredient_ref":"ing-3","name":"soy sauce"}],
     "requires_confirmation":true}
    """

    static func askJSON(missing: String, messageId: String = CookingFixtures.messageId) -> String {
        let base = CookingFixtures.askJSON().replacingOccurrences(of: CookingFixtures.messageId, with: messageId)
        return String(base.dropLast(1)) + #","missing_ingredient":\#(missing)}"#
    }

    static func response(missing: String, messageId: String = CookingFixtures.messageId) throws -> AskResponse {
        try CookingFixtures.decode(AskResponse.self, askJSON(missing: missing, messageId: messageId))
    }

    static func missing(_ json: String) throws -> MissingIngredient {
        try CookingFixtures.decode(MissingIngredient.self, json)
    }
}

/// Brief 017 PR 8 (in-cook part): the coach's `missing_ingredient` offer.
final class MissingIngredientContractTests: XCTestCase {
    func testOfferDecodes() throws {
        let missing = try XCTUnwrap(try MissingFixtures.response(missing: MissingFixtures.offerJSON()).missingIngredient)
        XCTAssertEqual(missing.status, .offer)
        XCTAssertEqual(missing.name, "soy sauce")
        XCTAssertEqual(missing.shoppingName, "soy sauce")
        XCTAssertEqual(missing.pantryItemId, UUID(uuidString: MissingFixtures.pantryItemId))
        XCTAssertEqual(missing.swap?.candidate, "tamari")
        XCTAssertEqual(missing.swap?.inPantry, true)
        XCTAssertEqual(missing.swap?.adaptation,
                       AdaptationInput(ingredientRef: "ing-3", replacement: "tamari", ratioOrAmount: "2 tbsp", source: .rule))
    }

    func testWhichDecodesItsCandidates() throws {
        let missing = try MissingFixtures.missing(MissingFixtures.whichJSON)
        XCTAssertEqual(missing.status, .which)
        XCTAssertEqual(missing.candidates.map(\.name), ["gochujang", "soy sauce"])
        XCTAssertNil(missing.swap)
        XCTAssertNil(missing.pantryItemId)
    }

    func testAnswersWithoutAnOfferAndUnknownShapesStillDecode() throws {
        XCTAssertNil(try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON()).missingIngredient)
        XCTAssertNil(try MissingFixtures.response(missing: "null").missingIngredient)

        let future = try MissingFixtures.response(missing: #"{"status":"later","requires_confirmation":true}"#)
        XCTAssertEqual(future.missingIngredient?.status, .unknown)
        XCTAssertNil(MissingIngredientOffer(missing: try XCTUnwrap(future.missingIngredient), state: .init(), session: nil),
                     "an unknown status shows nothing rather than guessing")
        XCTAssertEqual(future.answerText.isEmpty, false)

        let garbled = try MissingFixtures.response(missing: #"{"candidates":"nope"}"#)
        XCTAssertNil(garbled.missingIngredient, "an unreadable offer is dropped; the answer survives")

        let badSwap = try MissingFixtures.missing(MissingFixtures.offerJSON(swap: #"{"candidate":"tamari"}"#))
        XCTAssertNil(badSwap.swap, "a swap without its adaptation is not offered")
        XCTAssertEqual(badSwap.name, "soy sauce")
    }
}

@MainActor
final class MissingIngredientOfferTests: XCTestCase {
    private func offer(_ json: String, state: MissingIngredientOffer.State = .init(), session: CookingSession? = nil) throws -> MissingIngredientOffer? {
        let session = try session ?? CookingFixtures.session(adapted: false)
        return MissingIngredientOffer(missing: try MissingFixtures.missing(json), state: state, session: session)
    }

    func testOfferShowsTheSwapAndThreeSeparateButtons() throws {
        let offer = try XCTUnwrap(try offer(MissingFixtures.offerJSON()))
        XCTAssertEqual(offer.swapTitle, "Swap: tamari")
        XCTAssertEqual(offer.swapAmount, "2 tbsp")
        XCTAssertEqual(offer.inPantryText, "In your pantry")
        XCTAssertEqual(offer.risks, ["Slightly less salty."])
        XCTAssertNil(offer.allergyWarning)
        XCTAssertEqual(offer.actions, [.useSwap, .addToShoppingList, .removeFromPantry])
        XCTAssertEqual(offer.actions.map(\.title), ["Use this swap", "Add to shopping list", "Remove from pantry"])
        XCTAssertTrue(offer.statuses.isEmpty)
        XCTAssertNil(offer.prompt)
    }

    func testAllergyWarningIsShownAndSwapNotInPantryIsNotMarked() throws {
        let offer = try XCTUnwrap(try offer(MissingFixtures.offerJSON(swap: MissingFixtures.swapJSON(inPantry: false, allergy: "\"contains soy\""))))
        XCTAssertEqual(offer.allergyWarning, "Check the label: contains soy")
        XCTAssertNil(offer.inPantryText)
        XCTAssertTrue(offer.actions.contains(.useSwap), "the cook still decides")
    }

    func testRemoveFromPantryOnlyWhenThePantryHoldsIt() throws {
        let offer = try XCTUnwrap(try offer(MissingFixtures.offerJSON(inPantry: false)))
        XCTAssertEqual(offer.actions, [.useSwap, .addToShoppingList])
    }

    func testNoSwapSaysWhyAndAlreadyListedIsAStatus() throws {
        let offer = try XCTUnwrap(try offer(MissingFixtures.offerJSON(swap: nil, noSwap: "\"Nothing in your pantry stands in for soy sauce.\"", onList: true)))
        XCTAssertNil(offer.swapTitle)
        XCTAssertEqual(offer.noSwapText, "Nothing in your pantry stands in for soy sauce.")
        XCTAssertEqual(offer.statuses, ["On your shopping list"])
        XCTAssertEqual(offer.actions, [.removeFromPantry])
    }

    func testSwapAlreadyOnTheSessionIsNotOfferedAgain() throws {
        let session = try CookingFixtures.session(adapted: true)
        let offer = try XCTUnwrap(try offer(MissingFixtures.offerJSON(swap: MissingFixtures.swapJSON(ref: "ing-8")), session: session))
        XCTAssertEqual(offer.statuses, ["Swap in use"])
        XCTAssertFalse(offer.actions.contains(.useSwap))
    }

    func testWhichShowsTheCandidatesAndNoButtons() throws {
        let offer = try XCTUnwrap(try offer(MissingFixtures.whichJSON))
        XCTAssertEqual(offer.prompt, "Which one don’t you have?")
        XCTAssertEqual(offer.candidates.map(\.name), ["gochujang", "soy sauce"])
        XCTAssertTrue(offer.actions.isEmpty)
        XCTAssertNil(try self.offer(MissingFixtures.whichJSON, state: .init(picked: true)))
    }
}

@MainActor
final class MissingIngredientViewModelTests: XCTestCase {
    private struct Rig {
        let model: AssistantViewModel
        let cooking: FakeCookingService
        let shopping: FakeShoppingService
        let pantry: FakePantryService
        let approved: TestBox<[AdaptationInput]>
        let approveResult: TestBox<Bool>
        let pantryChanges: TestBox<Int>
        let turnId: UUID
    }

    /// A drawer that has just received `missing` as the answer to "I don't have that".
    private func makeRig(missing: String = MissingFixtures.offerJSON()) async throws -> Rig {
        let cooking = FakeCookingService()
        let response = try MissingFixtures.response(missing: missing)
        cooking.askHandler = { _, _ in response }
        let shopping = FakeShoppingService()
        let pantry = FakePantryService()
        let session = try CookingFixtures.session(adapted: false)
        let model = AssistantViewModel(sessionId: session.id, service: cooking, audio: FakeAudioOutput(),
                                       shopping: shopping, pantry: pantry, currentSession: { session })
        let approved = TestBox<[AdaptationInput]>([])
        let approveResult = TestBox(true)
        let pantryChanges = TestBox(0)
        model.onApproveSwap = { adaptation in approved.value.append(adaptation); return approveResult.value }
        model.onPantryChanged = { pantryChanges.value += 1 }
        model.query = "I don't have that"
        await model.ask()
        let turn = try XCTUnwrap(model.turns.first)
        return Rig(model: model, cooking: cooking, shopping: shopping, pantry: pantry, approved: approved,
                   approveResult: approveResult, pantryChanges: pantryChanges, turnId: turn.id)
    }

    private func offer(_ rig: Rig) throws -> MissingIngredientOffer {
        try XCTUnwrap(rig.model.offer(for: try XCTUnwrap(rig.model.turns.first { $0.id == rig.turnId })))
    }

    func testNothingHappensUntilAButtonIsTapped() async throws {
        let rig = try await makeRig()
        XCTAssertEqual(try offer(rig).actions, [.useSwap, .addToShoppingList, .removeFromPantry])
        XCTAssertTrue(rig.approved.value.isEmpty)
        XCTAssertTrue(rig.shopping.calls.isEmpty)
        XCTAssertTrue(rig.pantry.calls.isEmpty)
        XCTAssertTrue(rig.cooking.commands.isEmpty)
    }

    func testUseThisSwapSendsExactlyTheOfferedAdaptationAndNothingElse() async throws {
        let rig = try await makeRig()
        await rig.model.perform(.useSwap, turnId: rig.turnId)
        XCTAssertEqual(rig.approved.value, [AdaptationInput(ingredientRef: "ing-3", replacement: "tamari", ratioOrAmount: "2 tbsp", source: .rule)])
        XCTAssertTrue(rig.shopping.calls.isEmpty, "the swap never touches the shopping list")
        XCTAssertTrue(rig.pantry.calls.isEmpty, "or the pantry")
        let after = try offer(rig)
        XCTAssertEqual(after.statuses, ["Swap in use"])
        XCTAssertEqual(after.actions, [.addToShoppingList, .removeFromPantry])

        await rig.model.perform(.useSwap, turnId: rig.turnId)
        XCTAssertEqual(rig.approved.value.count, 1, "a used swap can't be sent twice")
    }

    func testRefusedSwapLeavesTheOfferWithAnError() async throws {
        let rig = try await makeRig()
        rig.approveResult.value = false
        await rig.model.perform(.useSwap, turnId: rig.turnId)
        let after = try offer(rig)
        XCTAssertEqual(after.error, "That swap wasn’t applied. Nothing changed. Try again.")
        XCTAssertEqual(after.actions, [.useSwap, .addToShoppingList, .removeFromPantry])
        XCTAssertNil(after.busy)

        rig.approveResult.value = true
        await rig.model.perform(.useSwap, turnId: rig.turnId)
        XCTAssertNil(try offer(rig).error, "the error clears on the next try")
    }

    func testAddToShoppingListUsesTheServersName() async throws {
        let rig = try await makeRig()
        await rig.model.perform(.addToShoppingList, turnId: rig.turnId)
        XCTAssertEqual(rig.shopping.calls, [.add("soy sauce", .ranOut, CookingFixtures.versionUUID)])
        XCTAssertTrue(rig.pantry.calls.isEmpty)
        XCTAssertTrue(rig.approved.value.isEmpty)
        let after = try offer(rig)
        XCTAssertEqual(after.statuses, ["On your shopping list"])
        XCTAssertEqual(after.actions, [.useSwap, .removeFromPantry])
    }

    func testShoppingFailureKeepsTheButton() async throws {
        let rig = try await makeRig(missing: MissingFixtures.offerJSON(inPantry: false))
        rig.shopping.addHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        await rig.model.perform(.addToShoppingList, turnId: rig.turnId)
        XCTAssertEqual(rig.shopping.calls, [.add("soy sauce", .missing, CookingFixtures.versionUUID)])
        let after = try offer(rig)
        XCTAssertEqual(after.error, "Couldn’t add it to your shopping list. Try again.")
        XCTAssertEqual(after.actions, [.useSwap, .addToShoppingList])
    }

    func testRemoveFromPantryDeletesThatItemOnly() async throws {
        let rig = try await makeRig()
        await rig.model.perform(.removeFromPantry, turnId: rig.turnId)
        XCTAssertEqual(rig.pantry.calls, [.delete(try XCTUnwrap(UUID(uuidString: MissingFixtures.pantryItemId)))])
        XCTAssertEqual(rig.pantryChanges.value, 1)
        XCTAssertTrue(rig.shopping.calls.isEmpty)
        let after = try offer(rig)
        XCTAssertEqual(after.statuses, ["Removed from your pantry"])
        XCTAssertEqual(after.actions, [.useSwap, .addToShoppingList])
    }

    func testPantryFailureLeavesTheOfferAndAlreadyGoneCountsAsRemoved() async throws {
        let rig = try await makeRig()
        rig.pantry.deleteHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        await rig.model.perform(.removeFromPantry, turnId: rig.turnId)
        XCTAssertEqual(try offer(rig).error, "Couldn’t remove it from your pantry. Try again.")
        XCTAssertTrue(try offer(rig).actions.contains(.removeFromPantry))
        XCTAssertEqual(rig.pantryChanges.value, 0)

        let gone = try CookingFixtures.apiError(status: 404, code: "NOT_FOUND")
        rig.pantry.deleteHandler = { _ in throw gone }
        await rig.model.perform(.removeFromPantry, turnId: rig.turnId)
        XCTAssertEqual(try offer(rig).statuses, ["Removed from your pantry"])
        XCTAssertNil(try offer(rig).error)
    }

    func testActionsNotOnTheOfferAreIgnored() async throws {
        let rig = try await makeRig(missing: MissingFixtures.offerJSON(swap: nil, onList: true, inPantry: false))
        XCTAssertTrue(try offer(rig).actions.isEmpty)
        for action in MissingIngredientOffer.Action.allCases {
            await rig.model.perform(action, turnId: rig.turnId)
        }
        XCTAssertTrue(rig.approved.value.isEmpty)
        XCTAssertTrue(rig.shopping.calls.isEmpty)
        XCTAssertTrue(rig.pantry.calls.isEmpty)
    }

    func testPickingACandidateAsksTheCoachAboutThatOne() async throws {
        let rig = try await makeRig(missing: MissingFixtures.whichJSON)
        let candidates = try offer(rig).candidates
        let next = try MissingFixtures.response(missing: MissingFixtures.offerJSON(), messageId: "3e000000-0000-4000-8000-000000000002")
        rig.cooking.askHandler = { _, _ in next }
        rig.model.query = "half typed"
        await rig.model.pick(candidates[1], turnId: rig.turnId)
        XCTAssertEqual(rig.cooking.calls.last, .ask("I don't have soy sauce", 1))
        XCTAssertEqual(rig.model.turns.count, 2)
        XCTAssertEqual(rig.model.query, "half typed", "what the cook was typing is kept")
        XCTAssertNil(rig.model.offer(for: rig.model.turns[0]), "the question is answered")
        XCTAssertEqual(rig.model.offer(for: rig.model.turns[1])?.swapTitle, "Swap: tamari")
        XCTAssertTrue(rig.approved.value.isEmpty, "picking only asks")
    }

    func testFailedPickKeepsTheChoices() async throws {
        let rig = try await makeRig(missing: MissingFixtures.whichJSON)
        let candidates = try offer(rig).candidates
        rig.cooking.askHandler = { _, _ in throw APIError.http(status: 503, correlationId: nil) }
        await rig.model.pick(candidates[0], turnId: rig.turnId)
        XCTAssertEqual(rig.model.turns.count, 1)
        XCTAssertNotNil(rig.model.errorMessage)
        XCTAssertEqual(try offer(rig).candidates.count, 2)
    }
}

@MainActor
final class CookingApproveAdaptationTests: XCTestCase {
    func testUseThisSwapIsAConfirmedCommandAtTheSessionsRevision() async throws {
        let service = FakeCookingService()
        let session = try CookingFixtures.session(revision: 4, adapted: false)
        service.sessionHandler = { _ in session }
        service.commandHandler = { command, _ in try CookingFixtures.session(revision: command.expectedRevision + 1, adapted: true) }
        let model = CookingViewModel(sessionId: session.id, service: service, audio: FakeAudioOutput())
        await model.load()
        let adaptation = AdaptationInput(ingredientRef: "ing-8", replacement: "lemon juice", ratioOrAmount: "1 tbsp", source: .rule)
        let ok = await model.approveAdaptation(adaptation)
        XCTAssertTrue(ok)
        let sent = try XCTUnwrap(service.commands.last?.0)
        XCTAssertEqual(sent.command, .approveAdaptation)
        XCTAssertEqual(sent.adaptation, adaptation)
        XCTAssertEqual(sent.expectedRevision, 4)
        XCTAssertTrue(sent.userConfirmed)
        XCTAssertEqual(sent.clientSource, .iosAssistant)
        XCTAssertEqual(model.session?.adaptations.count, 1, "the session shown is the server's answer")
    }

    func testRefusedSwapChangesNothing() async throws {
        let service = FakeCookingService()
        let session = try CookingFixtures.session(revision: 4, adapted: false)
        service.sessionHandler = { _ in session }
        service.commandHandler = { _, _ in throw APIError.http(status: 500, correlationId: nil) }
        let model = CookingViewModel(sessionId: session.id, service: service, audio: FakeAudioOutput())
        await model.load()
        let ok = await model.approveAdaptation(AdaptationInput(ingredientRef: "ing-8", replacement: "x", source: .rule))
        XCTAssertFalse(ok)
        XCTAssertEqual(model.session?.adaptations.count, 0)
        XCTAssertEqual(model.session?.revision, 4)
    }
}
