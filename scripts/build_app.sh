#!/usr/bin/env bash
# Compila, impacchetta HeadSwitch.app, la installa in /Applications e la avvia.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/HeadSwitch"

APP="$ROOT/build/HeadSwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeadSwitch"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Rimuove gli attributi estesi (iCloud/Finder su Desktop e Documenti) che fanno fallire codesign.
xattr -cr "$APP"

# Firma: usa il certificato locale "HeadSwitch Dev" se esiste (permessi stabili tra un update e l'altro),
# altrimenti firma ad-hoc.
if [ -z "${SIGN_ID:-}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "HeadSwitch Dev"; then
    SIGN_ID="HeadSwitch Dev"
  else
    SIGN_ID="-"
    echo "Nota: firma ad-hoc. Dopo ogni update potrebbe servire riattivare l'Accessibilità."
    echo "      Per evitarlo: ./scripts/setup_signing.sh (una sola volta)."
  fi
fi
codesign --force --sign "$SIGN_ID" --identifier dev.headswitch.app "$APP"

pkill -x HeadSwitch 2>/dev/null || true
rm -rf /Applications/HeadSwitch.app
ditto --noextattr --norsrc "$APP" /Applications/HeadSwitch.app
echo "Installata in /Applications/HeadSwitch.app"
open /Applications/HeadSwitch.app
