#!/usr/bin/env bash
# #2360 Scheibe C — Suchschleifen vorspulen.
#
#   while (i < n) { if (peekW(a+i) == / != peekW(b+i)) { ... } i += 1; }
#
# Der Vektorteil führt den Rumpf NIE aus; er überspringt nur Blöcke, in denen
# die Bedingung für kein Element zutrifft. Dort tut die skalare Fassung nichts
# außer `i += 1`, das Vorspulen ist also beobachtbar gleichwertig.
#
# Geprüft wird in drei Richtungen, weil jede einzeln blind wäre:
#   1. WERT — Vektorfassung und skalare Fassung geben Zeichen für Zeichen
#      dasselbe aus, einschließlich des Zählers NACH der Schleife (bei
#      Frühausstieg ist er n+1, nicht n).
#   2. ERZEUGNIS — die PCMPEQ-Bytes stehen wirklich drin. Ohne das könnte
#      Punkt 1 auch von einem Vektorisierer erfüllt sein, der nie greift.
#   3. GEGENRICHTUNG — Formen, die nicht vorgespult werden dürfen, tragen
#      KEINE PCMPEQ-Bytes: Aufruf in der Bedingung (Nebenwirkung), `<` statt
#      Gleichheit, dritte Anweisung im Rumpf.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

zaehl() { # Datei Hexmuster -> Vorkommen
  python3 - "$1" "$2" <<'PY'
import sys
print(open(sys.argv[1],'rb').read().count(bytes.fromhex(sys.argv[2])))
PY
}

# ── 1. und 2.: Wert und Erzeugnis ───────────────────────────────────────────
Q=tests/vektor_suche_2360/faelle.lyx
if "$LYXC" --std-path=. "$Q" -o "$TMP/vek" >"$TMP/b1.log" 2>&1; then
  ok "faelle_uebersetzt_vektor"
else
  bad "faelle_uebersetzt_vektor"; tail -5 "$TMP/b1.log"
fi
# --debug schaltet die Erkennung ab (DEBUG_MODE) und ist damit die skalare
# Vergleichsfassung derselben Quelle.
if "$LYXC" --std-path=. --debug "$Q" -o "$TMP/ska" >"$TMP/b2.log" 2>&1; then
  ok "faelle_uebersetzt_skalar"
else
  bad "faelle_uebersetzt_skalar"; tail -5 "$TMP/b2.log"
fi

if [ -x "$TMP/vek" ] && [ -x "$TMP/ska" ]; then
  "$TMP/vek" > "$TMP/out_vek.txt" 2>&1; rcv=$?
  "$TMP/ska" > "$TMP/out_ska.txt" 2>&1; rcs=$?
  if [ "$rcv" = "0" ] && [ "$rcs" = "0" ]; then
    ok "beide_fassungen_laufen"
  else
    bad "beide_fassungen_laufen (vek=$rcv ska=$rcs)"
  fi
  if diff -q "$TMP/out_ska.txt" "$TMP/out_vek.txt" >/dev/null; then
    ok "wert_identisch_zur_skalaren_fassung"
  else
    bad "wert_identisch_zur_skalaren_fassung"; diff "$TMP/out_ska.txt" "$TMP/out_vek.txt" | head -10
  fi
  # Der Zähler nach der Schleife: bei Frühausstieg n+1. Steht so in der
  # Ausgabe und ist die Stelle, an der #2357 einen zweiten Schaden fand.
  if grep -q "i_danach=101" "$TMP/out_vek.txt" && grep -q "i_danach=100" "$TMP/out_vek.txt"; then
    ok "zaehler_nach_der_schleife (101 bei Treffer, 100 ohne)"
  else
    bad "zaehler_nach_der_schleife"; grep i_danach "$TMP/out_vek.txt" | head -4
  fi
  # Trefferpositionen einzeln: erstes, letztes im Block, erster im nächsten
  # Block, im Rest hinter dem letzten vollen Block, keiner.
  erw="fund=0 fund=1 fund=15 fund=16 fund=99 fund=96 fund=-1"
  fehlt=""
  for e in $erw; do grep -q "  $e\$" "$TMP/out_vek.txt" || fehlt="$fehlt $e"; done
  if [ -z "$fehlt" ]; then ok "alle_sieben_trefferlagen"; else bad "Trefferlagen fehlen:$fehlt"; fi

  nb=$(zaehl "$TMP/vek" 660f74c1); nw=$(zaehl "$TMP/vek" 660f75c1); nd=$(zaehl "$TMP/vek" 660f76c1)
  if [ "$nb" -ge 2 ] && [ "$nw" -ge 1 ] && [ "$nd" -ge 1 ]; then
    ok "erzeugnis_traegt_pcmpeqb/w/d ($nb/$nw/$nd)"
  else
    bad "erzeugnis_traegt_pcmpeq (b=$nb w=$nw d=$nd)"
  fi
  if [ "$(zaehl "$TMP/ska" 660f74c1)" = "0" ]; then
    ok "skalare_fassung_ohne_pcmpeqb (Gegenrichtung)"
  else
    bad "skalare_fassung_ohne_pcmpeqb"
  fi
fi

# ── Breite 8 hängt an der ZUSAGE, nicht an der Laufmaschine ─────────────────
# Ohne --target-cpu ist SSE4.1 nicht zugesagt: dann kein PCMPEQQ. Mit der
# Zusage muss es da sein. Beide Seiten, sonst wäre die Prüfung auch von einem
# Übersetzer erfüllt, der die Zusage ignoriert.
if "$LYXC" --std-path=. "$Q" -o "$TMP/base" >/dev/null 2>&1 \
   && "$LYXC" --std-path=. --target-cpu=sse4 "$Q" -o "$TMP/s4" >/dev/null 2>&1; then
  q0=$(zaehl "$TMP/base" 660f3829c1); q1=$(zaehl "$TMP/s4" 660f3829c1)
  if [ "$q0" = "0" ] && [ "$q1" -ge 1 ]; then
    ok "pcmpeqq nur mit --target-cpu=sse4 (0 -> $q1)"
  else
    bad "pcmpeqq-Zusage (ohne=$q0 mit=$q1)"
  fi
  "$TMP/s4" > "$TMP/out_s4.txt" 2>&1
  if diff -q "$TMP/out_ska.txt" "$TMP/out_s4.txt" >/dev/null; then
    ok "sse4_fassung_wertgleich"
  else
    bad "sse4_fassung_wertgleich"; diff "$TMP/out_ska.txt" "$TMP/out_s4.txt" | head -5
  fi
else
  bad "sse4_uebersetzt"
fi

# ── 3. Gegenrichtung: Formen, die skalar bleiben MÜSSEN ─────────────────────
A=tests/vektor_suche_2360/ablehnung.lyx
if "$LYXC" --std-path=. "$A" -o "$TMP/abl" >"$TMP/b3.log" 2>&1; then
  ok "ablehnung_uebersetzt"
  if [ "$(zaehl "$TMP/abl" 660f74c1)" = "0" ]; then
    ok "abgelehnte_formen_ohne_pcmpeqb"
  else
    bad "abgelehnte_formen_ohne_pcmpeqb — eine davon wurde vorgespult"
  fi
  out=$("$TMP/abl" 2>&1)
  # Der Aufruf in der Bedingung muss für JEDES Element laufen: 81 Aufrufe bis
  # zum Treffer bei 80. Würde vorgespult, wären es weniger — das ist die
  # Wirkung, an der die Nebenwirkung messbar wird.
  if echo "$out" | grep -q "^aufrufe=81$"; then
    ok "aufrufe_in_der_bedingung_alle_ausgefuehrt (81)"
  else
    bad "aufrufe_in_der_bedingung"; echo "$out" | head -5
  fi
  if echo "$out" | grep -q "^mit_kleiner_als=80$" && echo "$out" | grep -q "^mit_drittem=180$"; then
    ok "abgelehnte_formen_rechnen_richtig"
  else
    bad "abgelehnte_formen_rechnen_richtig"; echo "$out" | head -5
  fi
else
  bad "ablehnung_uebersetzt"; tail -5 "$TMP/b3.log"
fi

# ── Der Vektorweg greift im SELBSTBAU, und zwar messbar ─────────────────────
# Ein Bericht, der nur Ablehnungen zählt, wäre auch von einem Vektorisierer
# erfüllt, der nie etwas anwendet.
if "$LYXC" --std-path=. --compile-profile="$TMP/p.json" --compile-profile-level=detailed \
     "$Q" -o "$TMP/pv" >/dev/null 2>&1; then
  n=$(python3 - "$TMP/p.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(r.get('count',0) for r in d.get('decision_summary',[]) if r['reason_code']=='VS_APPLIED_SKIP_SCAN'))
PY
)
  if [ "${n:-0}" -ge 4 ]; then ok "profil_meldet_${n}_anwendungen"; else bad "profil_meldet_anwendungen ($n)"; fi
else
  bad "profil_lauf"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
