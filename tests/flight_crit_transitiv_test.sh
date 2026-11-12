#!/bin/bash
# #1701 — @flight_crit prueft jetzt den AUFRUFGRAPH, nicht nur den eigenen
# Rumpf. Bis 1.1.3P sah die Pruefung nur die Knoten der annotierten Funktion;
# eine Allokation eine Ebene tiefer war von dort aus nicht zu sehen.
#
# Der Test prueft beide Richtungen: dass die neuen Faelle MELDEN, und —
# genauso wichtig — dass harmlose Aufrufe weiter durchgehen. Eine Regel, die
# jeden `peek64` beanstandet, waere im Alltag unbrauchbar und der Bestand
# haette sie sofort abgeschaltet.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

meldet() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/c.lyx"
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "$1 — uebersetzt klaglos"; return; fi
  if echo "$msg" | grep -qF "$3"; then ok "$1"
  else bad "$1 — andere Meldung: $(echo "$msg" | grep -i error | head -1)"; fi
}

schweigt() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" > "$TMP/b.log" 2>&1; then
    bad "$1 — faelschlich gemeldet: $(grep -oE 'sema error.*' "$TMP/b.log" | head -1)"; return
  fi
  chmod +x "$TMP/c"; got="$(timeout 20 "$TMP/c" 2>&1 | head -1)"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 — '$got' erwartet '$3'"; fi
}

# --- 1) Der Fall aus der Meldung: ein Helfer alloziert ---------------------
meldet "Helferaufruf, der alloziert" 'import std.io;
fn Hilf(): int64 { var p: int64 := alloc(32); free(p, 32); return 7; }
@flight_crit
fn Regel(): int64 { return Hilf(); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' \
  "Speicheranforderung in einer Funktion, die aus einer @flight_crit-Funktion gerufen wird"

# --- 2) Auch zwei Ebenen tiefer ------------------------------------------
#    Ein Test mit nur einer Ebene wuerde nicht zeigen, dass wirklich der GRAPH
#    abgelaufen wird und nicht bloss die direkten Aufrufe.
meldet "zwei Ebenen tiefer" 'import std.io;
fn Tief(): int64 { var p: int64 := alloc(16); free(p, 16); return 3; }
fn Mitte(): int64 { return Tief(); }
@flight_crit
fn Regel(): int64 { return Mitte(); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' \
  "Speicheranforderung in einer Funktion, die aus einer @flight_crit-Funktion gerufen wird"

# --- 3) Sprung ueber einen Funktionszeiger --------------------------------
#    Das Sprungziel steht zur Uebersetzungszeit nicht fest, die Laufzeit also
#    auch nicht — genau die Frage, die das Attribut beantworten soll.
meldet "Sprung ueber einen Funktionszeiger" 'import std.io;
pub type TFn = fn(a: int64): int64;
fn Doppelt(a: int64): int64 { return a * 2; }
@flight_crit
fn Regel(): int64 { var f: TFn := Doppelt; return f(21); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' \
  "indirekter Aufruf unter @flight_crit nicht erlaubt"

# --- 4) Zeichenketten-Builtins fordern Speicher an ------------------------
meldet "IntToStr im Regelzyklus" 'import std.io;
@flight_crit
fn Regel(v: int64): pchar { return IntToStr(v); }
fn main(): int64 { PrintLn(Regel(7)); return 0; }' \
  "Speicheranforderung unter @flight_crit nicht erlaubt"

# --- 5) Gegenprobe: harmlose Builtins und reines Rechnen bleiben erlaubt ---
schweigt "peek/poke und Rechnen bleiben erlaubt" 'import std.io;
@flight_crit
fn Regel(p: int64): int64 {
  var s: int64 := 0;
  var i: int64 := 0;
  while (i < 4) { s := s + peek64(p + i * 8); i := i + 1; }
  poke64(p, s);
  return s;
}
fn main(): int64 {
  var b: int64 := alloc(32);
  poke64(b, 1); poke64(b + 8, 2); poke64(b + 16, 3); poke64(b + 24, 4);
  PrintLn(IntToStr(Regel(b)));
  return 0;
}' "10"

# --- 6) Gegenprobe: ein Helfer OHNE Allokation bleibt erlaubt -------------
#    Ohne diesen Fall waere eine Regel, die jeden Aufruf beanstandet, gruen.
schweigt "Helfer ohne Allokation bleibt erlaubt" 'import std.io;
fn Rechne(a: int64): int64 { return a * 2 + 1; }
@flight_crit
fn Regel(): int64 { return Rechne(20); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' "41"

# --- 7) Gegenseitige Rekursion darf die Pruefung nicht aufhaengen ---------
#    Geprueft wird, dass der Compiler TERMINIERT und nichts meldet — der
#    Rueckgabewert ist nur das Beiwerk, das zeigt, dass das Programm laeuft.
#    A(4)->B(3)->A(2)->B(1)->A(0) endet bei 0.
schweigt "gegenseitige Rekursion terminiert" 'import std.io;
fn A(n: int64): int64 { if (n <= 0) { return 0; } return B(n - 1); }
fn B(n: int64): int64 { if (n <= 0) { return 1; } return A(n - 1); }
@flight_crit
fn Regel(): int64 { return A(4); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' "0"

# --- 8) Ein Tippfehler darf nur EINE Meldung erzeugen ---------------------
#    "nicht aufloesbar" ist mehrdeutig: Funktionszeiger oder Vertipper. Wer
#    hier pauschal meldet, verdoppelt jede Namensmeldung.
printf '%s\n' 'import std.io;
@flight_crit
fn Regel(): int64 { return Gibtsnicht(1); }
fn main(): int64 { PrintLn(IntToStr(Regel())); return 0; }' > "$TMP/t.lyx"
n="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" 2>&1 | grep -ci "error")"
if [ "$n" -eq 1 ]; then ok "Tippfehler erzeugt genau eine Meldung"
else bad "Tippfehler erzeugt $n Meldungen statt einer"; fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
