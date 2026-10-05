# Componentes de terceiros

O código do Libras Live está sob a [licença MIT](LICENSE). O app usa ou acompanha estes componentes, cada um com a própria licença. No app compilado, os textos das licenças e os avisos (`NOTICE`) ficam em `Libras Live.app/Contents/Resources/Licenses/`, e o **Ajustes › Sobre › Licenças** abre essa pasta.

## Distribuídos junto com o app

### Player do VLibras

- **O quê:** player Unity WebGL do avatar (Ícaro, Hosana e Guga), de [spbgovbr-vlibras/vlibras-web-browsers](https://github.com/spbgovbr-vlibras/vlibras-web-browsers), versão fixada no commit `6d6af49ac06b85e0dc22a601e66ef9a67b492f9a`.
- **Quem:** Suíte VLibras, desenvolvida pelo LAVID/UFPB com o Governo Federal.
- **Licença:** [GNU LGPL-3.0](https://www.gnu.org/licenses/lgpl-3.0.html).
- **Onde:** não fica neste repositório; o `Scripts/fetch-vlibras.sh` baixa para `Overlay/vlibras/`, e o app leva os arquivos sem modificação, com a licença, em `Contents/Resources/Overlay/vlibras/`. O código-fonte está no repositório original.
- As miniaturas dos personagens (`Resources/Avatars/`) e as capturas de tela em `docs/images/` mostram os avatares do VLibras.

### Ollama

- **O quê:** o servidor `ollama` e o `llama-server`, da versão [v0.34.0](https://github.com/ollama/ollama/releases/tag/v0.34.0), só a parte de Apple Silicon.
- **Licença:** [MIT](https://github.com/ollama/ollama/blob/main/LICENSE), © Ollama. Os executáveis incluem componentes com licenças próprias (llama.cpp e as bibliotecas que ele traz, cpp-httplib, fmt, picojson, Go, DLPack, XGrammar e MLX); os textos vêm do pacote oficial e ficam em `Contents/Resources/ollama/`.
- **Onde:** o `Scripts/fetch-ollama.sh` baixa o pacote oficial, confere o SHA-256 e guarda em `Vendor/ollama/`. A única mudança é separar a parte arm64 (`lipo -thin`) e assinar de novo, localmente.

### Bibliotecas Swift

Ligadas ao executável pelo Swift Package Manager (versões do `Package.resolved`):

| Pacote | Versão | Licença |
|---|---|---|
| [async-http-client](https://github.com/swift-server/async-http-client) | 1.36.1 | Apache-2.0 |
| [compress-nio](https://github.com/adam-fowler/compress-nio) | 1.4.2 | Apache-2.0 |
| [hummingbird](https://github.com/hummingbird-project/hummingbird) | 2.26.0 | Apache-2.0 |
| [hummingbird-websocket](https://github.com/hummingbird-project/hummingbird-websocket) | 2.7.0 | Apache-2.0 |
| [swift-algorithms](https://github.com/apple/swift-algorithms) | 1.2.1 | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.2 | Apache-2.0 |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | 1.1.5 | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 |
| [swift-certificates](https://github.com/apple/swift-certificates) | 1.20.0 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 |
| [swift-configuration](https://github.com/apple/swift-configuration) | 1.2.0 | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache-2.0 |
| [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing) | 1.4.1 | Apache-2.0 |
| [swift-http-structured-headers](https://github.com/apple/swift-http-structured-headers) | 1.7.0 | Apache-2.0 |
| [swift-http-types](https://github.com/apple/swift-http-types) | 1.8.0 | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | 1.15.1 | Apache-2.0 |
| [swift-metrics](https://github.com/apple/swift-metrics) | 2.11.0 | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio) | 2.102.0 | Apache-2.0 |
| [swift-nio-extras](https://github.com/apple/swift-nio-extras) | 1.35.1 | Apache-2.0 |
| [swift-nio-http2](https://github.com/apple/swift-nio-http2) | 1.46.0 | Apache-2.0 |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | 2.37.4 | Apache-2.0 |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | 1.28.0 | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 |
| [swift-service-context](https://github.com/apple/swift-service-context) | 1.3.0 | Apache-2.0 |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | 2.12.0 | Apache-2.0 |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 |
| [swift-websocket](https://github.com/hummingbird-project/swift-websocket) | 1.6.1 | Apache-2.0 |

## Usados pela internet, sem distribuição

- **API de tradução e dicionário de sinais do VLibras** (`traducao2.vlibras.gov.br` e `dicionario2.vlibras.gov.br`): serviços públicos do VLibras. O app manda o texto reconhecido para a tradução e baixa as animações dos sinais, que guarda em cache.
- **Modelos de linguagem** (Qwen, Gemma e outros): não vêm com o app. Você escolhe e baixa pela tela **IA local**, de [ollama.com](https://ollama.com/search). Cada modelo tem a própria licença ou os próprios termos de uso (por exemplo, Qwen: Apache-2.0; Gemma: [Termos de uso do Gemma](https://ai.google.dev/gemma/terms)); confira na página do modelo antes de usar.

## Marcas

VLibras, Ollama, OBS, macOS e os demais nomes citados pertencem aos respectivos donos. O Libras Live é um projeto independente, sem vínculo com o VLibras, o LAVID/UFPB, o Governo Federal, o Ollama ou o OBS.
