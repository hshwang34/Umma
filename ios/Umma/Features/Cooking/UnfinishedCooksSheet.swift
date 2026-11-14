import SwiftUI

/// "Already cooking" (409 on Start cooking: too many recipes in progress): Resume one, or stop one (after a
/// confirmation) and the start is retried. The cooking screen is presented by the parent's
/// `onDismiss`, after this sheet has gone.
struct UnfinishedCooksSheet: View {
    let starter: SessionStarter
    @State private var toAbandon: SessionSummary?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(starter.unfinished) { summary in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(summary.title).font(SLFont.headline)
                            Text(Self.stepText(summary))
                                .font(SLFont.subheadline)
                                .foregroundStyle(SLColor.textSecondary)
                            if starter.changedSessionIds.contains(summary.id) {
                                Label("Changed since you looked", systemImage: "arrow.triangle.2.circlepath")
                                    .font(SLFont.caption.weight(.semibold))
                                    .foregroundStyle(SLColor.warning)
                            }
                            HStack(spacing: Spacing.sm) {
                                Button("Resume") { starter.chooseResume(summary.id) }
                                    .disabled(starter.isBusy)
                                    .buttonStyle(.borderedProminent)
                                    .tint(SLColor.accent)
                                    .accessibilityIdentifier("unfinished.resume")
                                Button("Stop cooking", role: .destructive) { toAbandon = summary }
                                    .buttonStyle(.bordered)
                                    .disabled(starter.isBusy)
                                    .accessibilityIdentifier("unfinished.abandon")
                                if starter.abandoningId == summary.id || starter.isStarting { ProgressView() }
                            }
                            .frame(minHeight: Metrics.minTapTarget)
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                } footer: {
                    Text("You’re already cooking these. Resume one, or stop one to start this recipe.")
                }
                if let error = starter.errorMessage {
                    Section { Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger) }
                }
            }
            .interactiveDismissDisabled(starter.isBusy)
            .navigationTitle("Already cooking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { starter.dismissUnfinished() }
                        .disabled(starter.isBusy)
                }
            }
            .confirmationDialog("Stop cooking “\(toAbandon?.title ?? "")”?", isPresented: Binding(get: { toAbandon != nil }, set: { if !$0 { toAbandon = nil } }), titleVisibility: .visible) {
                Button("Stop cooking", role: .destructive) {
                    if let summary = toAbandon { Task { await starter.abandon(summary) } }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                if let summary = toAbandon {
                    Text("\(Self.stepText(summary)). You’ll lose your place and its swaps, and this recipe starts instead.")
                }
            }
        }
    }

    static func stepText(_ summary: SessionSummary) -> String {
        if summary.status == .created { return "Not started" }
        let step = min(summary.stepIndex, max(summary.stepsCount - 1, 0)) + 1
        return "\(summary.status == .paused ? "Paused at" : "At") step \(step) of \(summary.stepsCount)"
    }
}
