#!/usr/bin/env bash
# tests/lyxos_caps_warnung_test.sh — Wahrheitsgehalt der CAPS-Warnung (#2534, #2537).
#
# Bug: `_meldeCapOhneBit` wurde MITTEN im Scan gerufen, also auf einer halb
# gefuellten Union, und behauptete im zweiten Satz etwas ueber das ganze
# Erzeugnis: "Das LBF kommt beim Ladeprogramm an wie eines ohne Manifest."
# Das stimmt nur, wenn KEIN deklarierter Name ein Bit setzt. Gemessen war
# `@capabilities([fs.read, fs.write, fs.create])` ein LBF mit CAPS=3 — die
# Warnung nannte es manifestlos und hat beinahe zu einem Fehlerbericht ueber
# ein verlorenes Manifest gefuehrt.
#
# Zusaetzlich war die Aufzaehlung der tragenden Namen falsch: `process.*`
# versprach zu viel (nur exec und fork setzen ein Bit), audio.play und
# ui.notify fehlten, obwohl sie Bits setzen.
#
# Geprueft wird deshalb an der WIRKUNG, nicht am Vorhandensein der Warnung:
# fuer jeden Fall die CAPS-Bits AM ERZEUGNIS gegen den Wortlaut der Meldung.
# Beide Seiten, denn ein Test, der nur das Erscheinen des Satzes prueft, waere
# auch von der alten, immer gleichen Meldung erfuellt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# CAPS-TLV (Tag 5, u16-Laenge, 8 Byte LE) aus dem LBF lesen.
capbits() {
  python3 - "$1" <<'PY'
import sys
try: d=open(sys.argv[1],'rb').read()
except Exception: print("ERR"); sys.exit()
i=64+128; end=64+4032
while i<end-3:
    tag=d[i]; ln=d[i+1]|(d[i+2]<<8)
    if tag==0: break
    if tag==5: print(int.from_bytes(d[i+3:i+11],'little')); break
    i+=3+ln
else: print("none")
PY
}

# baue <name> <quelle> → setzt BITS und LOG
build() {
  printf 'unit main;\n%s\nfn main(): int64 { return 0; }\n' "$2" > "$TMP/$1.lyx"
  ( cd "$ROOT" && "$LYXC" --std-path=. --target=lyxos "$TMP/$1.lyx" -o "$TMP/$1.lbf" ) \
    > "$TMP/$1.log" 2>&1
  BITS="$(capbits "$TMP/$1.lbf")"
  LOG="$TMP/$1.log"
}

ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
nok()  { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

echo "--- 1. Union != 0: Erzeugnis traegt ein Manifest, Meldung darf es nicht leugnen ---"
# Der Fall aus #2534: fs.create setzt kein Bit, fs.read/fs.write schon.
build mixed '@capabilities([fs.read, fs.write, fs.create])'
if [ "$BITS" != "3" ]; then
  nok "mixed_bits" "CAPS am Erzeugnis = $BITS, erwartet 3 (fs.read=1 | fs.write=2)"
else
  ok "mixed_bits (CAPS=3 am Erzeugnis)"
fi
# Die Warnung zu fs.create SOLL kommen -- der Name bewirkt wirklich nichts.
if grep -q "@capabilities(fs.create) setzt kein Bit" "$LOG"; then
  ok "mixed_warnung_kommt"
else
  nok "mixed_warnung_kommt" "keine Warnung zu fs.create"
fi
# ... aber sie darf NICHT behaupten, das Manifest sei verloren. Das ist der Fix.
if grep -q "wie eines" "$LOG"; then
  nok "mixed_kein_totalverlust" "Meldung behauptet manifestlos, obwohl CAPS=$BITS"
else
  ok "mixed_kein_totalverlust"
fi
if grep -q "NICHT manifestlos" "$LOG"; then
  ok "mixed_sagt_was_gilt"
else
  nok "mixed_sagt_was_gilt" "Meldung sagt nicht, dass das Manifest getragen wird"
fi

echo "--- 2. Union == 0: dann ist die alte Aussage richtig und muss stehen ---"
build leer '@capabilities([fs.create])'
if [ "$BITS" != "0" ]; then
  nok "leer_bits" "CAPS am Erzeugnis = $BITS, erwartet 0"
else
  ok "leer_bits (CAPS=0 am Erzeugnis)"
fi
if grep -q "wie eines" "$LOG" && grep -q "ohne Manifest" "$LOG"; then
  ok "leer_totalverlust_gemeldet"
else
  nok "leer_totalverlust_gemeldet" "Union 0, aber die Meldung sagt es nicht"
fi
if grep -q "NICHT manifestlos" "$LOG"; then
  nok "leer_keine_falsche_entwarnung" "Union 0, aber die Meldung entwarnt"
else
  ok "leer_keine_falsche_entwarnung"
fi

echo "--- 3. Die Aufzaehlung der tragenden Namen stimmt, je Name am Erzeugnis ---"
# Jeder Name, den die Meldung als bit-setzend nennt, MUSS einzeln ein Bit
# setzen (#1823: der Tabelle nicht glauben, am Erzeugnis lesen).
for n in fs.read fs.write network.tcp.bind network.tcp.connect network.udp.bind \
         network.udp.connect network.unix network.raw process.exec process.fork \
         ki.embed ki.graph audio.mic audio.play ui.notify system.config \
         hardware.block hardware.gpio hardware.i2c hardware.spi hardware.usb; do
  build "pos_${n//./_}" "@capabilities([$n])"
  if [ "$BITS" = "0" ] || [ "$BITS" = "none" ] || [ "$BITS" = "ERR" ]; then
    nok "genannt_setzt_bit_$n" "Meldung nennt $n als tragend, Erzeugnis traegt $BITS"
  else
    ok "genannt_setzt_bit_$n (=$BITS)"
  fi
done

# Und die Gegenseite: process.exit/signal/sched/privileges wurden von der alten
# Formel `process.*` mitversprochen, setzen aber kein Bit. Dieselbe Praefix-
# Falle wie #1823, nur in der Meldung statt in der Zuordnung.
for n in process.exit process.signal process.sched process.privileges \
         fs.create fs.delete fs.meta fs.perm memory.mmap memory.lock; do
  build "neg_${n//./_}" "@capabilities([$n])"
  if [ "$BITS" != "0" ]; then
    nok "nicht_genannt_setzt_kein_bit_$n" "setzt $BITS, gehoert dann in die Aufzaehlung"
  else
    ok "nicht_genannt_setzt_kein_bit_$n"
  fi
done

echo "--- 4. Die Meldung verspricht process.* nicht mehr pauschal ---"
build nurexit '@capabilities([process.exit])'
if grep -qE "process\.\*" "$LOG"; then
  nok "kein_process_stern" "Meldung nennt weiter process.* -- trifft exit/signal/sched/privileges mit"
else
  ok "kein_process_stern"
fi
for n in audio.play ui.notify; do
  if grep -q "$n" "$LOG"; then ok "aufzaehlung_nennt_$n"
  else nok "aufzaehlung_nennt_$n" "setzt ein Bit, fehlt aber in der Aufzaehlung"; fi
done

echo "--- 5. Verweise zeigen auf den Vorgang, der das entschieden hat ---"
# Die alte Meldung verwies auf #1755/#1759/#1797/#1826 -- alle geschlossen und
# alle zu anderen Namen. Wer der Spur folgte, landete im Nichts.
if grep -qE "#(1755|1759|1797|1826)" "$LOG"; then
  nok "keine_toten_verweise" "verweist weiter auf geschlossene, unpassende Issues"
else
  ok "keine_toten_verweise"
fi

echo
echo "lyxos_caps_warnung_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
