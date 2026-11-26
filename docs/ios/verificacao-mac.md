# Verificação no Mac

Situação em 26/11/2026, no Xcode 27.2 com o simulador iPhone 17 Pro: **tudo compila e todos os testes passam**. Dos 57 pontos `VERIFY` da primeira escrita, sobraram **20**: 17 dependem de aparelho físico, 1 depende de uma decisão sua e 2 são do CI.

## O que foi verificado

| Item | Resultado |
|---|---|
| `core` no JVM (`jvmTest`, **JDK 21**) | 114 testes, 0 falhas |
| `core` no simulador (`iosSimulatorArm64Test`) | 101 testes, 0 falhas (os 13 de paridade com o Java só rodam no JVM) |
| `SuflyorKit` (`swift test` pelo esquema `SuflyorKit-Package`) | 138 testes: Domain 15, Importers 47, Speech 23, Session 30, Prompter 23 |
| App, Share e Controls | `BUILD SUCCEEDED`, 0 warnings; o app abre no simulador sem crash |

## Como compilar do zero

```bash
ios/scripts/fetch-sherpa-onnx.sh                          # xcframeworks em Vendor/ (gitignored), verificados por SHA-256
./gradlew -p core assembleSuflyorCoreReleaseXCFramework   # o preBuildScript do Xcode também faz isso
mkdir -p ios/Suflyor/Models/asr-{ru,en,tr}                # build "lite": o xcodegen exige as pastas, mesmo vazias
(cd ios && xcodegen generate --spec project.yml)
(cd ios && xcodebuild -project Suflyor.xcodeproj -scheme Suflyor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO build)
(cd ios/Packages/SuflyorKit && xcodebuild -scheme SuflyorKit-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test)
```

Armadilhas:
- **JDK 21** para os testes do `core`. Os testes de paridade comparam tabelas Unicode com o JDK: com o JDK 17 (Unicode 13) falham 2, e com o JDK 25 (Unicode 16) falha 1. O código está certo; o que muda é a versão do Unicode.
- No Kotlin/Native, uma classe de regex não casa code points suplementares. Para Han isso não muda o resultado, e o `PortabilityShimTest` prova isso. A única diferença é uma letra suplementar (como 𝐀 matemático) no meio de uma palavra latina, que no iOS divide a palavra. Detalhes em `CharNorm.kt`.

## Pendências do usuário

- Bundle id (`com.example.suflyor`), App Group e `DEVELOPMENT_TEAM` em `ios/project.yml` e em `AppConstants`. Trocar também o ícone provisório.
- `ios/Suflyor/Intents/SuflyorShortcuts.swift:6`: as frases dos Atalhos estão só em inglês.
- A licença GPL-3.0 e a App Store (seção 9 do plano).

## Pontos para o iPhone físico (`VERIFY(device)`)

**Voz**
- `SuflyorSpeech/MicrophoneAudioSource.swift:30`: o tap converte o áudio e aloca memória. Conferir se há estalo ou áudio perdido.
- `SuflyorSpeech/AppleSpeechAsr.swift:196`: `start(inputSequence:)` continua consumindo o stream.
- `SuflyorSpeech/AppleSpeechAsr.swift:226`: as palavras do roteiro, passadas como contexto, melhoram o reconhecimento da Apple.

**Modo Câmera**
- `SuflyorCamera/CaptureAudioSource.swift:93`: cópia das amostras de áudio reais.
- `SuflyorCamera/CameraRecorder.swift:203`: espelhamento da câmera frontal.
- `SuflyorCamera/CameraRecorder.swift:230`: formato 1080p a 60 fps.
- `SuflyorCamera/CameraRecorder.swift:262`: ângulos do `RotationCoordinator` em cada orientação.
- `SuflyorCamera/CameraRecorder.swift:315`: rotação gravada no arquivo de vídeo.
- `SuflyorCamera/CameraScreen.swift:59`: botões de hardware (volume, Botão de Ação, Controle da Câmera, AirPods).
- `SuflyorCamera/CameraScreen.swift:368`: lado da lente em paisagem, nos dois sentidos.

**PiP e outros apps** (o teste decisivo da seção 4.4 do plano)
- `SuflyorPrompter/PiPPrompter.swift:132`: categoria da sessão de áudio com o microfone ativo. **Testar se o microfone sobrevive quando o Instagram, o TikTok ou a Câmera começam a gravar.**
- `SuflyorPrompter/PiPPrompter.swift:428`: os botões de pular aparecem na janela do PiP.
- `SuflyorPrompter/OverlayTargetLauncher.swift:23` e `:25`: URL schemes do Instagram e do TikTok.

**App**
- `ios/Suflyor/Screens/LibraryView.swift:290`: o `fileExporter` com documento opcional.
- `ios/Shared/SuflyorIntents.swift:36` e `:53`: `openAppWhenRun` no iOS 26.

## CI (fora do escopo desta rodada)

- `.github/workflows/ios.yml:36` e `:40`: o rótulo do runner, o caminho do Xcode 27 e o nome do simulador ainda são chutes. O CI também precisa do JDK 21 e do `mkdir` das pastas `asr-*` (ou do `fetch-speech-models.sh`).

## Regerar

```bash
grep -rn --include='*.swift' --include='*.kt' --include='*.yml' --include='*.sh' -E 'VERIFY(\((device|user)\))?:' ios core .github tools
```
