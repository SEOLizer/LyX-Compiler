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

# ---------------------------------------------------------------------------
# Schritt 2 (#2343): Entscheidungen des Autovektorisierers.
# ---------------------------------------------------------------------------

# Eine Quelle mit genau einer vektorisierbaren Schleife (wird ANGEWANDT) und
# einer, die abgelehnt wird. Dazu ein Import, damit Entscheidungen aus einer
# FREMDEN Unit im Bericht stehen -- an denen haengt Pruefung 14.
cat > "$TMP/vek.lyx" <<'EOF'
import src.std.io;
fn summe(n: int64): int64 {
  var a: int64 := alloc(n * 4);
  var b: int64 := alloc(n * 4);
  var c: int64 := alloc(n * 4);
  var i: int64 := 0;
  while (i < n) { poke32(c + i * 4, peek32(a + i * 4) + peek32(b + i * 4)); i := i + 1; }
  var s: int64 := 0;
  i := 0;
  while (i < n) { s := s + 1; i := i + 1; }
  return s;
}
fn main(): int64 {
  PrintStrLn("vek");
  return summe(64) & 0;
}
EOF
baueVek() { ( cd "$TMP" && "$LYXC" --std-path="$ROOT" vek.lyx -o vapp "$@" ) >"$TMP/vout.log" 2>"$TMP/verr.log"; }

# 12. BEIDE Seiten. Ein Bericht, der nur Ablehnungen fuehrt, waere auch von
#     einem Vektorisierer erfuellt, der nie etwas anwendet; einer, der nur
#     Erfolge fuehrt, verschweigt die Gruende. Zusaetzlich: die Summe der
#     Zaehler in decision_summary muss decisions_recorded treffen -- sonst
#     zaehlt die Zusammenfassung etwas anderes als die Liste.
rm -f "$TMP"/v_*.json "$TMP/vapp"
baueVek --compile-profile="$TMP/v_det.json" --compile-profile-level=detailed
if python3 -I -c "
import json,sys
d=json.load(open('$TMP/v_det.json'))
dec=d['decisions']; sm=d['decision_summary']
erg=set(x['outcome'] for x in dec)
assert 'applied' in erg, 'keine angewandte Entscheidung: %r' % (erg,)
assert 'rejected' in erg, 'keine abgelehnte Entscheidung: %r' % (erg,)
assert all(x['pass_id']=='vectorize' for x in dec), 'fremder pass_id in decisions'
assert all(x['reason_code'] for x in dec), 'Entscheidung ohne reason_code'
su=sum(x['count'] for x in sm)
rec=d['collection']['decisions_recorded']
assert su==rec, 'Summe der Zaehler %d != decisions_recorded %d' % (su,rec)
assert len(set((x['reason_code'],x['outcome']) for x in sm))==len(sm), 'Grund doppelt in decision_summary'
" 2>"$TMP/p12.log"; then
  ok "12 detailed fuehrt angewandte UND abgelehnte Entscheidungen, Zaehler treffen die Liste"
else
  no "12 beide Seiten" "$(tail -2 "$TMP/p12.log" | tr '\n' ' ')"
fi

# 13. Die leere Liste darf nicht als "geprueft und nichts gefunden" lesbar
#     sein: ausserhalb von detailed sagt coverage DECISION_EVENTS, und der
#     Pass meldet dort not_instrumented statt per_event.
rm -f "$TMP"/v_*.json "$TMP/vapp"
baueVek --compile-profile="$TMP/v_bas.json" --compile-profile-level=basic
baueVek --compile-profile="$TMP/v_det.json" --compile-profile-level=detailed
if python3 -I -c "
import json
b=json.load(open('$TMP/v_bas.json')); t=json.load(open('$TMP/v_det.json'))
mb=b['coverage']['missing_capabilities']; mt=t['coverage']['missing_capabilities']
assert b['decisions']==[] and b['decision_summary']==[], 'basic fuehrt Entscheidungen'
assert 'DECISION_EVENTS' in mb, 'basic: leere Liste ohne DECISION_EVENTS'
assert 'DECISION_EVENTS' not in mt, 'detailed nennt DECISION_EVENTS trotz Erfassung'
pb=[p for p in b['coverage']['passes'] if p['pass_id']=='vectorize'][0]
pt=[p for p in t['coverage']['passes'] if p['pass_id']=='vectorize'][0]
assert pb['decisions']=='not_instrumented', pb
assert pt['decisions']=='per_event', pt
" 2>"$TMP/p13.log"; then
  ok "13 ohne detailed keine Entscheidungen, und coverage sagt es (DECISION_EVENTS)"
else
  no "13 leere Liste belegt" "$(tail -2 "$TMP/p13.log" | tr '\n' ' ')"
fi

# 14. Die Stelle muss zur Datei des Eintrags gehoeren. Bis zur Messung trug
#     JEDE Entscheidung den Pfad der Hauptdatei -- auch die aus src/std/*,
#     mit einer Zeilennummer, die es in der Hauptdatei nicht gibt. Geprueft
#     wird deshalb gegen die ZEILENZAHL der genannten Datei, nicht gegen das
#     Vorhandensein eines Pfades.
if python3 -I -c "
import json,os
d=json.load(open('$TMP/v_det.json'))
root='$TMP'; haupt=os.path.realpath('$TMP/vek.lyx')
mit=[x for x in d['decisions'] if 'file' in (x.get('location') or {})]
assert mit, 'keine Entscheidung mit Stelle'
fremd=0
for x in mit:
    f=x['location']['file']; ln=x['location']['line']
    pf=f if os.path.isabs(f) else os.path.join(root,f)
    assert os.path.exists(pf), 'Datei existiert nicht: %s' % f
    n=sum(1 for _ in open(pf,'rb'))
    assert 1<=ln<=n, 'Zeile %d liegt ausserhalb von %s (%d Zeilen)' % (ln,f,n)
    if os.path.realpath(pf)!=haupt: fremd+=1
assert fremd>0, 'keine Entscheidung aus einer importierten Unit -- Pruefung traegt nichts'
" 2>"$TMP/p14.log"; then
  ok "14 jede Stelle liegt in ihrer eigenen Datei (auch aus importierten Units)"
else
  no "14 Stelle gehoert zur Datei" "$(tail -2 "$TMP/p14.log" | tr '\n' ' ')"
fi

# 15. Filter beschneiden die Einzelliste, NICHT die Zusammenfassung. Sonst
#     liest sich eine gefilterte Sicht wie der ganze Lauf.
rm -f "$TMP/vapp"
baueVek --compile-profile="$TMP/v_f.json" --compile-profile-level=detailed --compile-profile-function=summe
if python3 -I -c "
import json
a=json.load(open('$TMP/v_det.json')); f=json.load(open('$TMP/v_f.json'))
assert f['decisions'], 'Filter laesst nichts durch'
assert all(x['function']=='summe' for x in f['decisions']), 'fremde Funktion trotz Filter'
assert len(f['decisions'])<len(a['decisions']), 'Filter hat nichts beschnitten'
assert f['decision_summary']==a['decision_summary'], 'decision_summary ist mitgefiltert'
assert f['coverage']['filters']['matches']==len(f['decisions']), 'matches != Trefferzahl'
assert a['coverage']['filters']['matches']==len(a['decisions']), 'matches ungefiltert falsch'
lim=f['collection']
assert lim['filtered'] is True, 'filtered nicht gesetzt'
assert any('gefiltert' in w for w in lim['warnings']), 'keine Warnung zur gefilterten Liste'
" 2>"$TMP/p15.log"; then
  ok "15 Filter beschneidet nur die Einzelliste, decision_summary bleibt global"
else
  no "15 Filterwirkung" "$(tail -2 "$TMP/p15.log" | tr '\n' ' ')"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
