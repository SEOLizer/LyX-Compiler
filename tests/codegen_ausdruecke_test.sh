#!/usr/bin/env bash
# tests/codegen_ausdruecke_test.sh — #1588, #1589, #1569, #1552, #1580, #1593.
#
# Sechs Punkte im Codegen, die denselben Kern haben: der Wert IST bekannt, der
# Weg dorthin fehlte.
#
#   #1588 `(x as Klasse).feld` lieferte STILL 0, `(x as Klasse).M()` brach ab.
#         cg_objClassIdx kannte den Cast-Knoten nicht und gab -1 zurueck; der
#         Feldoffset wurde -1 und cg_genFieldLoad nullte rax.
#   #1589 Anonyme Funktion als globaler Startwert und `con f := Dbl` — beides
#         Codeadressen, beides zur Uebersetzungszeit bekannt.
#   #1569 f64-Literale ab 1e-28 wurden zu 0: der Nenner der Bruchdarstellung
#         lief an die int64-Grenze und der Notzweig halbierte den Zaehler auf 0.
#   #1552 mulhi/umulhi/divrem128: die Hardware legt das volle Produkt in
#         RDX:RAX, der Codegen holte nur RAX ab.
#   #1580 Struct-Rueckgabe: zwei mmap je Aufruf (eine davon 4096 Byte fuer ein
#         Struct aus zwei Zahlen), nie ein munmap.
#   #1593 Aufruf ueber einen Feldzugriff — gemessen, nicht angenommen.
#
# GEMESSEN WIRD GEGEN EINE FREMDE REFERENZ, wo es eine gibt: die Bitmuster der
# Literale und die 128-Bit-Ergebnisse gegen Python. Bei #1580 zaehlt der
# Speicher, nicht die Laufzeit — die schwankt mit der Maschine.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >"$TMP/c.log" 2>&1; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|sema|Parse' "$TMP/c.log")"; return
  fi
  got="$(timeout 60 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# #1588 — (x as Klasse) als Empfaenger
# ===========================================================================
out "#1588: Feldzugriff und Methodenaufruf ueber einen Cast" 'import std.io;
type Basis = class {
  wert: int64;
  fn Create(w: int64): void { self.wert := w; }
  fn Zeige(): void { PrintStr(IntToStr(self.wert)); PrintStr(" "); }
};
fn main(): int64 {
  var a: int64 := new Basis(42);
  PrintStr(IntToStr((a as Basis).wert)); PrintStr(" ");
  (a as Basis).Zeige();
  var b: Basis := a as Basis;
  PrintLn(IntToStr(b.wert));
  return 0;
}' "42 42 42"

# Der Cast muss auch schreiben koennen, nicht nur lesen.
out "#1588: Schreiben ueber den Cast" 'import std.io;
type K = class { v: int64; fn Create(x: int64): void { self.v := x; } };
fn main(): int64 {
  var a: int64 := new K(1);
  (a as K).v := 42;
  PrintLn(IntToStr((a as K).v));
  return 0;
}' "42"

# ===========================================================================
# #1589 — Funktionswerte als globaler Startwert
# ===========================================================================
out "#1589: anonyme Funktion als globaler Startwert" 'import std.io;
let dbl: fn(int64): int64 := fn(x: int64): int64 { return x * 2; };
fn main(): int64 { PrintLn(IntToStr(dbl(21))); return 0; }' "42"

out "#1589: con mit Funktionsverweis" 'import std.io;
fn Dbl(x: int64): int64 { return x * 2; }
con f: fn(int64): int64 := Dbl;
fn main(): int64 { PrintLn(IntToStr(f(21))); return 0; }' "42"

# Ein Lambda auf Modulebene KANN nichts einfangen: es gibt dort keine lokalen
# Variablen, und ein Zugriff auf eine globale ist kein Einfangen (die Adresse
# steht fest). Der Codegen fuehrt trotzdem eine Pruefung mit Meldung — sie ist
# von hier aus nicht ausloesbar und wird deshalb nicht behauptet. Was zaehlt:
# der Zugriff auf eine Globale aus dem Lambda heraus muss stimmen.
out "#1589: Lambda global liest eine globale Variable" 'import std.io;
var k: int64 := 5;
let f: fn(int64): int64 := fn(x: int64): int64 { return x * k; };
fn main(): int64 { PrintLn(IntToStr(f(2))); return 0; }' "10"

# Was vorher schon ging, muss weiter gehen.
out "#1589: benannte Funktion als globaler Startwert unveraendert" 'import std.io;
fn Dbl(x: int64): int64 { return x * 2; }
var g: fn(int64): int64 := Dbl;
fn main(): int64 { PrintLn(IntToStr(g(21))); return 0; }' "42"

# ===========================================================================
# #1569 — kleine f64-Literale
# ===========================================================================
# Bitmuster gegen Python: 1e-26 4217834634465954580, 1e-28 4188260752279232537,
# 1e-29 4172965893781238599, 2.5e-40 4014333650523204995,
# 1e-100 3110860544497550640.
out "#1569: Literale bis 1e-100 tragen ihr Bitmuster" 'import std.io;
import std.alloc;
fn Bits(x: f64): int64 { var p: int64 := alloc(8); pokef64(p, x); var b: int64 := peek64(p); free(p, 8); return b; }
fn main(): int64 {
  PrintStr(IntToStr(Bits(1.0e-26))); PrintStr(" ");
  PrintStr(IntToStr(Bits(1.0e-28))); PrintStr(" ");
  PrintStr(IntToStr(Bits(1.0e-29))); PrintStr(" ");
  PrintStr(IntToStr(Bits(2.5e-40))); PrintStr(" ");
  PrintLn(IntToStr(Bits(1.0e-100)));
  return 0;
}' "4217834634465954580 4188260752279232537 4172965893781238599 4014333650523204995 3110860544497550640"

# Der Fall aus dem Bericht: alles > 0, nichts still zu null geworden.
out "#1569: kein Literal faellt auf null" 'import std.io;
fn T(v: f64): void { if (v > 0.0) { PrintStr("ok "); } else { PrintStr("NULL "); } }
fn main(): int64 {
  T(1.0e-26); T(1.0e-28); T(1.0e-29); T(2.5e-40); T(1.0e-100); T(1.0e-300);
  PrintLn("");
  return 0;
}' "ok ok ok ok ok ok "

# Grosse Exponenten und gewoehnliche Werte unveraendert.
out "#1569: grosse Exponenten und Alltagswerte unveraendert" 'import std.io;
import std.alloc;
fn Bits(x: f64): int64 { var p: int64 := alloc(8); pokef64(p, x); var b: int64 := peek64(p); free(p, 8); return b; }
fn main(): int64 {
  PrintStr(IntToStr(Bits(1.5))); PrintStr(" ");
  PrintLn(IntToStr(Bits(3.14159265358979)));
  return 0;
}' "4609434218613702656 4614256656552045841"

# ===========================================================================
# #1552 — 128-Bit-Zwischenergebnisse
# ===========================================================================
out "#1552: mulhi, umulhi, divrem128" 'import std.io;
import std.alloc;
fn main(): int64 {
  PrintStr(IntToStr(umulhi(4294967296, 4294967296))); PrintStr(" ");
  PrintStr(IntToStr(mulhi(0 - 1, 2))); PrintStr(" ");
  PrintStr(IntToStr(umulhi(3, 5))); PrintStr(" ");
  var r: int64 := alloc(8);
  PrintStr(IntToStr(divrem128(1, 0, 3, r))); PrintStr(" ");
  PrintStr(IntToStr(peek64(r))); PrintStr(" ");
  PrintStr(IntToStr(divrem128(0, 100, 7, r))); PrintStr(" ");
  PrintLn(IntToStr(peek64(r)));
  return 0;
}' "1 -1 0 6148914691236517205 1 14 2"

# Die Ausnahme, die `div` sonst als #DE ohne Erklaerung ausloest.
printf 'import std.io;\nimport std.alloc;\nfn main(): int64 { var r: int64 := alloc(8); PrintLn(IntToStr(divrem128(5, 0, 3, r))); return 0; }\n' > "$TMP/dv.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/dv.lyx" -o "$TMP/dv" >/dev/null 2>&1; then
  msg="$(timeout 20 "$TMP/dv" 2>&1)"; rc=$?
  if echo "$msg" | grep -qi "divrem128"; then ok "#1552: Quotientenueberlauf wird gemeldet statt als #DE zu sterben"
  else no "#1552: Quotientenueberlauf" "rc=$rc, '$msg'"; fi
else
  no "#1552: Quotientenueberlauf" "uebersetzt nicht"
fi

# ===========================================================================
# #1580 — Struct-Rueckgabe: Speicher statt Seiten
# ===========================================================================
cat > "$TMP/s80.lyx" <<'EOF'
import std.io;
type Pair = struct { a: int64; b: int64 };
fn MkStruct(x: int64): Pair { var p: Pair; p.a := x; p.b := x + 1; return p; }
fn main(): int64 {
  var i: int64 := 0;
  var s: int64 := 0;
  while (i < 200000) {
    var p: Pair := MkStruct(i);
    s := s + p.a;
    i := i + 1;
  }
  PrintStr("s="); PrintLn(IntToStr(s));
  return 0;
}
EOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/s80.lyx" -o "$TMP/s80" >"$TMP/s80.log" 2>&1; then
  rss="$(/usr/bin/time -f '%M' "$TMP/s80" 2>&1 >/dev/null | tail -1)"
  erg="$("$TMP/s80" 2>&1)"
  if [ "$erg" != "s=19999900000" ]; then
    no "#1580: Ergebnis" "'$erg'"
  elif [ "$rss" -lt 102400 ]; then
    ok "#1580: 200k Struct-Rueckgaben unter 100 MB (${rss} kB; vorher 1,6 GB)"
  else
    no "#1580: Speicher" "${rss} kB — die Belegung waechst weiter je Aufruf"
  fi
else
  no "#1580" "uebersetzt nicht: $(grep -m1 -i error "$TMP/s80.log")"
fi

# Die Wertsemantik aus #1351 darf davon nicht beruehrt werden.
out "#1580: Wertsemantik unveraendert" 'import std.io;
type P = struct { a: int64; b: int64 };
fn Aendere(p: P): int64 { p.a := 999; return p.a; }
fn main(): int64 {
  var x: P; x.a := 1; x.b := 2;
  var y: P := x;
  y.a := 42;
  PrintStr(IntToStr(x.a)); PrintStr(" "); PrintStr(IntToStr(y.a)); PrintStr(" ");
  Aendere(x);
  PrintStr(IntToStr(x.a)); PrintStr(" ");
  var z: P; z := y; z.b := 7;
  PrintStr(IntToStr(y.b)); PrintStr(" "); PrintLn(IntToStr(z.b));
  return 0;
}' "1 42 1 2 7"

# ===========================================================================
# #1593 — Aufruf ueber einen Feldzugriff (gemessen)
# ===========================================================================
out "#1593: Feld mit Funktionszeiger ruft den hinterlegten Wert" 'import std.io;
type Knopf = struct { on_click: fn(int64): int64; };
fn A(d: int64): int64 { return d + 1; }
fn B(d: int64): int64 { return d * 10; }
fn main(): int64 {
  var k: Knopf;
  k.on_click := A;
  PrintStr(IntToStr(k.on_click(5))); PrintStr(" ");
  k.on_click := B;
  PrintLn(IntToStr(k.on_click(5)));
  return 0;
}' "6 50"

out "#1593: dasselbe an einer Klasse" 'import std.io;
type W = class { cb: fn(int64): int64; pub fn Setze(f: fn(int64): int64) { self.cb := f; } };
fn A(d: int64): int64 { return d + 1; }
fn main(): int64 {
  var w: W := new W();
  w.Setze(A);
  PrintLn(IntToStr(w.cb(41)));
  return 0;
}' "42"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
