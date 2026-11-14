import Foundation
import XCTest
@testable import Umma

/// Brief 014: capture endpoints decode the contract's examples and send the documented shapes.
final class CaptureAPITests: XCTestCase {
    static let sessionId = "6f1c2a3b-0000-4000-8000-000000000001"
    static let questionId = "6f1c2a3b-0000-4000-8000-0000000000aa"
    static let jobId = "6f1c2a3b-0000-4000-8000-0000000000bb"
    static let draftId = "6f1c2a3b-0000-4000-8000-0000000000cc"

    static let askJSON = """
    {"question_id": "\(questionId)", "text": "How long do you let it simmer?",
     "topic_key": "simmer_time", "topic": "time", "phase": "live", "expires_at_ms": 81500}
    """

    static func sessionJSON(status: String = "recording", events: String = "null", pending: String = "null", wrapup: String = "[]") -> String {
        """
        {"id": "\(sessionId)", "mode": "voice", "status": "\(status)", "title_hint": "Mum's Kimchi Jjigae",
         "draft_id": null, "extraction_job_id": null, "asking_stopped": false, "paused": false,
         "live_asks_used": 0, "pending_question": \(pending), "wrapup_questions": \(wrapup),
         "transcript_deleted": false,
         "policy": {"silence_before_ask_ms": 1500, "min_ms_between_live_asks": 45000,
                    "max_live_asks": 6, "question_ttl_ms": 20000, "max_wrapup_questions": 3},
         "started_at": "2026-11-13T10:00:00Z", "ended_at": null,
         "created_at": "2026-11-13T10:00:00.123456Z", "updated_at": "2026-11-13T10:00:00Z",
         "events": \(events)}
        """
    }

    static let jobJSON = """
    {"id": "\(jobId)", "kind": "capture", "status": "queued", "stage": "queued", "progress": 0,
     "draft_id": "\(draftId)", "media_id": null, "clip_id": null, "demo": true, "partial": false,
     "clips_ready": 0, "clips_failed": 0, "error": null, "attempts": 0,
     "created_at": "2026-11-13T10:30:00Z", "updated_at": "2026-11-13T10:30:00Z", "finished_at": null}
    """

    private func makeClient() -> APIClient {
        APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: InMemoryTokenStore(token: "tok")
        )
    }

    private func route(_ table: [String: (Int, String)]) {
        StubURLProtocol.install { request in
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            guard let (status, body) = table[key] else {
                return (.stub(request, status: 404), Data(#"{"error":{"code":"NOT_FOUND","message":"no route \#(key)","retryable":false}}"#.utf8))
            }
            return (.stub(request, status: status), Data(body.utf8))
        }
    }

    private var sid: UUID { UUID(uuidString: Self.sessionId)! }
    private var base: String { "/v1/capture/sessions/\(Self.sessionId)" }

    // MARK: - Decoding

    func testSessionDecodesWithPolicyAndPendingQuestion() throws {
        let session = try JSONCoding.makeDecoder().decode(CaptureSession.self, from: Data(Self.sessionJSON(pending: Self.askJSON).utf8))
        XCTAssertEqual(session.status, .recording)
        XCTAssertEqual(session.titleHint, "Mum's Kimchi Jjigae")
        XCTAssertEqual(session.policy, .default)
        XCTAssertEqual(session.pendingQuestion?.topicKey, "simmer_time")
        XCTAssertEqual(session.pendingQuestion?.expiresAtMs, 81_500)
        XCTAssertEqual(session.pendingQuestion?.phase, .live)
        XCTAssertNil(session.events)
    }

    func testEventsAndUnknownEnumsDecodeTolerantly() throws {
        let events = """
        [{"id": "\(UUID())", "t_ms": 61000, "kind": "utterance", "text": "now we let it simmer", "topic_key": null, "question_id": null},
         {"id": "\(UUID())", "t_ms": 64000, "kind": "answer", "text": "about fifteen minutes", "topic_key": "simmer_time", "question_id": "\(Self.questionId)"},
         {"id": "\(UUID())", "t_ms": 65000, "kind": "photo", "text": "", "topic_key": null, "question_id": null}]
        """
        let session = try JSONCoding.makeDecoder().decode(CaptureSession.self, from: Data(Self.sessionJSON(status: "archived", events: events).utf8))
        XCTAssertEqual(session.status, .unknown)
        XCTAssertEqual(session.events?.map(\.kind), [.utterance, .answer, .unknown])
        XCTAssertEqual(session.events?[1].questionId, UUID(uuidString: Self.questionId))
    }

    func testDraftExtractionAndIngredientOriginDecode() throws {
        let json = """
        {"id": "\(Self.draftId)", "recipe_id": null, "status": "draft", "title": "Kimchi Jjigae", "summary": null,
         "tags": [], "cover_image_url": null, "servings": null, "prep_minutes": null, "cook_minutes": 15,
         "ingredients": [{"id": "ing-1", "name": "pork belly", "quantity": null, "unit": null, "optional": false,
                          "preparation": null, "notes": null, "evidence_origin": "ai_extracted"},
                         {"id": "ing-2", "name": "kimchi", "quantity": 2, "unit": "cup", "optional": false,
                          "preparation": null, "notes": null}],
         "steps": [], "creator_notes": ["Mum always uses the old sour kimchi"], "dietary_warnings": [],
         "validation": {"publishable": false, "problems": []},
         "extraction": {"job_id": "\(Self.jobId)", "source_media_id": null, "demo": true, "partial": false,
                        "unknowns": ["amount of pork belly not stated"], "notice": "Demo draft"},
         "created_at": "2026-11-13T10:30:00Z", "updated_at": "2026-11-13T10:30:00Z"}
        """
        let draft = try JSONCoding.makeDecoder().decode(Draft.self, from: Data(json.utf8))
        XCTAssertEqual(draft.extraction?.jobId, UUID(uuidString: Self.jobId))
        XCTAssertEqual(draft.extraction?.unknowns, ["amount of pork belly not stated"])
        XCTAssertTrue(draft.extraction?.demo == true)
        XCTAssertEqual(draft.ingredients.map(\.evidenceOrigin), [.aiExtracted, nil])
    }

    func testHandAuthoredDraftHasNoExtraction() throws {
        let draft = try JSONCoding.makeDecoder().decode(Draft.self, from: Data(AuthoringFixtures.emptyDraftJSON.utf8))
        XCTAssertNil(draft.extraction)
    }

    func testIngredientOriginIsOmittedWhenUnsetAndKeptThroughTheForm() throws {
        let plain = Ingredient(id: "ing-1", name: "salt", quantity: nil, unit: nil, optional: false, preparation: nil, notes: nil)
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(plainJSON["evidence_origin"], "never sent as null")
        XCTAssertTrue(plainJSON.keys.contains("quantity"), "other optionals stay explicit nulls")

        let ai = Ingredient(id: "ing-2", name: "pork belly", quantity: nil, unit: nil, optional: false, preparation: nil, notes: nil, evidenceOrigin: .aiExtracted)
        let roundTripped = EditableIngredient(ingredient: ai).ingredient
        XCTAssertEqual(roundTripped.evidenceOrigin, .aiExtracted, "an autosave must not drop the AI label")
        let aiJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(roundTripped)) as? [String: Any])
        XCTAssertEqual(aiJSON["evidence_origin"] as? String, "ai_extracted")
    }

    // MARK: - Requests

    func testCreateSendsModeTitleAndOptionalKey() async throws {
        route(["POST /v1/capture/sessions": (201, Self.sessionJSON())])
        let session = try await makeClient().createCaptureSession(CaptureCreateRequest(titleHint: "Mum's Kimchi Jjigae"), idempotencyKey: "k-create")
        XCTAssertEqual(session.id, sid)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "k-create")
        let body = try request.jsonBody()
        XCTAssertEqual(body["mode"] as? String, "voice")
        XCTAssertEqual(body["title_hint"] as? String, "Mum's Kimchi Jjigae")
    }

    func testTurnsSendsSnakeCaseBodyWithKeyAndDecodesAsk() async throws {
        route(["POST \(base)/turns": (200, #"{"ask": \#(Self.askJSON), "stored": 1, "closed_question_id": null, "asking_stopped": false}"#)])
        let request = CaptureTurnsRequest(segments: [CaptureSegmentIn(tMs: 61_000, text: "now we let it simmer")],
                                          silenceMs: 1800, assistantSpeaking: false, tMs: 62_800)
        let response = try await makeClient().postCaptureTurns(sessionId: sid, request, idempotencyKey: "k-turn-1")
        XCTAssertEqual(response.ask?.text, "How long do you let it simmer?")
        XCTAssertEqual(response.stored, 1)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Idempotency-Key"), "k-turn-1")
        let body = try sent.jsonBody()
        XCTAssertEqual(body["silence_ms"] as? Int, 1800)
        XCTAssertEqual(body["assistant_speaking"] as? Bool, false)
        XCTAssertEqual(body["t_ms"] as? Int, 62_800)
        let segment = try XCTUnwrap((body["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(segment["t_ms"] as? Int, 61_000)
        XCTAssertEqual(segment["is_final"] as? Bool, true)
    }

    func testOutcomeOmitsAnswerTextUnlessAnswered() async throws {
        route(["POST \(base)/questions/\(Self.questionId)": (200, #"{"question_id": "\#(Self.questionId)", "topic_key": "simmer_time", "outcome": "expired"}"#)])
        let qid = UUID(uuidString: Self.questionId)!
        let response = try await makeClient().postCaptureOutcome(
            sessionId: sid, questionId: qid, CaptureOutcomeRequest(outcome: .skipped, answerText: nil, tMs: 64_000), idempotencyKey: "k-q")
        XCTAssertEqual(response.outcome, .expired, "the server's verdict wins")
        let body = try XCTUnwrap(StubURLProtocol.requests.first).jsonBody()
        XCTAssertEqual(body["outcome"] as? String, "skipped")
        XCTAssertFalse(body.keys.contains("answer_text"))
        XCTAssertEqual(body["t_ms"] as? Int, 64_000)
    }

    func testCommandFinishGenerateAndPoll() async throws {
        route([
            "POST \(base)/commands": (200, Self.sessionJSON()),
            "POST \(base)/finish": (200, #"{"questions": [\#(Self.askJSON.replacingOccurrences(of: "\"live\"", with: "\"wrapup\"").replacingOccurrences(of: "81500", with: "null"))], "session": \#(Self.sessionJSON(status: "wrapping_up"))}"#),
            "POST \(base)/generate": (202, Self.jobJSON),
            "GET /v1/extractions/\(Self.jobId)": (200, Self.jobJSON.replacingOccurrences(of: "\"status\": \"queued\"", with: "\"status\": \"ready\"")),
        ])
        let client = makeClient()
        _ = try await client.postCaptureCommand(sessionId: sid, CaptureCommandRequest(command: .stopAsking, tMs: 90_000), idempotencyKey: "k-c")
        let finish = try await client.finishCapture(sessionId: sid, CaptureFinishRequest(tMs: 1_800_000), idempotencyKey: "k-f")
        XCTAssertEqual(finish.session.status, .wrappingUp)
        XCTAssertEqual(finish.questions.first?.phase, .wrapup)
        XCTAssertNil(finish.questions.first?.expiresAtMs)
        let job = try await client.generateCaptureDraft(sessionId: sid, idempotencyKey: "k-g")
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.draftId, UUID(uuidString: Self.draftId))
        let polled = try await client.extractionJob(id: job.id)
        XCTAssertEqual(polled.status, .ready)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }, ["k-c", "k-f", "k-g", nil])
        XCTAssertEqual(try requests[0].jsonBody()["command"] as? String, "stop_asking")
    }

    func testGetAndDelete() async throws {
        route(["GET \(base)": (200, Self.sessionJSON(events: "[]")), "DELETE \(base)": (204, "")])
        let session = try await makeClient().captureSession(id: sid)
        XCTAssertEqual(session.events, [])
        try await makeClient().deleteCaptureSession(id: sid)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "DELETE")
    }

    func testGenerationLimitIsDeferredNotLost() async throws {
        route(["POST \(base)/generate": (429, #"{"error":{"code":"CAPTURE_GENERATION_LIMIT","message":"You've used this month's AI drafts.","retryable":true,"details":{"limit":5,"used":5}}}"#)])
        do {
            _ = try await makeClient().generateCaptureDraft(sessionId: sid, idempotencyKey: "k")
            XCTFail("expected a 429")
        } catch let error as APIError {
            XCTAssertTrue(error.isCaptureGenerationDeferred)
            XCTAssertTrue(error.isRetryable)
        }
    }

    // MARK: - Request limits (backend TEXT_MAX)

    func testClampKeepsWholeWordsWithinTheServerLimit() {
        XCTAssertEqual(CaptureLimits.clamp("  four people  "), "four people")
        XCTAssertEqual(CaptureLimits.clamp("one two three", limit: 9), "one two")
        let long = String(repeating: "garlic ", count: 400)
        let clamped = CaptureLimits.clamp(long)
        XCTAssertLessThanOrEqual(clamped.unicodeScalars.count, CaptureLimits.spokenTextMax)
        XCTAssertTrue(clamped.hasSuffix("garlic"), "cut on a word boundary")
    }

    func testSplitBreaksLongTextIntoPiecesUnderTheLimit() {
        XCTAssertEqual(CaptureLimits.split("short words"), ["short words"])
        XCTAssertEqual(CaptureLimits.split("aa bb cc", limit: 5), ["aa bb", "cc"])
        XCTAssertEqual(CaptureLimits.split("abcdefgh", limit: 3), ["abc", "def", "gh"], "one over-long word is hard-cut")
        let long = String(repeating: "stir the pot ", count: 500)
        let pieces = CaptureLimits.split(long)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.unicodeScalars.count <= CaptureLimits.spokenTextMax })
        XCTAssertEqual(pieces.joined(separator: " "), long.trimmingCharacters(in: .whitespaces))
    }
}
