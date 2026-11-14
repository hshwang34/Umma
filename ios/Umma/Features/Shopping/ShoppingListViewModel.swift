import Foundation
import Observation

/// One line on the Shopping list screen.
struct ShoppingRowPresentation: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isChecked: Bool
    /// Why it is here, or who ticked it. Nil for a plain item the cook typed.
    let detail: String?

    init(_ item: ShoppingItem) {
        id = item.id
        name = item.rawLabel
        isChecked = item.isChecked
        if item.isChecked {
            detail = item.checkedBy == "receipt" ? "Bought. Ticked off by a receipt" : "Bought"
        } else {
            switch item.reason {
            case .missing: detail = "Missing for a recipe"
            case .ranOut: detail = "Ran out"
            case .noSubstitute: detail = "No swap found"
            case .manual, .unknown: detail = nil
            }
        }
    }

    var accessibilityLabel: String {
        [name, detail, isChecked ? nil : "To buy"].compactMap { $0 }.joined(separator: ", ")
    }
}

/// "Added to your shopping list: 4 items" (brief 017 finish screen). Nil when nothing was added.
struct ShoppingAddedSummary: Equatable {
    let title: String
    let names: [String]

    init?(names: [String]) {
        guard !names.isEmpty else { return nil }
        self.names = names
        title = "Added to your shopping list: \(names.count == 1 ? "1 item" : "\(names.count) items")"
    }
}

/// Shopping list (brief 017): add, tick, untick, delete. Items are shown in the order and state
/// the server returns; every change is the cook's tap.
@MainActor
@Observable
final class ShoppingListViewModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case error(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [ShoppingItem] = []
    private(set) var actionError: String?
    private(set) var busyIds: Set<UUID> = []
    private(set) var isAdding = false
    var newName = ""

    private let service: ShoppingService
    /// Last request wins: a slow earlier load, or one that started before a local write, is dropped.
    private var loadGeneration = 0

    init(service: ShoppingService) {
        self.service = service
    }

    var rows: [ShoppingRowPresentation] { items.map(ShoppingRowPresentation.init) }

    var summary: String {
        let open = items.filter { !$0.isChecked }.count
        if items.isEmpty { return "Nothing on your list" }
        if open == 0 { return "Everything is ticked off" }
        return open == 1 ? "1 item to buy" : "\(open) items to buy"
    }

    private var cleanName: String {
        String(newName.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(ShoppingItem.maxNameLength))
    }

    var canAdd: Bool { !cleanName.isEmpty && !isAdding }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if items.isEmpty { phase = .loading }
        do {
            let fetched = try await service.shoppingList()
            guard generation == loadGeneration else { return }
            items = fetched
            phase = .loaded
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            guard generation == loadGeneration else { return }
            if items.isEmpty { phase = .error(error.pantryMessage) } else { actionError = error.pantryMessage }
        }
    }

    /// Adds what was typed. A name already open on the list comes back as that item, not a second.
    func add() async {
        let name = cleanName
        guard !name.isEmpty, !isAdding else { return }
        isAdding = true
        actionError = nil
        defer { isAdding = false }
        do {
            replace(try await service.addShoppingItem(name: name, reason: .manual, recipeVersionId: nil))
            newName = ""
        } catch {
            actionError = "Couldn’t add \(name): \(error.pantryMessage)"
        }
    }

    /// Tick or untick, from the state the row shows.
    func toggle(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await write(id, failure: "Couldn’t update \(item.rawLabel)") {
            if item.isChecked {
                self.replace(try await self.service.uncheckShoppingItem(id: id))
            } else {
                self.replace(try await self.service.checkShoppingItem(id: id))
            }
        }
    }

    func delete(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await write(id, failure: "Couldn’t delete \(item.rawLabel)") {
            do {
                try await self.service.deleteShoppingItem(id: id)
            } catch let error as APIError where error.isNotFound {
                // Already gone: the list should not show it either.
            }
            self.loadGeneration += 1
            self.items.removeAll { $0.id == id }
        }
    }

    private func write(_ id: UUID, failure: String, _ work: () async throws -> Void) async {
        guard !busyIds.contains(id) else { return }
        busyIds.insert(id)
        actionError = nil
        defer { busyIds.remove(id) }
        do {
            try await work()
        } catch {
            actionError = "\(failure): \(error.pantryMessage)"
        }
    }

    /// A server-confirmed item replaces its row in place, or joins the end of the list.
    private func replace(_ item: ShoppingItem) {
        loadGeneration += 1
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        if phase != .loaded { phase = .loaded }
    }
}
