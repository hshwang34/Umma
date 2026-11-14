import SwiftUI

/// Shopping list (brief 017), opened from Pantry.
struct ShoppingListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: ShoppingListViewModel?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle("Shopping list")
        .navigationBarTitleDisplayMode(.inline)
        .pushedFromTabRoot()
        .task {
            let model = self.model ?? ShoppingListViewModel(service: environment.api)
            self.model = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: ShoppingListViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading your list…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load your shopping list", message: message,
                           primary: EmptyStateView.Action("Try again") { Task { await model.load() } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            list(model)
        }
    }

    private func list(_ model: ShoppingListViewModel) -> some View {
        @Bindable var model = model
        return List {
            Section {
                HStack(spacing: Spacing.sm) {
                    TextField("Add an item", text: $model.newName)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await model.add() } }
                        .accessibilityIdentifier("shopping.newName")
                    Button("Add") {
                        Task {
                            await model.add()
                            fieldFocused = true
                        }
                    }
                    .font(SLFont.bodyEmphasis)
                    .disabled(!model.canAdd)
                    .accessibilityIdentifier("shopping.add")
                }
                .frame(minHeight: Metrics.minTapTarget)
            } footer: {
                Text(model.summary)
            }
            if let error = model.actionError {
                Section { Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger) }
            }
            if model.items.isEmpty {
                Section {
                    Text("What you’re missing for a recipe lands here when you finish cooking. You can also add your own.")
                        .font(SLFont.callout)
                        .foregroundStyle(SLColor.textSecondary)
                }
            } else {
                Section {
                    ForEach(model.rows) { row in
                        Button {
                            Task { await model.toggle(id: row.id) }
                        } label: {
                            ShoppingRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busyIds.contains(row.id))
                        .opacity(model.busyIds.contains(row.id) ? 0.5 : 1)
                        .accessibilityLabel(row.accessibilityLabel)
                        .accessibilityHint(row.isChecked ? "Puts it back on the list" : "Crosses it off")
                        .accessibilityAddTraits(row.isChecked ? .isSelected : [])
                        .accessibilityIdentifier("shopping.row")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.delete(id: row.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Scan a grocery receipt in Pantry to cross off what you bought.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }
}

private struct ShoppingRowView: View {
    let row: ShoppingRowPresentation

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: row.isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(row.isChecked ? SLColor.success : SLColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(row.name)
                    .font(SLFont.body)
                    .strikethrough(row.isChecked)
                    .foregroundStyle(row.isChecked ? SLColor.textSecondary : SLColor.textPrimary)
                if let detail = row.detail {
                    Text(detail).font(SLFont.footnote).foregroundStyle(SLColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
    }
}
