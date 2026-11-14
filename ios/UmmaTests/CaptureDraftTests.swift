import Foundation
import XCTest
@testable import Umma

/// Brief 014 wrap-up → generating → draft: the generator's states and the editor's AI labels.
@MainActor
final class CaptureDraftTests: XCTestCase {
    private var api: FakeCaptureService!
    private var journal: CaptureJournalStore!
    private var draftId: UUID { Self.draftId }

    override func setUp() async throws {
        api = FakeCaptureService()
        journal = CaptureJournalStore(directory: FileManager.default.temporaryDirectory.appending(path: "capture-draft-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: journal.directory)
    }

    private nonisolated static let draftId = UUID()

    private nonisolated static func job(_ status: ExtractionJobStatus, _ stage: String? = nil, _ progress: Int = 0,
                                        _ error: ExtractionJobError? = nil, _ jobId: UUID? = nil) -> ExtractionJob {
        ExtractionJob(id: jobId ?? UUID(uuidString: "6f1c2a3b-0000-4000-8000-0000000000bb")!, kind: "capture", status: status,
                      stage: stage, progress: progress, draftId: draftId, demo: true, partial: false, error: error,
                      attempts: 1, createdAt: Date(), updatedAt: Date(), finishedAt: nil)
    }

    /// A coordinator that has recorded and finished (no questions left), ready to generate.
    private func finishedCoordinator() async -> CaptureCoordinator {
        let transport = FakeVoiceTransport()
        let coordinator = CaptureCoordinator(api: api, makeVoice: { VoiceSession(transport: transport, clock: FakeVoiceClock(), config: $0) },
                                             journal: journal, userId: nil, ticker: FakeVoiceClock(),
                                             config: .init(introLine: nil), sleep: { _ in await Task.yield() })
        await coordinator.start(titleHint: "Mum's Kimchi Jjigae")
        await coordinator.finish()
        return coordinator
    }

    private func generator(_ coordinator: CaptureCoordinator) -> CaptureDraftGenerator {
        CaptureDraftGenerator(api: api, coordinator: coordinator, pollInterval: .zero, sleep: { _ in await Task.yield() })
    }

    // MARK: - Generator

    func testGeneratePollsUntilReadyThenForgetsTheJournal() async {
        let coordinator = await finishedCoordinator()
        XCTAssertEqual(coordinator.phase, .readyToGenerate)
        let polls = LockedCounter(2)
        api.generateHandler = { Self.job(.queued, "queued", 0, nil, nil) }
        api.jobHandler = { _ in polls.take() ? Self.job(.processing, "extracting", 40, nil, nil) : Self.job(.ready, "done", 100, nil, nil) }
        let generator = generator(coordinator)
        generator.start()
        await generator.wait()
        XCTAssertEqual(generator.state, .ready(draftId: draftId, demo: true))
        XCTAssertNil(journal.load(api.sessionId), "nothing left to resume once the draft exists")
        XCTAssertEqual(api.calls.filter { if case .job = $0 { true } else { false } }.count, 3)
    }

    func testOverTheCapKeepsTheRecordingAndOffersTypeIn() async {
        let coordinator = await finishedCoordinator()
        api.generateHandler = {
            throw APIError.server(status: 429, code: "CAPTURE_GENERATION_LIMIT", message: "You’ve used this month’s AI drafts.",
                                  retryable: true, correlationId: nil)
        }
        let generator = generator(coordinator)
        generator.start()
        await generator.wait()
        guard case .deferred(let message) = generator.state else { return XCTFail("expected deferred, got \(generator.state)") }
        XCTAssertTrue(message.contains("recording is kept"))
        let p = GeneratingPresentation(generator.state)
        XCTAssertEqual(p.title, "Recording kept, try again later")
        XCTAssertTrue(p.showsTypeIn && p.showsRetry)
        XCTAssertNotNil(journal.load(api.sessionId), "the recording stays resumable")
    }

    func testAIRestingJobFailureIsDeferredAndRetryUsesANewKey() async {
        let coordinator = await finishedCoordinator()
        let first = LockedFlag()
        api.generateHandler = { Self.job(.queued, "queued", 0, nil, nil) }
        api.jobHandler = { _ in
            first.setOnce() ? Self.job(.failed, nil, 0, ExtractionJobError(code: "AI_RESTING", message: "Umma’s AI is resting this month."), nil)
                            : Self.job(.ready, "done", 100, nil, nil)
        }
        let generator = generator(coordinator)
        generator.start()
        await generator.wait()
        guard case .deferred = generator.state else { return XCTFail("expected deferred") }
        generator.start()
        await generator.wait()
        XCTAssertEqual(generator.state, .ready(draftId: draftId, demo: true))
        let keys = api.calls.compactMap { if case .generate(let key) = $0 { key } else { nil } }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
    }

    func testFailedJobOffersTheEditableDraft() async {
        let coordinator = await finishedCoordinator()
        api.generateHandler = { Self.job(.failed, nil, 0, ExtractionJobError(code: "TRANSCRIPT_EMPTY", message: "Umma didn’t hear any cooking."), nil) }
        let generator = generator(coordinator)
        generator.start()
        await generator.wait()
        XCTAssertEqual(generator.state, .failed("Umma didn’t hear any cooking.", draftId: draftId))
        let p = GeneratingPresentation(generator.state)
        XCTAssertTrue(p.showsOpenDraft)
        XCTAssertTrue(p.message.contains("still there"))
    }

    func testRelaunchDuringGenerationPollsTheSameJobWithoutGeneratingAgain() async throws {
        let coordinator = await finishedCoordinator()
        let jobId = UUID()
        coordinator.noteGeneration(key: "k-gen", jobId: jobId, draftId: draftId)
        let saved = try XCTUnwrap(journal.load(api.sessionId))
        api.sessionStatus = .generating
        api.jobHandler = { id in Self.job(.ready, "done", 100, nil, id) }
        let resumed = CaptureCoordinator(api: api, makeVoice: { VoiceSession(transport: FakeVoiceTransport(), clock: FakeVoiceClock(), config: $0) },
                                         journal: journal, userId: nil, ticker: FakeVoiceClock(), sleep: { _ in })
        await resumed.resume(from: saved)
        XCTAssertEqual(resumed.phase, .readyToGenerate)
        XCTAssertFalse(resumed.voice.state.isActive, "finishing a recording never reopens the mic")
        let generator = generator(resumed)
        generator.start()
        await generator.wait()
        XCTAssertEqual(generator.state, .ready(draftId: draftId, demo: true))
        XCTAssertFalse(api.calls.contains { if case .generate = $0 { true } else { false } })
        XCTAssertEqual(api.calls.last, .job(jobId))
    }

    func testPollingGivesUpAtTheDeadlineAndTryAgainChecksTheSameJob() async {
        let coordinator = await finishedCoordinator()
        api.generateHandler = { Self.job(.queued, "queued", 0, nil, nil) }
        api.jobHandler = { _ in Self.job(.processing, "extracting", 40, nil, nil) }
        let generator = CaptureDraftGenerator(api: api, coordinator: coordinator, pollInterval: .seconds(2),
                                              pollDeadline: .seconds(10), sleep: { _ in await Task.yield() })
        generator.start()
        await generator.wait()
        guard case .failed(let message, let failedDraft) = generator.state else { return XCTFail("expected a timeout, got \(generator.state)") }
        XCTAssertTrue(message.contains("recording is kept"))
        XCTAssertNil(failedDraft)
        XCTAssertTrue(GeneratingPresentation(generator.state).showsRetry, "the timeout is retryable")
        XCTAssertEqual(api.calls.filter { if case .job = $0 { true } else { false } }.count, 6, "polls at 0, 2, 4, 6, 8 and 10 s")

        api.jobHandler = { _ in Self.job(.ready, "done", 100, nil, nil) }
        generator.start()
        await generator.wait()
        XCTAssertEqual(generator.state, .ready(draftId: draftId, demo: true))
        XCTAssertEqual(api.calls.filter { if case .generate = $0 { true } else { false } }.count, 1, "Try again re-checks the job, never generates twice")
    }

    func testCancelDuringAPollIsNotAFailure() async {
        let coordinator = await finishedCoordinator()
        api.generateHandler = { Self.job(.queued, "queued", 0, nil, nil) }
        api.jobGate = {
            do { try await Task.sleep(for: .seconds(30)) } catch { throw APIError.cancelled }
        }
        let generator = generator(coordinator)
        generator.start()
        for _ in 0..<300 where !api.calls.contains(where: { if case .job = $0 { true } else { false } }) { await Task.yield() }
        generator.cancel()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(generator.state, .working(stage: "queued", progress: 0), "leaving the screen never shows a failure")
    }

    func testGeneratingCopyIsHonest() {
        XCTAssertEqual(GeneratingPresentation(.working(stage: "queued", progress: 0)).message, "Waiting for a turn. This usually takes a few seconds.")
        let working = GeneratingPresentation(.working(stage: "extracting", progress: 40))
        XCTAssertEqual(working.progress, 0.4)
        XCTAssertFalse(working.showsSpinner)
        XCTAssertTrue(GeneratingPresentation(.working(stage: "extracting", progress: 0)).showsSpinner, "no fake progress bar")
    }

    func testADraftThatWontOpenSaysSoAndOffersARetry() {
        let opening = GeneratingPresentation(.ready(draftId: draftId, demo: false))
        XCTAssertEqual(opening.message, "Opening it in the editor…")
        XCTAssertFalse(opening.showsOpenDraft)
        let failed = GeneratingPresentation(.ready(draftId: draftId, demo: false), openError: "No connection.")
        XCTAssertEqual(failed.message, "Couldn’t open it in the editor. No connection.")
        XCTAssertTrue(failed.showsOpenDraft, "the draft button retries")
        XCTAssertFalse(failed.showsSpinner)
    }

    // MARK: - Draft labels

    private func aiDraft(servings: Int? = nil, cookMinutes: Int? = nil) -> Draft {
        Draft(id: draftId, recipeId: nil, status: .draft, title: "Kimchi Jjigae", summary: nil, tags: [], coverImageUrl: nil,
              servings: servings, prepMinutes: nil, cookMinutes: cookMinutes,
              ingredients: [
                Ingredient(id: "ing-1", name: "pork belly", quantity: nil, unit: nil, optional: false, preparation: nil, notes: nil, evidenceOrigin: .aiExtracted),
                Ingredient(id: "ing-2", name: "kimchi", quantity: 2, unit: "cup", optional: false, preparation: nil, notes: nil, evidenceOrigin: .aiExtracted),
                Ingredient(id: "ing-3", name: "sesame seeds", quantity: nil, unit: nil, optional: true, preparation: nil, notes: nil, evidenceOrigin: .creatorReviewed),
              ],
              steps: [RecipeStep(id: "step-1", order: 0, instruction: "Simmer", ingredientRefs: [], estimatedMinutes: nil, successCues: [],
                                 warnings: [], creatorNote: nil, sourceClipId: nil, sourceStartMs: nil, sourceEndMs: nil, evidenceOrigin: .aiExtracted)],
              creatorNotes: ["Mum always uses the old sour kimchi"], dietaryWarnings: [],
              validation: .empty, createdAt: Date(), updatedAt: Date(),
              extraction: DraftExtraction(jobId: UUID(), demo: true, unknowns: ["amount of pork belly not stated"], notice: "Demo draft: AI is off."))
    }

    func testAIDraftLabelsFieldsAndMarksWhatWasNeverSaid() throws {
        let draft = aiDraft()
        let form = DraftForm(draft: draft)
        let review = try XCTUnwrap(DraftReviewPresentation(draft: draft, form: form))
        XCTAssertEqual(review.bannerTitle, "Demo draft from your recording")
        XCTAssertEqual(review.notice, "Demo draft: AI is off.")
        XCTAssertEqual(review.unknowns, ["amount of pork belly not stated"])
        XCTAssertTrue(review.servingsNeedsReview)
        XCTAssertTrue(review.cookTimeNeedsReview)
        XCTAssertEqual(form.ingredients.map { DraftReviewPresentation.ingredientLabels($0, isAIDraft: true) },
                       [["AI-drafted, check this", "Amount needs review"], ["AI-drafted, check this"], []])
        XCTAssertEqual(DraftReviewPresentation.stepLabels(form.steps[0], isAIDraft: true), ["AI-drafted, check this"])
    }

    func testHandAuthoredDraftHasNoReviewLabels() {
        var draft = aiDraft()
        draft.extraction = nil
        let form = DraftForm(draft: draft)
        XCTAssertNil(DraftReviewPresentation(draft: draft, form: form))
        XCTAssertFalse(form.servingsUnset)
        XCTAssertEqual(form.patch().servings, 4, "hand-authored drafts keep today's default")
    }

    func testUnsaidServingsAreNeverGuessedUntilSet() throws {
        var form = DraftForm(draft: aiDraft())
        XCTAssertTrue(form.servingsUnset)
        XCTAssertNil(form.patch().servings, "4 is only the stepper's start, never sent as a guess")
        form.servings = 5
        XCTAssertFalse(form.servingsUnset)
        XCTAssertEqual(form.patch().servings, 5)
        XCTAssertFalse(try XCTUnwrap(DraftReviewPresentation(draft: aiDraft(), form: form)).servingsNeedsReview)
        XCTAssertFalse(DraftForm(draft: aiDraft(servings: 3)).servingsUnset)
    }

    func testUnsaidServingsAreSentAsNullSoPublishStillRequiresThem() throws {
        let body = try JSONCoding.makeEncoder().encode(DraftForm(draft: aiDraft()).patch())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(json["servings"] is NSNull, "the backend's PATCH accepts null; publish validation then asks for servings")
    }

    func testAutosaveKeepsIngredientOrigins() {
        let patch = DraftForm(draft: aiDraft()).patch()
        XCTAssertEqual(patch.ingredients?.map(\.evidenceOrigin), [.aiExtracted, .aiExtracted, .creatorReviewed])
    }
}
