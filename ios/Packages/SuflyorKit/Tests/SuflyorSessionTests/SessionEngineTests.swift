import Dispatch
import Foundation
import SuflyorDomain
import SuflyorTestSupport
import Testing

@testable import SuflyorSession

@Suite struct VoiceFollowingTests {
    @Test func recognizedWordsUpdateTheState() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())
        asr.enqueue(AsrUpdate(text: "alpha bravo", isFinal: false))
        h.audio.sendChunk(db: -30)
        #expect(await h.waitForChunks(1))

        let state = await h.engine.state
        #expect(state.position == 2)
        #expect(state.nextToken == 2)
        #expect(state.total == 10)
        #expect(state.partial == "alpha bravo")
        #expect(state.levelDb == -30)

        // The utterance ends: the text moves to lastFinal and the partial clears.
        asr.enqueue(AsrUpdate(text: "alpha bravo charlie", isFinal: true))
        h.audio.sendChunk(db: -30)
        #expect(await h.waitForChunks(2))
        let after = await h.engine.state
        #expect(after.position == 3)
        #expect(after.partial == "")
        #expect(after.lastFinal == "alpha bravo charlie")
    }

    @Test func theRecognizerGetsTheScriptsWords() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())
        #expect(asr.hotwords.contains("charlie"))
        #expect(asr.biasWords.contains("juliet"))
    }

    @Test func pauseStopsFollowingAndResumeContinues() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())
        asr.enqueue(AsrUpdate(text: "alpha bravo", isFinal: false))
        h.audio.sendChunk()
        #expect(await h.waitForChunks(1))

        await h.engine.togglePause()
        let pausedAt = asr.acceptCount
        asr.enqueue(AsrUpdate(text: "charlie delta", isFinal: false))
        h.audio.sendChunk()
        #expect(await h.waitForChunks(2))
        #expect(asr.acceptCount == pausedAt) // not even fed while paused
        let paused = await h.engine.state
        #expect(paused.paused)
        #expect(paused.position == 2)

        await h.engine.togglePause()
        h.audio.sendChunk()
        #expect(await h.waitForChunks(3))
        let resumed = await h.engine.state
        #expect(!resumed.paused)
        #expect(resumed.position == 4)
    }

    @Test func manualStepsMoveByLines() async throws {
        let h = Harness()
        let script = h.script("alpha bravo charlie delta echo foxtrot", phraseMode: true, maxWords: 3)
        _ = await h.startListening(script: script)

        await h.engine.perform(.forward)
        #expect(await h.engine.state.position == 3)
        await h.engine.stepLine(-1) // back to the start of the previous line
        #expect(await h.engine.state.position == 0)
        await h.engine.jump(toToken: 4)
        #expect(await h.engine.state.position == 4)
        await h.engine.restart()
        #expect(await h.engine.state.position == 0)
    }

    @Test func aManualMoveDropsStaleResults() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())

        // The recognizer is "decoding" this chunk when the reader taps another place in the text.
        let gate = DispatchSemaphore(value: 0)
        asr.handler = { _, _ in
            gate.wait()
            return AsrUpdate(text: "alpha bravo", isFinal: false)
        }
        h.audio.sendChunk()
        #expect(await waitUntil { asr.acceptCount >= 1 })
        let resetsBefore = asr.resetCount

        await h.engine.jump(toToken: 4)
        gate.signal()
        #expect(await h.waitForChunks(1))

        let state = await h.engine.state
        #expect(state.position == 4) // "alpha bravo" would have moved it back to 2
        #expect(state.nextToken == 4)
        #expect(state.partial == "")
        #expect(asr.resetCount > resetsBefore) // the move reset the recognizer

        // Results that start after the move are applied again.
        asr.handler = nil
        asr.enqueue(AsrUpdate(text: "echo foxtrot", isFinal: false))
        h.audio.sendChunk()
        #expect(await h.waitForChunks(2))
        #expect(await h.engine.state.position == 6)
    }

    @Test func aNewScriptDropsStaleResultsToo() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())
        let gate = DispatchSemaphore(value: 0)
        asr.handler = { _, _ in
            gate.wait()
            return AsrUpdate(text: "alpha bravo", isFinal: false)
        }
        h.audio.sendChunk()
        #expect(await waitUntil { asr.acceptCount >= 1 })

        await h.engine.setScript(h.script("zulu yankee xray whiskey"))
        gate.signal()
        #expect(await h.waitForChunks(1))
        let state = await h.engine.state
        #expect(state.position == 0)
        #expect(state.total == 4)
        #expect(state.partial == "")
    }
}

@Suite struct TimedScrollingTests {
    private func startWithoutMicrophone(_ h: Harness, scroll: ScrollMode = .auto, script: PreparedScript? = nil) async {
        await h.engine.setScript(script ?? h.script())
        await h.engine.setScroll(scroll)
        await h.engine.start(mode: .rehearsal, audio: nil)
        _ = await waitUntil { await h.engine.state.listening }
    }

    @Test func countdownRunsBeforeTheTextMoves() async {
        let h = Harness()
        await startWithoutMicrophone(h)
        #expect(await h.engine.state.countdown == 3)

        h.clock.advance(1000)
        await h.engine.tick()
        #expect(await h.engine.state.countdown == 2)
        h.clock.advance(1000)
        await h.engine.tick()
        #expect(await h.engine.state.countdown == 1)
        #expect(await h.engine.state.position == 0) // still counting

        h.clock.advance(1000)
        await h.engine.tick()
        let state = await h.engine.state
        #expect(state.countdown == 0)
        #expect(state.position > 0) // the countdown is over: the text moves
    }

    @Test func noCountdownWhenSetToZero() async {
        var settings = Harness.defaultSettings()
        settings.countdownSeconds = 0
        let h = Harness(settings: settings)
        await startWithoutMicrophone(h)
        #expect(await h.engine.state.countdown == 0)
    }

    @Test func speedFollowsWordsPerMinute() async {
        var settings = Harness.defaultSettings()
        settings.countdownSeconds = 0
        let h = Harness(settings: settings)
        await startWithoutMicrophone(h)

        // 150 wpm = 2.5 words per second = 0.25 per tick: one word every 4 ticks.
        for tick in 1...8 {
            h.clock.advance(100)
            await h.engine.tick()
            let expected = tick / 4
            #expect(await h.engine.state.position == expected, "after \(tick) ticks")
        }
        let state = await h.engine.state
        #expect(state.nextToken == 2)

        // A long gap moves several words at once and carries the fraction.
        h.clock.advance(2000) // 5 words
        await h.engine.tick()
        #expect(await h.engine.state.position == 7)
    }

    @Test func stopsAtTheEndOfTheScript() async {
        var settings = Harness.defaultSettings()
        settings.countdownSeconds = 0
        let h = Harness(settings: settings)
        await startWithoutMicrophone(h)
        h.clock.advance(60_000)
        await h.engine.tick()
        let state = await h.engine.state
        #expect(state.position == 10)
        #expect(state.nextToken == h.script().tokens.count)
    }

    @Test func chineseAndKoreanMoveByCharacters() async {
        var settings = Harness.defaultSettings()
        settings.countdownSeconds = 0
        settings.autoScrollWpm = 120
        let h = Harness(settings: settings)
        let script = h.script("a b c d e f g h i j", language: .zh)
        await startWithoutMicrophone(h, script: script)
        h.clock.advance(1000) // 2 words per second x 1.7 characters per word = 3.4: three steps, 0.4 carried
        await h.engine.tick()
        #expect(await h.engine.state.position == 3)
    }

    @Test func pausedTextDoesNotMove() async {
        var settings = Harness.defaultSettings()
        settings.countdownSeconds = 0
        let h = Harness(settings: settings)
        await startWithoutMicrophone(h)
        await h.engine.togglePause()
        h.clock.advance(5000)
        await h.engine.tick()
        #expect(await h.engine.state.position == 0)
    }

    @Test func withoutAMicrophoneTheModeBecomesTimed() async {
        let h = Harness()
        await startWithoutMicrophone(h, scroll: .voice)
        #expect(await h.engine.state.scroll == .auto)
        #expect(h.factory.requests.isEmpty) // no recognizer is loaded for a session nobody listens to
    }
}

@Suite struct SoundModeTests {
    @Test func theTextWaitsOnSilenceAndMovesWhileSomebodyTalks() async throws {
        let h = Harness()
        await h.engine.setScroll(.sound)
        _ = await h.startListening()

        // A quiet room: the background level is learned and nothing counts as a voice.
        for _ in 0..<3 {
            h.clock.advance(100)
            h.audio.sendChunk(db: -60)
        }
        #expect(await h.waitForChunks(3))
        await h.engine.tick()
        #expect(await h.engine.state.position == 0)
        #expect(await h.engine.state.autoFallback == false)

        // A voice, 10 dB or more above the background.
        h.clock.advance(100)
        h.audio.sendChunk(db: -20)
        #expect(await h.waitForChunks(4))
        h.clock.advance(400) // still within the 600 ms hold
        await h.engine.tick()
        #expect(await h.engine.state.position == 1)

        // Nobody talks any more: the hold runs out and the text stops.
        h.clock.advance(2000)
        await h.engine.tick()
        h.clock.advance(1000)
        await h.engine.tick()
        #expect(await h.engine.state.position == 1)
    }

    @Test func soundModeDoesNotFeedTheRecognizer() async throws {
        let h = Harness()
        await h.engine.setScroll(.sound)
        let asr = try #require(await h.startListening())
        h.audio.sendChunk(db: -20)
        #expect(await h.waitForChunks(1))
        #expect(asr.acceptCount == 0)
    }
}

@Suite struct FallbackTests {
    @Test func twoSecondsOfDigitalSilenceMoveTheTextOnTheTimer() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())

        h.audio.sendChunk(digitalSilence: true)
        #expect(await h.waitForChunks(1))
        #expect(await h.engine.state.autoFallback == false) // a short gap is not enough

        h.clock.advance(1500)
        h.audio.sendChunk(digitalSilence: true)
        #expect(await h.waitForChunks(2))
        #expect(await h.engine.state.autoFallback == false)
        let fedBefore = asr.acceptCount

        h.clock.advance(1000) // 2.5 s of zeros in a row
        h.audio.sendChunk(digitalSilence: true)
        #expect(await h.waitForChunks(3))
        var state = await h.engine.state
        #expect(state.autoFallback)
        #expect(state.digitalSilence)
        #expect(asr.acceptCount == fedBefore) // zeros longer than 1 s are not decoded

        // The timer moves the text meanwhile (the countdown only belongs to the timed mode, not to the fallback).
        h.clock.advance(1000)
        await h.engine.tick()
        state = await h.engine.state
        #expect(state.position > 0)
        #expect(state.scroll == .voice) // the chosen mode stays

        // Sound is back: the fallback ends and voice following resumes.
        h.audio.sendChunk(db: -30)
        #expect(await h.waitForChunks(4))
        state = await h.engine.state
        #expect(!state.autoFallback)
        #expect(!state.digitalSilence)
    }

    @Test func anInterruptionMovesTheTextOnTheTimerUntilItEnds() async throws {
        let h = Harness()
        _ = await h.startListening()

        h.audio.send(.interrupted)
        #expect(await waitUntil { await h.engine.state.interrupted })
        var state = await h.engine.state
        #expect(state.autoFallback)

        h.clock.advance(1000)
        await h.engine.tick()
        #expect(await h.engine.state.position > 0)

        h.audio.send(.resumed)
        #expect(await waitUntil { await !h.engine.state.interrupted })
        state = await h.engine.state
        #expect(!state.autoFallback)
    }

    @Test func aFailedMicrophoneKeepsTheTimerGoing() async throws {
        let h = Harness()
        _ = await h.startListening()
        h.audio.send(.failed(.interruptedForGood))
        #expect(await waitUntil { await h.engine.state.micFailed })

        let state = await h.engine.state
        #expect(state.error == .capture(.interruptedForGood))
        #expect(state.scroll == .voice)
        h.clock.advance(1000)
        await h.engine.tick()
        #expect(await h.engine.state.position > 0)
    }

    @Test func aMicrophoneThatCantStartLeavesTheSessionIdle() async {
        let h = Harness()
        h.audio.failOnStart = .permissionDenied
        await h.engine.setScript(h.script())
        await h.engine.start(mode: .rehearsal, audio: h.audio)
        #expect(await waitUntil { await h.engine.state.error != nil })
        let state = await h.engine.state
        #expect(state.mode == .idle)
        #expect(!state.starting)
        #expect(!state.listening)
        #expect(state.error == .capture(.permissionDenied))
    }
}

@Suite struct RecognizerLifecycleTests {
    @Test func aLanguageChangeReloadsTheRecognizer() async throws {
        let h = Harness()
        let first = try #require(await h.startListening(script: h.script(language: .en)))
        #expect(h.factory.requests.map(\.language) == [.en])

        await h.engine.setScript(h.script("um dois tres quatro", language: .pt))
        let reloaded = await waitUntil {
            let loading = await h.engine.state.loadingModel
            return h.factory.requests.count == 2 && first.isReleased && !loading
        }
        #expect(reloaded)
        #expect(h.factory.requests.map(\.language) == [.en, .pt])
        #expect(h.factory.engines.last?.language == .pt)
        // The new recognizer got the new script's words, not the old ones.
        #expect(h.factory.engines.last?.hotwords.contains("quatro") == true)
        #expect(h.factory.engines.last?.hotwords.contains("charlie") == false)
    }

    @Test func theSameLanguageKeepsTheRecognizer() async throws {
        let h = Harness()
        let first = try #require(await h.startListening())
        await h.engine.setScript(h.script("one two three four five"))
        #expect(h.factory.requests.count == 1)
        #expect(!first.isReleased)
        #expect(first.hotwords.contains("three"))
    }

    @Test func turningHotwordsOffReloadsTheRecognizer() async throws {
        let h = Harness()
        let first = try #require(await h.startListening())
        var settings = Harness.defaultSettings()
        settings.useHotwords = false
        await h.engine.updateSettings(settings)
        let reloaded = await waitUntil { h.factory.requests.count == 2 && first.isReleased }
        #expect(reloaded)
        #expect(h.factory.requests.last?.hotwords == false)
    }

    @Test func aMissingPackIsReportedAndTheSessionStillRuns() async throws {
        let h = Harness()
        h.factory.fail(.pt, with: .packMissing(.pt))
        _ = await h.startListening(script: h.script("um dois tres", language: .pt))
        let state = await h.engine.state
        #expect(state.listening)
        #expect(state.error == .packMissing(.pt))
        #expect(state.loadingModel == false)
    }

    @Test func aPackThatIsNotInstalledNeverReachesTheFactory() async throws {
        let h = Harness()
        h.packs.setInstalled(.pt, false)
        _ = await h.startListening(script: h.script("um dois tres", language: .pt))
        let state = await h.engine.state
        #expect(state.listening)
        #expect(state.error == .packMissing(.pt))
        #expect(h.factory.requests.isEmpty)

        // Installed later: the next script loads the model.
        h.packs.setInstalled(.pt, true)
        await h.engine.setScript(h.script("quatro cinco seis", language: .pt))
        let loaded = await waitUntil {
            let now = await h.engine.state
            return now.error == nil && !now.loadingModel && h.factory.engines.count == 1
        }
        #expect(loaded)
    }

    @Test func installingThePackLaterIsPickedUpByTheNextScript() async throws {
        let h = Harness()
        h.factory.fail(.pt, with: .packMissing(.pt))
        _ = await h.startListening(script: h.script("um dois tres", language: .pt))
        h.factory.fail(.pt, with: nil)
        await h.engine.setScript(h.script("quatro cinco seis", language: .pt))
        let loaded = await waitUntil {
            let state = await h.engine.state
            return state.error == nil && !state.loadingModel && h.factory.engines.count == 1
        }
        #expect(loaded)
    }

    @Test func aSlowLoadKeepsTheSessionInStartingUntilItIsDone() async throws {
        let h = Harness()
        h.factory.delay = .milliseconds(150)
        await h.engine.setScript(h.script())
        await h.engine.start(mode: .rehearsal, audio: h.audio)
        let early = await h.engine.state
        #expect(early.starting)
        #expect(!early.listening)
        #expect(await waitUntil { await h.engine.state.listening })
        #expect(await h.engine.state.starting == false)
    }

    @Test func stopEndsTheSessionAndStopsTheMicrophone() async throws {
        let h = Harness()
        _ = await h.startListening()
        await h.engine.stop()
        let state = await h.engine.state
        #expect(state.mode == .idle)
        #expect(!state.listening)
        #expect(h.audio.stopCount >= 1)
    }

    @Test func releasingTheIdleRecognizerFreesIt() async throws {
        let h = Harness()
        let asr = try #require(await h.startListening())
        await h.engine.stop()
        await h.engine.releaseIdleRecognizer(reason: "test")
        #expect(await waitUntil { asr.isReleased })
    }

    @Test func updatesStartWithTheCurrentState() async {
        let h = Harness()
        await h.engine.setScript(h.script())
        var iterator = await h.engine.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.total == 10)
    }
}

@Suite struct StateMessagesTests {
    @Test func everyErrorHasAMessage() {
        let errors: [SessionError] = [
            .asrLoadFailed("boom"), .packMissing(.pt), .capture(.permissionDenied), .capture(.interruptedForGood),
            .capture(.sessionActivationFailed("x")), .capture(.startFailed("y")), .capture(.formatUnsupported(sampleRate: 44100)),
        ]
        for error in errors { #expect(!error.localizedMessage.isEmpty) }
    }
}
