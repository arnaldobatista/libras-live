# Desenvolvimento

Ferramentas para compilar, testar, medir e diagnosticar o Libras Live. Para o fluxo de contribuição, veja o [CONTRIBUTING.md](../CONTRIBUTING.md).

## Compilar e testar

| Comando | O que faz |
|---|---|
| `make build` | Baixa o player do VLibras e o Ollama (se faltarem) e compila em debug |
| `make test` | Roda os testes unitários |
| `make app` | Monta `build/Libras Live.app` em release |
| `make run` | Monta e abre o app |
| `make zip` | Monta o app e gera `build/Libras-Live-<versão>.zip` com o SHA-256, como no release |
| `make dev` | Roda direto com `swift run` (debug, sem o .app) |

Os testes cobrem frases estáveis, segmentação, fila, otimização da glosa, reescrita (prompt, validação e agrupamento), leitura da busca do Ollama, overlays, protocolo, cache e política de origem. Nenhum teste usa a internet.

O player do VLibras e o Ollama não ficam no repositório:

- `Scripts/fetch-vlibras.sh` (`make vlibras`) baixa o player para `Overlay/vlibras/`, num commit fixado.
- `Scripts/fetch-ollama.sh` (`make ollama`) baixa o Ollama numa versão fixada, confere o SHA-256 e guarda em `Vendor/ollama/` só o `ollama` e o `llama-server` de Apple Silicon (46 MB em vez de 500 MB).
- O `build-app.sh` copia os dois para dentro do app e junta as licenças de terceiros em `Contents/Resources/Licenses/`.

Para trocar de versão, mude o commit ou a versão e o SHA-256 no script e rode com `--force`.

## Segunda instância isolada

Com o app aberto no OBS, os comandos que mandam frases (`make say`, `make e2e`, `make burst`) fazem o avatar sinalizar **na cena da transmissão**. Para testar, abra uma segunda instância com outra porta e outra pasta de dados:

```bash
LIBRAS_PORT=8799 LIBRAS_SUPPORT_DIR=/tmp/libras-teste .build/debug/LibrasLive
```

```bash
make e2e PORT=8799
```

A prévia do avatar dentro do app (WebKit) só funciona com o app montado como `.app`; rodando o executável solto, ela fica em branco.

## Testes de ponta a ponta e medições

Precisam do app aberto, de Node 22+ e do Google Chrome.

| Comando | O que faz |
|---|---|
| `make e2e` | Abre o overlay no Chrome headless, envia frases e mede o tempo até tocar e terminar |
| `make burst` | Manda 6 frases de uma vez para validar a aceleração e o descarte |
| `make bench` | Mede quanto o avatar leva por tipo de glosa e velocidade (toca só na página headless) |

Para reproduzir uma sessão contra a fila com o modelo de tempo medido:

```bash
swift run libras-probe simulate sessao.tsv --grid
```

O arquivo tem uma frase por linha: `HH:MM:SS<TAB>texto<TAB>glosa`. `--grid` compara combinações de ajustes e `--timeline` mostra cada envio.

## libras-probe

Diagnóstico por linha de comando. Os canais são numerados a partir de 1.

| Comando | O que faz |
|---|---|
| `swift run libras-probe devices` | Lista os dispositivos de áudio e canais |
| `swift run libras-probe scan "Soundcraft" 8` | Mostra o pico de cada canal por 8 s |
| `swift run libras-probe level "Soundcraft" 5 10` | Nível do canal 5 por 10 s |
| `swift run libras-probe listen "Soundcraft" 5 30` | Transcreve o canal 5 por 30 s |
| `swift run libras-probe transcribe fala.aiff` | Transcreve um arquivo de áudio |
| `swift run libras-probe gloss "Bom dia a todos"` | Traduz para glosa |
| `swift run libras-probe log sessao.jsonl` | Converte um log de sessão em texto legível |
| `swift run libras-probe rewrite "frase"` | Mostra a frase nos três modos da IA, com o motor de `Vendor/` e os modelos do app |

Para gerar um áudio de teste:

```bash
say -v Luciana -o fala.aiff "Boa noite pessoal."
```

## Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `LIBRAS_PORT` | Porta do servidor, sem mudar a salva nas preferências |
| `LIBRAS_SUPPORT_DIR` | Pasta de dados (caches, logs, aparência) |
| `LIBRAS_OVERLAY_DIR` | Pasta do overlay, para editar sem remontar o app |
| `LIBRAS_OLLAMA_DIR` | Pasta do motor de IA (modelos, chave e log) |
| `LIBRAS_OLLAMA_BIN` | Outro executável do Ollama |

Para editar o overlay e só recarregar a página:

```bash
open --env LIBRAS_OVERLAY_DIR="$PWD/Overlay" "build/Libras Live.app"
```

Estas abrem o app direto num estado, para capturas de tela e testes de interface:

| Variável | Efeito |
|---|---|
| `LIBRAS_SECTION` | Tela inicial: `live`, `audio`, `avatar`, `obs`, `translation`, `ai` ou `logs` |
| `LIBRAS_SECTION_TOUR` | Troca de tela sozinha, por exemplo `audio:3,live:3` |
| `LIBRAS_WINDOW_SIZE` | Tamanho da janela, por exemplo `1040x800` |
| `LIBRAS_WINDOW_FLOAT=1` | Janela acima das outras (com `LIBRAS_WINDOW_SIZE`); coberta, a prévia do avatar pausa |
| `LIBRAS_BACKGROUND=1` | Abre sem roubar o foco |
| `LIBRAS_ONBOARDING=1` e `LIBRAS_ONBOARDING_STEP` | Boas-vindas, no passo 1 a 4 |
| `LIBRAS_OPEN_SETTINGS=1` e `LIBRAS_SETTINGS_TAB=about` | Abre os Ajustes, na aba Sobre |
| `LIBRAS_AI_TEST=1`, `LIBRAS_AI_SEARCH=1`, `LIBRAS_AI_PULL=<modelo>` | Tela IA local: roda o teste, abre a busca ou baixa um modelo |

Para as capturas do README, rode uma cópia do app com outro `CFBundleIdentifier` (preferências separadas) e `-AppleAccentColor 7` nos argumentos: com um valor inválido, o app usa a própria cor de destaque, como para quem deixa a cor do sistema em **Multicolorido**.

## Ícone e miniaturas

- O ícone é um arquivo do Icon Composer (`Resources/AppIcon.icon`, com o vidro do Liquid Glass) gerado a partir das formas em `Sources/LibrasLive/Brand/BrandMark.swift`. Para regerar, veja o cabeçalho de `Scripts/render-icon.swift`. O `build-app.sh` compila o ícone e a cor de destaque com `actool`.
- As miniaturas dos personagens (`Resources/Avatars/`) saem de `node Scripts/render-avatars.mjs --port 8799`, com uma instância isolada aberta.

## Versões

1. Atualize `CFBundleShortVersionString` e `CFBundleVersion` em `Resources/Info.plist`.
2. Escreva a seção da versão no `CHANGELOG.md`.
3. Crie e envie a tag:

```bash
git tag v0.3.0 && git push origin v0.3.0
```

O workflow **Release** compila no macOS 26, confere se a tag bate com a versão do `Info.plist` e publica o `.zip` com o SHA-256 em Releases, com as notas da seção do `CHANGELOG.md`.

O app é assinado só localmente (ad-hoc). Sem a assinatura Developer ID e a notarização da Apple, quem baixa precisa liberar o app em **Privacidade e Segurança** na primeira abertura.
