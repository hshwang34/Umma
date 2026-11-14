import Foundation
import Observation

/// Where the backend lives. A release build always uses `BuildConfig.productionAPIBaseURL`.
/// A debug build persists an override in `UserDefaults`; the simulator defaults to the Mac's
/// localhost, a physical device starts empty so the developer is prompted for the Mac's LAN IP.
protocol BaseURLProviding: Sendable {
    var baseURL: URL? { get }
    var baseURLString: String { get }
}

/// `UserDefaults` is documented thread-safe but not marked `Sendable`; reads happen on any task.
struct UserDefaultsBaseURLProvider: BaseURLProviding, @unchecked Sendable {
    static let key = "serverBaseURL"
    let defaults: UserDefaults
    let allowsOverride: Bool
    let fallback: String

    init(defaults: UserDefaults = .standard,
         allowsOverride: Bool = BuildConfig.allowsServerOverride,
         fallback: String = ServerSettings.platformDefault) {
        self.defaults = defaults
        self.allowsOverride = allowsOverride
        self.fallback = fallback
    }

    var baseURLString: String {
        ServerSettings.effective(defaults.string(forKey: Self.key) ?? "", allowsOverride: allowsOverride, fallback: fallback)
    }

    var baseURL: URL? {
        ServerSettings.validate(baseURLString)
    }
}

/// Fixed provider for tests and previews.
struct StaticBaseURLProvider: BaseURLProviding {
    let baseURL: URL?
    var baseURLString: String { baseURL?.absoluteString ?? "" }
}

@MainActor
@Observable
final class ServerSettings {
    #if targetEnvironment(simulator)
    private nonisolated static let isSimulator = true
    #else
    private nonisolated static let isSimulator = false
    #endif

    /// The address used when nothing is typed in: production in a release build.
    nonisolated static let platformDefault = defaultBaseURL(debug: BuildConfig.isDebug, simulator: isSimulator)

    nonisolated static func defaultBaseURL(debug: Bool, simulator: Bool) -> String {
        guard debug else { return BuildConfig.productionAPIBaseURL }
        return simulator ? "http://localhost:8000" : ""
    }

    private let defaults: UserDefaults
    /// False in a release build: the address is fixed and nothing typed or stored changes it.
    let allowsOverride: Bool
    private let fallback: String

    /// Fired after the *effective* base URL changes (not on every keystroke — the settings screen
    /// edits a draft and commits on Save). `AppEnvironment` uses it to sign out and drop caches.
    var onEffectiveBaseURLChanged: ((_ oldValue: String, _ newValue: String) -> Void)?

    /// Committed text. Empty means "use platform default".
    var baseURLText: String {
        didSet {
            guard allowsOverride, baseURLText != oldValue else { return }
            defaults.set(baseURLText, forKey: UserDefaultsBaseURLProvider.key)
            let before = Self.effective(oldValue, allowsOverride: allowsOverride, fallback: fallback)
            let after = effectiveBaseURLString
            if before != after {
                onEffectiveBaseURLChanged?(before, after)
            }
        }
    }

    init(defaults: UserDefaults = .standard,
         allowsOverride: Bool = BuildConfig.allowsServerOverride,
         fallback: String = ServerSettings.platformDefault) {
        self.defaults = defaults
        self.allowsOverride = allowsOverride
        self.fallback = fallback
        self.baseURLText = allowsOverride ? defaults.string(forKey: UserDefaultsBaseURLProvider.key) ?? fallback : fallback
    }

    var effectiveBaseURLString: String {
        Self.effective(baseURLText, allowsOverride: allowsOverride, fallback: fallback)
    }

    /// The address requests go to: the typed override when overrides are allowed and one is set,
    /// otherwise `fallback`.
    nonisolated static func effective(_ text: String,
                                      allowsOverride: Bool = BuildConfig.allowsServerOverride,
                                      fallback: String = platformDefault) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowsOverride && !trimmed.isEmpty ? trimmed : fallback
    }

    var isValid: Bool { Self.validate(effectiveBaseURLString) != nil }

    var isConfigured: Bool { !effectiveBaseURLString.isEmpty }

    func resetToDefault() {
        baseURLText = Self.platformDefault
    }

    /// Accepts only http(s) URLs with a host; strips a trailing slash.
    nonisolated static func validate(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}
