import Foundation
import Observation

/// One word in the live scan basket. `id` is stable for the chip's flight into the basket counter.
struct LiveScanBasketEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The server's basket key; the same key is never in the basket twice.
    let key: String
    let name: String
    let confidence: LiveScanConfidence
}

/// One-shot signal for the view: a new chip, or an "already have" pulse. `id` grows with every cue,
/// so the same item reported twice still animates twice.
struct LiveScanCue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case added(entryID: UUID)
        /// Already in the basket or already in the pantry; nothing was added.
        case alreadyHave
    }

    let id: Int
    let kind: Kind
    let key: String
    let name: String
}

/// What Done produced: items already saved, and the few the cook still has to decide.
struct LiveScanResultPresentation: Equatable {
    struct ReviewRow: Identifiable, Equatable {
        let id: String
        let name: String
        let reason: LiveScanReviewReason
        let reasonText: String
        let existingPantryItemId: UUID?

        init(_ item: LiveScanReviewItem) {
            id = item.key
            name = item.displayName.isEmpty ? item.canonicalName : item.displayName
            reason = item.reason
            existingPantryItemId = item.existingPantryItemId
            switch item.reason {
            case .unsure: reasonText = "Not sure"
            case .unrecognized: reasonText = "Not a name Umma knows"
            case .inPantry: reasonText = "Already in your pantry"
            case .demo: reasonText = "Demo item"
            case .unknown: reasonText = "Needs a check"
            }
        }
    }

    /// Saved with source `live`; the list shows them with an "Auto-added" chip.
    let autoAdded: [PantryItem]
    let review: [ReviewRow]

    init(_ finished: LiveScanFinished) {
        autoAdded = finished.saved
        review = finished.review.map(ReviewRow.init)
    }

    var autoAddedNames: [String] { autoAdded.map(\.rawLabel) }
}

/// Live pantry scan (brief 016): camera frames → Gemini Live → the backend basket.
///
/// One backend scan lasts the whole screen. Live sessions are short (`maxSessionSeconds`), so the
/// model rotates to a fresh token and transport while the basket and the scan id stay. Every
/// session start bumps `gate`; every stop supersedes it, so a late event or frame from an old
/// session is dropped. Nothing is stored on the phone and model audio is never played.
@MainActor
@Observable
final class LiveScanViewModel {
    enum Phase: Equatable {
        case idle
        /// Camera, token and connection are coming up (first start or "Keep scanning").
        case starting
        case scanning
        /// The 2-minute window ended. "Keep scanning" or Done.
        case timeUp
        /// Scan allowance or hourly limit reached. The basket is kept; Done still works.
        case limitReached
        /// The connection dropped and one reconnect didn't help. "Keep scanning" retries.
        case interrupted
        /// Couldn't start (camera, server, connection). "Keep scanning" retries.
        case failed
        case finishing
        case finished
        case cancelled
    }

    static let scanSeconds = 120
    nonisolated static let demoLabel = "Demo mode — not a real detection"
    static let limitMessage = "Today’s live scan allowance is used up. Tap Done to keep what you scanned, or add more by photo or voice."
    static let connectFailedMessage = "Couldn’t connect the live scan. Try again, or add items by photo or voice."
    static let scanClosedMessage = "This scan can’t take more items. Tap Done to keep what you scanned."
    /// A session that stayed open this long, or reported an item, was healthy.
    static let healthySessionSeconds: TimeInterval = 15
    /// How the server words a full basket (409 `STATE_CONFLICT`, same code as a finished scan).
    static let basketFullPrefix = "The basket is full"
    static let connectionMessage = "The scan lost its connection. Your basket is kept."

    private(set) var phase: Phase = .idle
    private(set) var basket: [LiveScanBasketEntry] = []
    private(set) var cue: LiveScanCue?
    /// Countdown of the current 2-minute window.
    private(set) var secondsRemaining = LiveScanViewModel.scanSeconds
    /// The token (or the server) said demo: scripted items, nothing auto-saved.
    private(set) var isDemo = false
    private(set) var message: String?
    /// The last start failed because camera access is denied; the screen offers "Open Settings".
    private(set) var permissionDenied = false
    private(set) var result: LiveScanResultPresentation?
    private(set) var scanID: UUID?

    let camera: any FrameStreamingCameraSource
    private let tokens: any LiveScanService
    private let service: any LiveScanBasketService
    private let makeTransport: @MainActor (LiveScanToken) -> any LiveScanTransport
    /// The pause between countdown updates; tests inject a sleep that never fires and call `tick()`.
    private let tickSleep: @Sendable () async throws -> Void
    /// Monotonic seconds. The window's deadline and a session's age are read from it.
    private let uptime: @Sendable () -> TimeInterval

    private var gate = CaptureStartGate()
    private var transport: (any LiveScanTransport)?
    /// Drains the current session's events; tests await it.
    private(set) var eventTask: Task<Void, Never>?
    /// The rotation or reconnect in flight; tests await it.
    private(set) var recoveryTask: Task<Void, Never>?
    /// The add on its way to the server. It is not cancelled with the session, so Done can wait for it.
    private var pendingAdd: Task<LiveScanItemResult, Error>?
    /// When the current 2-minute window ends, on `uptime`.
    private var deadline: TimeInterval?
    private var sessionOpenedAt: TimeInterval = 0
    private var frameTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// Keys the cook removed; a later report of the same item must never bring it back.
    private var removedKeys: Set<String> = []
    private var didAutoReconnect = false
    private var cueCount = 0

    init(camera: any FrameStreamingCameraSource,
         tokens: any LiveScanService,
         service: any LiveScanBasketService,
         makeTransport: @escaping @MainActor (LiveScanToken) -> any LiveScanTransport = { LiveScanTransports.make(for: $0) },
         tickSleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.camera = camera
        self.tokens = tokens
        self.service = service
        self.makeTransport = makeTransport
        self.tickSleep = tickSleep
        self.uptime = uptime
    }

    /// Drives the visible "Scanning" indicator; read from the source, never assumed.
    var cameraOn: Bool { camera.activeIndicator }
    var canContinue: Bool { phase == .timeUp || phase == .interrupted || phase == .failed }
    var canFinish: Bool { scanID != nil && [.starting, .scanning, .timeUp, .limitReached, .interrupted, .failed].contains(phase) }

    // MARK: - Start, stop

    func start() async {
        guard phase == .idle else { return }
        await begin()
    }

    /// Another 2-minute window on the same scan and basket. Also the retry after a failure.
    func continueScanning() async {
        guard canContinue else { return }
        await begin()
    }

    private func begin() async {
        let run = gate.begin()
        phase = .starting
        message = nil
        permissionDenied = false
        didAutoReconnect = false
        do {
            try await camera.startPreview()
            guard gate.isCurrent(run) else {
                // Stopped while the camera was starting: make sure it is off.
                if phase != .starting, phase != .scanning { await camera.stopPreview() }
                return
            }
            // The token comes first: the scan is created with the token's demo flag.
            let token = try await tokens.liveScanToken(alreadyInBasket: knownNames)
            guard gate.isCurrent(run) else { return }
            if scanID == nil {
                let scan = try await service.createLiveScan(demo: token.demo)
                guard gate.isCurrent(run) else { return }
                scanID = scan.id
                isDemo = token.demo || scan.demo
            } else if token.demo, !isDemo {
                await stop(.limitReached, Self.limitMessage)
                return
            }
            try await open(token, run: run)
            guard gate.isCurrent(run) else { return }
            phase = .scanning
            startTimer()
        } catch {
            guard gate.isCurrent(run) else { return }
            // A transport error has no user copy of its own.
            let text = error is LiveScanError ? Self.connectFailedMessage : error.pantryMessage
            if case CaptureError.permissionDenied = error { permissionDenied = true }
            await stop(Self.isLimit(error) ? .limitReached : .failed, text)
        }
    }

    /// Stops the camera and frames, closes the session, then saves: high-confidence new items go
    /// to the pantry, the rest come back for review.
    func finish() async {
        guard canFinish, let scanID else { return }
        await stop(.finishing)
        // Let an add that was already on its way to the server land before finishing.
        _ = await pendingAdd?.result
        do {
            let finished = try await service.finishLiveScan(scanID: scanID)
            guard phase == .finishing else { return }
            result = LiveScanResultPresentation(finished)
            phase = .finished
        } catch {
            guard phase == .finishing else { return }
            phase = .interrupted
            message = "Couldn’t save your scan: \(error.pantryMessage)"
        }
    }

    /// Stops everything and saves nothing. The server basket simply expires.
    func cancel() async {
        guard phase != .finishing, phase != .finished else { return }
        scanID = nil
        basket = []
        cue = nil
        await stop(.cancelled)
    }

    func remove(_ entry: LiveScanBasketEntry) async {
        guard phase != .finishing, phase != .finished, phase != .cancelled else { return }
        guard let scanID, let index = basket.firstIndex(where: { $0.id == entry.id }) else { return }
        basket.remove(at: index)
        removedKeys.insert(entry.key)
        do {
            try await service.removeLiveScanItem(scanID: scanID, key: entry.key)
        } catch {
            guard self.scanID == scanID else { return }
            removedKeys.remove(entry.key)
            if !basket.contains(where: { $0.key == entry.key }) {
                basket.insert(entry, at: min(index, basket.count))
            }
            message = Self.removeFailedMessage(entry.name, error)
        }
    }

    private static func removeFailedMessage(_ name: String, _ error: Error) -> String {
        "Couldn’t remove \(name): \(error.pantryMessage)"
    }

    /// Updates the countdown from the window's deadline, so a late tick can't stretch the window.
    /// The timer calls it; tests call it directly. Does nothing once the scan stopped.
    func tick() async {
        guard phase == .scanning, let deadline else { return }
        secondsRemaining = max(0, Int((deadline - uptime()).rounded(.up)))
        if secondsRemaining == 0 { await stop(.timeUp) }
    }

    // MARK: - Session

    private var knownNames: [String] { basket.map(\.key) + removedKeys.sorted() }

    private static func isLimit(_ error: Error) -> Bool {
        (error as? APIError)?.isRateLimited == true
    }

    private func open(_ token: LiveScanToken, run: Int) async throws {
        let transport = makeTransport(token)
        self.transport = transport
        try await transport.connect(token: token)
        guard gate.isCurrent(run) else {
            transport.close()
            return
        }
        sessionOpenedAt = uptime()
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, self.gate.isCurrent(run) else { return }
                await self.handle(event, run: run)
            }
        }
        let frames = camera.frames(maxFPS: token.frameMaxFps, longEdge: LiveFrameDefaults.longEdge)
        frameTask = Task { [weak self] in
            for await frame in frames {
                guard let self, self.gate.isCurrent(run) else { return }
                self.transport?.send(frame: frame.jpegData)
            }
        }
    }

    /// Never waits for the transport: both drains are cancelled, whether or not `close()` ends
    /// the event stream.
    private func closeSession() {
        frameTask?.cancel()
        frameTask = nil
        eventTask?.cancel()
        eventTask = nil
        transport?.close()
        transport = nil
    }

    /// Ends the live part: no session, no frames, no timer, camera off. The basket stays.
    private func stop(_ next: Phase, _ text: String? = nil) async {
        gate.supersede()
        closeSession()
        timerTask?.cancel()
        timerTask = nil
        phase = next
        message = text
        await camera.stopPreview()
    }

    private func startTimer() {
        timerTask?.cancel()
        deadline = uptime() + TimeInterval(Self.scanSeconds)
        secondsRemaining = Self.scanSeconds
        timerTask = Task { [weak self, tickSleep] in
            while true {
                do { try await tickSleep() } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func handle(_ event: LiveScanEvent, run: Int) async {
        switch event {
        case .itemReported(let callID, let name, let kind, let confidence):
            // A session that reports items is healthy: a later drop gets its own reconnect.
            didAutoReconnect = false
            await report(callID: callID, name: name, kind: kind, confidence: confidence, run: run)
        case .goAway, .closed(.sessionLimit):
            // The short session ran out: rotate.
            didAutoReconnect = false
            reconnect(after: run)
        case .closed(.client):
            break
        case .closed, .error:
            if uptime() - sessionOpenedAt >= Self.healthySessionSeconds { didAutoReconnect = false }
            guard !didAutoReconnect else {
                await stop(.interrupted, Self.connectionMessage)
                return
            }
            didAutoReconnect = true
            reconnect(after: run)
        }
    }

    /// New token, new transport, same scan and basket. The countdown keeps running. The work runs
    /// in its own task: closing the old session cancels the event task this is called from.
    private func reconnect(after old: Int) {
        guard gate.isCurrent(old), phase == .scanning else { return }
        let run = gate.begin()
        closeSession()
        recoveryTask = Task { [weak self] in
            await self?.openNextSession(run: run)
        }
    }

    private func openNextSession(run: Int) async {
        do {
            let token = try await tokens.liveScanToken(alreadyInBasket: knownNames)
            guard gate.isCurrent(run) else { return }
            if token.demo, !isDemo {
                await stop(.limitReached, Self.limitMessage)
                return
            }
            try await open(token, run: run)
        } catch {
            guard gate.isCurrent(run) else { return }
            if Self.isLimit(error) {
                await stop(.limitReached, error.pantryMessage)
            } else {
                await stop(.interrupted, Self.connectionMessage)
            }
        }
    }

    private enum AddFailure {
        /// This item is refused for good (not an ingredient, basket full). The scan goes on.
        case refused
        /// The scan itself can't take items any more (signed out, gone, finished).
        case scanClosed
        case transient
    }

    /// A full basket and a finished scan are both 409 `STATE_CONFLICT`; only the message differs.
    /// Any 409 that isn't the full-basket message counts as the scan being closed.
    private static func addFailure(_ error: Error) -> AddFailure {
        guard let api = error as? APIError, let code = api.status else { return .transient }
        switch code {
        case 422:
            return .refused
        case 409:
            if case .server(_, _, let text, _, _, _) = api, text.hasPrefix(basketFullPrefix) { return .refused }
            return .scanClosed
        case 401, 403, 404:
            return .scanClosed
        default:
            return .transient
        }
    }

    /// Sends one reported item to the basket and always answers the model, so it never waits.
    private func report(callID: String, name: String, kind: String?, confidence: LiveScanConfidence, run: Int) async {
        guard let scanID else { return }
        var status = "error"
        var canonical: String?
        var cueKind: LiveScanCue.Kind?
        var item: LiveScanItemResult?
        var scanClosed = false
        let reported = LiveScanItemReport(name: name, kind: kind, confidence: confidence)
        // Its own task: stopping the session must not cancel a request the server may already hold.
        let add = Task { [service] in
            try await service.addLiveScanItem(scanID: scanID, reported)
        }
        pendingAdd = add
        do {
            let out = try await add.value
            item = out
            canonical = out.canonicalName
            var removedAgain = false
            if out.status == .new, removedKeys.contains(out.key) {
                // The cook removed it during this scan: take it out again, never save it.
                do {
                    try await service.removeLiveScanItem(scanID: scanID, key: out.key)
                    removedAgain = true
                } catch {
                    // The server still holds it and would save it: show it again and say why.
                    guard self.scanID == scanID else { return }
                    removedKeys.remove(out.key)
                    message = Self.removeFailedMessage(out.canonicalName, error)
                }
            }
            switch out.status {
            case .new where removedAgain:
                status = LiveScanItemStatus.alreadyInBasket.rawValue
            case .new where !basket.contains(where: { $0.key == out.key }):
                // The server holds it now, so the basket shows it even if the scan just stopped.
                guard self.scanID == scanID else { return }
                let entry = LiveScanBasketEntry(id: UUID(), key: out.key, name: out.canonicalName, confidence: out.confidence)
                basket.append(entry)
                status = LiveScanItemStatus.new.rawValue
                cueKind = .added(entryID: entry.id)
            case .new, .alreadyInBasket:
                status = LiveScanItemStatus.alreadyInBasket.rawValue
                cueKind = .alreadyHave
            case .inPantry:
                status = LiveScanItemStatus.inPantry.rawValue
                cueKind = .alreadyHave
            case .unknown:
                status = "ignored"
            }
        } catch {
            switch Self.addFailure(error) {
            case .refused: status = "ignored"
            case .scanClosed: scanClosed = true
            case .transient: break
            }
        }
        // A stopped or rotated session gets no answer and no animation.
        guard gate.isCurrent(run) else { return }
        transport?.respond(callID: callID, name: "add_item", status: status, canonical: canonical)
        if let cueKind, let item {
            cueCount += 1
            cue = LiveScanCue(id: cueCount, kind: cueKind, key: item.key, name: item.canonicalName)
        }
        if scanClosed { await stop(.interrupted, Self.scanClosedMessage) }
    }
}
