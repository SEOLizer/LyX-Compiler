#!/usr/bin/env bash
# tests/symboltabellen_2175_test.sh — #2175: Namenssuche ohne lineare Laeufe.
#
# Bis 1.2.18B durchsuchten Sema.Lookup, cg_findLabel, cg_findConIdx,
# cg_funcRetTypeName, cg_lineOf, die Funktionssuche in cg_genCall,
# cg_eigeneUnitDefiniert und Sema._checkDuplicateFuncs bei jedem Aufruf die
# ganze Tabelle — die Uebersetzungszeit wuchs quadratisch mit der Programm-
# groesse (8000 Funktionen: 87 s). Gemessen wird hier:
#   - der WEG: die Zaehler aus --time-trace zaehlen jetzt die tatsaechlich
#     verglichenen Eintraege. Je Aufruf muessen es wenige sein, auch bei
#     4000 Funktionen — die lineare Suche laege bei Tausenden;
#   - die Skalierung: viermal so viel Quelltext darf nicht 16-mal so lange
#     brauchen (Grenze 10, linear waere 4);
#   - dass die Hash-Ketten die Bedeutung erhalten: Verschattung in
#     verschachtelten Bloecken und danach wieder der aeussere Name, private
#     Symbole, doppelte Funktionen mit denselben Meldungen in derselben
#     Reihenfolge wie die frueher quadratische Pruefung;
#   - Zeilennummern in Fehlermeldungen und im Erzeugnis (cg_lineOf).
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

# Programm mit N Funktionen und N Konstanten; jede Funktion ruft die vorige.
erzeuge() {  # n datei
  python3 -I - "$1" "$2" <<'PY'
import sys
n = int(sys.argv[1]); o = open(sys.argv[2], "w")
for i in range(n): o.write(f"con K{i}: int64 := {i % 97};\n")
o.write("fn fn_0(x: int64): int64 { return x + K0; }\n")
for i in range(1, n):
    o.write(f"fn fn_{i}(x: int64): int64 {{\n  var a: int64 := x + K{i};\n"
            f"  if (a > 1000) {{ a := a - K{(i*7) % n}; }}\n  return fn_{i-1}(a) + K{i-1};\n}}\n")
o.write(f"fn main(): int64 {{ var r: int64 := fn_{n-1}(1); PrintInt(r % 1000); Print(\"\\n\"); return 0; }}\n")
PY
}
baue() {  # quelle ausgabe [optionen]
  local q="$1" o="$2"; shift 2
  ( cd "$ROOT" && ulimit -v 4000000 && timeout 300 "$LYXCA" "$@" "$q" -o "$o" ) >"$o.log" 2>&1
}

# --- Weg: Vergleiche je Aufruf --------------------------------------------------
erzeuge 4000 "$TMP/g4000.lyx"
if baue "$TMP/g4000.lyx" "$TMP/g4000" --time-trace="$TMP/t.json"; then
  pr="$(python3 -I - "$TMP/t.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); ev = {e["name"]: e.get("args", {}) for e in d["traceEvents"]}
s, c = ev["sema"], ev["codegen-x86_64"]
# (Aufrufe, Vergleiche, hoechstens je Aufruf). Linear laege jeder Wert bei
# Hunderten bis Tausenden; die Ketten sind im Mittel kaum laenger als 1.
paare = [("Lookup", s, 4), ("funcRetTypeName", c, 4), ("findLabel", c, 4), ("findConIdx", c, 4)]
schlecht = []
for name, quelle, grenze in paare:
    a, v = quelle.get(name + "_aufrufe", 0), quelle.get(name + "_vergleiche", -1)
    if a < 100: schlecht.append(f"{name}: nur {a} Aufrufe")
    elif v < 0 or v > a * grenze: schlecht.append(f"{name}: {v} Vergleiche bei {a} Aufrufen")
# cg_lineOf: einmal der Text, danach binaere Suche (log2 der Zeilenzahl)
la, ls = c.get("lineOf_aufrufe", 0), c.get("lineOf_schritte", -1)
if la < 1000 or ls > la * 20 + 2000000: schlecht.append(f"lineOf: {ls} Schritte bei {la} Aufrufen")
print("ok" if not schlecht else "; ".join(schlecht))
PY
)"
  [ "$pr" = ok ] && ok "4000 Funktionen: wenige Vergleiche je Suche" || nok "Weg: $pr"
  aus="$("$TMP/g4000")"
  # Referenz: dieselbe Rechnung in Python (fn_i ruft fn_{i-1}, aussen beginnend)
  erw="$(python3 -I -c "
n = 4000; K = [i % 97 for i in range(n)]
x = 1; zu = 0
for i in range(n - 1, 0, -1):
    a = x + K[i]
    if a > 1000: a -= K[(i * 7) % n]
    zu += K[i - 1]; x = a
print((x + K[0] + zu) % 1000)")"
  [ "$aus" = "$erw" ] && ok "Programm mit 4000 Funktionen rechnet richtig [$aus]" || nok "4000 Funktionen: [$aus] statt [$erw]"
else nok "4000 Funktionen: uebersetzt nicht ($(tail -1 "$TMP/g4000.log"))"; fi

# --- Skalierung -----------------------------------------------------------------
erzeuge 2000 "$TMP/g2000.lyx"; erzeuge 8000 "$TMP/g8000.lyx"
cpu() {  # quelle -> CPU-Sekunden (Median aus drei Laeufen)
  local q="$1" i t=()
  for i in 1 2 3; do
    rm -f "$TMP/sk"
    t+=("$( { /usr/bin/time -f '%U %S' bash -c "ulimit -v 4000000; cd '$ROOT' && '$LYXCA' '$q' -o '$TMP/sk' >/dev/null 2>&1"; } 2>&1 | awk 'NF==2 {print $1+$2}')")
    # Ein abgebrochener Lauf (Guard-Zeitlimit, Absturz) ist keine Messung.
    [ -x "$TMP/sk" ] || { echo "abgebrochen"; return; }
  done
  printf '%s\n' "${t[@]}" | sort -g | sed -n 2p
}
if [ -x /usr/bin/time ]; then
  t2="$(cpu "$TMP/g2000.lyx")"; t8="$(cpu "$TMP/g8000.lyx")"
  v="$(python3 -I -c "import sys; a,b=float(sys.argv[1]),float(sys.argv[2]); print(round(b/max(a,0.01),1))" "$t2" "$t8" 2>/dev/null || echo kaputt)"
  if [ "$v" != kaputt ] && python3 -I -c "import sys; sys.exit(0 if float(sys.argv[1]) < 10 else 1)" "$v"; then
    ok "Skalierung 2000 -> 8000 Funktionen: Faktor $v (${t2}s -> ${t8}s, quadratisch waere 16)"
  else nok "Skalierung 2000 -> 8000: Faktor $v (${t2}s -> ${t8}s)"; fi
else echo "SKIP Skalierung: /usr/bin/time fehlt"; fi

# --- Verschattung ueber Bloecke und Funktionen hinweg ---------------------------
cat > "$TMP/schatten.lyx" <<'EOF'
var x: int64 := 1;
fn innen(x: int64): int64 { return x * 10; }
fn main(): int64 {
  var s: int64 := x;
  if (s == 1) {
    var x: int64 := 7;
    s := s * 100 + x;
    if (x == 7) { var x: int64 := 3; s := s * 10 + x; }
    s := s * 10 + x;
  }
  s := s * 10 + x;
  s := s * 1000 + innen(5);
  PrintInt(s); Print("\n");
  return 0;
}
EOF
if baue "$TMP/schatten.lyx" "$TMP/schatten"; then
  aus="$("$TMP/schatten")"
  # 1 -> 107 -> 1073 -> 10737 -> 107371 -> 107371050
  [ "$aus" = "107371050" ] && ok "Verschattung: innerer Name, danach wieder der aeussere [$aus]" \
    || nok "Verschattung: [$aus] statt [107371050]"
else nok "Verschattung: uebersetzt nicht ($(grep -m1 -i error "$TMP/schatten.log"))"; fi

# Nach dem Block ist der innere Name weg — die Kette muss ihn ausgehaengt haben.
cat > "$TMP/weg.lyx" <<'EOF'
fn main(): int64 {
  if (1 == 1) { var nurInnen: int64 := 4; PrintInt(nurInnen); }
  return nurInnen;
}
EOF
baue "$TMP/weg.lyx" "$TMP/weg"; rc=$?
if [ $rc -ne 0 ] && grep -q "nurInnen" "$TMP/weg.log"; then ok "Name ausserhalb seines Blocks: gemeldet"
else nok "Name ausserhalb seines Blocks: rc $rc, $(grep -m1 -iE 'error|nurInnen' "$TMP/weg.log")"; fi

# --- private Symbole (#1035) laufen weiter ueber dieselbe Kette -----------------
mkdir -p "$TMP/pv/u"
cat > "$TMP/pv/u/priv.lyx" <<'EOF'
unit u.priv;
fn geheim(): int64 { return 1; }
pub fn offen(): int64 { return geheim() + 41; }
EOF
cat > "$TMP/pv/haupt.lyx" <<'EOF'
import u.priv;
fn main(): int64 { PrintInt(offen()); Print("\n"); return geheim(); }
EOF
( cd "$TMP/pv" && ulimit -v 4000000 && timeout 60 "$LYXCA" --std-path="$ROOT" haupt.lyx -o h ) >"$TMP/pv.log" 2>&1; rc=$?
if [ $rc -ne 0 ] && grep -q "geheim" "$TMP/pv.log"; then ok "privates Symbol eines Imports: gemeldet"
else nok "privates Symbol: rc $rc, $(grep -m1 -iE 'error|geheim' "$TMP/pv.log")"; fi

# --- doppelte Funktionen: dieselben Meldungen wie die Doppelschleife ------------
cat > "$TMP/dup.lyx" <<'EOF'
fn a(): int64 { return 1; }
fn b(): int64 { return 2; }
fn a(): int64 { return 3; }
fn b(): int64 { return 4; }
fn a(): int64 { return 5; }
fn main(): int64 { return a(); }
EOF
baue "$TMP/dup.lyx" "$TMP/dup"
ist="$(grep "bereits deklariert" "$TMP/dup.log" | sed 's/.*line \([0-9]*\).*'"'"'\(.*\)'"'"'.*/\1\2/' | tr '\n' ' ')"
# Paare (a, b) in Quelltextreihenfolge: a@1 meldet a@3 und a@5, b@2 meldet
# b@4, a@3 meldet a@5 — die dritte Fassung von a also zweimal.
[ "$ist" = "3a 5a 4b 5a " ] && ok "doppelte Funktionen: Meldungen und Reihenfolge [$ist]" \
  || nok "doppelte Funktionen: [$ist] statt [3a 5a 4b 5a ]"

# --- Zeilennummern (cg_lineOf) --------------------------------------------------
# Die Zeile jeder Funktion steht in der DWARF-Zeilentabelle (--debug). Sie
# muss fuer alle 2000 Funktionen mit `grep -n` uebereinstimmen — auch weit
# hinten in der Datei, wo die binaere Suche viele Schritte macht.
if command -v readelf >/dev/null 2>&1; then
  if baue "$TMP/g2000.lyx" "$TMP/g2000d" --debug; then
    ist="$(readelf --debug-dump=decodedline "$TMP/g2000d" 2>/dev/null \
           | awk '$2 ~ /^[0-9]+$/ && $3 ~ /^0x/ {print $2}' | sort -n | uniq)"
    soll="$(grep -n '^fn ' "$TMP/g2000.lyx" | cut -d: -f1 | sort -n)"
    if [ -n "$ist" ] && [ "$ist" = "$soll" ]; then ok "Zeilen aller $(echo "$soll" | wc -l) Funktionen in DWARF stimmen"
    else nok "DWARF-Zeilen: $(diff <(echo "$soll") <(echo "$ist") | head -4 | tr '\n' ' ')"; fi
  else nok "--debug: uebersetzt nicht ($(tail -1 "$TMP/g2000d.log"))"; fi
else echo "SKIP Zeilennummern: readelf fehlt"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
