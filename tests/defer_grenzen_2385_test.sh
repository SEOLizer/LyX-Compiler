#!/usr/bin/env bash
# tests/defer_grenzen_2385_test.sh — die beiden Puffer des defer-Pfades
# WACHSEN, und ihre Obergrenze scheitert LAUT (#2385).
#
# Vorher verwarfen beide stillschweigend:
#
#   cg_genStmt, Zweig CGN_DEFER:  if (deferCount < deferCap) { ... }
#       Puffer voll -> der Eintrag wird NICHT angemeldet und laeuft NIE.
#       Gemessen: eine Funktion mit 70 defer uebersetzte ohne jede Meldung,
#       ausgefuehrt wurden 64.
#
#   cg_captureDeferArgs:         if (dfCount >= dfCap) { return; }
#       Grenze erreicht -> kein gesicherter Slot, cg_deferArgIdx liefert -1,
#       und das Argument wird beim ABLAUF ausgewertet statt bei der
#       Anmeldung. Das ist genau der Zustand, den #1030 beseitigt hat.
#
# Beides ist ein stiller Default: aus einem Engpass wird ein anderes
# Programm (nicht freigegebener Speicher, offene Dateien, doppelte Freigabe).
#
# GEPRUEFT WIRD DIE WIRKUNG, nicht die Uebersetzbarkeit: die Zahl der
# tatsaechlich gelaufenen defers, und der tatsaechlich benutzte Argumentwert.
#
# Die Obergrenzen (CG_DEFER_MAX 4096, CG_DFARG_MAX 16384) sind nicht dazu da,
# legitimen Code abzuweisen, sondern damit erzeugter Code nicht unbegrenzt
# belegt. Der Fall darunter ist hier nicht geprueft — 4096 defer in einer
# Funktion zu erzeugen kostet mehr Uebersetzungszeit als der Test wert ist.
# Geprueft ist, DASS die Grenze als Konstante existiert und der Zweig sie
# laut meldet; das ist am Quelltext belegt, nicht am Verhalten, und genau so
# ist es hier unten vermerkt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ── 1) Mehr defers als der Anfangspuffer fasst: alle muessen laufen ─────────
# 70 > deferCap(64) beim Start. Der Puffer muss wachsen.
{
  echo 'unit main;'
  echo 'import std.io;'
  echo 'fn z(i: int64) { PrintInt(i); PrintStr(" "c); }'
  echo 'fn viele(): int64 {'
  for i in $(seq 1 70); do echo "  defer z($i);"; done
  echo '  return 0;'
  echo '}'
  echo 'fn main(): int64 { viele(); PrintStrLn(""c); return 0; }'
} > "$TMP/v70.lyx"

if ( ulimit -c 0; cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/v70.lyx" -o "$TMP/v70" >"$TMP/v70.log" 2>&1 ); then
  n=$( ulimit -c 0; cd "$TMP" && timeout 60 ./v70 2>/dev/null | tr ' ' '\n' | grep -cE '^[0-9]+$' )
  if [ "$n" = "70" ]; then ok "siebzig_defer_laufen_alle ($n)"
  else no "siebzig_defer_laufen_alle" "$n von 70 gelaufen — Eintraege wurden verworfen"; fi
else
  no "siebzig_defer_laufen_alle" "uebersetzte nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/v70.log")"
fi

# ── 2) Mehr Argumente als der Anfangspuffer fasst: Zeitpunkt muss stimmen ───
# 60 defer mit je fuenf Argumenten = 300 > dfCap(256) beim Start. Jede
# Variable wird nach der Anmeldung auf 999 gesetzt; erscheint eine 999, wurde
# das Argument beim Ablauf ausgewertet.
{
  echo 'unit main;'
  echo 'import std.io;'
  echo 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64) { PrintInt(a); PrintStr(" "c); }'
  echo 'fn args(): int64 {'
  for i in $(seq 1 60); do echo "  var v$i: int64 := $i;"; echo "  defer f(v$i, 0, 0, 0, 0);"; done
  for i in $(seq 1 60); do echo "  v$i := 999;"; done
  echo '  return 0;'
  echo '}'
  echo 'fn main(): int64 { args(); PrintStrLn(""c); return 0; }'
} > "$TMP/a300.lyx"

if ( ulimit -c 0; cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/a300.lyx" -o "$TMP/a300" >"$TMP/a300.log" 2>&1 ); then
  aus=$( ulimit -c 0; cd "$TMP" && timeout 60 ./a300 2>/dev/null | tr ' ' '\n' )
  spaet=$( echo "$aus" | grep -c '^999$' )
  anz=$( echo "$aus" | grep -cE '^[0-9]+$' )
  if [ "$spaet" = "0" ] && [ "$anz" = "60" ]; then ok "dreihundert_argumente_gesichert ($anz Aufrufe, keine Spaetauswertung)"
  else no "dreihundert_argumente_gesichert" "$spaet von $anz Argumenten erst beim Ablauf ausgewertet"; fi
else
  no "dreihundert_argumente_gesichert" "uebersetzte nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/a300.log")"
fi

# ── 3) Die Obergrenzen sind vorhanden und melden laut ──────────────────────
# Am QUELLTEXT geprueft, mit Begruendung im Kopf dieses Tests. Ein
# Verhaltenstest waere hier teurer als aussagekraeftig; wichtig ist, dass der
# Zweig nicht wieder stillschweigend verwirft.
CG="$ROOT/src/codegen_x86.lyx"
for k in CG_DEFER_MAX CG_DFARG_MAX; do
  if grep -qE "^con $k:" "$CG"; then ok "grenze_${k}_definiert"
  else no "grenze_${k}_definiert" "Konstante fehlt"; fi
done
for fn in cg_deferPufferWachsen cg_dfPufferWachsen; do
  if grep -qE "fn $fn\(\)" "$CG"; then ok "wachstum_$fn"
  else no "wachstum_$fn" "Funktion fehlt"; fi
done
# Beide Wachstumsfunktionen muessen beim Erreichen der Grenze melden UND
# abbrechen — ein `return` ohne Meldung waere der alte stille Default.
for fn in cg_deferPufferWachsen cg_dfPufferWachsen; do
  blk=$( awk "/fn $fn\(\)/,/^  }/" "$CG" )
  if echo "$blk" | grep -q "EPrintStr" && echo "$blk" | grep -q "exit("; then
    ok "laut_$fn"
  else
    no "laut_$fn" "meldet nicht oder bricht nicht ab"
  fi
done
# Gegenprobe: die alten stillen Zweige duerfen nicht mehr dastehen.
if grep -q "if (self.dfCount >= self.dfCap) { return; }" "$CG"; then
  no "kein_stilles_return" "cg_captureDeferArgs verwirft noch stillschweigend"
else
  ok "kein_stilles_return"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
