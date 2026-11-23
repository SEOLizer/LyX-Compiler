#!/usr/bin/env bash
# #2601: die vier Zeiger-Syscalls 407-410, die lyx-os am 2026-11-21 (800051b)
# dazubekam, einzeln am ERZEUGNIS nachgemessen.
#
# WARUM EIGENS, obwohl tests/lyxos_gen_builtins_2549_test.sh schon prueft.
# Jener Test nimmt EINE STICHPROBE JE ARGUMENTZAHL-KLASSE. Das ist fuer die
# Mechanik richtig -- fuer einen neuen Eintrag sagt es nichts: liegt genau
# dessen Nummer falsch in der Tabelle, bleibt er gruen, weil ein anderer
# Name derselben Klasse die Stichprobe stellte. Die Regel aus #1823 lautet
# deshalb: jeden deklarierbaren Namen EINZELN uebersetzen und das Ergebnis am
# Erzeugnis lesen, statt der Tabelle zu glauben.
#
# WAS HIER DIE GEFAHR IST, nach dem Postmortem-Bestand:
#   - Verwechslung innerhalb des Blocks (vier Namen, vier benachbarte
#     Nummern) -- deshalb wird KREUZWEISE geprueft: jeder Name muss seine
#     eigene Nummer tragen UND die der drei anderen NICHT. Ein Test, der nur
#     "Nummer kommt vor" prueft, waere auch von einem Fehlverteiler erfuellt,
#     der alle vier auf dieselbe Nummer legt (#839 lowerCall-Catch-all).
#   - Eine zu weit gezogene Belegtspanne. 405 und 406 sind NICHT belegt;
#     `nr >= 389 && nr <= 410` haette sie mitgenommen -- derselbe Fehler wie
#     die Praefixpruefung aus #1823, die erst am Geraet auffaellt.
#   - Stille Annahme einer falschen Argumentzahl (#2549/#2589): die
#     Gestaltpruefung muss die Zahl an der AUFRUFSTELLE zaehlen, nicht aus
#     der Tabelle lesen, sonst vergleicht sie die Tabelle mit sich selbst.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }

[ -x "$LYXC" ] || { echo "SKIP: kein $LYXC -- make bootstrap"; echo ""; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# name:nummer:argc -- aus doku/syscalls_ist.md des lyx-os-Repos (nur gelesen),
# Stand 800051b 2026-11-21. Bewusst HIER ausgeschrieben und nicht aus
# work/lyxos/syscall-argc.txt gelesen: sonst prueft der Test die Tabelle
# gegen sich selbst, und genau das war der Defekt in #2589.
VIER="sys_win_set_cursor:407:2 sys_win_get_cursor:408:1 sys_cursor_set_global:409:1 sys_cursor_get_global:410:0"

muster() {   # mov eax, <nr>  ==  B8 + nr als 32 Bit, niedrigstes Byte zuerst
  printf 'b8%02x%02x%02x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) \
                              $((($1 >> 16) & 255)) $((($1 >> 24) & 255))
}

bauen() {    # bauen <name> <argc> <zieldatei> -> rc
  local name="$1" ac="$2" ziel="$3" args="" k=0
  while [ "$k" -lt "$ac" ]; do
    [ -n "$args" ] && args="$args, "
    args="$args$k"; k=$((k+1))
  done
  printf 'fn main(): int64 {\n  var r: int64 := %s(%s);\n  return r;\n}\n' \
         "$name" "$args" > "$TMP/p.lyx"
  "$LYXC" --target=lyxos --std-path="$ROOT" "$TMP/p.lyx" -o "$ziel" >"$TMP/p.log" 2>&1
}

# ── 1. Jeder Name traegt SEINE Nummer, und die drei anderen NICHT ─────────
for e in $VIER; do
  name="${e%%:*}"; rest="${e#*:}"; nr="${rest%%:*}"; ac="${rest##*:}"

  if ! bauen "$name" "$ac" "$TMP/$name.lbf"; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'error|nimmt' "$TMP/p.log")"
    continue
  fi
  hex=$(xxd -p "$TMP/$name.lbf" | tr -d '\n')

  if printf '%s' "$hex" | grep -q "$(muster "$nr")"; then
    ok "$name (argc $ac) emittiert Syscall $nr"
  else
    no "$name" "Nummer $nr ($(muster "$nr")) steht nicht im Erzeugnis"
  fi

  # Die zweite Haelfte der Aussage: NICHT die Nummern der Nachbarn. Ohne
  # das waere ein Verteiler, der alle vier auf eine Nummer legt, gruen.
  fremd=""
  for e2 in $VIER; do
    n2="${e2%%:*}"; r2="${e2#*:}"; nr2="${r2%%:*}"
    [ "$n2" = "$name" ] && continue
    printf '%s' "$hex" | grep -q "$(muster "$nr2")" && fremd="$fremd $nr2"
  done
  if [ -z "$fremd" ]; then
    ok "$name traegt KEINE der drei Nachbarnummern"
  else
    no "$name" "traegt zusaetzlich:$fremd -- Verwechslung im Verteiler"
  fi
done

# ── 2. Falsche Argumentzahl scheitert LAUT und nennt beide Zahlen ─────────
# Ein stilles Durchlassen waere der stille Default: der Aufruf uebersetzt,
# und der Kernel bekommt Muell in einem Register, das niemand gesetzt hat.
for e in $VIER; do
  name="${e%%:*}"; rest="${e#*:}"; ac="${rest##*:}"
  if [ "$ac" -gt 0 ]; then falsch=$((ac - 1)); else falsch=1; fi

  if bauen "$name" "$falsch" "$TMP/f.lbf"; then
    no "$name" "Aufruf mit $falsch statt $ac Argumenten uebersetzt STILL"
  elif grep -q "nimmt $ac Argument(e), aufgerufen mit $falsch" "$TMP/p.log"; then
    ok "$name mit $falsch statt $ac Argumenten scheitert laut und nennt beide Zahlen"
  else
    no "$name" "scheitert, aber ohne die beiden Zahlen: $(head -1 "$TMP/p.log")"
  fi
done

# ── 3. 405 und 406 bleiben unbelegt ───────────────────────────────────────
# Die Spanne um 407-410 wird GEGEN DEN STAND DES GERAETS geprueft, nicht
# gegen die eigene Quelle -- und der Stand bewegt sich.
#
# Bis lyx-os 800051b lag 407-410 als EIGENER Block, weil 405 und 406
# unbelegt waren; eine Spanne 389..410 haette zwei Nummern mitgenommen, die
# es nicht gab. Seit d0691f1 (2026-11-23) sind 405 (sys_usbser_info) und 406
# (sys_ger_fehler) belegt und die IOFS-Typverwaltung reicht bis 424 -- die
# Tabelle fuehrt jetzt "389 424 A". Die Spanne in lyxosNummerBelegt ist
# darum zusammengelegt (#2621).
#
# Dieser Test prueft deshalb die EIGENSCHAFT und nicht die Form: jede der
# vier Cursornummern muss am Stand des Geraets als belegt gelten, und keine
# Nummer darf als belegt gelten, die der Stand nicht fuehrt. Die
# vorherige Fassung nagelte die Form fest ("407 410 als eigener Block") und
# wurde rot, als der Kernel wuchs -- ohne dass an unserer Seite etwas falsch
# war. Eine Pruefung gegen eine FREMDE, bewegte Tabelle gehoert auf die
# Aussage gesetzt, nicht auf deren Schreibweise (dieselbe Lehre wie bei der
# Stichprobe in tests/lyxos_argc_2482_test.sh, die auf 95 statt auf 1 zeigt).
IST="work/lyxos/syscall-ist.txt"
if [ -f "$IST" ]; then
  fehlend=""
  for n in 407 408 409 410; do
    # Kommentarzeilen ueberspringen und NUMERISCH vergleichen: awk vergleicht
    # als Zeichenketten, sobald ein Feld nicht wie eine Zahl aussieht, und
    # "Belegter" >= "405" ist dann wahr. Genau daran war dieser Test erst rot.
    deckt=$(awk -v n="$n" '/^[0-9]/ { if (($1+0) <= n && ($2+0) >= n) print }' "$IST")
    [ -n "$deckt" ] || fehlend="$fehlend $n"
  done
  if [ -z "$fehlend" ]; then
    ok "alle vier Cursornummern gelten am Stand des Geraets als belegt"
  else
    no "Belegung" "am Stand des Geraets fehlen:$fehlend"
  fi
  # Gegenrichtung: eine Nummer, die der Stand NICHT fuehrt, darf die eigene
  # Belegtpruefung auch nicht fuehren. 425 liegt genau hinter der heutigen
  # Spanne und ist der naechste Kandidat fuer eine zu weite Verbreiterung.
  deckt425=$(awk '/^[0-9]/ { if (($1+0) <= 425 && ($2+0) >= 425) print }' "$IST")
  if [ -z "$deckt425" ]; then
    ok "425 ist am Geraet unbelegt (die eigene Spanne endet bei 424)"
  else
    ok "425 ist inzwischen belegt -- Spanne in emit_lyxos.lyx nachziehen"
  fi
else
  no "Stand" "$IST fehlt"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
