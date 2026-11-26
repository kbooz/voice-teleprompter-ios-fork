# Lista de verificação da primeira build no Mac

Gerada a partir dos comentários `// VERIFY:` do código (nenhum código Swift foi compilado no ambiente de desenvolvimento, que é Linux).
Total: **57** pontos. Regere com o comando no fim deste arquivo.

## Ordem sugerida

1. `ios/scripts/fetch-sherpa-onnx.sh --print-sha`: preencher `ORT_SHA256` e confirmar `SHERPA_SHA256`.
2. `./gradlew -p core assembleSuflyorCoreReleaseXCFramework` e `./gradlew -p core iosSimulatorArm64Test` (os testes comuns ainda não rodaram no iOS).
3. Definir `BUNDLE_ID_PREFIX`, `APP_GROUP` e `DEVELOPMENT_TEAM` em `ios/project.yml` e em `AppConstants`.
4. `xcodegen generate --spec ios/project.yml` e compilar o esquema `Suflyor` com Xcode 27 (modo Swift 6).
5. `swift test` no pacote `SuflyorKit` e, depois, os pontos abaixo, módulo a módulo.
6. Testar num iPhone real: microfone no PiP com Instagram, TikTok e Câmera gravando (decisão da seção 4.4 do plano).

## Pontos `VERIFY` por módulo

### App / CI / scripts (14)

- `.github/workflows/ios.yml:36` — the runner label that carries Xcode 27 (the macOS image name changes with each Xcode release).
- `.github/workflows/ios.yml:40` — the Xcode 27 install path on the runner image, and a simulator name that exists in that Xcode.
- `ios/Packages/SuflyorKit/Tests/SuflyorSpeechTests/ZipBuilder.swift:3` — ZIPFoundation reads these stored entries (MS-DOS "made by", no external attributes) like real packs.
- `ios/Shared/SuflyorIntents.swift:36` — still honoured on iOS 26 (the newer `supportedModes` may replace it).
- `ios/Shared/SuflyorIntents.swift:53` — see StartRecordingIntent.
- `ios/Suflyor/AppEnvironment+Import.swift:46` — install(from:) answers .notAPack quickly for a backup zip and never leaves files behind.
- `ios/Suflyor/AppEnvironment+Session.swift:59` — OverlayTargetLauncher.open(_:) / hint(for:target:) signatures as announced by WP-D.
- `ios/Suflyor/Core/KMPScriptCore.swift:10` — the Swift names of the Kotlin export (SuflyorCore.shared, labels, Int32 types) match the generated header.
- `ios/Suflyor/Core/KMPScriptCore.swift:11` — if `SuflyorCore.shared` resolves to the module, add `typealias KCore = SuflyorCore.SuflyorCore`.
- `ios/Suflyor/Data/SettingsStore.swift:52` — `WritableKeyPath & Sendable` accepts key path literals (`\.fontSize`) at every call site.
- `ios/Suflyor/Intents/SuflyorShortcuts.swift:6` — phrases are English only; localize them with an AppShortcuts.xcstrings if wanted.
- `ios/Suflyor/Screens/LibraryView.swift:177` — PasteButton(payloadType:onPaste:) and the icon-only label style.
- `ios/Suflyor/Screens/LibraryView.swift:291` — fileExporter accepts an optional document and presents once `file` is set.
- `ios/SuflyorControls/SuflyorControls.swift:20` — ControlWidgetButton(action:label:) builds with this closure on the iOS 26 SDK.

### SuflyorCamera (11)

- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:159` — `.allowBluetoothHFP` is the iOS 26 name (contratos 3.2 uses it too).
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:205` — the data output mirrors front-camera frames by default; turning that off gives the true picture.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:232` — front camera formats at 1080p that reach 60 fps; changing the format drops the preset.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:264` — RotationCoordinator(device:previewLayer:) and its KVO-observable angle properties (iOS 17+).
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:317` — angle to transform mapping for the front camera (unmirrored buffers): rotation by the same angle.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:320` — the recommended audio settings come back as [AnyHashable: Any]; AAC at the microphone's rate.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraRecorder.swift:86` — the reason key is `AVCaptureSessionInterruptionReasonKey`; logged as a raw number for the journal.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraScreen.swift:346` — FileRepresentation with SentTransferredFile is the documented way to share a file URL.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraScreen.swift:369` — `effectiveGeometry.interfaceOrientation` (iOS 16+) is the non-deprecated way to read the orientation.
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CameraScreen.swift:59` — the iOS 18 two-handler form of onCameraCaptureEvent: volume down, Action button, Camera Control and
- `ios/Packages/SuflyorKit/Sources/SuflyorCamera/CaptureAudioSource.swift:93` — copies the samples out of the block buffer into the PCM buffer's audio buffer list.

### SuflyorImporters (6)

- `ios/Packages/SuflyorKit/Sources/SuflyorImporters/RtfImporter.swift:17` — CFStringConvertEncodingToNSStringEncoding + String(data:encoding:) for the DOS CJK code pages.
- `ios/Packages/SuflyorKit/Sources/SuflyorImporters/ScriptArchive.swift:133` — ZIPFoundation in-memory creation: `Archive(data:accessMode: .create)` and `archive.data`.
- `ios/Packages/SuflyorKit/Sources/SuflyorImporters/ScriptArchive.swift:137` — `addEntry(with:type:uncompressedSize:compressionMethod:provider:)` (Int64 size in 0.9.19).
- `ios/Packages/SuflyorKit/Sources/SuflyorImporters/XmlSupport.swift:102` — XMLParser keeps `xmlns`/`xmlns:p` in attributeDict when shouldProcessNamespaces is false.
- `ios/Packages/SuflyorKit/Sources/SuflyorImporters/ZipReading.swift:31` — ZIPFoundation 0.9.19: `Archive(data:accessMode:)` is a throwing init (older releases: failable);
- `ios/Packages/SuflyorKit/Sources/SuflyorImporters/ZipReading.swift:58` — `Archive.extract(_:bufferSize:skipCRC32:progress:consumer:)` with a throwing consumer.

### SuflyorPrompter (8)

- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/OverlayTargetLauncher.swift:23` — "instagram://camera" opens the in-app camera; plain "instagram://app" opens the app.
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/OverlayTargetLauncher.swift:25` — TikTok's scheme is "snssdk1233://" (global build), "tiktok://" on some versions; neither is documented.
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/PiPPrompter.swift:117` — C-style creation is deprecated on newer SDKs in favour of `CMTimebase(sourceClock:)`; both exist.
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/PiPPrompter.swift:133` — PiP needs an active session in one of these categories. With the microphone running (.playAndRecord) this
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/PiPPrompter.swift:361` — `enqueue(_:)` on the layer is the long-standing API; newer SDKs prefer `sampleBufferRenderer.enqueue(_:)`.
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/PiPPrompter.swift:412` — if the SDK marks `AVPictureInPictureSampleBufferPlaybackDelegate` / `AVPictureInPictureControllerDelegate`
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/PiPPrompter.swift:432` — a finite range keeps the skip buttons in the window (an infinite one means "live", without them).
- `ios/Packages/SuflyorKit/Sources/SuflyorPrompter/PiPPrompter.swift:452` — the `@Sendable` on the completion handler follows the iOS 26 SDK; drop it if the protocol has none.

### SuflyorSpeech (16)

- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:122` — `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` is async and returns AVAudioFormat?.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:137` — `AnalyzerInput(buffer:)` and `yield` taking a non-Sendable payload (`sending`) under Swift 6.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:187` — SpeechTranscriber and SpeechAnalyzer are Sendable, so the two tasks below may capture them.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:190` — `transcriber.results` is an AsyncSequence of results with `text` (AttributedString) and `isFinal`.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:202` — `start(inputSequence:)` returns once the analysis runs; it keeps consuming `stream`.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:221` — `cancelAndFinishNow()` is async on SpeechAnalyzer.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:233` — `AnalysisContext`, its `contextualStrings[.general]` and `SpeechAnalyzer.setContext(_:)`.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:64` — `SpeechTranscriber.supportedLocale(equivalentTo:)` (async, returns Locale?) on the iOS 26 SDK.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:66` — `SpeechTranscriber.supportedLocales` is an async static property returning [Locale].
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:74` — `SpeechTranscriber.installedLocales` is an async static property returning [Locale].
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/AppleSpeechAsr.swift:83` — `AssetInventory.assetInstallationRequest(supporting:)` and `downloadAndInstall()`.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/MicrophoneAudioSource.swift:186` — the Swift name of the notification (AVAudioEngineConfigurationChange) on the iOS 26 SDK.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/MicrophoneAudioSource.swift:74` — `.allowBluetoothHFP` (iOS 26 name of `.allowBluetooth`) as in docs/ios/contratos.md.
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/PCMConverter16k.swift:41` — AVAudioConverter downmixes N channels to mono by itself (stereo/USB inputs); if the init
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/SherpaAsr.swift:154` — the c-api.h types come from our CSherpaOnnx module; the xcframework's own SherpaOnnxC module declares
- `ios/Packages/SuflyorKit/Sources/SuflyorSpeech/SpeechPackStore.swift:247` — ZIPFoundation 0.9.19 API: throwing Archive(url:accessMode:), Sequence of Entry, extract(_:to:).

### core (Kotlin) (2)

- `core/src/commonMain/kotlin/com/olerast/suflyor/script/CharNorm.kt:30` — on iosSimulatorArm64 (CjkHebrewTest) check that Kotlin/Native reads the surrogate pairs in the class as one
- `core/src/iosMain/kotlin/com/olerast/suflyor/script/Unicode.ios.kt:9` — compiled with Kotlin/Native on Linux (klib only, not linked or run). The first Mac run of the common tests

## Regerar

```bash
grep -rn --include='*.swift' --include='*.kt' --include='*.yml' --include='*.sh' 'VERIFY:' ios core .github tools
```
