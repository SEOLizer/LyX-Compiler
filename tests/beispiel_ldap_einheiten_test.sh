#!/usr/bin/env bash
# tests/beispiel_ldap_einheiten_test.sh — #2070: vier Beispiele, die seit einer
# strengeren sema nicht mehr uebersetzten, laufen wieder — und tun, was sie
# zeigen sollen.
#
# Keines davon kam in einem Lauf vor; der Beispiel-Sweep zu #2059 fand sie.
#
#   * examples/ldap_simple2.lyx, ldap_test.lyx, ldap_test_simple.lyx:
#     `var errMsg: int64 := LDAPErrorToStr(…)`. LDAPErrorToStr liefert pchar;
#     seit #1343 prueft die sema Rueckgabetypen ueber Unit-Grenzen. Vorher
#     uebersetzte das, und `Print(errMsg)` bekam eine Zahl statt eines Textes.
#   * examples/test_unit_types.lyx: `dist + 50.0` mit dist: km. Die Regel aus
#     #1110 ist gewollt — eine nackte Zahl sagt nicht, fuenfzig WAS. Das
#     Beispiel verrechnet jetzt zwei km-Werte.
#
# Geprueft wird die AUSGABE, nicht nur das Uebersetzen: "Datei entsteht" haette
# auch die alte Fassung mit der Zahl statt des Textes bestanden.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# Wie im Sweep: aus dem eigenen Verzeichnis, --std-path auf die Repo-Wurzel.
bauen() {  # $1 Beispiel (ohne .lyx), $2 zusaetzliche Option
  ( cd "$ROOT/examples" && timeout 120 "$LYXC" --std-path="$ROOT" $2 "$1.lyx" -o "$TMP/$1" ) >"$TMP/$1.log" 2>&1
}
laufen() {  # $1 Beispiel -> Ausgabe in $TMP/$1.aus, rc in $TMP/$1.rc
  ( timeout 10 "$TMP/$1" > "$TMP/$1.aus" 2>&1; echo $? > "$TMP/$1.rc" ) 2>/dev/null
}
hat() {  # $1 Beispiel, $2 erwartete Zeile (woertlich)
  if grep -aqxF -- "$2" "$TMP/$1.aus"; then ok "$1: \"$2\""
  else nok "$1: \"$2\" fehlt (Ausgabe: $(tr '\n' '|' < "$TMP/$1.aus" | cut -c1-90))"; fi
}

echo "--- LDAP-Beispiele: Fehlertexte kommen als TEXT an ---"
for b in ldap_simple2 ldap_test_simple ldap_test; do
  if ! bauen "$b" ""; then nok "$b uebersetzt nicht ($(grep -m1 -i 'error' "$TMP/$b.log"))"; continue; fi
  laufen "$b"
  rc="$(cat "$TMP/$b.rc")"
  [ "$rc" = "0" ] && ok "$b endet mit rc 0" || nok "$b endet mit rc $rc"
done
[ -f "$TMP/ldap_simple2.aus" ] && {
  hat ldap_simple2 "Error(0): Success"
  hat ldap_simple2 "Error(49): Invalid Credentials"
}
[ -f "$TMP/ldap_test_simple.aus" ] && {
  hat ldap_test_simple "LDAPErrorToStr(0): Success"
  hat ldap_test_simple "LDAPErrorToStr(49): Invalid Credentials"
  hat ldap_test_simple "Basic tests passed: 2"
}
[ -f "$TMP/ldap_test.aus" ] && {
  hat ldap_test "LDAPErrorToStr: Success"
  hat ldap_test "Tests passed (of 7): 7"
}

echo
echo "--- test_unit_types: Einheiten werden mit Einheiten verrechnet ---"
if bauen test_unit_types "--compile-unit"; then ok "test_unit_types uebersetzt"
else nok "test_unit_types uebersetzt nicht ($(grep -m1 -i 'error' "$TMP/test_unit_types.log"))"; fi

# GEGENPROBE: die Regel, an der das Beispiel scheiterte, gilt weiter. Das
# Beispiel wurde angepasst, nicht die Sprache.
sed 's/var dist2: km := dist + extra;/var dist2: km := dist + 50.0;/' \
  "$ROOT/examples/test_unit_types.lyx" > "$TMP/alt_units.lyx"
if ! grep -q 'dist + 50.0' "$TMP/alt_units.lyx"; then
  nok "Gegenprobe nicht aufgebaut — die Zeile im Beispiel hat sich geaendert"
elif ( cd "$TMP" && timeout 120 "$LYXC" --std-path="$ROOT" --compile-unit alt_units.lyx -o "$TMP/alt_units" ) >"$TMP/alt.log" 2>&1; then
  nok "dist + 50.0 wird angenommen — die Einheitenregel (#1110) greift nicht mehr"
elif grep -q 'dimensionsloser Zahl' "$TMP/alt.log"; then
  ok "dist + 50.0 wird weiter abgewiesen (\"Einheitentyp mit dimensionsloser Zahl verrechnet\")"
else
  nok "dist + 50.0 scheitert, aber nicht an der Einheitenregel: $(grep -m1 -i error "$TMP/alt.log")"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
