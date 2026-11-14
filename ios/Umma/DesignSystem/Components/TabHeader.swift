import SwiftUI

/// Brief 019: a tab's own header, in place of the standard navigation bar on the tab's top-level
/// screen. The title sits at the top left in the brand face, with optional trailing controls
/// (Pantry's mic / camera / +, Profile's settings). It scrolls with the content.
///
/// The root view hides the bar with `.tabRootHeader()`; screens pushed from the tab keep the
/// standard bar and back button.
struct TabHeader<Trailing: View>: View {
    let title: String
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        let layout = TabHeaderLayout.stacksVertically(for: dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.md))
        layout {
            Text(title)
                .font(SLFont.display)
                .foregroundStyle(SLColor.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tabHeader.title")
            HStack(spacing: Spacing.xs) {
                trailing
            }
            .labelStyle(.iconOnly)
            .font(SLFont.title3)
            .foregroundStyle(SLColor.accent)
            .buttonStyle(TabHeaderButtonStyle())
        }
        .padding(.top, TabHeaderLayout.topPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TabHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Header buttons: icon-only, at least a 44pt target, the accent colour, dimmed when pressed.
private struct TabHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// Layout rules, kept pure so they can be tested.
enum TabHeaderLayout {
    /// Standard top padding under the status bar (the scroll content already starts below it).
    static let topPadding: CGFloat = Spacing.sm

    /// At accessibility sizes the title takes the full width and the controls drop below it,
    /// so neither truncates.
    static func stacksVertically(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }
}

extension View {
    /// Hides the navigation bar on a tab's root content only (brief 019). Apply it inside the
    /// `NavigationStack`, on the root view, never on the stack itself, so pushed screens keep
    /// their bar and back button.
    func tabRootHeader() -> some View {
        toolbar(.hidden, for: .navigationBar)
    }

    /// For a screen pushed from a tab root: the standard bar, stated explicitly.
    func pushedFromTabRoot() -> some View {
        toolbar(.visible, for: .navigationBar)
    }
}

/// Brief 019: an in-page search field (Explore), in place of `.searchable`. Return submits and
/// dismisses the keyboard; the clear button empties the text and submits at once.
struct InPageSearchField: View {
    @Binding var text: String
    let prompt: String
    var identifier = "search"
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit {
                    focused = false
                    onSubmit()
                }
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(identifier)
            if InPageSearchFieldRules.showsClear(text: text) {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SLColor.textSecondary)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("\(identifier).clear")
            }
        }
        .padding(.leading, Spacing.md)
        .frame(minHeight: Metrics.minTapTarget)
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .onTapGesture { focused = true }
    }
}

enum InPageSearchFieldRules {
    static func showsClear(text: String) -> Bool { !text.isEmpty }
}
