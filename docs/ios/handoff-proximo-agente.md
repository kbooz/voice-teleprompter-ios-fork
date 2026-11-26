# Handoff: migração do Suflyor para iOS

Para um agente novo continuar o trabalho. O usuário fala português (BR): responda e documente em português; comentários de código em inglês, curtos, explicando o porquê.

## Onde as coisas estão (não repetido aqui)

| O quê | Onde |
|---|---|
| Plano geral (arquitetura, 3 modos, fases, riscos) | `docs/plano-migracao-ios.md` |
| Contratos entre módulos e divisão em 5 pacotes (WP-A a WP-E) | `docs/ios/contratos.md` — fonte da verdade das APIs |
| Pontos a conferir na 1ª build no Mac (57 `// VERIFY:`) e ordem sugerida | `docs/ios/verificacao-mac.md` |
| Código | `core/` (Kotlin Multiplatform), `ios/` (app, extensões, `Packages/SuflyorKit`), `tools/ios/`, `.github/workflows/ios.yml` |
| Histórico | `git log` no branch abaixo (cada WP tem um commit de merge) |

Repositório: fork `kbooz/voice-teleprompter-ios-fork` (original: olerast67/voice-teleprompter-android, GPL-3.0). Branch de trabalho: **`ccr-10af803e-xmgrh6`**, tudo commitado e enviado (o handoff foi escrito com o branch em `43f570f`; o commit do próprio handoff vem depois). **Nenhum PR foi criado**: só crie se o usuário pedir. Não envie para outro branch sem permissão.

## Estado

Os 5 pacotes foram feitos por agentes Sonnet em paralelo (planejados por mim, o Opus) e já estão integrados:
- **A** núcleo KMP (`core/`), **B** app iOS, **C** voz e sessão, **D** teleprompter/Modo Câmera/PiP, **E** importadores, strings, scripts e CI.
- Não há agentes rodando.

**Verificado de verdade (neste container Linux):**
- `./gradlew --no-daemon -p core jvmTest`: 112 testes, 0 falhas, incluindo testes de paridade contra o JVM e contra a lógica do `SessionEngine` do Android.
- O núcleo compila para `iosArm64` e `iosSimulatorArm64` (`compileKotlinIos*`). A linkagem do XCFramework é pulada no Linux.
- Python: `tools/ios/test_convert_strings.py`, `convert_strings.py --check`, `check_speech_assets.py`, `ios/scripts/speech_pack_catalog.py --check`: tudo OK.
- YAML/plists/JSON do app abrem sem erro.

**Nunca verificado:**
- Nenhuma linha de Swift foi compilada nem executada (sem Xcode/Swift aqui).
- O build do app Android depois da extração do `core/` (`includeBuild("core")`) não foi testado (sem Android SDK).
- Os testes comuns do `core` ainda não rodaram no simulador iOS.

## Limites do ambiente

- Bloqueados pelo proxy: `dl.google.com` (Google Maven, SDK Android), `huggingface.co`, `download.swift.org`, downloads de releases do GitHub e `codeload.github.com`. Liberados: Maven Central, Gradle Plugin Portal, `services.gradle.org`, PyPI, `raw.githubusercontent.com`, e o `kotlin-native-prebuilt` pelo Maven Central.
- JDK 21 (sem toolchains do Gradle). O Maven Central às vezes devolve 429; repita o comando.
- Os worktrees dos agentes continuam em `.claude/worktrees/agent-*` (travados, branches locais `worktree-agent-*`). `.claude/` está em `.git/info/exclude` para não aparecer como não rastreado. Já estão integrados; podem ser removidos (`git worktree unlock` + `git worktree remove`) quando o usuário quiser.

## Pendências e decisões em aberto

**Dependem do usuário / de um Mac (candidatas ao skill `wizard`):**
1. **Licença:** GPL-3.0 é considerada incompatível com os termos da App Store. Publicar exige permissão escrita do autor original. Não é aconselhamento jurídico. Sem isso, só build próprio pelo Xcode.
2. Preencher `ORT_SHA256` (vazio de propósito) e confirmar `SHERPA_SHA256` com `ios/scripts/fetch-sherpa-onnx.sh --print-sha`.
3. Definir o prefixo do bundle id, o App Group e o `DEVELOPMENT_TEAM` (hoje placeholder `com.example.suflyor`, em `ios/project.yml` e em `AppConstants`). Trocar o ícone provisório.
4. Rodar `docs/ios/verificacao-mac.md` na ordem sugerida.
5. **Teste decisivo (spike da Fase 0 do plano):** num iPhone real, o microfone sobrevive no PiP enquanto Instagram/TikTok/Câmera gravam? Se não, o Modo Câmera é o caminho principal (já é o botão primário do app). Confirmar também os URL schemes de Instagram/TikTok.
6. Ajustar no `ios.yml` o rótulo do runner (`macos-26`), o caminho do Xcode e o simulador (`iPhone 17`): foram chutados.

**Trabalho de código que ficou para depois:**
- O `SessionEngine.kt` do Android ainda tem lógica própria; só há um TODO para passar a usar `CoreFollower`. Fazer isso exige o Android SDK.
- Teclas de mídia (`HardwareKey.mediaPlayPause/Next/Previous`) não estão ligadas: precisa de `MPRemoteCommandCenter`.
- O motor da Apple (`SpeechAnalyzer`) não tem fallback automático para o sherpa quando o idioma não é suportado; precisa de comparação de WER, latência e bateria antes de virar padrão.
- `AVAudioSession.mediaServicesWereReset` não é tratado. O app deve chamar `SessionEngine.releaseIdleRecognizer` em aviso de memória.
- O app (WP-B) usa `ScriptArchive.read`; poderia usar `readContents` e mostrar o contador `skipped`. O editor reimplementa o limite de 300.000 caracteres.
- PDF que o PDFKit não abre dá `.cannotOpen` (a mensagem do Android para `.pdfUnsupported` fala de versão do Android).
- Legendas queimadas no vídeo, apagar o filme temporário após compartilhar, frases de App Shortcuts só em inglês, `THIRD_PARTY_NOTICES.md` ainda precisa da versão final dos pacotes.
- `Localizable.xcstrings` é gerado: depois de mexer em `ios/Suflyor/Resources/ios-strings/*.json` ou nas strings do Android, rode `python3 tools/ios/convert_strings.py` e commite (o CI roda `--check`).

## Decisões e armadilhas que não estão óbvias no código

- **Contratos primeiro:** nenhum módulo muda a API de outro. `Package.swift` e `SuflyorDomain` são do arquiteto: mudanças vão por pedido e são aplicadas na integração.
- **Offsets de texto são UTF-16** em todo o limite Kotlin/Swift (`TextRange`, fim exclusivo). Emojis e caracteres suplementares já têm testes.
- **Nome duplicado:** o framework KMP e o objeto fachada se chamam `SuflyorCore`. Se o Swift resolver para o módulo, use `typealias KCore = SuflyorCore.SuflyorCore` (já previsto em `KMPScriptCore.swift`).
- **`package` access:** Camera usa helpers `package` do Prompter e os testes de sessão usam `package init`. Isso exige que SwiftPM passe `-package-name` (padrão). O `SessionEngine` tem um `init` público de 4 parâmetros para o app.
- **Tracker não foi alterado:** o algoritmo é o do Android movido com shims de portabilidade (`Normalizer`, `UnicodeScript`, `lowercase(Locale)`, pinyin gerado). Se um teste falhar, corrija o shim, nunca a expectativa. O Kotlin/Native pode seguir outra versão do Unicode que o JVM.
- **Microfone no Modo Câmera:** o mesmo áudio gravado alimenta o reconhecimento (`CaptureAudioSource`), sem segundo cliente de microfone. No PiP, interrupção de áudio faz o texto seguir por tempo, com aviso.
- **Sem rede no app:** o CI faz grep de APIs de rede em `ios/**/*.swift`. Pacotes de voz entram por Arquivos (o navegador baixa).
- **Commits:** terminam com as linhas `Co-Authored-By` e `Claude-Session` indicadas pelo system-reminder de atribuição vigente na sessão.

## Skills sugeridos para o próximo agente

Chame com a ferramenta Skill:
- `mattpocock-skills:diagnosing-bugs` — quando a 1ª compilação no Mac (ou o `swift test`) falhar: há 57 pontos duvidosos e erros de Swift 6 strict concurrency prováveis.
- `mattpocock-skills:wizard` — para guiar o usuário nos passos que só ele faz (hash do ONNX Runtime, bundle id, time de desenvolvimento, permissão do autor, TestFlight).
- `mattpocock-skills:tdd` — ao refatorar o `SessionEngine` do Android para usar `CoreFollower`, ou ao corrigir paridade do tracker.
- `code-review` (ou `mattpocock-skills:code-review`) — revisar cada WP contra `docs/ios/contratos.md` antes de qualquer PR.
- `security-review` — conferir privacidade (sem rede, `PrivacyInfo.xcprivacy`) e o tratamento de zips e XML dos importadores (limites, DOCTYPE).
- `mattpocock-skills:resolving-merge-conflicts` — se houver merge com o projeto original (olerast67), que mexe em arquivos já movidos para `core/`.
- `mattpocock-skills:domain-modeling` — se for registrar as decisões acima como ADRs.
