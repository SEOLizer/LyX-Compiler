#!/bin/bash
# #1724 — die IR-Strecke muss Importe dort finden, wo der Hauptaufloeser sie
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
#
# GEPRUEFT WIRD DIE AUFLOESUNG, NICHT DIE UEBERSETZUNG (#1943). Bis 1.1.19D
# verlangte dieser Test, dass das Programm durchlaeuft — und uebersetzte damit
# die INSTALLIERTE Unit unter /usr/include/lyx/units. Die gehoert nicht zum
# Repo und ist per Definition aelter als das, was hier bearbeitet wird: jede
# Verschaerfung im Compiler machte den Test rot, bis jemand neu installiert.
# Gemessen wurde damit die Ausstattung des Rechners, nicht der Compiler.
#
# Die Frage des Tests ist aber eine andere: FINDET die IR-Strecke den Import
# ueber die vierte Stufe? Das beantwortet `--trace-imports` mit der
# Aufloesungszeile, unabhaengig davon, ob die dort liegende Fassung unter den
# heutigen Regeln noch uebersetzt.

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
timeout 300 "$LYXC" --target=lyxos --trace-imports "$TMP/t.lyx" -o "$TMP/t.out" >"$log" 2>&1

# 1. Der Import wird ueberhaupt aufgeloest — und zwar ueber den
#    INSTALLATIONSPFAD, denn die drei Stufen davor koennen hier nicht greifen.
if grep -q '^\[import\] std\.fs -> /usr/include/lyx/units/' "$log"; then
  ok "std.fs wird ohne --std-path ueber den Installationspfad gefunden"
else
  bad "Import ohne --std-path" "$(grep -E '^\[import\] std\.fs' "$log" | head -1)"
fi

# 2. Und die Meldung aus #1724 darf nicht wiederkommen. Sie zeigte auf einen
#    fehlenden Builtin, obwohl bloss die Unit nicht gefunden wurde.
if grep -q 'Import nicht lesbar' "$log"; then
  bad "Import ohne --std-path" "meldet weiterhin 'Import nicht lesbar'"
else
  ok "keine Meldung 'Import nicht lesbar'"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
