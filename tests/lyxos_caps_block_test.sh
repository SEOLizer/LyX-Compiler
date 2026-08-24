#!/usr/bin/env bash
# tests/lyxos_caps_block_test.sh — hardware.block in der CAPS-TLV (#1755).
#
# Lyx OS erzwingt das Manifest zur Syscall-Zeit und fuehrt eine eigene Klasse
# fuer Rohzugriff auf Blockgeraete (PLEDGE_BLOCK, Syscalls 98-102). Dafuer gab
# es keine Schreibweise: dd, diskinfo, partinfo, partition und ramdisk konnten
# das Recht nicht anfordern und liefen als LBF beim ersten Blockzugriff in ein
# Verbot.
#
# ABWEICHUNG VOM VORSCHLAG: das Issue schlug 0x10 vor. Diese Stelle ist seit
# jeher LBF_CAP_KI_EMBED (src/std/lyxos/lbf_layout.lyx). Wer nur die vier Bits
# misst, die ein Testprogramm setzt, sieht die belegten nicht. Vergeben ist
# deshalb 0x40 — die naechste freie Stelle (belegt: 1, 2, 4, 8, 16, 32, 128).
# Das Kernel-Team bildet 0x40 auf PLEDGE_BLOCK ab, nicht 0x10.
#
# Zweiter Teil: eine Capability, die im LBF-Ziel kein Bit setzt, ging still
# durch. `hardware.i2c` liest sich wie eine Zusage und ist dort keine — das
# Programm kommt beim Ladeprogramm an wie eines ohne Manifest.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# caps <datei> → Wert der CAPS-TLV (Typ 0x05, Laenge 8) im Genesis-Block
caps() {
  python3 - "$1" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
i = 0
while i < 4096:
    i = b.find(b'\x05', i)
    if i < 0: break
    if int.from_bytes(b[i+1:i+3], 'little') == 8:
        v = int.from_bytes(b[i+3:i+11], 'little')
        if v in (0, 1, 2, 4, 8, 16, 32, 64, 128):
            print(v); sys.exit()
    i += 1
print(-1)
PY
}

bau() {  # name, quelle → $TMP/<name>.lbf, Meldungen in $TMP/<name>.log
  printf '%s' "$2" > "$TMP/$1.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/$1.lyx" -o "$TMP/$1.lbf" > "$TMP/$1.log" 2>&1
}

# --- 1. hardware.block wird angenommen und setzt 0x40 --------------------
bau blk '@capabilities([hardware.block])
fn main(): int64 { return 0; }'
if grep -q "unbekannte Capability" "$TMP/blk.log"; then
  no "hardware.block bekannt" "sema weist den Namen ab"
else
  ok "hardware.block ist eine bekannte Capability"
  v="$(caps "$TMP/blk.lbf")"
  [ "$v" = "64" ] && ok "hardware.block setzt 0x40 in der CAPS-TLV" \
                  || no "CAPS-Bit" "caps=$v erwartet 64 (0x40)"
fi

# --- 2. Die 0x10 aus dem Vorschlag bleibt bei ki.embed ------------------
# Waere hardware.block auf 0x10 gelegt worden, traefen sich zwei Bedeutungen
# in einer Zahl und der Kernel koennte sie nicht auseinanderhalten.
if grep -q "LBF_CAP_KI_EMBED *: *int64 *:= *16" "$ROOT/src/std/lyxos/lbf_layout.lyx"; then
  ok "0x10 bleibt LBF_CAP_KI_EMBED (keine Doppelbelegung)"
else
  no "Doppelbelegung" "0x10 traegt nicht mehr ki.embed"
fi

# --- 3. Bestehende Bits unveraendert ------------------------------------
bau fs '@capabilities([fs.read])
fn main(): int64 { return 0; }'
v="$(caps "$TMP/fs.lbf")"
[ "$v" = "1" ] && ok "fs.read weiterhin 0x1" || no "fs.read" "caps=$v erwartet 1"

# --- 4. Capability ohne Bit meldet sich ---------------------------------
bau i2c '@capabilities([hardware.i2c])
fn main(): int64 { return 0; }'
if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/i2c.log"; then
  ok "hardware.i2c meldet, dass es im LBF-Ziel nichts bewirkt"
else
  no "stille Capability" "hardware.i2c geht wortlos durch"
fi
v="$(caps "$TMP/i2c.lbf")"
[ "$v" = "0" ] && ok "hardware.i2c setzt weiterhin kein Bit (nur die Meldung ist neu)" \
               || no "i2c-Bit" "caps=$v erwartet 0"

# --- 5. system.* meldet sich NICHT --------------------------------------
# Das sind die impliziten Rechte (exit, Heap, Zufall, Zeit); sie brauchen kein
# Bit. Wuerden sie warnen, waere die Meldung sofort Rauschen und niemand laese
# sie mehr.
bau sys '@capabilities([system.exit])
fn main(): int64 { return 0; }'
if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/sys.log"; then
  no "system.* warnt" "die impliziten Rechte duerfen nicht melden — sonst wird die Meldung Rauschen"
else
  ok "system.exit meldet nicht (implizites Recht)"
fi

# --- 6. Andere Ziele bleiben still --------------------------------------
# Auf Linux ist hardware.i2c eine gueltige Zusage; die Meldung gilt nur fuer
# das LBF-Ziel.
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/i2c.lyx" -o "$TMP/i2c.elf" > "$TMP/i2c_elf.log" 2>&1
if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/i2c_elf.log"; then
  no "ELF-Ziel warnt" "die Meldung gehoert nur zu --target=lyxos"
else
  ok "ELF-Ziel meldet nicht"
fi

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
