# Contribuindo com o Libras Live

Obrigado pelo interesse. O Libras Live é um app nativo em Swift com poucas dependências: Hummingbird para o servidor local e swift-log. As contribuições mais fáceis de aceitar são as que mantêm isso.

## Antes de começar

- **Encontrou um problema?** Abra uma issue com o modelo **Problema**. A versão do app (**Ajustes › Sobre**), o Mac e o resumo do log da sessão (**Logs › Salvar log…**) resolvem metade dos casos. Revise o log antes de colar: ele traz a fala transcrita.
- **Glosa ou sinal errado?** A tradução e os sinais vêm do VLibras. Se `swift run libras-probe gloss "a frase"` também devolve a glosa errada, o lugar certo é a [equipe do VLibras](https://vlibras.gov.br).
- **Mudança grande ou recurso novo?** Abra uma issue antes do pull request para combinar o caminho. Evita trabalho jogado fora dos dois lados.

## Ambiente

Os requisitos são os mesmos do [README](README.md#requisitos): Mac com Apple Silicon, macOS 26 ou mais novo e Xcode 26 ou mais novo. Os testes de ponta a ponta precisam também de Node 22+ e do Google Chrome.

```bash
git clone https://github.com/arnaldobatista/libras-live.git
```

```bash
cd libras-live && make run
```

## O ciclo de edição

| Mexeu em | Para a mudança valer |
|---|---|
| `Sources/` | `make run` monta e abre o app de novo |
| `Overlay/` (a página do avatar) | abra o app com `LIBRAS_OVERLAY_DIR` apontando para a pasta e recarregue a página (no OBS, **Atualizar cache da página atual**) |
| `Resources/` (ícone, `Info.plist`, miniaturas) | `make run` |

Rode o executável solto (`.build/debug/LibrasLive`) só para testes rápidos: a prévia do avatar só funciona com o app montado como `.app`.

Para depurar:

- **App:** a tela **Logs** mostra cada evento da sessão, e `make status` mostra o estado em JSON.
- **Overlay:** `?debug=1` no fim da URL mostra a conexão, a fala e a glosa sobre o avatar. A mesma URL no Chrome abre com o DevTools.
- **IA local:** **IA local › Motor › Ver log** abre o log do Ollama embutido.

Com o OBS aberto, os comandos que mandam frases fazem o avatar sinalizar na cena da transmissão. Use a [segunda instância isolada](docs/desenvolvimento.md#segunda-instância-isolada).

## Verificações

A integração contínua roda estas verificações em todo pull request. Rode antes na sua máquina:

```bash
swift build
```

```bash
swift test
```

Elas não abrem o app. Mexeu na fila, no servidor ou no overlay? Rode também `make e2e` com o app aberto. Mexeu na interface? Confira as telas em várias larguras e alturas de janela, a partir de 720 × 540.

## Estilo

- **Código, comentários, interface e mensagens em português**, como o resto do projeto.
- Comentários explicam **por quê**, não o quê, principalmente quando a razão é um comportamento do macOS, do VLibras, do Unity ou do Ollama que ninguém adivinharia lendo o código.
- Regras que não dependem do sistema ficam em `LibrasCore`, com testes (Swift Testing).
- Nada de dependências novas sem conversar antes.
- A thread principal fica livre: a interface não pode travar durante uma transmissão.
- Indentação de 4 espaços no Swift e 2 no resto; o `.editorconfig` cuida disso.

## Pull requests

- Um assunto por pull request.
- Diga o que mudou, por quê e como você testou: Mac, versão do macOS, áudio usado e, se ajudar, um trecho do log.
- Mudou algo visível para quem usa? Atualize o `README.md` e o `CHANGELOG.md`.

Ao enviar uma contribuição, você concorda que ela seja distribuída sob a [licença MIT](LICENSE) do projeto.
