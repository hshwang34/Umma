import Foundation

/// Everything a step row displays, computed without SwiftUI so tests can assert the exact
/// labels (PRD §13.4 provenance pill included) without a view-inspection library.
struct StepRowPresentation: Equatable, Sendable {
    let numberText: String
    let instruction: String
    /// "About 4 min" when the creator estimated a duration.
    let timePill: String?
    /// Transparency label for any step that is not creator-authored; nil otherwise.
    let provenancePill: String?
    let successCues: [String]
    let warnings: [String]
    /// "Creator note: …" when present and non-empty.
    let creatorNoteText: String?
    let accessibilityLabel: String

    init(number: Int, step: RecipeStep) {
        numberText = String(number)
        instruction = step.instruction
        timePill = step.estimatedMinutes.map { "About \(RecipeFormatting.minutes($0))" }
        provenancePill = step.provenanceLabel
        successCues = step.successCues
        warnings = step.warnings
        if let note = step.creatorNote, !note.isEmpty {
            creatorNoteText = "Creator note: \(note)"
        } else {
            creatorNoteText = nil
        }
        accessibilityLabel = "Step \(number)"
    }

    /// Pills in display order (time, then provenance).
    var pills: [String] { [timePill, provenancePill].compactMap { $0 } }
}

/// The "Steps" section header: title plus the recipe-wide provenance pill.
struct StepsHeaderPresentation: Equatable, Sendable {
    let title = "Steps"
    let provenancePill: String

    init(detail: RecipeDetail) {
        provenancePill = detail.headerProvenanceLabel
    }
}

/// Brief 019: the recipe page photo. Says whether it opens the full-screen viewer (a real photo
/// only, never the placeholder) and what credit line it shows under it.
struct RecipePhotoPresentation: Equatable, Sendable {
    struct Credit: Equatable, Sendable {
        /// "Photo: Jane Doe / Pexels"
        let text: String
        let url: URL
        let accessibilityLabel: String
        let accessibilityHint = "Opens the photographer’s page"
    }

    let imageURL: URL?
    let credit: Credit?

    init(imageURL: URL?, credit: CoverCredit?) {
        self.imageURL = imageURL
        self.credit = imageURL == nil ? nil : credit.flatMap(Self.credit(from:))
    }

    /// Only a real photo opens the viewer.
    var opensViewer: Bool { imageURL != nil }
    var accessibilityLabel: String { imageURL == nil ? "No photo yet" : "Recipe photo" }
    var accessibilityHint: String? { opensViewer ? "Opens the photo full screen" : nil }

    /// Pexels is the only provider today. A credit from an unknown source, without a name, or
    /// with a link that isn't http(s) is not shown rather than shown wrong.
    private static func credit(from credit: CoverCredit) -> Credit? {
        let name = credit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let sourceName = sourceNames[credit.source.lowercased()],
              let url = URL(string: credit.url),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return nil }
        return Credit(
            text: "Photo: \(name) / \(sourceName)",
            url: url,
            accessibilityLabel: "Photo by \(name) on \(sourceName)"
        )
    }

    private static let sourceNames = ["pexels": "Pexels"]
}
