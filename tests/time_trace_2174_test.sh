#!/usr/bin/env bash
# tests/time_trace_2174_test.sh — #2174: Zeitlinie der Uebersetzung.
#
# `--time-trace=DATEI` schreibt je Phase Start und Dauer (Chrome-Trace-Format)
# und Zusatzwerte: Importzeit, verarbeitete Units, Aufrufe der linearen Suchen;
# am Ende Wand-, CPU-Zeit und Spitzen-RSS. Gemessen wird hier, dass
#   - die Datei gueltiges JSON mit den Phasen und Zaehlern ist,
#   - die Zaehler WERTE tragen (nicht nur vorhanden sind — ein Zaehler, der
#     nie hochzaehlt, war der erste Fehler dieser Arbeit: Init setzte den
#     Schalter des Codegens zurueck),
#   - das Erzeugnis mit und ohne Option bitgleich ist,
#   - ohne Option keine Datei entsteht, ein nicht schreibbarer Pfad laut ist.
# Dazu Rauchtests fuer tools/stichprobe.py und tools/bench_compile.sh.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
LYXCA="$(readlink -f "$LYXC")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'EOF'
import std.conv;
fn quadrat(x: int64): int64 { var y: int64 := x * x; return y; }
fn main(): int64 {
  var s: int64 := 0; var i: int64 := 0;
  while (i < 10) { s := s + quadrat(i); i := i + 1; }
  PrintInt(s); Print(" "); PrintInt(RotateLeft32(1, 4)); Print("\n");
  return 0;
}
EOF
baue() {  # ausgabe [optionen]
  local o="$1"; shift
  ( cd "$ROOT" && timeout 240 "$LYXCA" --std-path="$ROOT" "$@" "$TMP/p.lyx" -o "$o" ) >"$o.log" 2>&1
}

# --- x86: Phasen, Zaehler, Bitgleichheit --------------------------------------
if baue "$TMP/mit" --time-trace="$TMP/t.json" && baue "$TMP/ohne"; then
  pr="$(python3 -I - "$TMP/t.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("kein JSON:", e); sys.exit()
ev = {e["name"]: e for e in d["traceEvents"]}
fehlt = [p for p in ("lexer", "parser", "sema", "codegen-x86_64") if p not in ev]
if fehlt: print("fehlende Phasen:", fehlt); sys.exit()
for e in d["traceEvents"]:
    if e.get("ph") != "X" or e["dur"] < 0 or e["ts"] < 0: print("Ereignis kaputt:", e); sys.exit()
s, c, o = ev["sema"].get("args", {}), ev["codegen-x86_64"].get("args", {}), d["otherData"]
pruef = {
  "sema.importe_units": s.get("importe_units", 0) >= 1,
  "sema.Lookup_aufrufe": s.get("Lookup_aufrufe", 0) > 0,
  "sema.Lookup_vergleiche": s.get("Lookup_vergleiche", 0) > 0,
  "codegen.importe_units": c.get("importe_units", 0) >= 1,
  "codegen.findLocal_aufrufe": c.get("findLocal_aufrufe", 0) > 0,
  "codegen.findLocalIdx_vergleiche": c.get("findLocalIdx_vergleiche", 0) >= c.get("findLocalIdx_aufrufe", 1),
  "codegen.findLabel_aufrufe": c.get("findLabel_aufrufe", 0) > 0,
  "codegen.funcRetTypeName_aufrufe": c.get("funcRetTypeName_aufrufe", 0) > 0,
  "wall_us": o.get("wall_us", 0) > 0,
  "cpu_us": o.get("cpu_us", 0) > 0,
  "peak_rss_kb": o.get("peak_rss_kb", 0) > 1000,
}
schlecht = [k for k, v in pruef.items() if not v]
print("ok" if not schlecht else "Werte fehlen/null: " + ", ".join(schlecht))
PY
)"
  [ "$pr" = ok ] && ok "x86: Phasen und Zaehler mit Werten" || nok "x86: $pr"
  cmp -s "$TMP/mit" "$TMP/ohne" && ok "Erzeugnis mit/ohne --time-trace bitgleich" || nok "Erzeugnis unterscheidet sich mit --time-trace"
  aus="$("$TMP/mit")"; [ "$aus" = "285 16" ] && ok "Programm laeuft [$aus]" || nok "Programm: [$aus] statt [285 16]"
else nok "x86: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/mit.log" "$TMP/ohne.log"))"; fi

# --- ohne Option: keine Datei; nicht schreibbarer Pfad: laut ------------------
rm -f "$TMP/nie.json"
baue "$TMP/b2" >/dev/null 2>&1
[ ! -e "$TMP/nie.json" ] && ok "ohne Option keine Zeitlinie" || nok "Datei ohne Option entstanden"
baue "$TMP/b3" --time-trace="$TMP/gibt/es/nicht/t.json"
grep -q "time-trace: Datei nicht schreibbar" "$TMP/b3.log" && ok "nicht schreibbarer Pfad: gemeldet" \
  || nok "nicht schreibbarer Pfad: keine Meldung ($(head -c 200 "$TMP/b3.log"))"

# --- IR-Ziel: Phase ir-lowering mit Zaehlern ----------------------------------
if baue "$TMP/a64" --target=arm64 --time-trace="$TMP/a.json"; then
  pa="$(python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1])); ev = {e['name']: e for e in d['traceEvents']}
a = ev.get('ir-lowering', {}).get('args', {})
print('ok' if 'ir-lowering' in ev and 'tregFind_aufrufe' in a and 'findTypeDecl_aufrufe' in a else 'fehlt: ' + str(list(ev)))" "$TMP/a.json")"
  [ "$pa" = ok ] && ok "arm64: ir-lowering mit Zaehlern" || nok "arm64: $pa"
else nok "arm64: uebersetzt nicht"; fi

# --- Werkzeuge -----------------------------------------------------------------
if ( cd "$ROOT" && bash tools/bench_compile.sh -n 1 -c "$LYXCA" "$TMP/p.lyx" ) >"$TMP/bench.log" 2>&1 \
   && grep -q "Median" "$TMP/bench.log" && grep -q "codegen-x86_64" "$TMP/bench.log"; then
  ok "tools/bench_compile.sh: Median und Phasen"
else nok "tools/bench_compile.sh: $(tail -2 "$TMP/bench.log" | tr '\n' ' ')"; fi

ps="$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)"
if command -v gdb >/dev/null 2>&1 && [ "$ps" -le 1 ]; then
  cat > "$TMP/heiss.lyx" <<'EOF'
fn heiss(n: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < n) { s := s + (i ^ (s >> 3)); i := i + 1; } return s; }
fn main(): int64 { var r: int64 := heiss(400000000); if (r == 7) { Print("x"); } return 0; }
EOF
  if ( cd "$ROOT" && "$LYXCA" --debug "$TMP/heiss.lyx" -o "$TMP/heiss" ) >/dev/null 2>&1; then
    python3 -I "$ROOT/tools/stichprobe.py" --intervall 0.01 --top 3 "$TMP/heiss" >"$TMP/sp.log" 2>&1
    # Die Schleife steckt in heiss — dort muss der groesste Anteil liegen.
    if grep -A1 "^Selbstzeit" "$TMP/sp.log" | grep -q "heiss"; then ok "tools/stichprobe.py: heisse Funktion erkannt"
    else nok "tools/stichprobe.py: $(head -6 "$TMP/sp.log" | tr '\n' ' ')"; fi
  else nok "stichprobe: Testprogramm uebersetzt nicht"; fi
else
  echo "SKIP tools/stichprobe.py: kein gdb oder ptrace_scope > 1"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
