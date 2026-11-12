#!/usr/bin/env bash
# tests/bump_ir_2227_test.sh — Zeichenketten-Builtins der IR-Backends aus dem
# Bump-Block (#2227).
#
# Bis 1.2.20B holten arm64 und riscv fuer JEDEN Aufruf von StrConcat, StrSub,
# StrCopy, IntToStr und FloatToStr (riscv auch PrintInt) ein eigenes mmap: eine
# Seite, ein Mapping, nie freigegeben. 300 000 Schleifenrunden mit drei solchen
# Aufrufen kosteten auf arm64 900 000 mmap und 3,5 s; nach rund einer Million
# Mappings ist vm.max_map_count erschoepft. x86 gibt seit #1980/#2225 aus einem
# Bump-Block aus — dieselbe Rechnung jetzt in emitBumpAlloc/rv_bumpAlloc.
#
# Geprueft wird:
#   1. der WEG: je Builtin 1000 Aufrufe unter qemu -strace, hoechstens drei
#      mmap im ganzen Programm (vorher 1000+);
#   2. die WIRKUNG ueber Blockgrenzen: 20 000 IntToStr-Ergebnisse (rund 20
#      Bloecke) werden alle aufgehoben und danach einzeln zurueckgelesen —
#      ueberlappen sich Puffer, stimmt die Summe nicht;
#   3. eine Anforderung ueber 64 KiB: StrConcat verdoppelt bis 196 608
#      Zeichen, Laenge und letztes Zeichen stimmen;
#   4. die Werte aller fuenf Builtins gleich mit x86.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

bau() { # name ziel  (Quelle $TMP/name.lyx)
  local opt=""; [ "$2" != x86 ] && opt="--target=$2"
  (cd "$ROOT" && ulimit -v 4000000 && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/$1.lyx" -o "$TMP/$1.$2" >"$TMP/$1.$2.log" 2>&1)
}
lauf() { # name ziel -> stdout
  local q=""; [ "$2" = arm64 ] && q="$QEMU_ARM64"; [ "$2" = riscv ] && q="$QEMU_RISCV64"
  ( ulimit -c 0; cd "$TMP" && timeout 60 $q "$TMP/$1.$2" 2>/dev/null )
}
mmaps() { # name ziel -> Zahl der mmap-Aufrufe
  local q="$QEMU_ARM64"; [ "$2" = riscv ] && q="$QEMU_RISCV64"
  ( ulimit -c 0; cd "$TMP" && timeout 60 $q -strace "$TMP/$1.$2" 2>&1 | grep -c 'mmap(' )
}

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: qemu fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: qemu fuer riscv fehlt"

# --- 1 + 4: je Builtin 1000 Aufrufe ---------------------------------------
n=0
for rumpf in \
  'var t: pchar := IntToStr(i - 500); s := s + StrLen(t) + StrToInt(t);' \
  'var u: pchar := StrConcat("ab", IntToStr(i)); s := s + StrLen(u);' \
  'var v: pchar := StrSub("abcdefgh", i % 5, 3); s := s + StrLen(v) + StrCharAt(v, 0);' \
  'var w: pchar := StrCopy("hallo"); s := s + StrLen(w) + StrCharAt(w, 4);' \
  'var x: f64 := (i as f64) * 0.5; var y: pchar := FloatToStr(x); s := s + StrLen(y) + StrCharAt(y, 0);'; do
  n=$((n+1)); name="b$n"
  printf 'import std.io;\nimport std.string;\nfn main(): int64 {\n  var i: int64 := 0; var s: int64 := 0;\n  while (i < 1000) { %s i := i + 1; }\n  PrintLn(s); return 0;\n}\n' "$rumpf" > "$TMP/$name.lyx"
  soll=""
  for z in $ZIELE; do
    if ! bau "$name" "$z"; then no "$name $z" "uebersetzt nicht: $(grep -i error "$TMP/$name.$z.log" | head -1)"; continue; fi
    got="$(lauf "$name" "$z")"
    if [ -z "$soll" ]; then soll="$got"
    elif [ "$got" != "$soll" ]; then no "$name $z Wert" "'$got' statt '$soll' (x86)"; continue; fi
    if [ "$z" != x86 ]; then
      m="$(mmaps "$name" "$z")"
      if [ "$m" -le 3 ]; then ok "$name $z: Wert $got wie x86, $m mmap fuer 1000 Aufrufe"
      else no "$name $z" "$m mmap fuer 1000 Aufrufe (erwartet <= 3)"; fi
    fi
  done
done

# --- 2: viele Ergebnisse ueber Blockgrenzen aufheben -----------------------
cat > "$TMP/viele.lyx" <<'LYX'
import std.io;
import std.string;
fn main(): int64 {
  var n: int64 := 20000;
  var tab: int64 := alloc(n * 8);
  var i: int64 := 0;
  while (i < n) { poke64(tab + i * 8, IntToStr(i * 7 - 3) as int64); i := i + 1; }
  var falsch: int64 := 0;
  var s: int64 := 0;
  i := 0;
  while (i < n) {
    var w: int64 := StrToInt(peek64(tab + i * 8) as pchar);
    if (w != i * 7 - 3) { falsch := falsch + 1; }
    s := s + w;
    i := i + 1;
  }
  PrintLn(falsch); PrintLn(s);
  return 0;
}
LYX
# Summe von 7i-3 fuer i < 20000: 7*19999*20000/2 - 3*20000
ERW="0 1399870000"
for z in $ZIELE; do
  if ! bau viele "$z"; then no "viele $z" "uebersetzt nicht: $(grep -i error "$TMP/viele.$z.log" | head -1)"; continue; fi
  got="$(lauf viele "$z" | tr '\n' ' ')"; got="${got% }"
  if [ "$got" = "$ERW" ]; then ok "viele $z: 20000 Ergebnisse ueber Blockgrenzen unversehrt"
  else no "viele $z" "'$got' erwartet '$ERW'"; fi
done

# --- 3: Anforderung ueber 64 KiB -------------------------------------------
cat > "$TMP/gross.lyx" <<'LYX'
import std.io;
import std.string;
fn main(): int64 {
  var s: pchar := StrConcat("abc", "");
  var k: int64 := 0;
  while (k < 16) { s := StrConcat(s, s); k := k + 1; }
  var t: pchar := StrConcat(s, "Z");
  var n: int64 := StrLen(t);
  // Builtin-Ergebnisse erst in Variablen: arm64/riscv bestimmen den Typ
  // eines Builtin-Aufrufs als Print-Argument nicht (vorbestehend).
  var c1: int64 := StrCharAt(t, n - 1);
  var c2: int64 := StrCharAt(t, n - 2);
  PrintLn(n); PrintLn(c1); PrintLn(c2);
  return 0;
}
LYX
ERW="196609 90 99"
for z in $ZIELE; do
  if ! bau gross "$z"; then no "gross $z" "uebersetzt nicht: $(grep -i error "$TMP/gross.$z.log" | head -1)"; continue; fi
  got="$(lauf gross "$z" | tr '\n' ' ')"; got="${got% }"
  if [ "$got" = "$ERW" ]; then ok "gross $z: 196 609 Zeichen, Ende 'Z'"
  else no "gross $z" "'$got' erwartet '$ERW'"; fi
done

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
