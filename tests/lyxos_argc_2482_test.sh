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
if [ "$ERFASST" -ge 300 ]; then
  ok "mindestens 300 Nummern tragen eine Argumentzahl (jetzt $ERFASST)"
else
  bad "Abdeckung" "nur $ERFASST Nummern — war 304 nach #2621, die Zahl darf nur steigen"
fi

# 6) Stichproben gegen den Kernel, von Hand nachgelesen in ring3.lyx:
#      323 sys_sendto(sock, buf_uva, len, dst_uva)        -> 4
#      3   sys_close(fd)                                  -> 1
#      95  sys_write(fd, buf, count)                      -> 3   (ring3.lyx:2078)
#      0   sys_read(fd, buf, count)                       -> 3
#    Ein Test, der nur "Tabelle vorhanden" prueft, ist blind fuer die
#    falsche Zahl darin (#1829) — deshalb WERTE.
#
#    HIER STAND `1 3` fuer sys_write. Nummer 1 trug die Signatur bis
#    LyxOS c0d0382 und war eine Dublette zu 95; seit 2d5bddc fuehrt die
#    Tabelle dort WP-S4 ("stdout dieses Strangs ist umgeleitet") OHNE
#    Signatur, und die Stichprobe war ohne eigenes Verschulden rot.
#    Lehre: eine Stichprobe gegen eine FREMDE, bewegte Tabelle gehoert auf
#    die Nummer gesetzt, die die Umsetzung TRAEGT (95, mit Rumpf im
#    Dispatcher), nicht auf die Kompatibilitaetsnummer daneben -- eine
#    Bruecke darf verschwinden, der Rumpf nicht.
fehler=""
for paar in "323 4" "3 1" "95 3" "0 3"; do
  set -- $paar
  ist=$(grep -P "^$1\t" "$STAND" | cut -f3)
  [ "$ist" = "$2" ] || fehler="$fehler nr$1(ist=${ist:-fehlt},soll=$2)"
done
if [ -z "$fehler" ]; then
  ok "Stichproben stimmen: 323->4, 3->1, 95->3, 0->3"
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

# 10) #2598: Signaturen mit vorangestelltem Arbeitspaketkuerzel. Der Auszug
#     verlangte die Signatur am SPALTENANFANG und liess damit 62 der 293
#     lesbaren Gestalten durchfallen -- darunter die beiden, mit denen ein
#     Geraetelauf seine Ausgabe zurueckholt. Stichproben auf genau diese Form:
#       389  "WP-S0 sys_serial_set(rolle, wert): ..."      -> 2
#       404  "WP-S4 sys_stdio_vormerken(welche, fd): ..."  -> 2
#       230  "DRV-3: sys_map_device(phys, size) -> uva"    -> 2
#     Sie stehen hier mit WERT und nicht als Anwesenheitsprobe: eine Liste,
#     die nur Vorhandensein prueft, ist blind fuer die falsche Zahl darin.
fehler=""
for paar in "389 2" "404 2" "230 2" "2561 3"; do
  set -- $paar
  ist=$(grep -P "^$1\t" "$STAND" | cut -f3)
  [ "$ist" = "$2" ] || fehler="$fehler nr$1(ist=${ist:-fehlt},soll=$2)"
done
if [ -z "$fehler" ]; then
  ok "Kuerzel-Form ist erfasst: 389->2, 404->2, 230->2, 2561->3 (#2598)"
else
  bad "Kuerzel-Form" "$fehler"
fi

# 11) Die andere Seite derselben Verschaerfung, AM ERZEUGNIS. Mit 2561 im
#     Auszug fiel auf, dass das Backend dort nur ZWEI Werte lud, waehrend
#     ir_lower drei Slots ablegt und der Kernelrumpf a0, a1 und a2 liest
#     (lyx-os ring3.lyx: TraceEvent(a0, tep, a2)). Die Laenge fiel still weg.
#
#     Geprueft wird die WIRKUNG im LBF, nicht der Quelltext: zwischen
#     `mov rax, 2561` (48 b8 01 0a 00..) und `syscall` (0f 05) muessen drei
#     Registerladungen stehen, einschliesslich rdx (48 8b 55). Vor dem Fix
#     endete die Folge nach rsi -- dieser Test waere rot gewesen.
if [ -x ./lyxc ]; then
  TD=$(mktemp -d)
  printf 'unit main;\nfn main(): int64 { return sys_trace_event(17, 0, 3); }\n' > "$TD/te.lyx"
  if ./lyxc --std-path=. --target=lyxos "$TD/te.lyx" -o "$TD/te.lbf" >"$TD/te.log" 2>&1; then
    if python3 - "$TD/te.lbf" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(bytes.fromhex('48b8010a000000000000'))
if i < 0:
    print('kein mov rax, 2561 im Erzeugnis'); sys.exit(1)
rest = d[i+10:i+40]
ende = rest.find(bytes.fromhex('0f05'))
if ende < 0:
    print('kein syscall nach dem Laden'); sys.exit(1)
lade = rest[:ende]
fehlt = [n for n, b in (('rdi','488b7d'), ('rsi','488b75'), ('rdx','488b55')) if bytes.fromhex(b) not in lade]
if fehlt:
    print('es fehlt die Ladung fuer: ' + ', '.join(fehlt) + ' -- ' + lade.hex(' ')); sys.exit(1)
sys.exit(0)
PYEOF
    then
      ok "sys_trace_event laedt im Erzeugnis drei Register (rdi, rsi, rdx) (#2598)"
    else
      bad "Erzeugnis 2561" "die dritte Ladung fehlt im LBF"
    fi
  else
    bad "Erzeugnis 2561" "sys_trace_event(17, 0, 3) uebersetzt nicht: $(head -2 "$TD/te.log" | tr '\n' ' ')"
  fi
  rm -rf "$TD"
else
  echo "    SKIP 11: ./lyxc fehlt (make bootstrap)"
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "OK: Gestaltpruefung ist nicht mehr fail-open (#2482), Kuerzel-Form erfasst (#2598)"
