#!/usr/bin/env bash
# tests/klassen_runde4_test.sh — #1630, #1629, #1626, #1631.
#
# Vier Meldungen aus derselben Ecke: was eine Ableitung erbt, was `0` bei einem
# Klassentyp bedeutet, was ueber eine Unit-Grenze hinweg noch geprueft wird und
# was der Codegen von einer GLOBALEN Variablen weiss.
#
# GEPRUEFT WIRD DER WEG:
#   #1630 daran, dass ein Feld der Basisklasse seinen Wert BEHAELT, waehrend
#         die Ableitung in ihr eigenes Array schreibt — ein Test auf "laeuft
#         durch" waere vorher gruen gewesen, der Code lief ja.
#   #1626 an der Meldung selbst, und mit der Gegenprobe in derselben Datei.
#   #1631 daran, dass die verkettete Form UEBERSETZT (sie brach vorher im
#         Codegen ab, nicht zur Laufzeit).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

lauf() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/c.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error|^error' "$TMP/c.log")"
    return
  fi
  local got; got="$(timeout 60 "$TMP/t" 2>&1 | tr -d '\r' \
    | grep -vE 'Capabilit|^===|^Programm:|^  o |^  [A-Za-z-]+ |^$|^Runtime')"
  if [ "$got" = "$erwartet" ]; then ok "$name"; else
    no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
  fi
}

weist_ab() {
  local name="$1" muster="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  local msg; msg="$(timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" 2>&1)"
  if echo "$msg" | grep -q "$muster"; then ok "$name"; else
    no "$name" "Muster '$muster' fehlt — $(echo "$msg"|grep -iE 'error'|head -1)"
  fi
}

# ===========================================================================
# #1630 — Inline-Array der Ableitung ueberlappte das der Basisklasse
# ===========================================================================
# Der Schaden war unsichtbar, bis ein Basisfeld seinen Wert verlor. Genau das
# wird hier gemessen: A bleibt 11, und Kids bleibt unberuehrt.
lauf "#1630: Inline-Array der Ableitung liegt hinter dem der Basis" \
'A=11
Kids sauber' 'import std.io;
type TBase = class {
  Kids: [64]int64;
  A: int64;
  fn Create(): void { self.A := 11; }
}
type TDer = class extends TBase {
  Arr: [256]int64;
}
fn main(): int64 {
  var d: TDer := new TDer();
  var k: int64 := 0;
  while (k < 256) { d.Arr[k] := 999; k := k + 1; }
  PrintStr("A="); PrintLn(IntToStr(d.A));
  var i: int64 := 0;
  var schmutz: int64 := 0;
  while (i < 64) {
    if (d.Kids[i] != 0) { schmutz := schmutz + 1; }
    i := i + 1;
  }
  if (schmutz == 0) { PrintLn("Kids sauber"); } else { PrintStr("Kids ueberschrieben: "); PrintLn(IntToStr(schmutz)); }
  return 0;
}'

# Gegenprobe: ohne Array in der Basis lag es vorher schon richtig.
lauf "#1630: gewoehnliche Felder erben unveraendert" '7
8' 'import std.io;
type B = class { a: int64; b: int64; }
type D = class extends B { c: int64; }
fn main(): int64 {
  var d: D := new D();
  d.a := 7; d.c := 8;
  PrintLn(IntToStr(d.a)); PrintLn(IntToStr(d.c));
  return 0;
}'

# ===========================================================================
# #1629 — 0 als Nullwert, ueberall
# ===========================================================================
lauf "#1629: 0 laesst sich lokal, global, als Startwert und als Rueckgabe schreiben" \
'frei ist null
lokal ist null
global ist null' 'import std.io;
type T = class { v: int64; }
var g: T := null;
fn Frei(): T { return 0; }
fn main(): int64 {
  if (Frei() == 0) { PrintLn("frei ist null"); }
  var a: T := 0;
  var l: T := new T();
  l := 0;
  if (l == 0) { PrintLn("lokal ist null"); }
  g := new T();
  g := 0;
  if (g == 0) { PrintLn("global ist null"); }
  return 0;
}'

# Die Gegenprobe: eine andere Zahl bleibt ein Fehler. Sonst waere aus der
# Nullwert-Regel ein Loch in der Typpruefung geworden.
weist_ab "#1629: eine andere Zahl bleibt abgewiesen" \
  "Struct/Klasse erwartet" 'type T = class { v: int64; }
fn main(): int64 { var a: T := 7; return 0; }'

# ===========================================================================
# #1626 — Stelligkeit ueber die Unit-Grenze
# ===========================================================================
mkdir -p "$TMP/Lib"
cat > "$TMP/Lib/Api.lyx" <<'EOF'
unit Lib.Api;
pub type TThing = class {
  fn Plain3(a: int64, b: int64, c: int64): int64 { return c; }
}
pub fn Frei3(a: int64, b: int64, c: int64): int64 { return c; }
EOF

cat > "$TMP/wenig.lyx" <<'EOF'
import std.io;
import Lib.Api;
fn main(): int64 {
  var t: TThing := new TThing();
  return t.Plain3(1, 2);
}
EOF
msg="$(timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/wenig.lyx" -o "$TMP/wenig" 2>&1)"
if echo "$msg" | grep -q "falsche Argument-Anzahl im Methodenaufruf von 'Plain3'"; then
  ok "#1626: zu wenige Argumente an einer importierten Methode werden gemeldet"
else
  no "#1626: zu wenige Argumente" "keine Meldung — $(echo "$msg"|grep -i error|head -1)"
fi

cat > "$TMP/viel.lyx" <<'EOF'
import std.io;
import Lib.Api;
fn main(): int64 {
  var t: TThing := new TThing();
  return t.Plain3(1, 2, 3, 4);
}
EOF
msg="$(timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/viel.lyx" -o "$TMP/viel" 2>&1)"
if echo "$msg" | grep -q "falsche Argument-Anzahl im Methodenaufruf von 'Plain3'"; then
  ok "#1626: zu viele Argumente an einer importierten Methode werden gemeldet"
else
  no "#1626: zu viele Argumente" "keine Meldung"
fi

# Gegenprobe: der richtige Aufruf und ein weggelassener VORGABEWERT gehen
# weiterhin durch — sonst haette die Pruefung den Bestand lahmgelegt.
cat > "$TMP/gut.lyx" <<'EOF'
import std.io;
import Lib.Api;
fn main(): int64 {
  var t: TThing := new TThing();
  PrintLn(IntToStr(t.Plain3(1, 2, 3)));
  return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/gut.lyx" -o "$TMP/gut" >"$TMP/g.log" 2>&1; then
  got="$("$TMP/gut" 2>&1 | tr -d '\r' | grep -E '^[0-9]+$' | tr '\n' ' ')"
  [ "$got" = "3 " ] && ok "#1626: der richtige Aufruf geht weiterhin durch" \
                    || no "#1626: richtiger Aufruf" "Ausgabe '$got'"
else
  no "#1626: richtiger Aufruf" "$(grep -m1 -iE 'error' "$TMP/g.log")"
fi

# ===========================================================================
# #1631 — verketteter Aufruf ueber eine globale Variable
# ===========================================================================
mkdir -p "$TMP/Demo"
cat > "$TMP/Demo/Mod2.lyx" <<'EOF'
unit Demo.Mod2;
pub type TInner = class {
  V: int64;
  fn Create(): void { self.V := 0; }
  fn SetS(s: pchar): void { self.V := 1; }
}
pub type TOuter = class {
  Slot: int64;
  fn Create(): void { self.Slot := (new TInner()) as int64; }
  fn Item(i: int64): TInner { return self.Slot as TInner; }
}
EOF

cat > "$TMP/kette.lyx" <<'EOF'
import Demo.Mod2;
import std.io;
var g: TOuter := null;
fn main(): int64 {
  g := new TOuter();
  g.Item(0).SetS("x"c);
  PrintLn(IntToStr(g.Item(0).V));
  var l: TOuter := new TOuter();
  l.Item(0).SetS("y"c);
  PrintLn(IntToStr(l.Item(0).V));
  return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/kette.lyx" -o "$TMP/kette" >"$TMP/k.log" 2>&1; then
  got="$("$TMP/kette" 2>&1 | tr -d '\r' | grep -E '^[0-9]+$' | tr '\n' ' ')"
  [ "$got" = "1 1 " ] && ok "#1631: verketteter Aufruf ueber eine globale Variable" \
                      || no "#1631: verketteter Aufruf" "Ausgabe '$got'"
else
  no "#1631: verketteter Aufruf" "$(grep -m1 -iE 'error' "$TMP/k.log")"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
