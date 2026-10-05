#!/usr/bin/env bash
# Notas do release: a seção da versão no CHANGELOG.md e como instalar.
#   Scripts/release-notes.sh 0.3.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Uso: release-notes.sh <versão>}"

NOTES="$(awk -v version="$VERSION" '
  index($0, "## [" version "]") == 1 || index($0, "## " version " ") == 1 { inside = 1; next }
  inside && /^## / { exit }
  inside && /^\[[^]]+\]: / { next }
  inside { print }
' "$ROOT/CHANGELOG.md")"

if [[ -z "${NOTES//[[:space:]]/}" ]]; then
  echo "Sem a seção da versão $VERSION no CHANGELOG.md." >&2
  exit 1
fi

printf '%s\n' "$NOTES"
cat <<'INSTALL'

---

**Instalação.** Requer Mac com Apple Silicon e macOS 26 ou mais novo.

1. Baixe o `.zip` abaixo, abra e arraste o **Libras Live** para **Aplicativos**.
2. Na primeira abertura, o macOS avisa que não conseguiu verificar o app, porque ele não tem a assinatura paga da Apple. Em **Ajustes do Sistema › Privacidade e Segurança**, clique em **Abrir Mesmo Assim**.

O arquivo `.sha256` confere o download: `shasum -a 256 -c Libras-Live-*.zip.sha256`.
INSTALL
