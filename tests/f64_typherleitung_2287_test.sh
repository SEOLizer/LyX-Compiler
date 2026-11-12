#!/usr/bin/env bash
# tests/f64_typherleitung_2287_test.sh — #2287: ein Local OHNE Typangabe, dessen
# Startwert ein eingebauter Gleitkommaleser ist, ist ein f64.
#
#   var v := peekf64(p);        // bis 1.2.22C: GANZZAHL
#   var v: f64 := peekf64(p);   // war immer richtig
#
# Ohne Typangabe trug das Local das IEEE-BITMUSTER und jede folgende Rechnung
# lief darauf: `v * v` ergab 0.0, eine laufende Summe ueber vier plausible
# Messwerte 9.24e18. Gemeldet wurde es als "f64-Akkumulation beschaedigt" mit
# Verdacht auf peekf64/pokef64 und Funktionsaufrufe — die rechnen alle richtig,
# sobald der Typ steht. Die Haelfte des Melderprogramms mit `var a: f64 := …`
# war deshalb korrekt, die andere nicht.
#
# Ursache: die Typherleitung fuer ein Local ohne Angabe fragte im
# Builtin-Zweig NUR nach Zeichenketten (cg_builtinReturnsPchar).
# cg_isF64Func kennt peekf64/peek32f seit #1502/#2160 — diese Stelle hat sie
# nicht gefragt.
#
# GEMESSEN WIRD DER WERT als Bitmuster (zeichengleich vergleichbar, keine
# Formatierungsfrage) auf x86_64, arm64 und riscv. Drei Gegenseiten im selben
# Programm, damit der Test nicht auch von einer zu weiten Regel erfuellt wird:
#   * `var n := peek64(p)` bleibt eine GANZZAHL,
#   * `var s := IntToStr(7)` bleibt eine ZEICHENKETTE (der Zweig daneben),
#   * die Rechnung laeuft ueber einen Funktionsaufruf in einer Schleife, also
#     in der Form des Melders.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

ZIELE="x86"
[ -n "$QEMU_ARM64" ] && ZIELE="$ZIELE arm64" || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv" || echo "HINWEIS: Emulator fuer riscv fehlt"

# Sollwerte als Bitmuster, mit Python gegengerechnet (nicht abgeschrieben).
ERW=$(python3 - <<'PY'
import struct
def b(x): return str(struct.unpack('<q', struct.pack('<d', x))[0])
# wert 3.5; produkt 12.25; summe 4 * (2*3.5) = 28.0
# Der Melderwert wird in DERSELBEN Reihenfolge akkumuliert wie im Programm —
# als Literal 31.4753 geschrieben waere er eine ULP daneben (…807 statt …806),
# und der Test haette den Compiler fuer die eigene Rechnung bestraft.
sum = 0.0; sumSq = 0.0
for v in (11.2, 23.1, -4.0, 0.5):
    sum += v; sumSq += v * v
print(' '.join([b(3.5), b(12.25), b(28.0), '42', 'sieben=7', b(sum + sumSq / 1000.0)]))
PY
)

cat > "$TMP/t.lyx" <<'LYX'
unit main;
import std.io;
import std.alloc;

fn doppelt(v: f64): f64 { return v * 2.0; }
fn finit(v: f64): bool { if (v != v) { return false; } return true; }

fn melderform(werte: int64, n: int64): f64 {
  // Die Form aus dem Melderfall: Local OHNE Typangabe, Kopie ueber den
  // Speicher, Hilfsfunktion im Schleifenrumpf.
  var sum: f64 := 0.0; var sumSq: f64 := 0.0; var i: int64 := 0;
  while (i < n) {
    var wert := peekf64(werte + i * 8);
    var kopie: int64 := alloc(8);
    pokef64(kopie, wert);
    var kopiert := peekf64(kopie);
    free(kopie, 8);
    if (finit(kopiert)) { sum := sum + kopiert; sumSq := sumSq + kopiert * kopiert; }
    i := i + 1;
  }
  return sum + sumSq / 1000.0;
}

fn main(): int64 {
  var b: int64 := alloc(8);
  var p: int64 := alloc(8);
  pokef64(p, 3.5);

  // 1. Local ohne Typangabe aus peekf64
  var wert := peekf64(p);
  pokef64(b, wert); PrintInt(peek64(b)); PrintStr(" "c);

  // 2. Produkt daraus
  pokef64(b, wert * wert); PrintInt(peek64(b)); PrintStr(" "c);

  // 3. Laufende Summe mit Funktionsaufruf in der Schleife
  var summe: f64 := 0.0;
  var i: int64 := 0;
  while (i < 4) { summe := summe + doppelt(wert); i := i + 1; }
  pokef64(b, summe); PrintInt(peek64(b)); PrintStr(" "c);

  // 4. GEGENSEITE: peek64 ohne Typangabe bleibt eine Ganzzahl.
  poke64(p, 42);
  var zahl := peek64(p);
  PrintInt(zahl + 0); PrintStr(" "c);

  // 5. GEGENSEITE: der Zeichenkettenzweig daneben bleibt unberuehrt.
  var text := IntToStr(7);
  PrintStr("sieben="c); PrintStr(text); PrintStr(" "c);

  // 6. Der Melderfall selbst.
  var werte: int64 := alloc(32);
  pokef64(werte, 11.2); pokef64(werte + 8, 23.1);
  pokef64(werte + 16, 0 - 4.0); pokef64(werte + 24, 0.5);
  pokef64(b, melderform(werte, 4)); PrintInt(peek64(b));
  PrintStr("\n"c);
  return 0;
}
LYX

for z in $ZIELE; do
  opt=""; q=""
  [ "$z" = arm64 ] && { opt="--target=arm64"; q="$QEMU_ARM64"; }
  [ "$z" = riscv ] && { opt="--target=riscv"; q="$QEMU_RISCV64"; }
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $opt "$TMP/t.lyx" -o "$TMP/t.$z" >"$TMP/t.$z.log" 2>&1); then
    no "$z" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/t.$z.log")"; continue
  fi
  got=$( cd "$TMP" && timeout 60 $q "$TMP/t.$z" 2>&1 | tr '\n' ' ' ); got="${got% }"
  if [ "$got" = "$ERW" ]; then ok "$z: $got"
  else no "$z" "'$got' erwartet '$ERW'"; fi
done

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
