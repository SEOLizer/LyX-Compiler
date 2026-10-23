#!/usr/bin/env bash
# tests/einbettung_test.sh — Einbettung kleiner Funktionen (#2208).
#
# Der Codegen ersetzt den Aufruf einer kleinen Funktion durch eine KOPIE
# ihres Rumpfes, in der die Parameter schon durch die Argumentknoten
# ersetzt sind. Der Gewinn liegt nicht im gesparten Aufruf, sondern darin,
# dass der Ausdruck auf den Variablen des Aufrufers rechnet und damit der
# Registerzuteilung (#2114) zugaenglich wird: ChaCha20 ging von 0,51 s auf
# 0,235 s bei 20 Mio Runden (gcc -O2: 0,15 s).
#
# Gemessen wird in BEIDEN Richtungen, und das ist hier der Kern:
#
#   * Dass die eingebetteten Faelle das richtige ERGEBNIS liefern, wuerde
#     auch ein Compiler erfuellen, der gar nicht einbettet. Deshalb wird
#     zusaetzlich am Erzeugnis gezaehlt, ob der `call` verschwunden ist.
#   * Dass ein `call` da ist, wuerde umgekehrt auch eine Einbettung
#     erfuellen, die nur nie greift. Deshalb beides am selben Programm.
#
# Die Ablehnungen sind kein Beiwerk: jede einzelne steht fuer einen Fall, in
# dem Einbetten das Verhalten AENDERN wuerde — ein doppelt eingesetzter
# Zwischenwert rechnete zweimal, ein Aufruf als Argument liefe zweimal, und
# bei @flight_crit haengt die FPU-Pruefung am Rahmen des Aufgerufenen (der
# Fall ist beim Bauen von #2208 wirklich aufgetreten: `D(1.0, 0.0)` lieferte
# still `inf` statt abzubrechen).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Uebersetzt, laeuft, liefert genau die erwartete Ausgabe (Zeilen mit
# Leerzeichen verbunden).
laeuft() { # name, quelle, erwartet
  local name="$1" quelle="$2" erwartet="$3"
  printf '%s\n' "$quelle" > "$TMP/p.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/p.log" 2>&1); then
    no "$name" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/p.log" | tr '\n' ' ')"; return 1
  fi
  local got
  got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/p" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$erwartet" ]; then ok "$name"; return 0; fi
  no "$name" "erwartet '$erwartet', bekam '$got'"; return 1
}

# Zahl der `call`-Befehle im Erzeugnis.
#
# Disassembliert wird die OBJEKT-Fassung (--emit=obj): das fertige Programm
# traegt keine Section-Header, und `objdump -d` liefert dort null Befehle —
# jede Zaehlung waere still 0 gewesen und jede Ablehnung scheinbar belegt.
# `-z`, damit lange Nullfolgen nicht abgekuerzt und der Rest ungelesen
# bleibt, `--no-show-raw-insn`, damit die Byte-Folgezeilen langer Befehle
# nicht als eigene Befehle zaehlen (#1370).
calls() { # quelldatei
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$1" -o "$TMP/o.o" >/dev/null 2>&1) \
    || { echo "-1"; return; }
  objdump -d -z --no-show-raw-insn "$TMP/o.o" 2>/dev/null | grep -c call
}

# Wurde der Aufruf von `fn <name>` eingebettet?
#
# Gemessen wird die DIFFERENZ gegen dasselbe Programm mit `@export` an der
# Funktion. Jede Annotation sperrt die Einbettung (cg_einbettbar), `@export`
# aber aendert sonst nichts am erzeugten Code — die Differenz ist damit
# genau der gesparte Aufruf. `@wcet` taugte dafuer nicht: an einer Funktion
# mit Schleife oder Rekursion ist die Schranke nicht nachweisbar, und die
# Vergleichsfassung uebersetzte gar nicht erst. Eine blosse Zaehlung taugte nicht: 740 der 741
# `call`-Befehle kommen aus der stdlib, und welcher davon der gesuchte ist,
# sagt das Erzeugnis nicht (exportiert wird nur `_start`).
eingebettet() { # name, quelle, fnname, erwartet-eingebettet(1/0)
  local name="$1" quelle="$2" fn="$3" soll="$4"
  printf '%s\n' "$quelle" > "$TMP/a.lyx"
  sed "s/^fn $fn/@export\nfn $fn/" "$TMP/a.lyx" > "$TMP/b.lyx"
  local ohne mit
  ohne=$(calls "$TMP/a.lyx"); mit=$(calls "$TMP/b.lyx")
  if [ "$ohne" -lt 0 ] || [ "$mit" -lt 0 ]; then
    no "$name (Erzeugnis)" "uebersetzt nicht"; return
  fi
  if [ "$soll" -eq 1 ]; then
    if [ "$ohne" -lt "$mit" ]; then ok "$name (Aufruf gespart: $ohne statt $mit)"
    else no "$name (Aufruf gespart)" "ohne Annotation $ohne, mit $mit — nicht eingebettet"; fi
  else
    if [ "$ohne" -eq "$mit" ]; then ok "$name (Aufruf bleibt: $ohne)"
    else no "$name (Aufruf bleibt)" "ohne Annotation $ohne, mit $mit — doch eingebettet"; fi
  fi
}

# Abgelehnt: der Wert muss stimmen UND der Aufruf stehenbleiben.
abgelehnt() { # name, quelle, erwartet, fnname
  laeuft "$1 (Wert)" "$2" "$3"
  eingebettet "$1" "$2" "$4" 0
}

# ------------------------------------------------------------------
# Eingebettet: Werte stimmen UND der Aufruf ist verschwunden
# ------------------------------------------------------------------

# Der Kern aus bench/chacha_qr.lyx. Zwei Zwischenwerte, jeder genau einmal
# gelesen, Parameter mehrfach — genau die Form, fuer die #2208 gebaut wurde.
Q='import std.io;
con M32: int64 := 4294967295;
fn rotl32(x: int64, n: int64): int64 {
  var l: int64 := (x << n) & M32;
  var r: int64 := (x & M32) >> (32 - n);
  return (l | r) & M32;
}
fn main(): int64 {
  var d: int64 := 20016;
  var i: int64 := 0;
  while (i < 3) { d := rotl32(d, 7); i := i + 1; }
  PrintLn(IntToStr(d));
  return 0;
}'
# Von Hand gegengerechnet: 20016<<7 = 2562048, nochmal <<7 = 327942144,
# ein drittes Mal 41976594432 & M32 = 3321888768, dazu die neun
# herausgedrehten Bits (327942144 >> 25 = 9) = 3321888777.
laeuft "#2208: Zwischenwerte eingesetzt, Wert stimmt" "$Q" "3321888777"
eingebettet "#2208: Zwischenwerte eingesetzt" "$Q" "rotl32" 1

laeuft "#2208: Parameter mehrfach gelesen" 'import std.io;
fn quad(x: int64): int64 { return x * x; }
fn main(): int64 { var a: int64 := 7; PrintLn(IntToStr(quad(a))); return 0; }' "49"

laeuft "#2208: Literal als Argument" 'import std.io;
fn add3(a: int64, b: int64, c: int64): int64 { return a + b + c; }
fn main(): int64 { PrintLn(IntToStr(add3(1, 2, 3))); return 0; }' "6"

laeuft "#2208: Vorzeichen als Argument" 'import std.io;
fn verdopple(x: int64): int64 { return x + x; }
fn main(): int64 { var n: int64 := 5; PrintLn(IntToStr(verdopple(0 - n))); return 0; }' "-10"

# Der Parameter heisst wie eine Variable des Aufrufers, meint aber etwas
# anderes. Wuerde die Ersetzung im kopierten ARGUMENT weiterlaufen, suchte
# sie sich selbst und rekursierte endlos.
laeuft "#2208: Parametername gleich Variablenname beim Aufrufer" 'import std.io;
fn f(x: int64): int64 { return x + 1; }
fn g(x: int64): int64 { return f(x) * 10; }
fn main(): int64 { var x: int64 := 3; PrintLn(IntToStr(g(x))); return 0; }' "40"

# Gleitkomma wird NICHT eingebettet: der return-Zweig des Aufgerufenen
# rechnet um (#2007 — `fn hoehe(): f64 { return 2500; }`), und ohne ihn las
# FloatToStr die Ganzzahl als Bitmuster. Der Wert muss trotzdem stimmen.
abgelehnt "#2208: f64-Funktion nicht eingebettet" 'import std.io;
fn mittel(a: f64, b: f64): f64 { var s: f64 := a + b; return s / 2.0; }
fn main(): int64 { var p: f64 := 3.0; var q: f64 := 4.0;
  PrintLn(FloatToStr(mittel(p, q), 2)); return 0; }' "3.50" "mittel"

laeuft "#2208: eingebettet in einen groesseren Ausdruck" 'import std.io;
fn dopp(x: int64): int64 { return x * 2; }
fn main(): int64 { var a: int64 := 3; var b: int64 := 4;
  PrintLn(IntToStr(dopp(a) + dopp(b) * 2)); return 0; }' "22"

# ------------------------------------------------------------------
# Abgelehnt: Wert stimmt UND der Aufruf steht noch
# ------------------------------------------------------------------


# Ein Aufruf als Argument wuerde so oft laufen, wie der Parameter gelesen
# wird. Gemessen wird die WIRKUNG: `zaehl` gibt bei jedem Lauf eine Zeile
# aus — zwei Zeilen hiesse zweimal ausgewertet.
laeuft "#2208: Aufruf als Argument laeuft genau einmal" 'import std.io;
var n: int64 := 0;
fn zaehl(): int64 { n := n + 1; PrintLn("lauf"c); return 3; }
fn quad(x: int64): int64 { return x * x; }
fn main(): int64 { PrintLn(IntToStr(quad(zaehl()))); return 0; }' "lauf 9"

# Ein Zwischenwert, der ZWEIMAL gelesen wird, darf nicht eingesetzt werden —
# seine Rechnung liefe sonst doppelt. Das Ergebnis bliebe hier richtig; die
# Pruefung haengt deshalb am Erzeugnis.
abgelehnt "#2208: doppelt gelesener Zwischenwert nicht eingesetzt" 'import std.io;
fn f(x: int64): int64 { var t: int64 := x + 1; return t * t; }
fn main(): int64 { var a: int64 := 4; PrintLn(IntToStr(f(a))); return 0; }' "25" "f"

abgelehnt "#2208: Rumpf mit Schleife nicht eingebettet" 'import std.io;
fn summe(n: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < n) { s := s + i; i := i + 1; }
  return s;
}
fn main(): int64 { var k: int64 := 5; PrintLn(IntToStr(summe(k))); return 0; }' "10" "summe"

abgelehnt "#2208: Rekursion nicht eingebettet" 'import std.io;
fn fak(n: int64): int64 { if (n < 2) { return 1; } return n * fak(n - 1); }
fn main(): int64 { var k: int64 := 5; PrintLn(IntToStr(fak(k))); return 0; }' "120" "fak"

abgelehnt "#2208: Rumpf mit Aufruf nicht eingebettet" 'import std.io;
fn inner(x: int64): int64 { return x + 1; }
fn aussen(x: int64): int64 { return inner(x) * 2; }
fn main(): int64 { var a: int64 := 3;
  PrintLn(IntToStr(aussen(a) + aussen(a) + aussen(a))); return 0; }' "24" "aussen"

# @flight_crit: die FPU-Pruefung haengt am Rahmen des AUFGERUFENEN. Genau
# dieser Fall ist beim Bauen von #2208 aufgetreten.
abgelehnt "#2208: @flight_crit nicht eingebettet" 'import std.io;
@flight_crit
fn mal2(a: f64): f64 { return a * 2.0; }
fn main(): int64 { var p: f64 := 1.5; PrintLn(FloatToStr(mal2(p), 2)); return 0; }' "3.00" "mal2"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
