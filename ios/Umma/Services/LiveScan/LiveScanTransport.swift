import Foundation

/// `POST /v1/ai/live-token` (brief 016 PR 2). A single-use Gemini Live token locked on the server
/// to the model, instructions and `add_item` tool. The phone never holds a provider key.
struct LiveScanToken: Sendable, Equatable {
    /// `auth_tokens/...`. Secret: never log it (`description` redacts it).
    let token: String
    let model: String
    let expiresAt: Date
    /// The session must open before this.
    let newSessionExpiresAt: Date
    let maxSessionSeconds: Int
    let nudgeText: String
    let nudgeEveryFrames: Int
    let frameMaxFps: Double
    /// Mock provider or over a cap: replay the demo script, never auto-save.
    let demo: Bool
}

extension LiveScanToken: Decodable {
    private enum CodingKeys: String, CodingKey {
        case token, model, expiresAt, newSessionExpiresAt, maxSessionSeconds, nudgeText, nudgeEveryFrames, frameMaxFps, demo
    }

    /// A demo answer carries `null` for the token and both expiries; a real one must have all three.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let demo = try values.decode(Bool.self, forKey: .demo)
        let token = try values.decodeIfPresent(String.self, forKey: .token)
        let expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        let newSessionExpiresAt = try values.decodeIfPresent(Date.self, forKey: .newSessionExpiresAt)
        if !demo, token == nil || expiresAt == nil || newSessionExpiresAt == nil {
            throw DecodingError.dataCorruptedError(forKey: .token, in: values,
                                                   debugDescription: "A live token without a token or expiry.")
        }
        self.init(token: token ?? "", model: try values.decode(String.self, forKey: .model),
                  expiresAt: expiresAt ?? .distantPast, newSessionExpiresAt: newSessionExpiresAt ?? .distantPast,
                  maxSessionSeconds: try values.decode(Int.self, forKey: .maxSessionSeconds),
                  nudgeText: try values.decode(String.self, forKey: .nudgeText),
                  nudgeEveryFrames: try values.decode(Int.self, forKey: .nudgeEveryFrames),
                  frameMaxFps: try values.decode(Double.self, forKey: .frameMaxFps), demo: demo)
    }
}

extension LiveScanToken: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "LiveScanToken(model: \(model), demo: \(demo), token: <redacted>)" }
    var debugDescription: String { description }
}

enum LiveScanConfidence: String, Sendable, Equatable {
    case high, medium, low, unknown

    init(raw: String?) {
        self = raw.flatMap { LiveScanConfidence(rawValue: $0.lowercased()) } ?? .unknown
    }
}

enum LiveScanCloseReason: Sendable, Equatable {
    /// `maxSessionSeconds` reached; the caller rotates to a fresh token and session.
    case sessionLimit
    /// `close()` was called.
    case client
    /// The server closed the socket.
    case server(code: Int, reason: String?)
    /// The connection dropped without a close frame.
    case connectionLost
}

enum LiveScanError: Error, Sendable, Equatable {
    case alreadyConnected
    case tokenExpired
    case invalidModel
    case setupFailed(String)
}

enum LiveScanEvent: Sendable, Equatable {
    /// One `add_item` tool call. Answer it with `respond(callID:...)`.
    case itemReported(callID: String, name: String, kind: String?, confidence: LiveScanConfidence)
    /// The server will close soon; rotate.
    case goAway
    /// Always the last event of a session.
    case closed(LiveScanCloseReason)
    case error(String)
}

/// One Live scan session. Make a new transport per session (rotation = close, mint, connect).
///
/// - `connect` returns once the server confirmed setup. Throws on an expired token or failed setup.
/// - `send(frame:)` drops frames over `frameMaxFps`; a text nudge follows every `nudgeEveryFrames`th
///   sent frame. Frames are sent and forgotten, never stored.
/// - `events` finishes after `.closed`.
@MainActor
protocol LiveScanTransport: AnyObject {
    var events: AsyncStream<LiveScanEvent> { get }
    func connect(token: LiveScanToken) async throws
    func send(frame jpeg: Data)
    func respond(callID: String, name: String, status: String, canonical: String?)
    func close()
}

enum LiveScanTransports {
    /// `demo` tokens never reach Gemini: they replay the scripted demo items.
    @MainActor
    static func make(for token: LiveScanToken) -> any LiveScanTransport {
        token.demo ? FakeLiveScanTransport(script: FakeLiveScanTransport.demoScript) : GeminiLiveTransport()
    }
}

protocol LiveScanService: Sendable {
    /// Reserves the scan's worst-case cost, then mints the token. Over a spend cap the answer is a
    /// `demo` token; over the hourly token limit it is a 429. `alreadyInBasket` names what earlier
    /// sessions of this scan reported, so a rotated session doesn't report them again.
    func liveScanToken(alreadyInBasket: [String]) async throws -> LiveScanToken
}

extension LiveScanService {
    func liveScanToken() async throws -> LiveScanToken {
        try await liveScanToken(alreadyInBasket: [])
    }
}

extension APIClient: LiveScanService {
    func liveScanToken(alreadyInBasket: [String]) async throws -> LiveScanToken {
        // Server limits: 100 names of at most 60 characters (422 beyond them).
        let names = alreadyInBasket.prefix(100).map { String($0.prefix(60)) }
        return try await send(.post("/v1/ai/live-token", body: try encoder.encode(LiveTokenRequest(alreadyInBasket: names))))
    }
}

private struct LiveTokenRequest: Encodable {
    let alreadyInBasket: [String]
}
