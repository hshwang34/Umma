import SwiftUI

/// What the cook confirms on the Start tap (brief 020). Servings are fixed when the cook is
/// created, so the number and "Scaled from N" are stated before anything is sent.
struct StartConfirmation: Equatable, Sendable {
    let servings: Int
    let title: String
    let message: String
    let confirmTitle: String

    static let cancelTitle = "Not yet"
    static let lockedNote = "Servings can’t be changed once you start."

    init(choice: ServingsChoice) {
        servings = choice.servings
        title = "Cooking for \(choice.servings)"
        confirmTitle = "Start cooking for \(choice.servings)"
        message = choice.isScaled
            ? "\(ServingsDial.scaledFrom(choice.original)). \(ServingsDial.notice) \(Self.lockedNote)"
            : Self.lockedNote
    }
}

extension View {
    /// The "Cooking for N" confirmation. `onConfirm` gets exactly what the dialog stated.
    func startConfirmation(_ confirmation: Binding<StartConfirmation?>,
                           onConfirm: @escaping (StartConfirmation) -> Void) -> some View {
        confirmationDialog(
            confirmation.wrappedValue?.title ?? "Start cooking",
            isPresented: Binding(get: { confirmation.wrappedValue != nil }, set: { if !$0 { confirmation.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: confirmation.wrappedValue
        ) { stated in
            Button(stated.confirmTitle) { onConfirm(stated) }
            Button(StartConfirmation.cancelTitle, role: .cancel) {}
        } message: { stated in
            Text(stated.message)
        }
    }
}

/// The cook screen's servings line: the session's own number, and that amounts are scaled when
/// they are. There is no control here: servings are locked once cooking starts.
struct SessionServings: Equatable, Sendable {
    let title: String
    let scaledFromText: String?
    let notice: String?

    init(session: CookingSession) {
        title = "Cooking for \(session.servings)"
        scaledFromText = session.amountsScaled ? ServingsDial.scaledFrom(session.originalServings) : nil
        notice = session.amountsScaled ? ServingsDial.notice : nil
    }

    var isScaled: Bool { scaledFromText != nil }
    var accessibilityLabel: String { [title, scaledFromText, notice].compactMap { $0 }.joined(separator: ". ") }
}

/// One ingredient of the current step, with the session's amount (already scaled by the server).
struct StepIngredientRow: Identifiable, Equatable, Sendable {
    let id: String
    /// "200 g", or nil for "to taste".
    let amountText: String?
    let name: String
    /// "instead of rice vinegar" for an approved swap, "optional" for an optional ingredient.
    let detail: String?

    var accessibilityLabel: String { [amountText, name, detail].compactMap { $0 }.joined(separator: ", ") }

    /// The current step's ingredients in the step's own order. An approved swap shows the
    /// replacement and its amount as the swap stated it. A ref the recipe doesn't have is skipped.
    static func rows(session: CookingSession) -> [StepIngredientRow] {
        guard let step = session.currentRecipeStep else { return [] }
        var seen = Set<String>()
        return step.ingredientRefs.compactMap { ref -> StepIngredientRow? in
            guard seen.insert(ref).inserted, let ingredient = session.recipe.ingredients.first(where: { $0.id == ref }) else { return nil }
            if let swap = session.adaptations.first(where: { $0.ingredientRef == ref }) {
                return StepIngredientRow(id: ref, amountText: swap.ratioOrAmount, name: swap.replacement,
                                         detail: "instead of \(swap.original)")
            }
            return StepIngredientRow(id: ref, amountText: RecipeFormatting.quantity(ingredient.quantity, unit: ingredient.unit),
                                     name: ingredient.name, detail: ingredient.optional ? "optional" : nil)
        }
    }
}

/// Under the step: what this step uses, in the session's amounts, and the scaled notice.
/// Nothing is shown for an unscaled cook on a step that names no ingredients.
struct StepAmountsView: View {
    let servings: SessionServings
    let rows: [StepIngredientRow]

    var body: some View {
        if servings.isScaled || !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Label(servings.title, systemImage: "person.2")
                        .font(SLFont.subheadline.weight(.semibold))
                        .foregroundStyle(SLColor.textPrimary)
                    if let scaledFrom = servings.scaledFromText {
                        MetadataPill(text: scaledFrom, style: .accent)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(servings.accessibilityLabel)
                .accessibilityIdentifier("cooking.servings")
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                        Text(row.amountText ?? "—")
                            .font(SLFont.quantity)
                            .foregroundStyle(SLColor.accent)
                            .frame(minWidth: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.name).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
                            if let detail = row.detail {
                                Text(detail).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityIdentifier("cooking.stepIngredient")
                }
                if let notice = servings.notice {
                    Text(notice)
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }
}
