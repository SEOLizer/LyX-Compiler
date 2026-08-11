#!/usr/bin/env bash
# tests/run_external_compile.sh — übersetzt die Tests aus suite-external.txt.
#
# Diese Tests brauchen zum AUSFÜHREN Zugangsdaten oder laufende Dienste (AWS,
# Cloudflare, DigitalOcean, Postgres, S3/MinIO) und liefen deshalb von keinem
# Ziel. Damit galten sie als zugeordnet — die Abdeckungsprüfung sah sie als
# erledigt an — und verfielen unbemerkt: beim ersten Durchlauf übersetzten
# 13 von 24 nicht (#1004).
#
# ÜBERSETZBARKEIT braucht keine Zugangsdaten. Genau die prüft dieses Skript.
#
# Einträge mit `# BROKEN` laufen mit, brechen den Lauf aber nicht ab; jeder
# trägt ein Issue. Ein Eintrag OHNE Markierung, der nicht mehr übersetzt, macht
# den Lauf rot — das ist der Verfallsschutz.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
LIST="$ROOT/tests/suite-external.txt"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ok=0; known=0; fail=0; failed_names=""

while read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  name="${line%% *}"
  src="$ROOT/tests/$name.lyx"
  if [ ! -f "$src" ]; then
    echo "FEHLT   $name (Datei nicht vorhanden)"; fail=$((fail+1)); continue
  fi
  if timeout 120 "$LYXC" --std-path="$ROOT" "$src" -o "$TMP/b" >/dev/null 2>&1; then
    ok=$((ok+1))
    case "$line" in
      *BROKEN*) echo "BESSER  $name uebersetzt wieder — Markierung in suite-external.txt entfernen" ;;
    esac
  else
    case "$line" in
      *BROKEN*) known=$((known+1)); echo "BEKANNT $name — ${line#*# }" ;;
      *)        fail=$((fail+1)); failed_names="$failed_names $name"
                echo "FAIL    $name uebersetzt nicht" ;;
    esac
  fi
done < "$LIST"

echo "Externe Tests: $ok uebersetzen, $known bekannt defekt, $fail unerwartet"
if [ "$fail" -gt 0 ]; then
  echo "Unerwartet:$failed_names"
  exit 1
fi
exit 0
