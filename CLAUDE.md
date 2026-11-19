# Tradutor — legendas ao vivo para macOS

## Objetivo do produto
App nativa de macOS (Swift + SwiftUI) que mostra legendas ao vivo, num overlay flutuante, de **todo** o áudio que o Mac reproduz (calls, vídeos, etc.), com tradução ao vivo entre português, inglês e espanhol.

## Ambiente
- Desenvolvimento: macOS 27.2.1, Xcode 27.2, Swift 6.4.2, Apple Silicon.
- **Deployment target: macOS 26.0.** É a versão mínima com todas as APIs que usamos (ScreenCaptureKit com áudio, Translation com `TranslationSession` fora de SwiftUI, SpeechAnalyzer). Não é preciso `#available` para estas APIs.
- Swift 6 language mode (strict concurrency).

## Idiomas
- Suportados: **pt** (variantes **PT-PT** e **PT-BR**), **en**, **es**.
- Origem: `Auto` (deteção automática) ou fixa (pt / en / es).
- Destino: escolhido pelo utilizador. Se origem == destino, não se traduz.
- A variante de pt é uma definição (afeta vocabulário/prompt da transcrição e a tradução). Atenção: nem todos os motores suportam PT-PT; confirmar o suporte real de cada motor antes de assumir.
  - WhisperKit: não tem variantes; a variante entra como prompt inicial com vocabulário típico.
  - Apple SpeechTranscriber: suporta `pt-PT` e `pt-BR` como locales distintos (confirmado no macOS 27.2). Não deteta o idioma: exige origem fixa.

## Pipeline
Áudio do sistema → Transcrição em streaming → Segmentação em frases → Tradução → Overlay

1. **Áudio do sistema**: PCM float32, mono, 16 kHz, com timestamp. Excluir o áudio da própria app.
2. **Transcrição em streaming**: eventos parciais (instáveis) e finais (estáveis, nunca duplicados).
3. **Segmentação em frases**: junta/corta texto em segmentos confirmados (pausa, pontuação ou ~6–10 palavras).
4. **Tradução**: só de segmentos confirmados; cancela traduções obsoletas; cache de repetidos.
5. **Overlay**: `NSPanel` não ativo, click-through, por cima de tudo (incluindo ecrã inteiro e todos os Spaces).

## Arquitetura
Os motores são trocáveis através de protocolos:

- `AudioSource` — expõe `AsyncStream<AudioChunk>`; `start()` / `stop()`.
- `TranscriptionEngine` — recebe `AsyncStream<AudioChunk>` e produz `AsyncStream<TranscriptionEvent>` (`.partial` / `.final`).
- `TranslationEngine` — `translate(_:from:to:) async throws -> String` e consulta de pares suportados.

As implementações concretas (ex.: `SystemAudioSource`, `WhisperKitEngine`, `AppleSpeechEngine`, `AppleTranslationEngine`) ficam atrás destes protocolos. O resto da app só conhece os protocolos.

Transcrição em streaming: os motores "por lotes" (Whisper) implementam `SpeechRecognizer` e o `StreamingTranscriber` trata das janelas deslizantes, VAD (`SpeechActivityDetector`), estabilização de idioma (`LanguageStabilizer`) e deduplicação de finais (`FinalDeduplicator`). Esta lógica não depende do WhisperKit e é testada com áudio sintético.

Dependências externas: só o **WhisperKit** (versão fixa no `project.yml`), importado com `@preconcurrency` porque ainda não está anotado para Swift 6. Modelos em `~/Library/Application Support/Tradutor/Models`.

Estrutura de pastas: `App/`, `Audio/`, `Transcription/`, `Translation/`, `Overlay/`, `Models/`, `Settings/`.

## Modelo de dados
```swift
struct CaptionSegment: Identifiable, Sendable {
    let id: UUID
    var originalText: String          // textoOriginal
    var detectedLanguage: Language    // idiomaDetetado
    var translatedText: String?       // textoTraduzido (nil até haver tradução)
    var targetLanguage: Language      // idiomaDestino
    var isConfirmed: Bool             // confirmado (final vs. parcial)
    let timestamp: Date
}
```
(Nomes de código em inglês; entre parênteses o nome do conceito em pt.)

## Regras
- **Swift concurrency**: `async/await`, `AsyncStream`, actors. Nada de callbacks/Combine quando houver alternativa async. Cancelamento limpo ao parar (sem tasks órfãs).
- **Sem dependências desnecessárias**: preferir frameworks da Apple. Cada dependência externa (ex.: WhisperKit) tem de ser justificada.
- **Comentar onde a API for subtil** (ex.: formatos de áudio, permissões TCC, comportamento de janelas, threads/actors). Não comentar o óbvio.
- **Verificar APIs na documentação/SDK instalado** (macOS 26+/Xcode 27) em vez de assumir de memória.
- Tudo processado localmente por defeito; motores cloud só se o utilizador os ativar.
- Ao fim de cada fase: compilar com `xcodebuild` e dar um checklist de testes manuais (áudio e permissões têm de ser testados pelo utilizador).

## Build
- O `.xcodeproj`, o `Info.plist` e os entitlements são gerados pelo XcodeGen a partir de `project.yml` (não versionados). Alterações de configuração fazem-se no `project.yml`.
- Gerar: `xcodegen generate`
- Compilar: `xcodebuild -project Tradutor.xcodeproj -scheme Tradutor -configuration Debug -derivedDataPath build build`
- Correr: `open build/Build/Products/Debug/Tradutor.app`
- Testes (Swift Testing, em `TradutorTests/`): `xcodebuild -project Tradutor.xcodeproj -scheme Tradutor -derivedDataPath build test`
- Testes de integração (motores reais + fala do `say`; descarregam modelos): prefixar com `TEST_RUNNER_TRADUTOR_INTEGRATION=1` (e opcionalmente `TEST_RUNNER_TRADUTOR_WHISPER_MODEL=small|large`) e usar `-only-testing:TradutorTests/TranscriptionIntegrationTests`.
- Se um teste falhar, o XCTest pode ficar vários minutos a simbolizar a pilha (o binário de debug com WhisperKit é grande). Usar `timeout` nos comandos de teste.
- Assinatura ad-hoc (sem Apple ID/equipa configurada): a permissão de Gravação de Ecrã pode ter de ser dada de novo após cada build.

## Convenções
- UI e comentários em **português (pt-PT)**.
- Nomes de código (tipos, funções, variáveis, ficheiros) em **inglês**.
