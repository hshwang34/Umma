import Foundation
import XCTest
@testable import Umma

private enum ServingsSessionFixtures {
    /// A session JSON with the brief 020 fields added (`sessionJSON` is a pre-020 payload).
    static func json(servings: Int, original: Int = 4, scaled: Bool? = nil, stepIndex: Int = 0, adapted: Bool = false,
                     status: String = "active") throws -> String {
        let base = try CookingFixtures.sessionJSON(status: status, stepIndex: stepIndex, adapted: adapted)
        let fields = #""servings":\#(servings),"original_servings":\#(original),"amounts_scaled":\#(scaled ?? (servings != original)),"#
        return "{" + fields + base.dropFirst(1)
    }

    static func session(servings: Int, original: Int = 4, stepIndex: Int = 0, adapted: Bool = false) throws -> CookingSession {
        try CookingFixtures.decode(CookingSession.self, json(servings: servings, original: original, stepIndex: stepIndex, adapted: adapted))
    }
}

/// Brief 020 PR 8: servings on the session contract.
final class SessionServingsContractTests: XCTestCase {
    func testSessionDecodesServings() throws {
        let session = try ServingsSessionFixtures.session(servings: 2)
        XCTAssertEqual(session.servings, 2)
        XCTAssertEqual(session.originalServings, 4)
        XCTAssertTrue(session.amountsScaled)
        XCTAssertEqual(session.recipe.servings, 4, "recipe.servings stays the creator's")
    }

    func testSessionFromBeforeServingsIsTheRecipesOwn() throws {
        let session = try CookingFixtures.session()
        XCTAssertEqual(session.servings, 4)
        XCTAssertEqual(session.originalServings, 4)
        XCTAssertFalse(session.amountsScaled)
        XCTAssertNil(SessionServings(session: session).scaledFromText)
    }

    func testCachedCopyKeepsItsServings() throws {
        let session = try ServingsSessionFixtures.session(servings: 6)
        let data = try JSONCoding.makeEncoder().encode(session)
        let restored = try JSONCoding.makeDecoder().decode(CookingSession.self, from: data)
        XCTAssertEqual(restored.servings, 6)
        XCTAssertEqual(restored.originalServings, 4)
        XCTAssertTrue(restored.amountsScaled)
    }

    private func createBody(servings: Int?) async throws -> [String: Any] {
        let json = try CookingFixtures.sessionJSON(status: "created", revision: 0)
        StubURLProtocol.install { request in (.stub(request, status: 201), Data(json.utf8)) }
        let client = APIClient(session: StubURLProtocol.makeSession(),
                               baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                               tokenProvider: InMemoryTokenStore(token: "tok"))
        _ = try await client.createSession(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], servings: servings)
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/sessions")
        return try request.jsonBody()
    }

    func testCreateSendsTheChosenServings() async throws {
        let body = try await createBody(servings: 2)
        XCTAssertEqual(body["servings"] as? Int, 2)
    }

    func testCreateWithoutServingsOmitsTheField() async throws {
        let body = try await createBody(servings: nil)
        XCTAssertNil(body["servings"])
        XCTAssertNotNil(body["recipe_version_id"])
    }
}

@MainActor
final class CookingServingsTests: XCTestCase {
    func testStartConfirmationStatesTheNumberAndTheScaling() {
        let scaled = StartConfirmation(choice: ServingsChoice(servings: 2, original: 4))
        XCTAssertEqual(scaled.title, "Cooking for 2")
        XCTAssertEqual(scaled.confirmTitle, "Start cooking for 2")
        XCTAssertEqual(scaled.message, "Scaled from 4. Cooking times, pan sizes and step text aren’t scaled. Taste as you go. Servings can’t be changed once you start.")
        XCTAssertEqual(scaled.servings, 2)

        let own = StartConfirmation(choice: ServingsChoice(servings: 4, original: 4))
        XCTAssertEqual(own.title, "Cooking for 4")
        XCTAssertEqual(own.message, "Servings can’t be changed once you start.")
        XCTAssertFalse(own.message.contains("Scaled"))
        XCTAssertEqual(StartConfirmation.cancelTitle, "Not yet")
    }

    func testStarterCreatesTheSessionWithTheConfirmedServings() async throws {
        let service = FakeCookingService()
        service.createHandler = { _, _ in try ServingsSessionFixtures.session(servings: 2) }
        let starter = SessionStarter(service: service)
        let session = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], servings: 2, epoch: 1)
        XCTAssertEqual(session?.servings, 2)
        XCTAssertEqual(service.createServings, [2])

        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        XCTAssertEqual(service.createServings, [2, nil], "no choice means the recipe's own")
    }

    func testRetryAfterStoppingAnUnfinishedCookKeepsTheServings() async throws {
        let service = FakeCookingService()
        let blocked = TestBox(true)
        let conflict = try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT",
                                                    details: #"{"open_session_ids":["\#(CookingFixtures.sessionId)"]}"#)
        service.createHandler = { _, _ in
            if blocked.value { throw conflict }
            return try ServingsSessionFixtures.session(servings: 3)
        }
        service.activeHandler = { blocked.value ? [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON())] : [] }
        service.sessionHandler = { _ in try CookingFixtures.session(stepIndex: 2, revision: 5) }
        service.commandHandler = { command, _ in
            blocked.value = false
            return try CookingFixtures.session(status: "abandoned", stepIndex: 2, revision: command.expectedRevision + 1)
        }
        let starter = SessionStarter(service: service)
        let first = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], servings: 3, epoch: 1)
        XCTAssertNil(first)
        let row = try XCTUnwrap(starter.unfinished.first)
        await starter.abandon(row)
        XCTAssertEqual(service.createServings, [3, 3])
        guard case .started(let session) = try XCTUnwrap(starter.takeOutcome()) else { return XCTFail("not started") }
        XCTAssertEqual(session.servings, 3)
    }

    func testPantryFitStartsWithTheServingsItWasOpenedFor() async throws {
        let cooking = FakeCookingService()
        cooking.createHandler = { _, _ in try ServingsSessionFixtures.session(servings: 2) }
        let pantry = FakePantryService()
        let model = PantryFitViewModel(recipeVersionId: CookingFixtures.versionUUID, recipeTitle: "T",
                                       servings: ServingsChoice(servings: 2, original: 4), service: pantry, cooking: cooking)
        XCTAssertEqual(model.startConfirmation?.title, "Cooking for 2")
        _ = await model.startCooking()
        XCTAssertEqual(cooking.createServings, [2])

        let own = PantryFitViewModel(recipeVersionId: CookingFixtures.versionUUID, recipeTitle: "T", service: pantry, cooking: cooking)
        XCTAssertNil(own.startConfirmation)
    }

    // MARK: Cook screen

    func testCookScreenShowsTheSessionsServingsNotTheRecipes() throws {
        let scaled = SessionServings(session: try ServingsSessionFixtures.session(servings: 2))
        XCTAssertEqual(scaled.title, "Cooking for 2")
        XCTAssertEqual(scaled.scaledFromText, "Scaled from 4")
        XCTAssertEqual(scaled.notice, ServingsDial.notice)
        XCTAssertEqual(scaled.accessibilityLabel, "Cooking for 2. Scaled from 4. \(ServingsDial.notice)")

        let own = SessionServings(session: try ServingsSessionFixtures.session(servings: 4))
        XCTAssertEqual(own.title, "Cooking for 4")
        XCTAssertNil(own.scaledFromText)
        XCTAssertNil(own.notice)
        XCTAssertFalse(own.isScaled)
    }

    func testStepIngredientsUseTheSessionsAmountsAsSent() throws {
        // The server sends scaled amounts in recipe.ingredients; the phone shows them as they are.
        let json = try ServingsSessionFixtures.json(servings: 2, stepIndex: 1)
            .replacingOccurrences(of: "\"quantity\": 2.0,\n      \"unit\": \"lb\"", with: "\"quantity\": 1.0,\n      \"unit\": \"lb\"")
        let session = try CookingFixtures.decode(CookingSession.self, json)
        let rows = StepIngredientRow.rows(session: session)
        XCTAssertEqual(rows.map(\.id), ["ing-1"])
        XCTAssertEqual(rows.first?.amountText, "1 lb")
        XCTAssertEqual(rows.first?.name, "boneless skinless chicken thighs")
        XCTAssertNil(rows.first?.detail)
        XCTAssertEqual(rows.first?.accessibilityLabel, "1 lb, boneless skinless chicken thighs")
    }

    func testStepIngredientsFollowTheStepAndShowAnApprovedSwap() throws {
        let rows = StepIngredientRow.rows(session: try ServingsSessionFixtures.session(servings: 4, adapted: true))
        XCTAssertEqual(rows.map(\.id), ["ing-2", "ing-3", "ing-4", "ing-5", "ing-6", "ing-7", "ing-8"])
        XCTAssertEqual(rows.first?.amountText, "3 tbsp")
        XCTAssertEqual(rows[4].amountText, "4 clove")
        let swapped = try XCTUnwrap(rows.last)
        XCTAssertEqual(swapped.name, "lemon juice + a pinch of sugar")
        XCTAssertEqual(swapped.amountText, "1 tbsp lemon juice + 1/2 tsp sugar")
        XCTAssertEqual(swapped.detail, "instead of rice vinegar")
    }

    func testViewModelExposesServingsAndStepIngredients() async throws {
        let service = FakeCookingService()
        let session = try ServingsSessionFixtures.session(servings: 2, stepIndex: 2)
        service.sessionHandler = { _ in session }
        let model = CookingViewModel(sessionId: session.id, service: service, audio: FakeAudioOutput())
        XCTAssertNil(model.servings)
        await model.load()
        XCTAssertEqual(model.servings?.title, "Cooking for 2")
        XCTAssertEqual(model.servings?.scaledFromText, "Scaled from 4")
        XCTAssertEqual(model.stepIngredients.map(\.name), ["neutral oil"])
    }
}
