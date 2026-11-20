#!/usr/bin/env bash
# #2589: Der BSD-Socket-Block 1536-1545 war ungeprueft, und der Kopfkommentar
# von std/net/socket.lyx behauptete das Gegenteil des Kernels.
#
# Vorgeschichte. Der Kommentar sagte "LyxOS kennt kein accept ... einen
# annehmenden Horcher gibt es nicht". Gemessen am Dispatcher
# (kernel/ring3.lyx:4571-4603) ist der vollstaendige Block da, und SkAccept ist
# in kernel/sock08.lyx:168 echt umgesetzt. Auf diesen Kommentar wurde ein
# Issue gebaut (#2585), das deshalb als unbegruendet geschlossen werden musste.
# Ein Kommentar ueber ein FREMDES Projekt ist eine Behauptung, kein Beleg.
#
# Zweitens war die Gestaltpruefung fuer die Spanne blind: die erzeugte
# Kerneltabelle fuehrt die zehn Nummern ohne Namen und ohne Signatur, also gibt
# LyxosArgcFuerNr -1 und der gewollte Durchfall fuer nicht erfasste Nummern
# greift (#2482).
#
# GEPRUEFT WIRD AN ZWEI VERSCHIEDENEN STELLEN, weil es zwei verschiedene Fragen
# sind:
#   - Die Zahl AM AUFRUF sieht nur sema. Die Gestaltpruefung im Backend
#     vergleicht die Kerneltabelle mit der Argumentzahl, die der
#     Emissionszweig als LITERAL mitgibt -- sie kann einen Aufruf mit zu
#     wenigen Argumenten grundsaetzlich nicht sehen.
#   - Die Zahl AN DER EMISSION sieht nur die Gestaltpruefung.
# Wer nur eine von beiden prueft, haelt die andere fuer gedeckt.
cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
no()  { echo "FAIL $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }

if [ ! -x "$LYXC" ]; then
  echo "SKIP: kein $LYXC -- make bootstrap"
  echo ""
  echo "Ergebnis: 0 PASS, 0 FAIL"
  exit 0
fi

SOCK="std/net/socket.lyx"
EMIT="src/backend/lyxos/emit_lyxos.lyx"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. Der Kopfkommentar behauptet nicht mehr das Gegenteil des Kernels ----
# Der richtiggestellte Kommentar ZITIERT den alten Wortlaut, damit der naechste
# Leser sieht, was korrigiert wurde. Ein Waechter, der nur nach der Zeichenkette
# sucht, haelt dieses Zitat fuer die Behauptung -- genau darin ist dieser Test
# beim ersten Lauf hereingefallen. Gesucht wird darum nach dem Satz AUSSERHALB
# einer als Zitat markierten Zeile.
behauptung=$(grep -n 'LyxOS kennt kein accept' "$SOCK" | grep -v 'ALTER WORTLAUT')
if [ -n "$behauptung" ]; then
  no "Kopfkommentar" "behauptet weiter 'LyxOS kennt kein accept': $behauptung"
else
  ok "der Kopfkommentar behauptet nicht mehr, LyxOS kenne kein accept"
fi

# Gegenprobe: der RICHTIGE Grund fuer -ENOSYS darf nicht mit weggefallen sein.
# Sonst entsteht der umgekehrte Irrtum, hier fehle nichts -- es fehlt etwas,
# nur anderes: accept4 (mit Flags) und die Stapelform sendmmsg/recvmmsg.
if grep -q 'sys_accept4' "$SOCK" && grep -q 'sys_sendmmsg\|sendmmsg' "$SOCK"; then
  ok "der Kopfkommentar nennt weiter den echten Grund (accept4, Stapelform)"
else
  no "Kopfkommentar" "der Grund fuer -ENOSYS (accept4/sendmmsg) fehlt jetzt"
fi

# --- 2. Die Zahl AM AUFRUF: zu wenige Argumente scheitern laut ---------------
# Zweiseitig je Nummer: die richtige Form muss durchgehen UND die emittierte
# Syscallnummer im Erzeugnis stehen; eine zu kurze Form muss abgewiesen werden.
# Name:Argumente:Syscallnummer -- die Lyx-Form, nicht die Kernelgestalt
# (set/getsockopt tragen in Lyx ein fuenftes `optlen`, das Linux braucht).
while IFS=: read -r name args nr; do
  [ -z "$name" ] && continue
  voll=""
  k=0
  while [ "$k" -lt "$args" ]; do
    [ -n "$voll" ] && voll="$voll, "
    voll="${voll}0"
    k=$((k+1))
  done
  printf 'unit main;\nfn main(): int64 { return %s(%s); }\n' "$name" "$voll" > "$TMP/ok.lyx"
  if "$LYXC" "$TMP/ok.lyx" --target=lyxos --std-path=. -o "$TMP/ok.lbf" >"$TMP/ok.log" 2>&1; then
    if NR="$nr" python3 -I - "$TMP/ok.lbf" <<'PY'
import os, struct, sys
d = open(sys.argv[1], 'rb').read()
sys.exit(0 if bytes([0x48, 0xB8]) + struct.pack('<q', int(os.environ['NR'])) in d else 1)
PY
    then
      ok "$name mit $args Argumenten emittiert Syscall $nr"
    else
      no "$name" "uebersetzt, aber Nummer $nr steht nicht im Erzeugnis"
    fi
  else
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/ok.log" | cut -c1-70)"
  fi

  kurz=$((args - 1))
  knapp=""
  k=0
  while [ "$k" -lt "$kurz" ]; do
    [ -n "$knapp" ] && knapp="$knapp, "
    knapp="${knapp}0"
    k=$((k+1))
  done
  printf 'unit main;\nfn main(): int64 { return %s(%s); }\n' "$name" "$knapp" > "$TMP/f.lyx"
  if "$LYXC" "$TMP/f.lyx" --target=lyxos --std-path=. -o "$TMP/f.lbf" >"$TMP/f.log" 2>&1; then
    no "$name" "Aufruf mit $kurz statt $args Argumenten uebersetzt still"
  elif grep -q "zu wenige Argumente im Aufruf von '$name'" "$TMP/f.log"; then
    ok "$name mit $kurz statt $args Argumenten scheitert laut und nennt den Namen"
  else
    no "$name" "scheitert, aber ohne den Namen: $(head -1 "$TMP/f.log" | cut -c1-70)"
  fi
done <<'LISTE'
sys_socket:3:1536
sys_bind:3:1537
sys_listen:2:1538
sys_accept:3:1539
sys_connect:3:1540
sys_sendmsg:3:1541
sys_recvmsg:3:1542
sys_setsockopt:5:1543
sys_getsockopt:5:1544
sys_shutdown:2:1545
LISTE

# --- 3. Die Zahl AN DER EMISSION stimmt mit dem handgepflegten Zusatz ---------
# Das ist ein Abgleich ZWEIER STELLEN IM EIGENEN QUELLTEXT; die aeussere
# Wahrheit ist der Dispatcher (kernel/ring3.lyx:4571-4603 @ c0d0382), und die
# steht als Messung im Kommentar des Zusatzes. Wer die Spanne anfasst, muss
# beide Stellen bewegen -- und genau das haelt diese Pruefung fest.
#
# Die LAUFENDE Wirkung des Zusatzes ist von aussen nicht ausloesbar: sie
# greift erst, wenn ein Emissionszweig eine falsche Argumentzahl mitgibt, und
# dafuer muesste man den Compiler aendern. Darum hier der statische Abgleich,
# ausdruecklich als solcher benannt.
unstimmig=0
while IFS=: read -r id nr soll; do
  [ -z "$id" ] && continue
  ist=$(grep -oE "id == $id \{ self\.emitVfsSyscall\(0x[0-9A-Fa-f]+, [0-9]+" "$EMIT" | grep -oE '[0-9]+$')
  if [ "$ist" != "$soll" ]; then
    unstimmig=$((unstimmig+1))
    echo "  Nummer $nr (id $id): emittiert mit $ist, der Kernel liest $soll"
  fi
done <<'EMISS'
48:1536:3
49:1537:3
50:1538:2
51:1539:3
52:1540:3
53:1541:3
54:1542:3
55:1543:4
56:1544:4
57:1545:2
EMISS
if [ "$unstimmig" = "0" ]; then
  ok "alle zehn Emissionsstellen tragen die am Dispatcher gemessene Argumentzahl"
else
  no "Emission" "$unstimmig Stellen weichen von der gemessenen Kernelgestalt ab"
fi

# Und der Zusatz selbst ist da. Ohne ihn faellt die Spanne wieder durch (#2482),
# und niemand merkt es, weil ein Durchfall keine Meldung erzeugt.
if grep -q 'nr >= 1536 && nr <= 1545' "$EMIT"; then
  ok "lyxosGestaltPasst traegt den handgepflegten Zusatz fuer 1536-1545"
else
  no "Zusatz" "lyxosGestaltPasst hat fuer 1536-1545 wieder keine Angabe"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
