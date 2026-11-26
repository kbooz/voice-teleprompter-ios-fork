import Foundation
import SuflyorDomain

/// Creates the recognizer for a language: sherpa-onnx from a bundled model or an installed pack, or Apple's engine.
/// A model load takes a second or two, so the work never runs on the caller's actor.
public final class SpeechEngineFactory: AsrEngineFactory, @unchecked Sendable {
    private let packs: SpeechPackStore

    public init(packs: SpeechPackStore) {
        self.packs = packs
    }

    public func makeEngine(
        language: SpeechLanguage,
        kind: AsrEngineKind,
        hotwords: Bool
    ) async throws(AsrLoadError) -> any AsrEngine {
        switch kind {
        case .sherpa:
            guard let model = packs.modelLocation(for: language) else { throw .packMissing(language) }
            let result: Result<SherpaAsr, AsrLoadError> = await Task.detached(priority: .userInitiated) { () -> Result<SherpaAsr, AsrLoadError> in
                do {
                    return .success(try SherpaAsr.create(
                        directory: model.directory,
                        language: language,
                        label: model.label,
                        modelType: model.modelType,
                        hotwords: hotwords
                    ))
                } catch {
                    // `create` throws only AsrLoadError; anything else is reported as a failed load.
                    return .failure((error as? AsrLoadError) ?? .modelLoadFailed("\(error)"))
                }
            }.value
            switch result {
            case .success(let engine): return engine
            case .failure(let error): throw error
            }
        case .apple:
            return try await AppleSpeechAsr.create(language: language, hotwords: hotwords)
        }
    }
}
