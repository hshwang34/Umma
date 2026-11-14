import Foundation

/// What the draft generator needs from a finished recording (brief 014 §6).
extension CaptureCoordinator {
    /// Generation progress lives in the journal so a relaunch can pick it up.
    func noteGeneration(key: String, jobId: UUID?, draftId: UUID?) {
        outbox.update { record in
            record.stage = .generating
            record.generateKey = key
            record.jobId = jobId
            if let draftId { record.draftId = draftId }
        }
    }

    /// Sends anything still queued (wrap-up answers) before the draft is generated.
    func flushWrites() async -> Bool {
        outbox.reopen()
        return await outbox.flush(maxFailures: config.maxFinishFailures)
    }

    /// The draft exists: nothing left to resume.
    func forget() {
        outbox.forget()
    }
}
