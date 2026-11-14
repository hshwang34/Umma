import Foundation
import Observation

/// Assistant drawer (PRD §6, COOK-03/04, Appendix A): typed questions, grounded answers.
///
/// The coach never changes state. A `proposed_action` is rendered as a question button; only a
/// tap on it sends a (confirmed) command, through the cooking screen's command path.
@MainActor
@Observable
final class AssistantViewModel {
    struct Turn: Identifiable, Equatable {
        let id: UUID
        let query: String
        let response: AskResponse
        /// The server's `step_index` when the question was asked.
        let stepIndexAtAsk: Int
        var proposalUsed = false

        var segments: [AnswerSegment] { AnswerSegment.split(response.answerText) }
    }

    static let maxQueryLength = 500

    var query = "" {
        didSet {
            if query.count > Self.maxQueryLength { query = String(query.prefix(Self.maxQueryLength)) }
        }
    }
    private(set) var turns: [Turn] = []
    private(set) var isAsking = false
    private(set) var errorMessage: String?
    /// False while the drawer is closed: an answer is never read out after dismissal.
    private(set) var isVisible = true

    private let sessionId: UUID
    private let service: CookingService
    private let audio: any AudioOutput
    /// Brief 017: the confirmed paths behind "Add to shopping list" and "Remove from pantry".
    private let shopping: ShoppingService?
    private let pantry: PantryService?
    /// The cooking screen's canonical Session (for `grounded_revision`, badges and staleness).
    private let currentSession: @MainActor () -> CookingSession?
    /// Sends a tapped proposal as a confirmed command; returns true when the server accepted it.
    var onProposal: (@MainActor (ProposedAction) async -> Bool)?
    /// Sends "Use this swap" as a confirmed `approve_adaptation`; true when the server accepted it.
    var onApproveSwap: (@MainActor (AdaptationInput) async -> Bool)?
    var onPantryChanged: (@MainActor () -> Void)?
    /// What the cook has done with each answer's missing-ingredient offer, by turn id.
    private(set) var offerStates: [UUID: MissingIngredientOffer.State] = [:]

    init(sessionId: UUID, service: CookingService, audio: any AudioOutput,
         shopping: ShoppingService? = nil, pantry: PantryService? = nil,
         currentSession: @escaping @MainActor () -> CookingSession?) {
        self.sessionId = sessionId
        self.service = service
        self.audio = audio
        self.shopping = shopping
        self.pantry = pantry
        self.currentSession = currentSession
    }

    var canAsk: Bool {
        !isAsking && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && currentSession() != nil
    }

    // MARK: Missing ingredient (brief 017)

    /// The offer under an answer, as displayed. Nil when the answer carries none.
    func offer(for turn: Turn) -> MissingIngredientOffer? {
        guard let missing = turn.response.missingIngredient else { return nil }
        return MissingIngredientOffer(missing: missing, state: offerStates[turn.id] ?? .init(),
                                      session: currentSession(), canShop: shopping != nil, canEditPantry: pantry != nil)
    }

    /// One explicit tap on one button of the offer. Nothing else happens with it: using the swap
    /// does not touch the pantry or the list, and the other way round. A failure leaves the offer
    /// as it was, with a plain error under it.
    func perform(_ action: MissingIngredientOffer.Action, turnId: UUID) async {
        guard let turn = turns.first(where: { $0.id == turnId }), let missing = turn.response.missingIngredient,
              let offer = offer(for: turn), offer.actions.contains(action), offer.busy == nil
        else { return }
        update(turnId) { $0.busy = action; $0.error = nil }
        let failure = await run(action, missing: missing)
        update(turnId) { state in
            state.busy = nil
            state.error = failure
            guard failure == nil else { return }
            switch action {
            case .useSwap: state.swapApplied = true
            case .addToShoppingList: state.addedToShoppingList = true
            case .removeFromPantry: state.removedFromPantry = true
            }
        }
    }

    /// Returns nil on success, or the message to show.
    private func run(_ action: MissingIngredientOffer.Action, missing: MissingIngredient) async -> String? {
        switch action {
        case .useSwap:
            guard let swap = missing.swap, let onApproveSwap else { return MissingIngredientOffer.swapFailed }
            return await onApproveSwap(swap.adaptation) ? nil : MissingIngredientOffer.swapFailed
        case .addToShoppingList:
            guard let name = missing.shoppingName, let shopping else { return MissingIngredientOffer.shoppingFailed }
            do {
                // In the pantry until now means it ran out; otherwise it was simply missing.
                _ = try await shopping.addShoppingItem(name: name, reason: missing.pantryItemId == nil ? .missing : .ranOut,
                                                       recipeVersionId: currentSession()?.recipeVersionId)
                return nil
            } catch {
                return MissingIngredientOffer.shoppingFailed
            }
        case .removeFromPantry:
            guard let id = missing.pantryItemId, let pantry else { return MissingIngredientOffer.pantryFailed }
            do {
                try await pantry.deletePantryItem(id: id)
            } catch let error as APIError where error.isNotFound {
                // Already gone (removed elsewhere): the answer is the same.
            } catch {
                return MissingIngredientOffer.pantryFailed
            }
            onPantryChanged?()
            return nil
        }
    }

    private func update(_ turnId: UUID, _ change: (inout MissingIngredientOffer.State) -> Void) {
        var state = offerStates[turnId] ?? .init()
        change(&state)
        offerStates[turnId] = state
    }

    /// "Which one?": the cook picks an ingredient and the coach is asked about that one. Asking is
    /// read only; the answer comes back as a new offer.
    func pick(_ candidate: MissingIngredient.Candidate, turnId: UUID) async {
        guard !isAsking, let turn = turns.first(where: { $0.id == turnId }),
              offer(for: turn)?.candidates.contains(candidate) == true
        else { return }
        let typed = query
        query = MissingIngredientOffer.pickQuery(candidate.name)
        let before = turns.count
        await ask()
        // Whatever the cook was typing is theirs; a failed ask leaves the choices on screen.
        query = typed
        if turns.count > before { update(turnId) { $0.picked = true } }
    }

    func ask() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking, let session = currentSession() else { return }
        isAsking = true
        errorMessage = nil
        defer { isAsking = false }
        do {
            let response = try await service.ask(sessionId: sessionId, query: text, groundedRevision: session.revision)
            turns.append(Turn(id: response.messageId, query: text, response: response, stepIndexAtAsk: session.stepIndex))
            query = ""
        } catch let error as APIError where error == .cancelled {
            return
        } catch let error as APIError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func message(for error: APIError) -> String {
        if error.isRateLimited {
            return "You’ve asked a lot this hour. Try again in a little while — the step on screen still has everything the recipe says."
        }
        if error.isTransportFailure {
            return "Can’t reach the coach right now. The step on screen still has everything the recipe says."
        }
        if let status = error.status, status >= 500 {
            return "The coach couldn’t answer right now. Try again, or follow the step on screen."
        }
        return error.userMessage
    }

    /// "Based on previous step": the server said so, or the step moved since the question.
    func isStale(_ turn: Turn) -> Bool {
        if turn.response.stale { return true }
        guard let session = currentSession() else { return false }
        return session.stepIndex != turn.stepIndexAtAsk
    }

    func badges(for turn: Turn) -> [GroundingBadge] {
        GroundingBadge.badges(for: turn.response.grounding, session: currentSession())
    }

    /// The proposal button, if the answer carries one the user hasn't used yet.
    func proposal(for turn: Turn) -> ProposedAction? {
        guard !turn.proposalUsed, let action = turn.response.proposedAction, action.isSupported else { return nil }
        // A stale proposal (the step already moved) is not offered.
        if isStale(turn) { return nil }
        // Only for exactly the state it was grounded on, and never while paused.
        guard let session = currentSession(), session.status == .active,
              session.revision == turn.response.groundedSessionRevision
        else { return nil }
        return action
    }

    func proposalTitle(for turn: Turn) -> String? {
        proposal(for: turn)?.buttonTitle(stepsCount: currentSession()?.stepsCount)
    }

    /// The user tapped the proposal: that tap is the confirmation.
    func acceptProposal(turnId: UUID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnId }),
              let action = proposal(for: turns[index]),
              let onProposal
        else { return }
        if await onProposal(action) {
            if let current = turns.firstIndex(where: { $0.id == turnId }) { turns[current].proposalUsed = true }
        }
    }

    /// The safety notice, when there is one, is read first.
    func readAloud(turnId: UUID) async {
        guard isVisible, let turn = turns.first(where: { $0.id == turnId }) else { return }
        await audio.speak(Self.spokenText(for: turn.response), pace: .normal)
    }

    static func spokenText(for response: AskResponse) -> String {
        guard let notice = response.safetyNotice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty else {
            return response.answerText
        }
        return "\(notice) \(response.answerText)"
    }

    func drawerDidAppear() { isVisible = true }

    /// The drawer closed: stop any answer being read.
    func drawerDidDisappear() {
        isVisible = false
        audio.stop()
    }
}
