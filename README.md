# Tradutor

App de barra de menus para macOS que mostra legendas ao vivo de **todo o áudio do Mac** (calls, vídeos, podcasts) num overlay flutuante, com tradução ao vivo entre português (PT-PT e PT-BR), inglês e espanhol. Tudo corre no Mac: transcrição com WhisperKit ou com o reconhecimento de fala da Apple, e tradução com a framework Translation.

## Requisitos

- macOS 26 ou posterior, Apple Silicon.
- Para compilar: Xcode 27 e [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Na primeira utilização a app descarrega:
  - o modelo Whisper escolhido (150–630 MB, para `~/Library/Application Support/Tradutor/Models`);
  - os idiomas de tradução (em Definições › Motor).

## Compilar e correr

```sh
xcodegen generate
xcodebuild -project Tradutor.xcodeproj -scheme Tradutor -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Tradutor.app
```

O `.xcodeproj`, o `Info.plist` e os entitlements são gerados a partir do `project.yml` e não são versionados.

### Testes

```sh
xcodebuild -project Tradutor.xcodeproj -scheme Tradutor -derivedDataPath build test
```

Os testes de integração usam os motores reais e descarregam modelos. Para os correr:

```sh
TEST_RUNNER_TRADUTOR_INTEGRATION=1 xcodebuild … test -only-testing:TradutorTests/TranscriptionIntegrationTests
```

### Argumentos de debug (só em Debug)

| Argumento | Efeito |
|---|---|
| `-TradutorAutoStart YES` | Inicia as legendas no arranque |
| `-TradutorAudioFile /caminho/fala.aiff` | Usa um ficheiro em vez do áudio do sistema (não precisa de permissão) |
| `-TradutorAudioFileLoop YES` | Repete o ficheiro sem fim (medições de desempenho) |
| `-TradutorEditOverlay YES` | Abre no modo de ajuste da posição |
| `-showLatency YES` | Mostra a latência no overlay |

Exemplo: `open build/Build/Products/Debug/Tradutor.app --args -TradutorAutoStart YES -TradutorAudioFile ~/fala.aiff`

## Utilização

- **⌃⌥L** liga e desliga as legendas.
- **⌃⌥M** alterna entre Só original, Só tradução e Original e tradução.
- Os atalhos mudam-se em Definições › Geral.
- O ícone da barra de menus mostra o estado (parado, a ouvir, a traduzir, problema) e o idioma detetado. O menu explica o que fazer quando há um problema.

### Permissões

| Permissão | Para quê | Quando é pedida |
|---|---|---|
| Gravação de Ecrã e Áudio do Sistema | Captar o áudio do Mac (ScreenCaptureKit) | Ao iniciar as legendas pela primeira vez |
| Itens de início de sessão | "Iniciar ao iniciar sessão" | Ao ligar a opção |

O macOS só aplica a permissão de Gravação de Ecrã depois de a app reabrir: o menu tem um botão para isso, e as legendas retomam sozinhas depois de reabrir.

## Distribuição

### As duas opções

| | **Developer ID + notarização** (fora da App Store) | **Mac App Store** |
|---|---|---|
| Conta | Apple Developer Program (99 USD/ano) | A mesma |
| Sandbox | Opcional (o projeto tem-na desligada) | Obrigatória |
| Revisão | Notarização automática (verificação de malware, minutos) | Revisão humana (dias), com as regras de privacidade da App Store |
| Distribuição | DMG no teu site; atualizações por tua conta (ex.: Sparkle) | Loja; atualizações automáticas |
| Áudio do sistema | ScreenCaptureKit funciona como está | ScreenCaptureKit é permitido na sandbox, mas a app tem de justificar o uso na revisão |

**Impacto nas permissões de áudio do sistema**

- **Em ambos os casos**, a captação passa pela permissão TCC de "Gravação de Ecrã e Áudio do Sistema". Não há forma de a evitar nem de a pedir em nome do utilizador.
- O pedido do sistema fala em gravar o ecrã, mesmo que a app só use o áudio. Isto assusta e convém explicá-lo no onboarding. O macOS também pode voltar a pedir confirmação periodicamente às apps que gravam o ecrã.
- **Assinatura estável:** o TCC associa a permissão à assinatura da app.
  - Com Developer ID (ou na App Store), a permissão mantém-se entre atualizações.
  - Com a assinatura ad-hoc de desenvolvimento, perde-se a cada build.
- **Alternativa a avaliar:** os *Core Audio process taps* (macOS 14.2+) captam só áudio, com uma permissão própria de "Gravação de Áudio do Sistema" e o texto do `NSAudioCaptureUsageDescription`, sem falar em ecrã.
  - Isto dá um pedido mais claro para o utilizador.
  - Seria uma nova implementação de `AudioSource`; o resto da app não muda.
  - O comportamento na sandbox da App Store tem de ser confirmado antes de escolher esse caminho.
- **Fora da App Store (Developer ID):**
  - É obrigatório o Hardened Runtime (já ligado no `project.yml`).
  - O microfone (para uma futura captação em simultâneo) precisa do entitlement `com.apple.security.device.audio-input` (já incluído) e do texto `NSMicrophoneUsageDescription`.
- **Na App Store**, a sandbox exige mudanças:
  - `com.apple.security.app-sandbox`.
  - `com.apple.security.network.client`, para descarregar os modelos Whisper.
  - `com.apple.security.device.microphone`, se for usado o microfone.
  - Os modelos passam a ficar no contentor da app (o caminho em Application Support muda sozinho).
  - O `AppRelauncher` lança `/bin/sh` para reabrir a app, o que tem de ser revisto.

**Recomendação:** começar com Developer ID + notarização.
- Não exige mudanças no código, e a permissão de áudio funciona sem surpresas.
- A versão para a App Store pode vir depois, com a sandbox ligada e testada a captação.

### Build com Developer ID

1. No Xcode › Settings › Accounts, adiciona a conta de programador e cria um certificado **Developer ID Application**.
2. Guarda as credenciais da notarização no Keychain. Basta fazer uma vez, com uma *app-specific password* criada em account.apple.com:
   ```sh
   xcrun notarytool store-credentials tradutor-notary --apple-id <email> --team-id <TEAMID>
   ```
3. Gera o DMG assinado, notarizado e com o ticket agrafado:
   ```sh
   DEVELOPMENT_TEAM=<TEAMID> scripts/build.sh --release
   ```
   O resultado fica em `build/dist/Tradutor-<versão>.dmg`.

Sem conta de programador, `scripts/build.sh` faz um build Release com assinatura ad-hoc em `build/dist/Tradutor.app`. Só serve para este Mac: noutro, o Gatekeeper bloqueia a app.

"Iniciar ao iniciar sessão" regista o caminho da app. Instala-a em `/Applications` antes de ligar a opção.

## Arquitetura

Áudio do sistema → transcrição em streaming → segmentação em frases → tradução → overlay. Os motores ficam atrás de protocolos (`AudioSource`, `TranscriptionEngine`, `TranslationEngine`). Os detalhes estão no [CLAUDE.md](CLAUDE.md).
