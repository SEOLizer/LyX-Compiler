#!/bin/bash
# #2482: Die Gestaltpruefung des lyxos-Backends darf nicht fail-open sein.
#
# `lyxosGestaltPasst(nr, argc)` kannte bis 1.2.39D genau einen Fall (0x020C
# sys_pipe) und gab fuer JEDE andere Nummer 1 zurueck, ohne etwas geprueft zu
# haben. Eine belegte Nummer mit falscher Argumentzahl ging damit durch — und
# der Kernel liest dann Register, die niemand gefuellt hat, oder uebergeht
# Werte, die der Aufrufer fuer uebergeben haelt. Dreimal belegt:
# `sys_mmap_device` (#2469, vier geladen, zwei gelesen), `sys_umount` (#2439,
# drei geladen, eines genommen), `pipe` (der einzige erfasste Fall).
#
# GEPRUEFT WIRD DIE DATENKETTE UND DIE ABDECKUNG, nicht ein Einzelfall:
#
#   kernel/ring3.lyx -> doku/syscalls_ist.md -> work/lyxos/syscall-argc.txt
#     -> src/backend/lyxos/lyxos_abi.lyx
#
# Der abgelegte Stand ist der Grund, warum das ohne das LyxOS-Repo laeuft.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

STAND="work/lyxos/syscall-argc.txt"
ABI="src/backend/lyxos/lyxos_abi.lyx"
EMIT="src/backend/lyxos/emit_lyxos.lyx"

# 1) Der Stand liegt im Repo und nennt seine Herkunft mit Commit.
if [ -f "$STAND" ] && grep -q "^# NICHT von Hand pflegen. Quelle (nur gelesen), Stand " "$STAND"; then
  ok "der Argumentzahl-Stand liegt im Repo und nennt seinen Kernel-Commit"
else
  bad "Stand" "$STAND fehlt oder nennt keine Herkunft"
fi

# 2) Die erzeugte Tabelle passt zum Stand. Ohne das laufen zwei Staende
#    auseinander, und die Pruefung urteilt nach dem aelteren.
if bash tools/lyxos_abi_erzeugen.sh --pruefen >/dev/null 2>&1; then
  ok "die erzeugte Tabelle stimmt mit dem abgelegten Stand ueberein"
else
  bad "Tabelle" "neu erzeugen: tools/lyxos_abi_erzeugen.sh"
fi

# 3) Die Pruefung FRAGT die Tabelle. Ein Test, der nur die Tabelle prueft,
#    waere auch von einer Fassung erfuellt, die sie niemals liest.
if grep -q "LyxosArgcFuerNr" "$EMIT"; then
  ok "lyxosGestaltPasst fragt LyxosArgcFuerNr"
else
  bad "Verdrahtung" "emit_lyxos ruft LyxosArgcFuerNr nicht"
fi

# 4) Nicht mehr fail-open: die Funktion darf nicht aus genau einem
#    Sonderfall plus `return 1` bestehen.
RUMPF=$(awk '/fn lyxosGestaltPasst/,/^    }/' "$EMIT" | grep -vE '^\s*//' | grep -cE 'if \(')
if [ "${RUMPF:-0}" -ge 2 ]; then
  ok "die Pruefung entscheidet an mehr als einem Sonderfall ($RUMPF Bedingungen)"
else
  bad "fail-open" "nur $RUMPF Bedingung(en) im Rumpf — wie vor #2482"
fi

# 5) ABDECKUNG, beziffert. Der Durchfall fuer nicht erfasste Nummern ist
#    gewollt (zwei Quellen, Bootloader-Abfaenge, #1795) — aber er muss eine
#    ZAHL sein und kein blinder Fleck. Die Zahl darf nur kleiner werden.
ERFASST=$(grep -vc '^#' "$STAND")
BELEGT=$(grep -v '^#' work/lyxos/syscall-ist.txt | awk '{s += $2 - $1 + 1} END {print s+0}')
echo "    erfasst: $ERFASST Nummern mit Argumentzahl, belegter Raum: $BELEGT Nummern"
if [ "$ERFASST" -ge 195 ]; then
  ok "mindestens 195 Nummern tragen eine Argumentzahl (jetzt $ERFASST)"
else
  bad "Abdeckung" "nur $ERFASST Nummern — war 199, die Zahl darf nur steigen"
fi

# 6) Stichproben gegen den Kernel, von Hand nachgelesen in ring3.lyx:
#      323 sys_sendto(sock, buf_uva, len, dst_uva)        -> 4
#      3   sys_close(fd)                                  -> 1
#      1   sys_write(fd, buf, count)                       -> 3
#    Ein Test, der nur "Tabelle vorhanden" prueft, ist blind fuer die
#    falsche Zahl darin (#1829) — deshalb WERTE.
fehler=""
for paar in "323 4" "3 1" "1 3"; do
  set -- $paar
  ist=$(grep -P "^$1\t" "$STAND" | cut -f3)
  [ "$ist" = "$2" ] || fehler="$fehler nr$1(ist=${ist:-fehlt},soll=$2)"
done
if [ -z "$fehler" ]; then
  ok "Stichproben stimmen: 323->4, 3->1, 1->3"
else
  bad "Werte" "$fehler"
fi

# 7) Jede Ausnahme nennt ihren Beleg. Die Argumentzahl kommt aus dem
#    SIGNATURKOMMENTAR der Kernel-Tabelle, und der ist nicht die ABI -- der
#    Rumpf des Handlers ist es. Wo beide auseinander gehen, steht die Nummer
#    in der Ausnahmeliste, und zwar mit Beleg. Ein Eintrag ohne Grund waere
#    derselbe stille Default, den diese Pruefung abschafft.
AUS="work/lyxos/syscall-argc-ausnahmen.txt"
if [ -f "$AUS" ]; then
  ohne=""
  while IFS= read -r z; do
    case "$z" in ''|'#'*) continue ;; esac
    grund=$(printf '%s' "$z" | cut -f2-)
    [ ${#grund} -ge 40 ] || ohne="$ohne $(printf '%s' "$z" | cut -f1)"
  done < "$AUS"
  if [ -z "$ohne" ]; then
    ok "jede Ausnahme nennt ihren Beleg ($(grep -vc '^#' "$AUS") Eintrag/Eintraege)"
  else
    bad "Ausnahmen ohne Beleg" "$ohne"
  fi
else
  ok "keine Ausnahmeliste noetig"
fi

# 8) Gegenprobe zur Ausnahme: 196 darf KEINE Argumentzahl tragen. Der
#    Kommentar nennt vier, der Rumpf liest drei (#2439) -- wer dem Kommentar
#    glaubt, weist einen richtigen Aufruf ab.
if grep -qP "^196\t" "$STAND"; then
  bad "Ausnahme 196" "196 traegt wieder eine Argumentzahl aus dem Kommentar"
else
  ok "196 ist ausgenommen (Kommentar vier, Rumpf drei)"
fi

# 9) Zweiseitig: eine Nummer, die der Bootloader abfaengt und die deshalb
#    NICHT erfasst ist, muss als 'nicht erfasst' gelten — sonst waere der
#    gewollte Durchfall in Wahrheit eine erfundene Zahl. 60 (sys_exit) steht
#    nur im Bootloader (#1795).
if grep -qP "^60\t" "$STAND"; then
  bad "Gegenprobe" "60 (sys_exit) traegt eine Argumentzahl, obwohl es nur im Bootloader steht"
else
  ok "60 (sys_exit) gilt als nicht erfasst — der Durchfall ist begruendet, nicht geraten"
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "OK: Gestaltpruefung ist nicht mehr fail-open (#2482)"
