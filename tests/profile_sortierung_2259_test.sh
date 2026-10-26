#!/usr/bin/env bash
# tests/profile_sortierung_2259_test.sh — der --profile-Bericht steht nach
# GESAMTTAKTEN, absteigend (#2259, Rest aus #2249).
#
# Der Bericht wird zur Uebersetzungszeit ausgerollt: je Eintrag eine feste
# Folge Druckbefehle (cg_profReportBytes). Die Reihenfolge war deshalb die der
# REGISTRIERUNG, nicht die der Laufzeit — wer wissen wollte, wo die Zeit
# bleibt, musste `sort -t, -k2 -n -r` dahinterhaengen. Jetzt liegt eine
# Laufzeit-Schleife darum, die je Runde den groessten noch nicht gedruckten
# Eintrag auswaehlt.
#
# GEPRUEFT WIRD DIE ORDNUNG, nicht die Zahl: Takte schwanken von Lauf zu Lauf
# (Frequenz, Cache, Nachbarlast), ihre REIHENFOLGE bei dieser Spreizung nicht.
# Das Programm hat drei Funktionen mit Faktor 20 bzw. 400 zwischen den
# Arbeitsmengen; main enthaelt alle drei und steht damit zwangslaeufig oben.
#
# Gegenseite, beides im selben Lauf:
#   * die Zahlen bleiben inklusive geordnet (main >= lang >= mittel >= kurz) —
#     eine Sortierung, die die Werte vertauscht statt die Zeilen, fiele auf;
#   * jede Funktion erscheint GENAU EINMAL. Die Schleife merkt sich den
#     gedruckten Eintrag, indem sie seine Aufrufzahl auf 0 setzt; ein Fehler
#     darin ergaebe eine Endlosausgabe oder fehlende Zeilen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'LYX'
import std.io;
fn kurz(n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n) { s := s + i; i := i + 1; }
  return s;
}
fn mittel(n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n * 20) { s := s + i; i := i + 1; }
  return s;
}
fn lang(n: int64): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < n * 400) { s := s + i; i := i + 1; }
  return s;
}
fn main(): int64 {
  PrintLn(kurz(1000) + mittel(1000) + lang(1000));
  return 0;
}
LYX

if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --profile "$TMP/p.lyx" -o "$TMP/p" >"$TMP/b.log" 2>&1); then
  echo "FAIL uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/b.log")"; exit 1
fi

( cd "$TMP" && timeout 60 "$TMP/p" >"$TMP/aus.txt" 2>"$TMP/err.txt" )
grep '^\[PROFILE\]' "$TMP/err.txt" > "$TMP/prof.txt" || true

if [ ! -s "$TMP/prof.txt" ]; then
  echo "FAIL kein Bericht auf stderr"; exit 1
fi

# Namen in Berichtsreihenfolge, und die Taktzahlen dazu.
NAMEN=$(sed 's/^\[PROFILE\] \([^:]*\):.*/\1/' "$TMP/prof.txt" | tr '\n' ' ')
NAMEN="${NAMEN% }"
TAKTE=$(sed 's/.*calls, \([0-9]*\) cycles total.*/\1/' "$TMP/prof.txt" | tr '\n' ' ')

# 1. Reihenfolge der ZEILEN: absteigend nach Gesamttakten.
absteigend=1
vorher=""
for t in $TAKTE; do
  if [ -n "$vorher" ] && [ "$t" -gt "$vorher" ]; then absteigend=0; fi
  vorher="$t"
done
if [ "$absteigend" -eq 1 ]; then ok "Zeilen stehen absteigend nach Gesamttakten ($TAKTE)"
else no "Reihenfolge" "nicht absteigend: $TAKTE"; fi

# 2. Erwartete Namensfolge bei dieser Spreizung (Faktor 20 und 400).
if [ "$NAMEN" = "main lang mittel kurz" ]; then ok "Namensfolge: $NAMEN"
else no "Namensfolge" "'$NAMEN' erwartet 'main lang mittel kurz'"; fi

# 3. Jede Funktion genau einmal — der Merker (Aufrufzahl auf 0) muss greifen.
doppelt=0
for f in main lang mittel kurz; do
  n=$(grep -c "^\[PROFILE\] $f:" "$TMP/prof.txt")
  if [ "$n" -ne 1 ]; then no "Anzahl $f" "$n Zeilen, erwartet 1"; doppelt=1; fi
done
[ "$doppelt" -eq 0 ] && ok "jede Funktion genau einmal (4 Zeilen: $(wc -l < "$TMP/prof.txt"))"

# 4. Gegenseite: die WERTE bleiben inklusive geordnet. main enthaelt alle drei.
hole() { grep "^\[PROFILE\] $1:" "$TMP/prof.txt" | sed 's/.*calls, \([0-9]*\) cycles total.*/\1/'; }
tm=$(hole main); tl=$(hole lang); tt=$(hole mittel); tk=$(hole kurz)
if [ -n "$tm" ] && [ -n "$tl" ] && [ -n "$tt" ] && [ -n "$tk" ] \
   && [ "$tm" -ge "$tl" ] && [ "$tl" -ge "$tt" ] && [ "$tt" -ge "$tk" ]; then
  ok "Werte inklusive geordnet: main $tm >= lang $tl >= mittel $tt >= kurz $tk"
else
  no "Werte" "main=$tm lang=$tl mittel=$tt kurz=$tk"
fi

# 5. Das Programm rechnet weiter richtig (der Bericht darf nichts verschieben).
erw=$(python3 -c "print(sum(range(1000)) + sum(range(20000)) + sum(range(400000)))")
got=$(tr -d '\n' < "$TMP/aus.txt")
if [ "$got" = "$erw" ]; then ok "Programmausgabe unveraendert ($got)"
else no "Programmausgabe" "'$got' erwartet '$erw'"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
