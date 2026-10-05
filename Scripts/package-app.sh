#!/usr/bin/env bash
# Monta o app em release e gera build/Libras-Live-<versão>.zip com o SHA-256: o mesmo arquivo do release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Libras Live.app"

"$ROOT/Scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Libras-Live-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"

# O ditto guarda a assinatura, os links e os atributos do bundle; um zip comum quebra a assinatura.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo "OK: $ZIP ($(du -h "$ZIP" | cut -f1))"
cat "$ZIP.sha256"
