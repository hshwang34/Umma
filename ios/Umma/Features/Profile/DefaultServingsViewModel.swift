import Foundation
import Observation

/// One choice in Profile → Default servings.
struct DefaultServingsOption: Identifiable, Hashable, Sendable {
    /// `nil` is "Recipe’s own".
    let servings: Int?

    var id: Int { servings ?? 0 }
    var title: String { servings.map(String.init) ?? Self.recipesOwn }
    var accessibilityLabel: String { servings.map(ServingsDial.count) ?? Self.recipesOwn }

    static let recipesOwn = "Recipe’s own"
    static let all = [DefaultServingsOption(servings: nil)] + User.defaultServingsRange.map { DefaultServingsOption(servings: $0) }
}

/// Profile → Default servings (brief 020). "Recipe’s own" until the cook sets it; once set, every
/// recipe opens scaled to it. Each choice is saved on that tap and rolled back if the save fails.
@MainActor
@Observable
final class DefaultServingsViewModel {
    static let title = "Default servings"
    static let footer = "With default servings set, every recipe opens scaled to that number. You can still change it on the recipe."

    /// What the picker shows: the tapped value while it saves, otherwise the saved one.
    private(set) var selected: Int?
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private var saved: Int?
    private let service: ProfileService
    /// The server's copy of the user after a save, for the auth store.
    private let onSaved: @MainActor (User) -> Void

    init(current: Int?, service: ProfileService, onSaved: @escaping @MainActor (User) -> Void) {
        saved = current
        selected = current
        self.service = service
        self.onSaved = onSaved
    }

    var options: [DefaultServingsOption] { DefaultServingsOption.all }

    /// The signed-in user changed underneath (a refresh from the server).
    func sync(current: Int?) {
        guard !isSaving else { return }
        saved = current
        selected = current
    }

    /// One save at a time: the picker is disabled while this runs.
    func select(_ servings: Int?) async {
        guard !isSaving, servings != saved else { return }
        if let servings, !User.defaultServingsRange.contains(servings) { return }
        selected = servings
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let user = try await service.setDefaultServings(servings)
            saved = user.defaultServings
            selected = user.defaultServings
            onSaved(user)
        } catch let error as APIError where error == .cancelled {
            selected = saved
        } catch {
            selected = saved
            errorMessage = "Couldn’t save your default servings: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }
}
