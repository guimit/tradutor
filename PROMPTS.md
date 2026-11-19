# Prompts para o Claude Code — App Mac de legendas com tradução ao vivo

Usa os prompts por ordem, um por sessão (ou `/clear` entre eles). Só avances quando o critério de "Pronto quando" estiver cumprido.
O prompt 0 cria o `CLAUDE.md`, que dá contexto a todas as fases seguintes.

---

## Prompt 0 — Contexto e CLAUDE.md

```
Vamos construir uma app nativa de macOS, em Swift e SwiftUI, que mostra legendas ao vivo, num overlay flutuante, de TODO o áudio que o Mac reproduz (calls, vídeos, etc.), com tradução ao vivo entre português, inglês e espanhol.

Antes de escrever código:
1. Corre `sw_vers`, `xcodebuild -version` e `swift --version` e diz-me o que tenho. Verifica se há Xcode completo (não só Command Line Tools). Se faltar algo, diz-me exatamente o que instalar.
2. Cria um CLAUDE.md na raiz com:
   - Objetivo do produto (acima).
   - Idiomas: pt (PT-PT e PT-BR), en, es. Origem com opção "Auto"; destino à escolha.
   - Pipeline: Áudio do sistema -> Transcrição em streaming -> Segmentação em frases -> Tradução -> Overlay.
   - Arquitetura: protocolos `AudioSource`, `TranscriptionEngine`, `TranslationEngine`, para os motores serem trocáveis.
   - Modelo de dados: `CaptionSegment { id, textoOriginal, idiomaDetetado, textoTraduzido?, idiomaDestino, confirmado, timestamp }`.
   - Regras: Swift concurrency (async/await, AsyncStream), sem dependências desnecessárias, código comentado onde a API for subtil, mínimo de macOS a decidir conforme o que tenho instalado.
   - Convenções: UI e comentários em português (pt-PT); nomes de código em inglês.
3. NÃO escrevas mais nada ainda. Mostra-me o CLAUDE.md e espera.
```
**Pronto quando:** o CLAUDE.md existe e a versão do macOS/Xcode está confirmada.

---

## Prompt 1 — Projeto base (menu bar app)

```
Lê o CLAUDE.md. Cria o projeto base da app "Tradutor" (nome provisório).

Requisitos:
- App de barra de menu (MenuBarExtra), sem ícone no Dock (LSUIElement = true).
- Usa XcodeGen (`project.yml`) para gerar o .xcodeproj, para o projeto ser reproduzível e versionável. Instala com brew se faltar. Se achares melhor outra abordagem, justifica antes.
- Alvo: macOS com o mínimo compatível com as APIs de que precisamos (ScreenCaptureKit, Translation). Confirma qual é, depois de veres o que tenho instalado.
- Entitlements e Info.plist: NSMicrophoneUsageDescription (para uso futuro) e a descrição de uso para gravação de ecrã/áudio do sistema. Sandbox desligado por agora; explica-me o impacto disto na distribuição.
- Estrutura de pastas: App/, Audio/, Transcription/, Translation/, Overlay/, Models/, Settings/.
- Menu com: Iniciar/Parar, Idioma de origem (Auto, Português, English, Español), Idioma de destino, Sair. Ainda sem lógica real.
- git init, .gitignore adequado, primeiro commit.

Compila com `xcodebuild` e confirma que corre. Diz-me como abrir e correr a app.
```
**Pronto quando:** a app compila e aparece só um ícone na barra de menu.

---

## Prompt 2 — Captação do áudio do sistema

```
Implementa a captação do áudio de sistema em Audio/.

- Protocolo `AudioSource` que expõe `AsyncStream<AudioChunk>` (PCM float 32, mono, 16 kHz, com timestamp) e métodos start()/stop().
- Implementação `SystemAudioSource` com ScreenCaptureKit (SCStream com capturesAudio = true, excludesCurrentProcessAudio = true para a app não captar o que ela própria emite). Faz a conversão e o resample para o formato acima.
- Pede e trata a permissão de "Gravação de Ecrã e Áudio do Sistema": deteta se falta, mostra um aviso claro com botão para abrir as Definições do Sistema no sítio certo, e lida com o caso de ser preciso reiniciar a app.
- Preparar a mistura opcional com o microfone no futuro (não implementar já).
- Debug: um comando no menu "Testar captação" que mostra o nível de áudio (medidor simples) e grava 10 s para um .wav em ~/Desktop para eu ouvir.

Verifica as APIs na documentação da versão do macOS que tenho (não assumas de memória) e testa o que for possível sem eu estar presente. Diz-me exatamente o que devo testar manualmente (ex.: abrir um vídeo no Safari e ver o medidor mexer).
```
**Pronto quando:** o WAV gravado tem o áudio do sistema (sem o teu microfone).

---

## Prompt 3 — Transcrição em streaming (pt/en/es)

```
Implementa a transcrição em Transcription/.

- Protocolo `TranscriptionEngine`: recebe `AsyncStream<AudioChunk>` e produz `AsyncStream<TranscriptionEvent>`, onde o evento é `.partial(texto, idioma)` ou `.final(texto, idioma, inicio, fim)`.
- Implementação principal `WhisperKitEngine` com WhisperKit (Swift Package):
  - streaming com janelas deslizantes e VAD para cortar silêncios;
  - deteção automática de idioma (pt/en/es) com estabilização: só mudar de idioma depois de 2 janelas consecutivas a concordarem;
  - modo de idioma fixo (pt/en/es) como alternativa;
  - para pt, deixar a variante PT-PT/PT-BR como definição (influencia o prompt inicial/vocabulário);
  - download do modelo na primeira utilização com barra de progresso; começa com um modelo pequeno (base/small) e deixa o modelo configurável; informa-me da latência medida no meu Mac.
- Segunda implementação opcional `AppleSpeechEngine` (SpeechAnalyzer/SpeechTranscriber), só se estiver disponível na minha versão do macOS. Se não estiver, deixa só o esqueleto com `#available`.
- Texto parcial deve ser instável e o final estável; nunca emitir finais duplicados.
- Janela de debug simples que mostra os eventos em tempo real (parcial a cinzento, final a preto), para eu testar antes do overlay.
- Testes unitários da lógica de estabilização de idioma e de deduplicação de finais (com áudio simulado).

Verifica a API atual do WhisperKit e do framework Speech na documentação antes de codar.
```
**Pronto quando:** falas em pt, en e es e a janela de debug mostra o texto certo com o idioma detetado.

---

## Prompt 4 — Overlay das legendas

```
Implementa o overlay em Overlay/.

- NSPanel sem borda, transparente, sempre por cima, não ativa (nonactivatingPanel), ignoresMouseEvents = true, collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]. Tem de aparecer também por cima de apps em ecrã inteiro e em todos os Spaces e monitores (segue o monitor principal por defeito; opção para escolher).
- Conteúdo em SwiftUI: 2 linhas no máximo, fundo semitransparente com cantos arredondados, texto com boa legibilidade. Mostra o texto parcial em cinzento claro e substitui pelo final sem a UI saltar (animação suave, altura estável).
- Definições (Settings/): tamanho da fonte, opacidade do fundo, posição (arrastar para reposicionar com um modo de edição que desativa o click-through temporariamente; guarda a posição), número de linhas.
- Modo de exibição: Só original / Só tradução / Ambos (a tradução ainda não existe, por isso mostra o original; deixa o código preparado).
- Esconder automaticamente após alguns segundos de silêncio.

Liga isto ao pipeline: AudioSource -> TranscriptionEngine -> Overlay. Botão Iniciar/Parar no menu controla tudo.
Diz-me como testar em: Safari com vídeo, uma call (Meet/Zoom/Teams) e um vídeo em ecrã inteiro.
```
**Pronto quando:** as legendas aparecem por cima de vídeo em ecrã inteiro, sem bloquear cliques.

---

## Prompt 5 — Tradução ao vivo

```
Implementa a tradução em Translation/.

- Protocolo `TranslationEngine` com `translate(texto, de, para) async throws -> String` e deteção de pares suportados.
- Implementação `AppleTranslationEngine` com a framework Translation da Apple (on-device). Verifica na documentação da minha versão do macOS como obter uma TranslationSession fora de uma view SwiftUI (se for preciso usar `.translationTask`, cria um host invisível). Trata o download dos pacotes de idioma (pt, en, es) com UI de progresso e explica-me o prompt que o sistema mostra.
- Estratégia de latência:
  1. mostrar o original parcial de imediato;
  2. traduzir só segmentos confirmados, ou blocos com ~6–10 palavras/pausa curta;
  3. substituir a tradução provisória quando chegar a versão final, sem saltos visuais;
  4. cancelar traduções obsoletas.
- Se origem == destino, não traduzir.
- Cache simples de traduções repetidas.
- Preparar `DeepLEngine` e `LLMTranslationEngine` como esqueletos atrás do protocolo (chave API guardada no Keychain), sem os ativar por defeito.
- Atualiza o overlay: modos Só original / Só tradução / Ambos funcionam de verdade; o menu permite escolher o idioma de destino.
- Mede e mostra no modo debug a latência: fala -> original -> tradução.

Testes: unitários para a lógica de segmentação/cancelamento. Diz-me que cenários testar manualmente (ex.: call em inglês com legendas em pt-PT).
```
**Pronto quando:** call em inglês aparece traduzida para português com atraso de poucos segundos.

---

## Prompt 6 — Barra de menu, atalhos e definições

```
Completa a experiência da app:

- Atalho global (configurável) para ligar/desligar as legendas; e outro para alternar entre Só original / Só tradução / Ambos.
- Janela de Definições com abas: Geral (iniciar no login), Idiomas (origem, destino, variante PT), Aparência (fonte, opacidade, posição), Motor (WhisperKit/Apple, modelo, motor de tradução), Avançado (debug de latência).
- Ícone da barra de menu que muda de estado (parado / a ouvir / a traduzir) e mostra o idioma detetado.
- Estados de erro claros: sem permissão, sem modelo descarregado, sem pacote de idioma, sem áudio há X segundos.
- Persistência das definições (UserDefaults/AppStorage).

Mantém tudo simples e consistente com o design nativo do macOS. No fim, faz um resumo do que mudou e do que ainda falta.
```
**Pronto quando:** consegues usar a app só com a barra de menu e os atalhos.

---

## Prompt 7 — Histórico e exportação

```
Adiciona histórico das transcrições.

- Guardar os `CaptionSegment` confirmados em armazenamento local (SwiftData ou SQLite), agrupados por sessão (início/fim, app de origem se detetável).
- Janela "Histórico" com lista de sessões, pesquisa, e vista da transcrição com original + tradução lado a lado.
- Exportar sessão para .txt, .md e .srt/.vtt (legendas com timestamps; original e traduzida como ficheiros separados).
- Opção em Definições para ativar/desativar o histórico e botão para apagar tudo (privacidade).
- Tudo local; nada sai do Mac, exceto se eu ativar um motor cloud.

Inclui testes para a geração de SRT/VTT (formatação de timestamps e quebras de linha).
```
**Pronto quando:** exportas uma call para SRT e abres o ficheiro no VLC com as legendas certas.

---

## Prompt 8 — Qualidade, desempenho e distribuição

```
Faz uma passagem de qualidade:

1. Desempenho: mede CPU/GPU/memória durante 30 min de uso contínuo; otimiza o que for preciso (tamanho da janela do Whisper, taxa de atualização do overlay, etc.).
2. Robustez: mudança de dispositivo de áudio (colunas -> auscultadores), ecrã a dormir/acordar, perda de permissão, mudança de monitor. A app deve recuperar sozinha.
3. Revê o código: remove duplicação, confirma que não há retain cycles nem tasks órfãs, garante cancelamento limpo ao parar.
4. Acessibilidade: contraste, VoiceOver nas definições, Reduce Motion.
5. Distribuição: explica-me as opções (assinatura com Developer ID + notarização para distribuir fora da App Store vs. App Store com sandbox) e os impactos das permissões de áudio do sistema em cada uma. Prepara o script de build/archive e o README com instruções.

Termina com uma lista priorizada de melhorias futuras (diarização, microfone em simultâneo, resumo de reuniões).
```

---

### Dicas de uso
- Corre cada prompt num git branch ou faz commit no fim de cada fase.
- Se o Claude Code assumir uma API "de memória", pede-lhe para verificar na documentação da tua versão do macOS.
- Os testes de áudio e permissões têm de ser feitos por ti no Mac; pede sempre um checklist manual no fim de cada fase.
