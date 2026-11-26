# Contratos da migração iOS (plano detalhado para os agentes)

Este documento detalha o [plano de migração](../plano-migracao-ios.md) em **5 pacotes de trabalho (WP)** que rodam em paralelo, cada um num git worktree próprio. Os contratos abaixo são a fonte da verdade: **um WP nunca muda a API de outro**. Se precisar mudar um contrato, o WP escreve o pedido no relatório final, e a mudança é aplicada na integração.

## 0. Regras para todos os WPs

- **Linguagem e ferramentas:** Swift 6 (modo de linguagem 6, concorrência estrita), iOS 26 como mínimo, SwiftUI + Observation (`@Observable`), Swift Testing (`import Testing`) para testes. Kotlin 2.3.20 no núcleo, como o resto do repositório.
- **Comentários de código em inglês**, curtos, explicando o *porquê* (o mesmo estilo do código Android). Documentação em português.
- **Nenhum código de rede no app.** Nada de `URLSession`, WebSocket ou analytics. A única dependência externa é a ZIPFoundation, além do sherpa-onnx vendorizado.
- **Este container não tem Xcode nem Swift.** O código Swift não pode ser compilado aqui. Por isso:
  - use só APIs da Apple que você tem certeza de que existem no iOS 26 com essa assinatura. Na dúvida, prefira a API mais antiga e estável;
  - marque com `// VERIFY:` toda chamada sobre a qual tenha dúvida, para a primeira build no Mac encontrar rápido;
  - releia cada arquivo procurando erros de tipo, `Sendable`, isolamento de ator, `try`/`await` faltando e imports;
  - não invente APIs de outros WPs: use só o que está neste documento e em `SuflyorDomain`.
- **Strings visíveis ao usuário:** use `L10n.text("chave")` (definido em `SuflyorDomain`).
  - Reaproveite as chaves Android (`app/src/main/res/values/strings*.xml`) quando o sentido for o mesmo.
  - Textos novos só do iOS usam a chave `ios_<wp>_<nome>` e vão para `ios/Suflyor/Resources/ios-strings/<wp>.json`, no formato `{"ios_camera_record": {"en": "Record", "pt-BR": "Gravar", "ru": "Запись", "tr": "Kaydet"}}`. O `en` é obrigatório; os demais idiomas são desejáveis.
- **Não edite:** `ios/Packages/SuflyorKit/Package.swift`, `ios/Packages/SuflyorKit/Sources/SuflyorDomain/**` e os arquivos de outros WPs (ver a seção 1).
- **Git:** faça commits no seu worktree (branch próprio) com mensagens claras. **Não faça push.** Termine cada mensagem de commit com:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Lsut29NsauSooHsXdpHsNT
  ```
- **Relatório final** (é a sua última mensagem): arquivos criados ou alterados; o que foi verificado e como (comandos e resultados); o que não pôde ser verificado; lista de `// VERIFY:`; pedidos de mudança de contrato; chaves de strings novas; TODOs.

## 1. Divisão e propriedade dos arquivos

| WP | Escopo | É dono de |
|---|---|---|
| **A — Núcleo KMP** | Extrair o rastreador e os normalizadores para o Kotlin Multiplatform, com a fachada para Swift | `core/**`, `settings.gradle.kts`, `build.gradle.kts` (raiz), `app/build.gradle.kts`, arquivos movidos de `app/src/**`, `.github/workflows/ci.yml` |
| **B — App iOS** | Projeto XcodeGen, telas, dados, configurações, adaptador KMP, extensões | `ios/project.yml`, `ios/Suflyor/**` (exceto `Resources/Localizable.xcstrings` e os JSON de outros WPs), `ios/SuflyorShare/**`, `ios/SuflyorControls/**`, `ios/Suflyor/Resources/ios-strings/app.json` |
| **C — Voz e sessão** | Microfone, sherpa-onnx, motor da Apple, pacotes de voz, motor de sessão | `Sources/SuflyorSpeech/**`, `Sources/SuflyorSession/**`, `Sources/SuflyorTestSupport/**`, `Sources/CSherpaOnnx/**`, `Tests/SuflyorSpeechTests/**`, `Tests/SuflyorSessionTests/**`, `Tests/SuflyorDomainTests/**`, `ios/Packages/SuflyorKit/Vendor/README.md`, `ios/scripts/fetch-sherpa-onnx.sh`, `ios-strings/speech.json` |
| **D — Teleprompter, câmera, PiP** | Renderização do texto, ensaio, Modo Câmera, PiP, teclas | `Sources/SuflyorPrompter/**`, `Sources/SuflyorCamera/**`, `Tests/SuflyorPrompterTests/**`, `ios-strings/prompter.json` |
| **E — Importadores e ferramentas** | Importadores de arquivo, backup, catálogo de strings, scripts, CI iOS | `Sources/SuflyorImporters/**`, `Tests/SuflyorImportersTests/**`, `tools/ios/**`, `tools/speech-assets.json`, `ios/scripts/fetch-speech-models.sh`, `.github/workflows/ios.yml`, `ios/Suflyor/Resources/Localizable.xcstrings`, `ios-strings/importers.json` |

Caminhos `Sources/` e `Tests/` são relativos a `ios/Packages/SuflyorKit/`.

## 2. Contrato do núcleo Kotlin (WP-A implementa; WP-B consome)

O módulo `core/` é um **build Gradle independente** (com `settings.gradle.kts` próprio), incluído na raiz com `includeBuild("core")`. Assim ele compila sem o Android SDK, e no Mac basta rodar `./gradlew -p core assembleSuflyorCoreReleaseXCFramework`.

- Alvos: `jvm()` (consumido pelo app Android), `iosArm64()` e `iosSimulatorArm64()`, gerando o XCFramework `SuflyorCore` (estático).
- Coordenadas: `group = "com.olerast.suflyor"`, artefato `core`. O app Android declara `implementation("com.olerast.suflyor:core")`, resolvido pela substituição do build incluído.
- **Os pacotes Kotlin continuam os mesmos** (`com.olerast.suflyor.track`, `.script`, `.doc`, `.speech`). Assim o código Android que fica no app não precisa mudar os imports, e os merges com o projeto original continuam fáceis.
- Vão para `core/src/commonMain`: `track/ScriptTracker.kt`; todo o `script/` (incluindo o `PhraseBreaker`); `doc/ScriptDocument.kt` (`ScriptDocument`, `Paragraph`, `ParagraphBuilder`); `doc/MarkdownImporter.kt`; a parte de `doc/ImportError.kt` de que eles dependem (`ImportWarning`, e `ImportError`/`ImportException` se forem necessários); e `hotwordList` (sai do `SherpaAsr.kt` para `core/.../speech/Hotwords.kt`, como função **pública**).
- Os testes que só dependem desses arquivos vão para `core/src/commonTest` (ou para `jvmTest` quando usam `java.io.File` ou `java.util.Random`): `ScriptTrackerTest`, `TrackerStressTest`, `EnglishTrackerTest`, `TurkishTrackerTest`, `CjkHebrewTest`, `EgyptianArabicTrackerTest`, `LetterNamesTest` e `RussianGoldenTest` (com `golden/ru_golden.txt`). `ImportersTest`, `ScriptArchiveTest` e `SpeechPackTest` ficam no app.

### 2.1 Fachada para Swift — `core/src/commonMain/kotlin/com/olerast/suflyor/core/SuflyorCore.kt`

As assinaturas são **exatamente** estas (os nomes de parâmetro viram rótulos no Swift):

```kotlin
package com.olerast.suflyor.core

/** UTF-16 offsets, end exclusive (Kotlin IntRange first..last becomes CoreRange(first, last + 1)). */
data class CoreRange(val start: Int, val endExclusive: Int)
data class CoreParagraph(val text: String, val heading: Boolean, val emphasis: List<CoreRange>)
data class CoreToken(val start: Int, val endExclusive: Int, val spoken: Boolean)
data class CoreLanguage(val code: String, val label: String, val needsPack: Boolean)
data class CoreFollowUpdate(
    val moved: Boolean,
    val position: Int,
    val nextToken: Int,
    val matches: Int,
    val score: Float,
    val reason: String,
)

object SuflyorCore {
    const val API_VERSION: Int = 1
    fun languages(): List<CoreLanguage>
    /** SpeechLang.detect on a document built from [paragraphs]; returns the SpeechLang code. */
    fun detectLanguage(paragraphs: List<CoreParagraph>): String
    /** MarkdownImporter.parse(text, title).paragraphs */
    fun parseMarkdown(text: String, title: String): List<CoreParagraph>
    /** ScriptLayout.build(doc, phraseMode, maxWords, lang). Unknown langCode falls back to RU, as on Android. */
    fun buildScript(title: String, paragraphs: List<CoreParagraph>, langCode: String, phraseMode: Boolean, maxWords: Int): CoreScript
}

class CoreScript internal constructor(internal val model: ScriptModel) {
    val title: String
    val langCode: String
    val displayText: String
    val tokens: List<CoreToken>
    val emphasis: List<CoreRange>
    val notes: List<CoreRange>
    val spokenWords: Int
    fun biasWords(): List<String>          // model.biasWords()
    fun hotwords(): String                 // hotwordList(model.lang, model.biasWords())
    fun newFollower(): CoreFollower
}

/**
 * ScriptTracker plus the word history and lead logic of Android's SessionEngine (onAsr, stepLine, moveTracker),
 * so both platforms follow the voice the same way. Not thread-safe.
 */
class CoreFollower internal constructor(script: CoreScript) {
    val position: Int          // tracker.position
    val nextToken: Int         // tracker.tokenIndexAt(displayPos)
    val size: Int              // tracker.size
    fun onRecognized(text: String, isFinal: Boolean, voiceActive: Boolean, leadWords: Int, nowMillis: Long): CoreFollowUpdate
    fun jumpToToken(tokenIndex: Int): CoreFollowUpdate
    fun stepLine(delta: Int): CoreFollowUpdate?
    fun restart(): CoreFollowUpdate
}
```

`CoreFollower.onRecognized` reproduz **literalmente** o `SessionEngine.onAsr` do Android:

1. `words = lang.words(text)`. Se não for final, guarda `lastSpeechAt = nowMillis`.
2. Se for final, junta `words` ao histórico e corta em `lang.history`, limpando as palavras parciais. Se não for final, as parciais passam a ser `words`.
3. `before = position`. Se `voiceActive`, chama `tracker.onHypothesis(final + partial)`.
4. Se `pos < before`, então `displayPos = pos`. Depois, `maxLead = voiceActive ? leadWords : 0` e `lead = (voiceActive && nowMillis - lastSpeechAt < SPEAKING_MS) ? maxLead : 0`, com o mesmo `SPEAKING_MS` do Android.
5. `displayPos = max(displayPos, min(pos + lead, size)).coerceAtMost(pos + maxLead)`.
6. Devolve `nextToken = tracker.tokenIndexAt(displayPos)`.

O `moved` e o `reason` vêm do `ScriptTracker.Update`. Quando o tracker não roda, o resultado é `moved = false` e `reason = "idle"`.

`jumpToToken`, `stepLine` e `restart` fazem o mesmo que o `moveTracker` do Android: limpam o histórico e as parciais e fazem `displayPos = position`. O `stepLine` usa o mesmo cálculo de primeira palavra de cada linha do `SessionEngine.stepLine` e devolve `null` quando não há para onde ir. Nesses três casos, o `reason` é `"manual"`. Resetar o reconhecedor e controlar a "época" ficam com o Swift.

### 2.2 Como o Swift vê a fachada (exportação Objective-C do Kotlin/Native)

Isso vale para o adaptador `KMPScriptCore` do WP-B:

- `object SuflyorCore` vira `SuflyorCore.shared`.
- `Int` vira `Int32`, `Long` vira `Int64`, `Float` vira `Float` e `Boolean` vira `Bool`.
- `List<CoreParagraph>` vira `[CoreParagraph]` e `List<String>` vira `[String]`.
- Retorno anulável vira opcional.
- Construtores de data class: `CoreParagraph(text:heading:emphasis:)` e `CoreRange(start:endExclusive:)`.
- Uso: `import SuflyorCore`.

## 3. Contratos Swift

`SuflyorDomain` (já escrito, em `ios/Packages/SuflyorKit/Sources/SuflyorDomain/`) define os tipos e protocolos de base: `ScriptParagraph`, `ImportedDocument`, `ImportError`, `ImportWarning`, `SpeechLanguage`, `PreparedScript`, `ScriptToken`, `FollowUpdate`, `ScriptFollowing`, `ScriptCoreProviding`, `AsrUpdate`, `AsrEngine`, `AsrEngineFactory`, `AsrEngineKind`, `SpeechPackInfo`, `SpeechPackManaging`, `AudioChunk`, `AudioEvent`, `AudioSource`, `CaptureError`, `ScrollMode`, `SessionMode`, `SessionState`, `SessionError`, `KeyAction`, `HardwareKey`, `KeyBindings`, `PrompterSettings`, `OverlayTarget`, `AppConstants`, `L10n` e `Journal`. **Leia esses arquivos antes de começar.**

As APIs públicas abaixo são as que cada WP **precisa** entregar. Pode haver tipos internos a mais, mas não outras APIs públicas usadas por terceiros.

### 3.1 `SuflyorImporters` (WP-E)

```swift
import UniformTypeIdentifiers

public struct DocumentImporter: Sendable {
    public init(core: any ScriptCoreProviding)
    /// Types offered in the file picker and the Share extension.
    public static var supportedContentTypes: [UTType] { get }
    /// `fileName` gives the extension and the default title; `contentType` is the UTType identifier when known.
    public func importFile(data: Data, fileName: String, contentType: String?) throws(ImportError) -> ImportedDocument
    public func importPastedText(_ text: String, title: String?) throws(ImportError) -> ImportedDocument
}

/// Library backup: a zip of Markdown files, readable by the Android app and back.
public enum ScriptArchive {
    public struct Entry: Hashable, Sendable {
        public var fileName: String
        public var document: ImportedDocument
    }
    public static func export(_ documents: [ImportedDocument]) throws -> Data
    public static func read(_ data: Data, core: any ScriptCoreProviding) throws(ImportError) -> [Entry]
    /// Markdown text of one script (also used for "Share text").
    public static func markdown(of document: ImportedDocument) -> String
}
```

### 3.2 `SuflyorSpeech` (WP-C)

```swift
import AVFAudio

/// AVAudioEngine input tap → 16 kHz mono chunks. Category .playAndRecord, options [.mixWithOthers, .allowBluetoothHFP,
/// .defaultToSpeaker]; handles interruptions and route changes as AudioEvents.
public final class MicrophoneAudioSource: AudioSource, @unchecked Sendable { public init() }

public enum MicrophonePermission {
    public static var isGranted: Bool { get }
    public static func request() async -> Bool
}

/// Accumulates mono Float samples (already at 16 kHz) into ~100 ms AudioChunks with rmsDb and digitalSilence,
/// computed as Android's AudioCapture does. Used by MicrophoneAudioSource and by WP-D's CaptureAudioSource.
public struct AudioChunker: Sendable {
    public init(sampleRate: Int = 16_000, chunkMillis: Int = 100)
    public mutating func append(_ samples: [Float]) -> [AudioChunk]
}

/// Any AVAudioPCMBuffer / CMSampleBuffer audio → 16 kHz mono Float32.
public final class PCMConverter16k: @unchecked Sendable {
    public init(inputFormat: AVAudioFormat) throws
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float]
}

public final class SpeechPackStore: SpeechPackManaging, @unchecked Sendable {
    /// Packs live in Application Support/speech/<code>/; bundled models in the app bundle's asr-<code>/ folders.
    public init(rootDirectory: URL? = nil, bundle: Bundle = .main)
}

public final class SpeechEngineFactory: AsrEngineFactory, @unchecked Sendable {
    public init(packs: SpeechPackStore)
}
```

### 3.3 `SuflyorSession` (WP-C)

```swift
public actor SessionEngine {
    public init(core: any ScriptCoreProviding, engines: any AsrEngineFactory, packs: any SpeechPackManaging, settings: PrompterSettings)
    /// A new stream per subscriber; yields the current state first.
    public func updates() -> AsyncStream<SessionState>
    public func setScript(_ script: PreparedScript)
    public func updateSettings(_ settings: PrompterSettings)
    /// `audio == nil` runs without a microphone (timed scrolling only).
    public func start(mode: SessionMode, audio: (any AudioSource)?)
    public func stop()
    public func togglePause()
    public func setScroll(_ mode: ScrollMode)
    public func stepLine(_ delta: Int)
    public func jump(toToken tokenIndex: Int)
    public func restart()
    public func perform(_ action: KeyAction)
}

/// Main-actor face of the engine for SwiftUI. Every method returns immediately and forwards to the actor.
@MainActor @Observable
public final class SessionStore {
    public private(set) var state: SessionState
    public private(set) var script: PreparedScript?
    public private(set) var settings: PrompterSettings
    public let engine: SessionEngine
    public init(engine: SessionEngine, settings: PrompterSettings)
    public func setScript(_ script: PreparedScript)
    public func updateSettings(_ settings: PrompterSettings)
    public func start(mode: SessionMode, audio: (any AudioSource)?)
    public func stop()
    public func togglePause()
    public func setScroll(_ mode: ScrollMode)
    public func stepLine(_ delta: Int)
    public func jump(toToken tokenIndex: Int)
    public func restart()
    public func perform(_ action: KeyAction)
    /// Applies `settings.keyBindings` (when `settings.keyControl`); returns false when the key is not bound.
    @discardableResult public func handle(_ key: HardwareKey) -> Bool
}
```

`SuflyorTestSupport` (WP-C) traz `SimpleScriptCore: ScriptCoreProviding` (tokenização simples por espaços e um follower ingênuo que avança quando as palavras batem), `FakeAsrEngine`, `FakeAsrEngineFactory`, `FakeAudioSource` e `FakeSpeechPackStore`, para testes e previews.

### 3.4 `SuflyorPrompter` (WP-D)

```swift
import SwiftUI

public struct PrompterStyle: Hashable, Sendable {
    public var fontSize: Double
    public var visibleLines: Int           // 0 = as many as fit (full screen)
    public var paddingStart: Double
    public var paddingEnd: Double
    public var wordHighlight: Bool
    public var backgroundOpacity: Double   // 0...1, band behind the text
    public var mirrorHorizontal: Bool
    public var mirrorVertical: Bool
    public static func overCamera(_ settings: PrompterSettings) -> PrompterStyle
    public static func fullScreen(_ settings: PrompterSettings) -> PrompterStyle
}

/// The scrolling script: read lines dimmed, [notes] styled, emphasis bold, the next word kept on the reading line.
public struct PrompterTextView: View {
    public init(script: PreparedScript, nextToken: Int, style: PrompterStyle, onTapToken: ((Int) -> Void)? = nil)
}

/// Full-screen rehearsal / teleprompter glass: text, controls (pause, mode, ±line, Aa, close), countdown, diagnostics line.
public struct RehearsalScreen: View {
    public init(store: SessionStore, settings: Binding<PrompterSettings>, onClose: @escaping () -> Void)
}

/// The "Aa" sheet: text size, lines, background, speed.
public struct TuneSheet: View {
    public init(settings: Binding<PrompterSettings>, fullScreen: Bool)
}

extension View {
    /// Keyboard, clicker and media keys while this view is on screen (UIKit presses).
    public func hardwareKeys(enabled: Bool, onKey: @escaping (HardwareKey) -> Void) -> some View
}

/// Draws the prompter into the Picture in Picture window (AVSampleBufferDisplayLayer + AVPictureInPictureController).
@MainActor
public final class PiPPrompter {
    public init(store: SessionStore)
    public static var isSupported: Bool { get }
    public private(set) var isActive: Bool
    /// The inline view PiP starts from; must be on screen before `start()`.
    public var hostView: some View { get }
    public func start()
    public func stop()
}
```

### 3.5 `SuflyorCamera` (WP-D)

```swift
public enum CameraPermission {
    public static var isGranted: Bool { get }
    public static func request() async -> Bool   // camera + microphone
}

/// Front camera live behind the text, recording with sound, saving to Photos and sharing.
public struct CameraScreen: View {
    public init(store: SessionStore, settings: Binding<PrompterSettings>, onClose: @escaping () -> Void)
}

/// The capture session's microphone as an AudioSource, so the session follows the same audio that is recorded.
public final class CaptureAudioSource: AudioSource, @unchecked Sendable { }
```

### 3.6 App (WP-B)

- O `ios/project.yml` (XcodeGen) gera `ios/Suflyor.xcodeproj` com o esquema **`Suflyor`** e estes alvos:
  - `Suflyor` (app);
  - `SuflyorShare` (Share Extension);
  - `SuflyorControls` (WidgetKit com o `ControlWidget`).
- O app depende do pacote local `Packages/SuflyorKit` e do `../core/build/XCFrameworks/release/SuflyorCore.xcframework`. Um *pre-build script* roda o Gradle quando o framework está faltando ou desatualizado.
- `KMPScriptCore: ScriptCoreProviding` (no app) adapta `SuflyorCore`: converte `TextRange` ↔ `CoreRange`, `Int` ↔ `Int32`, e `ScriptFollowing` é implementado por `KMPFollower`, que embrulha o `CoreFollower`. O `PreparedScript.handle` guarda o `CoreScript`.
- `AppEnvironment` (`@MainActor @Observable`) cria `KMPScriptCore`, `SpeechPackStore`, `SpeechEngineFactory`, `SessionEngine`, `SessionStore`, `DocumentImporter` e `SettingsStore`, e injeta tudo pelo `.environment`.
- Deep links `suflyor://record?script=<id>`, `suflyor://pip?script=<id>` e `suflyor://import`. A Share Extension grava o arquivo em `<App Group>/Inbox/` e abre `suflyor://import`.

## 4. Verificação na integração (feita pelo arquiteto)

1. `./gradlew -p core jvmTest` verde, com os testes do tracker que foram migrados.
2. Revisão de cada WP contra os contratos e merge na ordem A → E → C → D → B.
3. `python3 tools/ios/convert_strings.py` gera o catálogo final com os JSON de todos os WPs.
4. Lista consolidada de `// VERIFY:` para a primeira build no Mac.
