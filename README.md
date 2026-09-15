# Libras Live

App nativo para macOS que ouve um canal de áudio da transmissão, transcreve a fala em português e mostra um avatar 3D sinalizando em Libras numa página que entra no OBS como **fonte de navegador**.

> Tradução automática tem limites e **não substitui intérprete de Libras**. Vale avisar isso na transmissão.

```
Canal de áudio ─► Fala→texto ─► Frases estáveis ─► [Reescrita com IA local] ─► Glosa (VLibras) ─► Fila ─► Overlay no OBS
 (Core Audio)     (SpeechAnalyzer)  (commit cedo)       (Ollama, opcional)        (+ cache)       (atraso)   (avatar Unity)
```

## Requisitos

- macOS 26 ou superior, Apple Silicon
- Xcode 26 (Swift 6.2+), só para compilar
- Internet: a glosa vem da API pública do VLibras e os sinais animados vêm do dicionário do VLibras (com cache local)
- Para a reescrita com IA: espaço para um modelo (2,5 GB no recomendado) e, de preferência, 16 GB de memória
- Node 22+ e Google Chrome, só para o teste de ponta a ponta

## Começando

```bash
make run
```

`make run` baixa o player do VLibras (versão fixada), compila, monta `build/Libras Live.app` e abre o app. Na primeira abertura, as boas-vindas pedem a permissão de microfone, ajudam a escolher o áudio e mostram a URL do OBS.

### No app

A janela segue o padrão do macOS 26 (Liquid Glass): barra lateral com as telas, barra de ferramentas com **Começar/Parar** e **Limpar fila**, e um inspetor com os detalhes da frase selecionada. As telas se reorganizam conforme a largura (a partir de 720 × 540): na tela **Ao vivo**, o avatar fica numa coluna ao lado, fica menor ao lado da fala ou sai de cena quando falta espaço.

| Tela | O que tem |
|---|---|
| **Ao vivo** | Atraso, velocidade, fila, sinalizadas e descartadas; a fala reconhecida agora; o histórico com a glosa de cada frase; a prévia do avatar e a troca rápida de personagem. O campo embaixo testa frases sem microfone. |
| **Áudio** | Dispositivo (ex.: *Soundcraft Ui24*), canais (clique nos números; vários canais são somados em mono), nível por canal para achar a voz, ganho e detector de voz. |
| **Avatar** | Personagem, legenda do próprio avatar, cores e logo, com prévia ao vivo. |
| **OBS** | URL para copiar, passo a passo, overlays conectados, fundo para chroma key, painel de diagnóstico e porta. |
| **Tradução** | Velocidade, fila (juntar frases, descartes), glosa, reconhecimento de fala e dicionário. |
| **IA local** | Liga a reescrita das frases com IA, escolhe o modo e o modelo, testa uma frase nos três modos, mostra os modelos recomendados para o seu Mac e gerencia os modelos (baixar, buscar, carregar, excluir). |
| **Logs** | Sessão atual com resumo, salvar, sessões anteriores e apagar. |

Atalhos: **⌘L** começar/parar de ouvir, **⌘K** limpar fila, **⌘T** testar uma frase, **⌥⌘C** copiar a URL do overlay, **⇧⌘S** salvar o log, **⌘1…⌘7** trocar de tela e **⌘,** ajustes (prévia do avatar, ícone na barra de menus, logs e boas-vindas). O ícone na barra de menus também começa/para e mostra atraso e fila.

Ajuste o **ganho** até o medidor ficar entre -30 e -10 dB quando alguém fala.

### Aparência do avatar

Na tela **Avatar**, ligue **Personalizar cores e logo**:

- **Cores:** camisa, calça, pele, cabelo, sobrancelhas, íris e branco dos olhos. Dá para usar o seletor ou digitar o código (`#RRGGBB`).
- **Logo:**
  - escolha entre **VLibras** (original), **Minha logo** ou **Sem logo**;
  - escolha o arquivo ou arraste a imagem; ela é encaixada no quadro de 500 × 500 que o avatar usa, com margem de 75 px;
  - use PNG com fundo transparente: o app avisa se a imagem tiver fundo.
- **Posição da logo:** **Peito**, **Centro** ou **Peito e centro**, com ajuste de **tamanho** e deslocamento **horizontal/vertical**.
- **Prévia ao vivo** do avatar dentro do app. Ela não conta como overlay na fila e é uma só para o app inteiro: trocar de tela não recarrega o boneco.

As mudanças chegam ao OBS na hora. Desligar a personalização, ou voltar para a logo do VLibras, recarrega o player por alguns segundos, porque o avatar só volta ao visual original assim.

Também dá para mudar pela API local, por exemplo num botão do Stream Deck:

```bash
curl -X POST http://127.0.0.1:8765/api/appearance -H 'Content-Type: application/json' -d '{"shirt":"#111111","logoMode":"custom","logoPosition":"center"}'
```

Os campos são opcionais: `enabled`, `shirt`, `pants`, `skin`, `hair`, `eyebrows`, `iris`, `eyes`, `logoMode` (`vlibras`, `custom`, `none`), `logoPosition` (`chest`, `center`, `centerAndChest`), `logoScale` (0,3–1), `logoOffsetX` e `logoOffsetY` (-1 a 1).

> A [personalização oficial do VLibras](https://vlibras.gov.br/doc/widget/functionalities/customize-avatar.html) é exclusiva de instituições parceiras (pedido pelo cgpsp@economia.gov.br). Aqui ela roda localmente: as cores entram pelo método `ApplyJSON` do próprio player (LGPL) e a logo é servida pelo app. Confirme com a equipe do VLibras antes de usar uma logo em transmissão pública.

### Reescrita com IA local

Opcional, desligada por padrão. Um modelo de linguagem rodando no próprio Mac revisa cada frase antes da tradução para Libras, para ela chegar ao avatar mais clara. Nada sai do Mac: o [Ollama](https://ollama.com) vem dentro do app, numa porta própria, com os modelos em `~/Library/Application Support/LibrasLive/ollama/`.

Três modos:

| Modo | O que faz | Exemplo (fala reconhecida → enviado ao tradutor) |
|---|---|---|
| **Fiel** | Corrige erros de transcrição, pontuação e concordância e completa lacunas óbvias. Mantém as palavras e a ordem. | "detalhes de cada eta" → "detalhes de cada etapa" |
| **Intermediário** | Também tira repetições, hesitações e muletas. Mantém o sentido. | "é uma palavra é uma parábola que reflete…" → "é uma palavra, é uma parábola que reflete…" |
| **Nova versão** | Reescreve em frases curtas e diretas, fáceis de sinalizar. | "passaremos muito mais tempo explicando e interpretando…" → "Vamos passar mais tempo explicando, interpretando e detalhando cada etapa." |

Como funciona na transmissão:

- O reconhecedor confirma a fala em pedaços de ~6 palavras (um a cada 3 ou 4 s na fala corrida). Revisar cada pedaço sozinho quase não muda nada, então a IA recebe trechos maiores. Em **O que vai para a IA** você escolhe:
  - **Até o ponto final** (padrão): a frase vai inteira quando o reconhecedor põe o ponto; frases com menos de 6 palavras juntam com a seguinte. Sem ponto, corta numa vírgula perto do **máximo de palavras** (30, podendo passar um pouco).
  - **Por palavras**: junta N palavras e espera um ponto final por mais algumas (**pode passar até**); sem ponto, corta na última vírgula dentro do limite.
  - **Pausa na fala** (2 s): silêncio no áudio com o texto parado fecha o trecho antes.
  - Numa sessão real, trechos de pedaço em pedaço tinham 6,8 palavras; até o ponto final ficam com ~22. O custo é a espera: a IA só recebe a frase quando ela termina (uns 9 a 10 s depois do começo, na fala corrida). A tela mostra a espera estimada e o trecho que está juntando.
- As duas frases anteriores vão junto como contexto (dá para desligar).
- Cada trecho tem um **tempo máximo** (3 s por padrão, para até 20 palavras; trechos maiores ganham proporcionalmente, até o dobro). Se passar, se a IA estiver atrasada ou se a resposta parecer inventada (palavras demais, de menos ou sentido diferente), vai o texto original. A tradução nunca fica esperando a IA.
- O histórico marca as frases com **IA · fiel**, **IA · ok** (mesmas palavras) ou **original** (com o motivo), mostra o que foi falado e o inspetor traz os detalhes.
- O log registra cada reescrita e o resumo do `.txt` traz quantas mudaram, o tempo médio e por que ficou o original.

Modelos recomendados para o MacBook Pro M1 Pro 16 GB (medidos reescrevendo frases reais das lives):

| Modelo | Download | Memória | Por frase | Resultado |
|---|---|---|---|---|
| `qwen3:4b-instruct-2507-q4_K_M` (recomendado) | 2,5 GB | 2,9 GB | ~1 s | Português natural, corrige sem inventar |
| `gemma4:e2b-it-qat` | 4,3 GB | 3,6 GB | ~0,8 s | Mais rápido; ótima nova versão, mas no modo fiel às vezes corta palavras |
| `qwen3.5:4b` | 3,4 GB | 3,1 GB | ~1,6 s | Corrige mais erros do reconhecedor, mais lento |

- Com o avatar sinalizando ao mesmo tempo, os tempos sobem cerca de 50%.
- Modelos de 1 B ou menos (`qwen3.5:0.8b`) erram e inventam. O `granite4.2:3b` é rápido, mas quase não mexe no texto. Os de 8 B ou mais passam de 3 s por frase.
- O motor desliga o raciocínio ("thinking") dos modelos que pensam; com ele ligado a resposta demora e às vezes nem chega.
- Depois de instalar uma versão nova, a primeira subida do motor pode levar uns 30 s: o macOS confere os executáveis do Ollama, que vêm assinados só localmente. Depois sobe em menos de 1 s, e carregar o modelo na memória leva de 2 a 9 s (o app faz isso ao ligar a reescrita).

Na tela **IA local** dá para buscar outros modelos em ollama.com, baixar qualquer versão pelo nome, tirar da memória e excluir. Versões `-mlx` e `nvfp4` não rodam no motor embutido. O motor fecha junto com o app, até se o app travar.

### Logs da live

A tela **Logs** grava cada sessão em `~/Library/Application Support/LibrasLive/logs/`: fala reconhecida, glosa, ajustes na glosa, envios ao avatar, descartes com motivo, sinais inexistentes e tempos.

- **Salvar log…** (⇧⌘S) grava dois arquivos: um `.txt` legível e um `.jsonl` com os dados completos para análise.
  - O resumo do `.txt` traz descartes, velocidade, espera na fila, frases por envio, origem dos trechos, tempo até a frase ficar pronta e tempo parado.
  - Depois do resumo vem a linha do tempo.
- **Sessões anteriores** podem ser salvas ou mostradas no Finder. Sessões em que o app só abriu e fechou, sem ouvir nem traduzir, são apagadas sozinhas.
- **Apagar todos os logs…** apaga tudo e começa um arquivo novo.

Para ler um `.jsonl` no terminal: `swift run libras-probe log arquivo.jsonl`.

### No OBS

1. **Fontes › + › Navegador**
2. URL: `http://127.0.0.1:8765/`
3. Largura × altura: `540 × 960` (vertical) ou `720 × 720`
4. Deixe desmarcado *"Desligar fonte quando não visível"*, para o avatar não recarregar ao trocar de cena

O fundo já é transparente. Parâmetros opcionais na URL:

| Parâmetro | Exemplo | Efeito |
|---|---|---|
| `bg` | `bg=00ff00` | Cor de fundo (chroma key, se preferir) |
| `avatar` | `avatar=hosana` | `icaro`, `hosana` ou `guga` |
| `subtitles` | `subtitles=1` | Legenda do próprio avatar |
| `debug` | `debug=1` | Painel com conexão, fala e glosa |

Você pode ter mais de um overlay aberto (duas cenas, um monitor no navegador). A fila só avança quando todos os overlays **visíveis** terminam. Abas em segundo plano rodam a ~0 fps e são ignoradas; o app mostra *"(1 oculto)"*.

### Dicas para a mesa (Ui24 e similares)

- Mande para o Mac um canal ou auxiliar **só de voz**, sem música nem retorno. Isso é o que mais melhora o reconhecimento.
- Use `make scan D='Soundcraft'` enquanto alguém fala para ver o pico de cada canal no terminal.
- O OBS e o Libras Live podem ler o mesmo dispositivo ao mesmo tempo.

## Como funciona

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

### Protocolo do WebSocket (`/ws`)

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

### API local

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

## Desenvolvimento

```bash
make test
```

```bash
make e2e
```

```bash
make burst
```

- `make test` roda os testes unitários: segmentação, fila, frases estáveis, reescrita (prompt, validação, agrupamento), leitura da busca do Ollama, overlays, protocolo, cache e política de origem.
- `make e2e` precisa do app aberto. Ele abre o overlay no Chrome headless, envia frases e mede o tempo até tocar e terminar.
- `make burst` manda 6 frases de uma vez para validar a aceleração e o descarte.

> `make e2e`, `make burst` e `make say` mandam frases para **todos** os overlays conectados, inclusive o do OBS. Com o OBS aberto, use a segunda instância isolada descrita abaixo.

Medir e simular:

```bash
make bench
```

```bash
swift run libras-probe simulate sessao.tsv --grid
```

- `make bench` mede quanto o avatar leva por tipo de glosa e velocidade. Precisa do app aberto; toca só na página headless, sem afetar o OBS.
- `simulate` reproduz uma sessão contra a fila com o modelo medido. O arquivo tem uma frase por linha, `HH:MM:SS<TAB>texto<TAB>glosa`. `--grid` compara combinações de ajustes e `--timeline` mostra cada envio.

Segunda instância isolada, para testar sem mexer no app aberto no OBS:

```bash
LIBRAS_PORT=8799 LIBRAS_SUPPORT_DIR=/tmp/libras-teste .build/debug/LibrasLive
```

```bash
node Scripts/e2e-overlay.mjs --port 8799 --burst
```

O motor de IA vem de `Scripts/fetch-ollama.sh` (`make ollama`): baixa o Ollama numa versão fixada, confere o SHA-256 e guarda em `Vendor/ollama` só o `ollama` e o `llama-server` de Apple Silicon (46 MB em vez de 500 MB). O `build-app.sh` copia para `Contents/Resources/ollama`.

Testar a reescrita sem abrir o app (usa o motor de `Vendor/` e os modelos do app):

```bash
swift run libras-probe rewrite "passaremos muito mais tempo explicando e interpretando os detalhes de cada eta."
```

Diagnóstico por linha de comando (`libras-probe`):

```bash
swift run libras-probe devices
```

```bash
swift run libras-probe scan "Soundcraft" 8
```

```bash
swift run libras-probe level "Soundcraft" 5 10
```

```bash
swift run libras-probe transcribe fala.aiff
```

```bash
swift run libras-probe listen "Soundcraft" 5 30
```

```bash
swift run libras-probe gloss "Bom dia a todos"
```

```bash
swift run libras-probe log sessao.jsonl
```

Os canais são numerados a partir de 1. Para gerar um áudio de teste: `say -v Luciana -o fala.aiff "Boa noite pessoal."`.

Variáveis para abrir o app direto num estado (capturas de tela e testes de interface): `LIBRAS_SECTION` (`live`, `audio`, `avatar`, `obs`, `translation`, `logs`), `LIBRAS_ONBOARDING=1` com `LIBRAS_ONBOARDING_STEP` (1 a 4), `LIBRAS_OPEN_SETTINGS=1`, `LIBRAS_WINDOW_SIZE=1040x800` (tamanho da janela), `LIBRAS_SECTION_TOUR="audio:3,live:3"` (troca de tela sozinha), `LIBRAS_BACKGROUND=1` (abre sem roubar o foco), `LIBRAS_AI_TEST=1`, `LIBRAS_AI_SEARCH=1` e `LIBRAS_AI_PULL=<modelo>` (tela IA local). `LIBRAS_OLLAMA_DIR` aponta para outra pasta de modelos e `LIBRAS_OLLAMA_BIN` para outro executável do Ollama.

Ícone e miniaturas:

- O ícone é um arquivo do Icon Composer (`Resources/AppIcon.icon`, com vidro Liquid Glass) gerado a partir das formas em `Sources/LibrasLive/Brand/BrandMark.swift`. Para regerar, veja o cabeçalho de `Scripts/render-icon.swift`. O `build-app.sh` compila o ícone e a cor de destaque com `actool`.
- As miniaturas dos personagens (`Resources/Avatars`) saem de `node Scripts/render-avatars.mjs --port 8799`, com uma instância isolada aberta.

Para editar o overlay sem remontar o app:

```bash
open --env LIBRAS_OVERLAY_DIR="$PWD/Overlay" "build/Libras Live.app"
```

### O que a segunda live mostrou (14/09, conteúdo técnico corrido)

- **Descartes caíram de 26% para 10%** com as frases juntas: 145 frases em 23 envios, 6,3 por envio.
- **Palavras cortadas** (`multipl`, `jogu`, `repetid`): a confirmação por "0,8 s sem atualização" disparava no meio da fala, porque o reconhecedor atualiza em rajadas de ~1 s. Foi reproduzido com áudio e corrigido com o detector de voz e o prefixo estável. No mesmo áudio técnico de 30 s, a regra antiga gerou 31 fragmentos, 10 com palavra cortada; a nova gerou 12 trechos completos.
- **Modelo de tempo recalibrado** com os envios reais no OBS: ≈ 1,2 s + 1,84 s × sinais ÷ velocidade, contra 2,0 + 2,3 no Chrome headless. O simulador reproduz a live com 21 descartes, contra 16 reais.
- **Condensar o texto com o modelo de linguagem do macOS** foi testado com trechos reais e rejeitado: ele bloqueou trechos religiosos, inventou conteúdo em fragmentos e levou até 8,8 s na primeira chamada.

### Por que o avatar descartava frases

Medições do avatar com `Scripts/bench-avatar.mjs` (Chrome headless):

| Glosa | 1× | 2× | 3× | 4× |
|---|---|---|---|---|
| 1 sinal | 4,06 s | 3,29 s | 2,82 s | — |
| 4 sinais | 11,99 s | 6,83 s | 5,07 s | 4,19 s |
| Palavra soletrada (11 letras) | 10,65 s | 7,75 s | 6,22 s | — |
| `NÃO_PRATICAR` (soletrado) vs `PRATICAR NÃO` | 9,93 / 6,59 s | 7,21 / 4,17 s | 5,82 / 3,28 s | — |

- Cada envio ao avatar tem **~2 s fixos de transição** (sair do descanso e voltar), que a velocidade não reduz. Por isso o boneco "parava" entre frases.
- Cada sinal custa ~2,3 s ÷ velocidade.
- Soletrar acelera pouco com a velocidade.

Simulação da pregação da live de 14/09 (43 frases em ~3 min, velocidade 2–3×) com `libras-probe simulate`. A configuração antiga deu 12 descartes na simulação, contra 11 na live real:

| Configuração | Descartadas | Atraso médio |
|---|---|---|
| Antes (v0.1) | 12 (28%) | 13,2 s |
| Juntar frases (envio de até 20 s) | 5 (12%) | 11,4 s |
| Juntar + descartar após 20 s | 2 (5%) | 15,7 s |
| Juntar + velocidade máxima 3,5× | 1 (2%) | 10,8 s |

### Medições (M1 Pro, macOS 26.6)

| Medição | Resultado |
|---|---|
| Frase confirmada após ser falada | ~1,4 s |
| Frase na fila → glosa enviada ao avatar | 0,02–0,12 s |
| Primeiro sinal concluído | ~3–4 s após a frase entrar |
| Rajada de 6 frases longas | atraso estimado de 33 s → 2× de velocidade, 3 tocadas e 3 descartadas |

## Limitações conhecidas

- **Qualidade:** a glosa do VLibras é automática. Nomes próprios e termos técnicos costumam sair soletrados.
- **Dependência do VLibras:** tradução e dicionário vêm dos servidores públicos. O cache reduz o impacto de uma queda, mas frases e sinais nunca vistos precisam de internet.
- **Página oculta:** o avatar só roda em fonte visível (OBS ou aba em primeiro plano). A prévia dentro do app pausa enquanto não aparece (outra tela aberta ou janela coberta) e volta na hora; o OBS não é afetado.
- **Uma voz por vez:** o reconhecedor não separa falantes. Some só os canais de quem fala.
- **Reescrita com IA:** a frase chega ao avatar depois de terminar de ser falada (espera pelo ponto final ou pelas palavras escolhidas) mais 1 a 2 s de resposta. Com a fila muito atrasada, as frases passam direto para não aumentar o atraso. A IA pode interpretar errado uma frase ambígua; o modo **Fiel** é o mais seguro.

## Licenças

- Código deste projeto: defina a licença antes de publicar.
- Player VLibras (`Overlay/vlibras/`, baixado por `Scripts/fetch-vlibras.sh`): LGPL-3.0, © LAVID/UFPB. A licença acompanha os arquivos.
- A API de tradução e o dicionário são serviços públicos do VLibras.
- Ollama (`Vendor/ollama/`, baixado por `Scripts/fetch-ollama.sh`, e dentro do app): MIT, com as licenças das dependências (llama.cpp, MLX e outras) na mesma pasta.
- Cada modelo tem a própria licença (ex.: Qwen: Apache 2.0; Gemma: termos de uso do Gemma). Confira em ollama.com antes de usar.
