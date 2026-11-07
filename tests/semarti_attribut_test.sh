#!/usr/bin/env bash
# #2419 Punkt 1 — Deskriptoren am Code: @operation und --emit-semarti.
#
# Die Kette, die hier nachgewiesen wird:
#   @operation am Code  ->  lyxc --emit-semarti  ->  erzeugte Lyx-Unit
#                       ->  mitübersetzt  ->  Registry  ->  geprüfter Aufruf
#
# Warum eine erzeugte UNIT und keine Sektion im Erzeugnis: `.meta_safe` geht
# den Sektionsweg, aber nur für ELF. LBF (--target=lyxos) hat ein eigenes
# TLV-Format, arm64, riscv, PE und Mach-O je ihr eigenes. Eine Lyx-Unit ist
# formatneutral und läuft auf jedem Ziel.
#
# Geprüft wird in drei Richtungen:
#   1. WIRKUNG — das Programm, das die erzeugte Unit nutzt, läuft und findet
#      genau die Angaben aus den Attributen wieder, bis zur
#      Bestätigungspflicht.
#   2. FORM — fünf kaputte Attributwerte werden abgewiesen, die gültige nicht.
#   3. GEGENRICHTUNG — ohne das Attribut entsteht keine Operation.
set -u
ulimit -c 0
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# ── 1. Die ganze Kette ──────────────────────────────────────────────────────
cp tests/semarti/attr/semarti_traeger.lyx tests/semarti/attr/haupt.lyx "$TMP/"
if "$LYXC" --std-path=. --emit-semarti="$TMP/semarti_erzeugt.lyx" \
     "$TMP/semarti_traeger.lyx" -o "$TMP/wegwerf" >"$TMP/g.log" 2>&1; then
  : # Eine Unit ohne main schlägt beim Übersetzen fehl; die Ausgabe steht
    # vorher. Beides ist in Ordnung, geprüft wird die Datei.
  :
fi
if [ -s "$TMP/semarti_erzeugt.lyx" ]; then
  ok "erzeugte_unit_entstand"
else
  bad "erzeugte_unit_entstand"; tail -3 "$TMP/g.log"
fi
# Die Angaben müssen aus den Attributen stammen, nicht aus einer Vorgabe.
for muster in "com.example.doc.read_title" "com.example.doc.export" "2, 1, 3" \
              "SRR_RISIKO_AUSSENWIRKUNG" "SRR_BESTAETIGUNG_NOETIG" "SRR_OBJEKT_NOETIG" \
              "import semarti_traeger"; do
  if grep -q "$muster" "$TMP/semarti_erzeugt.lyx"; then
    ok "erzeugt_enthaelt_${muster// /_}"
  else
    bad "erzeugt_enthaelt_${muster// /_}"
  fi
done

if "$LYXC" --std-path=. -I"$TMP" "$TMP/haupt.lyx" -o "$TMP/prog" >"$TMP/h.log" 2>&1; then
  ok "programm_mit_erzeugter_unit_uebersetzt"
  out=$("$TMP/prog" 2>&1); rc=$?
  n=$(echo "$out" | grep -c '^PASS ')
  if [ "$rc" = "0" ] && echo "$out" | grep -q '^ALL PASS$'; then
    ok "kette_alle_${n}_pruefungen"
  else
    bad "kette (rc=$rc, PASS=$n)"; echo "$out" | grep '^FAIL' | head -6
  fi
  for z in erste_version_1_0_0 zweite_version_2_1_3 bestaetigung_aus_dem_attribut_greift \
           aufruf_der_erzeugten_operation; do
    if echo "$out" | grep -q "^PASS $z\$"; then ok "kette_kern_$z"; else bad "kette_kern_$z"; fi
  done
else
  bad "programm_mit_erzeugter_unit_uebersetzt"; tail -5 "$TMP/h.log"
fi

# ── 2. Form der Attributwerte, beide Seiten ─────────────────────────────────
pruef_form() { # beschreibung argumente erwartet_fehler
  printf '@capabilities([fs.read])\nunit t;\n@operation(%s)\npub fn f(): int64 { return 0; }\n' "$2" > "$TMP/f.lyx"
  "$LYXC" --std-path=. --emit-semarti="$TMP/f_out.lyx" "$TMP/f.lyx" -o "$TMP/fx" >"$TMP/f.log" 2>&1
  if grep -q "Parse error" "$TMP/f.log"; then gefunden=1; else gefunden=0; fi
  if [ "$gefunden" = "$3" ]; then ok "form_$1"; else bad "form_$1 (Fehler=$gefunden, erwartet $3)"; fi
}
pruef_form "id_ohne_namensraum"   'id: "ohnepunkt", version: "1.0.0"' 1
pruef_form "version_zweiteilig"   'id: "a.b", version: "1.0"'         1
pruef_form "version_mit_buchstabe" 'id: "a.b", version: "1.0.x"'      1
pruef_form "id_doppelpunkt"       'id: "a..b", version: "1.0.0"'      1
pruef_form "id_grossbuchstabe"    'id: "A.b", version: "1.0.0"'       1
pruef_form "unbekannter_schluessel" 'id: "a.b", version: "1.0.0", confrm: true' 1
pruef_form "unbekanntes_risiko"   'id: "a.b", version: "1.0.0", risk: schlimm' 1
pruef_form "gueltig"              'id: "a.b", version: "1.0.0"'       0

# ── 3. Gegenrichtung: ohne Attribut keine Operation ─────────────────────────
printf '@capabilities([fs.read])\nunit t2;\npub fn f(): int64 { return 0; }\n' > "$TMP/leer.lyx"
"$LYXC" --std-path=. --emit-semarti="$TMP/leer_out.lyx" "$TMP/leer.lyx" -o "$TMP/lx" >/dev/null 2>&1
if [ -s "$TMP/leer_out.lyx" ] && grep -q "return 0;" "$TMP/leer_out.lyx" \
   && ! grep -q "RegistryHinzufuegen" "$TMP/leer_out.lyx"; then
  ok "ohne_attribut_keine_operation"
else
  bad "ohne_attribut_keine_operation"; cat "$TMP/leer_out.lyx" 2>/dev/null | head -12
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
