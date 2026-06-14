#!/usr/bin/env bash
# pack.sh — Paket aus std/ zusammenstellen und publishen
#
# Nutzung:
#   ./packages/pack.sh std.alloc           # nur packen (Ausgabe: /tmp/lpm_pack/<name>/)
#   ./packages/pack.sh std.alloc --publish  # packen + lpm publish

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STD_DIR="$REPO_ROOT/std"
LPM="$REPO_ROOT/bin/lpm"

PKG="$1"
PUBLISH="${2:-}"

if [ -z "$PKG" ]; then
  echo "Nutzung: $0 <paketname> [--publish]"
  echo ""
  echo "Verfügbare Pakete:"
  ls "$SCRIPT_DIR" | grep -v '\.sh$' | grep -v '\.md$' | sort
  exit 1
fi

PKG_DIR="$SCRIPT_DIR/$PKG"
if [ ! -f "$PKG_DIR/lyx.toml" ]; then
  echo "Fehler: $PKG_DIR/lyx.toml nicht gefunden."
  exit 1
fi

# Zielverzeichnis
OUT="/tmp/lpm_pack/$PKG"
rm -rf "$OUT" && mkdir -p "$OUT"

# lyx.toml kopieren
cp "$PKG_DIR/lyx.toml" "$OUT/lyx.toml"

# Quelldateien aus [sources] files = [...] lesen und kopieren
FILES=$(grep -E '^\s*files\s*=' "$PKG_DIR/lyx.toml" \
  | sed 's/.*=\s*\[//' \
  | tr -d '[]"' \
  | tr ',' '\n' \
  | tr -d ' ')

COPIED=0
while IFS= read -r f; do
  f="$(echo "$f" | tr -d '\r')"
  [ -z "$f" ] && continue
  SRC="$STD_DIR/$f"
  DST_DIR="$OUT/$(dirname "$f")"
  if [ ! -f "$SRC" ]; then
    echo "WARNUNG: Quelldatei nicht gefunden: $SRC"
    continue
  fi
  mkdir -p "$DST_DIR"
  cp "$SRC" "$OUT/$f"
  echo "  + $f"
  COPIED=$((COPIED+1))
done <<< "$FILES"

echo ""
echo "Paket '$PKG' bereit: $OUT ($COPIED Dateien)"

if [ "$PUBLISH" = "--publish" ]; then
  echo "Publish → $("$LPM" --version 2>&1 | head -1)"
  cd "$OUT" && "$LPM" publish
fi
