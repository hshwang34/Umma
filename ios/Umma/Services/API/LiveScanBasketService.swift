import Foundation

/// Live pantry scan basket (brief 016 PR 3, `/v1/pantry/live-scans`). Nothing in a basket is pantry
/// truth until `finishLiveScan`. `APIClient` is the real implementation; tests inject a fake.
protocol LiveScanBasketService: Sendable {
    /// `POST /pantry/live-scans` → 201. `demo` is the live token's flag; the server forces it on
    /// under the mock provider. 429 `RATE_LIMITED` over the hourly scan limit.
    func createLiveScan(demo: Bool) async throws -> LiveScanCreated
    /// One model-reported item, normalised and deduplicated on the server. 409 `STATE_CONFLICT`
    /// when the scan is finished or the basket is full; 422 when the name isn't an ingredient.
    func addLiveScanItem(scanID: UUID, _ item: LiveScanItemReport) async throws -> LiveScanItemResult
    /// `DELETE .../items/{key}` → 204. 404 when the item isn't in the basket. The key goes into the
    /// path as is (the URL builder percent-encodes it), so a key containing "/" can't be removed.
    func removeLiveScanItem(scanID: UUID, key: String) async throws
    /// Saves new, high-confidence, recognised items and returns the rest for review. A retry
    /// replays the first answer.
    func finishLiveScan(scanID: UUID) async throws -> LiveScanFinished
}

extension APIClient: LiveScanBasketService {
    func createLiveScan(demo: Bool) async throws -> LiveScanCreated {
        try await send(.post("/v1/pantry/live-scans", body: try encoder.encode(CreateLiveScanRequest(demo: demo))))
    }

    func addLiveScanItem(scanID: UUID, _ item: LiveScanItemReport) async throws -> LiveScanItemResult {
        try await send(.post("/v1/pantry/live-scans/\(Self.pathId(scanID))/items", body: try encoder.encode(item)))
    }

    func removeLiveScanItem(scanID: UUID, key: String) async throws {
        _ = try await raw(.delete("/v1/pantry/live-scans/\(Self.pathId(scanID))/items/\(key)"))
    }

    func finishLiveScan(scanID: UUID) async throws -> LiveScanFinished {
        try await send(.post("/v1/pantry/live-scans/\(Self.pathId(scanID))/finish", body: Self.emptyObject))
    }
}

private struct CreateLiveScanRequest: Encodable {
    let demo: Bool
}

struct LiveScanCreated: Decodable, Sendable, Equatable {
    let id: UUID
    let demo: Bool
    let expiresAt: Date
}

/// What the model reported through `add_item`. The server treats it as untrusted data.
struct LiveScanItemReport: Encodable, Sendable, Equatable {
    let name: String
    let kind: String?
    /// `high`, `medium` or `low`; the server accepts nothing else.
    let confidence: String

    init(name: String, kind: String?, confidence: LiveScanConfidence) {
        self.name = name
        // Server limit: 32 characters.
        self.kind = kind.map { String($0.prefix(32)) }
        self.confidence = confidence == .unknown ? LiveScanConfidence.low.rawValue : confidence.rawValue
    }
}

enum LiveScanItemStatus: String, Decodable, Sendable, Equatable {
    case new
    case alreadyInBasket = "already_in_basket"
    case inPantry = "in_pantry"
    /// Anything this build doesn't know. Never added to the basket.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveScanItemStatus(rawValue: raw) ?? .unknown
    }
}

extension LiveScanConfidence: Decodable {
    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }
}

struct LiveScanItemResult: Decodable, Sendable, Equatable {
    let status: LiveScanItemStatus
    /// The basket key (the normalised name); `removeLiveScanItem` takes it.
    let key: String
    let canonicalName: String
    let displayName: String
    let confidence: LiveScanConfidence
    let existingPantryItemId: UUID?
}

enum LiveScanReviewReason: String, Decodable, Sendable, Equatable {
    case unsure
    case unrecognized
    case inPantry = "in_pantry"
    case demo
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveScanReviewReason(rawValue: raw) ?? .unknown
    }
}

/// A basket item `finish` did not save: the cook decides.
struct LiveScanReviewItem: Decodable, Sendable, Equatable {
    let status: LiveScanItemStatus
    let key: String
    let canonicalName: String
    let displayName: String
    let confidence: LiveScanConfidence
    let existingPantryItemId: UUID?
    let reason: LiveScanReviewReason
}

struct LiveScanFinished: Decodable, Sendable, Equatable {
    /// Already in the pantry with source `live`.
    let saved: [PantryItem]
    let review: [LiveScanReviewItem]
}
