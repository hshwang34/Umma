import Foundation

/// Brief 014 voice recipe capture DTOs. Shapes follow `docs/product/briefs/014-api-contract.md`.
/// Times inside a session are `tMs`: milliseconds since the session started, on the phone's clock.

enum CaptureSessionStatus: String, Codable, Sendable {
    case recording
    case wrappingUp = "wrapping_up"
    case generating
    case ready
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CaptureSessionStatus(rawValue: raw) ?? .unknown
    }
}

enum CapturePhase: String, Codable, Sendable {
    case live
    case wrapup
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CapturePhase(rawValue: raw) ?? .unknown
    }
}

/// One question Umma wants to ask. `expiresAtMs` is on the session clock; nil for wrap-up.
struct CaptureAsk: Codable, Sendable, Hashable, Identifiable {
    let questionId: UUID
    let text: String
    let topicKey: String
    /// temperature | time | quantity | doneness | servings | prep | equipment (kept as a string so a
    /// new topic never breaks decoding).
    let topic: String
    let phase: CapturePhase
    let expiresAtMs: Int64?

    var id: UUID { questionId }
}

/// The server's ask policy, mirrored so the phone's pause gate agrees with it.
struct CapturePolicy: Codable, Sendable, Hashable {
    var silenceBeforeAskMs: Int64 = 1500
    var minMsBetweenLiveAsks: Int64 = 45_000
    var maxLiveAsks: Int = 6
    var questionTtlMs: Int64 = 20_000
    var maxWrapupQuestions: Int = 3

    static let `default` = CapturePolicy()
}

struct CaptureEvent: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case utterance, question, answer, skip, marker, unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    let id: UUID
    let tMs: Int64
    let kind: Kind
    let text: String
    let topicKey: String?
    let questionId: UUID?
}

/// `GET/POST /v1/capture/sessions…`. `events` is only present on `GET`.
struct CaptureSession: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let mode: String
    let status: CaptureSessionStatus
    let titleHint: String?
    let draftId: UUID?
    let extractionJobId: UUID?
    let askingStopped: Bool
    let paused: Bool
    let liveAsksUsed: Int
    let pendingQuestion: CaptureAsk?
    let wrapupQuestions: [CaptureAsk]
    let transcriptDeleted: Bool
    let policy: CapturePolicy
    let startedAt: Date
    let endedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let events: [CaptureEvent]?
}

// MARK: - Limits

/// The server's request limits (`backend/app/domains/capture/schemas.py`). A body over one of
/// them is refused with a 422, so the phone never sends one.
enum CaptureLimits {
    /// `TEXT_MAX`: one segment's text, and an answer. Python counts Unicode scalars.
    static let spokenTextMax = 2000
    /// `MAX_SEGMENTS`: segments in one turns batch.
    static let segmentsPerTurn = 50

    /// `text` trimmed and, when over `limit`, cut back to the last whole word that fits (a hard
    /// cut only when one word is longer than `limit`).
    static func clamp(_ text: String, limit: Int = spokenTextMax) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > limit else { return trimmed }
        return split(trimmed, limit: limit).first ?? ""
    }

    /// `text` in pieces of at most `limit` scalars, broken between words. Text already within the
    /// limit comes back as it is.
    static func split(_ text: String, limit: Int = spokenTextMax) -> [String] {
        guard text.unicodeScalars.count > limit else { return text.isEmpty ? [] : [text] }
        var pieces: [String] = []
        var current = ""
        var count = 0
        for word in text.split(whereSeparator: \.isWhitespace) {
            for chunk in hardCut(String(word), limit: limit) {
                let size = chunk.unicodeScalars.count
                if count > 0, count + 1 + size > limit {
                    pieces.append(current)
                    current = ""
                    count = 0
                }
                if count > 0 {
                    current += " "
                    count += 1
                }
                current += chunk
                count += size
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// One word longer than `limit`, cut between characters.
    private static func hardCut(_ word: String, limit: Int) -> [String] {
        guard word.unicodeScalars.count > limit else { return [word] }
        var chunks: [String] = []
        var chunk = ""
        var count = 0
        for character in word {
            let size = character.unicodeScalars.count
            if count + size > limit, !chunk.isEmpty {
                chunks.append(chunk)
                chunk = ""
                count = 0
            }
            chunk.append(character)
            count += size
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
}

// MARK: - Requests

struct CaptureCreateRequest: Codable, Sendable, Hashable {
    var mode = "voice"
    var titleHint: String?
}

struct CaptureSegmentIn: Codable, Sendable, Hashable {
    let tMs: Int64
    let text: String
    var isFinal = true
}

/// `POST /capture/sessions/{id}/turns`. Send whenever captions finalise, and an empty batch with
/// the current `silenceMs` when a pause starts.
struct CaptureTurnsRequest: Codable, Sendable, Hashable {
    var segments: [CaptureSegmentIn]
    var silenceMs: Int64
    var assistantSpeaking: Bool
    var tMs: Int64?
}

struct CaptureTurnsResponse: Codable, Sendable, Hashable {
    let ask: CaptureAsk?
    let stored: Int
    let closedQuestionId: UUID?
    let askingStopped: Bool
}

enum CaptureOutcome: String, Codable, Sendable {
    case answered, skipped, later, expired, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CaptureOutcome(rawValue: raw) ?? .unknown
    }
}

struct CaptureOutcomeRequest: Codable, Sendable, Hashable {
    let outcome: CaptureOutcome
    var answerText: String?
    let tMs: Int64

    /// `answer_text` is omitted unless answered (the server requires it then).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(answerText, forKey: .answerText)
        try container.encode(tMs, forKey: .tMs)
    }
}

struct CaptureOutcomeResponse: Codable, Sendable, Hashable {
    let questionId: UUID
    let topicKey: String
    /// May differ from what was sent: a question past its expiry is `expired` whatever arrives.
    let outcome: CaptureOutcome
}

enum CaptureCommand: String, Codable, Sendable {
    case stopAsking = "stop_asking"
    case pause
    case resume
}

struct CaptureCommandRequest: Codable, Sendable, Hashable {
    let command: CaptureCommand
    var tMs: Int64?
}

struct CaptureFinishRequest: Codable, Sendable, Hashable {
    var tMs: Int64?
}

struct CaptureFinishResponse: Codable, Sendable, Hashable {
    let questions: [CaptureAsk]
    let session: CaptureSession
}

// MARK: - Extraction job (brief 008, shared with capture)

enum ExtractionJobStatus: String, Codable, Sendable {
    case queued, processing, ready, failed, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExtractionJobStatus(rawValue: raw) ?? .unknown
    }

    var isFinished: Bool { self == .ready || self == .failed }
}

struct ExtractionJobError: Codable, Sendable, Hashable {
    let code: String
    let message: String
}

/// `GET /v1/extractions/{id}` and the 202 from `POST …/generate`.
struct ExtractionJob: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let kind: String
    let status: ExtractionJobStatus
    let stage: String?
    let progress: Int
    let draftId: UUID?
    let demo: Bool
    let partial: Bool
    let error: ExtractionJobError?
    let attempts: Int
    let createdAt: Date
    let updatedAt: Date
    let finishedAt: Date?
}
