# Arquitetura

Como o Libras Live transforma a fala em sinais: as etapas, onde fica cada uma no código, os dados guardados no Mac e os protocolos entre o app e o overlay.

```
Canal de áudio ─► Fala→texto ─► Frases estáveis ─► [Reescrita com IA local] ─► Glosa (VLibras) ─► Fila ─► Overlay no OBS
 (Core Audio)     (SpeechAnalyzer)  (commit cedo)       (Ollama, opcional)        (+ cache)       (atraso)   (avatar Unity)
```

## Módulos

O pacote Swift tem estes alvos:

| Alvo | O que faz |
|---|---|
| `LibrasCore` | Regras sem dependência de sistema: frases estáveis, segmentação, fila de sinais, otimização da glosa, reescrita (prompt, validação e agrupamento), aparência, protocolo e formatação dos logs. É o alvo com mais testes. |
| `AudioCapture` | Dispositivos de áudio e captura por canal com Core Audio. |
| `Transcription` | Reconhecimento de fala com o `SpeechAnalyzer`. |
| `OverlayServer` | Servidor HTTP e WebSocket do overlay (Hummingbird), cache dos sinais e proteções do servidor local. |
| `LocalAI` | Motor Ollama embutido, cliente da API, busca em ollama.com e reescrita com prazo. |
| `LibrasLive` | O app: interface SwiftUI e orquestração (`AppModel`). |
| `LibrasProbe` | `libras-probe`, ferramenta de diagnóstico por linha de comando. |

## Etapas

| Etapa | Onde | Detalhes |
|---|---|---|
| Captura | `Sources/AudioCapture` | AUHAL com mapa de canais: o Core Audio entrega só os canais escolhidos. Soma em mono, ganho e medidor. Reinicia sozinho se o dispositivo cair ou mudar. `ChannelScanner` mede todos os canais para o seletor. |
| Fala→texto | `Sources/Transcription` | `SpeechAnalyzer` + `SpeechTranscriber` pt-BR, no próprio Mac. O áudio é convertido para o formato do reconhecedor fora da thread de áudio. |
| Frases estáveis | `LibrasCore/SpeechCommitController` | Decide quando a fala vira trecho, sem nunca cortar palavra. **Frase:** pontuação seguida de mais uma palavra. **Fala corrida:** palavras que não mudam há 1,2 s e já têm 3 palavras depois saem em blocos de ~6. **Pausa:** silêncio no áudio (detector de voz com piso de ruído adaptativo) e texto parado há 1,2 s. **Final** do reconhecedor. |
| Trechos | `LibrasCore/Segmenter` | Corta frases longas (padrão 14 palavras), preferindo vírgulas. |
| Glosa | `LibrasCore/GlossService` | `POST https://traducao2.vlibras.gov.br/translate` (~100 ms), cache LRU em memória e disco. Se a API falhar, tenta de novo antes de usar a glosa de emergência. |
| Glosa otimizada | `LibrasCore/GlossOptimizer` | Remove `[PONTO]` e repetições (`SENHOR SENHOR`). Troca compostos e palavras sem sinal por formas existentes no dicionário: `NÃO_PRATICAR` vira `PRATICAR NÃO`, `DISCERNIRMO` vira `DISCERNIR`, `QUANTA` vira `QUANTO`. Palavras sem sinal são soletradas só se forem curtas. Se a API falhar, tira artigos e preposições em vez de soletrar a frase inteira. |
| Fila | `LibrasCore/SignScheduler` | Mantém a ordem da fala e **junta as frases prontas num único envio** (até 20 s). Mede o atraso em segundos de sinalização. Com atraso, acelera, enxuga a glosa (pula palavras sem sinal e muletas), descarta primeiro repetições e só depois frases antigas. |
| Overlays | `LibrasCore/OverlayRoster` | Controla quem está pronto ou visível e quem ainda precisa terminar a glosa atual. |
| Servidor | `Sources/OverlayServer` | Hummingbird 2 em `127.0.0.1`: página, WebSocket, cache dos sinais em disco (com downloads deduplicados e pré-carregamento) e API. |
| Overlay | `Overlay/` | Player Unity WebGL do VLibras sem o widget, controlado por `overlay.js`. Detecta fim da reprodução por evento de estado e pelo contador de sinais, com vigia de 30 s. Aplica a aparência com `CustomizationBridge.ApplyJSON` e recarrega quando é preciso voltar ao original. Só mostra o canvas com o avatar pronto (esconde a tela branca de abertura do Unity). Na prévia do app, limpa o canvas com preto transparente para o WebKit não desenhar um contorno branco no avatar. |
| Reescrita | `LibrasCore/PhraseRewrite`, `LocalAI` | `RewriteBuffer` junta os trechos em frases, `RewritePrompt` monta as instruções de cada modo e `RewriteValidator` recusa respostas fora do formato, longas ou curtas demais ou que perderam as palavras do original. `OllamaEngine` sobe o `ollama serve` embutido sob um vigia em `sh` (fecha junto com o app), `OllamaClient` fala com a API, `PhraseRewriter` aplica o prazo e `OllamaLibrary` lê a busca de ollama.com. As frases passam pela IA uma de cada vez, na ordem da fala. |
| Aparência | `LibrasCore/AvatarAppearance`, `LogoRenderer` | Gera o JSON do player (`cabelo`, `calca`, `camisa`, `corpo`, `iris`, `olhos`, `sombrancelhas`, `logo`, `pos`; formato lido dos metadados do build) e renderiza a logo no quadro de 500 × 500. |

Dados locais ficam em `~/Library/Application Support/LibrasLive/`: `gloss-cache.json`, `signs/`, `logs/`, `appearance/` (logo original, logo pronta e imagem transparente) e `ollama/` (modelos, log do motor e chave do Ollama).

## Protocolo do WebSocket (`/ws`)

```jsonc
// app → overlay
{ "type": "gloss", "id": 42, "gloss": "BOM_DIA [PONTO]", "text": "Bom dia.", "speed": 1.2 }
{ "type": "config", "avatar": "icaro", "subtitles": false, "speed": 1, "signsBaseUrl": "http://127.0.0.1:8765/signs/",
  "appearance": "{\"camisa\":\"#111111\",…}", "appearanceRevision": 3, "appearanceReload": false }
{ "type": "caption", "text": "bom dia pes…", "final": false }
{ "type": "stop" }

// overlay → app
{ "type": "hello", "loaded": true, "visible": true }
{ "type": "ready", "visible": true }
{ "type": "visibility", "visible": false }
{ "type": "playing", "id": 42 }
{ "type": "progress", "counter": 1, "total": 2 }
{ "type": "ended", "id": 42, "reason": "done" }
```

## Rotas do servidor

O servidor escuta só em `127.0.0.1`, na porta 8765 (ou na escolhida em **OBS › Servidor**).

| Rota | Para quê |
|---|---|
| `GET /` | Página do overlay (`Overlay/index.html`, `overlay.js`, `overlay.css` e o player do VLibras) |
| `GET /ws` | WebSocket entre o app e cada overlay |
| `GET /signs/:nome` | Animação de um sinal, do cache local ou baixada do dicionário do VLibras |
| `GET /appearance/logo.png`, `/appearance/blank.png` | Logo da camisa do avatar e imagem transparente (sem logo) |
| `POST /api/say` | Injeta uma frase, como se tivesse sido falada |
| `POST /api/clear` | Limpa a fila e para o avatar |
| `POST /api/appearance` | Muda cores e logo |
| `GET /api/status` | Estado atual em JSON |

## API local

Útil para Stream Deck, automações e testes. Só aceita chamadas locais: `Host` precisa ser local, origens de outros sites são recusadas e `POST` exige JSON.

```bash
curl -X POST http://127.0.0.1:8765/api/say -H 'Content-Type: application/json' -d '{"text":"Bom dia a todos"}'
```

```bash
curl -X POST http://127.0.0.1:8765/api/clear -H 'Content-Type: application/json'
```

```bash
curl http://127.0.0.1:8765/api/status
```

Atalhos equivalentes: `make say T='Bom dia'`, `make clear` e `make status`.

Para mudar a aparência (os campos são opcionais):

```bash
curl -X POST http://127.0.0.1:8765/api/appearance -H 'Content-Type: application/json' -d '{"shirt":"#111111","logoMode":"custom","logoPosition":"center"}'
```

| Campo | Valores |
|---|---|
| `enabled` | `true` ou `false` |
| `shirt`, `pants`, `skin`, `hair`, `eyebrows`, `iris`, `eyes` | cor `#RRGGBB` |
| `logoMode` | `vlibras`, `custom` ou `none` |
| `logoPosition` | `chest`, `center` ou `centerAndChest` |
| `logoScale` | 0,3 a 1 |
| `logoOffsetX`, `logoOffsetY` | -1 a 1 |

### Proteções do servidor local

Páginas abertas no navegador conseguem fazer requisições para `127.0.0.1`. Por isso o servidor:

- recusa requisições cujo `Host` não seja local, o que bloqueia *DNS rebinding*;
- só aceita `POST` e WebSocket vindos de ferramentas locais (sem `Origin`) ou da própria origem do overlay;
- exige `Content-Type: application/json` nos `POST`, o que obriga o navegador a pedir permissão (preflight de CORS) antes;
- aceita como nome de sinal só letras, números e os símbolos usados em glosas, e guarda cada sinal num arquivo com nome codificado.

O motor de IA escuta em outra porta de `127.0.0.1` e usa as proteções do próprio Ollama contra origens de fora.
