#!/usr/bin/env bash
# #1980: Jede Verkettung mit `+` (StrConcat) belegte eine eigene 4-KB-Seite,
# die nie frei wurde.
#
# Die Ursache war dieselbe wie bei `new` vor #1836: ein roher mmap-Syscall je
# Aufruf. Der belegt MINDESTENS eine Seite — 4096 Byte fuer ein Ergebnis von
# elf Zeichen — und gibt nie etwas zurueck. Gemessen: 100.000 Verkettungen
# kosteten 400 MB.
#
# GEMESSEN WIRD DER SPEICHER, nicht das Ergebnis. Ein Test auf die richtige
# Zeichenkette waere auch von der alten Fassung erfuellt gewesen: die hat
# richtig verkettet und dabei den Speicher gefressen.
#
# Und die Gegenprobe auf die KORREKTHEIT gehoert dazu: ein Allokator, der
# Speicher wiederverwendet, waere sparsam und wuerde vorherige Ergebnisse
# ueberschreiben. Deshalb wird geprueft, dass zwei Ergebnisse nebeneinander
# leben und eine wachsende Kette erhalten bleibt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# --- Speicherbedarf bei 100.000 Verkettungen -------------------------------
cat > "$TMP/viel.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var s: pchar := "";
  var i: int64 := 0;
  while (i < 100000) { s := StrConcat("abcde", "fghij"); i := i + 1; }
  PrintLn(s);
  return 0;
}
EOF
if ! ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/viel.lyx" -o "$TMP/viel" ) >"$TMP/b.log" 2>&1; then
    nok "Pruefprogramm uebersetzt nicht"; grep -v Copyright "$TMP/b.log" | sed -n '1,4p'
    echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

rss="$( ulimit -v 4000000; /usr/bin/time -f "%M" "$TMP/viel" 2>&1 >/dev/null | tail -1 )"
# Vor dem Fix: rund 400.000 KB. Danach: wenige MB. Die Schranke liegt bei
# 50 MB — grosszuegig genug fuer Grundlast und Schwankungen, und um Faktor
# acht unter dem alten Wert.
if [ "$rss" -lt 51200 ] 2>/dev/null; then
    ok "100.000 Verkettungen bleiben unter 50 MB (gemessen: ${rss} KB)"
else
    nok "100.000 Verkettungen brauchen ${rss} KB — die Seite je Aufruf ist zurueck"
fi

# --- Und das Ergebnis stimmt weiterhin -------------------------------------
cat > "$TMP/richtig.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var s: pchar := "";
  var i: int64 := 0;
  while (i < 500) { s := StrConcat(s, "xy"); i := i + 1; }
  PrintStr(IntToStr(StrLen(s))); PrintStr(" ");
  PrintStr(StrSub(s, 0, 4)); PrintStr(" ");
  PrintStr(StrSub(s, 996, 4)); PrintStr(" ");
  var a: pchar := StrConcat("AAA", "111");
  var b: pchar := StrConcat("BBB", "222");
  PrintStr(a); PrintStr(" "); PrintLn(b);
  return 0;
}
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/richtig.lyx" -o "$TMP/richtig" ) >"$TMP/r.log" 2>&1; then
    ist="$( ulimit -v 4000000; timeout 60 "$TMP/richtig" 2>&1 )"
    if [ "$ist" = "1000 xyxy xyxy AAA111 BBB222" ]; then
        ok "wachsende Kette und zwei gleichzeitige Ergebnisse bleiben erhalten"
    else
        nok "Korrektheit: erwartet '1000 xyxy xyxy AAA111 BBB222', bekommen '$ist'"
    fi
else
    nok "Korrektheitsprogramm uebersetzt nicht"; grep -v Copyright "$TMP/r.log" | sed -n '1,3p'
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
