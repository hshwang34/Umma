import Foundation

/// SEAM, not built yet (brief 017 PR 8, the in-cook part): "I don’t have that" during cooking.
///
/// The backend `missing_ingredient` coach intent (brief 017 PR 7) is still being written. When it
/// lands, the assistant's answer will carry what happened (pantry item removed, shopping item
/// added) and an optional swap drawn from the pantry. The plan for this side:
/// - `AssistantViewModel` maps that answer to a `MissingIngredientOffer`;
/// - `AssistantDrawerView` shows it with one "Use this swap" approval (SUB-03), or says that
///   nothing suitable exists (SUB-05);
/// - approving goes through the existing adaptation command, never around the Step Oracle.
///
/// Until then nothing in the app creates one of these, and `isAvailable` stays false.
struct MissingIngredientOffer: Equatable, Sendable {
    static let isAvailable = false

    let ingredientName: String
    /// A swap from the cook's own pantry, if the coach found one. Applying it needs a tap.
    let swapCandidate: String?
}
