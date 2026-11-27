#!/usr/bin/env bash
# tests/lyxc_guard_coverage_test.sh — #1294: jeder Testaufruf von lyxc steht
# unter einer Ressourcengrenze.
#
# Warum es diese Pruefung gibt: die Grenze selbst ist wertlos, wenn das
# naechste neue Script sie vergisst. Genau so ist der Zustand entstanden, den
# #1294 beschreibt — 123 von 126 Scripts riefen den Compiler ungekappt auf, und
# ein einziger Endlosfall nahm die Maschine mit (Maus tot, dann die ganze
# Sitzung; kein Log ueberlebte).
#
# Dieselbe Bauart wie test_coverage_test.sh, der seit #1112 ueber die
# Testabdeckung wacht: eine Regel, die niemand prueft, verrottet.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- 1. Die Bibliothek ist da --------------------------------------------
if [ -f "$ROOT/tests/lib/lyxc_guard.sh" ]; then
  ok "tests/lib/lyxc_guard.sh vorhanden"
else
  no "tests/lib/lyxc_guard.sh" "fehlt — ohne sie ist jedes Script ungeschuetzt"
fi

# --- 2. Kein Script ruft lyxc ungekappt auf ------------------------------
# Gesucht wird jedes Script, das den Compiler benutzt und die Bibliothek NICHT
# einbindet. Der eigene Wachtest und die Bibliothek zaehlen nicht mit.
ungeschuetzt=""
anzahl=0
while IFS= read -r f; do
  case "$f" in
    */lib/lyxc_guard.sh|*/lyxc_guard_coverage_test.sh) continue ;;
    # Ausnahme mit Grund: hier ist LYXC der QUELLTEXT (src/lyxc.lyx), den das
    # Script mit grep durchsucht — es ruft den Compiler gar nicht auf. Die
    # Grenze wuerde die Variable auf den Wrapper umbiegen und die Pruefungen
    # ins Leere laufen lassen.
    */sec_wp27_read_test.sh) continue ;;
  esac
  anzahl=$((anzahl+1))
  grep -q "lyxc_guard" "$f" || ungeschuetzt="$ungeschuetzt $f"
# #2678: Das Muster hiess einmal '"\$LYXC"|\$\{LYXC\}' und traf damit nur
# zwei der drei gebraeuchlichen Schreibweisen -- unquotiertes `$LYXC` fiel
# durch, und `${LYXC:-./lyxc}` ist nicht `${LYXC}`. Gemessen: 11 weitere
# Scripts benutzen den Compiler so, 9 davon ohne Grenze (u.a.
# cpu_verteiler_2198_test.sh aus #2674). Aufgefallen ist es nur, weil ein
# zweiter neuer Test zufaellig quotiert schrieb und deshalb GEMELDET wurde.
# Jetzt zaehlt jedes Vorkommen des Namens als Benutzung: `$LYXC`, `"$LYXC"`,
# `${LYXC...}` in jeder Ersetzungsform. Die Abgrenzung nach hinten geschieht
# ueber eine Zeichenklasse und NICHT ueber \b -- in diesem Projekt ist das
# eine bekannte Falle (awk kennt \b nicht), und eine Zeichenklasse sagt
# dasselbe ohne Werkzeugabhaengigkeit. `${LYXC_TIMEOUT}` und `LYXCA` bleiben
# damit richtigerweise draussen: andere Namen.
done < <(grep -rlE '\$\{?LYXC([^A-Za-z0-9_]|$)' "$ROOT/tests" --include='*.sh')

if [ -z "$ungeschuetzt" ]; then
  ok "alle $anzahl Scripts mit lyxc-Aufruf binden die Grenze ein"
else
  n=$(printf '%s\n' $ungeschuetzt | wc -l)
  no "Ressourcengrenze fehlt in $n Script(en)" "$(printf '%s' "$ungeschuetzt" | tr ' ' '\n' | sed "s|$ROOT/||" | head -5 | tr '\n' ' ')"
  echo "  Abhilfe: nach der LYXC-Zuweisung diese Zeile einfuegen:"
  echo '  _g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"'
fi

# --- 3. Die Grenze greift auch wirklich ----------------------------------
# Ohne diese Probe wuerde eine Bibliothek, die versehentlich nichts tut, alle
# obigen Pruefungen bestehen.
#
# #2194: Hier stand `$LYXC src/lyxc.lyx` mit einem Zeitlimit von einer
# Sekunde — die Probe setzte also voraus, dass der SELBSTBAU laenger als eine
# Sekunde dauert. Genau das ist weggefallen: auf der CI-Maschine war er
# schneller als das Limit, und der Test meldete "die Bibliothek kappt nicht",
# obwohl sie in Ordnung war. Ein Test, der voraussetzt, dass der Compiler
# langsam bleibt, wird mit jeder Beschleunigung roter — dieselbe Falle wie
# "ein Test darf nicht voraussetzen, dass eine Luecke offen bleibt"
# (CLAUDE.md).
#
# Geprueft wird jetzt die BIBLIOTHEK, nicht die Geschwindigkeit des
# Compilers: sie umhuellt irgendein `$LYXC`, also genuegt ein Platzhalter,
# der sicher laenger laeuft als das Limit. Das Ergebnis haengt damit an
# nichts, was sich durch Optimierung aendern kann.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/langsam" <<'STUBEOF'
#!/usr/bin/env bash
# Platzhalter fuer lyxc: kehrt absichtlich nicht vor dem Zeitlimit zurueck.
sleep 30
STUBEOF
chmod +x "$TMP/langsam"
# Die Probe benutzt die VORGESCHRIEBENE Form `LYXC="${LYXC:-…}"` und bekommt
# den Platzhalter von aussen mitgegeben — so, wie es jeder Test erlaubt sein
# muss (tests/lyxc_umgebung_test.sh verlangt genau das). Eine feste Zuweisung
# an LYXC stuende hier sonst als Verstoss in der Pruefung, und die
# Ausnahmeliste dafuer zu erweitern waere der falsche Weg: die Regel ist
# richtig, nur die Form war es nicht.
# Begrenzer in Anfuehrungszeichen: so steht die Zeile UNVERAENDERT in der
# Datei, ohne Escapen. Mit einem offenen Begrenzer waere daraus
# `LYXC="\${LYXC:-…}"` geworden, und das Backslash bricht das
# Erlaubnis-Muster der Wache — die Zeile sah dann wie eine feste Zuweisung
# aus, obwohl sie keine ist. ROOT kommt beim Aufruf aus der Umgebung.
cat > "$TMP/probe.sh" <<'PROBEEOF'
LYXC="${LYXC:-$ROOT/lyxc}"
. "$ROOT/tests/lib/lyxc_guard.sh"
"$LYXC" --tut-nichts >/dev/null 2>&1
echo $?
PROBEEOF
rc=$(ROOT="$ROOT" LYXC="$TMP/langsam" LYXC_TIMEOUT=1 bash "$TMP/probe.sh" 2>/dev/null | tail -1)
if [ "$rc" = "124" ]; then
  ok "Zeitlimit greift (rc=124 statt Endloslauf)"
else
  no "Zeitlimit" "rc=$rc erwartet 124 — die Bibliothek kappt nicht"
fi

cat > "$TMP/probe2.sh" <<PROBEEOF
LYXC="${LYXC:-$ROOT/lyxc}"
LYXC_VM_KB=20000
. "$ROOT/tests/lib/lyxc_guard.sh"
"\$LYXC" --std-path="$ROOT" "$ROOT/src/lyxc.lyx" -o "$TMP/out2" >/dev/null 2>&1
echo \$?
PROBEEOF
rc2=$(bash "$TMP/probe2.sh" 2>/dev/null | tail -1)
if [ "$rc2" != "0" ]; then
  ok "Speichergrenze greift (rc=$rc2 statt unbegrenzter Belegung)"
else
  no "Speichergrenze" "rc=0 — 20 MB haetten nicht reichen duerfen"
fi

# --- 4. Gegenprobe: ein normaler Aufruf laeuft weiter ---------------------
# Eine Grenze, die alles abwuergt, waere bei 1 bis 3 ebenfalls gruen.
cat > "$TMP/ok.lyx" <<'LYXEOF'
fn main(): int64 { return 0; }
LYXEOF
cat > "$TMP/probe3.sh" <<PROBEEOF
LYXC="${LYXC:-$ROOT/lyxc}"
. "$ROOT/tests/lib/lyxc_guard.sh"
"\$LYXC" --std-path="$ROOT" "$TMP/ok.lyx" -o "$TMP/ok" >/dev/null 2>&1
echo \$?
PROBEEOF
rc3=$(bash "$TMP/probe3.sh" 2>/dev/null | tail -1)
if [ "$rc3" = "0" ]; then
  ok "gewoehnliche Uebersetzung laeuft unter der Grenze weiter"
else
  no "gewoehnliche Uebersetzung" "rc=$rc3 — die Vorgabewerte sind zu eng"
fi

# --- 5. Die Grenze umhuellt nur einen vorhandenen Compiler ---------------
# #2678: Der Wrapper ist immer ausfuehrbar. Wuerde die Grenze ihn auch ohne
# Compiler setzen, waere jedes `[ -x "$LYXC" ]` nach dem Einbinden wahr --
# gemessen 20 Scripts, deren SKIP-Zweig damit tot war. Beide Seiten werden
# geprueft: ohne Compiler unberuehrt, mit Compiler umhuellt. Eine Pruefung
# nur der ersten Haelfte waere auch von einer Grenze erfuellt, die gar nichts
# mehr tut.
# Begrenzer in Anfuehrungszeichen, und ZIEL kommt aus der Umgebung: so steht
# die LYXC-Zeile UNVERAENDERT in der Datei. Mit offenem Begrenzer wuerde
# daraus `LYXC="\${LYXC:-...}"`, und das Backslash bricht das
# Erlaubnis-Muster von tests/lyxc_umgebung_test.sh — die Zeile saehe dann wie
# eine feste Zuweisung aus, obwohl sie keine ist. Dieselbe Falle steht zehn
# Zeilen weiter oben schon beschrieben, und hier war sie trotzdem drin
# (gemessen: "FAIL 1 unbedingte LYXC-Zuweisung" im vollen Lauf).
cat > "$TMP/probe4.sh" <<'PROBEEOF'
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ZIEL}"
. "$ROOT/tests/lib/lyxc_guard.sh"
echo "$LYXC"
PROBEEOF
got4=$(ROOT="$ROOT" ZIEL="$TMP/gibt-es-nicht" bash "$TMP/probe4.sh" 2>/dev/null | tail -1)
if [ "$got4" = "$TMP/gibt-es-nicht" ]; then
  ok "fehlender Compiler: LYXC bleibt unberuehrt (SKIP-Zweige leben)"
else
  no "fehlender Compiler" "LYXC wurde auf '$got4' umgebogen — -x ist damit immer wahr"
fi

cat > "$TMP/probe5.sh" <<'PROBEEOF'
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ZIEL}"
. "$ROOT/tests/lib/lyxc_guard.sh"
echo "$LYXC"
PROBEEOF
got5=$(ROOT="$ROOT" ZIEL="$TMP/langsam" bash "$TMP/probe5.sh" 2>/dev/null | tail -1)
if [ "$got5" != "$TMP/langsam" ]; then
  ok "vorhandener Compiler: LYXC wird umhuellt"
else
  no "vorhandener Compiler" "LYXC blieb '$got5' — die Grenze greift gar nicht mehr"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
