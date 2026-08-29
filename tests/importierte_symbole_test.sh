#!/usr/bin/env bash
# tests/importierte_symbole_test.sh — Knotenindex importierter Symbole (#1857).
#
# Ein importiertes Symbol trug einen Knotenindex, der nur im Baum SEINER Unit
# gilt. Nach der Rueckkehr zeigt `self.nodes` wieder auf das Wurzelmodul —
# derselbe Index bezeichnet dort einen anderen Knoten. Wer daraus ein Flag
# liest, liest ein fremdes.
#
# Im Kernel liess deshalb EINE zusaetzliche `con`-Deklaration in ring3.lyx die
# Uebersetzung an unbeteiligter Stelle scheitern:
#
#   sema error: assignment to let/co binding not allowed 'g_spawn_parent'
#
# `g_spawn_parent` ist eine `pub var` aus einer ANDEREN Unit, und die Zeile war
# unveraendert. Die eingefuegte Konstante hatte nur die Knotennummern
# verschoben, sodass der geerbte Index auf eine `let`-Deklaration fiel.
#
# Der Test stellt genau das nach: eine grosse fremde Unit (hoher Knotenindex
# fuer die exportierte Variable) und ein Hauptmodul voller `let`-Bindungen
# (damit der geerbte Index dort auf eine trifft). Ohne den Fix ist das rot.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ── Der Fall aus dem Issue ─────────────────────────────────────────────────
python3 - "$TMP" <<'PY'
import sys
tmp = sys.argv[1]
# Fremde Unit: viele Deklarationen VOR der exportierten Variablen, damit deren
# Knotenindex hoch liegt.
vorlauf = "\n".join("pub con F%03d: int64 := %d;" % (i, i) for i in range(300))
open(tmp + "/fremd.lyx", "w").write("unit fremd;\n%s\npub var g_zaehler: int64 := 0;\n" % vorlauf)
# Hauptmodul: viele let-Bindungen — auf eine davon faellt der geerbte Index.
lets = "\n".join("let L%03d: int64 := %d;" % (i, i) for i in range(400))
open(tmp + "/haupt.lyx", "w").write(
    "import fremd;\n%s\nfn main(): int64 {\n  g_zaehler := 7;\n  return g_zaehler;\n}\n" % lets)
PY

if (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" -I . haupt.lyx -o h >"$TMP/h.log" 2>&1); then
  "$TMP/h" >/dev/null 2>&1
  if [ $? -eq 7 ]; then ok "pub_var_aus_fremder_unit_bleibt_beschreibbar"
  else no "pub_var_aus_fremder_unit_bleibt_beschreibbar" "falscher Rueckgabewert"; fi
else
  no "pub_var_aus_fremder_unit_bleibt_beschreibbar" "$(grep -im1 'error' "$TMP/h.log")"
fi

# Die Meldung darf auch nicht mit anderer Zahl von Konstanten auftauchen: der
# Fehler haing an der VERSCHIEBUNG, also an genau dieser Stellschraube.
for n in 0 1 7 33; do
  python3 - "$TMP" "$n" <<'PY'
import sys
tmp, n = sys.argv[1], int(sys.argv[2])
cons = "\n".join("con K%03d: int64 := %d;" % (i, i) for i in range(n))
lets = "\n".join("let L%03d: int64 := %d;" % (i, i) for i in range(400))
open(tmp + "/haupt.lyx", "w").write(
    "import fremd;\n%s\n%s\nfn main(): int64 {\n  g_zaehler := 7;\n  return g_zaehler;\n}\n" % (cons, lets))
PY
  if (cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" -I . haupt.lyx -o h >"$TMP/h.log" 2>&1); then
    ok "unbeteiligte_konstanten_${n}_stoeren_nicht"
  else
    no "unbeteiligte_konstanten_${n}_stoeren_nicht" "$(grep -im1 'error' "$TMP/h.log")"
  fi
done

# ── Gegenprobe: die Pruefung greift weiterhin, wo sie soll ─────────────────
# Sonst waere der Fix nur ein Abschalten.
printf 'let FEST: int64 := 5;\nfn main(): int64 { FEST := 6; return FEST; }\n' > "$TMP/l1.lyx"
if timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/l1.lyx" -o "$TMP/l1" >"$TMP/l1.log" 2>&1; then
  no "eigene_let_bindung_wird_gemeldet" "uebersetzte klaglos"
else
  grep -qi "let/co binding" "$TMP/l1.log" \
    && ok "eigene_let_bindung_wird_gemeldet" \
    || no "eigene_let_bindung_wird_gemeldet" "andere Meldung"
fi

printf 'con K: int64 := 5;\nfn main(): int64 { K := 6; return K; }\n' > "$TMP/l2.lyx"
if timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/l2.lyx" -o "$TMP/l2" >"$TMP/l2.log" 2>&1; then
  no "eigene_con_wird_gemeldet" "uebersetzte klaglos"
else
  ok "eigene_con_wird_gemeldet"
fi

# ── #1858: ueber Unit-Grenzen muss die Regel WIRKEN ───────────────────────
#
# Die Gegenrichtung zu oben. Bis 1.1.13D stand die Auskunft "einmal bindend"
# nur im Deklarationsknoten — den es fuer ein importiertes Symbol im aktuellen
# Baum nicht gibt. Die Zuweisung an eine importierte `let`-Bindung ging
# deshalb durch; gemessen auch mit dem Compiler VOR #1857, die Regel hat ueber
# Unit-Grenzen also nie gewirkt. Seit #1858 wird sie am SYMBOL gefuehrt.
printf 'unit fremd_fest;\npub let FREMD_FEST: int64 := 5;\npub con FREMD_KON: int64 := 9;\n' > "$TMP/fremd_fest.lyx"

printf 'import fremd_fest;\nfn main(): int64 { FREMD_FEST := 6; return FREMD_FEST; }\n' > "$TMP/i1.lyx"
if (cd "$TMP" && timeout 120 "$LYXC" --std-path="$ROOT" -I . i1.lyx -o i1 >"$TMP/i1.log" 2>&1); then
  no "importierte_let_bindung_wird_gemeldet" "uebersetzte klaglos"
else
  grep -qi "let/co binding" "$TMP/i1.log" \
    && ok "importierte_let_bindung_wird_gemeldet" \
    || no "importierte_let_bindung_wird_gemeldet" "andere Meldung: $(grep -im1 error "$TMP/i1.log")"
fi

printf 'import fremd_fest;\nfn main(): int64 { FREMD_KON := 6; return FREMD_KON; }\n' > "$TMP/i2.lyx"
if (cd "$TMP" && timeout 120 "$LYXC" --std-path="$ROOT" -I . i2.lyx -o i2 >"$TMP/i2.log" 2>&1); then
  no "importierte_con_wird_gemeldet" "uebersetzte klaglos"
else
  ok "importierte_con_wird_gemeldet"
fi

# Und LESEN muss weiterhin gehen — sonst waere die Sperre zu weit.
printf 'import fremd_fest;\nfn main(): int64 { return FREMD_FEST + FREMD_KON; }\n' > "$TMP/i3.lyx"
if (cd "$TMP" && timeout 120 "$LYXC" --std-path="$ROOT" -I . i3.lyx -o i3 >"$TMP/i3.log" 2>&1); then
  "$TMP/i3" >/dev/null 2>&1
  [ $? -eq 14 ] && ok "importierte_bindungen_bleiben_lesbar" \
                || no "importierte_bindungen_bleiben_lesbar" "falscher Rueckgabewert"
else
  no "importierte_bindungen_bleiben_lesbar" "$(grep -im1 error "$TMP/i3.log")"
fi

echo "== importierte_symbole_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
