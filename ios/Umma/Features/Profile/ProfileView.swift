import SwiftUI

/// Profile (PRD §6): my recipes, my drafts, account, device state, server, sign out.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: MyRecipesViewModel?
    @State private var editor: DraftEditorViewModel?
    @State private var isOpeningEditor = false
    @State private var openError: String?
    @State private var recipeToUnpublish: MyRecipe?
    @State private var draftToDelete: DraftSummary?
    // Brief 014: New recipe → chooser → record while cooking.
    @State private var showNewRecipeChooser = false
    @State private var chosenNewRecipe: NewRecipeOption.Kind?
    @State private var captureFlow: CaptureFlow?
    @State private var typeInAfterCapture = false
    @State private var pendingCaptures: [CaptureJournalRecord] = []
    @State private var showServerSettings = false
    // Brief 020: Default servings.
    @State private var servings: DefaultServingsViewModel?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listSectionSpacing(.compact)
                myRecipesSection
                draftsSection
                foodSection
                accountSection
                deviceSection
                Section {
                    Button(role: .destructive) {
                        environment.auth.signOut()
                    } label: {
                        Text("Sign out")
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SLColor.background)
            .navigationTitle("Profile")
            .tabRootHeader()
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .creator(let id):
                    CreatorProfileView(creatorId: id).pushedFromTabRoot()
                case .recipe(let id, let card):
                    RecipeDetailView(recipeId: id, card: card).pushedFromTabRoot()
                }
            }
            .navigationDestination(isPresented: $showServerSettings) {
                ServerSettingsView().pushedFromTabRoot()
            }
            .refreshable { await model?.refresh() }
            .confirmationDialog("Unpublish “\(recipeToUnpublish?.card.title ?? "")”?", isPresented: Binding(get: { recipeToUnpublish != nil }, set: { if !$0 { recipeToUnpublish = nil } }), titleVisibility: .visible) {
                Button("Unpublish", role: .destructive) {
                    if let recipe = recipeToUnpublish { Task { await model?.unpublish(recipeId: recipe.id) } }
                }
                Button("Keep published", role: .cancel) {}
            } message: {
                Text("It disappears from Explore and search. Existing links and pinned cooking sessions keep this version.")
            }
            .confirmationDialog("Delete “\(draftToDelete?.displayTitle ?? "")”?", isPresented: Binding(get: { draftToDelete != nil }, set: { if !$0 { draftToDelete = nil } }), titleVisibility: .visible) {
                Button("Delete draft", role: .destructive) {
                    if let draft = draftToDelete { Task { await model?.deleteDraft(id: draft.id) } }
                }
                Button("Keep draft", role: .cancel) {}
            } message: {
                Text("Only the draft is deleted. Anything already published stays published.")
            }
        }
        .task {
            if servings == nil {
                servings = DefaultServingsViewModel(current: environment.auth.user?.defaultServings, service: environment.api) { [environment] user in
                    environment.auth.updateUser(user)
                }
            }
            if model == nil {
                let created = MyRecipesViewModel(service: environment.api)
                model = created
                await created.load()
            } else {
                await model?.refresh()
            }
        }
        .fullScreenCover(item: $editor, onDismiss: { Task { await model?.refresh() } }) { editor in
            DraftEditorView(model: editor)
        }
        .sheet(isPresented: $showNewRecipeChooser, onDismiss: openChosenNewRecipe) {
            NewRecipeChooser { chosenNewRecipe = $0 }
        }
        .background {
            // A second cover can't share a view with the editor's; this one hosts capture.
            Color.clear.fullScreenCover(item: $captureFlow, onDismiss: captureDismissed) { flow in
                CaptureFlowView(flow: flow) { typeInAfterCapture = true }
            }
        }
        .onChange(of: environment.auth.user?.defaultServings) { _, current in servings?.sync(current: current) }
        .onAppear { pendingCaptures = environment.pendingCaptures() }
        .task {
            // Brief 014: a discard that couldn't reach the server is retried here.
            await CaptureCoordinator.retryPendingDiscards(api: environment.api, userId: environment.auth.user?.id)
            pendingCaptures = environment.pendingCaptures()
        }
        .task(id: environment.requestNewRecipe) {
            // Brief 015: onboarding's "Record your first recipe" lands here.
            guard environment.requestNewRecipe else { return }
            environment.requestNewRecipe = false
            if CaptureFeature.isEnabled() {
                showNewRecipeChooser = true
            } else {
                await createRecipe()
            }
        }
    }

    /// Brief 019: the tab's own header. Settings is a button, not a NavigationLink, so the
    /// header row in the List doesn't turn into a navigation cell.
    private var header: some View {
        TabHeader(title: "Profile") {
            // Debug builds only (brief 010): a release build always talks to production.
            if BuildConfig.allowsServerOverride {
                Button { showServerSettings = true } label: {
                    Label("Server settings", systemImage: "gearshape")
                }
                .accessibilityLabel("Server settings")
                .accessibilityIdentifier("profile.serverSettings")
            }
        }
    }

    // MARK: - My recipes

    @ViewBuilder
    private var myRecipesSection: some View {
        Section {
            Button {
                if CaptureFeature.isEnabled() {
                    showNewRecipeChooser = true
                } else {
                    Task { await createRecipe() }
                }
            } label: {
                HStack {
                    Label("New recipe", systemImage: "plus.circle.fill")
                    Spacer()
                    if isOpeningEditor { ProgressView() }
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
            .disabled(isOpeningEditor)
            .accessibilityIdentifier("profile.createRecipe")
            ForEach(pendingCaptures, id: \.sessionId) { record in
                CaptureResumeRow(record: record) {
                    if record.discardPending == true {
                        Task {
                            await CaptureCoordinator.retryPendingDiscards(api: environment.api, userId: environment.auth.user?.id)
                            pendingCaptures = environment.pendingCaptures()
                        }
                    } else {
                        captureFlow = environment.makeCaptureFlow(resuming: record)
                    }
                }
            }
            if let openError {
                Text(openError)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
            }
            if let error = model?.actionError {
                Text(error)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
            }
            switch model?.phase {
            case .none, .idle, .loading:
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("Loading your recipes…")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                }
            case .error(let message, _):
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.warning)
            case .loaded:
                if let model, model.recipes.isEmpty {
                    Text("Nothing published yet. Create a recipe, add ingredients and steps, then publish it.")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                } else if let model {
                    ForEach(model.recipes) { recipe in
                        NavigationLink(value: RecipeRoute.card(recipe.card)) {
                            MyRecipeRow(recipe: recipe, isBusy: model.busyRecipeIds.contains(recipe.id))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if recipe.visibility == .public {
                                Button("Unpublish") { recipeToUnpublish = recipe }
                                    .tint(SLColor.warning)
                            }
                        }
                        .contextMenu {
                            if recipe.visibility == .public {
                                Button("Unpublish…", systemImage: "eye.slash") { recipeToUnpublish = recipe }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("My recipes")
        } footer: {
            if let model, !model.recipes.isEmpty {
                Text("Swipe a recipe to unpublish it. Published versions are never changed in place; Edit on the recipe creates a new draft.")
            }
        }
    }

    // MARK: - Drafts

    @ViewBuilder
    private var draftsSection: some View {
        if let model, model.phase == .loaded {
            Section {
                if model.drafts.isEmpty {
                    Text("No drafts in progress.")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.textSecondary)
                } else {
                    ForEach(model.drafts) { draft in
                        Button {
                            Task { await continueDraft(draft) }
                        } label: {
                            DraftRow(draft: draft, isBusy: model.busyDraftIds.contains(draft.id) || isOpeningEditor)
                        }
                        .disabled(isOpeningEditor)
                        .accessibilityIdentifier("profile.draft.\(draft.id.uuidString.lowercased())")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { draftToDelete = draft }
                        }
                        .contextMenu {
                            Button("Continue editing", systemImage: "pencil") { Task { await continueDraft(draft) } }
                            Button("Delete draft…", systemImage: "trash", role: .destructive) { draftToDelete = draft }
                        }
                    }
                }
            } header: {
                Text("Drafts")
            } footer: {
                if !model.drafts.isEmpty { Text("Tap to continue. Swipe to delete.") }
            }
        }
    }

    // MARK: - Food preferences (brief 005)

    private var foodSection: some View {
        Section {
            NavigationLink {
                PreferencesView()
            } label: {
                Label("Allergies & foods to avoid", systemImage: "allergens")
                    .frame(minHeight: Metrics.minTapTarget)
            }
            .accessibilityIdentifier("profile.preferences")
            NavigationLink {
                TastePreferencesView()
            } label: {
                Label("Diets, cuisines & skill", systemImage: "fork.knife")
                    .frame(minHeight: Metrics.minTapTarget)
            }
            .accessibilityIdentifier("profile.taste")
            if let servings {
                defaultServingsRow(servings)
            }
            NavigationLink {
                FollowingListView()
            } label: {
                Label("Following", systemImage: "person.2")
                    .frame(minHeight: Metrics.minTapTarget)
            }
            .accessibilityIdentifier("profile.following")
        } header: {
            Text("Cooking")
        } footer: {
            Text("Allergies block swaps; foods to avoid are skipped when possible. \(DefaultServingsViewModel.footer)")
        }
    }

    /// Brief 020: "Recipe’s own" or 1 to 6. Saved on the tap; a failed save rolls back and says so.
    @ViewBuilder
    private func defaultServingsRow(_ model: DefaultServingsViewModel) -> some View {
        Picker(selection: Binding(get: { model.selected }, set: { value in Task { await model.select(value) } })) {
            ForEach(model.options) { option in
                Text(option.title)
                    .accessibilityLabel(option.accessibilityLabel)
                    .tag(option.servings)
            }
        } label: {
            Label(DefaultServingsViewModel.title, systemImage: "person.2")
                .frame(minHeight: Metrics.minTapTarget)
        }
        .pickerStyle(.menu)
        .disabled(model.isSaving)
        .accessibilityIdentifier("profile.defaultServings")
        if let error = model.errorMessage {
            Text(error)
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.danger)
                .accessibilityIdentifier("profile.defaultServingsError")
        }
    }

    // MARK: - Account / device (Slice 0)

    @ViewBuilder
    private var accountSection: some View {
        if let user = environment.auth.user {
            Section {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(SLColor.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(user.displayName)
                            .font(SLFont.title3)
                            .foregroundStyle(SLColor.textPrimary)
                        Text("Member since \(user.createdAt, format: .dateTime.month(.wide).year())")
                            .font(SLFont.footnote)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .accessibilityElement(children: .combine)
                LabeledContent("Units", value: user.preferenceUnits.displayName)
            } header: {
                Text("Account")
            }
        }
    }

    private var deviceSection: some View {
        Section {
            if BuildConfig.allowsServerOverride {
                LabeledContent("Server") {
                    Text(environment.serverSettings.effectiveBaseURLString.isEmpty ? "Not set" : environment.serverSettings.effectiveBaseURLString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            LabeledContent("Camera", value: environment.camera.isAvailable ? "Available (\(environment.camera.kind.displayName))" : "Unavailable")
            LabeledContent("Microphone", value: environment.speech.isAvailable ? "Available (\(environment.speech.kind.displayName))" : "Unavailable")
            LabeledContent("Speech output", value: environment.audio.isAvailable ? "Available" : "Unavailable")
        } header: {
            Text("Device")
        } footer: {
            if BuildConfig.isDebug {
                Text("Capture inputs are checked on launch; the simulator reports camera and microphone as unavailable.")
            }
        }
    }

    // MARK: - Actions

    private var creator: Creator? {
        environment.auth.user.map { Creator(id: $0.id, displayName: $0.displayName) }
    }

    private func createRecipe() async {
        guard let creator else { return }
        isOpeningEditor = true
        openError = nil
        defer { isOpeningEditor = false }
        do {
            editor = try await DraftEditorViewModel.createNew(service: environment.api, creator: creator)
        } catch {
            openError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func openChosenNewRecipe() {
        let choice = chosenNewRecipe
        chosenNewRecipe = nil
        switch choice {
        case .recordVoice: captureFlow = environment.makeCaptureFlow()
        case .typeIn: Task { await createRecipe() }
        case .recordCamera, nil: break
        }
    }

    private func captureDismissed() {
        pendingCaptures = environment.pendingCaptures()
        Task { await model?.refresh() }
        if typeInAfterCapture {
            typeInAfterCapture = false
            Task { await createRecipe() }
        }
    }

    private func continueDraft(_ draft: DraftSummary) async {
        guard let creator else { return }
        isOpeningEditor = true
        openError = nil
        defer { isOpeningEditor = false }
        do {
            editor = try await DraftEditorViewModel.open(draftId: draft.id, service: environment.api, creator: creator)
        } catch {
            openError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct MyRecipeRow: View {
    let recipe: MyRecipe
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(recipe.card.title)
                .font(SLFont.headline)
                .foregroundStyle(SLColor.textPrimary)
            HStack(spacing: Spacing.xs) {
                MetadataPill(
                    text: recipe.visibility.label,
                    systemImage: recipe.visibility == .public ? "globe" : "lock",
                    style: recipe.visibility == .public ? .accent : .neutral,
                    accessibilityLabel: "Visibility: \(recipe.visibility.label)"
                )
                MetadataPill(text: "v\(recipe.card.versionNumber)", accessibilityLabel: "Version \(recipe.card.versionNumber)")
                if recipe.hasOpenDraft {
                    MetadataPill(text: "Draft in progress", systemImage: "pencil")
                }
                if isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

private struct DraftRow: View {
    let draft: DraftSummary
    let isBusy: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(draft.displayTitle)
                    .font(SLFont.headline)
                    .foregroundStyle(SLColor.textPrimary)
                HStack(spacing: Spacing.xs) {
                    Text("\(draft.ingredientCount) ingredient\(draft.ingredientCount == 1 ? "" : "s") · \(draft.stepCount) step\(draft.stepCount == 1 ? "" : "s")")
                    Text("·")
                    Text("Edited \(draft.updatedAt, style: .relative) ago")
                }
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                if draft.recipeId != nil {
                    MetadataPill(text: "New version of a published recipe", systemImage: "arrow.triangle.branch")
                }
            }
            Spacer()
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Continues editing this draft")
    }
}

#Preview {
    ProfileView().environment(AppEnvironment.preview())
}
