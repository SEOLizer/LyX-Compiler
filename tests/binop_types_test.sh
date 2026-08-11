#!/usr/bin/env bash
# tests/binop_types_test.sh — #1143: Typen der binaeren Operatoren.
#
# Das Gegenstueck zu #1135: dort Zuweisung, Rueckgabe und Argumente, hier die
# OPERATOREN selbst. `true + 1` ergab 2, `"abc" * 2` eine Adresse mal zwei --
# beides ohne Meldung.
#
# ZUR PRAEMISSE DES ISSUES: `"a" + "b"` VERKETTET, und zwar richtig. Der
# Codegen erkennt den Fall und emittiert StrConcat;
# tests/regression/test_string_format.lyx lebt davon. Der Repro
# `PrintLn("Wert: " + IntToStr(7))` gab nur deshalb eine Zahl aus, weil
# `cg_inferPrintType` die Verkettung nicht als Zeichenkette einstufte und
# Print sie als Ganzzahl ausgab -- der Fehler sass im DRUCKER, nicht im
# Operator. Beides ist jetzt in Ordnung: die Verkettung bleibt zugelassen und
# Print gibt sie als Text aus.
#
# Ebenso gewollt: `bool ^ bool` ist boolesche Algebra
# (tests/regression/operators/simple_xor.lyx). Auch & und | auf zwei
# Wahrheitswerten bleiben zugelassen.
#
# ZUGELASSEN bleibt die ZEIGERARITHMETIK `pchar + int64` / `pchar - int64`:
# `peek8(src + i)` ist die uebliche zeichenweise Iteration. Ein Messlauf ueber
# std/, src/, data/ und examples/ fand davon 807 Fundstellen -- und KEINE
# einzige der Formen, die hier abgewiesen werden. Die Regel ist scharf, ohne
# den Bestand zu brechen; die Zahl der sema-Meldungen im Bestand ist vor und
# nach der Aenderung dieselbe (727).
#
# NICHT geprueft wird gemischte int/f64-Arithmetik. `10 - 2.5` rechnet falsch,
# das ist #1212 und dort zu entscheiden -- eine Meldung hier wuerde dem
# vorgreifen. Der letzte Abschnitt haelt das ausdruecklich fest.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, rumpf, erwarteter meldungsteil
  printf 'import src.std.io;\nfn main(): int64 {\n%s\nreturn 0;\n}\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

out() { # name, rumpf, erwartete ausgabe
  printf 'import src.std.io;\nfn main(): int64 {\n%s\nreturn 0;\n}\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# --- Der Repro aus dem Issue: Print gibt die Verkettung als TEXT aus -----
out "Repro: PrintLn einer Verkettung" 'PrintLn("Wert: " + IntToStr(7));' 'Wert: 7'

out "PrintLn zweier Literale" 'PrintLn("a" + "b");' 'ab'

out "Print ohne Zeilenumbruch" 'Print("a" + "b"); Print("\n");' 'ab'

# Gegenprobe: eine Zahl bleibt eine Zahl -- die Erkennung darf nicht alles
# als Zeichenkette ausgeben.
out "PrintLn einer Zahl unveraendert" 'PrintLn(20 + 22);' '42'

out "PrintLn eines Zeigerausdrucks bleibt Zahl" \
  'var s: pchar := "abcd"; PrintLn(peek8(s + 1));' '98'

# Die Verkettung selbst war nie kaputt -- nur ihre Ausgabe.
out "Verkettung in eine Variable" \
  'var s: pchar := "Hello" + " World"; PrintStrLn(s);' 'Hello World'

out "Verkettung mit Builtin-Ergebnis" \
  'PrintStrLn("x" + FloatToStr(1.5));' 'x1.500000'

# --- Die weiteren Faelle der Tabelle im Issue ----------------------------
fails "Zeichenkette minus Zeichenkette" 'PrintLn("abc" - "a");' \
  "Operator -: pchar und pchar"

fails "Zeichenkette mal Zahl" 'PrintLn("abc" * 2);' \
  "Operator *: pchar und int64"

fails "bool plus Zahl" 'PrintLn(true + 1);' \
  "Operator +: bool und int64"

fails "Zahl plus bool" 'PrintLn(1 + true);' \
  "Operator +: int64 und bool"

# Bit-Operatoren zaehlen mit, sobald ein Wahrheitswert mit einer ZAHL
# vermengt wird. Zwei Wahrheitswerte unter sich bleiben zugelassen -- das ist
# boolesche Algebra.
fails "bool & Zahl" 'PrintLn((true & 1) as int64);' \
  "Operator &: bool und int64"

fails "Zeichenkette geschoben" 'PrintLn("a" << 2);' \
  "Operator <<: pchar und int64"

fails "Zeichenkette modulo" 'PrintLn("abc" % 2);' \
  "Operator %: pchar und int64"

fails "Zeichenkette geteilt" 'PrintLn("abc" / 2);' \
  "Operator /: pchar und int64"

# --- Was weiterhin uebersetzen MUSS --------------------------------------
# Zeigerarithmetik: 807 Fundstellen im Bestand.
out "Zeigerarithmetik pchar + int64" \
  'var s: pchar := "abcd"; var i: int64 := 1; PrintLn(peek8(s + i));' '98'

out "Zeigerarithmetik pchar - int64" \
  'var s: pchar := "abcd"; var i: int64 := 0; PrintLn(peek8(s - i));' '97'

out "Zeigerarithmetik int64 + pchar" \
  'var s: pchar := "abcd"; var i: int64 := 1; PrintLn(peek8(i + s));' '98'

# Boolesche Algebra: tests/regression/operators/simple_xor.lyx lebt davon.
out "bool ^ bool bleibt zulaessig" \
  'var a: bool := true; var b: bool := false; if (a ^ b) { PrintStrLn("xor"); } return 0;' 'xor'

out "bool & bool bleibt zulaessig" \
  'var a: bool := true; var b: bool := true; if (a & b) { PrintStrLn("und"); } return 0;' 'und'

# StrConcat bleibt der ausdrueckliche Weg.
out "StrConcat verkettet" 'PrintStrLn(StrConcat("Wert: ", IntToStr(7)));' 'Wert: 7'

out "gewoehnliche Ganzzahlrechnung" 'PrintLn(20 + 22);' '42'

out "Gleitkomma unter sich" 'PrintLn((1.5 + 2.5) as int64);' '4'

# Der `as`-Cast ist die ausdrueckliche Umwandlung -- er darf nicht bemaengelt
# werden, sonst gaebe es keinen Weg, die Adressen doch zu verrechnen.
out "as-Cast oeffnet den Weg" \
  'var a: pchar := "x"; var b: pchar := "y"; PrintLn(((b as int64) - (a as int64)) != 0 as int64);' '1'

# Vergleiche bleiben unberuehrt: zwei Zeiger zu vergleichen ist zulaessig.
out "Zeigervergleich unveraendert" \
  'var a: pchar := "x"; var b: pchar := a; if (a == b) { PrintStrLn("gleich"); } return 0;' 'gleich'

out "Wahrheitswerte vergleichen" \
  'var a: bool := true; if (a == true) { PrintStrLn("ja"); } return 0;' 'ja'

# Unbestimmtes bleibt still -- dieselbe Zurueckhaltung wie bei #1135. `alloc`
# liefert eine Zahl, deren Typ die Ableitung nicht kennt; eine Meldung waere
# ein Fehlalarm.
out "Unbestimmtes wird nicht gemeldet" \
  'var p: int64 := alloc(16); poke64(p + 8, 7); PrintLn(peek64(p + 8));' '7'

# --- Gemischte int/f64-Arithmetik: entschieden in #1212 -------------------
# Bis 1.0.15E rechnete `1.5 + 1` falsch und ergab 1: die ganzzahlige Seite
# ging als Bitmuster eines double in die Rechnung. Dieser Testfall hielt den
# Stand bewusst fest, "damit die Aenderung dort auffaellt" — und hat genau das
# getan, als #1212 umgesetzt wurde.
#
# Entschieden ist HOCHZIEHEN, nicht melden: die ganzzahlige Seite wird nach
# f64 gewandelt. 1.5 + 1 = 2.5, `as int64` schneidet auf 2 ab.
out "gemischte int/f64-Arithmetik zieht hoch (#1212)" \
  'PrintLn((1.5 + 1) as int64);' '2'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
