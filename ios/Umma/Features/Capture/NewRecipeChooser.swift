import SwiftUI

enum CaptureFeature {
    /// `feature.voiceCapture`: Profile → New recipe opens the chooser with Record while cooking.
    nonisolated static let flagKey = "feature.voiceCapture"

    /// On by default since the draft step landed; `-feature.voiceCapture NO` hides it for demos.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads `-feature.voiceCapture NO` from the launch arguments.
        defaults.object(forKey: flagKey) == nil || defaults.bool(forKey: flagKey)
    }
}

/// Profile → New recipe (brief 014): record while cooking, record with camera (coming soon), or
/// type it in.
struct NewRecipeChooser: View {
    var onChoose: (NewRecipeOption.Kind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("How do you want to add it?")
                        .font(SLFont.title3)
                        .foregroundStyle(SLColor.textPrimary)
                        .padding(.bottom, Spacing.xs)
                    ForEach(NewRecipeOption.all) { option in
                        OptionRow(option: option) {
                            dismiss()
                            onChoose(option.kind)
                        }
                    }
                }
                .padding(Spacing.screen)
            }
            .background(SLColor.background)
            .navigationTitle("New recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct OptionRow: View {
    let option: NewRecipeOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: option.symbolName)
                    .font(SLFont.title3)
                    .foregroundStyle(option.isEnabled ? SLColor.tomato : SLColor.textSecondary)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .background(option.isEnabled ? SLColor.brandSoft : SLColor.surfaceRaised, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.sm) { titleText; badge }
                        VStack(alignment: .leading, spacing: Spacing.xs) { titleText; badge }
                    }
                    Text(option.detail)
                        .font(SLFont.subheadline)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if option.isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(SLColor.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(option.accessibilityIdentifier)
    }

    private var titleText: some View {
        Text(option.title)
            .font(SLFont.headline)
            .foregroundStyle(option.isEnabled ? SLColor.textPrimary : SLColor.textSecondary)
    }

    @ViewBuilder
    private var badge: some View {
        if let badge = option.badge {
            MetadataPill(text: badge, systemImage: "clock", style: .accent)
        }
    }
}

#Preview {
    NewRecipeChooser { _ in }
}

#Preview("Dark, AX5") {
    NewRecipeChooser { _ in }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
