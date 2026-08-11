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
done < <(grep -rlE '"\$LYXC"|\$\{LYXC\}' "$ROOT/tests" --include='*.sh')

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
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/probe.sh" <<PROBEEOF
LYXC="$ROOT/lyxc"
LYXC_TIMEOUT=1
. "$ROOT/tests/lib/lyxc_guard.sh"
"\$LYXC" --std-path="$ROOT" "$ROOT/src/lyxc.lyx" -o "$TMP/out" >/dev/null 2>&1
echo \$?
PROBEEOF
rc=$(bash "$TMP/probe.sh" 2>/dev/null | tail -1)
if [ "$rc" = "124" ]; then
  ok "Zeitlimit greift (rc=124 statt Endloslauf)"
else
  no "Zeitlimit" "rc=$rc erwartet 124 — die Bibliothek kappt nicht"
fi

cat > "$TMP/probe2.sh" <<PROBEEOF
LYXC="$ROOT/lyxc"
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
LYXC="$ROOT/lyxc"
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

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
