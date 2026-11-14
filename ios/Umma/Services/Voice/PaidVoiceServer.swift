import Foundation
import os

/// Brief 012 PR 2: the backend half of Paid voice. `WS /v1/voice/stream` takes gated 16 kHz
/// PCM and answers with transcripts and turn events; `POST /v1/voice/speak` streams Umma's server
/// voice as PCM. Vendor keys live only on the backend; the phone sends its own sign-in token.
protocol PaidVoiceServer: Sendable {
    func openStream() async throws -> any VoiceSocket
    func speak(_ text: String) async throws -> PaidSpeechAudio
}

/// One message on the voice socket.
enum VoiceSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

protocol VoiceSocket: AnyObject, Sendable {
    func send(_ message: VoiceSocketMessage) async throws
    func receive() async throws -> VoiceSocketMessage
    func close()
}

/// Streamed s16le mono PCM for one line.
struct PaidSpeechAudio: Sendable {
    let sampleRate: Double
    let chunks: AsyncThrowingStream<Data, Error>
}

enum PaidVoiceError: Error, Equatable, LocalizedError {
    /// The server refused: `VOICE_NOT_ENTITLED`, `VOICE_UNAVAILABLE`, `AI_RESTING`, ...
    case server(code: String, message: String)
    case unreachable
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .server(_, let message): message
        case .unreachable: PaidVoiceTransport.offlineNotice
        case .notSignedIn: "Sign in again to use server voice."
        }
    }
}

extension PaidVoiceError {
    /// A non-200 `/speak` answer. A 5xx, 401 or 403 always ends server voice for the session, so
    /// unless its envelope names one of the session refusals it reads as `HTTP_<status>` (a
    /// proxy's bare 502, or a 500 with any other code) and the line is said on-device instead.
    static func speakRefusal(status: Int, envelope: APIErrorEnvelope.Body?) -> PaidVoiceError {
        let message = envelope?.message ?? PaidVoiceTransport.offlineNotice
        if let code = envelope?.code, PaidVoiceTransport.fallbackCodes.contains(code) {
            return .server(code: code, message: message)
        }
        let endsSession = status >= 500 || status == 401 || status == 403
        let code = endsSession ? "HTTP_\(status)" : (envelope?.code ?? "HTTP_\(status)")
        return .server(code: code, message: message)
    }
}

/// What the server says on the voice socket.
enum PaidVoiceServerMessage: Equatable, Sendable {
    case ready
    case transcript(text: String, isFinal: Bool, startMs: Int64, endMs: Int64)
    case speechStarted(atMs: Int64)
    case utteranceEnd(lastWordEndMs: Int64)
    /// Over a budget cap: Paid falls back to Free with this message.
    case aiResting(message: String)
    case error(code: String, message: String)
    case closed(reason: String)

    private struct Wire: Decodable {
        let type: String
        var text: String?
        var isFinal: Bool?
        var startMs: Int64?
        var endMs: Int64?
        var atMs: Int64?
        var lastWordEndMs: Int64?
        var code: String?
        var message: String?
        var reason: String?
    }

    static func parse(_ text: String) -> PaidVoiceServerMessage? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = try? decoder.decode(Wire.self, from: Data(text.utf8)) else { return nil }
        switch wire.type {
        case "ready": return .ready
        case "transcript":
            return .transcript(text: wire.text ?? "", isFinal: wire.isFinal ?? false,
                               startMs: wire.startMs ?? 0, endMs: wire.endMs ?? 0)
        case "speech_started": return .speechStarted(atMs: wire.atMs ?? 0)
        case "utterance_end": return .utteranceEnd(lastWordEndMs: wire.lastWordEndMs ?? 0)
        case "ai_resting": return .aiResting(message: wire.message ?? PaidVoiceTransport.restingNotice)
        case "error": return .error(code: wire.code ?? "ERROR", message: wire.message ?? PaidVoiceTransport.offlineNotice)
        case "closed": return .closed(reason: wire.reason ?? "closed")
        default: return nil
        }
    }

    static let finalize = #"{"type":"finalize"}"#
    static let keepalive = #"{"type":"keepalive"}"#
    static let stop = #"{"type":"stop"}"#
}

/// The real server: the app's base URL and sign-in token, over `URLSession`.
struct HTTPPaidVoiceServer: PaidVoiceServer {
    let baseURL: BaseURLProviding
    let token: TokenProviding
    var session: URLSession = .shared

    func openStream() async throws -> any VoiceSocket {
        URLSessionVoiceSocket(task: session.webSocketTask(with: try streamRequest()))
    }

    func streamRequest() throws -> URLRequest {
        var request = try request(path: "v1/voice/stream", websocket: true)
        request.timeoutInterval = 10
        return request
    }

    func speak(_ text: String) async throws -> PaidSpeechAudio {
        var request = try request(path: "v1/voice/speak", websocket: false)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PaidVoiceError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw PaidVoiceError.unreachable }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes.prefix(4096) { body.append(byte) }
            let envelope = try? JSONCoding.makeDecoder().decode(APIErrorEnvelope.self, from: body)
            throw PaidVoiceError.speakRefusal(status: http.statusCode, envelope: envelope?.error)
        }
        let rate = Double(http.value(forHTTPHeaderField: "X-Audio-Sample-Rate") ?? "") ?? 24_000
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                do {
                    // ~100 ms per chunk at 24 kHz; always an even byte count (16-bit samples).
                    var buffer = Data()
                    buffer.reserveCapacity(4800)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 4800 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if buffer.count > 1 { continuation.yield(buffer.prefix(buffer.count & ~1)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        return PaidSpeechAudio(sampleRate: rate, chunks: chunks)
    }

    private func request(path: String, websocket: Bool) throws -> URLRequest {
        guard let base = baseURL.baseURL,
              var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        else { throw PaidVoiceError.unreachable }
        if websocket {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
        }
        guard let url = components.url else { throw PaidVoiceError.unreachable }
        guard let token = token.currentToken() else { throw PaidVoiceError.notSignedIn }
        var request = URLRequest(url: url)
        // The token goes in a header, never the URL (query strings end up in logs).
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// `URLSessionWebSocketTask` behind `VoiceSocket`.
final class URLSessionVoiceSocket: VoiceSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 1 << 20
        task.resume()
    }

    func send(_ message: VoiceSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> VoiceSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .text("")
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
