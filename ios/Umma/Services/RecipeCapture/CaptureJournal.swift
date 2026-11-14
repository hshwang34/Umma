import Foundation
import os

/// One write the server hasn't acknowledged yet. The key is generated once and kept with the
/// body, so every retry (including after a relaunch) replays the same request.
struct CaptureWrite: Codable, Equatable, Sendable {
    enum Body: Codable, Equatable, Sendable {
        case turns(CaptureTurnsRequest)
        case outcome(questionId: UUID, CaptureOutcomeRequest)
        case command(CaptureCommandRequest)
    }

    let key: String
    let body: Body

    init(key: String = UUID().uuidString, body: Body) {
        self.key = key
        self.body = body
    }

    /// A pause-only turn (no words): worthless once something newer is queued.
    var isPauseOnlyTurn: Bool {
        if case .turns(let request) = body { return request.segments.isEmpty }
        return false
    }
}

/// What the phone remembers about one capture session, so a crash or relaunch resumes or finishes
/// it without losing words. Audio is never kept, only transcript text and timings.
struct CaptureJournalRecord: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case recording, wrappingUp, generating
    }

    struct Line: Codable, Equatable, Sendable, Identifiable {
        let id: Int
        let tMs: Int64
        let text: String
        /// Set for words spoken as an answer to this question (not sent as a turn unless the
        /// answer couldn't be recorded).
        var questionId: UUID?
    }

    var version = 1
    let sessionId: UUID
    let userId: UUID?
    var titleHint: String?
    var startedAt: Date
    var stage: Stage = .recording
    /// The newest session time the phone has used; a resumed session continues after it.
    var lastTMs: Int64 = 0
    var lines: [Line] = []
    /// Final segments not yet put into a write.
    var unsent: [CaptureSegmentIn] = []
    var outbox: [CaptureWrite] = []
    var askingStopped = false
    var closedQuestionIds: [UUID] = []
    var finishKey: String?
    var generateKey: String?
    var jobId: UUID?
    var draftId: UUID?
    /// Discard was tapped but the server delete hasn't succeeded yet; retried from Profile.
    var discardPending: Bool?
}

/// One JSON file per session under Application Support (excluded from backup). Small files,
/// rewritten atomically on every change.
struct CaptureJournalStore: Sendable {
    let directory: URL
    private static let logger = Logger(subsystem: "com.umma.ios", category: "capture-journal")

    static var live: CaptureJournalStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return CaptureJournalStore(directory: base.appending(path: "CaptureJournal", directoryHint: .isDirectory))
    }

    private func url(_ sessionId: UUID) -> URL {
        directory.appending(path: "\(sessionId.uuidString.lowercased()).json")
    }

    func save(_ record: CaptureJournalRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            try JSONCoding.makeEncoder().encode(record).write(to: url(record.sessionId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("journal save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load(_ sessionId: UUID) -> CaptureJournalRecord? {
        guard let data = try? Data(contentsOf: url(sessionId)) else { return nil }
        return try? JSONCoding.makeDecoder().decode(CaptureJournalRecord.self, from: data)
    }

    /// Unfinished sessions for this user, newest first.
    func pending(userId: UUID?) -> [CaptureJournalRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONCoding.makeDecoder().decode(CaptureJournalRecord.self, from: Data(contentsOf: $0)) }
            .filter { $0.userId == userId }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func remove(_ sessionId: UUID) {
        try? FileManager.default.removeItem(at: url(sessionId))
    }

    /// Forget every recording on this phone (brief 010: sign-out, account deletion, server
    /// change), or only one account's when `userId` is given. Files that can't be read go too.
    func removeAll(userId: UUID? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if let userId {
                let record = try? JSONCoding.makeDecoder().decode(CaptureJournalRecord.self, from: Data(contentsOf: file))
                guard record?.userId == userId else { continue }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Spoken "skip" / "later" / "stop asking", mirroring the server's `policy.parse_command` so
/// the phone and server agree. Skip and later must be the whole short utterance ("don't skip the
/// kimchi" is not a command); stop asking may sit inside a sentence.
enum CaptureVoiceCommand: Equatable, Sendable {
    case skip, later, stopAsking

    private static let stopPhrases = ["stop asking", "no more questions", "stop the questions", "quiet please", "stop with the questions"]
    private static let skipPhrases: Set<String> = ["skip", "skip it", "skip that", "pass", "next question", "don't know", "i don't know"]
    private static let laterPhrases: Set<String> = ["later", "ask me later", "not now", "later please", "after"]
    private static let fillers: Set<String> = ["umma", "okay", "ok", "um", "uh"]

    static func parse(_ text: String) -> CaptureVoiceCommand? {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let cleaned = String(lowered.map { $0.isLetter || $0 == "'" || $0 == " " ? $0 : " " })
        var words = cleaned.split(separator: " ").map(String.init)
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        let norm = words.joined(separator: " ")
        let padded = " \(norm) "
        if stopPhrases.contains(where: { padded.contains(" \($0) ") }) { return .stopAsking }
        if skipPhrases.contains(norm) { return .skip }
        if laterPhrases.contains(norm) { return .later }
        return nil
    }
}
