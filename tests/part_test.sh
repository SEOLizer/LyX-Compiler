#!/usr/bin/env bash
# tests/part_test.sh — Partitionstabellen, und der Nachweis der ganzen Kette.
#
# Zwei Abbilder: eine GPT-Platte mit drei Partitionen, in denen ECHTE
# Dateisysteme liegen (FAT16, ext4, exFAT), und eine MBR-Platte mit zwei
# primaeren, einem erweiterten Behaelter und zwei LOGISCHEN Partitionen.
#
# Angelegt von `sgdisk` und `sfdisk`, die Dateisysteme von `mkfs.vfat`,
# `mkfs.ext4` und `mkfs.exfat` — alles fremde Werkzeuge. Zusaetzlich haelt der
# Runner die Ausgabe von `partx` daneben.
#
# Der eigentliche Nachweis steckt aber im Lyx-Test: die drei Dateisystem-Units
# werden mit dem Versatz aufgerufen, den std.fs.part ausrechnet. Stimmt er um
# EINEN Sektor nicht, findet keiner von ihnen seine Kennung — die Kette prueft
# sich selbst.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

finde() { for k in "/usr/sbin/$1" "/sbin/$1" "/usr/bin/$1" "$1"; do command -v "$k" >/dev/null 2>&1 && { echo "$k"; return 0; }; done; return 1; }

SGDISK="$(finde sgdisk)" || { echo "UEBERSPRUNGEN std.fs.part: sgdisk fehlt (Paket gdisk)"; exit 0; }
SFDISK="$(finde sfdisk)" || { echo "UEBERSPRUNGEN std.fs.part: sfdisk fehlt (Paket util-linux)"; exit 0; }
PARTX="$(finde partx)"   || { echo "UEBERSPRUNGEN std.fs.part: partx fehlt (Paket util-linux)"; exit 0; }
MKVFAT="$(finde mkfs.vfat)" || { echo "UEBERSPRUNGEN std.fs.part: mkfs.vfat fehlt"; exit 0; }
MKEXT4="$(finde mkfs.ext4)" || { echo "UEBERSPRUNGEN std.fs.part: mkfs.ext4 fehlt"; exit 0; }
MKEXFAT="$(finde mkfs.exfat)" || { echo "UEBERSPRUNGEN std.fs.part: mkfs.exfat fehlt"; exit 0; }
DEBUGFS="$(finde debugfs)" || { echo "UEBERSPRUNGEN std.fs.part: debugfs fehlt"; exit 0; }
command -v mcopy >/dev/null 2>&1 || { echo "UEBERSPRUNGEN std.fs.part: mtools fehlen"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "UEBERSPRUNGEN std.fs.part: python3 fehlt"; exit 0; }

export MTOOLS_SKIP_CHECK=1
printf 'Hallo Partition\n' > "$TMP/h.txt"

# ── GPT-Platte mit drei bestueckten Partitionen ────────────────────────────
GPT="$TMP/gpt.img"
dd if=/dev/zero of="$GPT" bs=1M count=96 status=none
"$SGDISK" -o -n 1:2048:+16M -t 1:0700 -c 1:"EFI-Teil" \
             -n 2:0:+24M    -t 2:8300 -c 2:"Linux-Teil" \
             -n 3:0:+20M    -t 3:0700 -c 3:"Daten-Teil" "$GPT" >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.fs.part: sgdisk konnte die Tabelle nicht anlegen"; exit 0; }

dd if=/dev/zero of="$TMP/p1.img" bs=1M count=16 status=none
"$MKVFAT" -F 16 -n TEIL1 "$TMP/p1.img" >/dev/null 2>&1
mcopy -i "$TMP/p1.img" "$TMP/h.txt" ::EINS.TXT >/dev/null 2>&1

dd if=/dev/zero of="$TMP/p2.img" bs=1M count=24 status=none
"$MKEXT4" -q -L TEIL2 -b 1024 "$TMP/p2.img" >/dev/null 2>&1
"$DEBUGFS" -w -R "write $TMP/h.txt ZWEI.TXT" "$TMP/p2.img" >/dev/null 2>&1

dd if=/dev/zero of="$TMP/p3.img" bs=1M count=20 status=none
"$MKEXFAT" -n TEIL3 "$TMP/p3.img" >/dev/null 2>&1
python3 "$ROOT/tests/lib/exfat_fuellen.py" "$TMP/p3.img" >/dev/null 2>&1

dd if="$TMP/p1.img" of="$GPT" bs=512 seek=2048  conv=notrunc status=none
dd if="$TMP/p2.img" of="$GPT" bs=512 seek=34816 conv=notrunc status=none
dd if="$TMP/p3.img" of="$GPT" bs=512 seek=83968 conv=notrunc status=none

# ── MBR-Platte mit erweiterter Partition und zwei logischen ────────────────
MBR="$TMP/mbr.img"
dd if=/dev/zero of="$MBR" bs=1M count=64 status=none
"$SFDISK" "$MBR" >/dev/null 2>&1 <<'EOF'
label: dos
start=2048, size=16384, type=6
start=18432, size=16384, type=83
start=34816, size=94208, type=5
start=36864, size=16384, type=83
start=55296, size=16384, type=83
EOF

# Vorbedingung nachmessen: hat die MBR-Platte wirklich logische Partitionen?
LOG=$("$PARTX" -o NR -g "$MBR" 2>/dev/null | tr -d ' ' | grep -c '^[56]$')
if [ "$LOG" -ne 2 ]; then
  echo "UEBERSPRUNGEN std.fs.part: die logischen Partitionen sind nicht entstanden"
  echo "  Damit bliebe die EBR-Kette ungeprueft — der schwierige Teil des MBR."
  exit 0
fi
echo "Vorbedingung: MBR traegt zwei logische Partitionen (EBR-Kette vorhanden)"
echo "Fremder Leser: partx nennt $("$PARTX" -o NR -g "$GPT" 2>/dev/null | wc -l) GPT-Partitionen"

if ! "$LYXC" --std-path="$ROOT" "$ROOT/tests/part_test.lyx" -o "$TMP/part_test" >"$TMP/build.log" 2>&1; then
  echo "FAIL std.fs.part: Testprogramm uebersetzt nicht"
  grep -i error "$TMP/build.log" | head -3
  exit 1
fi

"$TMP/part_test" "$GPT" "$MBR"
