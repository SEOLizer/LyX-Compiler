#!/usr/bin/env bash
# tests/ir_mmap_test.sh — #2122: mmap auf dem IR-Weg mit allen sechs Argumenten.
#
# Bis 1.2.14B wurde `mmap(addr, len, prot, flags, fd, off)` auf arm64/riscv zu
# IRO_ALLOC(len): Schutz, Flags, Deskriptor und Offset fielen still weg. Eine
# Dateiabbildung lieferte Nullen statt des Inhalts, PROT_EXEC kam nie an.
#
# Gemessen an der WIRKUNG: der Inhalt einer abgebildeten Datei, und die
# Schutzbits, die der Kernel bekommt (qemu -strace). Gegenseite: die anonyme
# RW-Abbildung, wie std/alloc sie nutzt, bleibt anonym und RW.
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

printf 'LYX!mmap' > "$TMP/daten.bin"
cat > "$TMP/m.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var fd: int64 := open("daten.bin"c, 0, 0);
  var p: int64 := mmap(0, 4096, 1, 2, fd, 0);          // PROT_READ, MAP_PRIVATE, Datei
  if (p < 0) { PrintLn("mmap Datei"); return 2; }
  PrintLn(IntToStr(peek8(p)));
  PrintLn(IntToStr(peek8(p + 7)));
  var q: int64 := mmap(0, 4096, 7, 34, 0 - 1, 0);      // RWX, anonym
  poke64(q, 5);
  PrintLn(IntToStr(peek64(q)));
  var a: int64 := mmap(0, 8192, 3, 34, 0 - 1, 0);      // RW, anonym (wie std/alloc)
  poke64(a + 8000, 9);
  PrintLn(IntToStr(peek64(a + 8000)));
  return 0;
}
EOF
for t in arm64 riscv; do
  case $t in arm64) q="$QEMU_ARM64" ;; riscv) q="$QEMU_RISCV64" ;; esac
  if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$t "$TMP/m.lyx" -o "$TMP/m_$t" ) >"$TMP/bl.log" 2>&1; then
    nok "[$t] uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
  fi
  aus="$( (cd "$TMP" && timeout 30 "$q" "./m_$t" 2>/dev/null) | tr '\n' '|')"
  # 'L' = 76, 'p' = 112: der Dateiinhalt, nicht Nullen.
  if [ "$aus" = "76|112|5|9|" ]; then ok "[$t] Datei abgebildet, Inhalt gelesen: [$aus]"
  else nok "[$t] [$aus] statt [76|112|5|9|]"; fi
  st="$( (cd "$TMP" && timeout 30 "$q" -strace "./m_$t" 2>&1 >/dev/null) | grep -E '^[0-9]+ mmap\(NULL,(4096|8192),' )"
  if echo "$st" | grep -q 'mmap(NULL,4096,PROT_READ,MAP_PRIVATE,3,0)'; then ok "[$t] Dateiabbildung: PROT_READ, MAP_PRIVATE, fd 3"
  else nok "[$t] Dateiabbildung nicht wie verlangt: $(echo "$st" | head -1)"; fi
  if echo "$st" | grep -q 'mmap(NULL,4096,PROT_EXEC|PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0)'; then ok "[$t] PROT_EXEC kommt an"
  else nok "[$t] RWX nicht verlangt: $(echo "$st" | sed -n 2p)"; fi
  if echo "$st" | grep -q 'mmap(NULL,8192,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0)'; then ok "[$t] anonyme RW-Abbildung unveraendert"
  else nok "[$t] anonyme RW-Abbildung veraendert: $(echo "$st" | sed -n 3p)"; fi
done
echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
