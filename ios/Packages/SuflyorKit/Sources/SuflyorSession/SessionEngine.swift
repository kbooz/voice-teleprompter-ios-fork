import Foundation
import SuflyorDomain

/// Microphone → recognizer → follower pipeline plus timed and sound-driven scrolling (port of Android's
/// `SessionEngine`). One session at a time.
///
/// Threading: the actor owns all state. Recognizer decoding runs off the actor (a detached task), so a manual move can
/// happen while a chunk is being decoded; the `epoch` then marks that result as stale and it is dropped, exactly as on
/// Android, where decoding ran on the capture thread.
public actor SessionEngine {
    // MARK: - Tuning (same values as Android)

    /// Sound mode: text keeps moving this long after the last loud chunk, so short gaps between words don't stop it.
    static let soundHoldMillis: Int64 = 600
    /// A talking voice is this much louder than the background (and louder than `voiceMinDb`).
    static let voiceMarginDb: Float = 10
    static let voiceMinDb: Float = -50
    /// The background level falls this many dB per chunk and rises slowly.
    static let floorFallDb: Float = 3
    /// Zero audio shorter than this still goes to the recognizer (a noise gate, a short mute).
    static let zeroFeedMillis: Int64 = 1000
    /// Digital silence (or an interruption) longer than this moves the text on the timer instead.
    static let silenceFallbackMillis: Int64 = 2000
    static let statLogMillis: Int64 = 5000
    /// The model stays loaded for a quick next take, then frees its memory.
    static let unloadAfter: Duration = .seconds(150)

    // MARK: - Collaborators

    private let core: any ScriptCoreProviding
    private let engines: any AsrEngineFactory
    private let packs: any SpeechPackManaging
    private var settings: PrompterSettings
    private let clock: @Sendable () -> Int64
    private let autoTick: Bool
    private let journal = Journal.shared

    // MARK: - State

    public private(set) var state = SessionState()
    private var subscribers: [Int: AsyncStream<SessionState>.Continuation] = [:]
    private var nextSubscriber = 0

    private var script: PreparedScript?
    private var follower: (any ScriptFollowing)?
    /// Token index of each spoken word, to turn a word position into a token for `jump(toToken:)`.
    private var spokenTokenIndex: [Int] = []
    private var language: SpeechLanguage = .ru

    private var asr: (any AsrEngine)?
    private var asrKind: AsrEngineKind?
    /// Bumped on every manual move / new script: recognizer results from before it are stale and dropped.
    private var epoch = 0
    /// Identifies the current start(): a load or a microphone start finishing for an older one does nothing.
    private var sessionToken = 0

    private var audio: (any AudioSource)?
    private var hasAudio = false
    private var startTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    /// Recognizer loads run one after another (Android: `asrLoadLock`).
    private var loadChain: Task<SessionError?, Never>?

    // Audio statistics for the periodic journal line.
    private var statFrames = 0
    private var statZeroFrames = 0
    private var statDbSum = 0.0
    private var statDbMax: Float = -120
    private var statWords = 0
    private var lastStatLog: Int64 = 0

    private var zeroSince: Int64?
    /// The recognizer got the last chunk (it is skipped while paused, timed or on long digital silence).
    private var feeding = false
    /// Sound mode: slowly adapting background level and when a louder chunk (a voice) was last heard.
    private var noiseFloorDb: Float?
    private var lastVoiceAt: Int64?

    private var autoCarry = 0.0
    private var lastTick: Int64 = 0
    private var countdownEndsAt: Int64?

    /// Chunks fully handled so far (tests wait on it).
    package private(set) var processedChunks = 0

    // MARK: - Init

    public convenience init(core: any ScriptCoreProviding, engines: any AsrEngineFactory, packs: any SpeechPackManaging, settings: PrompterSettings) {
        self.init(
            core: core,
            engines: engines,
            packs: packs,
            settings: settings,
            clock: { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
            autoTick: true
        )
    }

    /// Tests inject a clock and drive `tick()` themselves.
    package init(
        core: any ScriptCoreProviding,
        engines: any AsrEngineFactory,
        packs: any SpeechPackManaging,
        settings: PrompterSettings,
        clock: @escaping @Sendable () -> Int64,
        autoTick: Bool
    ) {
        self.core = core
        self.engines = engines
        self.packs = packs
        self.settings = settings
        self.clock = clock
        self.autoTick = autoTick
    }

    // MARK: - Updates

    /// A new stream per subscriber; yields the current state first.
    public func updates() -> AsyncStream<SessionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionState.self, bufferingPolicy: .bufferingNewest(8))
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeSubscriber(_ id: Int) {
        subscribers[id] = nil
    }

    private func mutate(_ change: (inout SessionState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        for continuation in subscribers.values { continuation.yield(next) }
    }

    // MARK: - Script

    public func setScript(_ script: PreparedScript) {
        // Reset first, then bump the epoch: a result decoded before the reset carries the old epoch and is dropped.
        asr?.reset()
        epoch += 1
        self.script = script
        language = script.language
        let newFollower = core.makeFollower(for: script)
        follower = newFollower
        spokenTokenIndex = script.tokens.indices.filter { script.tokens[$0].spoken }
        autoCarry = 0

        // A script in the other language needs the other model; the audio task sees no recognizer meanwhile.
        var stale: (any AsrEngine)?
        if let current = asr, current.language != script.language {
            stale = current
            asr = nil
            asrKind = nil
        }
        // Also load when a running session has no recognizer at all (an earlier load failed or the pack was missing).
        if stale != nil || (asr == nil && hasAudio && state.mode != .idle && !state.starting) {
            swapRecognizer(old: stale)
        } else {
            asr?.setBias(hotwords: script.hotwords, biasWords: script.biasWords)
        }
        mutate {
            $0.nextToken = newFollower.nextToken
            $0.position = newFollower.position
            $0.total = newFollower.size
            $0.partial = ""
            $0.lastFinal = ""
        }
    }

    public func updateSettings(_ new: PrompterSettings) {
        let old = settings
        settings = new
        // The model has to be created again to apply either of these.
        if old.useHotwords != new.useHotwords || old.asrEngine != new.asrEngine {
            recognizerSettingChanged()
        }
    }

    private func recognizerSettingChanged() {
        if state.mode == .idle {
            releaseIdleRecognizer(reason: "setting changed")
            return
        }
        let old = asr
        asr = nil
        asrKind = nil
        swapRecognizer(old: old)
    }

    // MARK: - Recognizer loading

    /// Frees the model of the old language first (they are large), then loads the new one if a session needs it.
    private func swapRecognizer(old: (any AsrEngine)?) {
        let running = state.mode != .idle
        if running { mutate { $0.loadingModel = true } }
        Task { [self] in
            if let old {
                await Task.detached { old.release() }.value
                journal.info("Recognizer released: \(old.language.code)")
            }
            if state.mode != .idle, hasAudio {
                let error = await ensureAsr()
                mutate { s in
                    // A successful load clears an earlier load failure; a new failure replaces it.
                    let kept: SessionError?
                    switch s.error {
                    case .asrLoadFailed?, .packMissing?: kept = nil
                    default: kept = s.error
                    }
                    s.loadingModel = false
                    s.error = error ?? kept
                }
            } else if running {
                mutate { $0.loadingModel = false }
            }
        }
    }

    /// Loads the recognizer for the current script's language; concurrent callers wait for the same load instead of
    /// failing.
    private func ensureAsr() async -> SessionError? {
        let previous = loadChain
        let task = Task { [self] () -> SessionError? in
            _ = await previous?.value
            return await loadRecognizer()
        }
        loadChain = task
        return await task.value
    }

    /// If the script switches language (or a setting changes) during a load, the loaded model is dropped and the right
    /// one loaded.
    private func loadRecognizer() async -> SessionError? {
        while true {
            let want = language
            let wantHotwords = settings.useHotwords
            let wantKind = settings.asrEngine
            if let current = asr {
                if current.language == want, current.hotwordsSetting == wantHotwords, asrKind == wantKind { return nil }
                asr = nil
                asrKind = nil
                await Task.detached { current.release() }.value
            }
            // Nothing to load: say so without a round trip to the factory.
            if wantKind == .sherpa, !packs.isAvailable(want) {
                journal.info("No speech pack for \(want.code): voice following is off")
                return .packMissing(want)
            }
            do {
                let started = clock()
                let engine = try await engines.makeEngine(language: want, kind: wantKind, hotwords: wantHotwords)
                // Hints come from the script that is current now: another one may have been opened during the load.
                guard language == want, settings.useHotwords == wantHotwords, settings.asrEngine == wantKind, asr == nil else {
                    await Task.detached { engine.release() }.value
                    continue
                }
                if let script { engine.setBias(hotwords: script.hotwords, biasWords: script.biasWords) }
                asr = engine
                asrKind = wantKind
                journal.info("Recognizer loaded in \(clock() - started) ms: \(engine.engineDescription)")
                return nil
            } catch {
                return sessionError(for: error, language: want)
            }
        }
    }

    private func sessionError(for error: any Error, language: SpeechLanguage) -> SessionError {
        switch error as? AsrLoadError {
        case .packMissing?:
            journal.info("No speech pack for \(language.code): voice following is off")
            return .packMissing(language)
        case .unsupportedLanguage?:
            journal.warning("The chosen recognizer doesn't support \(language.code)")
            return .asrLoadFailed("\(language.label) is not supported by this recognizer")
        case .modelLoadFailed(let detail)?:
            journal.error("Couldn't load the recognizer: \(detail)")
            return .asrLoadFailed(detail)
        case nil:
            journal.error("Couldn't load the recognizer", error)
            return .asrLoadFailed(error.localizedDescription)
        }
    }

    /// Frees the model when no session runs (after a while idle, or when the system is short of memory).
    public func releaseIdleRecognizer(reason: String = "memory") {
        guard state.mode == .idle, let old = asr else { return }
        asr = nil
        asrKind = nil
        Task { [self] in
            await Task.detached { old.release() }.value
            journal.info("Recognizer released (\(reason)): \(old.language.code)")
        }
    }

    // MARK: - Session

    /// `audio == nil` runs without a microphone (timed scrolling only).
    public func start(mode: SessionMode, audio newAudio: (any AudioSource)?) {
        if state.mode != .idle { stop() }
        guard mode != .idle else { return }
        unloadTask?.cancel()
        unloadTask = nil
        sessionToken += 1
        let token = sessionToken
        audio = newAudio
        hasAudio = newAudio != nil
        mutate {
            $0.mode = mode
            $0.starting = true
            $0.listening = false
            $0.error = nil
            $0.paused = false
            $0.autoFallback = false
            $0.micFailed = false
            $0.interrupted = false
            $0.countdown = 0
            // Nothing listens, so only the timer can move the text.
            if newAudio == nil, $0.scroll != .auto { $0.scroll = .auto }
        }
        startTask = Task { [self] in
            var asrError: SessionError?
            if hasAudio { asrError = await ensureAsr() }
            guard token == sessionToken, state.mode == mode, state.starting else { return }
            await continueStart(mode: mode, asrError: asrError, token: token)
        }
    }

    private func continueStart(mode: SessionMode, asrError: SessionError?, token: Int) async {
        resetStats()
        var stream: AsyncStream<AudioEvent>?
        if let source = audio {
            do {
                stream = try await source.start()
            } catch {
                let failure = (error as? CaptureError) ?? .startFailed(error.localizedDescription)
                guard token == sessionToken else { return }
                journal.error("\(failure)")
                audio = nil
                mutate {
                    $0.mode = .idle
                    $0.starting = false
                    $0.listening = false
                    $0.error = .capture(failure)
                }
                // The model may have loaded before the microphone refused: free it later like after a normal stop.
                scheduleUnload()
                return
            }
            guard token == sessionToken, state.mode == mode else {
                // Stopped while the microphone was opening; a newer start() may be using the same source object.
                if audio !== source { source.stop() }
                return
            }
        }
        journal.info(
            "Start: \(Self.logName(of: mode)), " + (hasAudio ? "16000 Hz" : "no microphone")
                + ", recognizer: \(asr?.engineDescription ?? "none")"
        )
        mutate {
            $0.starting = false
            $0.listening = true
            $0.error = asrError
        }
        lastTick = clock()
        if state.scroll == .auto { startCountdown() }
        if let stream {
            audioTask = Task { [self] in
                for await event in stream { await handle(event, token: token) }
            }
        }
        startTicker()
    }

    public func stop() {
        sessionToken += 1
        startTask?.cancel()
        startTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        audioTask?.cancel()
        audioTask = nil
        audio?.stop()
        audio = nil
        hasAudio = false
        if state.mode != .idle { journal.info("Session stopped") }
        scheduleUnload()
        countdownEndsAt = nil
        autoCarry = 0
        mutate {
            $0.mode = .idle
            $0.starting = false
            $0.listening = false
            $0.partial = ""
            $0.levelDb = -120
            $0.interrupted = false
            $0.digitalSilence = false
            $0.autoFallback = false
            $0.micFailed = false
            $0.countdown = 0
            $0.loadingModel = false
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [self] in
            try? await Task.sleep(for: Self.unloadAfter)
            guard !Task.isCancelled else { return }
            releaseIdleRecognizer(reason: "idle")
        }
    }

    // MARK: - Controls

    public func togglePause() {
        let paused = !state.paused
        mutate { $0.paused = paused }
        journal.info(paused ? "Paused" : "Resumed")
        if !paused, state.scroll == .auto { startCountdown() }
    }

    public func setScroll(_ mode: ScrollMode) {
        autoCarry = 0
        mutate { $0.scroll = mode }
        switch mode {
        case .auto: journal.info("Scroll: auto, \(settings.autoScrollWpm) wpm")
        case .sound: journal.info("Scroll: while talking, \(settings.autoScrollWpm) wpm")
        case .voice: journal.info("Scroll: voice")
        }
        if mode == .auto {
            startCountdown()
        } else {
            countdownEndsAt = nil
            mutate { $0.countdown = 0 }
        }
        recomputeFallback(now: clock())
    }

    /// Moves by display lines (see the follower: headings and [notes] are skipped).
    public func stepLine(_ delta: Int) {
        guard let follower, let moved = follower.stepLine(delta) else { return }
        afterManualMove(moved)
    }

    public func jump(toToken tokenIndex: Int) {
        guard let follower else { return }
        afterManualMove(follower.jump(toToken: tokenIndex))
    }

    public func restart() {
        guard let follower else { return }
        afterManualMove(follower.restart())
        if state.scroll == .auto { startCountdown() }
    }

    public func perform(_ action: KeyAction) {
        switch action {
        case .pause: togglePause()
        case .back: stepLine(-1)
        case .forward: stepLine(1)
        }
    }

    /// The reader moved the text by hand: what the recognizer heard so far no longer applies.
    private func afterManualMove(_ moved: FollowUpdate) {
        asr?.reset()
        epoch += 1
        autoCarry = 0
        mutate {
            $0.position = moved.position
            $0.nextToken = moved.nextToken
        }
    }

    // MARK: - Countdown and timed scrolling

    /// 3-2-1 before timed scrolling (voice following needs none: it starts when the reader does).
    private func startCountdown() {
        let seconds = settings.countdownSeconds
        guard seconds > 0, state.listening else { return }
        countdownEndsAt = clock() + Int64(seconds) * 1000
        mutate { $0.countdown = seconds }
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = nil
        guard autoTick else { return }
        tickerTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { break }
                tick()
            }
        }
    }

    /// One 100 ms step of the countdown and the timed scroll. Public to the package so tests can drive time.
    package func tick() {
        let now = clock()
        let dt = Double(now - lastTick) / 1000
        lastTick = now
        let st = state
        if let ends = countdownEndsAt {
            let left = Int((ends - now + 999) / 1000)
            if left <= 0 {
                countdownEndsAt = nil
                autoCarry = 0
                mutate { $0.countdown = 0 }
            } else if left != st.countdown {
                mutate { $0.countdown = left }
            }
        }
        let talking = lastVoiceAt.map { now - $0 < Self.soundHoldMillis } ?? false
        let timed = st.scroll == .auto || st.autoFallback || st.micFailed || !hasAudio || (st.scroll == .sound && talking)
        guard st.listening, !st.paused, countdownEndsAt == nil, timed, let follower else { return }

        // The speed is in words; Chinese and Korean scripts move by characters.
        autoCarry += Double(settings.autoScrollWpm) / 60 * dt * Double(language.unitsPerWord)
        guard autoCarry >= 1 else { return }
        let steps = Int(autoCarry)
        autoCarry -= Double(steps)
        let target = min(follower.position + steps, follower.size)
        let token = target >= spokenTokenIndex.count ? (script?.tokens.count ?? 0) : spokenTokenIndex[target]
        let moved = follower.jump(toToken: token)
        mutate {
            $0.position = moved.position
            $0.nextToken = moved.nextToken
        }
    }

    // MARK: - Audio

    private func handle(_ event: AudioEvent, token: Int) async {
        guard token == sessionToken else { return }
        switch event {
        case .chunk(let chunk):
            await handleChunk(chunk, token: token)
        case .interrupted:
            // No chunks arrive during an interruption, so the fallback can't wait for them.
            journal.info("Audio session interrupted (another app or a call has priority); the text moves on the timer")
            feeding = false
            mutate { $0.interrupted = true; $0.levelDb = -120 }
            recomputeFallback(now: clock())
        case .resumed:
            journal.info("Audio session resumed")
            mutate { $0.interrupted = false }
            recomputeFallback(now: clock())
        case .routeChanged(let description):
            journal.info("Audio route changed: \(description)")
        case .failed(let error):
            // The microphone stopped for good (the source already tried to reopen it): the timer keeps the text moving.
            journal.error("\(error); the text moves on the timer")
            mutate {
                $0.error = .capture(error)
                $0.micFailed = true
                $0.levelDb = -120
            }
        }
    }

    private func handleChunk(_ chunk: AudioChunk, token: Int) async {
        defer { processedChunks += 1 }
        let now = clock()
        statFrames += 1
        if chunk.digitalSilence { statZeroFrames += 1 }
        statDbSum += Double(chunk.rmsDb)
        statDbMax = max(statDbMax, chunk.rmsDb)
        if chunk.digitalSilence {
            if zeroSince == nil { zeroSince = now }
        } else {
            zeroSince = nil
        }

        // A talking voice stands out from the room: louder than the background by a margin. The background starts at the
        // first chunk heard, falls a few dB per chunk and rises slowly, so one very quiet chunk doesn't make the room
        // itself count as a voice for seconds.
        if !chunk.digitalSilence {
            let floor = noiseFloorDb ?? chunk.rmsDb
            if chunk.rmsDb > floor + Self.voiceMarginDb, chunk.rmsDb > Self.voiceMinDb { lastVoiceAt = now }
            noiseFloorDb = chunk.rmsDb < floor
                ? max(chunk.rmsDb, floor - Self.floorFallDb)
                : floor + (chunk.rmsDb - floor) * 0.01
        }

        // Recognition only matters while following the voice: paused, timed or long all-zero audio would decode for
        // nothing. A short zero gap is still fed, so the recognizer can close the phrase instead of losing it.
        let st = state
        let longZero = zeroSince.map { now - $0 > Self.zeroFeedMillis } ?? false
        let engine = (st.scroll == .voice && !st.paused && !longZero) ? asr : nil
        // Audio from before the pause must not complete a word now.
        if let engine, !feeding { engine.reset() }
        feeding = engine != nil
        if let engine {
            let fromEpoch = epoch
            let samples = chunk.samples
            let rate = chunk.sampleRate
            let update = await Task.detached(priority: .userInitiated) { engine.accept(samples, sampleRate: rate) }.value
            // The session may have stopped while this chunk was decoding.
            guard token == sessionToken else { return }
            if let update { onRecognized(update, fromEpoch: fromEpoch) }
        }

        // Voice and sound both depend on hearing: when the system feeds silence, the timer keeps the text moving.
        let fallback = fallbackNeeded(now: now)
        mutate {
            $0.levelDb = chunk.rmsDb
            $0.digitalSilence = chunk.digitalSilence
            $0.autoFallback = fallback
        }
        if now - lastStatLog >= Self.statLogMillis {
            lastStatLog = now
            logStats()
        }
    }

    private func fallbackNeeded(now: Int64) -> Bool {
        let needsMic = state.scroll == .voice || state.scroll == .sound
        let longZero = zeroSince.map { now - $0 > Self.silenceFallbackMillis } ?? false
        return needsMic && (state.interrupted || longZero)
    }

    private func recomputeFallback(now: Int64) {
        let fallback = fallbackNeeded(now: now)
        mutate { $0.autoFallback = fallback }
    }

    private func onRecognized(_ update: AsrUpdate, fromEpoch: Int) {
        // A manual move or a new script happened while this audio was being recognized: it would undo the move.
        guard fromEpoch == epoch, let follower else { return }
        let voice = !state.paused && state.scroll == .voice
        let moved = follower.onRecognized(
            text: update.text,
            isFinal: update.isFinal,
            voiceActive: voice,
            leadWords: settings.leadWords,
            nowMillis: clock()
        )
        if moved.moved, moved.reason != "follow" {
            journal.info(
                "Tracker: \(moved.reason) → word \(moved.position)/\(follower.size) (matched \(moved.matches), score "
                    + String(format: "%.1f", Double(moved.score)) + ")"
            )
        }
        let hasText = !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if update.isFinal, hasText {
            statWords += update.text.split(whereSeparator: { $0.isWhitespace }).count
            journal.info("Heard: \(update.text)")
        }
        mutate {
            $0.partial = update.isFinal ? "" : update.text
            if update.isFinal, hasText { $0.lastFinal = update.text }
            $0.position = moved.position
            $0.nextToken = moved.nextToken
        }
    }

    private func resetStats() {
        statFrames = 0
        statZeroFrames = 0
        statDbSum = 0
        statDbMax = -120
        statWords = 0
        zeroSince = nil
        feeding = false
        noiseFloorDb = nil
        lastVoiceAt = nil
        lastStatLog = clock()
        processedChunks = 0
    }

    private func logStats() {
        guard statFrames > 0 else { return }
        let avg = statDbSum / Double(statFrames)
        let zeroPercent = statZeroFrames * 100 / statFrames
        journal.info(
            String(
                format: "Mic, last 5 s: avg %.0f dB, peak %.0f dB, zero frames %d%%, words %d, position %d/%d",
                avg, Double(statDbMax), zeroPercent, statWords, state.position, state.total
            )
        )
        statFrames = 0
        statZeroFrames = 0
        statDbSum = 0
        statDbMax = -120
        statWords = 0
    }

    private static func logName(of mode: SessionMode) -> String {
        switch mode {
        case .idle: "idle"
        case .rehearsal: "rehearsal"
        case .camera: "camera"
        case .pictureInPicture: "picture in picture"
        }
    }
}

extension SpeechLanguage {
    /// Units (characters in Chinese and Korean) per spoken word, for the timed speed (Kotlin: `SpeechLang.unitsPerWord`).
    var unitsPerWord: Float {
        switch self {
        case .zh: 1.7 // a Chinese word has about 1.7 characters
        case .ko: 3 // a Korean word (eojeol) about 3 syllables
        default: 1
        }
    }
}
