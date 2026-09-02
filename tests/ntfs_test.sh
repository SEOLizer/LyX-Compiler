#!/usr/bin/env bash
# tests/ntfs_test.sh — baut ein NTFS-Abbild und liest es gegen ntfsls.
#
# `mkntfs` legt an, `ntfscp` schreibt hinein — beides aus ntfsprogs, beides
# ohne Wurzelrechte.
#
# DER ABGLEICH GEHT HIER WEITER als bei den Schwester-Units: statt eines
# Pruefprogramms gibt es einen fremden LESER. `ntfsls` listet das
# Wurzelverzeichnis, und der Lyx-Test muss jeden dieser Namen wiederfinden.
# Zwei unabhaengige Umsetzungen muessen sich also ueber den Inhalt einig sein.
#
# Sechzig Fuellerdateien sind kein Zufall: ohne sie passt der Wurzelindex
# vollstaendig in $INDEX_ROOT, und die INDX-Bloecke aus $INDEX_ALLOCATION —
# mit ihren eigenen Fixups — blieben ungeprueft. Dass sie entstanden sind,
# wird NACHGEMESSEN.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

finde() { for k in "/usr/sbin/$1" "/sbin/$1" "/usr/bin/$1" "$1"; do command -v "$k" >/dev/null 2>&1 && { echo "$k"; return 0; }; done; return 1; }

MKNTFS="$(finde mkntfs)"   || { echo "UEBERSPRUNGEN std.fs.ntfs: mkntfs fehlt (Paket ntfs-3g)"; exit 0; }
NTFSCP="$(finde ntfscp)"   || { echo "UEBERSPRUNGEN std.fs.ntfs: ntfscp fehlt (Paket ntfs-3g)"; exit 0; }
NTFSLS="$(finde ntfsls)"   || { echo "UEBERSPRUNGEN std.fs.ntfs: ntfsls fehlt — ohne fremden Leser gaebe es keinen Abgleich"; exit 0; }
NTFSINFO="$(finde ntfsinfo)" || { echo "UEBERSPRUNGEN std.fs.ntfs: ntfsinfo fehlt"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "UEBERSPRUNGEN std.fs.ntfs: python3 fehlt"; exit 0; }

IMG="$TMP/n.img"
dd if=/dev/zero of="$IMG" bs=1M count=32 status=none
"$MKNTFS" -Q -F -L PRUEFNT -s 512 "$IMG" >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.fs.ntfs: mkntfs konnte das Abbild nicht anlegen"; exit 0; }

printf 'Hallo NTFS\n' > "$TMP/hallo.txt"
python3 -c "open('$TMP/gross.bin','wb').write(bytes((i*7+3)&255 for i in range(200000)))"

"$NTFSCP" "$IMG" "$TMP/hallo.txt" HALLO.TXT >/dev/null 2>&1
"$NTFSCP" "$IMG" "$TMP/gross.bin" GROSS.BIN >/dev/null 2>&1
"$NTFSCP" "$IMG" "$TMP/hallo.txt" "Ein-sehr-langer-Dateiname-mit-vielen-Zeichen-zum-Pruefen.txt" >/dev/null 2>&1
for i in $(seq 1 60); do
  "$NTFSCP" "$IMG" "$TMP/hallo.txt" "FUELLER-NUMMER-$i.TXT" >/dev/null 2>&1
done

# Vorbedingung nachmessen: hat der Wurzelindex wirklich INDX-Bloecke?
if "$NTFSINFO" -i 5 -v "$IMG" 2>/dev/null | grep -q 'INDEX_ALLOCATION'; then
  echo "Vorbedingung: der Wurzelindex hat INDX-Bloecke (\$INDEX_ALLOCATION)"
else
  echo "UEBERSPRUNGEN std.fs.ntfs: der Wurzelindex passt ganz in \$INDEX_ROOT"
  echo "  Damit blieben die INDX-Bloecke mit ihren eigenen Fixups ungeprueft,"
  echo "  und der Test misst weniger, als er behauptet."
  exit 0
fi

# Der fremde Leser.
"$NTFSLS" "$IMG" 2>/dev/null > "$TMP/namen.txt"
ANZ=$(wc -l < "$TMP/namen.txt")
if [ "$ANZ" -lt 50 ]; then
  echo "FAIL std.fs.ntfs: ntfsls liefert nur $ANZ Namen — die Vorlage ist unbrauchbar"
  exit 1
fi
echo "Fremder Leser: ntfsls nennt $ANZ Eintraege im Wurzelverzeichnis"

if ! "$LYXC" --std-path="$ROOT" "$ROOT/tests/ntfs_test.lyx" -o "$TMP/ntfs_test" >"$TMP/build.log" 2>&1; then
  echo "FAIL std.fs.ntfs: Testprogramm uebersetzt nicht"
  grep -i error "$TMP/build.log" | head -3
  exit 1
fi

"$TMP/ntfs_test" "$IMG" "$TMP/namen.txt"
