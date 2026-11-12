#!/usr/bin/env bash
# tests/sprache_z16_test.sh — #1505, #1506, #1508, #1384, #1509.
#
# Fuenf Luecken zwischen Doku und Parser. Gemeinsam ist ihnen, dass die
# Dokumentation eine Form zeigt, die es nicht gab — und der Bestand deshalb
# einen Umweg ging oder gar nicht uebersetzte:
#
#   #1505 `tabelle[i](args)` wurde abgewiesen. Dispatch-Tabellen brauchten
#         eine Zwischenvariable; die Doku zeigt `dispatch[event](0)`.
#   #1506 `new T` gab es nicht, nur `new T[n]`. Fuer einen Einzelwert blieb
#         `new T[1]` oder alloc(8). Die eingebauten Typen sind ausserdem
#         Schluesselwoerter, `new f64` scheiterte an "expected IDENT".
#   #1508 `new T[](n)` (Kapazitaet n, Laenge 0) fehlte — der uebliche Wunsch
#         fuer einen Puffer, der per push gefuellt wird.
#   #1384 Wildcard-Import fehlte ganz.
#   #1509 @stack_limit wurde an JEDER rekursiven Funktion abgewiesen, auch mit
#         Tiefenzaehler und Schranke.
#
# GEMESSEN WIRD DIE WIRKUNG, nicht nur die Uebersetzbarkeit: welcher Handler
# laeuft, was in der Zelle steht, welche Laenge das Array hat, welche Units
# der Stern wirklich hereinholt. Und jeweils die Gegenprobe, dass die
# Verschaerfung bzw. Lockerung nicht zu weit greift.

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
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

meldet() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "uebersetzt klaglos"; return; fi
  if echo "$msg" | grep -qF "$3"; then ok "$1"; else no "$1" "andere Meldung: $(echo "$msg"|grep -iE 'error|Parse'|head -1)"; fi
}

# ===========================================================================
# #1505 — Aufruf ueber einen indizierten Ausdruck
# ===========================================================================

# Der Fall aus der Doku: eine Dispatch-Tabelle, direkt gerufen. Gemessen wird,
# WELCHER Handler laeuft — ein Test auf "uebersetzt" waere vor #1053 gruen
# gewesen, als der Aufruf still das Falsche tat (arr[0](21) ergab 12).
out "#1505: Dispatch-Tabelle direkt aufrufen" 'import std.io;
type Handler = fn(data: int64): void;
fn A(data: int64): void { PrintStr("A"); PrintStr(IntToStr(data)); }
fn B(data: int64): void { PrintStr("B"); PrintStr(IntToStr(data)); }
fn main(): int64 {
  var d: [2]Handler := [A, B];
  d[1](7); d[0](3);
  PrintLn("");
  return 0;
}' "B7A3"

# Mehrere Argumente — genau der Fall, der vor #1053 einen unverstaendlichen
# Fehler ueber ein fehlendes ')' gab.
out "#1505: zwei Argumente und Rueckgabewert" 'import std.io;
type Rechner = fn(a: int64, b: int64): int64;
fn Plus(a: int64, b: int64): int64 { return a + b; }
fn Mal(a: int64, b: int64): int64 { return a * b; }
fn main(): int64 {
  var t: [2]Rechner := [Plus, Mal];
  PrintStr(IntToStr(t[0](2, 3))); PrintStr(" ");
  PrintLn(IntToStr(t[1](6, 7)));
  return 0;
}' "5 42"

# Der Umweg ueber eine Zwischenvariable muss unveraendert gehen.
out "#1505: Zwischenvariable weiterhin gueltig" 'import std.io;
type Handler = fn(d: int64): void;
fn A(d: int64): void { PrintStr("A"); }
fn main(): int64 {
  var t: [1]Handler := [A];
  var h: Handler := t[0];
  h(0); PrintLn("");
  return 0;
}' "A"

# ===========================================================================
# #1506 — new T fuer einen Einzelwert
# ===========================================================================

# Die Zelle traegt den Wert selbst: `poke64(p, 42)` schreibt den Wert, nicht in
# einen Array-Kopf. Genau so zeigt es die Doku.
out "#1506: new int64 und new f64 als Einzelwert" 'import std.io;
fn main(): int64 {
  var p: int64 := new int64;
  poke64(p, 42);
  PrintStr(IntToStr(peek64(p))); PrintStr(" ");
  var f: int64 := new f64;
  pokef64(f, 2.5);
  PrintLn(FloatToStr(peekf64(f), 1));
  return 0;
}' "42 2.5"

# Gegenprobe: `new T[1]` bleibt das ARRAY mit einem Element — die beiden
# Formen unterscheiden sich sichtbar.
out "#1506: new T[1] bleibt ein Array" 'import std.io;
fn main(): int64 {
  var a: int64[] := new int64[1];
  PrintLn(IntToStr(len(a)));
  return 0;
}' "1"

# Eine Klasse muss weiter ihren Konstruktor bekommen, nicht eine Zelle.
out "#1506: new Klasse ohne Klammern ruft den Konstruktor" 'import std.io;
type Zaehler = class {
  wert: int64;
  pub fn Setze(v: int64) { self.wert := v; }
  pub fn Hole(): int64 { return self.wert; }
};
fn main(): int64 {
  var z: Zaehler := new Zaehler;
  z.Setze(42);
  PrintLn(IntToStr(z.Hole()));
  return 0;
}' "42"

# ===========================================================================
# #1508 — new T[](n): Kapazitaet ohne Laenge
# ===========================================================================
out "#1508: Kapazitaet reservieren, Laenge bleibt 0" 'import std.io;
fn main(): int64 {
  var dyn: int64[] := new int64[](4);
  PrintStr(IntToStr(len(dyn))); PrintStr(" ");
  var voll: int64[] := new int64[4];
  PrintLn(IntToStr(len(voll)));
  return 0;
}' "0 4"

# ===========================================================================
# #1384 — Wildcard-Import, auch ueber Unterverzeichnisse
# ===========================================================================
mkdir -p "$TMP/paket/unter"
printf 'unit paket.eins;\npub fn Eins(): int64 { return 1; }\n' > "$TMP/paket/eins.lyx"
printf 'unit paket.zwei;\npub fn Zwei(): int64 { return 2; }\n' > "$TMP/paket/zwei.lyx"
printf 'unit paket.unter.drei;\npub fn Drei(): int64 { return 3; }\n' > "$TMP/paket/unter/drei.lyx"
printf 'import std.io;\nimport paket.*;\nfn main(): int64 { PrintLn(IntToStr(Eins() + Zwei() + Drei())); return 0; }\n' > "$TMP/wc.lyx"

if timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/wc.lyx" -o "$TMP/wc" >"$TMP/wc.log" 2>&1; then
  got="$("$TMP/wc" 2>&1)"
  if [ "$got" = "6" ]; then ok "#1384: Wildcard holt auch Unterverzeichnisse (1+2+3)"
  else no "#1384: Wildcard" "'$got' erwartet '6'"; fi
else
  no "#1384: Wildcard" "$(grep -m1 -iE 'error|Parse' "$TMP/wc.log")"
fi

# Auf der echten Bibliothek — dort haengt an std.math noch ein Unterverzeichnis.
printf 'import std.io;\nimport std.math.*;\nfn main(): int64 { PrintLn(FloatToStr(PI, 5)); return 0; }\n' > "$TMP/wcstd.lyx"
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/wcstd.lyx" -o "$TMP/wcstd" >"$TMP/wcstd.log" 2>&1; then
  got="$("$TMP/wcstd" 2>&1)"
  [ "$got" = "3.14159" ] && ok "#1384: Wildcard auf std.math.*" \
                         || no "#1384: std.math.*" "'$got' erwartet '3.14159'"
else
  no "#1384: std.math.*" "$(grep -m1 -iE 'error' "$TMP/wcstd.log")"
fi

# Ein vertippter Pfad darf nicht wie ein leeres Verzeichnis aussehen.
printf 'import std.io;\nimport gibtsnicht.*;\nfn main(): int64 { return 0; }\n' > "$TMP/wcbad.lyx"
msg="$(timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/wcbad.lyx" -o "$TMP/wcbad" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && echo "$msg" | grep -q "Wildcard-Import"; then
  ok "#1384: unbekanntes Verzeichnis wird gemeldet"
else
  no "#1384: unbekanntes Verzeichnis" "rc=$rc"
fi

# Der gewoehnliche Import bleibt unveraendert.
out "#1384: einzelner Import unveraendert" 'import std.io;
fn main(): int64 { PrintLn("da"); return 0; }' "da"

# ===========================================================================
# #1509 — @stack_limit mit Tiefenzaehler
# ===========================================================================

# Das Beispiel aus der Doku, woertlich.
out "#1509: Tiefenzaehler wird als Nachweis anerkannt" 'import std.io;
@stack_limit(4096)
fn ParseExpr(depth: int64): int64 {
  if (depth > 64) { panic("Maximale Parse-Tiefe ueberschritten"); }
  if (depth >= 3) { return depth; }
  return ParseExpr(depth + 1);
}
fn main(): int64 { PrintLn(IntToStr(ParseExpr(0))); return 0; }' "3"

# Ohne Fortschritt ist nichts bewiesen — der Zaehler bliebe stehen.
meldet "#1509: ohne Fortschritt weiter abgewiesen" 'import std.io;
@stack_limit(4096)
fn Endlos(n: int64): int64 { return Endlos(n); }
fn main(): int64 { PrintLn(IntToStr(Endlos(1))); return 0; }' "nicht nachweisbar"

# Ohne Schranke ebenso — der Zaehler laeuft ins Leere.
meldet "#1509: ohne Waechter weiter abgewiesen" 'import std.io;
@stack_limit(4096)
fn OhneWaechter(depth: int64): int64 { return OhneWaechter(depth + 1); }
fn main(): int64 { PrintLn(IntToStr(OhneWaechter(0))); return 0; }' "nicht nachweisbar"

# Nicht-rekursiv mit @stack_limit muss unveraendert durchgehen.
out "#1509: nicht-rekursive Funktion unveraendert" 'import std.io;
@stack_limit(1024)
fn Flach(a: int64): int64 { return a * 2; }
fn main(): int64 { PrintLn(IntToStr(Flach(21))); return 0; }' "42"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
