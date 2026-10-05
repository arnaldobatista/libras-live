# Medições

Números medidos durante o desenvolvimento, com transmissões reais e testes de bancada, e o que eles mudaram no app. Tudo num MacBook Pro M1 Pro com 16 GB, macOS 26.

## Tempos do pipeline

| Medição | Resultado |
|---|---|
| Frase confirmada após ser falada | ~1,4 s |
| Frase na fila → glosa enviada ao avatar | 0,02–0,12 s |
| Primeiro sinal concluído | ~3–4 s após a frase entrar |
| Rajada de 6 frases longas | atraso estimado de 33 s → 2× de velocidade, 3 tocadas e 3 descartadas |

## Por que o avatar descartava frases

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

## O que a segunda live mostrou (14/09/2026, conteúdo técnico corrido)

- **Descartes caíram de 26% para 10%** com as frases juntas: 145 frases em 23 envios, 6,3 por envio.
- **Palavras cortadas** (`multipl`, `jogu`, `repetid`): a confirmação por "0,8 s sem atualização" disparava no meio da fala, porque o reconhecedor atualiza em rajadas de ~1 s. Foi reproduzido com áudio e corrigido com o detector de voz e o prefixo estável. No mesmo áudio técnico de 30 s, a regra antiga gerou 31 fragmentos, 10 com palavra cortada; a nova gerou 12 trechos completos.
- **Modelo de tempo recalibrado** com os envios reais no OBS: ≈ 1,2 s + 1,84 s × sinais ÷ velocidade, contra 2,0 + 2,3 no Chrome headless. O simulador reproduz a live com 21 descartes, contra 16 reais.

## Reescrita com IA local

### Modelos

Frases reais de duas transmissões (uma aula técnica e uma pregação), com o motor embutido, contexto de 2048 tokens e o raciocínio desligado. O tempo é por frase, com o modelo já carregado:

| Modelo | Download | Memória | Por frase | Resultado |
|---|---|---|---|---|
| `qwen3:4b-instruct-2507-q4_K_M` | 2,5 GB | 2,9 GB | ~1 s | Português natural; corrige a transcrição sem inventar. É o recomendado. |
| `gemma4:e2b-it-qat` | 4,3 GB | 3,6 GB | ~0,8 s | O mais rápido dos bons. Na nova versão, frases curtas e diretas; no modo fiel às vezes corta palavras. |
| `qwen3.5:4b` | 3,4 GB | 3,1 GB | ~1,6 s | Corrige mais erros do reconhecedor ("chatspots" → "chatbots"), mas é mais lento. |
| `granite4.2:3b` | 2,2 GB | — | ~0,7 s | Rápido, mas quase não mexe no texto. |
| `qwen3.5:0.8b` | 1,0 GB | — | ~0,4 s | Erra e inventa ("Uma prévia" → "Une prévia"; na nova versão, troca o sentido). |

- Com o avatar sinalizando ao mesmo tempo, os tempos sobem cerca de 50%.
- Modelos de 8 B ou mais passam de 3 s por frase nesse Mac.
- Os modelos que "pensam" (Qwen 3.5, Gemma 4, Granite 4.2) precisam de `think: false` na chamada. Com o raciocínio ligado, a resposta demora e, com o limite de tokens, às vezes chega vazia.
- O aquecimento e a reescrita usam o mesmo tamanho de contexto. Com valores diferentes, o Ollama recarrega o modelo (2 a 9 s) e a primeira frase estoura o prazo.
- O primeiro início de executáveis recém-copiados (app recém-instalado) leva uns 30 s, enquanto o macOS confere os arquivos. Depois, o motor sobe em menos de 1 s.

### O que vai para a IA

Na fala corrida, o reconhecedor confirma um pedaço de ~6 palavras a cada 3,8 s (mediana). Numa sessão real com a IA recebendo pedaço por pedaço, os trechos tinham **6,8 palavras** em média, e 62 de 93 voltaram iguais: um pedaço solto como "Não temos o direito de entregar" não tem o que corrigir.

A mesma sessão, simulada com as regras de agrupamento:

| Regra | Trechos | Palavras por trecho (média) | Espera até a IA receber (média) |
|---|---|---|---|
| Pedaço por pedaço (antes) | 93 | 6,8 | 1,2 s |
| Até o ponto final, máximo 30 | 31 | 21,9 | 10,1 s |
| Até o ponto final, máximo 20 | 38 | 17,9 | 8,1 s |
| 20 palavras, até +6 | 29 | 23,4 | 12,3 s |
| 12 palavras, até +6 | 41 | 16,6 | 8,4 s |

O padrão é **até o ponto final, máximo 30**: a frase vai inteira, que é o que a IA corrige melhor, e a espera fica perto do tempo de falar a frase.

### Alternativa descartada

**Condensar o texto com o modelo de linguagem do macOS** (Foundation Models) foi testado com trechos reais e rejeitado: ele bloqueou trechos religiosos, inventou conteúdo em fragmentos e levou até 8,8 s na primeira chamada.
