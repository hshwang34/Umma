import SwiftUI

/// Live pantry scan (brief 016 PR 6): the camera looks while this screen is open, recognised
/// items drop into a basket, and Done leads to a short list to check. Closing the screen at any
/// point before Done stops the camera and saves nothing.
struct LiveScanSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onAdded: ([PantryItem]) -> Void

    @State private var model: LiveScanViewModel?
    @State private var review: LiveScanReviewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let review {
                    LiveScanReviewView(model: review) {
                        onAdded(review.saved)
                        dismiss()
                    }
                } else if let model {
                    LiveScanView(model: model)
                }
            }
            .background(SLColor.background)
            .navigationTitle("Live scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if review == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            // "Saving your scan…": the server save lands whatever happens here.
                            .disabled(model?.blocksDismissal == true)
                            .accessibilityIdentifier("liveScan.cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(review != nil || model?.blocksDismissal == true)
        .task {
            guard model == nil else { return }
            let model = LiveScanViewModel(camera: Self.camera(environment.camera), tokens: environment.api, service: environment.api)
            // Auto-added items are in the pantry once Done has saved, even if this sheet has gone.
            model.onFinished = { result in onAdded(result.autoAdded) }
            self.model = model
            await model.start()
        }
        .onChange(of: model?.phase) { _, phase in
            guard phase == .finished, review == nil, let model, let result = model.result else { return }
            review = LiveScanReviewModel(result: result, isDemo: model.isDemo, service: environment.api)
        }
        // Backgrounded: the camera goes off and stays off until the cook taps "Keep scanning".
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, let model { Task { await model.pauseForBackground() } }
        }
        .onDisappear {
            if let model { Task { await model.cancel() } }
        }
    }

    /// The phone camera streams frames. Anything else (camera flag off) is reported as no camera.
    /// The simulator has no camera, so it gets a scripted one: the server's demo scan still runs.
    private static func camera(_ source: any CameraSource) -> any FrameStreamingCameraSource {
        if let streaming = source as? any FrameStreamingCameraSource { return streaming }
        #if targetEnvironment(simulator)
        return FakeFrameStreamingCameraSource()
        #else
        return FakeFrameStreamingCameraSource(isAvailable: false)
        #endif
    }
}

struct LiveScanView: View {
    let model: LiveScanViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The chip currently on its way into the basket (or the "already have" pulse).
    @State private var flying: LiveScanCue?

    private var presentation: LiveScanScreenPresentation {
        LiveScanScreenPresentation(phase: model.phase, cameraOn: model.cameraOn, secondsRemaining: model.secondsRemaining,
                                   isDemo: model.isDemo, message: model.message, permissionDenied: model.permissionDenied,
                                   basketCount: model.basket.count, canContinue: model.canContinue, canFinish: model.canFinish)
    }

    var body: some View {
        let shown = presentation
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                viewfinder(shown)
                status(shown)
                basket(shown)
            }
            .padding(Spacing.screen)
        }
        .safeAreaInset(edge: .bottom) { actions(shown) }
        .onChange(of: model.cue) { _, cue in
            guard let cue else { return }
            withAnimation(.snappy(duration: 0.25)) { flying = cue }
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                guard flying?.id == cue.id else { return }
                withAnimation(.easeIn(duration: 0.35)) { flying = nil }
            }
        }
    }

    private func viewfinder(_ shown: LiveScanScreenPresentation) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(SLColor.surfaceRaised)
            if model.cameraOn, let provider = model.camera as? CameraPreviewProviding {
                CameraPreviewView(provider: provider).accessibilityLabel("Camera viewfinder")
            } else {
                VStack(spacing: Spacing.sm) {
                    if shown.isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: model.cameraOn ? "camera.viewfinder" : "video.slash")
                            .font(SLFont.glyph)
                            .accessibilityHidden(true)
                    }
                    Text(model.cameraOn ? "Camera on" : LiveScanScreenPresentation.cameraOffLabel).font(SLFont.callout)
                }
                .foregroundStyle(SLColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if let indicator = shown.indicatorText {
                Label(indicator, systemImage: "circle.fill")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.onDanger)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(SLColor.danger, in: Capsule())
                    .padding(Spacing.sm)
                    .accessibilityIdentifier("liveScan.looking")
            }
        }
        .overlay(alignment: .topTrailing) {
            if let countdown = shown.countdownText {
                Text(countdown)
                    .font(SLFont.stepCounter)
                    .foregroundStyle(SLColor.textPrimary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(SLColor.surface, in: Capsule())
                    .padding(Spacing.sm)
                    .accessibilityLabel("Time left: \(countdown)")
                    .accessibilityIdentifier("liveScan.countdown")
            }
        }
        .overlay(alignment: .bottom) {
            if let cue = flying {
                cueChip(cue)
                    .padding(Spacing.md)
                    .id(cue.id)
                    // A new word pops in, then drops towards the basket below. Reduce Motion: fade.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.6).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .scale(scale: 0.5)).combined(with: .opacity)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    private func cueChip(_ cue: LiveScanCue) -> some View {
        let isNew = cue.kind != .alreadyHave
        return Label(isNew ? cue.name : "Already have \(cue.name)", systemImage: isNew ? "plus.circle.fill" : "checkmark.circle")
            .font(SLFont.bodyEmphasis)
            .foregroundStyle(isNew ? SLColor.onAccent : SLColor.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(isNew ? SLColor.accent : SLColor.surface, in: Capsule())
            .accessibilityIdentifier("liveScan.cue")
    }

    @ViewBuilder
    private func status(_ shown: LiveScanScreenPresentation) -> some View {
        if let demo = shown.demoLabel {
            Label(demo, systemImage: "theatermasks")
                .font(SLFont.footnote.weight(.semibold))
                .foregroundStyle(SLColor.warning)
                .accessibilityIdentifier("liveScan.demo")
        }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(shown.title)
                .font(SLFont.title3)
                .foregroundStyle(SLColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("liveScan.title")
            if let message = shown.message {
                if shown.isWarning {
                    MessageBlock(text: message, isWarning: true, showsSettings: shown.showsSettings)
                } else {
                    Text(message).font(SLFont.callout).foregroundStyle(SLColor.textSecondary)
                }
            }
        }
    }

    private func basket(_ shown: LiveScanScreenPresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label {
                Text("Basket · \(shown.basketCountText)").contentTransition(.numericText())
            } icon: {
                Image(systemName: "basket.fill")
            }
            .font(SLFont.headline)
            .foregroundStyle(SLColor.textPrimary)
            .accessibilityIdentifier("liveScan.basketCount")
            if model.basket.isEmpty {
                Text("Nothing yet. Items appear here as Umma recognises them.")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            } else {
                FlowLayout(spacing: Spacing.sm) {
                    ForEach(model.basket) { entry in
                        Button {
                            Task { await model.remove(entry) }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Text(entry.name).font(SLFont.subheadline.weight(.semibold))
                                Image(systemName: "xmark").font(SLFont.caption.weight(.bold))
                            }
                            .padding(.horizontal, Spacing.md)
                            .frame(minHeight: Metrics.minTapTarget)
                            .foregroundStyle(SLColor.textPrimary)
                            .background(SLColor.surfaceRaised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(entry.name)")
                        .accessibilityIdentifier("liveScan.chip")
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: model.basket)
                Text("Remove anything that’s wrong. It won’t be saved.")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
    }

    private func actions(_ shown: LiveScanScreenPresentation) -> some View {
        VStack(spacing: Spacing.sm) {
            if let title = shown.continueTitle {
                Button(title) { Task { await model.continueScanning() } }
                    .buttonStyle(SLButtonStyle(prominent: !shown.canFinish))
                    .accessibilityIdentifier("liveScan.continue")
            }
            if shown.canFinish || model.phase == .finishing {
                Button {
                    Task { await model.finish() }
                } label: {
                    if model.phase == .finishing { ProgressView().tint(SLColor.onBrand) } else { Text("Done") }
                }
                .buttonStyle(SLButtonStyle(prominent: true))
                .disabled(!shown.canFinish)
                .accessibilityHint("Stops the camera and shows your list to check")
                .accessibilityIdentifier("liveScan.done")
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.sm)
        .bottomBarScrim()
    }
}

/// After Done: what was added on its own, then the few items Umma wasn't sure about.
struct LiveScanReviewView: View {
    let model: LiveScanReviewModel
    let onDone: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(model.headline)
                        .font(SLFont.title2)
                        .foregroundStyle(SLColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("liveScan.review.headline")
                    if let detail = model.detail {
                        Text(detail).font(SLFont.callout).foregroundStyle(SLColor.textSecondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            if !model.autoAddedNames.isEmpty {
                Section {
                    ForEach(model.autoAddedNames, id: \.self) { name in
                        HStack {
                            Text(name).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
                            Spacer()
                            MetadataPill(text: PantrySource.live.badge, systemImage: PantrySource.live.systemImage)
                        }
                    }
                } header: {
                    Text("In your pantry")
                } footer: {
                    Text("Wrong one? Swipe it away in your pantry list.")
                }
            }
            if !model.rows.isEmpty {
                Section {
                    ForEach(model.rows) { row in reviewRow(row) }
                } header: {
                    Text("Check these")
                } footer: {
                    if model.rows.contains(where: \.isDuplicate) { Text(DuplicateChoice.hint) }
                }
            }
            if let error = model.error {
                Section { Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationBarBackButtonHidden()
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { if await model.confirm() { onDone() } }
            } label: {
                if model.isSaving { ProgressView().tint(SLColor.onBrand) } else { Text(model.primaryTitle) }
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .disabled(model.isSaving)
            .accessibilityIdentifier("liveScan.review.confirm")
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.sm)
            .bottomBarScrim()
        }
    }

    @ViewBuilder
    private func reviewRow(_ row: LiveScanReviewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                model.toggle(row.id)
            } label: {
                HStack(spacing: Spacing.md) {
                    if !row.isDuplicate {
                        Image(systemName: row.decision == nil ? "circle" : "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(row.decision == nil ? SLColor.textSecondary : SLColor.accent)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(row.name).font(SLFont.bodyEmphasis).foregroundStyle(SLColor.textPrimary)
                        Text(row.reasonText).font(SLFont.footnote).foregroundStyle(SLColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.isDuplicate)
            .accessibilityLabel("\(row.name), \(row.reasonText)")
            .accessibilityAddTraits(row.decision == .add ? .isSelected : [])
            .accessibilityIdentifier("liveScan.review.row")
            if row.isDuplicate {
                HStack(spacing: Spacing.sm) {
                    SelectableChip(title: DuplicateChoice.merge.label, isSelected: row.decision == .merge) {
                        model.choose(row.id, .merge)
                    }
                    SelectableChip(title: DuplicateChoice.keepBoth.label, isSelected: row.decision == .keepBoth) {
                        model.choose(row.id, .keepBoth)
                    }
                }
            }
        }
    }
}
