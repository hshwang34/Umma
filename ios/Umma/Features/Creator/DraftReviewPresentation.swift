import Foundation

/// Review labels for an AI-drafted recipe (brief 014 / 008): AI fields say "AI-drafted, check
/// this"; quantities and times the creator never said stay empty and say "needs review". Nil
/// (no labels at all) for a hand-authored draft.
struct DraftReviewPresentation: Equatable {
    static let aiLabel = "AI-drafted, check this"
    static let needsReview = "needs review"

    let bannerTitle: String
    let bannerMessage: String
    /// Demo (AI-off) notice from the server, shown as is.
    let notice: String?
    /// What the creator never said, from `extraction.unknowns`.
    let unknowns: [String]
    let servingsNeedsReview: Bool
    let cookTimeNeedsReview: Bool
    let prepTimeNeedsReview: Bool

    init?(draft: Draft, form: DraftForm) {
        guard let extraction = draft.extraction else { return nil }
        bannerTitle = extraction.demo ? "Demo draft from your recording" : "AI-drafted from your recording"
        bannerMessage = "Check every field marked “\(Self.aiLabel)”. Anything you didn’t say is left empty and marked “\(Self.needsReview)”, never guessed."
        notice = extraction.notice
        unknowns = extraction.unknowns
        servingsNeedsReview = form.servingsUnset
        cookTimeNeedsReview = form.cookMinutes == nil
        prepTimeNeedsReview = form.prepMinutes == nil
    }

    static func ingredientLabels(_ ingredient: EditableIngredient, isAIDraft: Bool) -> [String] {
        guard isAIDraft else { return [] }
        var labels: [String] = []
        if ingredient.evidenceOrigin == .aiExtracted || ingredient.evidenceOrigin == .unknown { labels.append(aiLabel) }
        if ingredient.quantity == nil, !ingredient.optional { labels.append("Amount \(needsReview)") }
        return labels
    }

    static func stepLabels(_ step: EditableStep, isAIDraft: Bool) -> [String] {
        guard isAIDraft else { return [] }
        return step.evidenceOrigin == .aiExtracted || step.evidenceOrigin == .unknown ? [aiLabel] : []
    }
}
