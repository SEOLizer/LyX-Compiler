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
# Der Block 407-410 steht als EIGENE Spanne in lyxosNummerBelegt. Waere er
# als 389..410 geschrieben, gaelten zwei Nummern als belegt, die es im
# Kernel nicht gibt -- und das faellt erst am Geraet auf. Geprueft wird am
# Stand des Geraets, nicht an der eigenen Quelle.
IST="work/lyxos/syscall-ist.txt"
if [ -f "$IST" ]; then
  # Kommentarzeilen ueberspringen und NUMERISCH vergleichen: awk vergleicht
  # als Zeichenketten, sobald ein Feld nicht wie eine Zahl aussieht, und
  # "Belegter" >= "405" ist dann wahr. Genau daran war dieser Test erst rot.
  deckt=$(awk '/^[0-9]/ { if (($1+0) <= 405 && ($2+0) >= 405) print; \
                          if (($1+0) <= 406 && ($2+0) >= 406) print }' "$IST")
  if [ -n "$deckt" ]; then
    no "405/406" "gelten laut $IST als belegt ($deckt) -- die eigene Spanne 407..410 muesste dann anders aussehen"
  else
    ok "405 und 406 sind am Geraet unbelegt (Annahme der eigenen Spanne)"
  fi
  if grep -q '^407 410 ' "$IST"; then
    ok "der Stand des Geraets fuehrt 407-410 als eigenen Block"
  else
    no "407-410" "stehen in $IST nicht als eigener Block"
  fi
else
  no "Stand" "$IST fehlt"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
