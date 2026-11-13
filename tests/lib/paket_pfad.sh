# #2499: Wo im Paketbaum die Vorkompilate liegen — EINE Stelle fuer alle Tests.
#
# Seit #2499 liegen sie je Architektur: `units/<arch>/std/io.lyu`. Den
# Verzeichnisnamen gibt das Makefile vor (LYU_ARCH), und das holt ihn aus
# LyuArchName (src/lyu_reader.lyx). Wer ihn hier noch einmal hinschreibt,
# pflegt ihn an zwei Stellen — genau die Klasse, aus der eine Datei entsteht,
# die der Aufloeser nicht findet.
#
# Erwartet $ROOT. Setzt PKG_UNITS (Wurzel mit Architekturebene) und PKG_ARCH.
PKG_ARCH="$(grep -oE '^LYU_ARCH[[:space:]]*\?=[[:space:]]*[A-Za-z0-9_]+' "$ROOT/Makefile" 2>/dev/null \
            | head -1 | awk '{print $NF}')"
: "${PKG_ARCH:=x86_64}"
PKG_UNITS="$ROOT/lyx-compiler/usr/include/lyx/units/$PKG_ARCH"
# Rueckfall auf den flachen Baum: ein alter Checkout hat die Ebene noch nicht.
if [ ! -d "$PKG_UNITS" ] && [ -d "$ROOT/lyx-compiler/usr/include/lyx/units/std" ]; then
  PKG_UNITS="$ROOT/lyx-compiler/usr/include/lyx/units"
fi

# #2499: Mit welchen Schaltern das Makefile die Vorkompilate baut. Wer eine
# .lyu zum Vergleich neu uebersetzt, muss DIESELBEN nehmen -- sonst vergleicht
# er zwei verschiedene Dinge und nennt das einen Unterschied.
PKG_OBJCODE="$(grep -oE '^LYU_OBJCODE[[:space:]]*\?=.*' "$ROOT/Makefile" 2>/dev/null \
               | head -1 | sed 's/^[^=]*=[[:space:]]*//')"
