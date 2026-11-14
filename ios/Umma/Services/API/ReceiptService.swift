import Foundation

/// Grocery receipt → pantry (brief 017, `/v1/pantry/receipts`). The server saves the lines it is
/// sure about and reports the rest; the photo is never stored. `APIClient` is the real
/// implementation; tests inject a fake.
protocol ReceiptService: Sendable {
    /// One receipt photo (multipart `image`). A second photo of the same receipt comes back with
    /// `duplicate` set and changes nothing.
    func readReceipt(_ photo: PantryPhotoUpload) async throws -> ReceiptResult
    /// Takes back what that receipt did, except on items the cook has changed since. 404 when
    /// the receipt is unknown or already undone.
    func undoReceipt(id: UUID) async throws -> ReceiptUndoResult
}

extension APIClient: ReceiptService {
    func readReceipt(_ photo: PantryPhotoUpload) async throws -> ReceiptResult {
        var form = MultipartFormData()
        form.addFile("image", filename: "receipt.jpg", contentType: "image/jpeg", data: photo.jpegData)
        return try await send(.multipart("/v1/pantry/receipts", form: form))
    }

    func undoReceipt(id: UUID) async throws -> ReceiptUndoResult {
        try await send(.post("/v1/pantry/receipts/\(Self.pathId(id))/undo", body: Self.emptyObject))
    }
}

struct ReceiptSkippedLine: Decodable, Sendable, Equatable {
    /// The line as printed. Untrusted text: shown, never acted on.
    let rawText: String
    let reason: String
}

/// A demo receipt saves nothing; this is what a real one would have added.
struct ReceiptWouldAdd: Decodable, Sendable, Equatable {
    let name: String
}

struct ReceiptResult: Decodable, Sendable, Equatable {
    /// Nil when nothing was saved (a demo included): there is nothing to undo.
    let receiptId: UUID?
    let duplicate: Bool
    let demo: Bool
    let store: String?
    /// New pantry items, source `receipt`.
    let added: [PantryItem]
    /// Items the cook already had; "last seen" (and sometimes the amount) was refreshed.
    let merged: [PantryItem]
    let skipped: [ReceiptSkippedLine]
    let wouldAdd: [ReceiptWouldAdd]
    /// Names ticked off the shopping list.
    let shoppingChecked: [String]

    private enum CodingKeys: String, CodingKey {
        case receiptId, duplicate, demo, store, added, merged, skipped, wouldAdd, shoppingChecked
    }

    init(receiptId: UUID?, duplicate: Bool = false, demo: Bool = false, store: String? = nil, added: [PantryItem] = [],
         merged: [PantryItem] = [], skipped: [ReceiptSkippedLine] = [], wouldAdd: [ReceiptWouldAdd] = [],
         shoppingChecked: [String] = []) {
        self.receiptId = receiptId
        self.duplicate = duplicate
        self.demo = demo
        self.store = store
        self.added = added
        self.merged = merged
        self.skipped = skipped
        self.wouldAdd = wouldAdd
        self.shoppingChecked = shoppingChecked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receiptId = try c.decodeIfPresent(UUID.self, forKey: .receiptId)
        duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        demo = try c.decodeIfPresent(Bool.self, forKey: .demo) ?? false
        store = try c.decodeIfPresent(String.self, forKey: .store)
        added = try c.decodeIfPresent([PantryItem].self, forKey: .added) ?? []
        merged = try c.decodeIfPresent([PantryItem].self, forKey: .merged) ?? []
        skipped = try c.decodeIfPresent([ReceiptSkippedLine].self, forKey: .skipped) ?? []
        wouldAdd = try c.decodeIfPresent([ReceiptWouldAdd].self, forKey: .wouldAdd) ?? []
        shoppingChecked = try c.decodeIfPresent([String].self, forKey: .shoppingChecked) ?? []
    }
}

struct ReceiptUndoResult: Decodable, Sendable, Equatable {
    let receiptId: UUID
    /// Items the receipt created, now deleted.
    let removed: Int
    /// Rebought items put back to their earlier amount and "last seen".
    let restored: Int
    /// Left alone because the cook edited or confirmed them after the receipt.
    let unchanged: [String]

    private enum CodingKeys: String, CodingKey { case receiptId, removed, restored, unchanged }

    init(receiptId: UUID, removed: Int = 0, restored: Int = 0, unchanged: [String] = []) {
        self.receiptId = receiptId
        self.removed = removed
        self.restored = restored
        self.unchanged = unchanged
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receiptId = try c.decode(UUID.self, forKey: .receiptId)
        removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        restored = try c.decodeIfPresent(Int.self, forKey: .restored) ?? 0
        unchanged = try c.decodeIfPresent([String].self, forKey: .unchanged) ?? []
    }
}
