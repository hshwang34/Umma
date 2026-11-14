import Foundation

/// The banner on Pantry after a receipt was read (brief 017 "Result banner"), and after its undo.
/// Lines Umma couldn't read are listed with nothing to answer.
struct ReceiptBannerPresentation: Equatable {
    static let maxListedLines = 6

    let title: String
    /// Short facts under the title, one per line.
    let details: [String]
    /// Receipt lines that weren't read, as printed. Capped; `moreSkippedText` covers the rest.
    let skippedLines: [String]
    let moreSkippedText: String?
    /// The receipt to take back. Nil when nothing was saved, on a repeat, a demo, or after Undo.
    let undoReceiptId: UUID?
    let isDemo: Bool

    init(_ result: ReceiptResult) {
        let skipped = result.skipped.count
        let notRead = skipped == 0 ? nil : (skipped == 1 ? "1 line not read" : "\(skipped) lines not read")
        var details: [String] = []
        isDemo = result.demo
        if result.demo {
            title = "Demo receipt. Nothing was saved"
            let names = result.wouldAdd.map(\.name)
            if !names.isEmpty { details.append("A real receipt like this would add: \(names.joined(separator: ", "))") }
            undoReceiptId = nil
        } else if result.duplicate {
            title = "You’ve already added this receipt"
            details.append("Nothing changed.")
            undoReceiptId = nil
        } else if result.added.isEmpty, result.merged.isEmpty {
            title = "Nothing was added from that receipt"
            details.append("Umma only adds food it can read clearly. Try a sharper photo, or add items by voice.")
            undoReceiptId = nil
        } else {
            title = Self.addedTitle(result.added.count)
            if !result.merged.isEmpty {
                details.append(result.merged.count == 1 ? "1 item you already had was refreshed"
                                                         : "\(result.merged.count) items you already had were refreshed")
            }
            if !result.shoppingChecked.isEmpty {
                details.append(result.shoppingChecked.count == 1 ? "Ticked 1 item off your shopping list"
                                                                  : "Ticked \(result.shoppingChecked.count) items off your shopping list")
            }
            undoReceiptId = result.receiptId
        }
        if !result.duplicate, !result.demo, let notRead { details.append(notRead) }
        self.details = details
        let lines = result.duplicate || result.demo ? [] : result.skipped.map(\.rawText).filter { !$0.isEmpty }
        skippedLines = Array(lines.prefix(Self.maxListedLines))
        moreSkippedText = lines.count > Self.maxListedLines ? "and \(lines.count - Self.maxListedLines) more" : nil
    }

    /// After a whole-receipt Undo.
    init(undone: ReceiptUndoResult) {
        title = "Receipt undone"
        var details: [String] = []
        if undone.removed > 0 { details.append(undone.removed == 1 ? "Removed 1 item" : "Removed \(undone.removed) items") }
        if undone.restored > 0 {
            details.append(undone.restored == 1 ? "1 item put back as it was" : "\(undone.restored) items put back as they were")
        }
        if !undone.unchanged.isEmpty {
            details.append("Left alone because you changed them since: \(undone.unchanged.joined(separator: ", "))")
        }
        if details.isEmpty { details.append("Nothing needed changing.") }
        self.details = details
        skippedLines = []
        moreSkippedText = nil
        undoReceiptId = nil
        isDemo = false
    }

    static func addedTitle(_ count: Int) -> String {
        switch count {
        case 0: return "Your receipt refreshed what you already had"
        case 1: return "Added 1 item from your receipt"
        default: return "Added \(count) items from your receipt"
        }
    }

    var canUndo: Bool { undoReceiptId != nil }
}
