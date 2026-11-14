import Foundation
import Observation

/// Turns a finished recording into a draft (brief 014 §6): `POST …/generate`, then polls the job
/// until it is ready or failed. Over a cap the recording is kept and nothing is lost: the creator
/// can try again later or type the recipe in.
@MainActor
@Observable
final class CaptureDraftGenerator {
    enum State: Equatable {
        case idle
        case requesting
        /// The job is running. `stage` is the server's (`queued`, `extracting`, `done`).
        case working(stage: String?, progress: Int)
        case ready(draftId: UUID, demo: Bool)
        /// Refused for now (monthly allowance, AI resting): retry later, the recording is kept.
        case deferred(String)
        /// The job failed; `draftId` is an editable (partial) draft when there is one.
        case failed(String, draftId: UUID?)
    }

    private(set) var state: State = .idle
    private let api: CaptureService
    private let coordinator: CaptureCoordinator
    private let pollInterval: Duration
    /// Polling gives up (retryably) once this much time has been spent waiting between polls.
    private let pollDeadline: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var task: Task<Void, Never>?
    /// Set when polling gave up: Try again checks the same job instead of generating again.
    private var reattachToJob = false

    init(api: CaptureService,
         coordinator: CaptureCoordinator,
         pollInterval: Duration = .seconds(2),
         pollDeadline: Duration = .seconds(180),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.api = api
        self.coordinator = coordinator
        self.pollInterval = pollInterval
        self.pollDeadline = pollDeadline
        self.sleep = sleep
    }

    /// Starts (or, after a relaunch, re-attaches to) the generation job.
    func start() {
        switch state {
        case .idle, .deferred, .failed: break
        default: return
        }
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits for the current run (tests).
    func wait() async {
        await task?.value
    }

    private func run() async {
        guard let sessionId = coordinator.sessionId else {
            state = .failed("This recording is no longer on this phone.", draftId: nil)
            return
        }
        var jobId = coordinator.record?.jobId
        let reattach = reattachToJob && jobId != nil
        reattachToJob = false
        if reattach {
            // Polling timed out last time; the job may have finished since.
            state = .working(stage: nil, progress: 0)
        } else if case .failed = state {
            // A failed job can be retried: generate again with a fresh key.
            jobId = nil
            coordinator.noteGeneration(key: UUID().uuidString, jobId: nil, draftId: nil)
        }
        if jobId == nil {
            state = .requesting
            // The wrap-up answers must reach the server before it writes the draft.
            guard await coordinator.flushWrites() else {
                state = .deferred("No connection right now. Your recording is kept on this phone. Try again, or type the recipe in.")
                return
            }
            let key = coordinator.record?.generateKey ?? UUID().uuidString
            coordinator.noteGeneration(key: key, jobId: nil, draftId: nil)
            do {
                let job = try await api.generateCaptureDraft(sessionId: sessionId, idempotencyKey: key)
                coordinator.noteGeneration(key: key, jobId: job.id, draftId: job.draftId)
                jobId = job.id
                if apply(job) { return }
            } catch _ where Task.isCancelled {
                return  // `cancel()`: leaving the screen is not a failure; the key is kept
            } catch let error as APIError where error.isCaptureGenerationDeferred {
                // The key is spent on a refusal; a later try is a new request.
                coordinator.noteGeneration(key: UUID().uuidString, jobId: nil, draftId: nil)
                state = .deferred("Your recording is kept. \(error.userMessage) Try again later, or type the recipe in.")
                return
            } catch {
                state = .failed(CaptureCoordinator.message(error), draftId: nil)
                return
            }
        }
        guard let jobId else { return }
        var waited: Duration = .zero
        while !Task.isCancelled {
            do {
                let job = try await api.extractionJob(id: jobId)
                if apply(job) { return }
            } catch _ where Task.isCancelled {
                return  // `cancel()`: not a failure
            } catch let error as APIError where !error.isRetryable && error != .cancelled {
                state = .failed(error.userMessage, draftId: coordinator.record?.draftId)
                return
            } catch {
                // A blip while polling: keep going, the job runs on the server regardless.
            }
            if waited >= pollDeadline {
                // Never spin forever: say so, keep the recording, and let Try again check this job.
                reattachToJob = true
                state = .failed("Umma is taking longer than usual to write this recipe. Your recording is kept. Try again to check on it.",
                                draftId: nil)
                return
            }
            await sleep(pollInterval)
            waited += pollInterval
        }
    }

    /// True when the job is finished.
    private func apply(_ job: ExtractionJob) -> Bool {
        switch job.status {
        case .ready:
            guard let draftId = job.draftId else {
                state = .failed("The draft was deleted.", draftId: nil)
                return true
            }
            state = .ready(draftId: draftId, demo: job.demo)
            coordinator.forget()
            return true
        case .failed:
            let code = job.error?.code
            let message = job.error?.message ?? "Umma couldn’t write the recipe."
            if code == "AI_RESTING" {
                coordinator.noteGeneration(key: UUID().uuidString, jobId: nil, draftId: job.draftId)
                state = .deferred("Your recording is kept. \(message) Try again later, or type the recipe in.")
            } else {
                state = .failed(message, draftId: job.draftId)
            }
            return true
        default:
            state = .working(stage: job.stage, progress: job.progress)
            return false
        }
    }
}

/// What the generating screen says for each state: honest, no fake progress.
struct GeneratingPresentation: Equatable {
    let title: String
    let message: String
    let progress: Double?
    let showsSpinner: Bool
    let showsRetry: Bool
    let showsTypeIn: Bool
    let showsOpenDraft: Bool

    /// `openError`: the ready draft couldn't be opened in the editor (shown with a retry).
    init(_ state: CaptureDraftGenerator.State, openError: String? = nil) {
        switch state {
        case .idle, .requesting:
            title = "Writing your recipe"
            message = "Sending your recording to Umma…"
            progress = nil
            (showsSpinner, showsRetry, showsTypeIn, showsOpenDraft) = (true, false, false, false)
        case .working(let stage, let value):
            title = "Writing your recipe"
            switch stage {
            case "queued": message = "Waiting for a turn. This usually takes a few seconds."
            case "done": message = "Almost there…"
            default: message = "Reading what you said and writing the steps. Nothing you didn’t say is filled in."
            }
            progress = value > 0 ? Double(min(value, 100)) / 100 : nil
            (showsSpinner, showsRetry, showsTypeIn, showsOpenDraft) = (progress == nil, false, false, false)
        case .ready:
            title = "Your draft is ready"
            progress = 1
            if let openError {
                message = "Couldn’t open it in the editor. \(openError)"
                (showsSpinner, showsRetry, showsTypeIn, showsOpenDraft) = (false, false, false, true)
            } else {
                message = "Opening it in the editor…"
                (showsSpinner, showsRetry, showsTypeIn, showsOpenDraft) = (false, false, false, false)
            }
        case .deferred(let text):
            title = "Recording kept, try again later"
            message = text
            progress = nil
            (showsSpinner, showsRetry, showsTypeIn, showsOpenDraft) = (false, true, true, false)
        case .failed(let text, let draftId):
            title = "Umma couldn’t write the recipe"
            message = draftId == nil ? text : "\(text) The draft is still there for you to fill in."
            progress = nil
            (showsSpinner, showsRetry, showsTypeIn, showsOpenDraft) = (false, true, draftId == nil, draftId != nil)
        }
    }
}
