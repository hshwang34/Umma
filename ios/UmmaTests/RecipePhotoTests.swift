import Foundation
import XCTest
@testable import Umma

/// Brief 019: the additive `cover_credit`, the recipe page photo presentation, and the viewer's
/// swipe-down rule.
@MainActor
final class RecipePhotoTests: XCTestCase {
    private static let credit: [String: Any] = [
        "name": "Jane Doe", "url": "https://www.pexels.com/@jane-doe", "source": "pexels", "future_field": 1,
    ]

    // MARK: - Decoding

    func testDetailDecodesCoverCredit() throws {
        let detail = try decodeDetail { $0["cover_credit"] = Self.credit }
        XCTAssertEqual(detail.coverCredit, CoverCredit(name: "Jane Doe", url: "https://www.pexels.com/@jane-doe", source: "pexels"))
    }

    func testDetailWithoutOrWithNullCoverCreditStillDecodes() throws {
        let old = try Fixtures.decode(RecipeDetail.self, from: "recipe_detail")
        XCTAssertNil(old.coverCredit, "older payloads have no cover_credit")
        let null = try decodeDetail { $0["cover_credit"] = NSNull() }
        XCTAssertNil(null.coverCredit)
    }

    func testCardDecodesCoverCredit() throws {
        let card = try decodeFirstCard { $0["cover_credit"] = Self.credit }
        XCTAssertEqual(card.coverCredit?.name, "Jane Doe")
        XCTAssertEqual(card.coverCredit?.source, "pexels")
    }

    func testCardWithoutOrWithNullCoverCreditStillDecodes() throws {
        let page = try Fixtures.decode(RecipePage.self, from: "recipes_list")
        XCTAssertNil(page.items.first?.coverCredit)
        let null = try decodeFirstCard { $0["cover_credit"] = NSNull() }
        XCTAssertNil(null.coverCredit)
    }

    // MARK: - Presentation

    private let photoURL = URL(string: "https://images.pexels.com/photos/1/pexels-photo-1.jpeg")!
    private let pexels = CoverCredit(name: "Jane Doe", url: "https://www.pexels.com/@jane-doe", source: "pexels")

    func testRealPhotoWithPexelsCreditShowsCreditLineAndOpensViewer() throws {
        let photo = RecipePhotoPresentation(imageURL: photoURL, credit: pexels)
        XCTAssertTrue(photo.opensViewer)
        XCTAssertEqual(photo.accessibilityLabel, "Recipe photo")
        XCTAssertEqual(photo.accessibilityHint, "Opens the photo full screen")
        let credit = try XCTUnwrap(photo.credit)
        XCTAssertEqual(credit.text, "Photo: Jane Doe / Pexels")
        XCTAssertEqual(credit.url.absoluteString, "https://www.pexels.com/@jane-doe")
        XCTAssertEqual(credit.accessibilityLabel, "Photo by Jane Doe on Pexels")
    }

    func testPlaceholderNeverOpensViewerOrShowsCredit() {
        let photo = RecipePhotoPresentation(imageURL: nil, credit: pexels)
        XCTAssertFalse(photo.opensViewer)
        XCTAssertNil(photo.credit, "a credit without a photo is never shown")
        XCTAssertEqual(photo.accessibilityLabel, "No photo yet")
        XCTAssertNil(photo.accessibilityHint)
    }

    func testCreatorPhotoHasNoCreditLine() {
        let photo = RecipePhotoPresentation(imageURL: photoURL, credit: nil)
        XCTAssertTrue(photo.opensViewer)
        XCTAssertNil(photo.credit)
    }

    func testUnusableCreditsAreHidden() {
        let bad = [
            CoverCredit(name: "  ", url: "https://www.pexels.com/@x", source: "pexels"),
            CoverCredit(name: "Jane", url: "javascript:alert(1)", source: "pexels"),
            CoverCredit(name: "Jane", url: "not a url", source: "pexels"),
            CoverCredit(name: "Jane", url: "https://example.test/@jane", source: "unsplash"),
        ]
        for credit in bad {
            XCTAssertNil(RecipePhotoPresentation(imageURL: photoURL, credit: credit).credit, "\(credit)")
        }
        let trimmed = RecipePhotoPresentation(imageURL: photoURL, credit: CoverCredit(name: " Jane ", url: "https://www.pexels.com/@jane", source: "Pexels"))
        XCTAssertEqual(trimmed.credit?.text, "Photo: Jane / Pexels")
    }

    func testViewModelPairsPhotoAndCreditFromTheSamePayload() async throws {
        let service = FakeRecipeService()
        let creatorPhoto = try decodeDetail { $0["cover_image_url"] = "https://media.example.test/creator.jpg" }
        service.detailHandler = { _ in creatorPhoto }
        let card = try decodeFirstCard {
            $0["cover_image_url"] = "https://images.pexels.com/photos/1/stock.jpeg"
            $0["cover_credit"] = Self.credit
        }
        let model = RecipeDetailViewModel(recipeId: creatorPhoto.recipeId, card: card, service: service)

        XCTAssertEqual(model.photo.credit?.text, "Photo: Jane Doe / Pexels", "before load: the card's stock photo and credit")
        await model.load()
        XCTAssertEqual(model.photo.imageURL?.absoluteString, "https://media.example.test/creator.jpg")
        XCTAssertNil(model.photo.credit, "the creator photo never carries the card's stale stock credit")
    }

    // MARK: - Viewer dismissal

    func testSwipeDownDismissal() {
        XCTAssertTrue(PhotoViewerDismissal.shouldDismiss(translation: 130, predictedEnd: 140))
        XCTAssertTrue(PhotoViewerDismissal.shouldDismiss(translation: 40, predictedEnd: 400), "a quick fling down")
        XCTAssertFalse(PhotoViewerDismissal.shouldDismiss(translation: 40, predictedEnd: 80))
        XCTAssertFalse(PhotoViewerDismissal.shouldDismiss(translation: -200, predictedEnd: -400), "upward never dismisses")
        XCTAssertEqual(PhotoViewerDismissal.backgroundOpacity(forDrag: 0), 1)
        XCTAssertEqual(PhotoViewerDismissal.backgroundOpacity(forDrag: 10_000), 0.5)
    }

    // MARK: - Helpers

    private func decodeDetail(_ edit: (inout [String: Any]) -> Void) throws -> RecipeDetail {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.data("recipe_detail")) as? [String: Any])
        edit(&object)
        return try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func decodeFirstCard(_ edit: (inout [String: Any]) -> Void) throws -> RecipeCard {
        var page = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.data("recipes_list")) as? [String: Any])
        var items = try XCTUnwrap(page["items"] as? [[String: Any]])
        edit(&items[0])
        page["items"] = items
        return try JSONCoding.makeDecoder().decode(RecipePage.self, from: JSONSerialization.data(withJSONObject: page)).items[0]
    }
}
