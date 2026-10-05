# Mudanças

As mudanças relevantes de cada versão ficam registradas aqui. O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e as versões seguem o [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [0.3.0] — 2026-10-05

Primeira versão pública.

### Projeto

- Código aberto sob a licença MIT, com a lista de componentes de terceiros em `THIRD_PARTY_NOTICES.md`.
- README para quem chega, documentação técnica em `docs/` (arquitetura, desenvolvimento e medições), guia de contribuição e política de segurança.
- Modelos de issue e de pull request.
- Verificação automática (compilação e testes no macOS 26) em cada push e pull request, e publicação do app pronto em Releases a cada tag de versão.

### App

- As licenças de terceiros vão dentro do app. **Ajustes › Sobre** abre a pasta, o código-fonte e a página para relatar problemas.
- Correção de um aviso de compilação do Xcode 27 na leitura de propriedades do Core Audio.

## 0.2.1 — 2026-09-15

### IA local

- Controle do que vai para a IA: a frase inteira até o ponto final (padrão) ou um número de palavras, com uma folga para terminar no ponto. Uma pausa real na fala fecha o trecho antes.
- A tela mostra a espera estimada e o trecho que está juntando.
- Trechos longos ganham mais tempo antes de a IA desistir, até o dobro do tempo máximo.
- O log registra as palavras de cada trecho e a resposta da IA quando ela é recusada.

## 0.2.0 — 2026-09-15

### IA local

- Reescrita das frases antes da tradução, com um modelo de linguagem rodando no Mac, em três modos: fiel, intermediário e nova versão.
- Ollama embutido no app, numa porta própria, com os modelos na pasta do app. Fecha junto com o app, mesmo se ele travar.
- Tela **IA local**: modo, modelo, tempo máximo, teste nos três modos, modelos recomendados para o Mac, busca em ollama.com, downloads com progresso, carregar, tirar da memória e excluir.
- Validação de cada resposta: se a IA passar do tempo ou a resposta parecer inventada, vai o texto original.
- Histórico e inspetor mostram o que a IA mudou; o log traz o resumo das reescritas.

## 0.1.0 — 2026-09-14

Primeira versão. As versões 0.1 e 0.2 foram usadas antes da abertura do código e não têm release.

- Captura de qualquer entrada de áudio do Mac, por canal, com nível de cada canal, ganho e detector de voz.
- Reconhecimento de fala em português no próprio Mac, com confirmação das frases sem cortar palavras.
- Tradução para glosa pela API do VLibras e sinais do dicionário do VLibras, com cache local.
- Fila que junta frases, acelera o avatar quando atrasa e descarta repetições e frases antigas.
- Overlay para o OBS com fundo transparente, três personagens e suporte a vários overlays.
- Cores e logo do avatar, com prévia ao vivo e API local.
- Logs de sessão com resumo, exportação em `.txt` e `.jsonl`.
- Interface no padrão do macOS 26 (Liquid Glass), adaptável ao tamanho da janela, com boas-vindas, atalhos e ícone na barra de menus.
- `libras-probe`, ferramenta de diagnóstico por linha de comando.

[0.3.0]: https://github.com/arnaldobatista/libras-live/releases/tag/v0.3.0
