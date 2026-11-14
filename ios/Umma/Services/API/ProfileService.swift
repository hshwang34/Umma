import Foundation

/// Profile settings stored on the user (`PATCH /v1/me`). Only the field that is sent changes.
protocol ProfileService: Sendable {
    /// Brief 020: `nil` clears it back to "the recipe's own".
    func setDefaultServings(_ servings: Int?) async throws -> User
}

extension APIClient: ProfileService {
    func setDefaultServings(_ servings: Int?) async throws -> User {
        try await send(.patch("/v1/me", body: try encoder.encode(DefaultServingsUpdate(defaultServings: servings))))
    }
}

struct DefaultServingsUpdate: Encodable, Sendable, Equatable {
    let defaultServings: Int?

    private enum CodingKeys: String, CodingKey {
        case defaultServings
    }

    /// Clearing is an explicit `null`: a missing field would change nothing.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultServings, forKey: .defaultServings)
    }
}
