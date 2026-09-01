#!/usr/bin/env bash
# tests/fat_test.sh — baut FAT-Abbilder und laesst std.fs.fat darauf los.
#
# Die Vorlagen kommen von `mkfs.vfat` und `mtools`, NICHT von uns. Das ist der
# Kern dieser Batterie: ein selbst gebautes Abbild belegt nur, dass Leser und
# Schreiber dieselbe Vorstellung haben — auch eine falsche. Gegen eine fremde
# Umsetzung gemessen steht auf der anderen Seite jemand, der die
# Spezifikation unabhaengig gelesen hat.
#
# Fehlen die Werkzeuge, wird das GESAGT und uebersprungen, nicht als Fehlschlag
# gewertet (#1911: ein Test, der seine Umgebung voraussetzt, faerbt den Lauf
# dauerhaft rot und wird dann ueberlesen).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

MKFS=""
for k in /usr/sbin/mkfs.vfat /sbin/mkfs.vfat mkfs.vfat; do
  command -v "$k" >/dev/null 2>&1 && { MKFS="$k"; break; }
done
if [ -z "$MKFS" ]; then
  echo "UEBERSPRUNGEN std.fs.fat: mkfs.vfat fehlt (Paket dosfstools)"
  echo "  Ohne fremd erzeugte Abbilder pruefte der Test nur sich selbst."
  exit 0
fi
if ! command -v mcopy >/dev/null 2>&1 || ! command -v mmd >/dev/null 2>&1; then
  echo "UEBERSPRUNGEN std.fs.fat: mtools fehlen (mcopy/mmd)"
  echo "  Die Abbilder liessen sich anlegen, aber nicht befuellen."
  exit 0
fi

export MTOOLS_SKIP_CHECK=1
IMG="$TMP/img"; mkdir -p "$IMG"

# Eine Datei mit BERECHENBAREM Inhalt: 200 000 Byte nach (i*7+3) mod 256.
# Sie belegt je nach Fassung dutzende bis hunderte Cluster — der Fall, an dem
# sich zeigt, ob die Clusterkette wirklich verfolgt wird.
printf 'Hallo FAT\n' > "$TMP/hallo.txt"
python3 -c "open('$TMP/gross.bin','wb').write(bytes((i*7+3)&255 for i in range(200000)))"

# FAT12 braucht ein kleines Medium, FAT32 ein grosses — die Fassung faellt aus
# der Clusterzahl, sie laesst sich nicht frei waehlen.
baue() { # typ, groesse-in-KB
  dd if=/dev/zero of="$IMG/fat$1.img" bs=1024 count="$2" status=none
  "$MKFS" -F "$1" -n "PRUEF$1" "$IMG/fat$1.img" >/dev/null 2>&1 || return 1
  mmd   -i "$IMG/fat$1.img" ::ORDNER                                  >/dev/null 2>&1 || return 1
  mmd   -i "$IMG/fat$1.img" ::ORDNER/TIEF                             >/dev/null 2>&1 || return 1
  mcopy -i "$IMG/fat$1.img" "$TMP/hallo.txt" ::HALLO.TXT              >/dev/null 2>&1 || return 1
  mcopy -i "$IMG/fat$1.img" "$TMP/hallo.txt" ::ORDNER/TIEF/UNTEN.TXT  >/dev/null 2>&1 || return 1
  mcopy -i "$IMG/fat$1.img" "$TMP/gross.bin" ::GROSS.BIN              >/dev/null 2>&1 || return 1
  mcopy -i "$IMG/fat$1.img" "$TMP/hallo.txt" "::Ein langer Dateiname.txt" >/dev/null 2>&1 || return 1
  return 0
}

for spec in "12 1440" "16 40000" "32 70000"; do
  set -- $spec
  if ! baue "$1" "$2"; then
    echo "UEBERSPRUNGEN std.fs.fat: FAT$1-Abbild liess sich nicht erzeugen"
    exit 0
  fi
done

if ! "$LYXC" --std-path="$ROOT" "$ROOT/tests/fat_test.lyx" -o "$TMP/fat_test" >"$TMP/build.log" 2>&1; then
  echo "FAIL std.fs.fat: Testprogramm uebersetzt nicht"
  grep -i error "$TMP/build.log" | head -3
  exit 1
fi

"$TMP/fat_test" "$IMG"
