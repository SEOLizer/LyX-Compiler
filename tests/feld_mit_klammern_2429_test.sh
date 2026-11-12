#!/usr/bin/env bash
# tests/feld_mit_klammern_2429_test.sh — #2429: ein FELD mit Klammern
# aufgerufen muss beim Uebersetzen scheitern.
#
# BEFUND. `b.Zahl()` auf einem int64-Feld uebersetzte ohne jede Meldung und
# sprang zur Laufzeit auf den FELDWERT als Codeadresse — SIGSEGV an einer
# Stelle, die im Quelltext harmlos aussieht. Der Absturz zeigte nicht auf den
# Aufruf, sondern irgendwohin.
#
# Besonders unangenehm dort, wo eine Bibliothek dieselbe Groesse einmal als
# Feld und einmal als Methode fuehrt (lyx-vcl: `Count` an TStringList,
# `Count()` an anderen Klassen). Solange der Feldwert 0 ist, faellt der Sprung
# nach 0 je nach Stelle nicht auf; mit dem ersten Eintrag stuerzt es ab.
#
# #1976 hat denselben Fall fuer eine FEHLENDE Methode geschlossen. Hier fehlt
# sie nicht — es gibt ein Feld gleichen Namens, und dann griff keine Pruefung.
#
# BEIDE SEITEN werden gemessen. Ein Test, der nur die Ablehnung zeigt, waere
# auch von einer Pruefung erfuellt, die JEDEN Methodenaufruf abweist:
#   - der Fehlerfall wird abgewiesen, mit dem Feldnamen in der Meldung
#   - normaler, GEERBTER und Funktionszeiger-Aufruf bleiben uebersetzbar
#     UND liefern den richtigen Wert (Wirkung, nicht Vorhandensein)
#
# NICHT ABGEDECKT: importierte Klassen. Fuer sie haelt sema nur einen Blob aus
# Namen (_fldRecord), in dem Felder und Methoden GEMISCHT und OHNE Typ stehen —
# daraus ist der Fall nicht entscheidbar. Eigenes Issue; der Feldtyp muesste
# durch das .lyu-Format getragen werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# abgewiesen <name> <quelltext> <erwarteter Textbaustein>
abgewiesen() {
  printf '%s' "$2" > "$TMP/x.lyx"
  local out rc
  out="$("$LYXC" --std-path="$ROOT" "$TMP/x.lyx" -o "$TMP/x" 2>&1)"; rc=$?
  if [ "$rc" = "0" ]; then
    echo "FAIL $1: uebersetzt klaglos (rc=0) — der Sprung auf den Feldwert bleibt"
    FAIL=$((FAIL+1)); return
  fi
  if ! printf '%s' "$out" | grep -qF "$3"; then
    echo "FAIL $1: abgewiesen, aber die Meldung nennt '$3' nicht:"
    printf '%s\n' "$out" | grep -iE "error" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (abgewiesen, Meldung nennt '$3')"
  PASS=$((PASS+1))
}

# laeuft <name> <quelltext> <erwartete Ausgabe>
laeuft() {
  printf '%s' "$2" > "$TMP/y.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/y.lyx" -o "$TMP/y" >"$TMP/log" 2>&1; then
    echo "FAIL $1: uebersetzt NICHT — Fehlalarm der Pruefung:"
    grep -iE "error" "$TMP/log" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL+1)); return
  fi
  local got
  got="$( ulimit -c 0; timeout 20 "$TMP/y" 2>&1 )"
  if [ "$got" != "$3" ]; then
    echo "FAIL $1: Ausgabe '$got' statt '$3'"
    FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (uebersetzt und liefert $3)"
  PASS=$((PASS+1))
}

K='type TBox = class { Zahl: int64; fn Create(): void { self.Zahl := 42; } fn Hol(): int64 { return self.Zahl; } }'
V='type TBasis = class { Wert: int64; fn Create(): void { self.Wert := 7; } fn Hol(): int64 { return self.Wert; } } type TKind = class extends TBasis { fn Create(): void { self.Wert := 9; } }'
Z='fn h(x: int64): int64 { return x + 40; } type TNE = fn(int64): int64; type TB = class { cb: TNE; fn Create(): void { self.cb := h; } }'
D='fn h2(x: int64): int64 { return x + 40; } type TD = class { cb: fn(int64): int64; fn Create(): void { self.cb := h2; } }'

echo "-- der Fehlerfall wird abgewiesen --"
abgewiesen "int64-Feld mit Klammern" \
  "unit main; import std.io; $K fn main(): int64 { var b: TBox := new TBox(); PrintLn(IntToStr(b.Zahl())); return 0; }" \
  "Zahl"

echo "-- Gegenseite: gueltige Aufrufe bleiben gueltig --"
laeuft "Methode derselben Klasse" \
  "unit main; import std.io; $K fn main(): int64 { var b: TBox := new TBox(); PrintLn(IntToStr(b.Hol())); return 0; }" \
  "42"
laeuft "GEERBTE Methode" \
  "unit main; import std.io; $V fn main(): int64 { var k: TKind := new TKind(); PrintLn(IntToStr(k.Hol())); return 0; }" \
  "9"
laeuft "Feld ohne Klammern" \
  "unit main; import std.io; $K fn main(): int64 { var b: TBox := new TBox(); PrintLn(IntToStr(b.Zahl)); return 0; }" \
  "42"
laeuft "Funktionszeiger-Feld ueber Typalias" \
  "unit main; import std.io; $Z fn main(): int64 { var b: TB := new TB(); PrintLn(IntToStr(b.cb(2))); return 0; }" \
  "42"
laeuft "Funktionszeiger-Feld direkt deklariert" \
  "unit main; import std.io; $D fn main(): int64 { var d: TD := new TD(); PrintLn(IntToStr(d.cb(2))); return 0; }" \
  "42"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: Feld mit Klammern wird abgewiesen, gueltige Aufrufe nicht"
exit 0
