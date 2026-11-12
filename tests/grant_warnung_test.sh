#!/usr/bin/env bash
# tests/grant_warnung_test.sh — #1899: die grant-Warnung meldet nur noch dort,
# wo ein `grant` etwas aendern kann.
#
# Bis 1.1.15A meldete jeder Import ohne `grant` — `lyxc` selbst 47 Mal je
# Uebersetzung. Zwei Lagen fielen darunter, in denen der Rat gar nicht
# befolgbar ist:
#
#   1. Das Programm hat kein `@capabilities`. Dann gibt es kein C(P) und
#      nichts zu schneiden; `_shouldStripModule` kehrt in diesem Fall
#      ausdruecklich sofort zurueck. Ein `grant` bliebe folgenlos.
#   2. Die importierte Unit deklariert nichts. Dann hat das `grant` keine
#      Menge, gegen die es geprueft werden koennte.
#
# Eine Warnung, die immer kommt, wird ueberlesen — und mit ihr die Faelle, in
# denen sie etwas sagt. Deshalb misst dieser Test BEIDE Richtungen: er zeigt
# nicht nur, dass die stummen Faelle schweigen, sondern auch, dass der eine
# Fall, auf den es ankommt, weiterhin meldet. Ohne die zweite Haelfte waere er
# auch von einer Aenderung erfuellt, die die Warnung ganz entfernt.
#
# Und die BILANZ bleibt vollstaendig: der Sicherheitsbericht zaehlt weiterhin
# jeden Import ohne grant, auch die nicht gemeldeten.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# zaehlt die grant-Warnungen einer Uebersetzung
warnungen() { printf '%s\n' "$1" > "$TMP/g.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" 2>&1 | grep -c "Import ohne explizites grant"; }

pruefe() { # name, erwartete Anzahl, quelltext
  n="$(warnungen "$3")"
  if [ "$n" = "$2" ]; then ok "$1"; else no "$1" "$n Warnung(en), erwartet $2"; fi
}

# std.io deklariert nichts, std.fs deklariert sieben Capabilities — das ist
# der Unterschied, an dem die Entscheidung haengt.
CAPS='@capabilities([system.exit, fs.read, fs.create, fs.delete, fs.meta, fs.perm, fs.write, system.time])'
GRANT='grant [fs.read, fs.create, fs.delete, fs.meta, fs.perm, fs.write, system.time]'

echo "=== schweigt, wo ein grant folgenlos waere ==="

pruefe "ohne @capabilities: keine Meldung" 0 'unit main;
import std.io;
fn main(): int64 { return 0; }'

pruefe "ohne @capabilities auch bei einer deklarierenden Unit" 0 "unit main;
import std.io;
import std.fs;
fn main(): int64 { return 0; }"

pruefe "mit @capabilities, aber die Unit deklariert nichts" 0 "unit main;
$CAPS
import std.io;
fn main(): int64 { return 0; }"

echo
echo "=== meldet weiter, wo ein grant etwas aendert ==="

# DAS ist die Haelfte, die den Test tragfaehig macht.
pruefe "deklarierende Unit ohne grant wird gemeldet" 1 "unit main;
$CAPS
import std.io;
import std.fs;
fn main(): int64 { return 0; }"

pruefe "mit grant schweigt sie wieder" 0 "unit main;
$CAPS
import std.io;
import std.fs $GRANT;
fn main(): int64 { return 0; }"

# Zwei deklarierende Units, eine mit grant, eine ohne: genau EINE Meldung.
# Ein Zaehler, der nur "meldet ueberhaupt" pruefte, saehe hier nichts.
pruefe "zwei deklarierende Units, eine ohne grant: genau eine Meldung" 1 "unit main;
$CAPS
import std.io;
import std.fs $GRANT;
import std.time;
fn main(): int64 { return 0; }"

echo
echo "=== die Bilanz bleibt vollstaendig ==="

# Der Sicherheitsbericht zaehlt weiter JEDEN Import ohne grant — sonst waere
# mit dem Rauschen auch die Auskunft verschwunden.
printf '%s\n' 'unit main;
import std.io;
fn main(): int64 { return 0; }' > "$TMP/b.lyx"
ber="$("$LYXC" --std-path="$ROOT" "$TMP/b.lyx" -o "$TMP/b" 2>&1 | grep 'Grant-Modell')"
case "$ber" in
  *"Import(e) ohne grant"*) ok "Bericht nennt die Importe ohne grant weiterhin" ;;
  *) no "Bericht nennt die Importe ohne grant weiterhin" "Zeile fehlt: $ber" ;;
esac

# Und zwar mit einer Zahl groesser 0, obwohl keine Warnung erschien.
zahl="$(printf '%s' "$ber" | grep -o '[0-9]\+ Import' | grep -o '[0-9]\+')"
if [ -n "$zahl" ] && [ "$zahl" -gt 0 ]; then
  ok "Bericht zaehlt $zahl Import(e), obwohl keine Warnung kam"
else
  no "Bericht zaehlt trotz stiller Uebersetzung" "Zahl: '$zahl'"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
