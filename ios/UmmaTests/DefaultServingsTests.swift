import Foundation
import XCTest
@testable import Umma

private final class FakeProfileService: ProfileService, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Int?] = []
    var calls: [Int?] { lock.withLock { _calls } }
    var handler: @Sendable (Int?) throws -> User = { servings in DefaultServingsFixtures.user(servings) }
    var gate: AsyncGate?

    func setDefaultServings(_ servings: Int?) async throws -> User {
        lock.withLock { _calls.append(servings) }
        await gate?.wait()
        return try handler(servings)
    }
}

private enum DefaultServingsFixtures {
    static func userJSON(_ field: String) -> String {
        String(SocialFixtures.userJSON().dropLast(1)) + field + "}"
    }

    static func user(_ servings: Int?) -> User {
        try! SocialFixtures.decode(User.self, userJSON(#","default_servings":\#(servings.map(String.init) ?? "null")"#))
    }
}

/// Brief 020: `default_servings` on the user and `PATCH /v1/me`.
final class DefaultServingsContractTests: XCTestCase {
    func testUserDecodesDefaultServings() throws {
        XCTAssertEqual(DefaultServingsFixtures.user(2).defaultServings, 2)
        XCTAssertNil(DefaultServingsFixtures.user(nil).defaultServings)
        XCTAssertNil(try SocialFixtures.decode(User.self, SocialFixtures.userJSON()).defaultServings, "older servers send no field")
        for odd in [#","default_servings":0"#, #","default_servings":9"#, #","default_servings":"two""#] {
            let user = try SocialFixtures.decode(User.self, DefaultServingsFixtures.userJSON(odd))
            XCTAssertNil(user.defaultServings, "\(odd) reads as the recipe's own, and the user still decodes")
        }
    }

    func testCachedUserKeepsDefaultServings() throws {
        let data = try JSONCoding.makeEncoder().encode(DefaultServingsFixtures.user(3))
        XCTAssertEqual(try JSONCoding.makeDecoder().decode(User.self, from: data).defaultServings, 3)
    }

    private func patchBody(_ servings: Int?) async throws -> [String: Any] {
        StubURLProtocol.install { request in
            (.stub(request, status: 200), Data(DefaultServingsFixtures.userJSON(#","default_servings":\#(servings.map(String.init) ?? "null")"#).utf8))
        }
        let client = APIClient(session: StubURLProtocol.makeSession(),
                               baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                               tokenProvider: InMemoryTokenStore(token: "tok"))
        let user = try await client.setDefaultServings(servings)
        XCTAssertEqual(user.defaultServings, servings)
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/v1/me")
        return try request.jsonBody()
    }

    func testPatchSendsOnlyDefaultServings() async throws {
        let body = try await patchBody(2)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["default_servings"] as? Int, 2)
    }

    func testClearingSendsAnExplicitNull() async throws {
        let body = try await patchBody(nil)
        XCTAssertEqual(body.count, 1)
        XCTAssertTrue(body["default_servings"] is NSNull, "a missing field would change nothing")
    }
}

@MainActor
final class DefaultServingsViewModelTests: XCTestCase {
    private func makeModel(current: Int? = nil) -> (DefaultServingsViewModel, FakeProfileService, TestBox<[User]>) {
        let service = FakeProfileService()
        let saved = TestBox<[User]>([])
        let model = DefaultServingsViewModel(current: current, service: service) { saved.value.append($0) }
        return (model, service, saved)
    }

    func testStartsAsRecipesOwnWithSevenChoices() {
        let (model, _, _) = makeModel()
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.options.map(\.title), ["Recipe’s own", "1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(model.options.map(\.accessibilityLabel).prefix(3), ["Recipe’s own", "1 serving", "2 servings"])
        XCTAssertEqual(DefaultServingsViewModel.title, "Default servings")
    }

    func testSelectSavesAndHandsTheUserBack() async {
        let (model, service, saved) = makeModel()
        await model.select(2)
        XCTAssertEqual(service.calls, [2])
        XCTAssertEqual(model.selected, 2)
        XCTAssertEqual(saved.value.map(\.defaultServings), [2])
        XCTAssertNil(model.errorMessage)

        await model.select(2)
        XCTAssertEqual(service.calls, [2], "the same choice is not saved twice")

        await model.select(nil)
        XCTAssertEqual(service.calls, [2, nil])
        XCTAssertNil(model.selected)
    }

    func testFailedSaveRollsBackAndSaysSo() async {
        let (model, service, saved) = makeModel(current: 4)
        service.handler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        await model.select(1)
        XCTAssertEqual(model.selected, 4)
        XCTAssertTrue(saved.value.isEmpty)
        XCTAssertEqual(model.errorMessage?.hasPrefix("Couldn’t save your default servings"), true)
        XCTAssertFalse(model.isSaving)
    }

    func testOneSaveAtATimeAndOutOfRangeIsIgnored() async {
        let (model, service, _) = makeModel()
        let gate = AsyncGate()
        service.gate = gate
        let first = Task { await model.select(3) }
        await gate.waitUntilWaiting()
        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.selected, 3, "shows the tap while it saves")
        await model.select(5)
        model.sync(current: 6)
        XCTAssertEqual(model.selected, 3, "a refresh never overwrites a save in flight")
        await gate.open()
        await first.value
        XCTAssertEqual(service.calls, [3])
        XCTAssertEqual(model.selected, 3)

        service.gate = nil
        await model.select(7)
        XCTAssertEqual(service.calls, [3])
        model.sync(current: nil)
        XCTAssertNil(model.selected)
    }
}

@MainActor
final class RecipeDefaultServingsTests: XCTestCase {
    private func makeModel(original: Int = 4, defaultServings: Int?) async throws -> RecipeDetailViewModel {
        let text = String(decoding: try Fixtures.data("recipe_detail"), as: UTF8.self)
            .replacingOccurrences(of: "\"servings\": 4", with: "\"servings\": \(original)")
        let detail = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(text.utf8))
        let service = FakeRecipeService()
        service.detailHandler = { _ in detail }
        let model = RecipeDetailViewModel(recipeId: detail.recipeId, defaultServings: defaultServings, service: service)
        await model.load()
        return model
    }

    func testRecipeOpensScaledToTheDefault() async throws {
        let model = try await makeModel(defaultServings: 2)
        XCTAssertEqual(model.dial?.servings, 2)
        XCTAssertEqual(model.dial?.scaledFromText, "Scaled from 4")
        XCTAssertEqual(model.ingredients.first?.quantity, 1)
    }

    func testDialStillChangesPerRecipeWithoutTouchingTheDefault() async throws {
        let model = try await makeModel(defaultServings: 2)
        model.setServings(5)
        XCTAssertEqual(model.dial?.servings, 5)
        XCTAssertEqual(model.defaultServings, 2)
        model.resetServings()
        XCTAssertEqual(model.dial?.servings, 4, "reset goes to the creator's, not the default")
        XCTAssertNil(model.dial?.scaledFromText)
    }

    func testDefaultEqualToTheOriginalIsNotScaled() async throws {
        let model = try await makeModel(defaultServings: 4)
        XCTAssertEqual(model.dial?.isScaled, false)
        XCTAssertEqual(model.ingredients, model.detail?.ingredients)
    }

    func testRecipeForEightOpensAtItsOriginalUnlessADefaultIsSet() async throws {
        let own = try await makeModel(original: 8, defaultServings: nil)
        XCTAssertEqual(own.dial?.servings, 8)
        let scaled = try await makeModel(original: 8, defaultServings: 6)
        XCTAssertEqual(scaled.dial?.servings, 6)
        XCTAssertEqual(scaled.dial?.scaledFromText, "Scaled from 8")
    }

    func testDefaultSetWhileTheRecipeIsOpenAppliesUntilTheDialIsTouched() async throws {
        let model = try await makeModel(defaultServings: nil)
        model.defaultServings = 3
        XCTAssertEqual(model.dial?.servings, 3)
        model.setServings(1)
        model.defaultServings = 6
        XCTAssertEqual(model.dial?.servings, 1)
    }
}
