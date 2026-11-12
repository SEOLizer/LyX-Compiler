#!/usr/bin/env bash
# tests/simd_f32_test.sh — `parallel Array<f32>` auf den AUSFUEHRBAREN Zielen:
# x86-64 ELF und arm64 unter qemu. Gemessen wird der WERT, nicht das
# Vorhandensein von Befehlen.
#
# Warum es diesen Test gibt (#2183, #2184, #2185):
#
# Fuer den ELF-Weg gab es bis 1.2.18C keinen einzigen Test. Die vorhandenen
# Faelle `simd_add`/`simd_store_load` stehen in lyxos_builtin_intrinsics_test.sh
# und messen ausschliesslich --target=lyxos. Deshalb fiel jahrelang nicht auf,
# dass der Schreibpfad in codegen_x86 die unteren 32 Bit des f64-BITMUSTERS
# ablegte statt den Wert zu wandeln: `v[0] := 7.0` schrieb still eine Null
# (bei 2.0, 3.0, 7.0 sind diese Bits 0), `v[0] := 1.1` ergab 2576980378.
# Gemessen gegen den Vorgaengerstand lieferte der Wertefall unten
# `0 0 0 0 0 4290772992` statt `6 3 14 40 6 2`.
#
# Alle Faelle nutzten zudem n = 4 und konnten den fehlenden Rest-Durchgang
# nicht sehen (#2184): die Schleife lief in 16-Byte-Schritten bis `rax >= n*4`,
# bei n = 5 also einen Block zu weit — aus beiden Quellen gelesen und ins Ziel
# GESCHRIEBEN. Der Waechterfall unten belegt das als WIRKUNG: mit alter
# Schleife (und schon gefixtem Schreibpfad) stehen hinter dem letzten Element
# fremde Werte, mit Rest-Durchgang Nullen.
#
# arm64 brach vorher mit "kennt Opcode 165 nicht" ab (IRO_SIMD_NEW fehlte),
# die NEON-Tabelle war also unerreichbar — und in allen vier Zeilen falsch
# kodiert (#2185). Jeder Fall laeuft deshalb auf BEIDEN Zielen; weichen sie
# voneinander ab, ist das ein Defekt, auch wenn ein Ziel plausibel aussieht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
QEMU="$QEMU_ARM64"
if [ -z "$QEMU" ]; then
  echo "HINWEIS: qemu-aarch64 fehlt — arm64 wird nur uebersetzt, nicht ausgefuehrt."
fi

# pruefe NAME ERWARTETE_AUSGABE QUELLTEXT
# Uebersetzt fuer x86-64 und arm64 und vergleicht die Ausgabe beider mit der
# Erwartung. `ulimit -c 0` haelt qemu-Abstuerze davon ab, .core-Dateien ins
# Repo zu legen (#2090).
pruefe() {
  local name="$1" erwartet="$2" quelle="$3"
  printf "%s" "$quelle" > "$TMP/c.lyx"

  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c.x86" >"$TMP/c.log" 2>&1); then
    echo "FAIL $name: x86-64 uebersetzte nicht"; sed -n '1,3p' "$TMP/c.log"; FAIL=$((FAIL+1)); return
  fi
  local got_x86
  got_x86=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/c.x86" 2>/dev/null | tr '\n' ' ' )
  got_x86="${got_x86% }"
  if [ "$got_x86" = "$erwartet" ]; then
    echo "PASS $name x86-64 ($got_x86)"; PASS=$((PASS+1))
  else
    echo "FAIL $name x86-64: '$got_x86' erwartet '$erwartet'"; FAIL=$((FAIL+1))
  fi

  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=arm64 -o "$TMP/c.a64" >"$TMP/a.log" 2>&1); then
    echo "FAIL $name: arm64 uebersetzte nicht"; sed -n '1,3p' "$TMP/a.log"; FAIL=$((FAIL+1)); return
  fi
  if [ -z "$QEMU" ]; then
    echo "PASS $name arm64 (nur uebersetzt — qemu fehlt)"; PASS=$((PASS+1)); return
  fi
  local got_a64
  got_a64=$( ulimit -c 0; cd "$TMP" && timeout 60 "$QEMU" "$TMP/c.a64" 2>/dev/null | tr '\n' ' ' )
  got_a64="${got_a64% }"
  if [ "$got_a64" = "$erwartet" ]; then
    echo "PASS $name arm64 ($got_a64)"; PASS=$((PASS+1))
  else
    echo "FAIL $name arm64: '$got_a64' erwartet '$erwartet'"; FAIL=$((FAIL+1))
  fi
}

# --- Ablage und Rueckgabe eines Elements (#2183) -----------------------------
# 7.0 ist der Fall, der vorher still 0 lieferte: die unteren 32 Bit von
# double(7.0) sind 0.
pruefe "element_ablegen" "7" '
import src.std.io;
fn main(): int64 {
  let v: parallel Array<f32>(4) = parallel Array<f32>(4);
  v[0] := 7.0;
  PrintLn(v[0] as int64);
  return 0;
}'

# Ein Wert, dessen f64-Bitmuster unten NICHT null ist: vorher kam hier
# 2576980378 heraus (die unteren 32 Bit von double(1.1)), jetzt die 1 aus
# 1.1f. Damit ist belegt, dass gewandelt und nicht abgeschnitten wird.
pruefe "element_kein_bitmuster" "1" '
import src.std.io;
fn main(): int64 {
  let v: parallel Array<f32>(4) = parallel Array<f32>(4);
  v[0] := 1.1;
  PrintLn(v[0] as int64);
  return 0;
}'

# Ganzzahliger Ausdruck in ein f32-Element: `v[0] := 2` muss 2.0f ablegen,
# nicht das Bitmuster der Ganzzahl 2 (das waere eine Denormalzahl, also 0).
pruefe "element_aus_ganzzahl" "2" '
import src.std.io;
fn main(): int64 {
  let v: parallel Array<f32>(4) = parallel Array<f32>(4);
  v[0] := 2;
  PrintLn(v[0] as int64);
  return 0;
}'

# --- die vier Vektoroperationen (#2183, #2185) ------------------------------
pruefe "vier_operationen" "14 6 40 2" '
import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>(4) = parallel Array<f32>(4);
  let b: parallel Array<f32>(4) = parallel Array<f32>(4);
  a[0] := 10.0; b[0] := 4.0;
  let s: parallel Array<f32> = a + b;
  let d: parallel Array<f32> = a - b;
  let m: parallel Array<f32> = a * b;
  let q: parallel Array<f32> = a / b;
  PrintLn(s[0] as int64);
  PrintLn(d[0] as int64);
  PrintLn(m[0] as int64);
  PrintLn(q[0] as int64);
  return 0;
}'

# Nicht nur Element 0: ein Wert im zweiten 16-Byte-Block und einer im ersten.
pruefe "mehrere_lanes" "6 3" '
import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>(8) = parallel Array<f32>(8);
  let b: parallel Array<f32>(8) = parallel Array<f32>(8);
  a[0] := 2.5; b[0] := 4.0;
  a[5] := 1.5; b[5] := 2.0;
  let c: parallel Array<f32> = a + b;
  PrintLn(c[0] as int64);
  PrintLn(c[5] as int64);
  return 0;
}'

# --- Rest-Durchgang (#2184) -------------------------------------------------
# Laengen, die nicht durch 4 teilbar sind. Summiert wird ueber ALLE Elemente,
# damit ein uebergangenes Rest-Element auffaellt.
#
# ACHTUNG, was diese Faelle NICHT zeigen: nachgemessen sind sie auch mit der
# alten Schleife gruen. Die schrieb HINTER das letzte Element, die Elemente
# selbst blieben richtig. Sie sichern also den neuen Rest-Durchgang gegen eine
# kuenftige Regression (ein Rest, der uebergangen wird), nicht den damaligen
# Ueberlauf — den belegt der Waechterfall darunter.
for n in 1 2 3 5 6 7 8; do
  pruefe "rest_n$n" "$((107 * n))" "
import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>($n) = parallel Array<f32>($n);
  let b: parallel Array<f32>($n) = parallel Array<f32>($n);
  var i: int64 := 0;
  while (i < $n) { a[i] := 100.0; b[i] := 7.0; i += 1; }
  let c: parallel Array<f32> = a + b;
  var s: int64 := 0;
  i := 0;
  while (i < $n) { s += c[i] as int64; i += 1; }
  PrintLn(s);
  return 0;
}"
done

# Waechter HINTER dem letzten Element (#2184). Acht Elemente werden angelegt
# und alle acht gefuellt, dann wird die Laenge auf 5 gesetzt: die Elemente
# 5..7 sind damit echter Speicher hinter dem Ende. Das Ziel wird frisch per
# mmap angelegt, ist also genullt — ein Ueberlauf schriebe dort a[i]+b[i].
#
# Dass alle acht gefuellt werden, ist der Punkt: waeren sie 0, schriebe der
# Ueberlauf eine Null und bliebe unsichtbar. Gegen den Zwischenstand
# (Schreibpfad gefixt, Schleife alt) meldet dieser Fall 3363962880.
pruefe "waechter_hinter_dem_ende" "535 0" '
import src.std.io;
fn main(): int64 {
  let a: parallel Array<f32>(8) = parallel Array<f32>(8);
  let b: parallel Array<f32>(8) = parallel Array<f32>(8);
  var i: int64 := 0;
  while (i < 8) { a[i] := 100.0; b[i] := 7.0; i += 1; }
  var pa: int64 := a as int64;
  var pb: int64 := b as int64;
  poke64(pa - 8, 5);
  poke64(pb - 8, 5);
  let c: parallel Array<f32> = a + b;
  var pc: int64 := c as int64;
  var s: int64 := 0;
  i := 0;
  while (i < 5) { s += c[i] as int64; i += 1; }
  PrintLn(s);
  var w: int64 := 0;
  w += peek32(pc + 5 * 4) as int64;
  w += peek32(pc + 6 * 4) as int64;
  w += peek32(pc + 7 * 4) as int64;
  PrintLn(w);
  return 0;
}'

# --- Rechnen MIT dem gelesenen Element --------------------------------------
# `v[i]` muss ein f64-WERT sein, kein Bitmuster: sonst rechnet jede
# Weiterverwendung auf den IEEE-Bits. Ohne den Elementtyp-Vermerk aus #2183
# galt das Element als Ganzzahl.
pruefe "element_rechnet_als_f64" "5" '
import src.std.io;
fn main(): int64 {
  let v: parallel Array<f32>(4) = parallel Array<f32>(4);
  v[0] := 2.5;
  var x: f64 := v[0] + 2.5;
  PrintLn(x as int64);
  return 0;
}'

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
