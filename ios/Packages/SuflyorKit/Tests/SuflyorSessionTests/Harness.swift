import Foundation
import SuflyorDomain
import SuflyorTestSupport

@testable import SuflyorSession

/// A clock the test moves by hand, so scrolling speed and timeouts don't depend on real time.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    var now: Int64 { lock.withLock { value } }

    func advance(_ millis: Int64) {
        lock.withLock { value += millis }
    }
}

/// Polls until `condition` holds (real time, a few milliseconds apart) or `timeout` passes.
func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// An engine wired to fakes, with a manual clock and no automatic ticking: tests call `tick()` themselves.
struct Harness {
    let clock: ManualClock
    let core: SimpleScriptCore
    let factory: FakeAsrEngineFactory
    let packs: FakeSpeechPackStore
    let audio: FakeAudioSource
    let engine: SessionEngine

    /// 150 words per minute is 0.25 words per 100 ms tick, which is exact in binary floating point.
    static func defaultSettings() -> PrompterSettings {
        var settings = PrompterSettings()
        settings.leadWords = 0
        settings.autoScrollWpm = 150
        settings.countdownSeconds = 3
        return settings
    }

    init(settings: PrompterSettings = Harness.defaultSettings()) {
        let clock = ManualClock()
        let core = SimpleScriptCore()
        let factory = FakeAsrEngineFactory()
        let packs = FakeSpeechPackStore(installed: Set(SpeechLanguage.allCases))
        self.clock = clock
        self.core = core
        self.factory = factory
        self.packs = packs
        self.audio = FakeAudioSource()
        self.engine = SessionEngine(
            core: core,
            engines: factory,
            packs: packs,
            settings: settings,
            clock: { clock.now },
            autoTick: false
        )
    }

    static let tenWords = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"

    func script(
        _ text: String = Harness.tenWords,
        language: SpeechLanguage = .en,
        phraseMode: Bool = false,
        maxWords: Int = 7
    ) -> PreparedScript {
        core.prepare(
            title: "test",
            paragraphs: [ScriptParagraph(text: text)],
            language: language,
            phraseMode: phraseMode,
            maxWords: maxWords
        )
    }

    /// Starts with the fake microphone and waits until the session listens; returns the recognizer that was loaded.
    @discardableResult
    func startListening(script: PreparedScript? = nil, mode: SessionMode = .rehearsal) async -> FakeAsrEngine? {
        await engine.setScript(script ?? self.script())
        await engine.start(mode: mode, audio: audio)
        _ = await waitUntil { await engine.state.listening }
        return factory.engines.last
    }

    func waitForChunks(_ count: Int) async -> Bool {
        await waitUntil { await engine.processedChunks >= count }
    }
}
