import SwiftUI

/// One capture run, presented full screen from Profile.
@MainActor
final class CaptureFlow: Identifiable {
    let id = UUID()
    let coordinator: CaptureCoordinator
    let resumeRecord: CaptureJournalRecord?

    init(coordinator: CaptureCoordinator, resumeRecord: CaptureJournalRecord? = nil) {
        self.coordinator = coordinator
        self.resumeRecord = resumeRecord
    }
}

extension AppEnvironment {
    /// A capture run on the voice transport the user's tier calls for.
    func makeCaptureFlow(resuming record: CaptureJournalRecord? = nil) -> CaptureFlow {
        let coordinator = CaptureCoordinator(api: api, makeVoice: { self.makeVoiceSession(config: $0) }, userId: auth.user?.id)
        return CaptureFlow(coordinator: coordinator, resumeRecord: record)
    }

    /// Unfinished recordings on this phone for the signed-in user, newest first.
    func pendingCaptures() -> [CaptureJournalRecord] {
        CaptureJournalStore.live.pending(userId: auth.user?.id)
    }
}

struct CaptureFlowView: View {
    let flow: CaptureFlow
    var onTypeInstead: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            switch flow.coordinator.phase {
            case .readyToGenerate:
                RecordingSavedView { dismiss() }
            default:
                RecordView(coordinator: flow.coordinator, resumeRecord: flow.resumeRecord,
                           onTypeInstead: typeInstead, onClose: { dismiss() })
            }
        }
        .interactiveDismissDisabled()
        // The mic never outlives the screen: the app going to the background, sign-out, a deep
        // link or another cover replacing this one all stop it; the journal keeps the words.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, CaptureFlowView.micMayBeOn(flow.coordinator.phase) { flow.coordinator.stopForNow() }
        }
        .onDisappear { flow.coordinator.stopForNow() }
    }

    static func micMayBeOn(_ phase: CaptureCoordinator.Phase) -> Bool {
        switch phase {
        // .voiceStopped too: Resume from there awaits the mic while the phase is unchanged.
        case .starting, .recording, .paused, .finishing, .wrappingUp, .voiceStopped: true
        default: false
        }
    }

    private func typeInstead() {
        dismiss()
        onTypeInstead()
    }

}

/// Until drafts are generated from recordings (next PR): the recording is safe on the server.
private struct RecordingSavedView: View {
    var onClose: () -> Void

    var body: some View {
        EmptyStateView(systemImage: "checkmark.circle", title: "Recording saved",
                       message: "Everything you said is saved. Turning it into a recipe arrives in the next update.",
                       primary: EmptyStateView.Action("Close", handler: onClose))
            .background(SLColor.background)
    }
}

/// Profile row: an unfinished recording left by a crash, a relaunch or "Stop for now".
struct CaptureResumeRow: View {
    let record: CaptureJournalRecord
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "waveform.circle.fill")
                    .font(SLFont.title3)
                    .foregroundStyle(SLColor.tomato)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(record.titleHint ?? "Unfinished recording")
                        .font(SLFont.headline)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(subtitle)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Metrics.minTapTarget)
        }
        .accessibilityHint("Resume or finish this recording")
        .accessibilityIdentifier("profile.captureResume")
    }

    var subtitleForTests: String { subtitle }

    private var subtitle: String {
        let lines = "\(record.lines.count) line\(record.lines.count == 1 ? "" : "s") heard"
        if record.discardPending == true { return "Discard pending: couldn’t reach Umma yet. Tap to try again." }
        switch record.stage {
        case .recording: return "Not finished · \(lines). Tap to continue."
        case .wrappingUp, .generating: return "Recorded · \(lines). Tap to make the recipe."
        }
    }
}
