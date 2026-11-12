#!/usr/bin/env bash
# tests/index_pchar_test.sh — #2131: `s[i]` auf einem pchar ist das BYTE i,
# auf allen Zielen; ein Index auf einen Skalar wird laut abgewiesen.
#
# Bis 1.2.15A:
#   - Der IR-Weg (arm64, riscv, lyxos) las `s[i]` mit IRO_LOAD_IDX, also
#     8 Byte ab s+8i: "HELLO"[1] lieferte Muell, x86 die richtige 69.
#     Ebenso schrieb `s[i] := b` 8 Byte an s+8i.
#   - x86 kannte pchar nur als Bezeichner. Ein pchar-FELD, `x as pchar`,
#     eine pchar-Konstante und ein Aufruf mit pchar-Rueckgabe fielen in den
#     Zweig "roher Zeiger".
#   - Dieser Zweig sprang mit `jnz +7` zwei Byte zu weit, mitten in den
#     Ladebefehl: `p[i]` mit `p: int64` lieferte den Zeiger selbst (unteres
#     Byte um 0xD8 verschoben), unabhaengig von i. Der IR-Weg las 8 Byte.
#
# Gemessen wird der WERT auf x86_64, arm64, android-arm64 und riscv — und
# die Wirkung des Schreibens ueber peek64 auf das ganze Wort (nur das eine
# Byte darf sich aendern). Gegenseite: Index auf int64 (Bezeichner,
# Parameter, Cast, Aufruf, Feld) wird auf jedem Ziel laut abgewiesen.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) timeout 30 "$2" ;;
    arm64|android-arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

pruefe() {  # name, datei, soll-ausgabe
  local t
  for t in linux arm64 android-arm64 riscv; do
    rm -f "$TMP/p"
    if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$2" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; continue
    fi
    local aus rc
    aus="$(lauf $t "$TMP/p" 2>/dev/null | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$3" ] && [ "$rc" = "0" ]; then ok "$1 [$t]: [$aus]"
    else nok "$1 [$t]: [$aus] rc=$rc statt [$3]"; fi
  done
}

# Der Fall aus dem Issue: "HELLO"[1] = 69 ('E').
cat > "$TMP/issue.lyx" <<'EOF'
fn main(): int64 {
  var s: pchar := "HELLO";
  PrintInt(s[1]); Print("\n");
  PrintInt(s[4]); Print("\n");
  return 0;
}
EOF
pruefe "Issue: \"HELLO\"[1]" "$TMP/issue.lyx" "69|79|"

# Alle Herkuenfte eines pchar, lesend und schreibend. Das Schreiben wird am
# ganzen Wort gemessen: nach b[3] := 77 muss peek64 genau 77 << 24 liefern —
# eine 8-Byte-Schreibweise an Offset 24 laege ausserhalb des Wortes, eine an
# Offset 3 zerstoerte die Nachbarbytes nicht sichtbar, aber verschiebt den
# Wert; nur das Byte trifft 1291845632.
cat > "$TMP/herkunft.lyx" <<'EOF'
import std.alloc;
type T = class {
  s: pchar;
  n: int64;
};
con K: pchar := "WORLD";
var g: pchar;
fn gib(): pchar { return "ABCDEF"; }
fn par(q: pchar, i: int64): int64 { return q[i]; }
fn main(): int64 {
  var t: T := new T();
  t.s := "XYZ";
  PrintInt(t.s[2]); Print(" ");
  PrintInt(gib()[4]); Print(" ");
  PrintInt(K[1]); Print(" ");
  PrintInt("HELLO"[1]); Print(" ");
  PrintInt(par("abc", 2)); Print("\n");
  var p: int64 := alloc(16);
  poke64(p, 0); poke64(p + 8, 0);
  (p as pchar)[3] := 77;
  PrintInt((p as pchar)[3]); Print(" ");
  PrintInt(peek64(p)); Print("\n");
  g := p as pchar;
  g[5] := 9;
  PrintInt(g[5] + g[3]); Print(" ");
  t.s := p as pchar;
  t.s[6] := 1;
  PrintInt(peek64(p)); Print(" ");
  PrintInt(peek64(p + 8)); Print("\n");
  var b: pchar := alloc(8) as pchar;
  var i: int64 := 0;
  while (i < 7) { b[i] := 97 + i; i := i + 1; }
  b[7] := 0;
  PrintLn(b);
  return 0;
}
EOF
pruefe "pchar: Feld, Aufruf, Konstante, Literal, Parameter, Cast, Modulvariable" "$TMP/herkunft.lyx" \
  "90 69 79 69 99|77 1291845632|86 291371873206272 0|abcdefg|"

# Gegenseite: Index auf einen Skalar. Jede Herkunft laut, auf beiden
# Codegen-Wegen (x86 direkt, arm64/riscv ueber ir_lower). Gemessen wird die
# Meldung mit der Issue-Nummer UND dass keine Binary entsteht.
neg() {  # name, quelltext
  printf '%s\n' "$2" > "$TMP/neg.lyx"
  local t
  for t in linux arm64 riscv; do
    rm -f "$TMP/n"
    ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/neg.lyx" -o "$TMP/n" ) >"$TMP/n.log" 2>&1; local rc=$?
    if [ "$rc" != "0" ] && [ ! -s "$TMP/n" ] && grep -q "#2131" "$TMP/n.log"; then ok "$1 [$t]: laut abgewiesen"
    else nok "$1 [$t]: rc=$rc, keine #2131-Meldung ($(head -c 200 "$TMP/n.log" | tr '\n' ' '))"; fi
  done
}
neg "int64-Local" 'import std.alloc;
fn main(): int64 { var p: int64 := alloc(32); poke64(p + 8, 22); PrintInt(p[1]); return 0; }'
neg "int64-Parameter" 'fn f(p: int64): int64 { return p[3]; }
fn main(): int64 { PrintInt(f(4096)); return 0; }'
neg "Cast nach int64" 'fn main(): int64 { var s: pchar := "HELLO"; PrintInt((s as int64)[1]); return 0; }'
neg "Aufruf mit int64-Rueckgabe" 'fn f(): int64 { return 4096; }
fn main(): int64 { PrintInt(f()[1]); return 0; }'
neg "Schreiben auf int64" 'import std.alloc;
fn main(): int64 { var p: int64 := alloc(32); p[1] := 5; PrintInt(peek64(p + 8)); return 0; }'
neg "int64-Feld (sema kennt den Typ nicht)" 'import std.alloc;
type T = class { buf: int64; };
fn main(): int64 { var t: T := new T(); t.buf := alloc(32); PrintInt(t.buf[1]); return 0; }'
neg "Schreiben auf int64-Feld" 'import std.alloc;
type T = class { buf: int64; };
fn main(): int64 { var t: T := new T(); t.buf := alloc(32); t.buf[1] := 5; return 0; }'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
