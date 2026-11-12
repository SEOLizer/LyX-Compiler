#!/usr/bin/env bash
# tests/lyu_dekl_2488_test.sh — #2488: Typalias und f64-Konstante stehen in
# der .lyu.
#
# BEFUND. Zwei Symbolarten standen in der Symboltabelle einer .lyu, ohne von
# einer Deklaration beschrieben zu werden. Der Codegen zaehlte sie als
# verloren und verlangte die Quelle:
#
#   error: codegen: Quelle der importierten Unit nicht lesbar: std/list.lyx
#     Nicht beschrieben: ListInt64
#
#   pub type X = <Grundtyp>   17 Units (ListInt64, TLSKey, date ...)
#   pub con X: f64             6 Units (PI, TAU ... -- der Konstanten-
#                                abschnitt kennt nur int64 und pchar)
#
# WIE HIER GEPRUEFT WIRD: der Test baut sich eine EIGENE kleine Unit, laesst
# sie mit --compile-unit zur .lyu vorkompilieren und LOESCHT DANN DIE QUELLE.
# Damit ist die Lage hergestellt, in der der Fehler auftritt -- ohne ein
# Paket zu bauen (zu langsam) und ohne von der installierten stdlib
# abzuhaengen (die ist umgebungsabhaengig, siehe #2484).
#
# BEIDE SEITEN:
#   1. Alias und f64-Konstante sind aus der reinen .lyu benutzbar, und der
#      f64-Wert ist BITGLEICH -- geprueft mit `==` gegen dasselbe Literal,
#      was bei einer Abweichung im letzten Bit durchfaellt. Die Textform in
#      der .lyu (statt eines formatierten Bitmusters) muss das halten.
#   2. Ein Alias auf einen FUNKTIONSTYP ist nicht beschreibbar und muss
#      weiter LAUT scheitern. Ohne diese Haelfte waere der Test auch von
#      einer Umsetzung erfuellt, die irgendetwas hinschreibt und damit still
#      Falsches liefert.
#
# NICHT ABGEDECKT: #2146. Eine .lyu traegt keinen Objektcode, deshalb ist
# eine Unit aus dem Paket weiterhin nicht AUFRUFBAR (gemessen: 310 von 500).
# Dieser Test prueft, was #2488 zusagt, und nicht mehr.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

mkdir -p "$TMP/u/probe"

# .lyu bauen und die Quelle entfernen
vorkompilieren() {   # <name> <quelltext>
  printf '%s' "$2" > "$TMP/u/probe/$1.lyx"
  if ! "$LYXC" --std-path="$TMP/u" --compile-unit "$TMP/u/probe/$1.lyx" \
       -o "$TMP/u/probe/$1.lyu" >"$TMP/vk.log" 2>&1; then
    echo "FAIL $1: --compile-unit scheitert"
    grep -iE "error" "$TMP/vk.log" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL+1)); return 1
  fi
  rm -f "$TMP/u/probe/$1.lyx"      # ab hier gibt es NUR die .lyu
  return 0
}

echo "-- Alias und f64-Konstante aus der reinen .lyu --"
if vorkompilieren kern 'unit probe.kern;
pub type ProbeHandle = int64;
pub con PROBE_PI: f64 := 3.141592653589793;
pub con PROBE_N: int64 := 42;
'; then
  printf '%s' 'unit main;
import std.io;
import probe.kern;
fn main(): int64 {
  var h: ProbeHandle := 7;
  PrintLn(IntToStr(h));
  PrintLn(IntToStr(PROBE_N));
  if (PROBE_PI == 3.141592653589793) { PrintLn("f64 bitgleich"c); } else { PrintLn("f64 ABWEICHEND"c); }
  return 0;
}' > "$TMP/c.lyx"
  if "$LYXC" -I"$TMP/u" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
    got="$( ulimit -v 2000000 -c 0; timeout 30 "$TMP/c" 2>&1 | tr '\n' '|' )"
    if [ "$got" = "7|42|f64 bitgleich|" ]; then
      echo "PASS Alias, int64-con und f64-con aus der .lyu (7|42|bitgleich)"
      PASS=$((PASS+1))
    else
      echo "FAIL Ausgabe '$got' statt '7|42|f64 bitgleich|'"
      FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL uebersetzt NICHT gegen die reine .lyu:"
    grep -iE "error|Nicht beschrieben" "$TMP/c.log" | head -3 | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
fi

echo "-- Gegenseite: nicht beschreibbarer Alias scheitert LAUT --"
# Ein Alias auf einen Funktionstyp kann die .lyu nicht beschreiben
# (_typText kennt keine Funktionstypen). Der Schreiber muss den Eintrag
# WEGLASSEN und der Codegen weiter die Quelle verlangen -- statt etwas
# hinzuschreiben, das nachher still falsch ist.
if vorkompilieren fnalias 'unit probe.fnalias;
pub type ProbeCb = fn(int64): int64;
'; then
  printf '%s' 'unit main;
import std.io;
import probe.fnalias;
fn h(x: int64): int64 { return x + 1; }
fn main(): int64 {
  var c: ProbeCb := h;
  PrintLn(IntToStr(c(1)));
  return 0;
}' > "$TMP/d.lyx"
  out="$("$LYXC" -I"$TMP/u" --std-path="$ROOT" "$TMP/d.lyx" -o "$TMP/d" 2>&1)"
  rc=$?
  if [ "$rc" = "0" ]; then
    echo "FAIL Funktionstyp-Alias uebersetzte klaglos — der Eintrag beschreibt ihn falsch"
    FAIL=$((FAIL+1))
  elif printf '%s' "$out" | grep -q "Nicht beschrieben: ProbeCb"; then
    echo "PASS Funktionstyp-Alias scheitert laut und nennt ProbeCb"
    PASS=$((PASS+1))
  else
    echo "FAIL scheitert, aber nicht mit der erwarteten Ursache:"
    printf '%s\n' "$out" | grep -iE "error" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
fi

echo "-- pub var auf Modulebene (#2488 Schritt 2) --"
# Eine Modulvariable ist SPEICHER, nicht nur ein Name. Dass der Eintrag
# gefahrlos ist, haengt daran, dass cg_addGlobal bei einem NAMENStreffer
# denselben Datenoffset zurueckgibt -- eine zweite Deklaration legt keinen
# zweiten Speicher an. Geprueft wird deshalb nicht nur das Lesen, sondern
# auch das SCHREIBEN: wer auf eine eigene Zelle schriebe, bekaeme beim
# Zurueklesen den alten Wert.
if vorkompilieren pv 'unit probe.pv;
pub var PvZaehler: int64 := 5;
pub var PvLeer: int64;
'; then
  printf '%s' 'unit main;
import std.io;
import probe.pv;
fn main(): int64 {
  PrintLn(IntToStr(PvZaehler));
  PrintLn(IntToStr(PvLeer));
  PvZaehler := PvZaehler + 1;
  PrintLn(IntToStr(PvZaehler));
  return 0;
}' > "$TMP/pv.lyx"
  if "$LYXC" -I"$TMP/u" --std-path="$ROOT" "$TMP/pv.lyx" -o "$TMP/pv" >"$TMP/pv.log" 2>&1; then
    got="$( ulimit -v 2000000 -c 0; timeout 30 "$TMP/pv" 2>&1 | tr '\n' '|' )"
    if [ "$got" = "5|0|6|" ]; then
      echo "PASS pub var: Startwert 5 erhalten, ohne Startwert 0, Schreiben wirkt (6)"
      PASS=$((PASS+1))
    else
      echo "FAIL pub var: Ausgabe '$got' statt '5|0|6|'"
      FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL pub var uebersetzt NICHT gegen die reine .lyu:"
    grep -iE "error|Nicht beschrieben" "$TMP/pv.log" | head -3 | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
fi

echo "-- Gegenseite: nicht ausrechenbarer Startwert scheitert LAUT --"
# Den Wert weglassen und den Eintrag trotzdem schreiben waere der stille
# Fall: der Leser saehe 0, wo 7 steht. Der Schreiber muss den Eintrag
# deshalb GANZ weglassen, und der Codegen die Quelle verlangen.
if vorkompilieren pvx 'unit probe.pvx;
fn _hol(): int64 { return 7; }
pub var PvBerechnet: int64 := _hol();
'; then
  printf '%s' 'unit main;
import std.io;
import probe.pvx;
fn main(): int64 {
  PrintLn(IntToStr(PvBerechnet));
  return 0;
}' > "$TMP/pvx.lyx"
  out="$("$LYXC" -I"$TMP/u" --std-path="$ROOT" "$TMP/pvx.lyx" -o "$TMP/pvx" 2>&1)"
  if [ "$?" = "0" ]; then
    echo "FAIL berechneter Startwert uebersetzte klaglos — der Leser bekommt still eine 0"
    FAIL=$((FAIL+1))
  elif printf '%s' "$out" | grep -q "Nicht beschrieben: PvBerechnet"; then
    echo "PASS berechneter Startwert scheitert laut und nennt PvBerechnet"
    PASS=$((PASS+1))
  else
    echo "FAIL scheitert, aber nicht mit der erwarteten Ursache:"
    printf '%s\n' "$out" | grep -iE "error" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL+1))
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: Typalias, f64-Konstante und pub var stehen in der .lyu (#2488)"
exit 0
