#!/usr/bin/env bash
# #1707 — Jede Suite muss den Compiler aus der Umgebung annehmen.
#
# Warum es diesen Waechter gibt: 197 Suiten schrieben `LYXC="$ROOT/lyxc"`
# unbedingt. Ein Aufruf `LYXC=/pfad/zu/neuem/lyxc bash tests/x.sh` mass damit
# still weiter `./lyxc` aus dem Repo — die Suite meldete gruen, und man hielt
# die eigene Aenderung fuer geprueft. Genau das hat innerhalb einer Sitzung
# zwei falsche Schlussfolgerungen erzeugt, eine davon stand danach als
# erfundene Begruendung in einem Quellkommentar.
#
# Geprueft wird zweierlei:
#   1. keine unbedingte Zuweisung an LYXC,
#   2. kein Aufruf des Compilers am Namen LYXC vorbei.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# tests/lib/lyxc_guard.sh biegt LYXC bewusst auf einen Wrapper um (#1294) und
# reicht den vorgefundenen Wert darin weiter — das ist kein Verstoss.
AUSNAHME="tests/lib/lyxc_guard.sh"

# 1: keine unbedingte Zuweisung
unbedingt=$(grep -rn '^[[:space:]]*LYXC=' tests/ --include='*.sh' \
            | grep -v "^$AUSNAHME:" \
            | grep -v "^tests/lyxc_umgebung_test.sh:" \
            | grep -vE 'LYXC="?\$\{?LYXC:-')
if [ -z "$unbedingt" ]; then
  _pass "1 keine unbedingte LYXC-Zuweisung"
else
  _fail "1 unbedingte LYXC-Zuweisung" "$(echo "$unbedingt" | head -5)"
fi

# 2: kein Compiler-Aufruf am Namen vorbei
vorbei=$(grep -rnE '"\$ROOT/lyxc"|"\$REPO_ROOT/lyxc"|(^|[^a-zA-Z_.])\./lyxc[[:space:]]' \
         tests/ --include='*.sh' \
         | grep -v "^$AUSNAHME:" \
         | grep -v "^tests/lyxc_umgebung_test.sh:" \
         | grep -v 'LYXC:-' \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
         | grep -v 'echo ')
if [ -z "$vorbei" ]; then
  _pass "2 kein Aufruf am Namen LYXC vorbei"
else
  _fail "2 Aufruf am Namen LYXC vorbei" "$(echo "$vorbei" | head -5)"
fi

# 3: der Mechanismus greift wirklich — eine echte Suite gegen einen
#    Platzhalter-Compiler laufen lassen und pruefen, dass sie ihn benutzt
TMP=$(mktemp -d)
# Der Platzhalter meldet sich ueber eine Datei, nicht ueber stderr: die
# Suiten leiten die Ausgabe des Compilers nach /dev/null um, eine Meldung
# waere also kein Nachweis.
cat > "$TMP/lyxc" <<STUB
#!/usr/bin/env bash
touch "$TMP/aufgerufen"
exit 1
STUB
chmod +x "$TMP/lyxc"
LYXC="$TMP/lyxc" bash tests/f64_typspur_import_test.sh >/dev/null 2>&1
if [ -f "$TMP/aufgerufen" ]; then
  _pass "3 LYXC aus der Umgebung wird tatsaechlich benutzt"
else
  _fail "3 LYXC aus der Umgebung wird ignoriert" "Platzhalter nie aufgerufen"
fi
rm -rf "$TMP"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
