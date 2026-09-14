#!/usr/bin/env bash
# Compila em release e monta build/Libras Live.app (assinatura ad-hoc).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Libras Live.app"

cd "$ROOT"
"$ROOT/Scripts/fetch-vlibras.sh"

echo "Compilando ($CONFIG)..."
swift build -c "$CONFIG" --product LibrasLive
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LibrasLive"

echo "Montando $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LibrasLive"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
rsync -a --delete --exclude ".DS_Store" "$ROOT/Overlay/" "$APP/Contents/Resources/Overlay/"
if [[ -d "$ROOT/Resources/Avatars" ]]; then
  rsync -a --delete --exclude ".DS_Store" "$ROOT/Resources/Avatars/" "$APP/Contents/Resources/Avatars/"
fi

echo "Compilando ícone (Liquid Glass) e cor de destaque..."
ASSETS_TMP="$(mktemp -d)"
xcrun actool "$ROOT/Resources/AppIcon.icon" "$ROOT/Resources/Assets.xcassets" \
  --compile "$APP/Contents/Resources" \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --output-partial-info-plist "$ASSETS_TMP/partial.plist" \
  --output-format human-readable-text > "$ASSETS_TMP/actool.log" 2>&1 || { cat "$ASSETS_TMP/actool.log"; exit 1; }
rm -rf "$ASSETS_TMP"

codesign --force --sign - --timestamp=none "$APP"

echo "OK: $APP"
