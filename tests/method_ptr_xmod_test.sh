#!/usr/bin/env bash
# tests/method_ptr_xmod_test.sh — B2 #3: method-pointer-Feld auf IMPORTIERTER Klasse (cross-module).
# Widget-Unit definiert method-Typ-Alias + Klasse mit method-Feld; App importiert + bindet Handler.
# ELF: runtime; LyxOS: compile + Disasm (lea fn-addr = fat-assign, call rax = fat-call).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
mkdir -p "$TMP/widgets"
cat > "$TMP/widgets/vui.lyx" <<'EOF'
pub type TControl = class { x: int64; };
pub type TNotifyMethod = method(TControl): int64;
pub type TButton = class extends TControl { on_click: TNotifyMethod; };
EOF
cat > "$TMP/app.lyx" <<'EOF'
import widgets.vui;
type TForm = class { tag: int64; fn Handle(s: TControl): int64 { return self.tag + s.x; } };
fn main(): int64 { var f: TForm := new TForm(); f.tag := 30; var b: TButton := new TButton(); b.x := 12; b.on_click := f.Handle; return b.on_click(b as TControl); }
EOF
# ELF runtime: self.tag(30)+s.x(12)=42
( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" app.lyx -o "$TMP/appe" >/dev/null 2>&1 )
if [ -f "$TMP/appe" ]; then timeout 5 "$TMP/appe" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 42 ]; then echo "PASS elf_xmod (=42)"; PASS=$((PASS+1)); else echo "FAIL elf_xmod: exit=$rc"; FAIL=$((FAIL+1)); fi
else echo "FAIL elf_xmod: compile"; FAIL=$((FAIL+1)); fi
# LyxOS: compile + fat-assign(lea)/fat-call(call rax) im Code (runtime braucht Kernel wg. new)
( cd "$TMP" && LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos app.lyx -o "$TMP/appl.lyxnative" >/dev/null 2>&1 )
if [ -f "$TMP/appl.lyxnative" ]; then
  if python3 -c "
import sys
d=open('$TMP/appl.lyxnative','rb').read();c=b''.join(d[b*4096+64:b*4096+64+4032] for b in range(1,len(d)//4096))
sys.exit(0 if (b'\x48\x8d\x05' in c and b'\xff\xd0' in c) else 1)"; then
    echo "PASS lyxos_xmod (lea fn-addr + call rax)"; PASS=$((PASS+1))
  else echo "FAIL lyxos_xmod: kein fat-assign/call im Code"; FAIL=$((FAIL+1)); fi
else echo "FAIL lyxos_xmod: compile"; FAIL=$((FAIL+1)); fi
echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]
