#!/usr/bin/env bash
# tests/ext4_test.sh — baut ein ext4-Abbild, laesst es pruefen und liest es.
#
# Anders als bei exFAT gibt es hier einen fremden SCHREIBER: `debugfs` aus
# e2fsprogs legt Dateien und Verzeichnisse ohne Wurzelrechte an. Zusaetzlich
# urteilt `e2fsck` ueber das fertige Abbild, bevor der Lyx-Test es liest.
#
# Der Runner erzwingt ausserdem eine FRAGMENTIERTE Datei: er belegt das
# Abbild mit Fuellern, loescht jeden zweiten und schreibt dann erst die grosse
# Datei. Dadurch zerfaellt sie in mehrere Extents, deren Wurzel nicht mehr in
# den Inode passt und in einen eigenen Baumknoten wandert (Tiefe > 0). Ohne
# diesen Kunstgriff waere die Datei ein einziger Extent, und der schwierige
# Teil des Lesers bliebe ungeprueft.
#
# Dass die Fragmentierung wirklich eintrat, wird NACHGEMESSEN — eine
# Vorbereitung, die stillschweigend misslingt, macht den Test wertlos, ohne
# dass er rot wird.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

finde() { for k in "/usr/sbin/$1" "/sbin/$1" "$1"; do command -v "$k" >/dev/null 2>&1 && { echo "$k"; return 0; }; done; return 1; }

MKFS="$(finde mkfs.ext4)"  || { echo "UEBERSPRUNGEN std.fs.ext4: mkfs.ext4 fehlt (Paket e2fsprogs)"; exit 0; }
DEBUGFS="$(finde debugfs)" || { echo "UEBERSPRUNGEN std.fs.ext4: debugfs fehlt (Paket e2fsprogs)"; exit 0; }
E2FSCK="$(finde e2fsck)"   || { echo "UEBERSPRUNGEN std.fs.ext4: e2fsck fehlt (Paket e2fsprogs)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "UEBERSPRUNGEN std.fs.ext4: python3 fehlt"; exit 0; }

IMG="$TMP/e4.img"
dd if=/dev/zero of="$IMG" bs=1M count=16 status=none
"$MKFS" -q -L PRUEFE4 -b 1024 "$IMG" >/dev/null 2>&1 || {
  echo "UEBERSPRUNGEN std.fs.ext4: mkfs.ext4 konnte das Abbild nicht anlegen"; exit 0; }

printf 'Hallo ext4\n' > "$TMP/hallo.txt"
python3 -c "open('$TMP/gross.bin','wb').write(bytes((i*7+3)&255 for i in range(200000)))"
python3 -c "open('$TMP/fill.bin','wb').write(b'x'*40960)"

# 1) Fueller anlegen, 2) jeden zweiten loeschen, 3) erst dann die Nutzdateien.
{ for i in $(seq 1 100); do echo "write $TMP/fill.bin F$i"; done; echo quit; } > "$TMP/c1"
"$DEBUGFS" -w -f "$TMP/c1" "$IMG" >/dev/null 2>&1
{ for i in $(seq 2 2 100); do echo "rm F$i"; done; echo quit; } > "$TMP/c2"
"$DEBUGFS" -w -f "$TMP/c2" "$IMG" >/dev/null 2>&1

cat > "$TMP/c3" <<EOF
write $TMP/hallo.txt HALLO.TXT
write $TMP/gross.bin GROSS.BIN
write $TMP/hallo.txt Ein-sehr-langer-Dateiname-mit-vielen-Zeichen-zum-Pruefen.txt
symlink /ZIEL.LNK HALLO.TXT
mkdir /ORDNER
cd /ORDNER
mkdir TIEF
cd /ORDNER/TIEF
write $TMP/hallo.txt UNTEN.TXT
quit
EOF
"$DEBUGFS" -w -f "$TMP/c3" "$IMG" >/dev/null 2>&1

# Die restlichen Fueller weg — sie haben ihren Zweck erfuellt.
{ for i in $(seq 1 2 100); do echo "rm F$i"; done; echo quit; } > "$TMP/c4"
"$DEBUGFS" -w -f "$TMP/c4" "$IMG" >/dev/null 2>&1

# Vorbedingung nachmessen: hat GROSS.BIN wirklich einen Extent-Baumknoten?
EXT="$("$DEBUGFS" -R "stat GROSS.BIN" "$IMG" 2>/dev/null | sed -n '/EXTENTS/,$p' | tail -n +2)"
if printf '%s' "$EXT" | grep -q "ETB"; then
  echo "Vorbedingung: GROSS.BIN hat einen Extent-Baumknoten (Tiefe > 0)"
else
  echo "UEBERSPRUNGEN std.fs.ext4: die Datei liess sich nicht fragmentieren"
  echo "  Der Zuteiler hat sie am Stueck abgelegt; damit bliebe der"
  echo "  Baumdurchlauf ungeprueft, und der Test misst weniger, als er behauptet."
  echo "  Extents: $EXT"
  exit 0
fi

# Der fremde Richter — VOR dem Test.
if ! "$E2FSCK" -fn "$IMG" >"$TMP/fsck.log" 2>&1; then
  echo "FAIL std.fs.ext4: e2fsck haelt die Vorlage fuer fehlerhaft"
  tail -6 "$TMP/fsck.log"
  exit 1
fi
echo "Vorlage von e2fsck bestaetigt: $(tail -1 "$TMP/fsck.log")"

if ! "$LYXC" --std-path="$ROOT" "$ROOT/tests/ext4_test.lyx" -o "$TMP/ext4_test" >"$TMP/build.log" 2>&1; then
  echo "FAIL std.fs.ext4: Testprogramm uebersetzt nicht"
  grep -i error "$TMP/build.log" | head -3
  exit 1
fi

"$TMP/ext4_test" "$IMG"
