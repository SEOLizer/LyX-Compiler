#!/usr/bin/env bash
# tests/lyu_leser_laut_test.sh — #2445.
#
# Eine unbrauchbare .lyu muss die DATEI nennen, nicht ein Symbol, das sie
# haette tragen sollen.
#
# Der Mechanismus hinter der falschen Fährte: LyuReader._u8 liefert jenseits
# des Puffers 0 und konnte das nicht melden. Eine abgeschnittene Datei las sich
# dadurch als Nullen -- symCount 0, alle Offsets 0 -- und das ist ein GUELTIGER
# Zustand: eine Unit ohne Symbole (#1966, tests/sec_wp35_lyu_symcount_test.sh
# Pruefung 5). Gemessen vor dem Fix:
#
#   std/fs.lyu auf 40 Byte gekuerzt -> "sema error: undefined symbol 'SEEK_END'"
#   std/time.lyu ohne LYU-Magic     -> "error: codegen: Quelle der importierten
#                                       Unit nicht lesbar: std/time.lyx"
#
# Die zweite Meldung beschuldigt die Quelle, die gar nichts dafuer kann. Beide
# schicken den Leser an die falsche Stelle, und bei einem Paket, das nur noch
# .lyu ausliefert (#2447), ist das der Normalfall statt der Ausnahme.
#
# Geprueft wird die WIRKUNG: rc != 0 UND die Meldung nennt den Pfad der .lyu
# UND den Grund. Ein Test, der nur auf rc != 0 sieht, waere auch vom alten
# Verhalten erfuellt gewesen -- es brach ja ebenfalls ab, nur anderswo.
#
# Die Formatfassung wird in BEIDE Richtungen geprueft: eine gueltige Datei muss
# weiter durchgehen. Ein Test, der nur das Abweisen zeigt, waere auch von einem
# Leser erfuellt, der jede .lyu abweist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- #2445: unbrauchbare .lyu nennt die Datei ---"

# Eigene Unit, eigene .lyu: so haengt der Test an keiner fremden Datei und
# beschaedigt nichts im Repo.
mkdir -p "$TMP/baum/meins" "$TMP/arb"
cat > "$TMP/quelle.lyx" <<'LYX'
unit meins.rechner;

pub con FAKTOR: int64 := 2;

pub fn Verdoppeln(n: int64): int64 {
  return n * FAKTOR;
}
LYX
if ! (ulimit -v 4000000; "$LYXC" "$TMP/quelle.lyx" --compile-unit \
        -o "$TMP/baum/meins/rechner.lyu" --std-path="$ROOT") > "$TMP/cu.log" 2>&1; then
  echo "FAIL Vorbereitung: --compile-unit scheitert"; sed -n '1,5p' "$TMP/cu.log"; exit 1
fi
GUT="$TMP/baum/meins/rechner.lyu"
cp "$GUT" "$TMP/gut.lyu"

# Das Programm liegt AUSSERHALB des Baums und wird aus einem dritten
# Verzeichnis uebersetzt: aus dem Repo heraus gewinnt CWD-relatives std/ gegen
# jeden Suchpfad, und die Messung waere wertlos.
printf 'import meins.rechner;\nfn main(): int64 { return FAKTOR; }\n' > "$TMP/arb/p.lyx"

pruefe() {   # Name, erwarteter Grundtext
  local NAME="$1" GRUND="$2"
  ( cd "$TMP/arb" && ulimit -v 4000000; "$LYXC" "$TMP/arb/p.lyx" -o "$TMP/arb/p" \
      -I "$TMP/baum" ) > "$TMP/l.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    nok "$NAME: uebersetzt durch, obwohl die .lyu unbrauchbar ist"
    return
  fi
  # Die Meldung muss den PFAD der .lyu nennen …
  if ! grep -q "rechner.lyu" "$TMP/l.log"; then
    nok "$NAME: Meldung nennt die .lyu nicht: $(grep -m1 -iE 'error' "$TMP/l.log" | cut -c1-110)"
    return
  fi
  # … und den Grund.
  if ! grep -qi "$GRUND" "$TMP/l.log"; then
    nok "$NAME: Grund fehlt (erwartet '$GRUND'): $(grep -m1 -iE 'nicht lesbar' "$TMP/l.log" | cut -c1-110)"
    return
  fi
  # Und sie muss VOR jeder Folgemeldung ueber ein Symbol stehen: wer zuerst
  # "undefined symbol" liest, sucht im eigenen Programm.
  local zErst zSym
  zErst="$(grep -n "nicht lesbar" "$TMP/l.log" | head -1 | cut -d: -f1)"
  zSym="$(grep -n "undefined symbol" "$TMP/l.log" | head -1 | cut -d: -f1)"
  if [ -n "$zSym" ] && [ -n "$zErst" ] && [ "$zErst" -gt "$zSym" ]; then
    nok "$NAME: die Symbolmeldung steht vor dem Befund zur Datei"
    return
  fi
  ok "$NAME"
}

# 1. Abgeschnitten.
head -c 40 "$TMP/gut.lyu" > "$GUT"
pruefe "abgeschnittene .lyu (40 Byte)" "abgeschnitten\|hinter dem Dateiende\|kuerzer als der Kopf"

# 2. Kein LYU-Kopf.
printf 'DIES_IST_KEINE_LYU_SONDERN_TEXT_1234567890\n' > "$GUT"
pruefe "fremde Datei ohne LYU-Kopf" "Magic"

# 3. Unbekannte Formatfassung. Die Zahl muss mit in der Meldung stehen: zu alt
#    heisst neu vorkompilieren, zu neu heisst der Compiler ist der aeltere.
cp "$TMP/gut.lyu" "$GUT"
printf '\x63\x00' | dd of="$GUT" bs=1 seek=4 conv=notrunc status=none
pruefe "Formatfassung 99" "Formatfassung"
if grep -q "99" "$TMP/l.log"; then
  ok "die gelesene Fassung steht in der Meldung"
else
  nok "die Meldung nennt die gelesene Fassung nicht"
fi

# 4. Leere Datei.
: > "$GUT"
# Eine leere Datei ist DA und liefert nichts. Sie darf nicht als "Modul nicht
# gefunden" erscheinen -- das zeigt auf den Suchpfad statt auf die Datei.
pruefe "leere .lyu" "leer\|kuerzer als der Kopf"

# 5. Gegenprobe: die unveraenderte .lyu muss weiter durchgehen. Ohne sie waere
#    jeder Teil oben auch von einem Leser erfuellt, der alles abweist.
cp "$TMP/gut.lyu" "$GUT"
if ( cd "$TMP/arb" && ulimit -v 4000000; "$LYXC" "$TMP/arb/p.lyx" -o "$TMP/arb/p" \
       -I "$TMP/baum" ) > "$TMP/ok.log" 2>&1; then
  wert="$( (ulimit -v 2000000; "$TMP/arb/p") ; echo $? )"
  if [ "$wert" = "2" ]; then
    ok "unveraenderte .lyu uebersetzt und liefert den Wert aus der Unit (FAKTOR=2)"
  else
    nok "unveraenderte .lyu uebersetzt, liefert aber $wert statt 2"
  fi
else
  nok "unveraenderte .lyu uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/ok.log" | cut -c1-110)"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
