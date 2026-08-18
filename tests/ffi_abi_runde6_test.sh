#!/usr/bin/env bash
# tests/ffi_abi_runde6_test.sh — #1620 und #1607.
#
# Beide betreffen den FFI-Aufrufpfad und lassen sich nur gegen eine echte
# C-Bibliothek pruefen; sie wird hier uebersetzt. Ohne gcc wird SPRINGEND
# uebersprungen und das gesagt — ein Test, der ohne Werkzeug still gruen
# meldet, waere schlimmer als keiner.
#
# GEPRUEFT WIRD DER WEG:
#   #1620 an der SUMME, die die C-Funktion bildet — sie ist nur richtig, wenn
#         jedes einzelne Argument angekommen ist. Sechs Argumente gingen schon
#         vorher, ein Test mit sechs waere gruen gewesen.
#   #1607 daran, dass `if (n < 0)` den Fehlerfall erkennt. Der Wert allein sah
#         mit 4294967295 nach einer Zahl aus.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if ! command -v gcc >/dev/null 2>&1; then
  echo "SKIP ffi_abi_runde6: kein gcc — die Testbibliothek laesst sich nicht bauen"
  echo "--- 0 PASS, 0 FAIL (uebersprungen)"
  exit 0
fi

cat > "$TMP/argsum.c" <<'EOF'
long a6(long a,long b,long c,long d,long e,long f){return a+b+c+d+e+f;}
long a7(long a,long b,long c,long d,long e,long f,long g){return a+b+c+d+e+f+g;}
long a10(long a,long b,long c,long d,long e,long f,long g,long h,long i,long j){
  return a+b+c+d+e+f+g+h+i+j;}
long a13(long a,long b,long c,long d,long e,long f,long g,long h,long i,long j,
         long k,long l,long m){return a+b+c+d+e+f+g+h+i+j+k+l+m;}
int retneg(void){return -1;}
int retmin(void){return -2147483648;}
int retpos(void){return 42;}
unsigned int retneg_u(void){return (unsigned int)-1;}
short retshort(void){return -300;}
EOF
if ! gcc -shared -fPIC -o "$TMP/libargsum.so" "$TMP/argsum.c" 2>"$TMP/gcc.log"; then
  echo "SKIP ffi_abi_runde6: gcc konnte die Testbibliothek nicht bauen"
  echo "--- 0 PASS, 0 FAIL (uebersprungen)"
  exit 0
fi

# Uebersetzt im TMP-Verzeichnis (die link-Angabe ist relativ) und laeuft dort.
lauf() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" t.lyx -o t >c.log 2>&1); then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error|^error' "$TMP/c.log")"
    return
  fi
  local got; got="$(cd "$TMP" && LD_LIBRARY_PATH=. timeout 60 ./t 2>&1 | tr -d '\r' \
    | grep -vE 'Capabilit|^===|^Programm:|^  o |^  [A-Za-z-]+ |^$|^Runtime')"
  if [ "$got" = "$erwartet" ]; then ok "$name"; else
    no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
  fi
}

# ===========================================================================
# #1620 — Argumente ab dem siebten laufen ueber den Stapel
# ===========================================================================
lauf "#1620: 7, 10 und 13 Argumente kommen vollstaendig an" \
'21
28
55
91' 'import std.io;
@cap(ui.display)
extern fn a6(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64): int64 link "./libargsum.so";
@cap(ui.display)
extern fn a7(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64): int64 link "./libargsum.so";
@cap(ui.display)
extern fn a10(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64, j: int64): int64 link "./libargsum.so";
@cap(ui.display)
extern fn a13(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64, j: int64, k: int64, l: int64, m: int64): int64 link "./libargsum.so";
fn main(): int64 {
  PrintLn(IntToStr(a6(1,2,3,4,5,6)));
  PrintLn(IntToStr(a7(1,2,3,4,5,6,7)));
  PrintLn(IntToStr(a10(1,2,3,4,5,6,7,8,9,10)));
  PrintLn(IntToStr(a13(1,2,3,4,5,6,7,8,9,10,11,12,13)));
  return 0;
}'

# Der Aufruf darf den eigenen Rahmen nicht beschaedigen: der Wert davor und
# danach muss stehenbleiben, und zwei Aufrufe hintereinander muessen gehen.
lauf "#1620: der Stapel des Aufrufers bleibt unversehrt" \
'111
55
55
222' 'import std.io;
@cap(ui.display)
extern fn a10(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64, j: int64): int64 link "./libargsum.so";
fn main(): int64 {
  var vorher: int64 := 111;
  var nachher: int64 := 222;
  PrintLn(IntToStr(vorher));
  PrintLn(IntToStr(a10(1,2,3,4,5,6,7,8,9,10)));
  PrintLn(IntToStr(a10(1,2,3,4,5,6,7,8,9,10)));
  PrintLn(IntToStr(nachher));
  return 0;
}'

# Ein Aufruf mit Stapelargumenten INNERHALB eines Ausdrucks — dort haengt noch
# eigener Zwischenstand auf dem Stapel.
lauf "#1620: geschachtelt in einem Ausdruck" '110' 'import std.io;
@cap(ui.display)
extern fn a10(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64, j: int64): int64 link "./libargsum.so";
fn main(): int64 {
  PrintLn(IntToStr(a10(1,2,3,4,5,6,7,8,9,10) + a10(1,2,3,4,5,6,7,8,9,10)));
  return 0;
}'

# ===========================================================================
# #1607 — 32-Bit-Rueckgaben vorzeichenrichtig erweitern
# ===========================================================================
lauf "#1607: int32-Rueckgabe wird vorzeichenrichtig erweitert" \
'-1
-2147483648
42
Fehler erkannt' 'import std.io;
@cap(ui.display)
extern fn retneg(): int32 link "./libargsum.so";
@cap(ui.display)
extern fn retmin(): int32 link "./libargsum.so";
@cap(ui.display)
extern fn retpos(): int32 link "./libargsum.so";
fn main(): int64 {
  PrintLn(IntToStr(retneg()));
  PrintLn(IntToStr(retmin()));
  PrintLn(IntToStr(retpos()));
  if (retneg() < 0) { PrintLn("Fehler erkannt"); } else { PrintLn("Fehler NICHT erkannt"); }
  return 0;
}'

lauf "#1607: int16 ebenso, und uint32 bleibt vorzeichenlos" \
'-300
4294967295' 'import std.io;
@cap(ui.display)
extern fn retshort(): int16 link "./libargsum.so";
@cap(ui.display)
extern fn retneg_u(): uint32 link "./libargsum.so";
fn main(): int64 {
  PrintLn(IntToStr(retshort()));
  PrintLn(IntToStr(retneg_u()));
  return 0;
}'

# Gegenprobe: ohne Breitenangabe bleibt es beim alten Verhalten. Wer int64
# schreibt, bekommt int64 — die Regel greift nur, wo sie angegeben ist.
lauf "#1607: ohne Breitenangabe unveraendert" '4294967295' 'import std.io;
@cap(ui.display)
extern fn retneg(): int64 link "./libargsum.so";
fn main(): int64 {
  PrintLn(IntToStr(retneg()));
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
