import Foundation
import XCTest
@testable import Umma

enum ShoppingFixtures {
    static let milkId = UUID(uuidString: "a1b2c3d4-0000-4000-8000-000000000001")!
    static let eggsId = UUID(uuidString: "a1b2c3d4-0000-4000-8000-000000000002")!

    static func itemJSON(id: UUID = milkId, name: String = "milk", reason: String = "missing", checkedAt: String? = nil,
                         checkedBy: String? = nil) -> String {
        """
        {"id":"\(id.uuidString.lowercased())","raw_label":"\(name)","normalized_name":"\(name)","ingredient_id":null,
         "reason":"\(reason)","source_session_id":null,"source_recipe_version_id":null,
         "checked_at":\(checkedAt.map { "\"\($0)\"" } ?? "null"),"checked_by":\(checkedBy.map { "\"\($0)\"" } ?? "null"),
         "created_at":"2026-11-14T09:00:00Z","updated_at":"2026-11-14T09:00:00Z"}
        """
    }

    static func item(id: UUID = milkId, name: String = "milk", reason: String = "missing", checkedAt: String? = nil,
                     checkedBy: String? = nil) -> ShoppingItem {
        // swiftlint:disable:next force_try
        try! PantryFixtures.decode(ShoppingItem.self, itemJSON(id: id, name: name, reason: reason, checkedAt: checkedAt, checkedBy: checkedBy))
    }
}

/// Brief 017: the shopping-list endpoints through the `URLProtocol` stub, and `shopping_added`.
final class ShoppingAPITests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(session: StubURLProtocol.makeSession(),
                  baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                  tokenProvider: InMemoryTokenStore(token: "tok"))
    }

    func testShoppingEndpointsSendAndDecodeTheContract() async throws {
        let milk = ShoppingFixtures.milkId.uuidString.lowercased()
        let ticked = ShoppingFixtures.itemJSON(checkedAt: "2026-11-14T10:00:00Z", checkedBy: "user")
        StubURLProtocol.install { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/v1/shopping-list"):
                let eggs = ShoppingFixtures.itemJSON(id: ShoppingFixtures.eggsId, name: "eggs", reason: "later",
                                                     checkedAt: "2026-11-14T10:00:00Z", checkedBy: "receipt")
                return (.stub(request, status: 200), Data(#"{"items":[\#(ShoppingFixtures.itemJSON()),\#(eggs)]}"#.utf8))
            case ("POST", "/v1/shopping-list"):
                // 200: already on the list. The same item comes back.
                return (.stub(request, status: 200), Data(ShoppingFixtures.itemJSON().utf8))
            case ("POST", "/v1/shopping-list/\(milk)/check"):
                return (.stub(request, status: 200), Data(ticked.utf8))
            case ("POST", "/v1/shopping-list/\(milk)/uncheck"):
                return (.stub(request, status: 200), Data(ShoppingFixtures.itemJSON().utf8))
            case ("DELETE", "/v1/shopping-list/\(milk)"):
                return (.stub(request, status: 204), Data())
            default:
                return (.stub(request, status: 404), Data())
            }
        }
        let client = makeClient()

        let list = try await client.shoppingList()
        XCTAssertEqual(list.map(\.rawLabel), ["milk", "eggs"], "the server's order is kept")
        XCTAssertEqual(list.map(\.isChecked), [false, true])
        XCTAssertEqual(list[0].reason, .missing)
        XCTAssertEqual(list[1].reason, .unknown, "a reason this build doesn't know never fails the list")
        XCTAssertEqual(list[1].checkedBy, "receipt")

        let added = try await client.addShoppingItem(name: String(repeating: "m", count: 200), reason: .ranOut, recipeVersionId: nil)
        XCTAssertEqual(added.id, ShoppingFixtures.milkId)
        let body = try StubURLProtocol.requests[1].jsonBody()
        XCTAssertEqual((body["name"] as? String)?.count, 120)
        XCTAssertEqual(body["reason"] as? String, "ran_out")
        XCTAssertNil(body["recipe_version_id"], "left out when there is no recipe")

        let checked = try await client.checkShoppingItem(id: ShoppingFixtures.milkId)
        XCTAssertTrue(checked.isChecked)
        let unchecked = try await client.uncheckShoppingItem(id: ShoppingFixtures.milkId)
        XCTAssertFalse(unchecked.isChecked)
        try await client.deleteShoppingItem(id: ShoppingFixtures.milkId)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "DELETE")
    }

    func testOnlyClientReasonsAreSent() {
        XCTAssertEqual(ShoppingReason.manual.sendable, "manual")
        XCTAssertEqual(ShoppingReason.missing.sendable, "missing")
        XCTAssertEqual(ShoppingReason.ranOut.sendable, "ran_out")
        XCTAssertEqual(ShoppingReason.noSubstitute.sendable, "manual")
        XCTAssertEqual(ShoppingReason.unknown.sendable, "manual")
    }

    func testSessionDecodesShoppingAddedAndDefaultsToEmpty() throws {
        let plain = try CookingFixtures.session(status: "completed")
        XCTAssertEqual(plain.shoppingAdded, [])
        let json = try CookingFixtures.sessionJSON(status: "completed")
        let end = try XCTUnwrap(json.lastIndex(of: "}"))
        let withAdded = String(json[..<end]) + #","shopping_added":["soy sauce","honey"]}"#
        let completed = try CookingFixtures.decode(CookingSession.self, withAdded)
        XCTAssertEqual(completed.shoppingAdded, ["soy sauce", "honey"])
    }
}
