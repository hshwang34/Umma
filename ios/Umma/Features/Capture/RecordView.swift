import SwiftUI
import UIKit

/// Brief 014 recording screen: the voice bar with live captions, elapsed time, a quiet "heard so
/// far" list, a question card while Umma asks, and Pause / Done. Listening starts only on Start.
struct RecordView: View {
    let coordinator: CaptureCoordinator
    /// A journaled session to continue (relaunch), instead of starting a new one.
    var resumeRecord: CaptureJournalRecord?
    var onTypeInstead: () -> Void
    var onClose: () -> Void

    @State private var titleHint = ""
    @State private var showCloseOptions = false
    /// The Start / Continue task, cancelled on Close or when the screen goes away.
    @State private var startTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: RecordPresentation {
        RecordPresentation(
            phase: coordinator.phase,
            question: coordinator.question,
            heard: coordinator.heard.map(\.text),
            elapsedMs: coordinator.nowMs,
            askingStopped: coordinator.askingStopped,
            isRetrying: coordinator.isRetrying,
            wrapUp: (coordinator.wrapUpIndex, coordinator.wrapUpQuestions.count)
        )
    }

    var body: some View {
        // The timer and captions re-read the coordinator every second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(presentation)
        }
        .background(SLColor.background)
        .navigationTitle(presentation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { close() }
                    .accessibilityIdentifier("record.close")
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $showCloseOptions, titleVisibility: .visible) {
            Button("Stop for now") {
                coordinator.stopForNow()
                onClose()
            }
            Button("Discard recording", role: .destructive) {
                Task {
                    await coordinator.discard()
                    onClose()
                }
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Stop for now keeps everything you said; you can resume or finish it from Profile. Discard deletes the recording.")
        }
        .onChange(of: presentation.keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            startTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @ViewBuilder
    private func content(_ p: RecordPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header(p)
                switch coordinator.phase {
                case .idle:
                    startCard
                case .failed:
                    failedCard
                default:
                    if p.showsVoiceBar {
                        VoiceBarContent(presentation: RecordPresentation.voiceBar(coordinator.voice, hidingQuestion: p.card?.question))
                            .accessibilityIdentifier("record.voiceBar")
                    }
                    if let card = p.card { QuestionCardView(card: card, coordinator: coordinator) }
                    if let notice = p.notice {
                        Label(notice, systemImage: "wifi.slash")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.warning)
                            .padding(Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SLColor.warningSurface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    heardList(p)
                }
            }
            .padding(Spacing.screen)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: p.card)
        }
        .safeAreaInset(edge: .bottom) { controls(p) }
    }

    private func header(_ p: RecordPresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                if coordinator.phase == .recording {
                    Circle().fill(SLColor.tomato).frame(width: 12, height: 12).accessibilityHidden(true)
                }
                Text(p.elapsedText)
                    .font(SLFont.timer)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityLabel(p.elapsedAccessibility)
            }
            Text(p.statusLine)
                .font(SLFont.subheadline)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record.header")
    }

    // MARK: - Before recording

    private var startCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let resumeRecord {
                Text("You have a recording from \(resumeRecord.startedAt, style: .relative) ago with \(resumeRecord.lines.count) line\(resumeRecord.lines.count == 1 ? "" : "s") heard. Continue where you left off.")
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
            } else {
                Text("Cook as usual and say what you’re doing. Umma may ask a short question when you pause; say “skip”, “later” or “stop asking” any time.")
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("What are you cooking? (optional)", text: $titleHint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("record.titleHint")
            }
            if !coordinator.isVoiceAvailable {
                Label("Voice isn’t available on this device, so recording can’t start.", systemImage: "mic.slash")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.warning)
            }
            Button {
                startTask = Task {
                    if let resumeRecord {
                        await coordinator.resume(from: resumeRecord)
                    } else {
                        let hint = titleHint.trimmingCharacters(in: .whitespacesAndNewlines)
                        await coordinator.start(titleHint: hint.isEmpty ? nil : String(hint.prefix(120)))
                    }
                }
            } label: {
                Label(resumeRecord == nil ? "Start recording" : "Continue recording", systemImage: "mic.fill")
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .disabled(!coordinator.isVoiceAvailable)
            .slDisabledAppearance(!coordinator.isVoiceAvailable)
            .accessibilityIdentifier("record.start")
            Button("Type it in instead", action: onTypeInstead)
                .buttonStyle(SLButtonStyle(prominent: false))
                .accessibilityIdentifier("record.typeInstead")
            Text("Audio is never stored. Only the words are sent, and they’re deleted once the recipe is published or discarded.")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var failedCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Button("Type it in instead") {
                coordinator.stopForNow()
                onTypeInstead()
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .accessibilityIdentifier("record.typeInstead")
            Button("Close") {
                coordinator.stopForNow()
                onClose()
            }
            .buttonStyle(SLButtonStyle(prominent: false))
        }
    }

    // MARK: - Heard so far

    @ViewBuilder
    private func heardList(_ p: RecordPresentation) -> some View {
        if let count = p.heardCountText {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(count)
                    .font(SLFont.overline)
                    .foregroundStyle(SLColor.textSecondary)
                    .textCase(.uppercase)
                ForEach(Array(p.heardLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(SLFont.callout)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("record.heard")
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(_ p: RecordPresentation) -> some View {
        if p.showsPauseToggle || p.showsDone || p.isBusy {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Spacing.sm))
                : AnyLayout(HStackLayout(spacing: Spacing.sm))
            VStack(spacing: Spacing.sm) {
                if p.showsStopAsking {
                    Button("Stop asking questions") { coordinator.stopAsking() }
                        .font(SLFont.footnote)
                        .frame(minHeight: Metrics.minTapTarget)
                        .accessibilityIdentifier("record.stopAsking")
                }
                layout {
                    if p.showsPauseToggle {
                        Button {
                            if coordinator.phase == .recording {
                                coordinator.pause()
                            } else {
                                Task { await coordinator.resume() }
                            }
                        } label: {
                            Label(p.pauseToggleTitle, systemImage: p.pauseToggleSymbol)
                        }
                        .buttonStyle(SLButtonStyle(prominent: false))
                        .accessibilityIdentifier("record.pauseToggle")
                    }
                    if p.showsDone || p.isBusy {
                        Button {
                            Task { await coordinator.finish() }
                        } label: {
                            if p.isBusy {
                                ProgressView().tint(SLColor.onBrand)
                            } else {
                                Label("Done", systemImage: "checkmark")
                            }
                        }
                        .buttonStyle(SLButtonStyle(prominent: true))
                        .disabled(p.isBusy)
                        .accessibilityLabel(p.isBusy ? "Working" : "Done")
                        .accessibilityHint("Stops recording and asks a few last questions")
                        .accessibilityIdentifier("record.done")
                    }
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.md)
            .background(.bar)
        }
    }

    private func close() {
        switch coordinator.phase {
        case .recording, .paused, .voiceStopped, .wrappingUp, .finishing:
            showCloseOptions = true
        default:
            // Still starting (or never started): make sure a pending start can't open the mic.
            startTask?.cancel()
            coordinator.stopForNow()
            onClose()
        }
    }
}

/// The question Umma is asking, shown while it is spoken and while it waits for the answer.
struct QuestionCardView: View {
    let card: RecordPresentation.Card
    let coordinator: CaptureCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(card.eyebrow)
                .font(SLFont.overline)
                .foregroundStyle(SLColor.accent)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Text(card.question)
                .font(SLFont.title3)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("record.question")
            Text(card.status)
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
            if let answer = card.answer {
                Label(answer, systemImage: "quote.bubble")
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityLabel("Your answer: \(answer)")
                    .accessibilityIdentifier("record.answer")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) { buttons }
                VStack(alignment: .leading, spacing: Spacing.sm) { buttons }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.brandSoft, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record.questionCard")
        // VoiceOver hears each new question as it appears (and the next wrap-up one), not only
        // when focus happens to land on the card.
        .onChange(of: card.question, initial: true) { _, text in
            AccessibilityNotification.Announcement("\(card.eyebrow). \(text)").post()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Skip") { coordinator.skipQuestion() }
            .buttonStyle(.bordered)
            .tint(SLColor.accent)
            .frame(minHeight: Metrics.minTapTarget)
            .accessibilityIdentifier("record.skipQuestion")
        if card.showsDefer {
            Button(card.deferTitle) { coordinator.deferQuestion() }
                .buttonStyle(.bordered)
                .tint(SLColor.accent)
                .frame(minHeight: Metrics.minTapTarget)
                .accessibilityIdentifier("record.deferQuestion")
        }
    }
}
