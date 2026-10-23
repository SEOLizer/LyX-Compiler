#!/usr/bin/env bash
# tests/ausdruck_register_test.sh — Zwischenwerte in Registern, Sprungpaare
# ausgerichtet (#2228).
#
# Drei Aenderungen am x86-Codegen, jede mit ihrem Nachweis:
#
#   1. Halteregister: ein wartender linker Operand einer reinen Rechnung liegt
#      in r11, r9, r8, rdi oder rsi statt auf dem Stapel (bisher nur r11). Im
#      SHA-256-Block fielen push/pop von 268 auf 76. Die WERTE tief
#      verschachtelter Ausdruecke werden gegen Python gerechnet.
#   2. `push rax; pop reg` direkt vor einem Aufruf wird `mov reg, rax`.
#   3. JCC-Erratum: ein Paar cmp/test + bedingter Sprung, das eine 32-Byte-
#      Grenze kreuzt oder an ihr endet, laeuft auf Skylake..Coffee Lake nicht
#      aus dem uop-Cache. Ohne Ausrichtung machte Punkt 2 das Sortieren 8 %
#      LANGSAMER, weil sich ein Schleifensprung genau ueber eine Grenze schob.
#      Mit Ausrichtung: SHA-256 −8 %, CRC32 −7 %, Selbstbau −5,6 %, kein Kern
#      langsamer.
#
# Der Weg fuer 3 wird am fertigen Programm gemessen: eine Funktion mit 32
# Schleifen, deren Bedingungen auf verschiedenen Lagen mod 32 landen. Kein
# Paar darf kreuzen. Ohne Ausrichtung kreuzt rund ein Drittel.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

laeuft() { # name quelle erwartet
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/p.log" 2>&1); then
    no "$1" "uebersetzt nicht: $(grep -v Copyright "$TMP/p.log" | head -2 | tr '\n' ' ')"; return
  fi
  local got; got=$( ulimit -c 0; cd "$TMP" && timeout 30 "$TMP/p" 2>/dev/null | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "erwartet '$3', bekam '$got'"; fi
}

# Werte gegen Python gerechnet (64 Bit mit Ueberlauf, arithmetischer Shift).
laeuft "verschachtelte reine Ausdruecke (fuenf Halteregister tief)" 'import std.io;
fn main(): int64 {
  var a: int64 := 0x1234567; var b: int64 := 0x89ABCDE; var c: int64 := 77; var d: int64 := 5;
  var r1: int64 := (((a >> 2) | (a << 30)) ^ ((a >> 13) | (a << 19)) ^ ((a >> 22) | (a << 10))) & 0xFFFFFFFF;
  var r2: int64 := ((a * 3 + b) * (c - d)) - ((a ^ b) & (c | d)) + ((a % c) * (b / d));
  var r3: int64 := ((a + b) * (c + d)) - ((a - b) * (c - d)) + ((a * b) ^ (c * d)) - (((a | b) & (c ^ d)) << 3);
  PrintLn(r1); PrintLn(r2); PrintLn(r3);
  return 0;
}' "1717912647 16191549255 2755647057306661"

# Ein Aufruf mitten in einer Rechnung: dort darf kein Halteregister ueber den
# Aufruf leben (die rechte Seite ist nicht rein, es bleibt beim Stapel).
laeuft "Aufruf in einer verschachtelten Rechnung" 'import std.io;
fn g(x: int64, y: int64, z: int64, w: int64): int64 { return x * 1000 + y * 100 + z * 10 + w; }
fn main(): int64 {
  var a: int64 := 3; var b: int64 := 4;
  var r: int64 := ((a << 2) | (b >> 1)) + g(a + b, a * b, b - a, (a ^ b) & 7) * ((a | b) + 1);
  PrintLn(r);
  PrintLn(g(peek64(@a), a + 1, b, a * b - 10));
  return 0;
}' "65750 3442"

# --- Weg 2: kein push/pop vor einem Aufruf mit einem Argument ----------------
pushpop() {
  printf '%s\n' "$1" > "$TMP/c.lyx"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --emit=obj "$TMP/c.lyx" -o "$TMP/c.o" >/dev/null 2>&1) || { echo -1; return; }
  objdump -d -z --no-show-raw-insn "$TMP/c.o" 2>/dev/null | grep -cE '\spush +%rax$'
}
OHNE='import std.io;
fn main(): int64 { var p: int64 := 64; var i: int64 := 2; var s: int64 := p + i * 8; PrintLn(s); return 0; }'
MIT='import std.io;
fn main(): int64 { var p: int64 := 64; var i: int64 := 2; var s: int64 := peek64(@p) + MemPeek(p + i * 8); PrintLn(s); return 0; }
fn MemPeek(x: int64): int64 { return x; }'
o=$(pushpop "$OHNE"); m=$(pushpop "$MIT")
if [ "$o" -lt 0 ] || [ "$m" -lt 0 ]; then no "Weg: push/pop vor Aufrufen" "uebersetzt nicht"
elif [ "$m" -le $((o + 1)) ]; then ok "Weg: Argument direkt ins Register ($o -> $m push rax)"
else no "Weg: push/pop vor Aufrufen" "$o -> $m push rax"; fi

# --- Weg 3: keine Sprungpaare ueber 32-Byte-Grenzen ---------------------------
# f enthaelt 32 Schleifen; vor jeder steht eine wachsende Zahl von Zuweisungen,
# damit die Bedingungen auf alle Lagen mod 32 fallen.
{
  echo 'import std.io;'
  echo '@export'
  echo 'fn f(n: int64): int64 {'
  echo '  var s: int64 := 0;'
  for k in $(seq 0 31); do
    j=0; while [ $j -lt $k ]; do echo "  s := s + $j;"; j=$((j+1)); done
    echo "  var lauf$k: int64 := 0;"
    echo "  while (lauf$k < n) { s := s + lauf$k * $k; lauf$k += 1; }"
  done
  echo '  return s;'
  echo '}'
  echo 'fn main(): int64 { PrintLn(f(3)); return 0; }'
} > "$TMP/j.lyx"
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/j.lyx" -o "$TMP/j" --map-file >/dev/null 2>&1); then
  a=$(awk '$4=="f"{print $1}' "$TMP/j.map"); b=$(awk -v a="$a" 'f{print $1; exit} $4=="f"{f=1}' "$TMP/j.map")
  if [ -z "$a" ] || [ -z "$b" ]; then no "Weg: Sprungpaare" "f nicht in der Abbildkarte"
  else
    paare=$(objdump -D -z -b binary -m i386:x86-64 --start-address=$((a - 0x400000)) --stop-address=$((b - 0x400000)) "$TMP/j" \
      | awk -F'\t' '/^ +[0-9a-f]+:/ { split($1,x,":"); gsub(/ /,"",x[1]); adr=strtonum("0x" x[1]); n=split($2,by," "); ins=$3;
          if (ins ~ /^j(n?[a-z]+) / && ins !~ /^jmp/ && pc != "" ) {
            s=padr+0x400000; e=adr+n+0x400000;
            if (int(s/32) != int((e-1)/32) || e%32==0) kreuz++; ges++ }
          if (ins ~ /^(cmp|test)/) { pc=ins; padr=adr } else if (ins !~ /^j/) { pc="" } }
        END { print ges+0, kreuz+0 }')
    ges=${paare% *}; kreuz=${paare#* }
    if [ "$ges" -lt 32 ]; then no "Weg: Sprungpaare" "nur $ges Paare gefunden"
    elif [ "$kreuz" -eq 0 ]; then ok "Weg: $ges cmp/test+jcc-Paare, keines ueber eine 32-Byte-Grenze"
    else no "Weg: Sprungpaare" "$kreuz von $ges Paaren kreuzen eine 32-Byte-Grenze"; fi
  fi
  got=$( ulimit -c 0; timeout 20 "$TMP/j" ); exp=$(python3 -c "print(sum(sum(range(k)) for k in range(32)) + sum(k*3 for k in range(32)))")
  if [ "$got" = "$exp" ]; then ok "32 Schleifen rechnen richtig ($got)"; else no "32 Schleifen" "'$got' erwartet '$exp'"; fi
else no "Weg: Sprungpaare" "uebersetzt nicht"; fi

echo "ausdruck_register: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
