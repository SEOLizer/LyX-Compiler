#!/usr/bin/env bash
# tests/print_f64_test.sh — Print/PrintLn geben f64-Werte aus (Issue #1049).
#
# Der f64-Zweig in cg_genPrintMulti war ein Platzhalter: er emittierte die
# Konstante "0.0" und verwarf den ausgewerteten Wert. `PrintLn(1.5)` gab damit
# 0.0 aus — fehlerfrei übersetzt, fehlerfrei gelaufen, falscher Wert. Der
# Umwandler `_lyx_f64_to_str` war die ganze Zeit vorhanden und wurde von
# PrintFloat und vom %f-Fall in cg_genPrintf bereits benutzt.
#
# Geprüft wird deshalb der AUSGEGEBENE WERT. Ein Test, der nur auf „irgendeine
# Zahl mit Punkt" prüft, wäre auch mit dem Platzhalter grün gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, rumpf von main, erwartete ausgabe
  cat > "$TMP/c.lyx" <<EOF
import std.io;
fn main(): int64 {
$2
  return 0;
}
EOF
  rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 5 "$TMP/c" 2>&1)"
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

out "positiver Wert"      '  var a: f64 := 1.5;
  PrintLn(a);' '1.500000'

out "Null bleibt Null"    '  var a: f64 := 0.0;
  PrintLn(a);' '0.000000'

out "negativer Wert"      '  var a: f64 := 0.0 - 2.25;
  PrintLn(a);' '-2.250000'

out "ganzzahliger Wert"   '  var a: f64 := 7.0;
  PrintLn(a);' '7.000000'

# Der eigentliche Kern: zwei VERSCHIEDENE Werte müssen sich unterscheiden.
# Mit dem Platzhalter waren beide Zeilen identisch ("0.0").
out "zwei Werte sind verschieden" '  var a: f64 := 1.5;
  var b: f64 := 2.5;
  PrintLn(a); PrintLn(b);' '1.500000
2.500000'

# Gemischte Argumentliste: der f64-Zweig darf die anderen nicht stören.
out "gemischt mit int und Text" '  var a: f64 := 1.5;
  Print("v="); Print(a); Print(" n="); Print(42); PrintLn("");' 'v=1.500000 n=42'

# stderr-Variante nutzt denselben Zweig mit anderem Ausgabehelfer.
out "auf stderr"          '  var a: f64 := 1.5;
  EPrintLn(a);' '1.500000'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
