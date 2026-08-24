#!/usr/bin/env bash
# tests/lyxos_argv_test.sh — _start holt argc/argv vom Startstapel (#1754).
#
# Lyx OS legt argc und argv nach AMD64-SysV auf den Startstapel, fuer ELF- und
# LBF-Kinder gleich (kernel/lbf_exec.lyx LbfPrepare, kernel/sched_ring3.lyx
# LoadElfSched): beim Sprung nach `entry` zeigt rsp auf argc, dahinter stehen
# die argv-Zeiger. Der lyxos-Startrumpf fasste rsp nicht an -- GetArgC() war
# fest 0, und jedes Kommandozeilenwerkzeug als LBF lief in seine Usage-Meldung.
#
# Geprueft wird die erzeugte Befehlsfolge, nicht der Rueckgabewert: ausfuehren
# liesse sich das nur auf dem Geraet, wo ein Aufrufer die Argumente legt. Der
# hiesige Pruefstand (lbf_run) springt mit dem Stapel des Laufzeit-Wirts an --
# was dort bei [rsp] steht, sagt ueber den Fix nichts aus. Ein Ergebnistest
# waere hier also genau die Sorte gruener Test, die nichts misst.
#
# Vor dem Fix waeren alle Pruefungen rot: der Rumpf begann mit
# `xor rbp,rbp` direkt gefolgt vom Canary-Seed, und GetArgC emittierte
# `xor rax,rax`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { return GetArgC(); }' > "$TMP/c.lyx"
if ! LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lbf" >"$TMP/log" 2>&1; then
  echo "FAIL Uebersetzung: $(grep -iE 'error' "$TMP/log" | head -1)"; exit 1
fi
ok "uebersetzt --target=lyxos"
xxd -p "$TMP/c.lbf" | tr -d '\n' > "$TMP/hex"

# 1. Startrumpf liest [rsp] und [rsp+8] und legt beides in den Datenbereich.
#    4831ed        xor rbp,rbp
#    488b0424      mov rax,[rsp]            <- argc
#    488905 d32    mov [rip+d32],rax
#    488d442408    lea rax,[rsp+8]          <- argv
#    488905 d32    mov [rip+d32],rax
if grep -q "4831ed488b0424488905........488d442408488905" "$TMP/hex"; then
  ok "_start sichert argc aus [rsp] und argv aus [rsp+8]"
else
  no "_start-Folge" "argc/argv werden nicht vom Stapel geholt"
fi

# 2. Der Canary-Seed folgt DANACH, nicht direkt auf xor rbp,rbp.
#    Vor dem Fix stand dort 4831ed48b88a...(movabs rax,138).
if grep -q "4831ed48b88a00000000000000" "$TMP/hex"; then
  no "Reihenfolge" "Canary-Seed steht direkt hinter xor rbp,rbp — argc/argv fehlen"
else
  ok "Canary-Seed erst nach dem Sichern der Argumente"
fi

# 3. GetArgC laedt RIP-relativ, statt ein festes 0 zu erzeugen.
if grep -q "488b05" "$TMP/hex"; then
  ok "GetArgC laedt aus dem Datenbereich (MOV rax,[rip+d32])"
else
  no "GetArgC" "kein RIP-relativer Ladebefehl im Programm"
fi

# 4. Und liest DASSELBE Wort, das _start beschrieben hat. Beide Displacements
#    zeigen auf dieselbe absolute Stelle; verglichen wird ueber die Zieladresse.
python3 - "$TMP/c.lbf" <<'PY'
import sys, re
b = open(sys.argv[1], 'rb').read()
i = b.find(bytes.fromhex('4831ed488b0424'))
if i < 0:
    print("FAIL Zielabgleich: Startrumpf nicht gefunden"); sys.exit(1)
def ziel(off, insn_len, disp_at):
    d = int.from_bytes(b[off+disp_at:off+disp_at+4], 'little', signed=True)
    return off + insn_len + d
schreib = ziel(i+7, 7, 3)            # mov [rip+d32],rax  (argc)
j = b.find(bytes.fromhex('488b05'), i+30)
if j < 0:
    print("FAIL Zielabgleich: kein Ladebefehl nach dem Startrumpf"); sys.exit(1)
lese = ziel(j, 7, 3)
if schreib == lese:
    print("PASS GetArgC liest genau das Wort, das _start schreibt (0x%x)" % schreib)
else:
    print("FAIL Zielabgleich: _start schreibt 0x%x, GetArgC liest 0x%x" % (schreib, lese))
    sys.exit(1)
PY
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

# 5. Die Offsets des CALL nach main kommen aus dem Rumpf, nicht aus Literalen.
if grep -q "startCallRel32Off" "$ROOT/src/lyxc.lyx"; then
  ok "CALL-Offset stammt vom Startrumpf (keine festen Zahlen in lyxc.lyx)"
else
  no "CALL-Offset" "lyxc.lyx traegt wieder feste Zahlen"
fi

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
