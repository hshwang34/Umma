import Foundation
import Observation

/// What the live scan screen shows for one model state. Built from plain values so tests assert
/// the copy and the buttons without inspecting the view.
struct LiveScanScreenPresentation: Equatable {
    static let lookingLabel = "Umma is looking"
    static let cameraOffLabel = "Camera off"

    /// Shown only while the camera really is on (read from the source, never assumed).
    let indicatorText: String?
    /// "1:45 left", only while frames are being sent.
    let countdownText: String?
    let title: String
    let message: String?
    let isWarning: Bool
    let showsSettings: Bool
    let demoLabel: String?
    let basketCountText: String
    /// "Keep scanning" (a new 2-minute window) or "Try again" (after a failed start).
    let continueTitle: String?
    let canFinish: Bool
    let isBusy: Bool

    init(phase: LiveScanViewModel.Phase, cameraOn: Bool, secondsRemaining: Int, isDemo: Bool, message: String?,
         permissionDenied: Bool, basketCount: Int, canContinue: Bool, canFinish: Bool) {
        indicatorText = cameraOn ? Self.lookingLabel : nil
        countdownText = phase == .scanning ? "\(Self.clock(secondsRemaining)) left" : nil
        demoLabel = isDemo ? LiveScanViewModel.demoLabel : nil
        basketCountText = basketCount == 1 ? "1 item" : "\(basketCount) items"
        self.canFinish = canFinish
        isBusy = phase == .idle || phase == .starting || phase == .finishing
        var text = message
        switch phase {
        case .idle, .starting:
            title = "Starting the camera…"
        case .scanning:
            title = "Point at your ingredients"
            text = message ?? "Move slowly across the fridge or a shelf. Each thing Umma recognises drops into your basket."
        case .timeUp:
            title = "Two minutes are up"
            text = message ?? "The camera is off. Keep scanning, or tap Done to check your list."
        case .limitReached:
            title = "That’s all the live scanning for today"
        case .interrupted:
            title = "The scan stopped"
        case .paused:
            title = "Scanning paused"
        case .failed:
            title = permissionDenied ? "Umma can’t use the camera" : "The scan didn’t start"
        case .finishing:
            title = "Saving your scan…"
        case .finished, .cancelled:
            title = ""
        }
        self.message = text
        isWarning = [.limitReached, .interrupted, .failed].contains(phase) || (phase == .scanning && message != nil)
        showsSettings = phase == .failed && permissionDenied
        continueTitle = canContinue ? (phase == .failed ? "Try again" : "Keep scanning") : nil
    }

    static func clock(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }
}

/// The short list after Done (brief 016 "Finish"). Items the server was sure about are already in
/// the pantry. Everything else waits here, unticked, and is saved only for the rows the cook
/// chose, on the "Add" tap.
@MainActor
@Observable
final class LiveScanReviewModel {
    /// What the cook decided for one row. No decision means the item is left out.
    enum Decision: Equatable {
        case add
        case merge
        case keepBoth
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let reasonText: String
        /// Set when the item matches something already in the pantry: the cook picks Merge or
        /// Keep both, never a default (PAN-04).
        var existingPantryItemId: UUID?
        var decision: Decision?

        var isDuplicate: Bool { existingPantryItemId != nil }
    }

    let autoAddedNames: [String]
    let isDemo: Bool
    private(set) var rows: [Row]
    private(set) var isSaving = false
    private(set) var error: String?
    /// Everything this scan put in the pantry, once the cook is finished here.
    private(set) var saved: [PantryItem]

    private let service: PantryService

    init(result: LiveScanResultPresentation, isDemo: Bool, service: PantryService) {
        autoAddedNames = result.autoAddedNames
        saved = result.autoAdded
        self.isDemo = isDemo
        self.service = service
        rows = result.review.map {
            Row(id: $0.id, name: $0.name, reasonText: $0.reasonText, existingPantryItemId: $0.existingPantryItemId)
        }
    }

    var headline: String {
        if isDemo { return "Demo scan. Nothing was saved" }
        switch autoAddedNames.count {
        case 0: return rows.isEmpty ? "Nothing new was found" : "Check these before they’re added"
        case 1: return "Added 1 item to your pantry"
        case let count: return "Added \(count) items to your pantry"
        }
    }

    var detail: String? {
        if rows.isEmpty {
            return autoAddedNames.isEmpty ? "Your pantry is unchanged. You can scan again, or add items by photo or voice." : nil
        }
        return "Umma wasn’t sure about these. Nothing below is added unless you choose it."
    }

    var selectedCount: Int { rows.filter { $0.decision != nil }.count }

    var primaryTitle: String {
        switch selectedCount {
        case 0: return "Done"
        case 1: return "Add 1 item"
        case let count: return "Add \(count) items"
        }
    }

    /// Tick or untick a row that has no match in the pantry.
    func toggle(_ id: String) {
        update(id) { row in
            guard !row.isDuplicate else { return }
            row.decision = row.decision == nil ? .add : nil
        }
    }

    /// Merge or Keep both for a row that matches a pantry item. Tapping the chosen one clears it.
    func choose(_ id: String, _ choice: DuplicateChoice) {
        let decision: Decision = choice == .merge ? .merge : .keepBoth
        update(id) { row in
            guard row.isDuplicate else { return }
            row.decision = row.decision == decision ? nil : decision
        }
    }

    /// A tap on a row. Ignored while a save is on its way.
    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard !isSaving, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        error = nil
    }

    /// Saves only the rows the cook chose. Returns true when the screen can close. With nothing
    /// chosen it is a plain Done and sends nothing.
    func confirm() async -> Bool {
        guard !isSaving else { return false }
        let chosen = rows.filter { $0.decision != nil }
        guard !chosen.isEmpty else { return true }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            saved += try await service.addPantryItems(chosen.map(Self.newItem), observationId: nil)
            return true
        } catch let api as APIError {
            if let conflicts = api.pantryConflicts, !conflicts.isEmpty {
                // The server found a match we didn't know about: ask, never decide.
                for conflict in conflicts where chosen.indices.contains(conflict.index) {
                    guard let index = rows.firstIndex(where: { $0.id == chosen[conflict.index].id }) else { continue }
                    rows[index].existingPantryItemId = conflict.existing.id
                    rows[index].decision = nil
                }
                error = "Some of these are already in your pantry. Choose Merge or Keep both, then add again."
            } else {
                error = "Couldn’t add: \(api.pantryMessage)"
            }
            return false
        } catch {
            self.error = "Couldn’t add: \(error.pantryMessage)"
            return false
        }
    }

    /// A camera-found item the cook confirmed by hand is a `photo` item: `live` is reserved for
    /// what the server auto-saved, and the public endpoint doesn't accept it.
    private static func newItem(_ row: Row) -> NewPantryItem {
        var resolution: PantryResolution?
        if let existing = row.existingPantryItemId {
            resolution = row.decision == .merge ? .mergeInto(existing) : .keepBoth
        }
        return NewPantryItem(rawLabel: row.name, source: .photo, resolution: resolution)
    }
}
