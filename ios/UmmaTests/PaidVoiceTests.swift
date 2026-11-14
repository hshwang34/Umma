import Foundation
import XCTest
@testable import Umma

/// Brief 012 PR 2, Paid transport: gating, the server-clock mapping, barge-in and every
/// fallback path, against a fake socket and fake audio. Real audio and the network need a device.
@MainActor
final class PaidVoiceTests: XCTestCase {
    private var server: FakePaidVoiceServer!
    private var audio: FakePaidVoiceAudio!
    private var free: FakeVoiceTransport!
    private var transport: PaidVoiceTransport!
    private var events: [VoiceTransportEvent] = []

    override func setUp() async throws {
        server = FakePaidVoiceServer()
        audio = FakePaidVoiceAudio()
        free = FakeVoiceTransport(inputLabel: "iPhone mic (on device)")
        transport = PaidVoiceTransport(server: server, audio: audio, fallback: free,
                                       readyTimeout: .seconds(2), keepaliveInterval: .seconds(60))
        events = []
    }

    override func tearDown() async throws {
        transport.stop()
    }

    private func start() async throws {
        try await transport.start { [weak self] event in self?.events.append(event) }
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private var transcripts: [VoiceTransportEvent] {
        events.filter { if case .transcript = $0 { true } else { false } }
    }

    // MARK: - Server path

    func testStartsOnTheServerAndSendsOnlyGatedAudioPlusFinalize() async throws {
        try await start()
        XCTAssertEqual(transport.tier, .paid)
        XCTAssertNil(transport.notice)
        XCTAssertTrue(audio.isRunning)
        XCTAssertFalse(free.isRunning)
        let chunk = Data(repeating: 7, count: 3200)
        audio.emit(.audio(chunk))
        audio.emit(.spanEnded)
        await eventually("audio and finalize") { self.server.socket.sent.count == 2 }
        XCTAssertEqual(server.socket.sentAudio, [chunk])
        XCTAssertEqual(server.socket.sentText, [PaidVoiceServerMessage.finalize])
    }

    func testTranscriptsLandOnTheTransportClock() async throws {
        try await start()
        audio.offsetMs = 4_000  // the span the server heard started 4 s into the session
        server.socket.push(#"{"type":"transcript","text":"next","is_final":false,"speech_final":false,"start_ms":120,"end_ms":400}"#)
        server.socket.push(#"{"type":"transcript","text":"Next step.","is_final":true,"speech_final":true,"start_ms":120,"end_ms":700}"#)
        await eventually("two transcripts") { self.transcripts.count == 2 }
        XCTAssertEqual(transcripts, [
            .transcript(text: "next", isFinal: false, startMs: 4_120, endMs: 4_400),
            .transcript(text: "Next step.", isFinal: true, startMs: 4_120, endMs: 4_700),
        ])
    }

    func testUtteranceEndClosesAnUnconfirmedPartial() async throws {
        try await start()
        server.socket.push(#"{"type":"transcript","text":"two eggs","is_final":false,"start_ms":0,"end_ms":500}"#)
        server.socket.push(#"{"type":"utterance_end","last_word_end_ms":500}"#)
        await eventually("partial promoted") { self.transcripts.count == 2 }
        XCTAssertEqual(transcripts.last, .transcript(text: "two eggs", isFinal: true, startMs: 0, endMs: 500))
    }

    func testFlushDropsEarlierWordsButKeepsASpanStillGoing() async throws {
        try await start()
        audio.audioSentMs = 2_000
        transport.flushHypothesis()
        server.socket.push(#"{"type":"transcript","text":"echo","is_final":true,"start_ms":1500,"end_ms":1900}"#)
        audio.openSpanAudioMs = 2_600  // a barge-in span is open
        transport.flushHypothesis()
        server.socket.push(#"{"type":"transcript","text":"wait","is_final":true,"start_ms":2600,"end_ms":2900}"#)
        await eventually("the barge-in words") { self.transcripts.count == 1 }
        XCTAssertEqual(transcripts, [.transcript(text: "wait", isFinal: true, startMs: 2_600, endMs: 2_900)])
    }

    func testKeepsTheHonestMicLabel() async throws {
        audio.inputLabel = "Bluetooth mic (AirPods)"
        try await start()
        XCTAssertEqual(transport.inputLabel, "Bluetooth mic (AirPods)")
        audio.emit(.inputChanged(label: "iPhone mic"))
        XCTAssertEqual(events.last, .inputChanged(label: "iPhone mic"))
    }

    // MARK: - Server voice and barge-in

    func testSpeaksInTheServerVoice() async throws {
        try await start()
        server.lineChunks = [Data(repeating: 1, count: 4800), Data(repeating: 2, count: 4800)]
        await transport.speak("Cook until 165°F (74°C) inside.")
        XCTAssertEqual(server.spoken, ["Cook until 165°F (74°C) inside."])
        XCTAssertEqual(audio.played.count, 2)
        XCTAssertEqual(audio.lineRates, [24_000])
        XCTAssertTrue(free.spoken.isEmpty)
    }

    func testBargeInCutsTheLineAndCancelsTheStream() async throws {
        try await start()
        server.holdLine = true
        audio.holdsPlayback = true
        let speaking = Task { await transport.speak("Next, fold in the rice gently.") }
        await eventually("first chunk") { self.audio.played.count == 1 }
        XCTAssertTrue(transport.isSpeaking)
        audio.emit(.voiceActivity(true))  // the cook talks over Umma
        await speaking.value
        XCTAssertFalse(transport.isSpeaking)
        XCTAssertGreaterThanOrEqual(audio.flushCount, 1)
        XCTAssertEqual(events.last, .voiceActivity(true))
        await eventually("stream cancelled") { self.server.lineCancelled }
    }

    func testStopSpeakingFlushesAtOnce() async throws {
        try await start()
        server.holdLine = true
        let speaking = Task { await transport.speak("A long line.") }
        await eventually("first chunk") { self.audio.played.count == 1 }
        transport.stopSpeaking()
        await speaking.value
        XCTAssertGreaterThanOrEqual(audio.flushCount, 1)
    }

    // MARK: - Fallback

    func testAIRestingMidSessionFallsBackWithTheReason() async throws {
        try await start()
        server.socket.push(#"{"type":"ai_resting","reason":"user_daily_cap","message":"AI is resting, so voice runs on this iPhone for now."}"#)
        await eventually("fallback running") { self.free.isRunning }
        XCTAssertEqual(transport.tier, .free)
        XCTAssertEqual(transport.notice, "AI is resting, so voice runs on this iPhone for now.")
        XCTAssertEqual(transport.inputLabel, "iPhone mic (on device)")
        XCTAssertTrue(server.socket.isClosed)
        XCTAssertFalse(audio.isRunning)
        await eventually("label update") { self.events.last == .inputChanged(label: "iPhone mic (on device)") }
        free.emit(.transcript(text: "eggs", isFinal: true))
        XCTAssertEqual(events.last, .transcript(text: "eggs", isFinal: true))
        await transport.speak("Got it.")
        XCTAssertEqual(free.spoken, ["Got it."])
    }

    func testFreeEntitlementRefusalAtStartFallsBack() async throws {
        server.sendsReady = false
        server.socket.push(#"{"type":"error","code":"VOICE_NOT_ENTITLED","message":"Server voice is part of Paid. Voice runs on this iPhone."}"#)
        try await start()
        XCTAssertTrue(free.isRunning)
        XCTAssertEqual(transport.tier, .free)
        XCTAssertEqual(transport.notice, "Server voice is part of Paid. Voice runs on this iPhone.")
        XCTAssertFalse(audio.isRunning)
    }

    func testUnreachableServerFallsBackAtStart() async throws {
        server.openError = URLError(.notConnectedToInternet)
        try await start()
        XCTAssertTrue(free.isRunning)
        XCTAssertEqual(transport.notice, PaidVoiceTransport.offlineNotice)
    }

    func testNoReadyInTimeFallsBack() async throws {
        server.sendsReady = false
        transport = PaidVoiceTransport(server: server, audio: audio, fallback: free,
                                       readyTimeout: .milliseconds(50), keepaliveInterval: .seconds(60))
        try await start()
        XCTAssertTrue(free.isRunning)
        XCTAssertEqual(transport.notice, PaidVoiceTransport.offlineNotice)
    }

    func testConnectionDropMidSessionFallsBack() async throws {
        try await start()
        server.socket.fail()
        await eventually("fallback running") { self.free.isRunning }
        XCTAssertEqual(transport.notice, PaidVoiceTransport.offlineNotice)
    }

    func testSpeakFailureFallsBackAndStillSaysTheLine() async throws {
        try await start()
        server.speakError = PaidVoiceError.server(code: "AI_RESTING", message: PaidVoiceTransport.restingNotice)
        await transport.speak("Next, stir.")
        XCTAssertEqual(free.spoken, ["Next, stir."])
        XCTAssertEqual(transport.notice, PaidVoiceTransport.restingNotice)
    }

    func testABareServerErrorOnSpeakFallsBackAndStillSaysTheLine() async throws {
        try await start()
        // A proxy's 502 with no envelope: never a line-only refusal, so the line isn't dropped.
        server.speakError = PaidVoiceError.speakRefusal(status: 502, envelope: nil)
        await transport.speak("Next, stir.")
        XCTAssertEqual(free.spoken, ["Next, stir."])
        XCTAssertEqual(transport.tier, .free)
        XCTAssertEqual(transport.notice, PaidVoiceTransport.offlineNotice)
    }

    func testSessionEndingSpeakRefusals() {
        for status in [500, 502, 503, 504, 401, 403] {
            guard case let .server(code, _) = PaidVoiceError.speakRefusal(status: status, envelope: nil) else {
                return XCTFail("expected a server refusal")
            }
            XCTAssertEqual(code, "HTTP_\(status)")
            XCTAssertTrue(PaidVoiceTransport.endsServerVoice(code: code), code)
        }
        let unknown500 = APIErrorEnvelope.Body(code: "INTERNAL", message: "Oops.", retryable: true,
                                               correlationId: nil, details: nil)
        XCTAssertEqual(PaidVoiceError.speakRefusal(status: 500, envelope: unknown500),
                       .server(code: "HTTP_500", message: "Oops."))
        let unavailable = APIErrorEnvelope.Body(code: "VOICE_UNAVAILABLE", message: "Off.", retryable: false,
                                                correlationId: nil, details: nil)
        XCTAssertEqual(PaidVoiceError.speakRefusal(status: 503, envelope: unavailable),
                       .server(code: "VOICE_UNAVAILABLE", message: "Off."))
        for code in ["VOICE_UNAVAILABLE", "UNAUTHORIZED", "AI_RESTING", "VOICE_NOT_ENTITLED"] {
            XCTAssertTrue(PaidVoiceTransport.endsServerVoice(code: code), code)
        }
        for code in ["RATE_LIMITED", "PAYLOAD_TOO_LARGE", "HTTP_429", "HTTP_413", "HTTP_abc"] {
            XCTAssertFalse(PaidVoiceTransport.endsServerVoice(code: code), code)
        }
    }

    func testAStaleFailingStartLeavesTheNewerRunAlone() async throws {
        server.heldOpenError = URLError(.notConnectedToInternet)
        let first = Task { try await self.start() }
        await eventually("first start waiting on the server") { self.server.isOpenHeld }
        transport.stop()
        try await start()  // the newer run comes up on the server
        XCTAssertTrue(audio.isRunning)
        server.releaseOpen()  // the stale start now fails
        do {
            try await first.value
            XCTFail("a superseded start must throw")
        } catch let error as CaptureError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(audio.isRunning, "the newer run keeps its audio")
        XCTAssertEqual(audio.stopCount, 1, "only the explicit stop() stopped the audio")
        XCTAssertEqual(transport.tier, .paid)
        XCTAssertNil(transport.notice)
        XCTAssertFalse(free.isRunning)
    }

    func testNoFallbackAvailableFailsVisibly() async throws {
        free.isAvailable = false
        server.openError = URLError(.notConnectedToInternet)
        do {
            try await start()
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(PaidVoiceTransport.offlineNotice))
        }
    }

    func testStopSendsStopAndClosesEverything() async throws {
        try await start()
        transport.stop()
        XCTAssertFalse(audio.isRunning)
        await eventually("stop sent, then closed") { self.server.socket.isClosed }
        XCTAssertEqual(server.socket.sentText.last, PaidVoiceServerMessage.stop)
        server.socket.push(#"{"type":"transcript","text":"late","is_final":true,"start_ms":0,"end_ms":10}"#)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(transcripts.isEmpty, "nothing after stop")
    }

    func testPauseGoesToTheAudioOrTheFallback() async throws {
        try await start()
        transport.setInputPaused(true)
        XCTAssertTrue(audio.isPaused)
        server.socket.push(#"{"type":"closed","reason":"max_duration"}"#)
        await eventually("fallback running") { self.free.isRunning }
        await eventually("fallback paused too") { self.free.isInputPaused }
    }

    func testFallbackKeepsAnUnconfirmedPartialAsSaid() async throws {
        try await start()
        audio.offsetMs = 1_000
        server.socket.push(#"{"type":"transcript","text":"and the gar","is_final":false,"start_ms":0,"end_ms":600}"#)
        await eventually("partial") { self.transcripts.count == 1 }
        server.socket.fail()
        await eventually("fallback running") { self.free.isRunning }
        XCTAssertEqual(transcripts.last, .transcript(text: "and the gar", isFinal: true, startMs: 1_000, endMs: 1_600))
    }

    func testALineRefusedOnItsOwnIsSkippedAndPaidStays() async throws {
        try await start()
        for code in ["RATE_LIMITED", "PAYLOAD_TOO_LARGE"] {
            server.speakError = PaidVoiceError.server(code: code, message: "Too many voice lines this minute.")
            await transport.speak("Next.")
        }
        XCTAssertEqual(transport.tier, .paid)
        XCTAssertNil(transport.notice)
        XCTAssertFalse(free.isRunning)
        XCTAssertTrue(free.spoken.isEmpty)
        server.speakError = nil
        await transport.speak("Next, stir.")
        XCTAssertEqual(audio.played.count, 1, "the next line plays in the server voice")
    }
}
