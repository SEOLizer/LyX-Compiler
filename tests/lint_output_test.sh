#!/usr/bin/env bash
# tests/lint_output_test.sh — #1137: der Linter meldet lesbar.
#
# Der Befund im Issue lautete "meldet nichts". Tatsaechlich meldete er sehr
# wohl — nur unbrauchbar:
#
#   datei:: W004 function should use PascalCase naming
#   datei:: W006 unreachable code after return statement mai
#
# Vier Fehler kamen zusammen:
#
#   1. Die ZEILENNUMMER ging ueber `PrintInt` auf STDOUT, waehrend der Rest der
#      Meldung auf stderr geht. Auf stderr allein blieb "datei::" uebrig, die
#      Ziffern standen zusammenhanglos in der Programmausgabe.
#   2. Zehn Meldungstexte wurden mit handgezaehlter Laenge geschrieben, acht
#      davon falsch — mal abgeschnitten, mal ueber das Ende hinaus.
#   3. `lnt_warn` bekam von den einen Aufrufern einen KNOTEN, von den anderen
#      eine fertige ZEILE, schickte aber alles durch `lnt_lineOf` — die Zeile
#      wurde also als Knotenindex gedeutet.
#   4. Und die Wurzel: im Parser bekam JEDES Token die Zeile des VORIGEN
#      (`_tokenize` las `lx.line` vor `Next()`). Innerhalb einer Zeile faellt
#      das nicht auf, beim ersten Token einer neuen Zeile aber schon — um so
#      viele Zeilen, wie dazwischen leer waren. Das betraf jede Meldung zu
#      einer Deklaration, auch die von sema.
#
# Dazu zwei Pruefungen, die IMMER meldeten und damit reines Rauschen waren:
# W004 nahm `main` nicht aus (Zeigervergleich statt Inhalt), W016 verglich
# Funktions- gegen Modulnamen und konnte nie treffen.
#
# Geprueft wird die MELDUNG: Zeilennummer, vollstaendiger Text, richtiger
# Strom, und dass die Gegenprobe schweigt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- Ein Programm mit bekannten Verstoessen, Zeilen genau abgezaehlt -----
cat > "$TMP/a.lyx" <<'EOF'
import src.std.io;



fn alpha(): int64 { var u: int64 := 1; return 0; }
fn main(): int64 {
  return alpha();
  PrintStrLn("nie");
}
EOF
err="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" --lint a.lyx -o "$TMP/a" 2>&1 >/dev/null)"
out="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" --lint a.lyx -o "$TMP/a" 2>/dev/null)"

# W001 (unused u) und W004 (alpha) stehen in Zeile 5, W006 in Zeile 8.
case "$err" in
  *":5: W004"*) ok "W004 nennt Zeile 5" ;;
  *) no "W004 nennt Zeile 5" "$(printf '%s' "$err" | grep W004 || echo 'keine W004-Meldung')" ;;
esac
case "$err" in
  *":5: W001"*) ok "W001 nennt Zeile 5" ;;
  *) no "W001 nennt Zeile 5" "$(printf '%s' "$err" | grep W001 || echo 'keine W001-Meldung')" ;;
esac
case "$err" in
  *":8: W006"*) ok "W006 nennt Zeile 8" ;;
  *) no "W006 nennt Zeile 8" "$(printf '%s' "$err" | grep W006 || echo 'keine W006-Meldung')" ;;
esac

# Kein "datei::" mehr — daran erkannte man die fehlende Zeilennummer.
case "$err" in
  *".lyx::"*) no "Zeilennummer fehlt nicht mehr" "'datei::' steht noch in der Meldung" ;;
  *) ok "Zeilennummer fehlt nicht mehr" ;;
esac

# Der Meldungstext ist vollstaendig (vorher: "... statement mai").
case "$err" in
  *"unreachable code after return statement"*) ok "Meldungstext vollstaendig" ;;
  *) no "Meldungstext vollstaendig" "abgeschnitten" ;;
esac

# Die Lint-Meldungen gehoeren auf stderr, nicht in die Programmausgabe.
case "$out" in
  *"W001"*|*"W004"*|*"W006"*) no "Lint-Meldungen nur auf stderr" "stehen auf stdout" ;;
  *) ok "Lint-Meldungen nur auf stderr" ;;
esac

# Und die Ziffern der Zeilennummer duerfen nicht mehr einzeln auf stdout landen.
case "$out" in
  *"lyxc "*) ok "stdout traegt weiter die Compilerausgabe" ;;
  *) no "stdout traegt weiter die Compilerausgabe" "leer?" ;;
esac

# --- `--lint` unterdrueckt keine anderen Warnungen -----------------------
# Der Issue-Text vermutete das; tatsaechlich stand die Grant-Warnung immer auf
# stdout und die Lint-Meldungen auf stderr.
case "$out" in
  *"Import ohne explizites grant"*) ok "Grant-Warnung bleibt bei --lint" ;;
  *) no "Grant-Warnung bleibt bei --lint" "fehlt" ;;
esac

# --- Zwei Dauer-Melder sind weg -----------------------------------------
cat > "$TMP/b.lyx" <<'EOF'
import src.std.io;
fn Alpha(): int64 { return 1; }
fn main(): int64 { PrintLn(Alpha()); return 0; }
EOF
errB="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" --lint b.lyx -o "$TMP/b" 2>&1 >/dev/null)"

# `main` MUSS klein geschrieben sein — der Codegen sucht genau diesen Namen.
case "$errB" in
  *W004*) no "W004 nimmt main aus" "meldet trotzdem: $(printf '%s' "$errB" | grep W004)" ;;
  *) ok "W004 nimmt main aus" ;;
esac

# W016 meldete jeden Import, auch den benutzten.
case "$errB" in
  *W016*) no "W016 meldet nicht mehr blind" "meldet trotzdem" ;;
  *) ok "W016 meldet nicht mehr blind" ;;
esac

# Ein sauberes Programm erzeugt keine einzige Lint-Meldung. (Auf stderr steht
# ausserdem der LCBS-Audit — gefiltert wird deshalb auf die W-Codes.)
lintB="$(printf '%s\n' "$errB" | grep -E ' W[0-9]{3} ' || true)"
if [ -z "$lintB" ]; then ok "sauberes Programm meldet nichts"
else no "sauberes Programm meldet nichts" "$lintB"; fi

# --- Die Zeilennummern stimmen auch fuer sema ----------------------------
# Dieselbe Wurzel (Token trug die Zeile des vorigen) verschob auch
# sema-Meldungen zu Deklarationen.
cat > "$TMP/c.lyx" <<'EOF'
import src.std.io;



fn alpha(): int64 { var x: int64 := 1; }
fn main(): int64 { return alpha(); }
EOF
errC="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" c.lyx -o "$TMP/c" 2>&1)"
case "$errC" in
  *"(line 5)"*) ok "sema nennt Zeile 5 fuer die Funktion" ;;
  *) no "sema nennt Zeile 5 fuer die Funktion" "$(printf '%s' "$errC" | grep -i 'sema error' | head -1)" ;;
esac

# --- Gegenprobe: ohne --lint keine Lint-Meldungen ------------------------
errD="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" a.lyx -o "$TMP/d" 2>&1 >/dev/null)"
case "$errD" in
  *W001*|*W004*|*W006*) no "ohne --lint schweigt der Linter" "meldet trotzdem" ;;
  *) ok "ohne --lint schweigt der Linter" ;;
esac

errE="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" --no-lint a.lyx -o "$TMP/e" 2>&1 >/dev/null)"
case "$errE" in
  *W001*|*W004*|*W006*) no "--no-lint schaltet ab" "meldet trotzdem" ;;
  *) ok "--no-lint schaltet ab" ;;
esac

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
