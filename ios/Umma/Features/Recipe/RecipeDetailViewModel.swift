import Foundation
import Observation

/// Recipe detail state: load, Save/Unsave (optimistic, rolled back on error), owner actions.
@MainActor
@Observable
final class RecipeDetailViewModel {
    enum Phase: Equatable {
        case loading
        case loaded(RecipeDetail)
        case error(String, retryable: Bool)
    }

    let recipeId: UUID
    /// Card from the list (header placeholder while the detail loads); nil when opened by id (deep link).
    let card: RecipeCard?

    private(set) var phase: Phase = .loading
    /// Optimistic saved flag; seeded from the server's `saved` (nil → treated as not saved).
    private(set) var isSaved = false
    private(set) var isTogglingSave = false
    /// Inline message after a failed save/unsave; cleared on the next attempt.
    private(set) var saveError: String?
    private(set) var isUnpublishing = false
    private(set) var actionError: String?
    /// Set after a successful unpublish so the screen can say so honestly.
    private(set) var unpublishedVisibility: RecipeVisibility?

    private let service: RecipeService
    /// Fired after the server confirms a save-state change (not on rollback). The view uses it to
    /// tell the Saved tab to refresh.
    var onSavedChanged: (@MainActor (UUID, Bool) -> Void)?

    init(recipeId: UUID, card: RecipeCard? = nil, service: RecipeService) {
        self.recipeId = recipeId
        self.card = card
        self.service = service
        if let saved = card?.saved { isSaved = saved }
    }

    var detail: RecipeDetail? {
        if case .loaded(let detail) = phase { return detail }
        return nil
    }

    var title: String { detail?.title ?? card?.title ?? "Recipe" }
    var creatorName: String? { detail?.creator.displayName ?? card?.creator.displayName }
    var creatorId: UUID? { detail?.creator.id ?? card?.creator.id }
    var versionNumber: Int? { detail?.versionNumber ?? card?.versionNumber }
    var summary: String? { detail?.summary ?? card?.summary }
    var servings: Int? { detail?.servings ?? card?.servings }

    // MARK: Servings (brief 020)

    /// What the cook dialled on this visit. Nil until they touch the dial: the recipe then shows
    /// its own servings. Never saved; a published version is never changed.
    private(set) var chosenServings: Int?

    /// The servings control, once the recipe has loaded.
    var dial: ServingsDial? {
        detail.flatMap { ServingsDial(original: $0.servings, chosen: chosenServings) }
    }

    /// Ingredient amounts for the servings on the dial. At the recipe's own servings these are
    /// exactly the creator's.
    var ingredients: [Ingredient] {
        guard let detail, let dial else { return detail?.ingredients ?? [] }
        return detail.ingredients.map { $0.scaled(originalServings: dial.original, servings: dial.servings) }
    }

    /// A value that is not a stop on this recipe's dial is ignored.
    func setServings(_ servings: Int) {
        guard let dial, dial.stops.contains(servings) else { return }
        chosenServings = servings
    }

    func stepServings(up: Bool) {
        guard let next = up ? dial?.higher : dial?.lower else { return }
        chosenServings = next
    }

    /// One tap back to the creator's amounts.
    func resetServings() {
        guard let dial else { return }
        chosenServings = dial.original
    }
    var prepMinutes: Int? { detail?.prepMinutes ?? card?.prepMinutes }
    var cookMinutes: Int? { detail?.cookMinutes ?? card?.cookMinutes }
    var coverImageURL: URL? { detail?.coverImageURL ?? card?.coverImageURL }
    /// Brief 019: the photo and its credit always come from the same payload, so a creator photo
    /// on the detail never carries a stale stock credit from the card.
    var photo: RecipePhotoPresentation {
        if let detail, detail.coverImageURL != nil {
            return RecipePhotoPresentation(imageURL: detail.coverImageURL, credit: detail.coverCredit)
        }
        return RecipePhotoPresentation(imageURL: card?.coverImageURL, credit: card?.coverCredit)
    }
    /// Server-provided when present; otherwise the contract's canonical universal link.
    var shareURL: URL { detail?.shareURL ?? ShareLinks.universal(recipeId: recipeId) }

    func isOwner(userId: UUID?) -> Bool {
        guard let userId, let detail else { return false }
        return detail.creator.id == userId
    }

    func load() async {
        phase = .loading
        do {
            let detail = try await service.recipe(id: recipeId)
            phase = .loaded(detail)
            // A toggle in flight owns `isSaved`; a reload must not overwrite the optimistic value.
            if let saved = detail.saved, !isTogglingSave { isSaved = saved }
        } catch let error as APIError {
            if error == .cancelled { return }
            phase = .error(error.userMessage, retryable: error.isRetryable)
        } catch {
            phase = .error(error.localizedDescription, retryable: true)
        }
    }

    /// Flip immediately, confirm with the idempotent POST/DELETE, roll back if the call fails.
    func toggleSave() async {
        guard !isTogglingSave else { return }
        let previous = isSaved
        let target = !previous
        isSaved = target
        isTogglingSave = true
        saveError = nil
        defer { isTogglingSave = false }
        do {
            let result = target ? try await service.saveRecipe(id: recipeId) : try await service.unsaveRecipe(id: recipeId)
            isSaved = result.saved
            if result.saved != previous { onSavedChanged?(recipeId, result.saved) }
        } catch let error as APIError where error == .cancelled {
            isSaved = previous
        } catch {
            isSaved = previous
            saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    func setActionError(_ message: String?) {
        actionError = message
    }

    /// Owner only; the view asks for confirmation first. Returns true on success.
    @discardableResult
    func unpublish() async -> Bool {
        guard !isUnpublishing else { return false }
        isUnpublishing = true
        actionError = nil
        defer { isUnpublishing = false }
        do {
            let result = try await service.unpublishRecipe(id: recipeId)
            unpublishedVisibility = result.visibility
            return true
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            return false
        }
    }
}
