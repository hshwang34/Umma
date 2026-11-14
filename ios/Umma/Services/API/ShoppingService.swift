import Foundation

/// Shopping list (brief 017, `/v1/shopping-list`). Owner only. `APIClient` is the real
/// implementation; view-model tests inject a fake.
protocol ShoppingService: Sendable {
    /// The list as the server orders it, ticked items included.
    func shoppingList() async throws -> [ShoppingItem]
    /// Adds one item. A name that is already open on the list returns that item (each item
    /// appears once), so this is safe to repeat.
    func addShoppingItem(name: String, reason: ShoppingReason, recipeVersionId: UUID?) async throws -> ShoppingItem
    func checkShoppingItem(id: UUID) async throws -> ShoppingItem
    func uncheckShoppingItem(id: UUID) async throws -> ShoppingItem
    func deleteShoppingItem(id: UUID) async throws
}

extension APIClient: ShoppingService {
    func shoppingList() async throws -> [ShoppingItem] {
        let response: ItemsResponse<ShoppingItem> = try await send(.get("/v1/shopping-list"))
        return response.items
    }

    func addShoppingItem(name: String, reason: ShoppingReason, recipeVersionId: UUID?) async throws -> ShoppingItem {
        let body = ShoppingItemRequest(name: String(name.prefix(ShoppingItem.maxNameLength)), reason: reason.sendable,
                                       recipeVersionId: recipeVersionId)
        return try await send(.post("/v1/shopping-list", body: try encoder.encode(body)))
    }

    func checkShoppingItem(id: UUID) async throws -> ShoppingItem {
        try await send(.post("/v1/shopping-list/\(Self.pathId(id))/check", body: Self.emptyObject))
    }

    func uncheckShoppingItem(id: UUID) async throws -> ShoppingItem {
        try await send(.post("/v1/shopping-list/\(Self.pathId(id))/uncheck", body: Self.emptyObject))
    }

    func deleteShoppingItem(id: UUID) async throws {
        _ = try await raw(.delete("/v1/shopping-list/\(Self.pathId(id))"))
    }
}

private struct ShoppingItemRequest: Encodable {
    let name: String
    let reason: String
    let recipeVersionId: UUID?
}

/// Why an item is on the list. The client only ever sends the first three.
enum ShoppingReason: String, Decodable, Sendable, Equatable {
    case manual
    case missing
    case ranOut = "ran_out"
    /// Written by the coach when no swap exists. Never sent.
    case noSubstitute = "no_substitute"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ShoppingReason(rawValue: raw) ?? .unknown
    }

    /// What `POST /shopping-list` accepts; anything else goes as a plain manual add.
    var sendable: String {
        switch self {
        case .manual, .missing, .ranOut: return rawValue
        case .noSubstitute, .unknown: return ShoppingReason.manual.rawValue
        }
    }
}

struct ShoppingItem: Decodable, Sendable, Identifiable, Equatable {
    /// Server limit on a name.
    static let maxNameLength = 120

    let id: UUID
    let rawLabel: String
    let normalizedName: String
    let reason: ShoppingReason
    /// Set when ticked, by the cook or by a receipt.
    let checkedAt: Date?
    /// `user` or `receipt`; kept as text so a new value never fails the list.
    let checkedBy: String?
    let createdAt: Date

    var isChecked: Bool { checkedAt != nil }
}
