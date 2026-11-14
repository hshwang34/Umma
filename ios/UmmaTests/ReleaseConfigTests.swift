import Foundation
import XCTest
@testable import Umma

/// Brief 010: what a release build is configured to do. The tests run in a debug build, so the
/// release behaviour is exercised through the same functions with `allowsOverride: false`.
@MainActor
final class ReleaseConfigTests: XCTestCase {
    private let production = BuildConfig.productionAPIBaseURL

    func testProductionURLIsAValidHTTPSAddress() throws {
        let url = try XCTUnwrap(ServerSettings.validate(production))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.absoluteString, production, "no trailing slash or stray whitespace")
    }

    func testReleaseDefaultsToProductionAndDebugKeepsTheLocalDefaults() {
        XCTAssertEqual(ServerSettings.defaultBaseURL(debug: false, simulator: false), production)
        XCTAssertEqual(ServerSettings.defaultBaseURL(debug: false, simulator: true), production)
        XCTAssertEqual(ServerSettings.defaultBaseURL(debug: true, simulator: true), "http://localhost:8000")
        XCTAssertEqual(ServerSettings.defaultBaseURL(debug: true, simulator: false), "")
    }

    func testReleaseIgnoresAnOverrideLeftByAnEarlierBuild() {
        let defaults = freshDefaults()
        defaults.set("http://10.0.0.2:8000", forKey: UserDefaultsBaseURLProvider.key)

        let provider = UserDefaultsBaseURLProvider(defaults: defaults, allowsOverride: false, fallback: production)
        XCTAssertEqual(provider.baseURLString, production)
        XCTAssertEqual(provider.baseURL?.absoluteString, production)

        let settings = ServerSettings(defaults: defaults, allowsOverride: false, fallback: production)
        XCTAssertEqual(settings.effectiveBaseURLString, production)
        XCTAssertTrue(settings.isValid)
        XCTAssertTrue(settings.isConfigured)
    }

    func testReleaseNeverChangesServerOrSignsAnyoneOut() {
        let defaults = freshDefaults()
        let settings = ServerSettings(defaults: defaults, allowsOverride: false, fallback: production)
        var changes = 0
        settings.onEffectiveBaseURLChanged = { _, _ in changes += 1 }

        settings.baseURLText = "http://evil.example:8000"

        XCTAssertEqual(settings.effectiveBaseURLString, production)
        XCTAssertEqual(changes, 0)
        XCTAssertNil(defaults.string(forKey: UserDefaultsBaseURLProvider.key), "nothing is stored")
    }

    func testDebugStillHonoursAnOverride() {
        let defaults = freshDefaults()
        defaults.set(" http://10.0.0.2:8000 ", forKey: UserDefaultsBaseURLProvider.key)
        let provider = UserDefaultsBaseURLProvider(defaults: defaults, allowsOverride: true, fallback: production)
        XCTAssertEqual(provider.baseURLString, "http://10.0.0.2:8000")
    }

    // MARK: - Bundle

    func testInfoPlistDeclaresNoNonExemptEncryptionAndCarriesAVersionAndBuild() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertFalse(version.isEmpty || version.contains("$("), "MARKETING_VERSION was expanded")
        XCTAssertFalse(build.isEmpty || build.contains("$("), "CURRENT_PROJECT_VERSION was expanded")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.umma.ios")
    }

    func testPrivacyManifestShipsAndDeclaresWhatTheAppCollects() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)

        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(types, Set(["Name", "EmailAddress", "UserID", "PhotosorVideos", "AudioData", "Health", "OtherUserContent"]
            .map { "NSPrivacyCollectedDataType\($0)" }))
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }

        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: apis.compactMap { api -> (String, [String])? in
            guard let type = api["NSPrivacyAccessedAPIType"] as? String,
                  let reasons = api["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
            return (type, reasons)
        })
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }
}
