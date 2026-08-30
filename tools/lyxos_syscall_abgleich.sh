#!/bin/bash
# Gleicht den erlaubten Syscall-Nummernraum des lyxos-Backends gegen LyxOS ab.
#
# #1795: die Menge gueltiger Nummern steht in ZWEI Quellen, und keine allein
# ist vollstaendig:
#
#   A) die aus `kernel/ring3.lyx` erzeugte Dispatcher-Tabelle
#      (`doku/syscalls_ist.md`, erzeugt von `tools/sync_syscalls.py`)
#   B) die Abfangstellen im Bootloader (`bootloader/boot.asm`), die Nummern
#      VOR dem Dispatcher behandeln — dort stehen `exit` (60) und
#      `exit_group` (231), die in A fehlen.
#
# Wer A fuer die vollstaendige Menge haelt, weist `exit` ab und damit jedes
# lyxos-Programm. Genau das ist beim ersten Anlauf des Waechters aus #1734
# passiert.
#
# Der abgeglichene Stand liegt als `work/lyxos/syscall-ist.txt` im Repo, damit
# die Pruefung auch ohne das LyxOS-Repo laeuft. Dieses Skript erzeugt ihn neu
# und zeigt, was sich seit dem letzten Abgleich geaendert hat.
#
# Aufruf:
#   tools/lyxos_syscall_abgleich.sh              # nur vergleichen
#   tools/lyxos_syscall_abgleich.sh --schreiben  # Stand im Repo erneuern
#   LYXOS_REPO=/pfad/zu/lyx-os tools/lyxos_syscall_abgleich.sh
#
# Das LyxOS-Repo wird nur GELESEN.

set -u
cd "$(dirname "$0")/.." || exit 1

LYXOS_REPO="${LYXOS_REPO:-$HOME/PhpstormProjects/lyx-os}"
STAND="work/lyxos/syscall-ist.txt"
SCHREIBEN=0
[ "${1:-}" = "--schreiben" ] && SCHREIBEN=1

TABELLE="$LYXOS_REPO/doku/syscalls_ist.md"
BOOT="$LYXOS_REPO/bootloader/boot.asm"

if [ ! -f "$TABELLE" ] || [ ! -f "$BOOT" ]; then
    echo "LyxOS-Repo nicht lesbar: $LYXOS_REPO"
    echo "  erwartet: doku/syscalls_ist.md und bootloader/boot.asm"
    echo "  Pfad ueber LYXOS_REPO setzen."
    exit 2
fi

HERKUNFT=$(cd "$LYXOS_REPO" && git log -1 --format='%h %ad' --date=short 2>/dev/null || echo "unbekannt")

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Quelle A: Dispatcher-Tabelle -----------------------------------------
# Zeilenform: | 103 | `HSW` | `sys_disk_id_range` | ... |
grep -E '^\| *[0-9]+ *\|' "$TABELLE" | sed 's/^| *//; s/ *|.*//' | sort -n -u > "$TMP/a.txt"

# --- Quelle B: Bootloader-Abfaenge ----------------------------------------
# Im Ring-3-Zweig steht `cmp rax, N` gefolgt von `je .ring3_<ziel>`. Diese
# Nummern erledigt der Bootloader SELBST oder reicht sie an den Dispatcher
# weiter — beides heisst: es gibt sie.
#
# Nicht uebernommen werden die Spannen-Grenzen (`jb`/`jbe` um 0x0204..0x020F):
# der Bootloader reicht dort PAUSCHAL weiter, Handler gibt es aber nur fuer
# vier der zwoelf Nummern. Wer die Grenzen als belegt liest, erlaubt 518-521
# und 524-527 — genau die Nummern, die dieses Backend einmal ins Leere
# emittiert hat (#1795). Ebenso wenig uebernommen wird 0x999: das ist ein
# Zaehler fuer den Kernel-Selbsttest, kein Aufruf fuer Programme.
awk '
  /cmp[ \t]+rax,[ \t]*(0x)?[0-9A-Fa-f]+/ {
      nr = $0
      sub(/.*rax,[ \t]*/, "", nr)
      sub(/[ \t;].*/, "", nr)
      letzte = nr
      next
  }
  /je[ \t]+\.ring3_/ {
      if (letzte != "") {
          if (letzte ~ /^0x/) printf "%d\n", strtonum(letzte)
          else print letzte + 0
      }
      letzte = ""
      next
  }
  # Jede ANDERE Verzweigung entwertet den zuletzt gesehenen Vergleich. Ohne
  # das erbte ein spaeteres `je .ring3_*` die Zahl aus einer Spannen-Grenze:
  # 0x020F (527) wanderte so in den erlaubten Raum, obwohl dort kein Handler
  # steht.
  # (`\b` waere in awk ein Backspace, kein Wortende — deshalb [ \t].)
  /^[ \t]*(j[a-z]+|call|ret)[ \t]/ { letzte = "" }
' "$BOOT" | sort -n -u > "$TMP/b.txt"

sort -n -u "$TMP/a.txt" "$TMP/b.txt" > "$TMP/alle.txt"

# --- Laeufe bilden ---------------------------------------------------------
{
  echo "# Belegter LyxOS-Syscall-Raum — erzeugt von tools/lyxos_syscall_abgleich.sh"
  echo "# NICHT von Hand pflegen. Quellen (nur gelesen), Stand $HERKUNFT:"
  echo "#   A doku/syscalls_ist.md   (aus kernel/ring3.lyx erzeugt)"
  echo "#   B bootloader/boot.asm    (Abfaenge VOR dem Dispatcher)"
  echo "#"
  echo "# Eine Zeile je zusammenhaengendem Lauf: 'von bis quelle'. Quelle B heisst:
# mindestens eine Nummer des Laufs steht NUR im Bootloader."
  echo "# Die Luecken INNERHALB der Spannen sind die Aussage — eine grobe"
  echo "# Spanne 0..255 wuerde sie stillschweigend durchlassen (#1734)."
  awk '
    { n = $1
      if (von == "") { von = n; bis = n; next }
      if (n == bis + 1) { bis = n; next }
      print von, bis; von = n; bis = n }
    END { if (von != "") print von, bis }
  ' "$TMP/alle.txt" | while read -r von bis; do
      # Herkunft je Lauf: steht jede Nummer des Laufs in A?
      quelle="A"
      n=$von
      while [ "$n" -le "$bis" ]; do
          grep -qx "$n" "$TMP/a.txt" || quelle="B"
          n=$((n + 1))
      done
      echo "$von $bis $quelle"
  done
} > "$TMP/neu.txt"

ANZ=$(wc -l < "$TMP/alle.txt")

if [ "$SCHREIBEN" = "1" ]; then
    mkdir -p "$(dirname "$STAND")"
    cp "$TMP/neu.txt" "$STAND"
    echo "geschrieben: $STAND ($ANZ Nummern, LyxOS $HERKUNFT)"
    exit 0
fi

echo "LyxOS $HERKUNFT: $ANZ belegte Nummern (A: $(wc -l < "$TMP/a.txt"), nur B: $(comm -13 <(sort "$TMP/a.txt") <(sort "$TMP/b.txt") | sort -n | tr '\n' ' '))"

RC=0
if [ ! -f "$STAND" ]; then
    echo "FEHLT: $STAND — mit --schreiben anlegen"
    RC=1
elif ! diff -u <(grep -v '^#' "$STAND") <(grep -v '^#' "$TMP/neu.txt") > "$TMP/d.txt"; then
    echo
    echo "ABWEICHUNG zum abgelegten Stand ($STAND):"
    sed -n '3,$p' "$TMP/d.txt"
    echo
    echo "Wenn der neue Stand richtig ist: tools/lyxos_syscall_abgleich.sh --schreiben"
    echo "und lyxosNummerBelegt in src/backend/lyxos/emit_lyxos.lyx nachziehen."
    RC=1
else
    # Verglichen werden die LAEUFE, nicht der Kopf. Sonst faerbt jeder
    # LyxOS-Commit die Pruefung rot, auch wenn er an den Syscalls nichts
    # aendert — und ein Test, der aus fremden Gruenden rot wird, wird als
    # erstes ignoriert.
    STAND_HER=$(sed -n 's/^# NICHT von Hand pflegen. Quellen (nur gelesen), Stand \(.*\):$/\1/p' "$STAND")
    if [ "$STAND_HER" != "$HERKUNFT" ]; then
        echo "Stand im Repo ist aktuell (Nummern unveraendert)."
        echo "  abgelegt gegen $STAND_HER, jetzt gemessen gegen $HERKUNFT —"
        echo "  die Herkunftszeile zieht der naechste --schreiben-Lauf nach."
    else
        echo "Stand im Repo ist aktuell."
    fi
fi
exit $RC
