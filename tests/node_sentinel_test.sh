#!/usr/bin/env bash
# tests/node_sentinel_test.sh — Issue #989.
#
# Der AST verwendet -1 als Marker fuer "kein Kind" (Parser._alloc setzt c0..c3
# und next auf -1). Etliche Baumlaeufe rufen die Knoten-Zugriffsfunktionen
# trotzdem ungeprueft mit -1 auf. Ohne Sentinel liegt nodes + (-1)*88 UNTER der
# Knoten-Arena: liegt dort zufaellig noch eine gemappte Seite, wird still
# Garbage gelesen; faellt der Puffer an einen Mapping-Anfang, faultet der
# Compiler mit SIGSEGV.
#
# Sichtbar wurde das als scheinbare Groessengrenze: JEDE Zwei-Zeilen-Ergaenzung
# in src/sema.lyx brach den Selbstbau (unveraendert 3/3 gruen, mit Zusatz 0/5),
# waehrend dieselbe Ergaenzung in parser.lyx oder codegen_x86.lyx harmlos war.
# Der Parser alloziert den Knotenpuffer jetzt um einen Knoten groesser und laesst
# self.nodes hinter einen Sentinel zeigen, dessen Kinder alle -1 sind.
#
# Dieser Test prueft das Verhalten, das damals brach: der Compiler muss eine
# vergroesserte sema.lyx uebersetzen koennen. Er baut NICHT den ganzen Compiler
# (zu langsam fuer make test), sondern prueft den Sentinel direkt am Verhalten
# von Programmen, die Baumlaeufe ueber leere Kindlisten ausloesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

runs() { # name, quelltext, erwarteter exit
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c"
  out=$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    no "$1" "compile fehlgeschlagen: $(echo "$out" | grep -iE 'error' | head -1)"; return
  fi
  timeout 5 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$1 (=$rc)"; else no "$1" "exit=$rc erwartet $3"; fi
}

# Konstrukte mit leeren Kindlisten: leerer Funktionsrumpf, leerer Block,
# parameterlose Funktion, leerer Struct-/Klassenkoerper, Schleife ohne Rumpf.
runs "leere Rumpfe und Bloecke" 'fn nix(): void { }
fn leer(): int64 {
  { }
  var i: int64 := 0;
  while (i < 3) { i := i + 1; }
  nix();
  return i;
}
fn main(): int64 { return leer() + 39; }' 42

runs "Klasse ohne Felder, Methode ohne Parameter" 'type E = class { fn wert(): int64 { return 42; } };
fn main(): int64 { var e: E := new E(); return e.wert(); }' 42

# Der eigentliche Regressionsschutz: eine grosse Uebersetzungseinheit muss
# uebersetzbar bleiben. Ohne Sentinel haing das an der Speicherlage.
gen="$TMP/big.lyx"
{
  echo 'fn main(): int64 {'
  echo '  var acc: int64 := 0;'
  for i in $(seq 1 2000); do
    echo "  var v$i: int64 := $i;"
    echo "  if (v$i < 0) { acc := acc + 1; }"
  done
  echo '  return acc;'
  echo '}'
} > "$gen"
rm -f "$TMP/big"
if (cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$gen" -o "$TMP/big" >/dev/null 2>&1) && [ -f "$TMP/big" ]; then
  timeout 10 "$TMP/big" >/dev/null 2>&1
  if [ $? -eq 0 ]; then ok "grosse Einheit (2000 Deklarationen)"; else no "grosse Einheit" "Laufzeitfehler"; fi
else
  no "grosse Einheit (2000 Deklarationen)" "compile fehlgeschlagen"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
