import SwiftUI

/// One capture run, presented full screen from Profile: record, wrap up, generate, review.
@MainActor
final class CaptureFlow: Identifiable {
    let id = UUID()
    let coordinator: CaptureCoordinator
    let generator: CaptureDraftGenerator
    let resumeRecord: CaptureJournalRecord?

    init(coordinator: CaptureCoordinator, generator: CaptureDraftGenerator, resumeRecord: CaptureJournalRecord? = nil) {
        self.coordinator = coordinator
        self.generator = generator
        self.resumeRecord = resumeRecord
    }
}

extension AppEnvironment {
    /// A capture run on the voice transport the user's tier calls for.
    func makeCaptureFlow(resuming record: CaptureJournalRecord? = nil) -> CaptureFlow {
        var makeVoice: (VoiceSessionConfig) -> VoiceSession = { self.makeVoiceSession(config: $0) }
        #if DEBUG
        // UI walkthrough only (`-capture.script kimchi`): a scripted cook instead of the mic.
        if let name = UserDefaults.standard.string(forKey: "capture.script"), let scripted = ScriptedVoiceTransport.named(name) {
            makeVoice = { VoiceSession(transport: scripted, config: $0) }
        }
        #endif
        let coordinator = CaptureCoordinator(api: api, makeVoice: makeVoice, journal: captureJournal, userId: auth.user?.id)
        return CaptureFlow(coordinator: coordinator,
                           generator: CaptureDraftGenerator(api: api, coordinator: coordinator),
                           resumeRecord: record)
    }

    /// Unfinished recordings on this phone for the signed-in user, newest first.
    func pendingCaptures() -> [CaptureJournalRecord] {
        captureJournal.pending(userId: auth.user?.id)
    }
}

struct CaptureFlowView: View {
    let flow: CaptureFlow
    var onTypeInstead: () -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: DraftEditorViewModel?
    @State private var openError: String?

    var body: some View {
        Group {
            if let editor {
                // The existing editor and its publish confirmation; Close ends the flow.
                DraftEditorView(model: editor)
            } else {
                NavigationStack {
                    switch flow.coordinator.phase {
                    case .readyToGenerate:
                        GeneratingView(generator: flow.generator,
                                       openError: openError,
                                       onTypeInstead: typeInstead,
                                       onOpenDraft: { id in Task { await openDraft(id) } },
                                       onClose: { dismiss() })
                    default:
                        RecordView(coordinator: flow.coordinator, resumeRecord: flow.resumeRecord,
                                   onTypeInstead: typeInstead, onClose: { dismiss() })
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        // The mic never outlives the screen: the app going to the background, sign-out, a deep
        // link or another cover replacing this one all stop it; the journal keeps the words.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, CaptureFlowView.micMayBeOn(flow.coordinator.phase) { flow.coordinator.stopForNow() }
        }
        .onDisappear { flow.coordinator.stopForNow() }
        .task {
            // A recording that was already finished goes straight to making the draft (no mic).
            if let record = flow.resumeRecord, record.stage != .recording, flow.coordinator.phase == .idle {
                await flow.coordinator.resume(from: record)
            }
        }
        .onChange(of: flow.generator.state) { _, state in
            if case .ready(let draftId, _) = state { Task { await openDraft(draftId) } }
        }
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

    /// Opens the draft in the editor. A failure is shown on the generating screen with a retry,
    /// never left on "Opening it in the editor…".
    private func openDraft(_ id: UUID) async {
        guard editor == nil else { return }
        guard let user = environment.auth.user else {
            openError = "You’re signed out. Sign in, then try again."
            return
        }
        openError = nil
        do {
            editor = try await DraftEditorViewModel.open(draftId: id, service: environment.api,
                                                         creator: Creator(id: user.id, displayName: user.displayName))
        } catch {
            openError = CaptureCoordinator.message(error)
        }
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
