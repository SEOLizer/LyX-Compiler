#!/usr/bin/env bash
# tests/new_speicher_test.sh — `new` belegt die Objektgroesse, nicht eine Seite (#1836).
#
# Bis 1.1.12B emittierte der Codegen fuer JEDE Instanziierung ein eigenes
# mmap ueber 4096 Byte — unabhaengig von der Objektgroesse. Ein Objekt mit
# einem einzigen int64-Feld kostete damit 4 KB residenten Speicher und einen
# Syscall. Gemessen am Repro aus dem Issue: 100.000 Objekte brauchten 400 MB
# und 1,34 s, waehrend 100.000 x alloc(16) mit 12 KB und 7 ms auskamen.
#
# Jetzt wird aus einem 64-KB-Block herausgegeben (Bump-Allokator, CG_HEAP_PTR /
# CG_HEAP_END). Keine Freiliste — `dispose` gibt ohnehin nichts zurueck —, und
# weil nichts wiederverwendet wird, ist jede Stelle frisch aus mmap und damit
# GENULLT: ein Konstruktor, der ein Feld nicht setzt, findet dort weiterhin 0.
#
# GEMESSEN WIRD DIE WIRKUNG, nicht die Umsetzung: der Abstand zweier Objekte
# und der Speicherbedarf unter Last. Ein Test, der nur prueft "new liefert
# einen Zeiger", waere auch vorher gruen gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }
ulimit -c 0 2>/dev/null

bau() {  # quelltext -> $TMP/p
  printf '%s' "$1" > "$TMP/p.lyx"
  timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/p.log" 2>&1
}

lauf() {  # name, quelltext, erwartete ausgabe
  if ! bau "$2"; then no "$1" "uebersetzt nicht: $(grep -im1 error "$TMP/p.log")"; return; fi
  local got; got="$(timeout 60 "$TMP/p" 2>&1)"
  if [ "$got" = "$3" ]; then ok "$1 ($got)"; else no "$1" "'$got' erwartet '$3'"; fi
}

# --- 1. Der Abstand zweier Objekte ---------------------------------------
# Vorher 4096, jetzt die Objektgroesse. Geprueft wird gegen eine grosszuegige
# Schranke: entscheidend ist "nicht seitenweise", nicht die genaue Zahl.
if bau 'import std.io;
type T = class { A: int64; fn Create(): void { self.A := 0; } }
fn main(): int64 {
  var a: T := new T();
  var b: T := new T();
  var d: int64 := (b as int64) - (a as int64);
  if (d < 0) { d := 0 - d; }
  PrintInt(d); PrintLn(""c);
  return 0;
}'; then
  d="$(timeout 60 "$TMP/p" 2>&1)"
  if [ "$d" -ge 8 ] 2>/dev/null && [ "$d" -le 64 ] 2>/dev/null; then
    ok "Abstand zweier Objekte ist $d Byte (vorher 4096)"
  else
    no "Abstand zweier Objekte" "$d Byte — erwartet 8..64"
  fi
else
  no "Abstand zweier Objekte" "uebersetzt nicht"
fi

# --- 2. Speicher unter Last ----------------------------------------------
# 100.000 Objekte kosteten vorher rund 400 MB. Die Schranke liegt bei 50 MB:
# weit ueber dem, was der Bump-Allokator braucht (rund 2 MB), und weit unter
# dem alten Wert. Ein Rueckfall auf seitenweise Belegung faellt damit auf,
# ohne dass der Test an einer knappen Zahl haengt.
if command -v /usr/bin/time >/dev/null 2>&1; then
  if bau 'type T = class { A: int64; fn Create(): void { self.A := 0; } }
fn main(): int64 {
  var i: int64 := 0;
  while (i < 100000) { var o: T := new T(); i := i + 1; }
  return 0;
}'; then
    rss="$(/usr/bin/time -f "%M" "$TMP/p" 2>&1 | tail -1)"
    if [ "$rss" -lt 51200 ] 2>/dev/null; then
      ok "100.000 Objekte brauchen ${rss} KB (Schranke 50 MB, vorher 400 MB)"
    else
      no "Speicher unter Last" "${rss} KB — Schranke 50 MB. Belegt `new` wieder eine Seite je Objekt?"
    fi
  else
    no "Speicher unter Last" "uebersetzt nicht"
  fi
else
  echo "SKIP Speicher unter Last: /usr/bin/time fehlt — ohne Messung sagt das nichts"
fi

# --- 3. Was der Bump-Allokator nicht kaputtmachen darf --------------------
# Ein nicht gesetztes Feld muss 0 sein. Das traegt nur, solange nie
# wiederverwendet wird; faende jemand eine Freiliste ein, faellt es hier auf.
lauf "nicht gesetztes Feld ist 0" 'import std.io;
type T = class { A: int64; B: int64; fn Create(): void { self.A := 7; } }
fn main(): int64 { var o: T := new T(); PrintInt(o.A + o.B); PrintLn(""c); return 0; }' "7"

# Geerbte Felder liegen im selben Block — die Groesse kommt aus dem Layout,
# und dort sind sie eingeflacht. Waere die Groesse zu klein, schriebe das
# letzte Feld in das naechste Objekt.
lauf "Vererbung und virtueller Aufruf" 'import std.io;
type A = class { X: int64; Y: int64; fn Create(): void { self.X := 1; self.Y := 2; } virtual fn W(): int64 { return self.X + self.Y; } }
type B = class extends A { Z: int64; fn Create(): void { self.X := 1; self.Y := 2; self.Z := 4; } override fn W(): int64 { return self.X + self.Y + self.Z; } }
fn main(): int64 { var b: B := new B(); var a: A := b as A; PrintInt(a.W()); PrintLn(""c); return 0; }' "7"

# Der eigentliche Beweis, dass sich die Objekte nicht ueberschreiben: viele
# Objekte, jedes mit eigenem Wert, und das ERSTE wird am Ende noch einmal
# gelesen.
lauf "5000 Objekte bleiben getrennt" 'import std.io;
type P = class { V: int64; fn Create(): void { self.V := 0; } }
fn main(): int64 {
  var erste: P := new P(); erste.V := 11;
  var s: int64 := 0; var i: int64 := 0;
  while (i < 5000) { var o: P := new P(); o.V := i; s := s + o.V; i := i + 1; }
  PrintInt(s); Print(" "c); PrintInt(erste.V); PrintLn(""c);
  return 0;
}' "12497500 11"

# Ein Objekt groesser als der Block (64 KB): dann muss der Block nach dem
# Objekt bemessen werden, sonst laege es hinter dem Ende.
lauf "Objekt groesser als der Block" 'import std.io;
type G = class { D: [20000]int64; N: int64; fn Create(): void { self.N := 5; } }
fn main(): int64 { var g: G := new G(); PrintInt(g.N); PrintLn(""c); return 0; }' "5"

# Ein Objekt, das im Konstruktor selbst eines anlegt — verschachtelte
# Belegung waehrend der Belegung.
lauf "Objekt legt im Konstruktor eines an" 'import std.io;
type I = class { W: int64; fn Create(): void { self.W := 3; } }
type O = class { K: I; fn Create(): void { self.K := new I(); } }
fn main(): int64 { var o: O := new O(); PrintInt(o.K.W); PrintLn(""c); return 0; }' "3"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
