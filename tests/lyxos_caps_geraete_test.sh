#!/usr/bin/env bash
# tests/lyxos_caps_geraete_test.sh — Geraete-Bits in der CAPS-TLV (#1755, #1759).
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
        # #1912: Hier stand eine feste Liste bis 256. Sie sollte Zufallstreffer
        # ausschliessen, schloss aber zugleich jedes Bit aus, das spaeter
        # dazukam — audio.mic (512), audio.play (1024), ui.notify (2048)
        # lasen dadurch -1, also "nicht gefunden" statt ihres Werts. Eine
        # Filterliste, die mit dem Bestand nicht mitwaechst, macht aus einem
        # richtigen Wert ein stilles Nichts.
        # Geprueft wird jetzt die EIGENSCHAFT: 0 oder genau ein gesetztes Bit
        # bis 0x800.
        if v == 0 or (v <= 2048 and (v & (v - 1)) == 0):
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

# --- 3b. hardware.i2c/usb/gpio/spi → 0x100 (#1759) ----------------------
# Ein gemeinsames Bit fuer alle vier: der Kernel kennt genau eine Klasse
# (PLEDGE_DEVICE). Feiner getrennte Bits waeren eine Zusage, die niemand
# einloesen koennte; aufteilen laesst sich das spaeter, ohne bestehende
# Bedeutungen zu verschieben.
#
# ABWEICHUNG VOM VORSCHLAG: das Issue nannte 0x80 — die ist system.config
# (bis #1912 stand hier faelschlich LBF_CAP_AUDIO_MIC).
# Zweite Meldung in Folge, deren Zahl aus einer Messung stammt, die nur die
# selbst gesetzten Bits sieht (bei #1755 war es 0x10 gegen KI_EMBED).
for hw in hardware.i2c hardware.usb hardware.gpio hardware.spi; do
  bau "dev_${hw#hardware.}" "@capabilities([$hw])
fn main(): int64 { return 0; }"
  v="$(caps "$TMP/dev_${hw#hardware.}.lbf")"
  [ "$v" = "256" ] && ok "$hw setzt 0x100 (PLEDGE_DEVICE)" \
                   || no "$hw" "caps=$v erwartet 256 (0x100)"
  if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/dev_${hw#hardware.}.log"; then
    no "$hw warnt noch" "die Warnung gehoert weg, sobald das Bit gesetzt wird"
  else
    ok "$hw warnt nicht mehr"
  fi
done

# 0x80 bleibt EINDEUTIG belegt — sonst traefen sich zwei Bedeutungen in einer
# Zahl.
#
# #1912: Hier stand bis 1.1.15B ein `grep` auf `LBF_CAP_AUDIO_MIC := 128` in
# der TABELLE. Genau die war falsch: der Emitter setzt fuer `audio.mic` seit
# #1797 die 512, weil 128 dort an `system.config` ging. Der Test hat also die
# stale Seite der Divergenz festgenagelt und die Abweichung dadurch
# konserviert — die Tabelle ist jetzt nachgezogen.
#
# Gemessen wird deshalb am ERZEUGNIS, wie es die Regel aus #1823 verlangt:
# jeden Namen einzeln uebersetzen und das Bit lesen, statt der Tabelle zu
# glauben.
bau cfg '@capabilities([system.config])
fn main(): int64 { return 0; }'
vcfg="$(caps "$TMP/cfg.lbf")"
[ "$vcfg" = "128" ] && ok "0x80 gehoert system.config (am Erzeugnis gemessen)" \
                    || no "0x80 gehoert system.config" "caps=$vcfg erwartet 128"

bau mic '@capabilities([audio.mic])
fn main(): int64 { return 0; }'
vmic="$(caps "$TMP/mic.lbf")"
[ "$vmic" = "512" ] && ok "audio.mic haelt 0x200, nicht 0x80" \
                    || no "audio.mic haelt 0x200" "caps=$vmic erwartet 512"

# Und die beiden sind verschieden — ohne diese Zeile waere der Test auch von
# zwei gleichen Rueckgaben erfuellt.
[ "$vcfg" != "$vmic" ] && ok "system.config und audio.mic sind verschiedene Bits" \
                       || no "system.config und audio.mic" "beide $vcfg"

# Blockgeraete bleiben eine eigene Klasse, nicht DEVICE.
v="$(caps "$TMP/blk.lbf")"
[ "$v" = "64" ] && ok "hardware.block bleibt 0x40, faellt nicht in DEVICE" \
                || no "block vs device" "caps=$v erwartet 64"

# --- 4. Capability ohne Bit meldet sich ---------------------------------
# Beispiel ist jetzt fs.meta: seit #1759 bilden die vier hardware.*-Busse ab,
# taugen als "stille Capability" also nicht mehr. fs.meta ist registriert und
# setzt kein Bit — der Fall, den die Warnung sichtbar machen soll.
bau meta '@capabilities([fs.meta])
fn main(): int64 { return 0; }'
if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/meta.log"; then
  ok "fs.meta meldet, dass es im LBF-Ziel nichts bewirkt"
else
  no "stille Capability" "fs.meta geht wortlos durch"
fi
v="$(caps "$TMP/meta.lbf")"
[ "$v" = "0" ] && ok "fs.meta setzt weiterhin kein Bit (nur die Meldung ist neu)" \
               || no "meta-Bit" "caps=$v erwartet 0"

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
# Auf Linux ist fs.meta eine gueltige Zusage; die Meldung gilt nur fuer das
# LBF-Ziel.
LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/meta.lyx" -o "$TMP/meta.elf" > "$TMP/meta_elf.log" 2>&1
if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/meta_elf.log"; then
  no "ELF-Ziel warnt" "die Meldung gehoert nur zu --target=lyxos"
else
  ok "ELF-Ziel meldet nicht"
fi

# --- #1823: process.* — nur exec und fork tragen das Spawn-Recht -----------
# Die Zuordnung lief ueber das PRAEFIX `process` (7 Zeichen) und traf damit alle
# fuenf Namen. Gemessen am Erzeugnis setzte `@capabilities([process.exit])`
# Bit 8 = LBF_CAP_PROC_SPAWN, das der Kernel auf PLEDGE_EXEC abbildet: wer
# anmeldete, sich beenden zu duerfen, bekam das Recht, PROGRAMME ZU STARTEN.
#
# Geprueft wird beides — dass die beiden richtigen Namen das Bit setzen UND
# dass die drei anderen es NICHT tun. Nur die erste Haelfte zu pruefen, waere
# auch von der alten, zu weiten Zuordnung erfuellt worden.
for pn in exec fork; do
  bau "pe_$pn" "@capabilities([process.$pn])
fn main(): int64 { return 0; }"
  v="$(caps "$TMP/pe_$pn.lbf")"
  [ "$v" = "8" ] && ok "process.$pn setzt 0x08 (PROC_SPAWN)" \
                 || no "process.$pn" "caps=$v erwartet 8"
done

for pn in exit signal sched; do
  bau "px_$pn" "@capabilities([process.$pn])
fn main(): int64 { return 0; }"
  v="$(caps "$TMP/px_$pn.lbf")"
  if [ "$v" = "8" ]; then
    no "process.$pn" "setzt PROC_SPAWN (0x08) — Rechteausweitung, siehe #1823"
  else
    ok "process.$pn setzt kein Spawn-Bit (caps=$v)"
  fi
  # Und es wird gemeldet, statt still nichts zu tun.
  if grep -q "setzt kein Bit in der CAPS-TLV" "$TMP/px_$pn.log"; then
    ok "process.$pn wird als wirkungslos gemeldet"
  else
    no "process.$pn" "keine Meldung, obwohl kein Bit gesetzt wird"
  fi
done

echo "----"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
