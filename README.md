# Libras Live

App nativo para macOS que ouve um canal de áudio da transmissão, transcreve a fala em português e mostra um avatar 3D sinalizando em Libras numa página que entra no OBS como **fonte de navegador**.

> Tradução automática tem limites e **não substitui intérprete de Libras**. Vale avisar isso na transmissão.

```
Canal de áudio ─► Fala→texto ─► Frases estáveis ─► Glosa (VLibras) ─► Fila ─► Overlay no OBS
 (Core Audio)     (SpeechAnalyzer)  (commit cedo)     (+ cache)       (atraso)   (avatar Unity)
```

## Requisitos

- macOS 26 ou superior, Apple Silicon
- Xcode 26 (Swift 6.2+), só para compilar
- Internet: a glosa vem da API pública do VLibras e os sinais animados vêm do dicionário do VLibras (com cache local)
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
| **Logs** | Sessão atual com resumo, salvar, sessões anteriores e apagar. |

Atalhos: **⌘L** começar/parar de ouvir, **⌘K** limpar fila, **⌘T** testar uma frase, **⌥⌘C** copiar a URL do overlay, **⇧⌘S** salvar o log, **⌘1…⌘6** trocar de tela e **⌘,** ajustes (prévia do avatar, ícone na barra de menus, logs e boas-vindas). O ícone na barra de menus também começa/para e mostra atraso e fila.

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
| Aparência | `LibrasCore/AvatarAppearance`, `LogoRenderer` | Gera o JSON do player (`cabelo`, `calca`, `camisa`, `corpo`, `iris`, `olhos`, `sombrancelhas`, `logo`, `pos`; formato lido dos metadados do build) e renderiza a logo no quadro de 500 × 500. |

Dados locais ficam em `~/Library/Application Support/LibrasLive/`: `gloss-cache.json`, `signs/`, `logs/` e `appearance/` (logo original, logo pronta e imagem transparente).

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

- `make test` roda os testes unitários: segmentação, fila, frases estáveis, overlays, protocolo, cache e política de origem.
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

Variáveis para abrir o app direto num estado (capturas de tela e testes de interface): `LIBRAS_SECTION` (`live`, `audio`, `avatar`, `obs`, `translation`, `logs`), `LIBRAS_ONBOARDING=1` com `LIBRAS_ONBOARDING_STEP` (1 a 4), `LIBRAS_OPEN_SETTINGS=1`, `LIBRAS_WINDOW_SIZE=1040x800` (tamanho da janela), `LIBRAS_SECTION_TOUR="audio:3,live:3"` (troca de tela sozinha) e `LIBRAS_BACKGROUND=1` (abre sem roubar o foco).

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

## Licenças

- Código deste projeto: defina a licença antes de publicar.
- Player VLibras (`Overlay/vlibras/`, baixado por `Scripts/fetch-vlibras.sh`): LGPL-3.0, © LAVID/UFPB. A licença acompanha os arquivos.
- A API de tradução e o dicionário são serviços públicos do VLibras.
