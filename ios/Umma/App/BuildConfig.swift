import Foundation

/// Values that differ between a debug build and the build testers get (brief 010).
enum BuildConfig {
    /// The hosted backend every release build talks to. This is the one place to change it.
    static let productionAPIBaseURL = "https://umma-api.fly.dev"

    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    /// The server address can be changed (and is shown) in debug builds only. A release build
    /// always uses `productionAPIBaseURL`, whatever an older build left in `UserDefaults`.
    static let allowsServerOverride = isDebug
}
