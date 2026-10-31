#!/usr/bin/env bash
# tests/vektor_hilfsindex_2334_test.sh — #2334: die Vektorerkennung nimmt
# auch eine Hilfsvariable als Index.
#
# Bis 1.2.27A verlangte `cg_vmErkennen` einen Rumpf mit GENAU ZWEI
# Anweisungen und den Zaehler direkt als Index. `bench/arr_int.lyx` schreibt
# ihn aber als Hilfsvariable:
#
#   while (i < n) { var o: int64 := i * 2; poke16(c + o, ...); i += 1; }
#
# Damit blieb jede int16- und int32-Schleife skalar, obwohl PADDW, PADDD,
# PMULLW und PMULLD alle in cg_sseGanzOpcode stehen: int8_add lag auf
# gcc-Niveau, int16_add 9,20x dahinter — bei identischer Rechnung.
#
# Geprueft wird in vier Richtungen:
#
#   1. WERT, differentiell: beide Schreibweisen im selben Programm, Ergebnis
#      Element fuer Element gleich, ueber alle drei Breiten und drei
#      Operatoren. `n` ist KEIN Vielfaches der Vektorbreite, damit der
#      Rest-Durchgang mitgeprueft wird.
#   2. UEBERLAPPUNG in der Hilfsvariablen-Form: c == a+1, c == a, c == a-1.
#      Die Laufzeitpruefung muss greifen und skalar rechnen.
#   3. AM ERZEUGNIS, BEIDE SEITEN: die Hilfsform muss Vektorbefehle
#      enthalten, und vier Formen, die NICHT passen duerfen, muessen ohne
#      bleiben. Ohne die zweite Haelfte wuerde der Test auch bestehen, wenn
#      die Bedingung alles durchlaesst.
#   4. GATING: PMULLD braucht sse4. Bei --target-cpu=baseline darf es NICHT
#      erscheinen (eine automatische Umformung darf keine CPU-Forderung
#      erheben, die im Quelltext niemand gestellt hat), mit Zusage schon —
#      und das Ergebnis muss in beiden Faellen dasselbe sein.
#
# Gezaehlt wird ueber die PRAEFIX-STRUKTUR, nicht ueber ein einzelnes Byte:
# ein Zaehler, der nur `C4|C5` und zwei Bytes weiter den Opcode sucht, hat in
# #2330 einen `call rel32` als PADDW gelesen (#1370). Ein Lyx-Erzeugnis hat
# keine ELF-Sektionen, `objdump -d` disassembliert daran gar nichts.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
_v="$(dirname "$0")/lib/vektorzahl.sh"; [ -f "$_v" ] || _v="$(dirname "$0")/../lib/vektorzahl.sh"; . "$_v"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

baue() { printf '%s' "$2" > "$TMP/$1.lyx"
         (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" ${3:-} "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1); }

# ---------------------------------------------------------------- 1
# n = 1000 ist kein Vielfaches von 16, 8 oder 4 — der Rest-Durchgang laeuft
# bei jeder Breite mit.
Q_WERTE='unit main;
import std.io;
import std.alloc;

// Hilfsvariable im Rumpf (neue Form)
fn h8p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 1; poke8(c + o, (peek8(a + o) + peek8(b + o)) & 0xFF); i += 1; }
}
fn h8m(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 1; poke8(c + o, (peek8(a + o) - peek8(b + o)) & 0xFF); i += 1; }
}
fn h16p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 2; poke16(c + o, (peek16(a + o) + peek16(b + o)) & 0xFFFF); i += 1; }
}
fn h16m(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 2; poke16(c + o, (peek16(a + o) - peek16(b + o)) & 0xFFFF); i += 1; }
}
fn h16s(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 2; poke16(c + o, (peek16(a + o) * peek16(b + o)) & 0xFFFF); i += 1; }
}
fn h32p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(c + o, (peek32(a + o) + peek32(b + o)) & 0xFFFFFFFF); i += 1; }
}
fn h32m(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(c + o, (peek32(a + o) - peek32(b + o)) & 0xFFFFFFFF); i += 1; }
}
fn h32s(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(c + o, (peek32(a + o) * peek32(b + o)) & 0xFFFFFFFF); i += 1; }
}

// Gegenstueck ohne Hilfsvariable (alte, schon erkannte Form) — das ist der
// Vergleichsmassstab. Beide Fassungen muessen bitgleich dasselbe liefern.
fn d8p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) + peek8(b + i)) & 0xFF); i += 1; }
}
fn d8m(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke8(c + i, (peek8(a + i) - peek8(b + i)) & 0xFF); i += 1; }
}
fn d16p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke16(c + i * 2, (peek16(a + i * 2) + peek16(b + i * 2)) & 0xFFFF); i += 1; }
}
fn d16m(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke16(c + i * 2, (peek16(a + i * 2) - peek16(b + i * 2)) & 0xFFFF); i += 1; }
}
fn d16s(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke16(c + i * 2, (peek16(a + i * 2) * peek16(b + i * 2)) & 0xFFFF); i += 1; }
}
fn d32p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke32(c + i * 4, (peek32(a + i * 4) + peek32(b + i * 4)) & 0xFFFFFFFF); i += 1; }
}
fn d32m(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke32(c + i * 4, (peek32(a + i * 4) - peek32(b + i * 4)) & 0xFFFFFFFF); i += 1; }
}
fn d32s(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke32(c + i * 4, (peek32(a + i * 4) * peek32(b + i * 4)) & 0xFFFFFFFF); i += 1; }
}

fn vgl(x: int64, y: int64, bytes: int64, name: pchar): int64 {
  var k: int64 := 0;
  while (k < bytes) {
    if (peek8(x + k) != peek8(y + k)) {
      Print("ABWEICHUNG "); Print(name); Print(" bei Byte "); PrintLn(IntToStr(k));
      return 1;
    }
    k += 1;
  }
  return 0;
}

fn main(): int64 {
  var n: int64 := 1000;
  var a: int64 := alloc(n * 4); var b: int64 := alloc(n * 4);
  var c1: int64 := alloc(n * 4); var c2: int64 := alloc(n * 4);
  // Werte, die bei jeder Breite ueber die Maske laufen: Differenzen werden
  // negativ, Produkte ueberschreiten 8 und 16 Bit.
  var i: int64 := 0;
  while (i < n) {
    poke32(a + i * 4, (i * 2654435761) & 0xFFFFFFFF);
    poke32(b + i * 4, (i * 40503 + 251) & 0xFFFFFFFF);
    i += 1;
  }
  var schlecht: int64 := 0;
  h8p(a, b, c1, n);  d8p(a, b, c2, n);  schlecht += vgl(c1, c2, n, "8+"c);
  h8m(a, b, c1, n);  d8m(a, b, c2, n);  schlecht += vgl(c1, c2, n, "8-"c);
  h16p(a, b, c1, n); d16p(a, b, c2, n); schlecht += vgl(c1, c2, n * 2, "16+"c);
  h16m(a, b, c1, n); d16m(a, b, c2, n); schlecht += vgl(c1, c2, n * 2, "16-"c);
  h16s(a, b, c1, n); d16s(a, b, c2, n); schlecht += vgl(c1, c2, n * 2, "16*"c);
  h32p(a, b, c1, n); d32p(a, b, c2, n); schlecht += vgl(c1, c2, n * 4, "32+"c);
  h32m(a, b, c1, n); d32m(a, b, c2, n); schlecht += vgl(c1, c2, n * 4, "32-"c);
  h32s(a, b, c1, n); d32s(a, b, c2, n); schlecht += vgl(c1, c2, n * 4, "32*"c);
  if (schlecht == 0) { PrintLn("WERTE OK"); return 0; }
  Print("WERTE ROT "); PrintLn(IntToStr(schlecht));
  return 1;
}'
if baue werte "$Q_WERTE"; then
  aus=$( cd "$TMP" && timeout 120 ./werte 2>&1 )
  if [ "$aus" = "WERTE OK" ]; then
    ok "Wert: Hilfsform und direkte Form gleich (3 Breiten x 3 Operatoren, n=1000, Rest-Durchgang)"
  else
    no "Wert" "$(printf '%s' "$aus" | head -4)"
  fi
else
  no "Wert" "uebersetzt nicht: $(grep -v Copyright "$TMP/werte.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 2
# Ueberlappung in der Hilfsvariablen-Form. Die Vektorschleife schreibt 16
# Byte je Schritt; bei c == a + 1 liefert sie etwas anderes als die skalare.
# Die Laufzeitpruefung muss das abfangen.
Q_UEBER='unit main;
import std.io;
import std.alloc;
fn h16p(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 2; poke16(c + o, (peek16(a + o) + peek16(b + o)) & 0xFFFF); i += 1; }
}
fn skalar(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) {
    var o: int64 := i * 2;
    var w: int64 := (peek16(a + o) + peek16(b + o)) & 0xFFFF;
    poke16(c + o, w);
    i += 1;
  }
}
fn fuell(p: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { poke16(p + i * 2, (i * 7 + 3) & 0xFFFF); i += 1; }
}
fn main(): int64 {
  var n: int64 := 100;
  var schlecht: int64 := 0;
  var f: int64 := 0;
  while (f < 3) {
    // Die Felder liegen MIT VORLAUF in einer groesseren Ablage: C == A - 2
    // muss innerhalb der Ablage bleiben, sonst prueft der Test nicht die
    // Ueberlappung, sondern beschaedigt den Haldenspeicher.
    var bufA: int64 := alloc((n + 16) * 2);
    var bufB: int64 := alloc((n + 16) * 2);
    var bufC: int64 := alloc((n + 16) * 2);
    var bufD: int64 := alloc((n + 16) * 2);
    var A: int64 := bufA + 16;   var B: int64 := bufB + 16;
    var A2: int64 := bufC + 16;  var B2: int64 := bufD + 16;
    fuell(A, n + 4); fuell(B, n + 4);
    fuell(A2, n + 4); fuell(B2, n + 4);
    var C: int64 := A;  var C2: int64 := A2;       // f == 1: c == a
    if (f == 0) { C := A + 2;  C2 := A2 + 2; }     // Ziel liegt HINTER der Quelle
    if (f == 2) { C := A - 2;  C2 := A2 - 2; }     // Ziel liegt VOR der Quelle
    h16p(A, B, C, n);
    skalar(A2, B2, C2, n);
    // Verglichen wird die ganze Ablage einschliesslich Vorlauf, damit ein
    // Schreibzugriff daneben auffaellt.
    var k: int64 := 0;
    while (k < (n + 16) * 2) {
      if (peek8(bufA + k) != peek8(bufC + k)) {
        Print("UEBER ABWEICHUNG Fall "); Print(IntToStr(f)); Print(" Byte "); PrintLn(IntToStr(k));
        schlecht += 1;
        k := (n + 16) * 2;
      }
      k += 1;
    }
    f += 1;
  }
  if (schlecht == 0) { PrintLn("UEBER OK"); return 0; }
  return 1;
}'
if baue ueber "$Q_UEBER"; then
  aus=$( cd "$TMP" && timeout 120 ./ueber 2>&1 )
  if [ "$aus" = "UEBER OK" ]; then ok "Ueberlappung in der Hilfsform: Laufzeitpruefung greift"
  else no "Ueberlappung" "$(printf '%s' "$aus" | head -4)"; fi
else
  no "Ueberlappung" "uebersetzt nicht: $(grep -v Copyright "$TMP/ueber.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 3a
Q_JA='unit main;
import std.io;
import std.alloc;
fn k16(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 2; poke16(c + o, (peek16(a + o) + peek16(b + o)) & 0xFFFF); i += 1; }
}
fn k32(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(c + o, (peek32(a + o) + peek32(b + o)) & 0xFFFFFFFF); i += 1; }
}
fn main(): int64 {
  var n: int64 := 64;
  var a: int64 := alloc(n * 4); var b: int64 := alloc(n * 4); var c: int64 := alloc(n * 4);
  k16(a, b, c, n); k32(a, b, c, n);
  return 0;
}'
if baue ja "$Q_JA"; then
  N=$(vek_zahl "$TMP/ja.lyx" 'padd[bwd]|vpadd[bwd]|pmullw|vpmullw')
  if [ "$N" -ge 2 ]; then ok "Erzeugnis: Hilfsform wird vektorisiert ($N gepackte Befehle)"
  else no "Erzeugnis Hilfsform" "nur $N gepackte Befehle — nicht erkannt"; fi
else
  no "Erzeugnis Hilfsform" "uebersetzt nicht: $(grep -v Copyright "$TMP/ja.log" | grep -m1 -iE 'error|lyxc:')"
fi

# ---------------------------------------------------------------- 3b
# Vier Formen, die NICHT passen duerfen. Jede einzeln, damit ein Treffer
# zuordenbar bleibt.
nein_fall() {   # name, rumpf
  local Q='unit main;
import std.io;
import std.alloc;
fn k(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { '"$2"' }
}
fn main(): int64 {
  var n: int64 := 64;
  var a: int64 := alloc(n * 8); var b: int64 := alloc(n * 8); var c: int64 := alloc(n * 8);
  k(a, b, c, n);
  return 0;
}'
  if baue "nein_$1" "$Q"; then
    local N; N=$(vek_zahl "$TMP/nein_$1.lyx" 'padd[bwd]|vpadd[bwd]|pmullw|vpmullw')
    if [ "$N" -eq 0 ]; then ok "Gegenseite $1: kein gepackter Befehl"
    else no "Gegenseite $1" "$N gepackte Befehle — die Bedingung ist zu weit"; fi
  else
    no "Gegenseite $1" "uebersetzt nicht: $(grep -v Copyright "$TMP/nein_$1.log" | grep -m1 -iE 'error|lyxc:')"
  fi
}
# Faktor passt nicht zur Breite
nein_fall faktor 'var o: int64 := i * 3; poke16(c + o, (peek16(a + o) + peek16(b + o)) & 0xFFFF); i += 1;'
# Initialwert kommt nicht aus der Schleifenvariablen
nein_fall fremd 'var o: int64 := n * 2; poke16(c + o, (peek16(a + o) + peek16(b + o)) & 0xFFFF); i += 1;'
# zwei Deklarationen — nur EINE ist zugelassen
nein_fall zwei 'var o: int64 := i * 2; var p: int64 := o; poke16(c + p, (peek16(a + p) + peek16(b + p)) & 0xFFFF); i += 1;'
# Hilfsvariable heisst wie der Zaehler: sie verdeckt im Rumpf genau die
# Groesse, die die Bedingung liest
nein_fall verdeckt 'var i: int64 := i * 2; poke16(c + i, (peek16(a + i) + peek16(b + i)) & 0xFFFF); i += 1;'

# ---------------------------------------------------------------- 4
# PMULLD braucht sse4. Ohne Zusage darf es nicht erscheinen, mit Zusage
# schon — und das Ergebnis muss gleich sein.
Q_MULLD='unit main;
import std.io;
import std.alloc;
fn k(a: int64, b: int64, c: int64, n: int64) {
  var i: int64 := 0;
  while (i < n) { var o: int64 := i * 4; poke32(c + o, (peek32(a + o) * peek32(b + o)) & 0xFFFFFFFF); i += 1; }
}
fn main(): int64 {
  var n: int64 := 257;
  var a: int64 := alloc(n * 4); var b: int64 := alloc(n * 4); var c: int64 := alloc(n * 4);
  var i: int64 := 0;
  while (i < n) { poke32(a + i * 4, i + 1); poke32(b + i * 4, 65537); i += 1; }
  k(a, b, c, n);
  var s: int64 := 0;
  i := 0;
  while (i < n) { s := s + (peek32(c + i * 4) & 0xFFFFFFFF); i += 1; }
  Print("summe="); PrintLn(IntToStr(s));
  return 0;
}'
A=""; B=""
if baue mb "$Q_MULLD" "--target-cpu=baseline"; then
  N=$(vek_zahl "$TMP/mb.lyx" 'pmulld|vpmulld' --target-cpu=baseline); A=$( cd "$TMP" && timeout 60 ./mb 2>&1 )
  if [ "$N" -eq 0 ]; then ok "Gating: --target-cpu=baseline ohne PMULLD"
  else no "Gating baseline" "$N PMULLD — eine automatische Umformung hat eine CPU-Forderung erhoben"; fi
else
  no "Gating baseline" "uebersetzt nicht: $(grep -v Copyright "$TMP/mb.log" | grep -m1 -iE 'error|lyxc:')"
fi
if baue ms "$Q_MULLD" "--target-cpu=sse4"; then
  N=$(vek_zahl "$TMP/ms.lyx" 'pmulld|vpmulld' --target-cpu=sse4); B=$( cd "$TMP" && timeout 60 ./ms 2>&1 )
  if [ "$N" -ge 1 ]; then ok "Gating: --target-cpu=sse4 emittiert PMULLD ($N)"
  else no "Gating sse4" "kein PMULLD, obwohl zugesagt"; fi
else
  no "Gating sse4" "uebersetzt nicht: $(grep -v Copyright "$TMP/ms.log" | grep -m1 -iE 'error|lyxc:')"
fi
if [ -n "$A" ] && [ "$A" = "$B" ]; then
  ok "Gating: beide Stufen rechnen gleich ($A)"
else
  no "Gating Ergebnisgleichheit" "baseline '$A' gegen sse4 '$B'"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
