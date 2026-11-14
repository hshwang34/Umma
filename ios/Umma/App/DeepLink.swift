import Foundation

/// Share / deep-link formats (brief 003, REC-01):
/// - custom scheme `umma://recipe/{recipe_id}`
/// - universal link `https://ummacooks.app/r/{recipe_id}` (the domain we own, and the one in
///   the associated-domains entitlement; the path is handled when iOS hands it to the app).
enum ShareLinks {
    static let scheme = "umma"
    static let universalHost = "ummacooks.app"

    static func universal(recipeId: UUID) -> URL {
        URL(string: "https://\(universalHost)/r/\(recipeId.uuidString.lowercased())")!
    }

    static func custom(recipeId: UUID) -> URL {
        URL(string: "\(scheme)://recipe/\(recipeId.uuidString.lowercased())")!
    }
}

enum DeepLink: Equatable, Sendable {
    case recipe(UUID)

    /// Returns nil for anything that is not one of the two recipe link forms. Trailing slashes and
    /// upper-case UUIDs are tolerated; extra path components, other hosts and other schemes are not.
    static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        let host = components.host?.lowercased() ?? ""
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch scheme {
        case ShareLinks.scheme:
            // umma://recipe/{id} → host "recipe", path "/{id}"
            guard host == "recipe", segments.count == 1 else { return nil }
            return UUID(uuidString: segments[0]).map(DeepLink.recipe)
        case "https":
            // Only the exact host in the associated-domains entitlement (`applinks:ummacooks.app`).
            guard host == ShareLinks.universalHost,
                  segments.count == 2, segments[0] == "r"
            else { return nil }
            return UUID(uuidString: segments[1]).map(DeepLink.recipe)
        default:
            return nil
        }
    }
}
