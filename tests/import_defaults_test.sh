#!/usr/bin/env bash
# tests/import_defaults_test.sh — #1342.
#
# Der Codegen sucht die Deklaration einer gerufenen Funktion nur in der eigenen
# Modulkette (WP-MEM-05). Kam sie aus einer anderen Unit, fand er sie nicht,
# und ein ausgelassener Parameter bekam, was gerade auf dem Stack lag —
# gemessen: -140735687454702 statt 5. Seit 1.0.16K wurde das immerhin gemeldet.
#
# Jetzt werden die Vorgaben eingesetzt. Die Knoten der importierten Unit gibt
# es nach dem Import nicht mehr, deshalb schreibt der Codegen die KONSTANTEN
# Vorgaben beim Einlesen ab und legt sie in eine Tabelle.
#
# ZUR AUSSAGEKRAFT: geprüft wird der gerechnete WERT, nicht dass es übersetzt.
# Der alte Zustand übersetzte ja auch — er rechnete nur mit Stack-Resten, und
# ein Test auf „läuft durch" wäre grün gewesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/dv"
cat > "$TMP/dv/lib.lyx" <<'EOF'
unit dv.lib;

pub fn WithDefault(a: int64, b: int64 = 5): int64 { return a - b; }
pub fn Zwei(a: int64, b: int64 = 2, c: int64 = 3): int64 { return a * 100 + b * 10 + c; }
pub fn MitF64(a: f64, b: f64 = 0.5): f64 { return a + b; }
pub fn MitBool(a: int64, b: bool = true): int64 { if (b) { return a; } return 0 - a; }
pub fn MitNeg(a: int64, b: int64 = 0 - 7): int64 { return a + b; }
EOF

cat > "$TMP/dv/nichtkonst.lyx" <<'EOF'
unit dv.nichtkonst;

pub fn Konst(): int64 { return 9; }
pub fn NichtKonst(a: int64, b: int64 = Konst()): int64 { return a + b; }
EOF

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! (cd "$TMP" && "$LYXC" --std-path="$ROOT" p.lyx -o p >/dev/null 2>&1); then
    no "$1" "uebersetzt nicht: $(cd "$TMP" && "$LYXC" --std-path="$ROOT" p.lyx -o p 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(cd "$TMP" && timeout 30 ./p 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Der Fall aus der Meldung
# ===========================================================================

out "#1342: ausgelassener Vorgabewert wird eingesetzt" 'import std.io;
import dv.lib;
fn main(): int64 { PrintLn(IntToStr(WithDefault(10))); return 0; }' "5"

# Angegeben schlaegt Vorgabe — sonst waere aus dem Fix ein Fehler in der
# Gegenrichtung geworden.
out "#1342: angegebener Wert schlaegt die Vorgabe" 'import std.io;
import dv.lib;
fn main(): int64 {
  PrintStr(IntToStr(WithDefault(10, 1))); PrintStr(" ");
  PrintLn(IntToStr(WithDefault(10, 0)));
  return 0;
}' "9 10"

# Zwei Vorgaben hintereinander, und der Fall dazwischen: eine angegeben, eine
# ausgelassen. Die Stellen muessen in der richtigen Reihenfolge gefuellt werden.
out "#1342: zwei Vorgaben, ganz und halb ausgelassen" 'import std.io;
import dv.lib;
fn main(): int64 {
  PrintStr(IntToStr(Zwei(1))); PrintStr(" ");
  PrintStr(IntToStr(Zwei(1, 4))); PrintStr(" ");
  PrintLn(IntToStr(Zwei(1, 4, 6)));
  return 0;
}' "123 143 146"

# ===========================================================================
# Andere Arten von Konstanten
# ===========================================================================

out "#1342: f64-, bool- und negative Vorgaben" 'import std.io;
import dv.lib;
fn main(): int64 {
  PrintStr(FloatToStr(MitF64(1.25), 2)); PrintStr(" ");
  PrintStr(IntToStr(MitBool(7))); PrintStr(" ");
  PrintLn(IntToStr(MitNeg(10)));
  return 0;
}' "1.75 7 3"

# ===========================================================================
# Was NICHT eingesetzt wird, bleibt gemeldet
# ===========================================================================

# Eine Vorgabe, die erst zur Laufzeit entsteht, kann beim Einlesen nicht
# abgeschrieben werden. Statt etwas zu raten, meldet sema weiterhin — und die
# Unit selbst meldet ohnehin, dass der Wert nicht feststeht.
printf 'import std.io;\nimport dv.nichtkonst;\nfn main(): int64 { PrintLn(IntToStr(NichtKonst(1))); return 0; }\n' > "$TMP/nk.lyx"
rm -f "$TMP/nk"
msg="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" nk.lyx -o nk 2>&1)"
if [ -f "$TMP/nk" ]; then
  no "#1342: nicht konstante Vorgabe bleibt gemeldet" "uebersetzt, statt zu melden"
else
  case "$msg" in
    *"Vorgabewert einer importierten Funktion"*) ok "#1342: nicht konstante Vorgabe bleibt gemeldet" ;;
    *"Default-Wert muss zur Uebersetzungszeit feststehen"*) ok "#1342: nicht konstante Vorgabe bleibt gemeldet" ;;
    *) no "#1342: nicht konstante Vorgabe bleibt gemeldet" "$(echo "$msg" | grep -i error | head -1)" ;;
  esac
fi

# Zu wenige Argumente OHNE Vorgabe bleiben ein Fehler.
printf 'import std.io;\nimport dv.lib;\nfn main(): int64 { PrintLn(IntToStr(Zwei())); return 0; }\n' > "$TMP/za.lyx"
rm -f "$TMP/za"
msg2="$(cd "$TMP" && "$LYXC" --std-path="$ROOT" za.lyx -o za 2>&1)"
if [ -f "$TMP/za" ]; then
  no "#1342: fehlendes Pflichtargument bleibt ein Fehler" "uebersetzt"
else
  case "$msg2" in
    *"Argument-Anzahl"*) ok "#1342: fehlendes Pflichtargument bleibt ein Fehler" ;;
    *) no "#1342: fehlendes Pflichtargument bleibt ein Fehler" "$(echo "$msg2" | grep -i error | head -1)" ;;
  esac
fi

# ===========================================================================
# Gegenprobe: Vorgaben in DERSELBEN Datei bleiben unveraendert
# ===========================================================================

out "#1342: Vorgaben derselben Datei unveraendert" 'import std.io;
fn Lokal(a: int64, b: int64 = 4): int64 { return a * b; }
fn main(): int64 {
  PrintStr(IntToStr(Lokal(3))); PrintStr(" ");
  PrintLn(IntToStr(Lokal(3, 5)));
  return 0;
}' "12 15"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
