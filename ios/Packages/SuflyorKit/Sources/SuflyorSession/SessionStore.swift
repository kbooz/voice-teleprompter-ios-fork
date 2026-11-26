import Foundation
import Observation
import SuflyorDomain

/// Main-actor face of the engine for SwiftUI. Every method returns immediately and forwards to the actor.
///
/// Commands go through one `AsyncStream` and a single consumer, so they reach the engine in the order they were given
/// (separate `Task`s would not keep that order).
@MainActor @Observable
public final class SessionStore {
    public private(set) var state: SessionState
    public private(set) var script: PreparedScript?
    public private(set) var settings: PrompterSettings
    public let engine: SessionEngine

    private enum Command: Sendable {
        case setScript(PreparedScript)
        case updateSettings(PrompterSettings)
        case start(SessionMode, (any AudioSource)?)
        case stop
        case togglePause
        case setScroll(ScrollMode)
        case stepLine(Int)
        case jump(Int)
        case restart
        case perform(KeyAction)
    }

    @ObservationIgnored private let commands: AsyncStream<Command>.Continuation

    public init(engine: SessionEngine, settings: PrompterSettings) {
        self.engine = engine
        self.settings = settings
        self.state = SessionState()
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        self.commands = continuation

        // The engine's own settings come from the same place; this only makes sure they agree.
        continuation.yield(.updateSettings(settings))
        Task.detached {
            for await command in stream { await Self.run(command, on: engine) }
        }
        Task { [weak self] in
            let states = await engine.updates()
            for await newState in states {
                guard let self else { return }
                self.state = newState
            }
        }
    }

    nonisolated private static func run(_ command: Command, on engine: SessionEngine) async {
        switch command {
        case .setScript(let script): await engine.setScript(script)
        case .updateSettings(let settings): await engine.updateSettings(settings)
        case .start(let mode, let audio): await engine.start(mode: mode, audio: audio)
        case .stop: await engine.stop()
        case .togglePause: await engine.togglePause()
        case .setScroll(let mode): await engine.setScroll(mode)
        case .stepLine(let delta): await engine.stepLine(delta)
        case .jump(let token): await engine.jump(toToken: token)
        case .restart: await engine.restart()
        case .perform(let action): await engine.perform(action)
        }
    }

    public func setScript(_ script: PreparedScript) {
        self.script = script
        commands.yield(.setScript(script))
    }

    public func updateSettings(_ settings: PrompterSettings) {
        self.settings = settings
        commands.yield(.updateSettings(settings))
    }

    public func start(mode: SessionMode, audio: (any AudioSource)?) {
        commands.yield(.start(mode, audio))
    }

    public func stop() { commands.yield(.stop) }
    public func togglePause() { commands.yield(.togglePause) }
    public func setScroll(_ mode: ScrollMode) { commands.yield(.setScroll(mode)) }
    public func stepLine(_ delta: Int) { commands.yield(.stepLine(delta)) }
    public func jump(toToken tokenIndex: Int) { commands.yield(.jump(tokenIndex)) }
    public func restart() { commands.yield(.restart) }
    public func perform(_ action: KeyAction) { commands.yield(.perform(action)) }

    /// Applies `settings.keyBindings` (when `settings.keyControl`); returns false when the key is not bound.
    @discardableResult
    public func handle(_ key: HardwareKey) -> Bool {
        guard settings.keyControl, let action = settings.keyBindings[key] else { return false }
        perform(action)
        return true
    }
}
