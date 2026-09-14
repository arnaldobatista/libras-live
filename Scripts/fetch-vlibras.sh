#!/usr/bin/env bash
# Baixa o player Unity WebGL do VLibras (LGPL-3.0) para Overlay/vlibras.
# Fonte: https://github.com/spbgovbr-vlibras/vlibras-web-browsers (commit fixado).
set -euo pipefail

REPO="https://github.com/spbgovbr-vlibras/vlibras-web-browsers.git"
COMMIT="${VLIBRAS_COMMIT:-6d6af49ac06b85e0dc22a601e66ef9a67b492f9a}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Overlay/vlibras"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$COMMIT" && "${1:-}" != "--force" ]]; then
  echo "VLibras já está em $DEST ($COMMIT)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Baixando VLibras ($COMMIT)..."
git -C "$TMP" init -q
git -C "$TMP" remote add origin "$REPO"
git -C "$TMP" fetch -q --depth 1 origin "$COMMIT"
git -C "$TMP" checkout -q FETCH_HEAD

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$TMP/public/unity/unity-loader.js" \
   "$TMP/public/unity/playerweb.data.unityweb" \
   "$TMP/public/unity/playerweb.wasm.code.unityweb" \
   "$TMP/public/unity/playerweb.wasm.framework.unityweb" \
   "$TMP/src/player/unity/playerweb.json" \
   "$TMP/LICENSE" \
   "$DEST/"
echo "$COMMIT" > "$DEST/VERSION"

echo "OK: $(du -sh "$DEST" | cut -f1) em $DEST"
