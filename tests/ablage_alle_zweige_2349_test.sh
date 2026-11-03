#!/usr/bin/env bash
# tests/ablage_alle_zweige_2349_test.sh — #2349: `arr[i] := wert` ueber ALLE
# Zweige des Ablagepfads, am WERT geprueft.
#
# Hintergrund: in `CGN_ASSIGN` auf `CGN_INDEX` (src/codegen_x86.lyx) wird der
# Wert auf den Stapel gelegt und in jedem Zweig mit `pop rcx` bzw. `pop rsi`
# zurueckgeholt. #2349 will diesen Transport sparen. Dabei muessen ELF
# pop-Stellen gleichzeitig umgestellt werden; ein vergessenes `pop` ist keine
# falsche Zahl, sondern eine Stapel-Unwucht — und damit Speicherkorruption
# mit beliebiger Fernwirkung.
#
# Dieser Test faehrt deshalb jeden Zweig einmal durch und prueft den
# ZURUECKGELESENEN Wert, nicht die Uebersetzbarkeit:
#
#   1. parallel Array<int8|int16|int32|int64>  — Ganzzahlbreiten 1/2/4/8
#   2. parallel Array<f32>                      — cvtsd2ss + movss
#   3. parallel Array<f64>                      — movsd
#   4. Festes Feld `[N]int64`                   — mit Bereichspruefung
#   5. pchar-Element                            — Byteschreibzugriff
#   6. Map-Zuweisung                            — eigener Zweig vor dem Feld
#
# Zusaetzlich wird bei den Feldern das NACHBARELEMENT geprueft: eine zu breite
# Ablage (der Fehler aus #2199) trifft sonst unbemerkt daneben. Und die Summe
# ueber alle Elemente kommt dazu, damit ein Zweig nicht nur an einer Stelle
# richtig schreibt.
#
# Die Prueffrage fuer diesen Test lautet nicht "faellt eine falsche Zahl auf",
# sondern "faellt eine Stapel-Unwucht auf". Deshalb laeuft jedes Programm bis
# zum Ende und gibt einen Abschlussmarker aus; bricht es vorher ab oder
# liefert es rc != 0, ist der Test rot.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/ablage.lyx" <<'EOF'
import std.io;

fn main(): int64 {
  var n: int64 := 37;          // kein Vielfaches einer Vektorbreite
  var i: int64 := 0;

  // 1. Ganzzahlbreiten 1/2/4/8
  var a8:  parallel Array<int8>  := parallel Array<int8>(n);
  var a16: parallel Array<int16> := parallel Array<int16>(n);
  var a32: parallel Array<int32> := parallel Array<int32>(n);
  var a64: parallel Array<int64> := parallel Array<int64>(n);
  i := 0;
  while (i < n) {
    a8[i]  := (i & 127);
    a16[i] := (i * 300) & 32767;
    a32[i] := i * 100000;
    a64[i] := i * 1000000000;
    i := i + 1;
  }
  var s8: int64 := 0;  var s16: int64 := 0;  var s32: int64 := 0;  var s64: int64 := 0;
  i := 0;
  while (i < n) {
    s8  := s8  + a8[i];
    s16 := s16 + a16[i];
    s32 := s32 + a32[i];
    s64 := s64 + a64[i];
    i := i + 1;
  }
  PrintStr("s8="c);   PrintLn(s8);
  PrintStr("s16="c);  PrintLn(s16);
  PrintStr("s32="c);  PrintLn(s32);
  PrintStr("s64="c);  PrintLn(s64);
  // Nachbarelement: eine zu breite Ablage trifft hier daneben (#2199).
  PrintStr("a8_letzte="c);  PrintLn(a8[n - 1]);
  PrintStr("a16_letzte="c); PrintLn(a16[n - 1]);

  // 2./3. Gleitkomma: f32 und f64
  var f32a: parallel Array<f32> := parallel Array<f32>(n);
  var f64a: parallel Array<f64> := parallel Array<f64>(n);
  i := 0;
  while (i < n) {
    f32a[i] := (i * 2) as f64;
    f64a[i] := (i * 3) as f64;
    i := i + 1;
  }
  var sf32: int64 := 0;  var sf64: int64 := 0;
  i := 0;
  while (i < n) {
    sf32 := sf32 + (f32a[i] as int64);
    sf64 := sf64 + (f64a[i] as int64);
    i := i + 1;
  }
  PrintStr("sf32="c); PrintLn(sf32);
  PrintStr("sf64="c); PrintLn(sf64);
  // Ganzzahliger Ausdruck in ein Gleitkommaelement: eigener Zweig.
  f32a[0] := 7;
  f64a[0] := 9;
  PrintStr("f32_int="c); PrintLn(f32a[0] as int64);
  PrintStr("f64_int="c); PrintLn(f64a[0] as int64);

  // 4. Festes Feld mit Bereichspruefung
  var fest: [8]int64;
  i := 0;
  while (i < 8) { fest[i] := i * 11; i := i + 1; }
  var sfest: int64 := 0;
  i := 0;
  while (i < 8) { sfest := sfest + fest[i]; i := i + 1; }
  PrintStr("sfest="c); PrintLn(sfest);

  // 5. pchar-Element (Byteschreibzugriff)
  var puf: pchar := alloc(16) as pchar;
  i := 0;
  while (i < 5) { puf[i] := (65 + i) as char; i := i + 1; }
  puf[5] := 0 as char;
  PrintStr("puf="c); PrintStrLn(puf);

  // 6. Map-Zuweisung — eigener Zweig VOR dem Feldzweig
  var m: Map<int64, int64>;   // #1152: ohne Initialisierung, einen Konstruktor gibt es nicht
  i := 0;
  while (i < 10) { m[i] := i * 7; i := i + 1; }
  var smap: int64 := 0;
  i := 0;
  while (i < 10) { smap := smap + m[i]; i := i + 1; }
  PrintStr("smap="c); PrintLn(smap);

  PrintStrLn("ENDE"c);
  return 0;
}
EOF

if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" ablage.lyx -o ablage ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
  echo "=== PASS=$PASS FAIL=$FAIL"
  exit 1
fi

AUS="$( cd "$TMP" && timeout 60 ./ablage 2>&1 )"
rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc — bei einer Stapel-Unwucht bricht das Programm hier ab. Ausgabe: $(echo "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"
  exit 1
fi
ok "uebersetzt und laeuft bis zum Ende"

hol() { echo "$AUS" | sed -n "s/^$1=//p"; }

# Erwartungswerte gegengerechnet, nicht aus einem Lauf uebernommen:
#   n = 37, i = 0..36
#   s8   = sum(i & 127)              = sum(0..36)            = 666
#   s16  = sum((i*300) & 32767)      = sum(i*300)            = 666*300  = 199800
#   s32  = sum(i*100000)             = 666*100000            = 66600000
#   s64  = sum(i*1000000000)         = 666*1000000000        = 666000000000
#   sf32 = sum(i*2)                  = 1332
#   sf64 = sum(i*3)                  = 1998
#   sfest= sum(i*11), i=0..7 = 28*11 = 308
#   smap = sum(i*7), i=0..9  = 45*7  = 315
pruefe() { # $1 = Name, $2 = erwartet
  v="$(hol "$1")"
  if [ "$v" = "$2" ]; then
    ok "$1 = $2"
  else
    no "$1" "'$v' statt $2"
  fi
}
pruefe s8 666
pruefe s16 199800
pruefe s32 66600000
pruefe s64 666000000000
pruefe a8_letzte 36
pruefe a16_letzte 10800
pruefe sf32 1332
pruefe sf64 1998
pruefe f32_int 7
pruefe f64_int 9
pruefe sfest 308
pruefe smap 315

p="$(hol puf)"
if [ "$p" = "ABCDE" ]; then ok "pchar-Element = ABCDE"; else no "pchar-Element" "'$p' statt ABCDE"; fi

if echo "$AUS" | grep -q '^ENDE$'; then
  ok "Abschlussmarker erreicht — kein Abbruch durch Stapel-Unwucht"
else
  no "Abschlussmarker" "fehlt; das Programm ist vorher ausgestiegen"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
