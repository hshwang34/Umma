import Foundation

extension CaptureCoordinator {
    /// Discard: delete the session (and its transcript) on the server first; the journal goes once
    /// that succeeds (or the session is already gone). Otherwise it stays as "discard pending" and
    /// Profile retries.
    func discard() async {
        discardRequested = true
        cancelPendingStart()
        fail("Recording discarded.")
        outbox.suspend()
        guard let sessionId else { return }
        outbox.update { $0.discardPending = true }
        if await Self.deleteOnServer(sessionId, api: api) {
            outbox.forget()
        } else {
            fail("Couldn’t delete the recording yet. Umma will try again from Profile.")
        }
    }

    /// Retries the server delete for journals marked discard pending (Profile, on appear).
    static func retryPendingDiscards(api: CaptureService, journal: CaptureJournalStore = .live, userId: UUID?) async {
        for record in journal.pending(userId: userId) where record.discardPending == true {
            if await deleteOnServer(record.sessionId, api: api) { journal.remove(record.sessionId) }
        }
    }

    private static func deleteOnServer(_ sessionId: UUID, api: CaptureService) async -> Bool {
        do {
            try await api.deleteCaptureSession(id: sessionId)
            return true
        } catch let error as APIError where error.isNotFound {
            return true
        } catch {
            return false
        }
    }
}
