#!/bin/bash
# #1723 — die IR-Strecke muss Importe dort finden, wo der Hauptaufloeser sie
# findet.
#
# `_irLeseImport` kannte nur drei Stufen: Arbeitsverzeichnis, -I und
# --std-path. Der Hauptaufloeser (sema._leseDatei) hat seit 1.0.18D eine
# vierte, den Installationspfad /usr/include/lyx/units. Ohne sie meldete die
# IR-Strecke "Import nicht lesbar, seine Funktionen fehlen: std.fs" und zwei
# Zeilen spaeter "unbekannter Builtin/Funktion: FileExists" — eine Meldung,
# die auf einen fehlenden Builtin zeigt, obwohl bloss die Unit nicht gefunden
# wurde. Zwei Stellen beantworteten dieselbe Frage verschieden.
#
# Der Test laeuft bewusst aus einem FREMDEN Arbeitsverzeichnis und OHNE
# --std-path — genau die Bedingung, unter der es brach. Aus dem Repo heraus
# gemessen faellt der Fehler nicht auf, weil dort schon die erste Stufe
# greift.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

if [ ! -d /usr/include/lyx/units/std ]; then
  echo "SKIP: kein installiertes lyxc unter /usr/include/lyx/units — die vierte Stufe ist hier nicht pruefbar"
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi

cat > "$TMP/t.lyx" <<'EOF'
import std.fs;
fn main(): int64 { return FileExists("/tmp") as int64; }
EOF

# Aus dem TMP-Verzeichnis heraus, ohne --std-path: nur der Installationspfad
# kann std.fs noch liefern.
cd "$TMP" || exit 1
log="$TMP/l"
if timeout 300 "$LYXC" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$log" 2>&1; then
  if grep -q 'Import nicht lesbar' "$log"; then
    bad "Import ohne --std-path" "uebersetzt, meldet aber weiterhin 'Import nicht lesbar'"
  elif [ "$(head -c4 "$TMP/t.out")" = "LYX!" ]; then
    ok "std.fs wird ohne --std-path gefunden (LYX!-Container)"
  else
    bad "Import ohne --std-path" "kein LYX!-Container"
  fi
else
  bad "Import ohne --std-path" "$(grep -iE 'nicht lesbar|unbekannt|error' "$log" | head -1)"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
