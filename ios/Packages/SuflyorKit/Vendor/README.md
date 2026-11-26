# Vendor: sherpa-onnx e ONNX Runtime para iOS

Esta pasta recebe os dois XCFrameworks estáticos que o pacote `SuflyorKit` usa como `binaryTarget`:

| Arquivo | O que é | Versão |
|---|---|---|
| `sherpa-onnx.xcframework` | API C do sherpa-onnx (o framework interno se chama `SherpaOnnxC`) | **v1.13.8**, a mesma do app Android |
| `onnxruntime.xcframework` | ONNX Runtime estático | **1.28.2** (o que o `build-ios.sh` do sherpa-onnx v1.13.8 usa) |

Os binários **não vão para o git** (`Vendor/*.xcframework` está no `.gitignore`). Só este README e a licença
(`LICENSE-sherpa-onnx.txt`, Apache-2.0) ficam versionados. O cabeçalho C está em `Sources/CSherpaOnnx/include/`.

## Opção 1: baixar os binários prontos (recomendado)

```sh
ios/scripts/fetch-sherpa-onnx.sh
```

O script baixa os dois zips das releases do GitHub, confere o SHA-256 **antes** de descompactar e instala em
`Vendor/`. É idempotente: se a versão fixada já estiver instalada, não faz nada (`--force` instala de novo).

**Primeira vez, num Mac:** o SHA-256 do ONNX Runtime ainda não está fixado no script (as releases do GitHub estavam
bloqueadas onde o script foi escrito), e por isso o script **recusa instalar**. Rode:

```sh
ios/scripts/fetch-sherpa-onnx.sh --print-sha
```

Ele baixa os dois zips e imprime `SHERPA_SHA256=...` e `ORT_SHA256=...`. Confira os valores nas páginas das releases e
cole no topo do script. O `SHERPA_SHA256` já vem preenchido com o `checksum` que o `Package.swift` do próprio
sherpa-onnx declara para a tag v1.13.8 (o checksum do SwiftPM é o SHA-256 do zip); o `--print-sha` serve para
confirmar.

Atenção ao ONNX Runtime: o `Package.swift` da tag `v1.28.2` do repositório `csukuangfj/onnxruntime-libs` ainda aponta
para os zips da release `v1.28.1` (checksum `992d8a0cc6014cccc3a7815c36bbff5e5a06833ea2c4d47dd43ef071f639cf9d` para o
iOS estático). O script usa a release `v1.28.2`, que é a que o `build-ios.sh` do sherpa-onnx v1.13.8 baixa. Se esse zip
não existir, a alternativa é a opção 2.

## Opção 2: compilar com o script oficial

Precisa de Xcode, CMake e cerca de 20 minutos.

```sh
git clone --branch v1.13.8 --depth 1 https://github.com/k2-fsa/sherpa-onnx.git
cd sherpa-onnx
./build-ios.sh
```

O script baixa o ONNX Runtime 1.28.2 sozinho (`SHERPA_ONNX_ONNXRUNTIME_VERSION` muda a versão). Ao final, copie:

```sh
cp -R build-ios/sherpa-onnx.xcframework                          <repo>/ios/Packages/SuflyorKit/Vendor/
cp -R build-ios/ios-onnxruntime/onnxruntime.xcframework          <repo>/ios/Packages/SuflyorKit/Vendor/
```

Compilar por conta própria dá binários diferentes dos oficiais (sem SHA-256 em comum): use só se a opção 1 não servir.

## Ligação

As bibliotecas são C++ estáticas. O alvo `CSherpaOnnx` precisa de `linkerSettings: [.linkedLibrary("c++")]` e, por causa
do ONNX Runtime, de `.linkedFramework("CoreML")`, `.linkedFramework("Foundation")` e `.linkedFramework("CoreFoundation")`
(são os mesmos ajustes dos `Package.swift` oficiais do sherpa-onnx e do onnxruntime-libs). Isso está no pedido de
mudança de contrato do WP-C, porque o `Package.swift` não é do WP-C.

## Licenças

sherpa-onnx: Apache-2.0 (`LICENSE-sherpa-onnx.txt`). ONNX Runtime: MIT. Os dois entram no `THIRD_PARTY_NOTICES.md`.
