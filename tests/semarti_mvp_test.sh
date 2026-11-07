#!/usr/bin/env bash
# SemaRTI (Semantic Runtime Introspection) — MVP.
#
# Drei Nachweise, und keiner davon ist durch einen der anderen ersetzbar:
#
#   1. ABLAUF — das vertikale Slice prüft die Reihenfolge aus der
#      Spezifikation (ID, Version, Schema, Autorisierung, Policy,
#      Bestätigung, Handler, Ausgabe, Audit). Entscheidend ist, dass es die
#      WIRKUNG misst: der Handler zählt seine Aufrufe, und jede Ablehnung
#      muss diesen Zähler unverändert lassen. Ein Test, der nur Fehlercodes
#      vergleicht, wäre auch von einer Umsetzung erfüllt, die den Handler
#      ausführt und danach einen Fehler zurückgibt.
#
#   2. DURCHSETZUNG — die Capability-Bindung ist kein Papier. Ein Programm
#      mit `@capabilities([fs.read])`, dessen Code schreiben will, wird vom
#      seccomp-Filter getötet (SIGSYS, rc 159), und die Datei entsteht nicht.
#      Beide Seiten werden gemessen: der erlaubte Fall muss durchlaufen.
#
#   3. COMPILER-SEITE — ein Tippfehler in `@capabilities` wird beim
#      Übersetzen gemeldet. Erst zusammen mit Nachweis 1 ist die Kette
#      dicht: SemaRTI lässt nur deklarierte Rechte zu, der Übersetzer lässt
#      nur existierende Namen zu, der Kernel setzt durch.
set -u
# Der verbotene Fall stirbt mit Absicht an SIGSYS. Ohne diese Zeile schreibt
# jeder Lauf einen Speicherabzug — in diesem Baum sind dadurch schon
# qemu_*.core-Dateien im Arbeitsbaum gelandet.
ulimit -c 0
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# ── 1. Ablauf ───────────────────────────────────────────────────────────────
if "$LYXC" --std-path=. tests/semarti/slice.lyx -o "$TMP/slice" >"$TMP/b1.log" 2>&1; then
  ok "slice_uebersetzt"
  out=$("$TMP/slice" 2>&1); rc=$?
  n=$(echo "$out" | grep -c '^PASS ')
  if [ "$rc" = "0" ] && echo "$out" | grep -q '^ALL PASS$'; then
    ok "slice_alle_${n}_pruefungen"
  else
    bad "slice (rc=$rc, PASS=$n)"; echo "$out" | grep '^FAIL' | head -8
  fi
  # Die zentrale Zeile einzeln bestätigen: sie ist der Kern des MVP.
  if echo "$out" | grep -q '^PASS keine_ablehnung_erreichte_den_handler$'; then
    ok "wirkungsnachweis_ablehnung_erreicht_handler_nicht"
  else
    bad "wirkungsnachweis_ablehnung_erreicht_handler_nicht"
  fi
else
  bad "slice_uebersetzt"; tail -5 "$TMP/b1.log"
fi

# ── 1b. Objektmodell ────────────────────────────────────────────────────────
# Drei Fehlerklassen, jede mit eigenem Nachweis: ein veraltetes Handle trifft
# nicht den Nachmieter seines Platzes, ein Objekt verschwindet nicht während
# eines Zugriffs, und dieselbe Operation mit demselben Recht ist auf einem
# Objekt erlaubt und auf einem anderen verboten.
if "$LYXC" --std-path=. tests/semarti/objekte.lyx -o "$TMP/objekte" >"$TMP/b1b.log" 2>&1; then
  ok "objekte_uebersetzt"
  out=$("$TMP/objekte" 2>&1); rc=$?
  n=$(echo "$out" | grep -c '^PASS ')
  if [ "$rc" = "0" ] && echo "$out" | grep -q '^ALL PASS$'; then
    ok "objekte_alle_${n}_pruefungen"
  else
    bad "objekte (rc=$rc, PASS=$n)"; echo "$out" | grep '^FAIL' | head -8
  fi
  for z in altes_handle_trifft_nachmieter_nicht verleiht_nicht_freigebbar fremdes_dokument_verboten veraltetes_handle_eigener_befund; do
    if echo "$out" | grep -q "^PASS $z\$"; then ok "objekte_kern_$z"; else bad "objekte_kern_$z"; fi
  done
else
  bad "objekte_uebersetzt"; tail -5 "$TMP/b1b.log"
fi

# ── 2. Durchsetzung am Kernel ───────────────────────────────────────────────
ZIEL=/tmp/semarti_darf_nicht_$$.txt
rm -f "$ZIEL"
if "$LYXC" --std-path=. tests/semarti/durchsetzung.lyx -o "$TMP/durch" >"$TMP/b2.log" 2>&1; then
  ok "durchsetzung_uebersetzt"
  # Erlaubter Fall: muss durchlaufen. Ohne diese Seite wäre der Test auch von
  # einem Programm erfüllt, das IMMER stirbt.
  if o=$("$TMP/durch" 0 2>&1) && echo "$o" | grep -q "LESEN_ERLAUBT"; then
    ok "erlaubter_fall_laeuft"
  else
    bad "erlaubter_fall_laeuft"; echo "$o" | head -3
  fi
  # Verbotener Fall: SIGSYS. rc 159 = 128 + 31.
  "$TMP/durch" 1 >"$TMP/v.log" 2>&1; vrc=$?
  if [ "$vrc" = "159" ]; then
    ok "verbotener_fall_stirbt_an_sigsys (rc=159)"
  else
    bad "verbotener_fall_stirbt_an_sigsys (rc=$vrc)"; tail -3 "$TMP/v.log"
  fi
  if grep -q "SCHREIBEN_LIEF_DURCH" "$TMP/v.log"; then
    bad "schreiben_lief_durch — die Haertung greift nicht"
  else
    ok "kein_durchlauf_nach_dem_verbot"
  fi
else
  bad "durchsetzung_uebersetzt"; tail -5 "$TMP/b2.log"
fi
# Die Wirkung, nicht nur das Signal: es darf keine Datei entstanden sein.
if [ -e "$ZIEL" ] || [ -e /tmp/semarti_darf_nicht.txt ]; then
  bad "verbotene_datei_entstanden"; rm -f "$ZIEL" /tmp/semarti_darf_nicht.txt
else
  ok "verbotene_datei_entstand_nicht"
fi

# ── 3. Compiler weist unbekannte Capability ab ──────────────────────────────
# Zweiseitig: der Tippfehler scheitert, der richtige Name übersetzt.
printf '@capabilities([fs.reed])\nunit main;\nimport std.io;\nfn main(): int64 { PrintStrLn("x"c); return 0; }\n' > "$TMP/tipp.lyx"
if "$LYXC" --std-path=. "$TMP/tipp.lyx" -o "$TMP/tipp" >"$TMP/t.log" 2>&1; then
  bad "tippfehler_in_capability_wurde_angenommen"
else
  if grep -qi "unbekannte Capability" "$TMP/t.log"; then
    ok "tippfehler_in_capability_wird_gemeldet"
  else
    bad "tippfehler_abgewiesen, aber mit anderem Grund"; tail -3 "$TMP/t.log"
  fi
fi
printf '@capabilities([fs.read])\nunit main;\nimport std.io;\nfn main(): int64 { PrintStrLn("x"c); return 0; }\n' > "$TMP/gut.lyx"
if "$LYXC" --std-path=. "$TMP/gut.lyx" -o "$TMP/gut" >"$TMP/g.log" 2>&1; then
  ok "richtiger_capability_name_uebersetzt (Gegenrichtung)"
else
  bad "richtiger_capability_name_uebersetzt"; tail -3 "$TMP/g.log"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
