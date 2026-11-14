import Foundation
import XCTest
@testable import Umma

/// Brief 012 PR 2, Paid voice layer: the speech gate, the server's wire messages and the
/// stream request. No hardware or network.
final class PaidVoiceLayerTests: XCTestCase {
    // MARK: - Gate

    private func frame(_ ms: Int) -> Data { Data(repeating: 0, count: ms * PaidSpeechGate.bytesPerMs) }

    func testGateSendsOnlySpeechWithPreRollBatchedAndFinalizes() {
        var gate = PaidSpeechGate()
        var outputs: [PaidSpeechGate.Output] = []
        var activity: [Bool] = []
        func feed(_ levelDb: Float, from start: Int64, to end: Int64) {
            var t = start
            while t < end {
                let (change, out) = gate.process(frame(20), levelDb: levelDb, atMs: t)
                if let change { activity.append(change) }
                outputs += out
                t += 20
            }
        }
        feed(-70, from: 0, to: 1_000)  // quiet: nothing leaves the phone
        XCTAssertTrue(outputs.isEmpty)
        feed(-20, from: 1_000, to: 2_000)  // speech
        feed(-70, from: 2_000, to: 3_000)  // quiet again
        XCTAssertEqual(activity, [true, false])
        XCTAssertEqual(outputs.last, .spanEnded)
        let audio = outputs.compactMap { if case .audio(let d) = $0 { d } else { nil } }
        XCTAssertTrue(audio.dropLast().allSatisfy { $0.count == 3_200 }, "100 ms batches")
        let sentMs = audio.reduce(0) { $0 + $1.count } / PaidSpeechGate.bytesPerMs
        // Pre-roll (≤ 320 ms) + 1 s of speech + the release tail; never the long silences.
        XCTAssertGreaterThan(sentMs, 1_200)
        XCTAssertLessThan(sentMs, 1_800)
        XCTAssertEqual(gate.audioSentMs, Int64(sentMs))
        XCTAssertFalse(gate.isOpen)
    }

    func testConfigurationChangeNeverRestartsAPausedOrInterruptedMic() {
        typealias Audio = EnginePaidVoiceAudio
        XCTAssertTrue(Audio.restartsOnConfigurationChange(isRunning: true, isInputPaused: false, isInterrupted: false))
        XCTAssertFalse(Audio.restartsOnConfigurationChange(isRunning: true, isInputPaused: true, isInterrupted: false))
        XCTAssertFalse(Audio.restartsOnConfigurationChange(isRunning: true, isInputPaused: false, isInterrupted: true))
        XCTAssertFalse(Audio.restartsOnConfigurationChange(isRunning: false, isInputPaused: false, isInterrupted: false))
    }

    func testGateMapsTheServerClockAcrossSpans() {
        var gate = PaidSpeechGate()
        func feed(_ levelDb: Float, from start: Int64, to end: Int64) {
            var t = start
            while t < end { _ = gate.process(frame(20), levelDb: levelDb, atMs: t); t += 20 }
        }
        feed(-70, from: 0, to: 1_000)
        feed(-20, from: 1_000, to: 1_600)
        feed(-70, from: 1_600, to: 5_000)
        let firstSpanMs = gate.audioSentMs
        feed(-20, from: 5_000, to: 5_600)
        // Audio 0 is where span one's pre-roll starts (~0.7 s); span two starts after it.
        let spanOneStart = gate.transportMs(forAudioMs: 0)
        XCTAssertGreaterThanOrEqual(spanOneStart, 700)
        XCTAssertLessThan(spanOneStart, 1_000)
        let spanTwoStart = gate.transportMs(forAudioMs: firstSpanMs)
        XCTAssertGreaterThanOrEqual(spanTwoStart, 4_700)
        XCTAssertLessThan(spanTwoStart, 5_000)
        XCTAssertEqual(gate.transportMs(forAudioMs: firstSpanMs + 250), spanTwoStart + 250)
        XCTAssertEqual(gate.spanStartAudioMs, firstSpanMs)
    }

    func testGateCloseFlushesAndFinalizes() {
        var gate = PaidSpeechGate()
        var t: Int64 = 0
        var outputs: [PaidSpeechGate.Output] = []
        while t < 400 { outputs += gate.process(frame(20), levelDb: -20, atMs: t).outputs; t += 20 }
        XCTAssertTrue(gate.isOpen)
        outputs += gate.close()
        XCTAssertEqual(outputs.last, .spanEnded)
        XCTAssertNil(gate.spanStartAudioMs)
    }

    // MARK: - Wire

    func testParsesServerMessages() {
        XCTAssertEqual(PaidVoiceServerMessage.parse(#"{"type":"ready","sample_rate":16000}"#), .ready)
        XCTAssertEqual(PaidVoiceServerMessage.parse(#"{"type":"speech_started","at_ms":40}"#), .speechStarted(atMs: 40))
        XCTAssertEqual(PaidVoiceServerMessage.parse(#"{"type":"closed","reason":"idle"}"#), .closed(reason: "idle"))
        XCTAssertEqual(PaidVoiceServerMessage.parse(#"{"type":"ai_resting","reason":"monthly_cap","message":"m"}"#),
                       .aiResting(message: "m"))
        XCTAssertNil(PaidVoiceServerMessage.parse("not json"))
        XCTAssertNil(PaidVoiceServerMessage.parse(#"{"type":"something_new"}"#))
    }

    func testRequestsCarryTheTokenInAHeaderOverWebSocketSchemes() throws {
        struct Base: BaseURLProviding {
            var baseURL: URL? { URL(string: "https://api.example.com") }
            var baseURLString: String { "https://api.example.com" }
        }
        struct Token: TokenProviding { func currentToken() -> String? { "tok" } }
        struct NoToken: TokenProviding { func currentToken() -> String? { nil } }
        let request = try HTTPPaidVoiceServer(baseURL: Base(), token: Token()).streamRequest()
        XCTAssertEqual(request.url?.absoluteString, "wss://api.example.com/v1/voice/stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        do {
            _ = try HTTPPaidVoiceServer(baseURL: Base(), token: NoToken()).streamRequest()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? PaidVoiceError, .notSignedIn)
        }
    }
}
