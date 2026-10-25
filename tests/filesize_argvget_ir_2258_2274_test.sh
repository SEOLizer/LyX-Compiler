#!/usr/bin/env bash
# tests/filesize_argvget_ir_2258_2274_test.sh — zwei Luecken der IR-Ziele
# (arm64, riscv), beide aus derselben Klasse "eine Aufzaehlung ist
# unvollstaendig".
#
#   #2258  FileSize (Builtin-ID 406) war nur auf x86 und lyxos vorhanden.
#          arm64/riscv wiesen die ID laut ab — damit war std.csv auf diesen
#          Zielen GAR NICHT uebersetzbar (CsvOpen ruft FileSize), und der
#          Dateiweg von std.nn_io ebenso. ir_lower setzt FileSize dort jetzt
#          aus open (220), lseek (228) und close (221) zusammen, wie
#          FileReadAll seit #2266. Gemessen wird die GROESSE einer Datei
#          bekannter Laenge, nicht die Uebersetzbarkeit; Gegenseite: eine
#          fehlende Datei muss -1 liefern, nicht 0 — 0 ist eine gueltige
#          Dateigroesse.
#
#   #2274  `PrintLn(ArgvGet(argv, 1))` gab auf x86 still die ADRESSE des
#          Arguments als Zahl aus und wurde auf arm64/riscv abgewiesen:
#          ArgvGet stand in keiner der DREI Listen "liefert pchar"
#          (cg_isPcharExpr, cg_builtinReturnsPchar, _printArt). Die drei sind
#          jetzt eine (src/backend/builtin_typen.lyx). Gemessen wird der
#          ausgegebene TEXT auf allen drei Zielen; Gegenseite: ein Builtin,
#          das eine Zahl liefert (popcount), muss weiter als Zahl ausgegeben
#          werden — eine zu weite Liste wuerde hier eine Adresse drucken.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

dateien() {
  printf 'abcdefghij'      > "$TMP/zehn.txt"       # 10 Byte
  printf ''                > "$TMP/leer.txt"       # 0 Byte, gueltige Groesse
  printf 'a,b\n1,2\n3,4\n' > "$TMP/t.csv"
  rm -f "$TMP/fehlt.txt"
}

fall() { # name erwartet [programmargumente...]
  local name="$1" erw="$2"; shift 2
  sed "s|@TMP@|$TMP|g" > "$TMP/$name.lyx"
  local z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$name.$z.log")"; continue
    fi
    dateien
    local got
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" "$@" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# 1. #2258: Groesse einer Datei bekannter Laenge, Leerdatei, fehlende Datei.
fall groesse "10 0 -1" <<'LYX'
unit main;
import std.fs;
fn main(): int64 {
  PrintInt(FileSize("@TMP@/zehn.txt"c)); PrintStr("\n"c);
  PrintInt(FileSize("@TMP@/leer.txt"c)); PrintStr("\n"c);
  PrintInt(FileSize("@TMP@/fehlt.txt"c)); PrintStr("\n"c);
  return 0;
}
LYX

# 2. #2258: die WIRKUNG — std.csv liest auf allen drei Zielen dieselbe Tabelle.
#    Vor dem Fix uebersetzte diese Unit auf arm64/riscv nicht.
fall csv "2 2" <<'LYX'
unit main;
import std.csv;
fn main(): int64 {
  var t: int64 := CsvOpenCsv("@TMP@/t.csv"c, true);
  PrintInt(CsvRowCount(t)); PrintStr(" "c); PrintInt(CsvColCount(t)); PrintStr("\n"c);
  CsvFree(t);
  return 0;
}
LYX

# 3. #2274: ArgvGet und GetArg als Zeichenkette — der TEXT, nicht die Adresse.
fall argvget "hallo hallo welt" hallo welt <<'LYX'
unit main;
import std.io;
pub fn main(argc: int64, argv: pchar): int64 {
  PrintLn(ArgvGet(argv, 1));
  PrintStr(GetArg(1)); PrintStr(" "c); PrintStr(GetArg(2)); PrintStr("\n"c);
  return 0;
}
LYX

# 4. Gegenseite zu #2274: ein Builtin, das eine ZAHL liefert, bleibt eine Zahl.
#    Eine zu weit gefasste Liste "liefert pchar" wuerde hier den Wert als
#    Adresse lesen und Muell drucken oder abstuerzen.
fall zahl "8 63" <<'LYX'
unit main;
fn main(): int64 {
  PrintInt(popcount(255)); PrintStr("\n"c);
  PrintInt(clz(1)); PrintStr("\n"c);
  return 0;
}
LYX

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
