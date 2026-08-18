#!/usr/bin/env bash
# tests/laute_abbrueche_runde10_test.sh — #1642 und #1643.
#
# Zwei Abstuerze mit derselben Form: der Aufruf trifft eine 0 und springt oder
# liest ins Leere. Ein Segfault nennt weder die Stelle noch den Grund.
#
# GEPRUEFT WIRD DER WEG:
#   #1642 am INHALT des frisch angelegten Arrays (cap/len), nicht nur daran,
#         dass es nicht mehr abstuerzt — die 0 sah ja aus wie ein Array.
#   #1643 an der MELDUNG: sie muss Klasse und Methode nennen. Ein Test auf
#         "bricht ab" waere auch beim Segfault gruen gewesen.

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
  [ "$got" = "$erwartet" ] && ok "$name" || no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
}

# ===========================================================================
# #1642 — das leere Array-Literal
# ===========================================================================
# Der Kern: `[]` lieferte eine 0. Geprueft wird der Kopf, nicht nur der Lauf.
lauf "#1642: [] legt wirklich ein Array an (cap/len im Kopf)" \
'nicht null
1024
0' 'fn main(): int64 {
  var a: array := [];
  var p: int64 := a as int64;
  if (p != 0) { PrintStr("nicht null\n"); } else { PrintStr("NULL\n"); }
  PrintInt(peek64(p));      PrintStr("\n");
  PrintInt(peek64(p + 8));  PrintStr("\n");
  return 0;
}'

lauf "#1642: len() auf dem leeren Array" '0' 'fn main(): int64 {
  var a: array := [];
  PrintInt(len(a));
  PrintStr("\n");
  return 0;
}'

# Der Repro aus dem Bericht: len VOR dem ersten push war der Absturz, danach
# lief es — deshalb beide Reihenfolgen.
lauf "#1642: len vor und nach push" \
'0
1
2
10' 'fn main(): int64 {
  var a: array := [];
  PrintInt(len(a)); PrintStr("\n");
  push(a, 10);
  PrintInt(len(a)); PrintStr("\n");
  push(a, 20);
  PrintInt(len(a)); PrintStr("\n");
  PrintInt(a[0]);   PrintStr("\n");
  return 0;
}'

# Gegenprobe: die Form OHNE Initialisierer war seit #1177 in Ordnung.
lauf "#1642: var a: array; unveraendert" '0' 'fn main(): int64 {
  var a: array;
  PrintInt(len(a));
  PrintStr("\n");
  return 0;
}'

# Gegenprobe: ein Literal MIT Elementen bleibt, wie es war.
lauf "#1642: Literal mit Elementen unveraendert" \
'3
7' 'fn main(): int64 {
  var a: array := [7, 8, 9];
  PrintInt(len(a)); PrintStr("\n");
  PrintInt(a[0]);   PrintStr("\n");
  return 0;
}'

# ===========================================================================
# #1643 — Aufruf einer abstrakten Methode
# ===========================================================================
# Die Meldung muss Klasse UND Methode nennen; der Abbruch ist definiert (1).
printf '%s\n' 'type Animal = class {
  abstract fn Speak(): int64;
};
fn main(): int64 {
  var a: Animal := new Animal();
  return a.Speak();
}' > "$TMP/ab.lyx"
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/ab.lyx" -o "$TMP/ab" >"$TMP/c.log" 2>&1; then
  out="$(timeout 30 "$TMP/ab" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then
    no "#1643: definierter Abbruch statt Segfault" "rc=$rc (Absturz)"
  elif echo "$out" | grep -q "Animal.Speak"; then
    ok "#1643: der Abbruch nennt Klasse und Methode (rc=$rc)"
  else
    no "#1643: Meldung" "rc=$rc, Ausgabe: $(echo "$out"|head -1)"
  fi
else
  no "#1643: abstrakter Aufruf" "uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/c.log")"
fi

# Gegenprobe: eine UEBERSCHRIEBENE Methode laeuft normal — direkt und ueber
# den Basistyp (also durch die VMT, deren Slot der Rumpf jetzt belegt).
lauf "#1643: ueberschriebene Methode unveraendert, auch virtuell" \
'42
42
1' 'import std.io;
type Animal = class {
  abstract fn Speak(): int64;
  fn Name(): int64 { return 1; }
};
type Dog = class extends Animal {
  override fn Speak(): int64 { return 42; }
};
fn main(): int64 {
  var d: Dog := new Dog();
  PrintLn(IntToStr(d.Speak()));
  var a: Animal := d as Animal;
  PrintLn(IntToStr(a.Speak()));
  PrintLn(IntToStr(d.Name()));
  return 0;
}'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
