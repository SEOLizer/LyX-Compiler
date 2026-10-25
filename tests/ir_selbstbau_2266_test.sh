#!/usr/bin/env bash
# tests/ir_selbstbau_2266_test.sh — Builtins fuer den arm64-Selbstbau und das
# logische Nicht auf den IR-Zielen (#2266).
#
# Der Selbstbau `lyxc src/lyxc.lyx --target=arm64` scheiterte nach #2260 an
# sieben Builtins, die nur lyxos kannte: die fest geslotteten sys_*-Aufrufe
# (21/23, dazu 32/33), EPrintInt (234), peekf64/pokef64 (253/254),
# StrStartsWith (405), FileReadAll (409). ir_lower setzt sie auf den
# Linux-IR-Zielen jetzt aus vorhandenen Bausteinen zusammen (lyxos behaelt
# seine nativen IDs); StrEq (404) aus derselben Familie mit.
#
# Dahinter lag ein schwerer Defekt: `!x`/`not x` war auf arm64, riscv, esp32
# und arm-cm BITWEISE (IRO_NOT als MVN/xori -1) — `not true` war wahr, jedes
# `if not x` lief falsch herum. Der arm64-Compiler stieg deshalb bei
# `if not cliOk { return }` still aus.
#
# Geprueft wird die WIRKUNG auf x86, arm64 und riscv (gleiche Ausgabe), dazu
# der Selbstbau: das arm64- und das riscv-Erzeugnis von lyxc uebersetzen unter
# qemu ein Programm, das richtig rechnet (riscv seit #2271).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
# Der Selbstbau uebersetzt die Compilerquelle (allein 52-62 s, unter Last mehr):
# die Grenzen, die lyxc_guard.sh dafuer nennt. Mit 60 s brach er unter
# Volllast ab (#2271).
LYXC_VM_KB=$(( 8 * 1024 * 1024 )); LYXC_TIMEOUT=900
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"
# Dateien vor JEDEM Lauf frisch: sys_truncate kuerzt eine davon.
dateien() { printf 'Zeile eins\nZeile zwei\n' > "$TMP/eingabe.txt"; printf 'abcdefgh' > "$TMP/kurz.txt"; }

fall() { # name erwartet  (Quelle auf stdin; @TMP@ wird ersetzt)
  local name="$1" erw="$2"
  sed "s|@TMP@|$TMP|g" > "$TMP/$name.lyx"
  local z
  for z in $ZIELE; do
    local opt="" q=""
    [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
    [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$name.lyx" -o "$TMP/$name.$z" >"$TMP/$name.$z.log" 2>&1); then
      no "$name $z" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/$name.$z.log")"; continue
    fi
    local got
    dateien
    got=$( cd "$TMP" && timeout 60 $q "$TMP/$name.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
    if [ "$got" = "$erw" ]; then ok "$name $z: $got"; else no "$name $z" "'$got' erwartet '$erw'"; fi
  done
}

# 1. Logisches Nicht — bool aus Aufruf, Literal-Variable, Ganzzahl.
fall nicht "2 3 6 8 0 1" <<'LYX'
import std.io;
fn wahr(): bool { return true; }
fn falsch(): bool { return false; }
fn main(): int64 {
  var a: bool := wahr();
  var b: bool := falsch();
  if not a { PrintLn(1); } else { PrintLn(2); }
  if not b { PrintLn(3); } else { PrintLn(4); }
  if !a { PrintLn(5); } else { PrintLn(6); }
  var c: bool := true;
  if not c { PrintLn(7); } else { PrintLn(8); }
  var x: int64 := 5; var y: int64 := 0;
  var nx: int64 := (!x) as int64; var ny: int64 := (!y) as int64;
  PrintLn(nx); PrintLn(ny);
  return 0;
}
LYX

# 2. Zeichenketten und Datei: StrEq, StrStartsWith, FileReadAll.
# "Zeile eins\n": Index 7 ist 'i' (105).
fall zeichen_datei "1 0 1 0 1 22 105" <<'LYX'
import std.io;
fn main(): int64 {
  var e1: int64 := StrEq("abc", "abc") as int64;
  var e2: int64 := StrEq("abc", "abd") as int64;
  var s1: int64 := StrStartsWith("--std-path=.", "--std") as int64;
  var s2: int64 := StrStartsWith("--std", "--std-path") as int64;
  var s3: int64 := StrStartsWith("abc", "") as int64;
  PrintLn(e1); PrintLn(e2); PrintLn(s1); PrintLn(s2); PrintLn(s3);
  var t: pchar := FileReadAll("@TMP@/eingabe.txt");
  var n: int64 := StrLen(t);
  PrintLn(n);
  var c: int64 := StrCharAt(t, 7);
  PrintLn(c);
  return 0;
}
LYX

# 3. sys_*-Aufrufe (fest geslottet) und EPrintInt/peekf64/pokef64.
# sys_write gibt "abcdefg" selbst aus; es steht deshalb in der Zeile.
fall sys_und_f64 "11 9 abcdefg 7 1" <<'LYX'
import std.io;
import std.alloc;
fn main(): int64 {
  var fd: int64 := sys_open("@TMP@/eingabe.txt", 0, 0);
  var buf: int64 := alloc(64);
  var r: int64 := sys_read(fd, buf as pchar, 11);
  sys_close(fd);
  PrintLn(r);
  var p: int64 := alloc(16);
  var f: f64 := 2.25;
  pokef64(p, f);
  var g: f64 := peekf64(p);
  var h: int64 := (g * 4.0) as int64;
  PrintLn(h);
  var w: int64 := sys_write(1, "abcdefg\n", 8);
  PrintLn(w - 1);
  var leer: int64 := sys_truncate("@TMP@/kurz.txt", 1);
  PrintLn(leer + 1);
  return 0;
}
LYX
# EPrintInt geht auf stderr — getrennt geprueft.
cat > "$TMP/ep.lyx" <<'LYX'
import std.io;
fn main(): int64 { EPrintInt(4711); return 0; }
LYX
for z in $ZIELE; do
  opt=""; q=""
  [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
  [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/ep.lyx" -o "$TMP/ep.$z" >/dev/null 2>&1); then
    err=$( cd "$TMP" && timeout 60 $q "$TMP/ep.$z" 2>&1 >/dev/null )
    if [ "$err" = "4711" ]; then ok "EPrintInt $z auf stderr"; else no "EPrintInt $z" "stderr '$err'"; fi
  else no "EPrintInt $z" "uebersetzt nicht"; fi
done

# 4. Selbstbau: lyxc fuer arm64 und riscv, das Erzeugnis uebersetzt unter qemu
# ein Programm. riscv (#2271): eine Funktion des Compilers liegt ueber 1 MiB —
# JAL reichte nicht, und main(argc, argv) bekam kein argc.
printf 'import std.io;\nfn main(): int64 {\n  var s: int64 := 0; var i: int64 := 1;\n  while (i <= 10) { s := s + i * i; i += 1; }\n  PrintLn(s);\n  return 0;\n}\n' > "$TMP/h.lyx"
for z in arm64 riscv; do
  q="$QEMU_ARM64"; em_soll=183
  [ "$z" = riscv ] && { q="$QEMU_RISCV64"; em_soll=243; }
  [ -n "$q" ] || continue
  (cd "$ROOT" && ulimit -v 8000000 && timeout 1200 "$LYXC" --std-path="$ROOT" --target=$z src/lyxc.lyx -o "$TMP/lyxc_$z" >"$TMP/sb.log" 2>&1); sbRc=$?
  if [ "$sbRc" -eq 0 ]; then
    em=$(od -An -tu2 -j18 -N2 "$TMP/lyxc_$z" | tr -d ' ')
    if [ "$em" = "$em_soll" ]; then ok "Selbstbau $z: Erzeugnis e_machine $em"; else no "Selbstbau $z" "e_machine $em"; fi
    rm -f "$TMP/h"
    ( cd "$ROOT" && ulimit -v 8000000 && timeout 600 "$q" "$TMP/lyxc_$z" "$TMP/h.lyx" --std-path="$ROOT" -o "$TMP/h" >"$TMP/h.log" 2>&1 )
    got=$( [ -x "$TMP/h" ] && "$TMP/h" )
    if [ "$got" = "385" ]; then ok "$z-Compiler uebersetzt ein Programm (Ergebnis 385)"
    else no "$z-Compiler" "Ergebnis '$got' ($(grep -m1 -iE 'error|signal|Verwendung' "$TMP/h.log"))"; fi
  else no "Selbstbau $z" "rc $sbRc: $(grep -v '^ \|^=\|^$' "$TMP/sb.log" | tail -2 | tr '\n' ' ')"; fi
done

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
