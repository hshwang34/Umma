import SwiftUI
import XCTest
@testable import Umma

/// Brief 019: the tab header's layout rule and the in-page search field's clear button.
final class TabHeaderTests: XCTestCase {
    func testHeaderStacksOnlyAtAccessibilitySizes() {
        XCTAssertFalse(TabHeaderLayout.stacksVertically(for: .large))
        XCTAssertFalse(TabHeaderLayout.stacksVertically(for: .xxxLarge))
        XCTAssertTrue(TabHeaderLayout.stacksVertically(for: .accessibility1))
        XCTAssertTrue(TabHeaderLayout.stacksVertically(for: .accessibility5))
    }

    func testClearButtonShowsOnlyWithText() {
        XCTAssertFalse(InPageSearchFieldRules.showsClear(text: ""))
        XCTAssertTrue(InPageSearchFieldRules.showsClear(text: "kimchi"))
        XCTAssertTrue(InPageSearchFieldRules.showsClear(text: " "), "whitespace is still text the user can clear")
    }

    @MainActor
    func testClearingAndSubmittingResetsTheQuery() async {
        let service = FakeRecipeService(listHandler: { _ in RecipePage(items: [], nextCursor: nil) })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .seconds(60))
        model.searchText = "kimchi"
        await model.submitSearchNow()
        XCTAssertEqual(model.query, "kimchi")
        // The field's clear button: empty the text, then submit at once (no debounce wait).
        model.searchText = ""
        await model.submitSearchNow()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(service.calls.map(\.query), ["kimchi", nil], "the cleared search refetches the feed straight away")
    }
}
