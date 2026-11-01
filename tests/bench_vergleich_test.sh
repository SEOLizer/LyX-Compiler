#!/usr/bin/env bash
# tests/bench_vergleich_test.sh — das Vergleichsgeschirr bleibt messfaehig (#2332).
#
# tools/bench_vergleich.sh misst die Uebersetzungszeit von lyxc gegen TCC,
# GCC, Clang und Cranelift auf EINER generierten Last (tools/gen_bench_last.sh).
# Gemessen wird nur, wenn alle Fassungen dieselbe Pruefsumme liefern — dieser
# Test haelt genau das wach:
#
#   1. der Generator schreibt alle drei Fassungen und sie sind nicht leer;
#   2. jeder VORHANDENE Compiler uebersetzt die Last und sein Erzeugnis gibt
#      dieselbe Pruefsumme aus wie die anderen.
#
# Zeiten werden hier NICHT geprueft. Eine Zeitschwelle im Test ist auf einer
# geteilten Maschine ein Wuerfel; der Nachweis gehoert in bench/ergebnisse/.
# Was dieser Test faengt, ist der Verfall: eine Sprachaenderung, nach der die
# Lyx-Fassung nicht mehr uebersetzt, oder ein Codegen-Fehler, nach dem sie
# etwas anderes rechnet als GCC. Ohne den Test faellt beides erst beim
# naechsten Messlauf auf, und dann sieht es nach einem Messproblem aus.
#
# Ein fehlender Fremdcompiler ist KEIN Fehlschlag (tcc/clang brauchen
# Installationsrechte), wird aber als HINWEIS genannt. Weniger als zwei
# vorhandene Compiler ist einer: dann vergleicht das Geschirr nichts.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
# Weitergabe an tools/bench_vergleich.sh ueber die Umgebung (es liest LYXC
# selbst bedingt ein). Ein Praefix `LYXC="$LYXC" cmd` je Aufruf taete
# dasselbe, saehe fuer tests/lyxc_umgebung_test.sh aber wie eine unbedingte
# Zuweisung aus (#1707) -- der Waechter liest den Zeilenanfang.
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1. Generator
if "$ROOT/tools/gen_bench_last.sh" -n 40 -o "$TMP/q" >"$TMP/gen.log" 2>&1; then
  fehlt=""
  for f in last.lyx last.c last.rs; do
    [ -s "$TMP/q/$f" ] || fehlt="$fehlt $f"
  done
  if [ -n "$fehlt" ]; then no "Generator" "leer oder fehlt:$fehlt"; else ok "Generator schreibt drei Fassungen"; fi
else
  no "Generator" "$(tail -2 "$TMP/gen.log" | tr '\n' ' ')"
fi

# 2. Pruefsummen aller vorhandenen Compiler. -w 0 laesst den Laufzeitteil
#    aus, -n 1 misst einmal; gemessen wird hier nichts, geprueft alles.
echo "--- vorhandene Compiler ---"
"$ROOT/tools/bench_vergleich.sh" -l | sed 's/^/    /'
if timeout 900 "$ROOT/tools/bench_vergleich.sh" -c "$LYXC" -f 40 -n 1 -w 0 >"$TMP/v.log" 2>&1; then
  anzahl=$(grep -c 'uebersetzen' "$TMP/v.log")
  if [ "$anzahl" -lt 2 ]; then
    no "Vergleich" "nur $anzahl Compiler gemessen — es gibt nichts zu vergleichen"
  else
    ok "$anzahl Compiler, gleiche Pruefsumme ($(sed -n 's/^Pruefsumme.*: //p' "$TMP/v.log"))"
  fi
  grep -E '^NICHT gemessen|^ +[a-z0-9-]+ +-> ' "$TMP/v.log" | sed 's/^/HINWEIS: /'
else
  no "Vergleich" "$(grep -E '^FEHLER' "$TMP/v.log" | head -3 | tr '\n' ' ')"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
