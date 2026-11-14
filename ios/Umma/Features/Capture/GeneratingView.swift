import SwiftUI

/// After the wrap-up: Umma writes the draft (brief 014). Honest progress only; over a cap the
/// recording is kept and the creator can try later or type it in.
struct GeneratingView: View {
    let generator: CaptureDraftGenerator
    /// Opening the ready draft in the editor failed (the message); the draft button retries.
    var openError: String?
    var onTypeInstead: () -> Void
    var onOpenDraft: (UUID) -> Void
    var onClose: () -> Void

    var body: some View {
        let p = GeneratingPresentation(generator.state, openError: openError)
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Image(systemName: p.showsRetry ? "tray.full" : "text.badge.star")
                    .font(SLFont.glyph)
                    .foregroundStyle(SLColor.tomato)
                    .frame(width: 88, height: 88)
                    .background(SLColor.brandSoft, in: Circle())
                    .accessibilityHidden(true)
                Text(p.title)
                    .font(SLFont.title2)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("generating.title")
                Text(p.message)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("generating.message")
                if let progress = p.progress {
                    ProgressView(value: progress)
                        .tint(SLColor.brand)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                } else if p.showsSpinner {
                    ProgressView().controlSize(.large)
                }
                VStack(spacing: Spacing.sm) {
                    if p.showsOpenDraft, let draftId = openableDraftId {
                        Button(openError == nil ? "Open the draft" : "Try again") { onOpenDraft(draftId) }
                            .buttonStyle(SLButtonStyle(prominent: true))
                            .accessibilityIdentifier("generating.openDraft")
                    }
                    if p.showsRetry {
                        Button("Try again") { generator.start() }
                            .buttonStyle(SLButtonStyle(prominent: !p.showsOpenDraft))
                            .accessibilityIdentifier("generating.retry")
                    }
                    if p.showsTypeIn {
                        Button("Type it in instead", action: onTypeInstead)
                            .buttonStyle(SLButtonStyle(prominent: false))
                            .accessibilityIdentifier("generating.typeIn")
                    }
                }
                .padding(.top, Spacing.sm)
            }
            .padding(Spacing.screen)
            .padding(.top, Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(SLColor.background)
        .navigationTitle("New recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onClose)
                    .accessibilityIdentifier("generating.close")
            }
        }
        .task { generator.start() }
        .onDisappear { generator.cancel() }
        .onChange(of: openError) { _, error in
            if let error { AccessibilityNotification.Announcement("Couldn’t open the draft. \(error)").post() }
        }
    }

    /// The draft the button opens: a ready one, or the editable partial of a failed job.
    private var openableDraftId: UUID? {
        switch generator.state {
        case .ready(let draftId, _): return draftId
        case .failed(_, let draftId): return draftId
        default: return nil
        }
    }
}
