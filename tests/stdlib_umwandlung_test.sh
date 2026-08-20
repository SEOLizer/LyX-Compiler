#!/usr/bin/env bash
# tests/stdlib_umwandlung_test.sh — #1517, #1518, #1520, #1544.
#
# Vier Meldungen, ein Muster: eine Funktion tut etwas Plausibles, statt zu
# melden — oder es gibt sie an der richtigen Stelle gar nicht.
#
#   #1517 StrToF64("0.5") lieferte 0.0 UND ok=1. Der Nachkommateil wurde nicht
#         gelesen, der Erfolg trotzdem gemeldet.
#   #1518 StrToInt64("-") lieferte 0 UND ok=1. Die Ziffernschleife lief null
#         Mal, am Ende stand unbesehen ok=1.
#   #1520 BPF_MAP_TYPE_QUEUE/STACK standen auf 18/19 — das sind SOCKHASH und
#         CGROUP_STORAGE. Der Aufruf legte still eine andere Kartenart an.
#   #1544 Die Textform einer IPv4-Adresse fehlte in std.net.types und lag
#         dafuer zweimal in Protokoll-Units.
#
# GEPRÜFT WIRD DAS ok-FLAG, nicht nur der Rückgabewert: 0 ist bei beiden
# Konvertierungen ein gültiges Ergebnis. Ein Test, der nur den Wert vergleicht,
# waere bei "0" und bei "-" gleichermassen gruen gewesen — und vor dem Fix
# genauso.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ rc=$rc"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

f64_rumpf='import std.io;
import std.alloc;
import std.string;
fn Z(t: pchar): void {
  var ok: int64 := alloc(8);
  poke64(ok, 7);
  var v: f64 := StrToF64(t, ok);
  PrintStr(FloatToStr(v, 3)); PrintStr("/"); PrintLn(IntToStr(peek64(ok)));
}
fn main(): int64 {
%s
  return 0;
}'

int_rumpf='import std.io;
import std.alloc;
import std.string;
fn Z(t: pchar): void {
  var ok: int64 := alloc(8);
  poke64(ok, 7);
  var v: int64 := StrToInt64(t, ok);
  PrintStr(IntToStr(v)); PrintStr("/"); PrintLn(IntToStr(peek64(ok)));
}
fn main(): int64 {
%s
  return 0;
}'

# ===========================================================================
# #1517 — StrToF64
# ===========================================================================

out "#1517: Nachkommastellen werden gelesen" \
  "$(printf "$f64_rumpf" '  Z("0.5"c); Z("3.75"c); Z("-2.25"c);')" \
  "0.500/1
3.750/1
-2.250/1"

# Ganzzahlform ohne Punkt bleibt gueltig, und ein Vorzeichen-Plus auch.
out "#1517: Ganzzahlform und Pluszeichen" \
  "$(printf "$f64_rumpf" '  Z("42"c); Z("+7.5"c); Z("0"c);')" \
  "42.000/1
7.500/1
0.000/1"

# Der entscheidende Fall: kaputte Eingabe MUSS ok=0 setzen. Der Wert darf
# dabei alles sein — geprueft wird die Meldung.
out "#1517: kaputte Eingabe meldet Misserfolg" \
  "$(printf "$f64_rumpf" '  Z("abc"c); Z("1.2.3"c); Z("1x"c); Z(""c); Z("."c);')" \
  "0.000/0
0.000/0
0.000/0
0.000/0
0.000/0"

# ===========================================================================
# #1518 — StrToInt64
# ===========================================================================

# Ein blosses Vorzeichen ist keine Zahl. Vor dem Fix kam 0 mit ok=1, und der
# Aufrufer konnte das nicht von einer echten Null unterscheiden.
out "#1518: blosses Vorzeichen meldet Misserfolg" \
  "$(printf "$int_rumpf" '  Z("-"c); Z("+"c);')" \
  "0/0
0/0"

# Die echte Null muss weiterhin Erfolg melden — sonst waere der Fix eine
# Verschlimmbesserung.
out "#1518: echte Null bleibt gueltig" \
  "$(printf "$int_rumpf" '  Z("0"c); Z("-0"c);')" \
  "0/1
0/1"

out "#1518: normale Zahlen unveraendert" \
  "$(printf "$int_rumpf" '  Z("42"c); Z("-42"c); Z("+7"c);')" \
  "42/1
-42/1
7/1"

out "#1518: Buchstaben melden Misserfolg" \
  "$(printf "$int_rumpf" '  Z("x"c); Z(""c);')" \
  "0/0
0/0"

# ===========================================================================
# #1520 — BPF-Kartenarten
# ===========================================================================

# Die Werte stammen aus linux/bpf.h. Geprueft werden auch die beiden Namen,
# die vorher faelschlich getroffen wurden — steht QUEUE wieder auf 18, faellt
# der Vergleich mit SOCKHASH auf.
out "#1520: BPF-Kartenarten wie in linux/bpf.h" 'import std.io;
import std.bpf;
fn main(): int64 {
  PrintStr(IntToStr(BPF_MAP_TYPE_QUEUE)); PrintStr(" ");
  PrintStr(IntToStr(BPF_MAP_TYPE_STACK)); PrintStr(" ");
  PrintStr(IntToStr(BPF_MAP_TYPE_SOCKHASH)); PrintStr(" ");
  PrintStr(IntToStr(BPF_MAP_TYPE_CGROUP_STORAGE)); PrintStr(" ");
  PrintStr(IntToStr(BPF_MAP_TYPE_HASH)); PrintStr(" ");
  PrintLn(IntToStr(BPF_MAP_TYPE_RINGBUF));
  return 0;
}' "22 23 18 19 1 27"

# ===========================================================================
# #1544 — IPv4ToStr
# ===========================================================================

out "#1544: IPv4ToStr in std.net.types" 'import std.io;
import std.net.types;
fn main(): int64 {
  PrintLn(IPv4ToStr(3232235777));
  PrintLn(IPv4ToStr(0));
  PrintLn(IPv4ToStr(4294967295));
  PrintLn(IPv4ToStr(134744072));
  PrintLn(IPv4ToStr(16909060));
  return 0;
}' "192.168.1.1
0.0.0.0
255.255.255.255
8.8.8.8
1.2.3.4"

# Die beiden alten Kopien muessen weiterlaufen — sie zeigen jetzt auf dieselbe
# Umwandlung, und vorhandene Aufrufer duerfen davon nichts merken.
out "#1544: alte Namen liefern dasselbe" 'import std.io;
import std.net.bgp;
import std.net.whois;
fn main(): int64 {
  PrintLn(BGPFormatIPv4(3232235777) as pchar);
  PrintLn(WhoisFormatIPv4(3232235777) as pchar);
  PrintLn(BGPFormatIPv4(134744072) as pchar);
  return 0;
}' "192.168.1.1
192.168.1.1
8.8.8.8"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
