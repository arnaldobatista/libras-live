#!/usr/bin/env bash
# Baixa o Ollama (MIT) em versão fixada para Vendor/ollama, só com o que roda em Apple Silicon:
# o servidor `ollama` e o `llama-server` que ele usa para os modelos GGUF, com Metal.
# Fica de fora o que é de Intel e o motor MLX (versões "-mlx" dos modelos).
# Fonte: https://github.com/ollama/ollama/releases
set -euo pipefail

VERSION="${OLLAMA_VERSION:-0.34.0}"
SHA256="${OLLAMA_SHA256:-dd12b00bcce2d6551178e67ada90d5af9f75bdb54a118b96655250fa3e8ef734}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/ollama"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" && "${1:-}" != "--force" ]]; then
  echo "Ollama já está em $DEST ($VERSION)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Baixando Ollama $VERSION..."
curl -fL --progress-bar -o "$TMP/ollama-darwin.tgz" "https://github.com/ollama/ollama/releases/download/v$VERSION/ollama-darwin.tgz"
echo "$SHA256  $TMP/ollama-darwin.tgz" | shasum -a 256 -c - >/dev/null
mkdir -p "$TMP/x"
tar -xzf "$TMP/ollama-darwin.tgz" -C "$TMP/x"

rm -rf "$DEST"
mkdir -p "$DEST"
for binary in ollama llama-server; do
  lipo "$TMP/x/$binary" -thin arm64 -output "$DEST/$binary"
done
# Separar a arquitetura invalida a assinatura original: assina de novo (ad-hoc).
codesign --force --sign - --timestamp=none "$DEST/ollama" "$DEST/llama-server" 2>/dev/null
find "$TMP/x" -maxdepth 1 \( -name '*LICENSE*' -o -name '*NOTICE*' \) -exec cp {} "$DEST/" \;
curl -fsSL -o "$DEST/OLLAMA_LICENSE" "https://raw.githubusercontent.com/ollama/ollama/v$VERSION/LICENSE"
echo "$VERSION" > "$DEST/VERSION"

echo "OK: $(du -sh "$DEST" | cut -f1) em $DEST"
