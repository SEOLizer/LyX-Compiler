#!/usr/bin/env bash
# tests/cli_globals_methodptr_test.sh — #1163, #1164 und #1172.
#
# #1163: Die Kommandozeile prueft ihre Argumente nicht. Ein unbekanntes Flag
# wurde stillschweigend geschluckt, ein ungueltiger Wert auf einen Default
# zurueckgesetzt — beides mit Exit 0. Wer sich vertippt, bekam ein Binary, das
# anders uebersetzt wurde als beabsichtigt. Die Asymmetrie war der Kern:
# `@energy(9)` als Attribut wird sauber abgewiesen, ueber das Flag ging
# derselbe Wert durch.
#
# #1164: Eine globale Variable wurde nur initialisiert, wenn rechts ein
# GANZZAHLLITERAL stand. Jeder andere Ausdruck wurde verworfen, ohne Meldung —
# die Variable stand danach auf 0. Betroffen war ausgerechnet `0 - 1`, die
# uebliche Schreibweise fuer negative Werte.
#
# #1172: Ein Methodenzeiger ohne Typangabe (`var m := c.Get;`) uebersetzte und
# starb beim Aufruf mit SIGSEGV. Gebunden wurde nur bei ausdruecklichem Typ;
# ohne ihn wurde das FELD dieses Namens geladen, das die Klasse nicht fuehrt —
# Offset 0, also der VMT-Zeiger.
#
# Gemessen wird die Meldung bzw. der Wert nach dem Start. Bei allen dreien
# waere ein Test, der nur schaut, ob etwas uebersetzt, vorher gruen gewesen:
# #1163 und #1164 liefen mit Exit 0 durch, #1172 uebersetzte klaglos.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Grenze um den Compiler-Aufruf: ein Endlosfall soll den Test rot machen,
# nicht die Maschine (#1294).
lyxc_run() { ( ulimit -v $(( 4 * 1024 * 1024 )); timeout 60 "$LYXC" "$@" ); }

ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
no()  { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { return 0; }\n' > "$TMP/leer.lyx"

# ===========================================================================
# #1163 — die Kommandozeile meldet sich
# ===========================================================================

# Abgewiesen: Meldung UND Exit != 0. Beides zusammen, sonst waere ein Compiler,
# der meldet und trotzdem baut, ebenso gruen.
cli_rejects() { # name, flag, erwartete meldung
  out=$(lyxc_run "$TMP/leer.lyx" "$2" -o "$TMP/leer.bin" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "Exit 0 — still geschluckt"; return; fi
  if echo "$out" | grep -q "$3"; then ok "$1 (abgewiesen, rc=$rc)"
  else no "$1" "keine passende Meldung — '$(echo "$out" | head -1)'"; fi
}

cli_rejects "unbekanntes Langflag"     "--voellig-erfunden"  "unbekannter Schalter"
cli_rejects "unbekannter Kurzschalter" "-Xyz"                "unbekannter Schalter"
# --energy-stats steht in guides/, gibt es aber nicht — es fiel bisher durch.
cli_rejects "Flag aus der Doku, das es nicht gibt" "--energy-stats" "unbekannter Schalter"
cli_rejects "Energiestufe zu hoch"     "--target-energy=9"   "ausserhalb 1..5"
cli_rejects "Energiestufe 0"           "--target-energy=0"   "ausserhalb 1..5"
cli_rejects "Energiestufe keine Zahl"  "--target-energy=abc" "erwartet eine Zahl"

# Gegenprobe: die gueltigen Formen muessen weiter durchgehen. Eine Pruefung,
# die ALLES abweist, waere sonst ebenso gruen.
cli_accepts() { # name, flag(s)
  if lyxc_run "$TMP/leer.lyx" $2 -o "$TMP/leer.bin" >/dev/null 2>&1; then ok "$1"
  else no "$1" "abgewiesen, obwohl gueltig"; fi
}

cli_accepts "ohne Flags"            ""
cli_accepts "-O2"                   "-O2"
cli_accepts "-v"                    "-v"
cli_accepts "-wa und -we"           "-wa"
cli_accepts "--target-energy=3"     "--target-energy=3"
cli_accepts "--lint"                "--lint"

# --emit-asm stand hier als Beispiel fuer "gueltig". Das war es nie: der
# Schalter setzte ein Feld, das niemand liest (#1098). Seit 1.0.17F wird er
# abgewiesen statt still geschluckt; die Umsetzung fuehrt #1370.
cli_rejects "angenommener, aber nicht umgesetzter Schalter" "--emit-asm" "nicht umgesetzt"

# ===========================================================================
# #1164 — globale Startwerte
# ===========================================================================

gout() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/g.lyx"; rm -f "$TMP/g"
  if ! lyxc_run --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 10 "$TMP/g" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# Der Repro aus dem Bericht. Vor dem Fix zweimal 0.
gout "globale Startwerte werden gerechnet" 'import src.std.io;
var a: int64 := 0 - 1;
var b: int64 := 2 + 3;
fn main(): int64 { PrintLn(a); PrintLn(b); return 0; }' "-1
5"

# Ein benannter con und ein zusammengesetzter Ausdruck.
gout "con und Rechnung als Startwert" 'import src.std.io;
con BASIS: int64 := 40;
var a: int64 := BASIS + 2;
var b: int64 := 3 * 4 - 2;
fn main(): int64 { PrintLn(a); PrintLn(b); return 0; }' "42
10"

# #1151 muss mitlaufen: die Kuerzung auf schmale Typen rechnet der Compiler.
gout "Kuerzung auf int8 laeuft mit" 'import src.std.io;
var d: int8 := 300;
fn main(): int64 { PrintLn(d as int64); return 0; }' "44"

# Gegenprobe: das Ganzzahlliteral, das schon vorher ging, geht weiter.
gout "einfaches Literal unveraendert" 'import src.std.io;
var a: int64 := 7;
fn main(): int64 { PrintLn(a); return 0; }' "7"

# Zeichenkette als Startwert: die Adresse steht erst fest, wenn die Codelaenge
# feststeht (der Datenbereich folgt darauf). Vor dem Fix blieb hier eine 0 —
# ein Nullzeiger, der wie eine leere Zeichenkette aussieht.
gout "Zeichenkette als globaler Startwert" 'import src.std.io;
var s: pchar := "hallo";
fn main(): int64 { PrintLn(s); PrintLn(IntToStr(StrLen(s))); return 0; }' "hallo
5"

# Die leere Zeichenkette muss ein gueltiger Zeiger auf ein Nullbyte sein, kein
# Nullzeiger — gemessen ueber StrLen, nicht ueber einen Vergleich gegen 0.
gout "leere Zeichenkette ist ein gueltiger Zeiger" 'import src.std.io;
var leer: pchar := "";
fn main(): int64 { PrintLn(IntToStr(StrLen(leer))); return 0; }' "0"

# Nicht ausrechenbar: melden statt still 0.
printf '%s\n' 'import src.std.io;
fn f(): int64 { return 1; }
var a: int64 := f();
fn main(): int64 { PrintLn(a); return 0; }' > "$TMP/gn.lyx"
out=$(lyxc_run --std-path="$ROOT" "$TMP/gn.lyx" -o "$TMP/gn" 2>&1)
if echo "$out" | grep -q "zur Uebersetzungszeit nicht bekannt"; then
  ok "nicht konstanter Startwert wird gemeldet"
else
  no "nicht konstanter Startwert" "keine Meldung — '$(echo "$out" | tail -1)'"
fi

# ===========================================================================
# #1172 — Methodenzeiger ohne Typangabe
# ===========================================================================
# Gemessen wird der AUFRUF, nicht die Uebersetzung: vor dem Fix uebersetzte
# beides und nur der Aufruf starb.

gout "Methodenzeiger mit und ohne Typangabe" 'import src.std.io;
type C  = class { a: int64; fn Get(): int64 { return self.a; } };
type CM = method(): int64;
fn main(): int64 {
    var c: C := new C();
    c.a := 7;
    var mit: CM := c.Get;
    PrintLn(IntToStr(mit()));
    var ohne := c.Get;
    PrintLn(IntToStr(ohne()));
    return 0;
}' "7
7"

gout "Methodenzeiger mit Parameter, ohne Typangabe" 'import src.std.io;
type F  = class { v: int64; fn Handle(x: int64): int64 { return self.v + x; } };
type TM = method(x: int64): int64;
fn main(): int64 {
    var f: F := new F();
    f.v := 40;
    var mit: TM := f.Handle;
    PrintLn(IntToStr(mit(2)));
    var ohne := f.Handle;
    PrintLn(IntToStr(ohne(2)));
    return 0;
}' "42
42"

# Gegenprobe: ein echtes FELD gleichen Musters wird weiterhin GELADEN und nicht
# als Methode gebunden — sonst haette die Aenderung den Feldzugriff gekapert.
gout "gleichnamiges Feld wird weiter geladen" 'import src.std.io;
type D = class { wert: int64; };
fn main(): int64 {
    var d: D := new D();
    d.wert := 9;
    var w := d.wert;
    PrintLn(IntToStr(w));
    return 0;
}' "9"

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
