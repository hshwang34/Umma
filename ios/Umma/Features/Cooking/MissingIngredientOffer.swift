import Foundation

/// "I don’t have that" while cooking (brief 017): what the coach's answer offers, as displayed.
///
/// The backend only describes; nothing has happened when this is shown. Each button is its own
/// explicit tap on an existing confirmed path: the swap through the `approve_adaptation` session
/// command (never around the Step Oracle), the shopping list through `POST /shopping-list`, the
/// pantry through `DELETE /pantry/{id}`. Tapping one never does another.
struct MissingIngredientOffer: Equatable, Sendable {
    enum Action: String, CaseIterable, Sendable {
        case useSwap, addToShoppingList, removeFromPantry

        var title: String {
            switch self {
            case .useSwap: return "Use this swap"
            case .addToShoppingList: return "Add to shopping list"
            case .removeFromPantry: return "Remove from pantry"
            }
        }
    }

    /// What the cook has done with one offer.
    struct State: Equatable, Sendable {
        var swapApplied = false
        var addedToShoppingList = false
        var removedFromPantry = false
        var picked = false
        var busy: Action?
        var error: String?
    }

    static let whichPrompt = "Which one don’t you have?"
    static let swapFailed = "That swap wasn’t applied. Nothing changed. Try again."
    static let shoppingFailed = "Couldn’t add it to your shopping list. Try again."
    static let pantryFailed = "Couldn’t remove it from your pantry. Try again."
    /// Sent to the coach when the cook picks from "which one?". Plain apostrophe: it is matched as typed.
    static func pickQuery(_ name: String) -> String { "I don't have \(name)" }

    /// "Which one don’t you have?" with `candidates`, or nil for an offer.
    let prompt: String?
    let candidates: [MissingIngredient.Candidate]
    /// Shown first and prominently: "Check the label: contains soy".
    let allergyWarning: String?
    /// "Swap: tamari".
    let swapTitle: String?
    let swapAmount: String?
    /// "In your pantry" when the swap is something the cook already has.
    let inPantryText: String?
    let risks: [String]
    /// Why there is no swap to offer (SUB-05), in the coach's words.
    let noSwapText: String?
    /// What has been done or is already so: "Swap in use", "On your shopping list", …
    let statuses: [String]
    /// The buttons, in order. Each is one explicit tap.
    let actions: [Action]
    let busy: Action?
    let error: String?

    /// Nil when there is nothing the app can show (an unknown status, or an offer naming nothing).
    init?(missing: MissingIngredient, state: State, session: CookingSession?, canShop: Bool = true, canEditPantry: Bool = true) {
        busy = state.busy
        error = state.error
        switch missing.status {
        case .unknown:
            return nil
        case .which:
            // Once the cook has picked, the question is answered by the next turn.
            guard !missing.candidates.isEmpty, !state.picked else { return nil }
            prompt = Self.whichPrompt
            candidates = missing.candidates
            allergyWarning = nil
            swapTitle = nil
            swapAmount = nil
            inPantryText = nil
            risks = []
            noSwapText = nil
            statuses = []
            actions = []
        case .offer:
            guard let name = missing.name, !name.isEmpty else { return nil }
            prompt = nil
            candidates = []
            var statuses: [String] = []
            var actions: [Action] = []

            let swap = missing.swap
            let alreadySwapped = swap.map { swap in session?.adaptations.contains { $0.ingredientRef == swap.adaptation.ingredientRef } ?? false } ?? false
            allergyWarning = swap?.allergyWarning.flatMap { $0.isEmpty ? nil : "Check the label: \($0)" }
            swapTitle = swap.map { "Swap: \($0.candidate)" }
            swapAmount = swap.flatMap { $0.ratioOrAmount.isEmpty ? nil : $0.ratioOrAmount }
            inPantryText = swap?.inPantry == true ? "In your pantry" : nil
            risks = swap?.risks ?? []
            noSwapText = swap == nil ? missing.noSwapReason.flatMap { $0.isEmpty ? nil : $0 } : nil
            if swap != nil {
                if state.swapApplied || alreadySwapped {
                    statuses.append("Swap in use")
                } else if session?.status.isOpen == true {
                    actions.append(.useSwap)
                }
            }
            if let shoppingName = missing.shoppingName, !shoppingName.isEmpty {
                if state.addedToShoppingList || missing.onShoppingList {
                    statuses.append("On your shopping list")
                } else if canShop {
                    actions.append(.addToShoppingList)
                }
            }
            // Only when the pantry actually holds it.
            if missing.pantryItemId != nil {
                if state.removedFromPantry {
                    statuses.append("Removed from your pantry")
                } else if canEditPantry {
                    actions.append(.removeFromPantry)
                }
            }
            self.statuses = statuses
            self.actions = actions
        }
    }
}
