#!/bin/bash
# #1723 — Aufruf eines Funktionszeigers aus einer MODULVARIABLEN.
#
# Der Lowerer konnte globale Variablen laengst LESEN (globalNameBuf, wenn eine
# als Wert auftritt), fragte beim AUFRUF aber nicht danach. Der Name fiel
# deshalb bis zur Abbruchmeldung durch: "unbekannter Builtin/Funktion: g_cb".
# Zuweisung und Vergleich derselben Variablen gingen, nur der Aufruf nicht.
#
# Auf dem x86-Weg war das #1574. Dieselbe Frage, zwei Stellen, eine davon
# nachgezogen — in diesem Compiler ein wiederkehrendes Muster.
#
# Geprueft wird der gemeldete Fall UND die vier, die schon vorher gingen: ein
# Fix, der den Aufruf ueber Modulvariablen erlaubt und dabei die Local-Regel
# umstoesst, waere kein Fortschritt. Deshalb ist der Verdeckungsfall dabei.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; F=$((F+1)); }

# baut <name> <quelltext> — gegen lyxos, muss LYX! liefern
baut() {
  printf '%s\n' "$2" > "$TMP/t.lyx"
  if timeout 300 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/t.lyx" -o "$TMP/t.out" >"$TMP/l" 2>&1; then
    if [ "$(head -c4 "$TMP/t.out")" = "LYX!" ]; then ok "$1"; else bad "$1" "kein LYX!-Container"; fi
  else
    bad "$1" "$(grep -oE 'unbekannter Builtin.*|sema error.*' "$TMP/l" | head -1)"
  fi
}

VOR='pub type TCb = fn(x: int64): int64;
fn Verdopple(x: int64): int64 { return x * 2; }'

baut "#1723 Aufruf ueber Modulvariable" "$VOR
var g_cb: TCb;
fn main(): int64 { g_cb := Verdopple; if (g_cb == 0) { return 1; } return g_cb(21); }"

baut "Modulvariable zuweisen und pruefen, ohne Aufruf" "$VOR
var g2: TCb;
fn main(): int64 { g2 := Verdopple; if (g2 == 0) { return 1; } return 0; }"

baut "Aufruf ueber lokale Variable" "$VOR
fn main(): int64 { var cb: TCb := Verdopple; return cb(21); }"

baut "Modulvariable ueber lokale Kopie" "$VOR
var g3: TCb;
fn main(): int64 { g3 := Verdopple; var c: TCb := g3; return c(21); }"

baut "Aufruf ueber Klassenfeld" "$VOR
pub type THalter = class {
  Cb: TCb;
  fn Ruf(x: int64): int64 { if (self.Cb == 0) { return 0; } return self.Cb(x); }
};
fn main(): int64 { var h: THalter := new THalter(); h.Cb := Verdopple; return h.Ruf(21); }"

# Die Local-Regel darf der Fix nicht umstossen: ein gleichnamiges Local
# verdeckt die Modulvariable, wie ueberall sonst auch.
baut "gleichnamiges Local verdeckt die Modulvariable" "$VOR
fn Verdreifache(x: int64): int64 { return x * 3; }
var f: TCb;
fn main(): int64 { f := Verdopple; var f2: TCb := Verdreifache; return f(21) + f2(1); }"

# Ergebnis auf dem Linux-Weg: der Aufruf muss auch RECHNEN, nicht nur bauen.
printf '%s\n' "$VOR
var g_cb: TCb;
fn main(): int64 { g_cb := Verdopple; return g_cb(21); }" > "$TMP/r.lyx"
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r.out" >"$TMP/l" 2>&1; then
  "$TMP/r.out"; rc=$?
  if [ "$rc" -eq 42 ]; then ok "Linux: Aufruf ueber Modulvariable liefert 42"
  else bad "Linux: Ergebnis" "exit=$rc statt 42"; fi
else
  bad "Linux: uebersetzt nicht" "$(grep -i error "$TMP/l" | head -1)"
fi

echo "Ergebnis: $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
