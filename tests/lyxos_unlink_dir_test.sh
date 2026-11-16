#!/usr/bin/env bash
# tests/lyxos_unlink_dir_test.sh -- rmdir und unlink auf die flache Kernelform
# von sys_unlink (#2531, Gestaltaenderung mit lyx-os 1fe08f7).
#
# ZWEI Befunde, eine Ursache: der Kernel hat Nr 97 von einem auf ZWEI
# Argumente geaendert, `sys_unlink(path_phys, flags)`, Bit 0 = UNLINK_DIR.
#
#   * `rmdir` emittierte 0x0208 (520) -- eine Nummer aus der Entwurfs-ABI, die
#     es nie gab. Jeder --target=lyxos-Bau, der rmdir erreichte, brach ab.
#   * `unlink` emittierte 97 mit EINEM Argument. Damit blieb rsi ungesetzt und
#     der Kernel las dort Muell als Flags -- ein gesetztes Bit 0 haette aus
#     dem Loeschen einer Datei das Loeschen eines Verzeichnisses gemacht.
#
# GEPRUEFT WIRD AM ERZEUGNIS, nicht an der Meldung und nicht an "uebersetzt":
# die Bytefolge `48 B8 61 00 00 00 00 00 00 00` (mov rax, 97) gefolgt von
# `48 C7 C6 <imm32>` (mov rsi, imm). Der Unterschied zwischen den beiden
# Faellen ist genau dieses Imm -- 0 fuer unlink, 1 fuer rmdir. Ein Test, der
# nur das Vorhandensein der 97 prueft, waere von beiden Faellen erfuellt und
# damit blind fuer eine Verwechslung (#1789).
#
# Die Gegenprobe gehoert dazu: 520 darf im Erzeugnis NICHT mehr vorkommen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

# erwartetes Flag am Erzeugnis messen: name, quelle, flag
fall() {
  printf 'import std.fs;\nfn main(): int64 { var r: bool := %s("/tmp/x"); if (r) { PrintLn("weg"); } return 0; }\n' "$2" > "$TMP/$1.lyx"
  if ! ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/$1.lyx" -o "$TMP/$1.lbf" ) >"$TMP/$1.log" 2>&1; then
    echo "FAIL $1: uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID' "$TMP/$1.log" | cut -c1-90)"
    FAIL=$((FAIL+1)); return
  fi
  local got
  got=$(python3 - "$TMP/$1.lbf" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
pat = bytes([0x48, 0xB8]) + (97).to_bytes(8, 'little')     # mov rax, 97
i = d.find(pat)
if i < 0:
    print("keine-97"); raise SystemExit
seg = d[i:i+40]
j = seg.find(bytes([0x48, 0xC7, 0xC6]))                    # mov rsi, imm32
if j < 0:
    print("kein-rsi"); raise SystemExit
print(int.from_bytes(seg[j+3:j+7], 'little', signed=True))
PY
)
  if [ "$got" = "$3" ]; then echo "PASS $1: mov rax,97 + mov rsi,$got"; PASS=$((PASS+1));
  else echo "FAIL $1: rsi=$got erwartet $3"; FAIL=$((FAIL+1)); fi

  # Gegenprobe: die alte Entwurfsnummer darf nicht mehr drinstehen.
  if python3 - "$TMP/$1.lbf" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
raise SystemExit(0 if (0x208).to_bytes(8, 'little') in d else 1)
PY
  then echo "FAIL $1: 0x0208 (520) steht weiter im Erzeugnis"; FAIL=$((FAIL+1));
  else echo "PASS $1: keine 520 mehr"; PASS=$((PASS+1)); fi
}

echo "--- unlink: Datei loeschen, Bit 0 MUSS 0 sein ---"
fall unlink unlink 0
echo "--- rmdir: Verzeichnis loeschen, Bit 0 MUSS 1 sein (UNLINK_DIR) ---"
fall rmdir rmdir 1

echo "--- der abgelegte Stand nennt 97 mit ZWEI Argumenten ---"
# Ohne das faellt der Emitter in emitUnlinkFlach laut aus; die Zahl steht in
# der erzeugten Tabelle und kommt aus work/lyxos/syscall-argc.txt.
if grep -qE "nr == 97 \) \{ return 2;|nr == 97\) \{ return 2;" "$ROOT/src/backend/lyxos/lyxos_abi.lyx"; then
  echo "PASS lyxos_abi.lyx fuehrt 97 mit zwei Argumenten"; PASS=$((PASS+1))
else
  echo "FAIL lyxos_abi.lyx fuehrt 97 nicht mit zwei Argumenten -- tools/lyxos_abi_erzeugen.sh fahren"
  FAIL=$((FAIL+1))
fi

echo
echo "lyxos_unlink_dir_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
