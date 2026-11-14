#!/bin/bash
# Erzeugt src/backend/lyxos/lyxos_abi.lyx aus work/lyxos/syscall-argc.txt.
#
# #2482: Die Gestaltpruefung des lyxos-Backends war fail-open — sie kannte
# genau eine Nummer (0x020C) und gab fuer jede andere 1 zurueck, ohne zu
# pruefen. Damit ging eine belegte Nummer mit FALSCHER Argumentzahl durch, und
# der Kernel liest dann Register, die niemand gefuellt hat, oder uebergeht
# Werte, die der Aufrufer fuer uebergeben haelt.
#
# Die Datenkette, EINE Richtung, keine Handarbeit dazwischen:
#
#   lyx-os kernel/ring3.lyx
#     -> (dessen tools/sync_syscalls.py) doku/syscalls_ist.md
#     -> (tools/lyxos_syscall_abgleich.sh --schreiben) work/lyxos/syscall-argc.txt
#     -> (dieses Skript) src/backend/lyxos/lyxos_abi.lyx
#
# Der abgelegte Stand im Repo ist der Grund, warum die Pruefung auch ohne das
# LyxOS-Repo laeuft — wie beim Nummernraum (#1795).
#
# Aufruf:
#   tools/lyxos_abi_erzeugen.sh            # erzeugen
#   tools/lyxos_abi_erzeugen.sh --pruefen  # nur vergleichen, nichts schreiben
set -u
cd "$(dirname "$0")/.." || exit 1

STAND="work/lyxos/syscall-argc.txt"
ZIEL="src/backend/lyxos/lyxos_abi.lyx"
PRUEFEN=0
[ "${1:-}" = "--pruefen" ] && PRUEFEN=1

if [ ! -f "$STAND" ]; then
    echo "FEHLT: $STAND — mit tools/lyxos_syscall_abgleich.sh --schreiben anlegen"
    exit 2
fi

HERKUNFT=$(sed -n 's/^# NICHT von Hand pflegen. Quelle (nur gelesen), Stand \(.*\):$/\1/p' "$STAND")
ANZ=$(grep -vc '^#' "$STAND")
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

{
cat <<KOPF
// src/backend/lyxos/lyxos_abi.lyx — Argumentzahl je LyxOS-Syscallnummer.
//
// ERZEUGT von tools/lyxos_abi_erzeugen.sh aus work/lyxos/syscall-argc.txt.
// NICHT VON HAND PFLEGEN — neu erzeugen, sonst laufen zwei Staende
// auseinander.
//
// Stand der Quelle: LyxOS $HERKUNFT, $ANZ Nummern mit lesbarer Signatur.
//
// WOZU (#2482). \`lyxosGestaltPasst\` prueft, ob eine Nummer in der
// Aufrufgestalt benutzt wird, die der Kernel erwartet — und kannte bis
// 1.2.39D genau EINEN Fall (0x020C sys_pipe). Fuer jede andere Nummer gab sie
// 1 zurueck, ohne etwas geprueft zu haben: fail-open. Belegt war der Schaden
// dreimal: \`sys_mmap_device\` legte vier Werte ab, gebaut ist
// \`dev_map_mmio(a0, a1)\` mit zwei (#2469); \`sys_umount\` lud drei und nahm
// eines (#2439); \`pipe\` war der einzige erfasste Fall.
//
// WAS HIER NICHT STEHT: Nummern, deren Zeile in der Kernel-Tabelle keine
// lesbare Signatur traegt, und die Abfangstellen des Bootloaders, die gar
// nicht in dieser Tabelle stehen (#1795: 60, 231, 11, 12, 515). Fuer die gibt
// \`LyxosArgcFuerNr\` -1 zurueck, und die Gestaltpruefung laesst sie durch.
// Dieser Durchfall ist gewollt und begruendet — ein Abweisen waere hier kein
// Strengebeweis, sondern ein Fehlalarm. Wie weit die Erfassung reicht, misst
// tests/lyxos_argc_2482_test.sh; die Luecke ist damit eine Zahl, die kleiner
// werden kann, und kein blinder Fleck.
//
// -1 und nicht 0: die Null ist eine GUELTIGE Argumentzahl, ein Fehlwert muss
// also ausserhalb des Wertebereichs liegen.

unit src.backend.lyxos.lyxos_abi;

// Argumentzahl, die der LyxOS-Kernel fuer diese Nummer liest, oder -1, wenn
// die Nummer hier nicht erfasst ist.
pub fn LyxosArgcFuerNr(nr: int64): int64 {
KOPF
grep -v '^#' "$STAND" | awk -F'\t' 'NF>=3 { printf "  if (nr == %s) { return %s; }   // %s\n", $1, $3, $2 }'
cat <<'FUSS'
  return 0 - 1;
}

// Name, unter dem der Kernel diese Nummer fuehrt, oder 0, wenn nicht erfasst.
// Nur fuer Meldungen — wer pruefen will, nimmt LyxosArgcFuerNr.
pub fn LyxosNameFuerNr(nr: int64): pchar {
FUSS
grep -v '^#' "$STAND" | awk -F'\t' 'NF>=3 { printf "  if (nr == %s) { return \"%s\"c; }\n", $1, $2 }'
cat <<'FUSS2'
  return 0 as pchar;
}
FUSS2
} > "$TMP"

if [ "$PRUEFEN" = "1" ]; then
    if diff -q "$ZIEL" "$TMP" >/dev/null 2>&1; then
        echo "aktuell: $ZIEL stimmt mit $STAND ueberein ($ANZ Nummern)"
        exit 0
    fi
    echo "ABWEICHUNG: $ZIEL passt nicht zu $STAND"
    diff -u "$ZIEL" "$TMP" 2>/dev/null | sed -n '3,$p' | head -20
    echo "  Neu erzeugen: tools/lyxos_abi_erzeugen.sh"
    exit 1
fi

cp "$TMP" "$ZIEL"
echo "geschrieben: $ZIEL ($ANZ Nummern, LyxOS $HERKUNFT)"
