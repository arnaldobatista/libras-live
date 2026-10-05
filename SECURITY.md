# Segurança

## Como relatar uma vulnerabilidade

**Não abra uma issue pública.** Use o relato privado do GitHub: [Security → Report a vulnerability](https://github.com/arnaldobatista/libras-live/security/advisories/new). Só você e o mantenedor enxergam a conversa até a correção sair.

Conte o que acontece, como reproduzir e qual impacto você enxerga. O projeto é mantido no tempo livre, então a resposta pode levar alguns dias.

## Versões com correção

Só a versão mais recente, na branch `main`.

## O que interessa

O Libras Live roda um servidor HTTP e WebSocket no próprio Mac (`127.0.0.1:8765`) e, com a IA ligada, um motor Ollama numa porta própria. Por isso interessa principalmente:

- uma página aberta no navegador conseguir falar com o servidor do app: mandar frases, limpar a fila, mudar a aparência, ler o estado ou abrir o WebSocket;
- ler ou gravar arquivos fora das pastas do app pelas rotas do servidor (sinais e logo);
- o motor de IA embutido aceitar chamadas de outro computador ou de sites;
- o player do VLibras ou o Ollama serem trocados no download sem o build perceber.

Falhas do VLibras, do Ollama ou do OBS devem ir para os projetos deles.

## Como o Libras Live se protege

- O servidor escuta só em `127.0.0.1` e recusa requisições cujo `Host` não seja local, o que bloqueia *DNS rebinding*.
- `POST` e WebSocket só são aceitos de ferramentas locais (sem `Origin`) ou da própria origem do overlay. Todo `POST` exige `Content-Type: application/json`, o que obriga o navegador a pedir permissão (preflight de CORS) antes.
- Nomes de sinal aceitam só letras, números e os símbolos usados em glosas, e cada sinal vira um arquivo com nome codificado. A rota de aparência entrega só `logo.png` e `blank.png`.
- A logo enviada é desenhada de novo num PNG; o arquivo original nunca é servido.
- O motor de IA escuta só em `127.0.0.1`, mantém as proteções de origem do próprio Ollama e fecha junto com o app, mesmo se o app travar.
- O build baixa o player do VLibras num commit fixo e o Ollama numa versão fixa, conferida pelo SHA-256.
- Não há telemetria. Os logs, que contêm a fala transcrita, ficam no Mac.
