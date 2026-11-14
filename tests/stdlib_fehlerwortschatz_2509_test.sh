#!/bin/bash
# #2509 / #2515: Wer einen Fehlercode in der OEFFENTLICHEN Schnittstelle
# nimmt oder zurueckgibt, muss ihn auch EXPORTIEREN.
#
# std/result.lyx deklarierte seine vierzehn ERR_*-Codes als `con`, std/error.lyx
# seine 133 errno-Konstanten ebenso. Beide Units geben die Codes ueber ihre
# pub-Funktionen heraus (`ErrInt64`, `ResultInt64Error`, `ErrorCodeToString`,
# `GetErrorCode`, `GetErrorMessage`) -- die Zahlen waren also der Wortschatz
# der Schnittstelle, aber nicht Teil davon. Uebrig blieb, sie hinzuschreiben:
# `ErrInt64(2)` statt `ErrInt64(ERR_INVALID_INPUT)`.
#
# GEPRUEFT WIRD DIE WIRKUNG, nicht das Vorhandensein eines `pub`: ein
# Programm, das die Namen benutzt, muss uebersetzen UND das Richtige
# ausgeben. Eine Quellsuche nach "pub con" waere auch von einer Unit
# erfuellt, die den Namen exportiert und den falschen Wert dahinterlegt.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

# 1+2) std.result: der Name uebersetzt und benennt denselben Code wie die Zahl.
cat > "$TMP/r.lyx" <<'EOF'
unit main;
import std.io;
import std.result;
fn main(): int64 {
    var r: ResultInt64 := ErrInt64(ERR_INVALID_INPUT);
    PrintLn(ErrorCodeToString(ResultInt64Error(r)));
    PrintInt(ResultInt64Error(r)); PrintLn("");
    return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" >"$TMP/r.log" 2>&1 && [ -x "$TMP/r" ]; then
  ok "std.result: ERR_INVALID_INPUT ist von aussen benennbar"
  aus="$("$TMP/r" 2>&1)"
  # ERR_INVALID_INPUT ist 2 -- der Wert gehoert zur Schnittstelle, nicht nur der Name.
  if [ "$(echo "$aus" | tail -1)" = "2" ]; then
    ok "std.result: der Name traegt den Wert 2, nicht irgendeinen"
  else
    bad "std.result: Wert" "ausgegeben '$(echo "$aus" | tail -1)', erwartet 2"
  fi
else
  bad "std.result" "$(grep -m1 -E 'error|nicht pub' "$TMP/r.log")"
  bad "std.result: Wert" "kein Erzeugnis"
fi

# 3+4) std.error: dasselbe fuer die errno-Namen.
cat > "$TMP/e.lyx" <<'EOF'
unit main;
import std.io;
import std.error;
fn main(): int64 {
    var rc: int64 := 0 - 2;
    if (GetErrorCode(rc) != ENOENT) { PrintLn("falsch"); return 1; }
    PrintInt(ENOENT); PrintLn("");
    PrintInt(EPERM);  PrintLn("");
    return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/e.lyx" -o "$TMP/e" >"$TMP/e.log" 2>&1 && [ -x "$TMP/e" ]; then
  ok "std.error: ENOENT/EPERM sind von aussen benennbar"
  aus="$("$TMP/e" 2>&1)"
  if [ "$(echo "$aus" | sed -n 1p)" = "2" ] && [ "$(echo "$aus" | sed -n 2p)" = "1" ]; then
    ok "std.error: ENOENT = 2 und EPERM = 1 (Werte, nicht nur Namen)"
  else
    bad "std.error: Werte" "ausgegeben '$aus', erwartet 2 und 1"
  fi
else
  bad "std.error" "$(grep -m1 -E 'error|nicht pub' "$TMP/e.log")"
  bad "std.error: Werte" "kein Erzeugnis"
fi

# 5) Gegenprobe, zweiseitig: ein INTERNER Name bleibt innen. Ohne diese
#    Haelfte waere der Test auch von einer Unit erfuellt, die kurzerhand
#    ALLES exportiert -- und dann ist jede Umbenennung ein Bruch der
#    Schnittstelle. RESULT_INT64_MIN ist Rechengroesse von SafeDiv/SafeMod
#    und steht in keiner Signatur.
cat > "$TMP/i.lyx" <<'EOF'
unit main;
import std.io;
import std.result;
fn main(): int64 { PrintInt(RESULT_INT64_MIN); PrintLn(""); return 0; }
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/i.lyx" -o "$TMP/i" >"$TMP/i.log" 2>&1; then
  bad "Gegenprobe" "RESULT_INT64_MIN ist von aussen sichtbar -- exportiert wurde zu viel"
else
  if grep -q "nicht pub" "$TMP/i.log"; then
    ok "interner Name bleibt innen (RESULT_INT64_MIN), und die Meldung sagt warum"
  else
    bad "Gegenprobe" "abgelehnt, aber ohne 'nicht pub': $(grep -m1 error "$TMP/i.log")"
  fi
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "OK: Fehlerwortschatz ist Teil der Schnittstelle (#2509, #2515)"
