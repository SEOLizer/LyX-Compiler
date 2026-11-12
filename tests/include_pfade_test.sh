#!/usr/bin/env bash
# tests/include_pfade_test.sh — #1736: mehrere -I-Pfade werden ALLE durchsucht.
#
# Bis 1.1.6B hielt `includePath` genau einen Pfad, und jedes weitere `-I`
# ersetzte den vorigen. Im eigenen Arbeitsbaum fiel das nicht auf, weil dort
# `-I .` dabeisteht und das Arbeitsverzeichnis ohnehin durchsucht wird. Aus
# einem installierten Paket heraus brach derselbe Aufruf — und die Meldung
# nannte eine Unit, die mit der Plattformwahl nichts zu tun hatte.
#
# Der deutlichste Fall: ein NICHT EXISTIERENDER zweiter Pfad machte einen
# vorher funktionierenden Bau kaputt.
#
# Geprueft wird mit einem Paket aus zwei Verzeichnissen — allgemeine Units im
# einen, plattformabhaengige im anderen. Und zwar am ERGEBNIS: das Programm
# rechnet 7 + 11 = 18, also stammt jede Unit aus dem richtigen Verzeichnis.
# Nur zu bauen genuegt hier nicht; ein falsch aufgeloester Import koennte eine
# gleichnamige Unit mit anderem Inhalt erwischen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/pkg/paket" "$TMP/pkg/platform/linux/paket"
cat > "$TMP/pkg/paket/allgemein.lyx" <<'EOF'
unit paket.allgemein;
pub fn AllgemeinWert(): int64 { return 7; }
EOF
cat > "$TMP/pkg/platform/linux/paket/spezifisch.lyx" <<'EOF'
unit paket.spezifisch;
pub fn SpezifischWert(): int64 { return 11; }
EOF
cat > "$TMP/app.lyx" <<'EOF'
import paket.allgemein;
import paket.spezifisch;
fn main(): int64 { return AllgemeinWert() + SpezifischWert(); }
EOF
cat > "$TMP/nur_allgemein.lyx" <<'EOF'
import paket.allgemein;
fn main(): int64 { return AllgemeinWert(); }
EOF

baut_und_rechnet() {   # Name, erwarteter Rueckgabewert, Quelle, -I-Argumente...
  local name="$1" erwartet="$2" quelle="$3"; shift 3
  if ! "$LYXC" "$@" "$TMP/$quelle" -o "$TMP/a.out" >"$TMP/a.log" 2>&1; then
    no "$name" "$(grep -iE 'nicht gefunden|error' "$TMP/a.log" | head -1)"
    return
  fi
  "$TMP/a.out"; local rc=$?
  if [ "$rc" = "$erwartet" ]; then ok "$name (= $erwartet)"
  else no "$name" "gebaut, aber Ergebnis $rc statt $erwartet — falsche Unit aufgeloest?"; fi
}

P="$TMP/pkg"
L="$TMP/pkg/platform/linux"

# Beide Reihenfolgen muessen gehen. Die uebliche ist allgemein-zuerst; genau
# die war kaputt, weil der zweite Pfad den ersten ersetzte.
baut_und_rechnet "allgemein zuerst, dann Plattform" 18 app.lyx -I "$P" -I "$L"
baut_und_rechnet "Plattform zuerst, dann allgemein" 18 app.lyx -I "$L" -I "$P"

# Drei Pfade, der erste nutzlos.
baut_und_rechnet "drei Pfade, der erste leer"       18 app.lyx -I /tmp -I "$L" -I "$P"

# Der Fall aus dem Ticket: ein nicht existierender Pfad darf nichts kaputt
# machen — weder am Anfang, in der Mitte noch am Ende.
baut_und_rechnet "nicht existierender Pfad hinten"  7  nur_allgemein.lyx -I "$P" -I /tmp/gibtsnicht
baut_und_rechnet "nicht existierender Pfad vorn"    7  nur_allgemein.lyx -I /tmp/gibtsnicht -I "$P"
baut_und_rechnet "nicht existierender Pfad mittig"  18 app.lyx -I "$L" -I /tmp/gibtsnicht -I "$P"

# Die lange Schreibweise verhaelt sich wie -I.
baut_und_rechnet "--include-path zweimal"           18 app.lyx --include-path="$L" --include-path="$P"

# Ein einzelner Pfad, der die Unit nicht enthaelt, muss weiterhin MELDEN —
# sonst hiesse "alle Pfade durchsuchen" am Ende "irgendetwas nehmen".
if "$LYXC" -I "$P" "$TMP/app.lyx" -o "$TMP/b.out" >"$TMP/b.log" 2>&1; then
  no "fehlende Unit wird gemeldet" "baut, obwohl paket.spezifisch nirgends liegt"
elif grep -q "Modul nicht gefunden" "$TMP/b.log"; then
  ok "fehlende Unit wird weiterhin gemeldet"
else
  no "fehlende Unit wird gemeldet" "scheitert, aber ohne die Meldung"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
