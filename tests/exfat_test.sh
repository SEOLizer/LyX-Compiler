#!/usr/bin/env bash
# tests/exfat_test.sh — baut ein exFAT-Abbild, laesst es PRUEFEN und liest es.
#
# Fuer exFAT gibt es kein `mtools`, und ein Loop-Mount braeuchte Wurzelrechte.
# Das Abbild kommt deshalb von `mkfs.exfat`, befuellt wird es von
# tests/lib/exfat_fuellen.py.
#
# Damit das trotzdem traegt, urteilt eine FREMDE Umsetzung: `fsck.exfat` prueft
# das befuellte Abbild, BEVOR der Lyx-Test es liest. Meldet fsck nicht "clean",
# bricht der Lauf hier ab — dann waere die Vorlage falsch, und jede Pruefung
# danach waere wertlos.
#
# Fehlen die Werkzeuge, wird das gesagt und uebersprungen (#1911).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

finde() { for k in "/usr/sbin/$1" "/sbin/$1" "$1"; do command -v "$k" >/dev/null 2>&1 && { echo "$k"; return 0; }; done; return 1; }

MKFS="$(finde mkfs.exfat)" || {
  echo "UEBERSPRUNGEN std.fs.exfat: mkfs.exfat fehlt (Paket exfatprogs)"
  echo "  Ohne fremd erzeugtes Abbild pruefte der Test nur sich selbst."
  exit 0
}
FSCK="$(finde fsck.exfat)" || {
  echo "UEBERSPRUNGEN std.fs.exfat: fsck.exfat fehlt (Paket exfatprogs)"
  echo "  Ohne den fremden Richter waere die selbst befuellte Vorlage kein Nachweis."
  exit 0
}
command -v python3 >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.fs.exfat: python3 fehlt (Befuellskript)"
  exit 0
}

IMG="$TMP/ex.img"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
"$MKFS" -n PRUEFEX "$IMG" >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.fs.exfat: mkfs.exfat konnte das Abbild nicht anlegen"
  exit 0
}

if ! python3 "$ROOT/tests/lib/exfat_fuellen.py" "$IMG" >"$TMP/fuell.log" 2>&1; then
  echo "FAIL std.fs.exfat: Befuellen des Abbilds schlug fehl"
  head -5 "$TMP/fuell.log"
  exit 1
fi

# Der fremde Richter. Er laeuft VOR dem Test — nicht danach.
if ! "$FSCK" -n "$IMG" >"$TMP/fsck.log" 2>&1 || ! grep -q "clean" "$TMP/fsck.log"; then
  echo "FAIL std.fs.exfat: fsck.exfat haelt die Vorlage fuer fehlerhaft"
  echo "  Damit waere jede Pruefung danach wertlos — der Fehler liegt im"
  echo "  Befuellskript, nicht im Leser."
  tail -5 "$TMP/fsck.log"
  exit 1
fi
echo "Vorlage von fsck.exfat bestaetigt: $(grep -o 'clean.*' "$TMP/fsck.log" | head -1)"

if ! "$LYXC" --std-path="$ROOT" "$ROOT/tests/exfat_test.lyx" -o "$TMP/exfat_test" >"$TMP/build.log" 2>&1; then
  echo "FAIL std.fs.exfat: Testprogramm uebersetzt nicht"
  grep -i error "$TMP/build.log" | head -3
  exit 1
fi

"$TMP/exfat_test" "$IMG"
