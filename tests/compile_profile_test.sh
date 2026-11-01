#!/usr/bin/env bash
# tests/compile_profile_test.sh — das Compilatprofil (--compile-profile, #2343).
#
# Geprueft wird der DATENVERTRAG und das Verhalten an den Raendern, nicht die
# Hoehe einzelner Zahlen. Eine Zeitschwelle im Test ist auf einer geteilten
# Maschine ein Wuerfel.
#
# Die wichtigste Pruefung ist 5: das Compilat muss mit und ohne Schalter
# BITGLEICH sein, in allen drei Stufen. Dass eine JSON-Datei entsteht, ist
# dagegen ein Vorhandenseinstest und sagt nichts — genau diese Sorte Pruefung
# hat in diesem Repo mehrfach einen echten Defekt verdeckt.
#
# Pruefung 7 misst, dass ein fehlender Messwert als Objekt mit "value": null
# und einem Grund erscheint. Eine 0 an dieser Stelle waere die gefaehrlichste
# Form des Fehlers: sie liest sich wie eine Messung.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/gut.lyx" <<'EOF'
import src.std.io;
fn main(): int64 {
  PrintStrLn("profil");
  return 0;
}
EOF

# Ein Programm, das sema laut abweist — fuer den Teilbericht.
cat > "$TMP/kaputt.lyx" <<'EOF'
fn main(): int64 {
  return GibtEsNicht();
}
EOF

baue() { # $1.. = Zusatzargumente; Quelle und Ziel stehen fest
  ( cd "$TMP" && "$LYXC" --std-path="$ROOT" gut.lyx -o app "$@" ) >"$TMP/out.log" 2>"$TMP/err.log"
}

# 1. Ohne Schalter entsteht keine Profildatei.
rm -f "$TMP"/*.json
if baue && [ -z "$(ls "$TMP"/*.json 2>/dev/null)" ]; then
  ok "1 ohne Schalter kein Profil"
else
  no "1 ohne Schalter kein Profil" "$(ls "$TMP"/*.json 2>/dev/null) rc=$?"
fi

# 2. Automatischer Pfad: <ausgabe>.lyxc-profile.json, nicht <basis>.json.
rm -f "$TMP"/*.json
if baue --compile-profile && [ -s "$TMP/app.lyxc-profile.json" ]; then
  ok "2 automatischer Pfad app.lyxc-profile.json"
else
  no "2 automatischer Pfad" "nicht entstanden: $(ls "$TMP" | tr '\n' ' ')"
fi

# 3. Expliziter Pfad, und der Bericht ist parsebares JSON mit Schemaversion.
rm -f "$TMP"/*.json
if baue --compile-profile="$TMP/eigen.json" \
   && python3 -I -c "
import json,sys
d=json.load(open('$TMP/eigen.json'))
assert d['schema_version']=='1.0', d['schema_version']
assert d['status']['result']=='success', d['status']
assert d['status']['exit_code']==0
assert isinstance(d['spans'],list) and len(d['spans'])>0
assert d['decisions']==[] and d['decision_summary']==[]
" 2>"$TMP/p3.log"; then
  ok "3 expliziter Pfad, Schema 1.0, Status success"
else
  no "3 expliziter Pfad" "$(tail -2 "$TMP/p3.log" | tr '\n' ' ')"
fi

# 4. Ungueltige Kombinationen sind CLI-Fehler VOR dem Bau: Exit 2, kein
#    Erzeugnis, kein Bericht. Der letzte Fall traf vorher erst nach dem Bauen
#    und meldete den Lauf trotzdem als Erfolg.
cli_fehler() { # $1 = Beschreibung, Rest = Argumente
  local was="$1"; shift
  rm -f "$TMP/app" "$TMP"/*.json
  ( cd "$TMP" && "$LYXC" --std-path="$ROOT" gut.lyx -o app "$@" ) >/dev/null 2>"$TMP/e.log"
  local rc=$?
  if [ "$rc" -ne 2 ]; then
    no "4 $was" "rc=$rc erwartet 2"
  elif [ -e "$TMP/app" ]; then
    no "4 $was" "hat trotzdem uebersetzt"
  elif [ -n "$(ls "$TMP"/*.json 2>/dev/null)" ]; then
    no "4 $was" "hat trotzdem einen Bericht geschrieben"
  else
    ok "4 $was"
  fi
}
cli_fehler "Level ohne --compile-profile"   --compile-profile-level=analysis
cli_fehler "Filter ohne --compile-profile"  --compile-profile-function=main
cli_fehler "Filter in basic"                --compile-profile --compile-profile-function=main
cli_fehler "unbekanntes Level"              --compile-profile --compile-profile-level=bogus
cli_fehler "unbekannte Pass-Kennung"        --compile-profile --compile-profile-level=detailed --compile-profile-pass=gibtsnicht
cli_fehler "Profil auf die Quelldatei"      --compile-profile=gut.lyx
cli_fehler "Profil auf die Ausgabedatei"    --compile-profile=app

# 5. Bitgleichheit des Compilats. Der Kern: das Profil darf das Erzeugnis
#    nicht anfassen, auch nicht ueber eine Zufallskennung oder einen
#    Zeitstempel im Compilat.
rm -f "$TMP"/*.json "$TMP/app"
baue
ohne=$(sha256sum "$TMP/app" | cut -d' ' -f1)
gleich=1
for lvl in basic analysis detailed; do
  # Nur das Erzeugnis weg -- die Berichte dieser Schleife werden in den
  # Pruefungen 7 bis 9 weiterverwendet.
  rm -f "$TMP/app"
  baue --compile-profile="$TMP/b_$lvl.json" --compile-profile-level="$lvl"
  mit=$(sha256sum "$TMP/app" | cut -d' ' -f1)
  if [ "$mit" != "$ohne" ]; then
    no "5 Bitgleichheit ($lvl)" "$mit != $ohne"
    gleich=0
  fi
done
[ "$gleich" -eq 1 ] && ok "5 Compilat bitgleich mit und ohne Profil (alle drei Stufen, SHA-256 $ohne)"

# 6. Regulaerer Compilerfehler: Teilbericht mit eigenem Status, und der
#    Compiler-Exitcode bleibt der des Fehlers.
#
# Hier wird NICHT pauschal "$TMP"/*.json geloescht: die Berichte aus Pruefung 5
# sind die Eingabe von 7 bis 9. Ein Aufraeumen, das die Belege des naechsten
# Schrittes mitnimmt, hat diesen Test schon zweimal rot gemacht.
( cd "$TMP" && "$LYXC" --std-path="$ROOT" kaputt.lyx -o kaputt --compile-profile="$TMP/f.json" ) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  no "6 Teilbericht bei Compilerfehler" "rc=0 — die Quelle sollte abgewiesen werden"
elif python3 -I -c "
import json
d=json.load(open('$TMP/f.json'))
assert d['status']['result']=='compile_error', d['status']
assert d['status']['completion']=='partial', d['status']
assert d['status']['exit_code']==$rc, (d['status']['exit_code'], $rc)
assert d['summary']['output_bytes']['value'] is None, d['summary']['output_bytes']
" 2>"$TMP/p6.log"; then
  ok "6 Teilbericht bei Compilerfehler, Exitcode $rc erhalten"
else
  no "6 Teilbericht bei Compilerfehler" "$(tail -2 "$TMP/p6.log" | tr '\n' ' ')"
fi

# 7. Fehlende Messfaehigkeiten stehen als Objekt mit Grund da — nicht als 0
#    und nicht als fehlendes Feld.
if python3 -I -c "
import json
d=json.load(open('$TMP/b_analysis.json'))
s=d['summary']
for k in ('phase_rss_bytes','child_cpu_ns'):
    assert s[k]['value'] is None, (k, s[k])
    assert s[k]['unavailable'], (k, s[k])
# Vorhandene Messungen tragen ihre Herkunft.
for k in ('compile_wall_ns','process_cpu_ns'):
    assert s[k]['origin']=='measured', (k, s[k])
assert s['process_cpu_ns']['scope']=='process'
assert s['peak_rss_bytes']['scope']=='process'
# Keine Summe der Spannzeiten im Bericht: sie waere keine Walltime.
assert 'spans_total_ns' not in d['summary']
" 2>"$TMP/p7.log"; then
  ok "7 fehlende Faehigkeiten mit Grund, Messungen mit Herkunft und Geltungsbereich"
else
  no "7 fehlende Faehigkeiten" "$(tail -2 "$TMP/p7.log" | tr '\n' ' ')"
fi

# 8. coverage trennt die vier Zustaende und nennt die nicht gemeldeten Paesse.
#    inline ist not_run (vorhanden, nicht verdrahtet), nicht absent.
if python3 -I -c "
import json
d=json.load(open('$TMP/b_analysis.json'))
p={x['pass_id']: x for x in d['coverage']['passes']}
assert p['sema']['timing']=='measured', p['sema']
assert p['inline']['timing']=='not_run', p['inline']
assert p['vectorize']['decisions']=='not_instrumented', p['vectorize']
assert p['ir-optimize']['decisions']=='not_instrumented', p['ir-optimize']
assert 'DECISION_EVENTS' in d['coverage']['missing_capabilities']
assert d['coverage']['level']=='analysis'
" 2>"$TMP/p8.log"; then
  ok "8 coverage trennt measured/not_instrumented/not_run und nennt die Luecken"
else
  no "8 coverage" "$(tail -2 "$TMP/p8.log" | tr '\n' ' ')"
fi

# 9. analysis traegt Phasenkennzahlen, basic nicht. Die feinen Zaehler kosten
#    im Rumpf der Phasen etwas und bleiben in basic aus; coverage sagt das
#    ueber die Stufe.
if python3 -I -c "
import json
a=json.load(open('$TMP/b_analysis.json'))
b=json.load(open('$TMP/b_basic.json'))
na=sum(len(s['metrics']) for s in a['spans'])
nb=sum(len(s['metrics']) for s in b['spans'])
assert na > 0, 'analysis ohne Kennzahlen'
assert nb == 0, ('basic traegt Kennzahlen', nb)
# Jede Kennzahl ist ein Messobjekt, keine nackte Zahl.
for s in a['spans']:
    for k, v in s['metrics'].items():
        assert v['origin']=='measured', (k, v)
# Phasenzeiten stehen schon in basic — sie sind der Zweck der Stufe.
assert all(s['duration_ns']['value'] >= 0 for s in b['spans'])
assert len(b['spans']) > 0
" 2>"$TMP/p9.log"; then
  ok "9 analysis mit Kennzahlen, basic nur mit Phasenzeiten"
else
  no "9 Stufen" "$(tail -2 "$TMP/p9.log" | tr '\n' ' ')"
fi

# 10. Nicht beschreibbares Ziel: Warnung, aber der Build bleibt erfolgreich
#     und der Exitcode wird nicht umgedeutet.
rm -f "$TMP/app"
mkdir -p "$TMP/dicht" && chmod 500 "$TMP/dicht"
( cd "$TMP" && "$LYXC" --std-path="$ROOT" gut.lyx -o app --compile-profile="$TMP/dicht/p.json" ) >/dev/null 2>"$TMP/w.log"
rc=$?
chmod 700 "$TMP/dicht"
if [ "$rc" -ne 0 ]; then
  no "10 nicht beschreibbares Ziel" "rc=$rc — der Build war erfolgreich, der Exitcode darf nicht kippen"
elif ! grep -q 'warning: --compile-profile' "$TMP/w.log"; then
  no "10 nicht beschreibbares Ziel" "keine Warnung: $(tail -1 "$TMP/w.log")"
elif [ ! -x "$TMP/app" ]; then
  no "10 nicht beschreibbares Ziel" "Erzeugnis fehlt"
elif [ -n "$(ls "$TMP/dicht" 2>/dev/null)" ]; then
  no "10 nicht beschreibbares Ziel" "halbe Datei zurueckgelassen: $(ls "$TMP/dicht")"
else
  ok "10 nicht beschreibbares Ziel: Warnung, Exitcode 0, keine halbe Datei"
fi

# 11. Ein vorhandener Bericht wird ersetzt, nicht angehaengt, und ein
#     Schreibfehler laesst keinen halben zurueck. Geprueft am Austausch:
#     nach zwei Laeufen steht genau ein JSON-Dokument in der Datei.
rm -f "$TMP"/*.json
baue --compile-profile="$TMP/zwei.json"
erste=$(python3 -I -c "import json;print(json.load(open('$TMP/zwei.json'))['invocation_id'])")
baue --compile-profile="$TMP/zwei.json"
zweite=$(python3 -I -c "import json;print(json.load(open('$TMP/zwei.json'))['invocation_id'])")
if [ -z "$erste" ] || [ -z "$zweite" ]; then
  no "11 Austausch" "Bericht nicht lesbar"
elif [ "$erste" = "$zweite" ]; then
  no "11 Austausch" "Laufkennung unveraendert — wurde der Bericht ueberhaupt ersetzt?"
elif [ -n "$(ls "$TMP"/*.tmp.* 2>/dev/null)" ]; then
  no "11 Austausch" "Nachbardatei liegen geblieben: $(ls "$TMP"/*.tmp.*)"
else
  ok "11 Bericht wird vollstaendig ersetzt, keine Nachbardatei zurueck"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
