import Foundation

/// Brief 014 voice recipe capture (`/v1/capture/sessions`) plus the brief 008 job poll it shares.
///
/// Every write except create needs an `Idempotency-Key`; callers generate one per logical
/// request and reuse it on retries (the server replays the first response for the same key and
/// body). `CaptureCoordinator` keeps the key with the request in its journal so a retry after a
/// relaunch reuses it too.
protocol CaptureService: Sendable {
    /// `POST /capture/sessions` → 201 (a replayed key → 200). The key is optional on create.
    func createCaptureSession(_ request: CaptureCreateRequest, idempotencyKey: String?) async throws -> CaptureSession
    /// `GET /capture/sessions/{id}`: the session with its events, for resuming after a relaunch.
    func captureSession(id: UUID) async throws -> CaptureSession
    /// `DELETE /capture/sessions/{id}` → 204. Deletes the transcript; a draft made from it is kept.
    func deleteCaptureSession(id: UUID) async throws
    func postCaptureTurns(sessionId: UUID, _ request: CaptureTurnsRequest, idempotencyKey: String) async throws -> CaptureTurnsResponse
    func postCaptureOutcome(sessionId: UUID, questionId: UUID, _ request: CaptureOutcomeRequest, idempotencyKey: String) async throws -> CaptureOutcomeResponse
    func postCaptureCommand(sessionId: UUID, _ request: CaptureCommandRequest, idempotencyKey: String) async throws -> CaptureSession
    /// Done: status → `wrapping_up`, with at most 3 wrap-up questions.
    func finishCapture(sessionId: UUID, _ request: CaptureFinishRequest, idempotencyKey: String) async throws -> CaptureFinishResponse
    /// → 202 Job (`kind: capture`). Over a cap: `CAPTURE_GENERATION_LIMIT` 429 / `AI_RESTING` 503.
    func generateCaptureDraft(sessionId: UUID, idempotencyKey: String) async throws -> ExtractionJob
    /// `GET /extractions/{job_id}`: poll until `ready` or `failed`.
    func extractionJob(id: UUID) async throws -> ExtractionJob
}

extension APIClient: CaptureService {
    private static func capturePath(_ sessionId: UUID, _ suffix: String = "") -> String {
        "/v1/capture/sessions/\(pathId(sessionId))\(suffix)"
    }

    private func idempotent(_ endpoint: Endpoint, key: String?) -> Endpoint {
        var endpoint = endpoint
        if let key { endpoint.headers[Self.idempotencyHeader] = key }
        return endpoint
    }

    func createCaptureSession(_ request: CaptureCreateRequest, idempotencyKey: String?) async throws -> CaptureSession {
        try await send(idempotent(.post("/v1/capture/sessions", body: try encoder.encode(request)), key: idempotencyKey))
    }

    func captureSession(id: UUID) async throws -> CaptureSession {
        try await send(.get(Self.capturePath(id)))
    }

    func deleteCaptureSession(id: UUID) async throws {
        _ = try await raw(.delete(Self.capturePath(id)))
    }

    func postCaptureTurns(sessionId: UUID, _ request: CaptureTurnsRequest, idempotencyKey: String) async throws -> CaptureTurnsResponse {
        // A pause may make the interviewer think; same budget as other AI-backed calls.
        var endpoint = idempotent(.post(Self.capturePath(sessionId, "/turns"), body: try encoder.encode(request)), key: idempotencyKey)
        endpoint.timeout = 20
        return try await send(endpoint)
    }

    func postCaptureOutcome(sessionId: UUID, questionId: UUID, _ request: CaptureOutcomeRequest, idempotencyKey: String) async throws -> CaptureOutcomeResponse {
        let path = Self.capturePath(sessionId, "/questions/\(Self.pathId(questionId))")
        return try await send(idempotent(.post(path, body: try encoder.encode(request)), key: idempotencyKey))
    }

    func postCaptureCommand(sessionId: UUID, _ request: CaptureCommandRequest, idempotencyKey: String) async throws -> CaptureSession {
        try await send(idempotent(.post(Self.capturePath(sessionId, "/commands"), body: try encoder.encode(request)), key: idempotencyKey))
    }

    func finishCapture(sessionId: UUID, _ request: CaptureFinishRequest, idempotencyKey: String) async throws -> CaptureFinishResponse {
        var endpoint = idempotent(.post(Self.capturePath(sessionId, "/finish"), body: try encoder.encode(request)), key: idempotencyKey)
        // The interviewer reads the whole transcript once more.
        endpoint.timeout = 30
        return try await send(endpoint)
    }

    func generateCaptureDraft(sessionId: UUID, idempotencyKey: String) async throws -> ExtractionJob {
        try await send(idempotent(.post(Self.capturePath(sessionId, "/generate"), body: nil), key: idempotencyKey))
    }

    func extractionJob(id: UUID) async throws -> ExtractionJob {
        try await send(.get("/v1/extractions/\(Self.pathId(id))"))
    }
}

extension APIError {
    /// Generation refused for now (allowance used up, AI budget resting): the recording is kept
    /// and the creator can try later or type the recipe in.
    var isCaptureGenerationDeferred: Bool {
        guard case .server(_, let code, _, _, _, _) = self else { return false }
        return ["CAPTURE_GENERATION_LIMIT", "AI_RESTING", "PROVIDER_NOT_CONFIGURED"].contains(code)
    }
}
