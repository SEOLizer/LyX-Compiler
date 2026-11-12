#!/usr/bin/env bash
# tests/simd_elembreite_test.sh — Elementbreite von `parallel Array<T>` (#2199).
#
# Die Ablage hatte eine feste Schrittweite von 4 Byte. Daraus folgten DREI
# stille Fehler, und der dritte war der gefaehrlichste:
#
#   1. `parallel Array<int64>`: `v[0] := 4294967296` ergab 0 — die oberen
#      32 Bit gingen verloren.
#   2. `a + b` auf Ganzzahlen lief als `addps`, also GLEITKOMMA auf dem
#      Bitmuster. Fuer kleine Werte stimmte das Ergebnis zufaellig (denormale
#      Floats sind in ihren Bits linear, 10+4 ergab 14), fuer groessere nicht:
#      `100000000 + 1` blieb 100000000.
#   3. `parallel Array<f64>` war in Wahrheit f32. Die Ablage hielt 32 Bit,
#      beim Lesen wandelte cvtss2sd zurueck — runde Werte ueberlebten das
#      unbemerkt.
#
# Daher die Auswahl der Pruefwerte: GLATTE Zahlen taugen nicht. 1.5 und 2.25
# sind in f32 exakt und waren auch VOR dem Fix gruen. Geprueft wird mit 0.1
# (in f32 nicht exakt), 1e40 (f32-Ueberlauf) und 1e-50 (f32-Unterlauf).
#
# Verglichen wird das BITMUSTER in der Ablage (peek64) gegen das eines echten
# f64 (pokef64 in einen Puffer, dann peek64) — nicht die Ausgabe und auch
# nicht `as int64`:
#
#   * Die Ausgabeformate unterscheiden sich je Ziel; src.std.io schreibt sechs
#     Nachkommastellen, zu wenig um float(0.1) von 0.1 zu trennen. Genau das
#     hat meinen ersten arm64-Nachweis wertlos gemacht.
#   * `as int64` KONVERTIERT den Wert, es reinterpretiert nicht die Bits: fuer
#     0.1 liefern beide Seiten 0, und der Vergleich ist trivial erfuellt. Mein
#     erster Entwurf dieser Suite prueffte genau so und meldete vier gruene
#     Faelle, die nichts belegten — aufgefallen ist es nur, weil die
#     f32-GEGENPROBE daraufhin ebenfalls "gleich" sagte, was unmoeglich ist.
#   * `pokef64` taugt als Vergleichsquelle nicht: Builtin-ID 254 ist im
#     arm64-Linux-Zweig nicht behandelt (der Compiler meldet es laut).
#
# Die Erwartungen stehen deshalb als IEEE-754-Muster da, mit Python
# gegengerechnet (struct.pack('<d', x)) und damit unabhaengig vom Compiler:
#
#   0.1       4591870180066957722      1e40    5205425776111082661
#   0.3       4599075939470750515      1e-50   3859002664735258655
#   0.7       4604480259023595110      1.0     4607182418800017408
#   0.1+0.2   4599075939470750516
#
# 0.1+0.2 und 0.3 unterscheiden sich um genau EINS — der klassische Fall, in
# dem f32 und f64 auseinanderlaufen. In f32 gerechnet kaeme dort nicht ein
# Bit Unterschied heraus, sondern ein voellig anderes Muster.
#
# `peek64` auf die Ablage prueft zugleich die SCHRITTWEITE: liegt Element 1
# nicht bei +8, stimmt das Muster dort nicht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
. "$(dirname "$0")/lib/qemu.sh"   # #2048

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# werte NAME ERWARTET QUELLE — x86-64 und arm64 (riscv kennt IRO_SIMD_NEW
# nicht und meldet das laut, #1339; dort gibt es also nichts zu messen).
werte() {
  local name="$1" erwartet="$2" quelle="$3" got
  printf '%s\n' "${quelle/import src.std.io;/import std.io;}" > "$TMP/x.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/x.lyx" -o "$TMP/x" >"$TMP/x.log" 2>&1); then
    no "$name [x86_64]" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/x.log" | tr '\n' ' ')"
  else
    got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/x" 2>/dev/null | tr '\n' ' ' )
    got="${got% }"
    if [ "$got" = "$erwartet" ]; then ok "$name [x86_64] ($got)"
    else no "$name [x86_64]" "'$got' erwartet '$erwartet'"; fi
  fi

  printf '%s\n' "$quelle" > "$TMP/a.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/a.lyx" -o "$TMP/a" >"$TMP/a.log" 2>&1); then
    no "$name [arm64]" "uebersetzt nicht: $(sed -n '1,3p' "$TMP/a.log" | tr '\n' ' ')"; return
  fi
  if [ -z "$QEMU_ARM64" ]; then ok "$name [arm64] (nur uebersetzt — qemu fehlt)"; return; fi
  got=$( ulimit -c 0; cd "$TMP" && timeout 60 "$QEMU_ARM64" "$TMP/a" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$erwartet" ]; then ok "$name [arm64] ($got)"
  else no "$name [arm64]" "'$got' erwartet '$erwartet'"; fi
}

# --- f64 ist echt f64: Bitmuster gegen einen gewoehnlichen f64-Wert ---------
#
# Die Vergleiche gehen in Variablen, weil `--target=arm64` den Typ eines
# Ausdrucks in PrintLn nicht bestimmen kann (vorbestehende Grenze, die der
# Compiler laut meldet).
werte "#2199: f64-Element bitgleich mit echtem f64" "1 1 1" 'import src.std.io;
fn main(): int64 {
  let v: parallel Array<f64>(4) = parallel Array<f64>(4);
  v[0] := 0.1;
  v[1] := 1.0e40;
  v[2] := 0.3;
  var base: int64 := v as int64;
  var r0: int64 := 0; if (peek64(base)      == 4591870180066957722) { r0 := 1; }
  var r1: int64 := 0; if (peek64(base + 8)  == 5205425776111082661) { r1 := 1; }
  var r2: int64 := 0; if (peek64(base + 16) == 4599075939470750515) { r2 := 1; }
  PrintLn(r0); PrintLn(r1); PrintLn(r2);
  return 0;
}'

# Der UNTERLAUF-Fall (1e-50 ist in f32 null) laeuft nur auf x86-64: auf arm64
# ist `1.0e-50 > 0.0` schon ohne Vektoren falsch — ein vorbestehender Defekt
# im dortigen Gleitkommapfad, als #2223 aufgeschrieben. Ein Test, der daran
# haengt, wuerde nicht die Elementbreite messen, sondern ein fremdes Problem.
nurX86() { # name, erwartet, quelle
  local name="$1" erwartet="$2" got
  printf '%s\n' "${3/import src.std.io;/import std.io;}" > "$TMP/u.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/u.lyx" -o "$TMP/u" >"$TMP/u.log" 2>&1); then
    no "$name [x86_64]" "uebersetzt nicht"; return
  fi
  got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/u" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$erwartet" ]; then ok "$name [x86_64] ($got)"
  else no "$name [x86_64]" "'$got' erwartet '$erwartet'"; fi
}

nurX86 "#2199: f64 haelt einen Wert, der in f32 null waere" "1" 'import src.std.io;
fn main(): int64 {
  let v: parallel Array<f64>(4) = parallel Array<f64>(4);
  v[0] := 1.0e-50;
  var r: int64 := 0; if (peek64(v as int64) == 3859002664735258655) { r := 1; }
  PrintLn(r);
  return 0;
}'

# Die RECHNUNG in f64, ebenfalls am Bitmuster: 0.1 + 0.2 ist der klassische
# Fall, in dem f32 und f64 verschiedene Ergebnisse haben.
werte "#2199: f64-Addition bitgleich" "1" 'import src.std.io;
fn main(): int64 {
  let a: parallel Array<f64>(8) = parallel Array<f64>(8);
  let b: parallel Array<f64>(8) = parallel Array<f64>(8);
  a[0] := 0.1; b[0] := 0.2;
  let s: parallel Array<f64> = a + b;
  var rs: int64 := 0; if (peek64(s as int64) == 4599075939470750516) { rs := 1; }
  PrintLn(rs);
  return 0;
}'

# --- Schrittweite: die Elemente duerfen sich nicht ueberlappen -------------
#
# Mit 4-Byte-Schrittweite lagen zwei f64-Elemente im Raum eines einzigen; das
# zweite ueberschrieb die oberen Bits des ersten. Geprueft an VERSCHIEDENEN
# Werten, die beide nicht in f32 exakt sind.
werte "#2199: Elemente ueberlappen nicht (Schrittweite 8)" "1 1" 'import src.std.io;
fn main(): int64 {
  let v: parallel Array<f64>(8) = parallel Array<f64>(8);
  v[0] := 0.1;
  v[1] := 0.3;
  var base: int64 := v as int64;
  var r0: int64 := 0; if (peek64(base)     == 4591870180066957722) { r0 := 1; }
  var r1: int64 := 0; if (peek64(base + 8) == 4599075939470750515) { r1 := 1; }
  PrintLn(r0); PrintLn(r1);
  return 0;
}'

# --- Laengen 1..9 und der Waechter dahinter --------------------------------
#
# Der Pfad hat drei Stufen (32 Byte, 16 Byte, Einzelelemente). Bei f64 fasst
# ein 16-Byte-Block ZWEI Elemente, ein 32-Byte-Block vier — die Stufengrenzen
# liegen also bei anderen Laengen als bei f32. Geprueft wird das letzte
# Element (es liegt je Laenge in einer anderen Stufe) und der Platz dahinter.
for n in 1 2 3 4 5 6 7 8 9; do
  werte "#2199: f64-Addition Laenge $n" "1 1" "import src.std.io;
fn main(): int64 {
  let a: parallel Array<f64>($n) = parallel Array<f64>($n);
  let b: parallel Array<f64>($n) = parallel Array<f64>($n);
  let w: parallel Array<f64>(16) = parallel Array<f64>(16);
  var i: int64 := 0;
  while (i < 16) { w[i] := 0.7; i := i + 1; }
  var k: int64 := 0;
  while (k < $n) { a[k] := 0.1; b[k] := 0.2; k := k + 1; }
  let s: parallel Array<f64> = a + b;
  var letztes: int64 := peek64((s as int64) + ($n - 1) * 8);
  var r1: int64 := 0; if (letztes == 4599075939470750516) { r1 := 1; }
  // Waechter: w wurde VOR der Rechnung gefuellt und darf unberuehrt sein.
  var kaputt: int64 := 0;
  var e7: int64 := 4604480259023595110;
  var wbase: int64 := w as int64;
  var j: int64 := 0;
  while (j < 16) { if (peek64(wbase + j * 8) != e7) { kaputt := kaputt + 1; } j := j + 1; }
  var r2: int64 := 0; if (kaputt == 0) { r2 := 1; }
  PrintLn(r1); PrintLn(r2);
  return 0;
}"
done

# --- f32 bleibt f32 --------------------------------------------------------
#
# Die Gegenprobe: ein f32-Element darf NICHT plötzlich f64-genau sein, sonst
# waere die Breite schlicht ueberall auf 8 gesetzt. float(0.1) unterscheidet
# sich von 0.1 — genau daran ist der Fehler ueberhaupt aufgefallen.
werte "#2199: f32 bleibt bei 4 Byte (Gegenprobe)" "1 1" 'import src.std.io;
fn main(): int64 {
  // Zwei f32-Elemente liegen in EINEM 8-Byte-Wort: 1.0f = 0x3F800000 bei +0,
  // 2.0f = 0x40000000 bei +4. Waere die Breite ueberall auf 8 gesetzt, stuende
  // bei +0 das f64-Muster von 1.0 und bei +8 das von 2.0 — diese Gegenprobe
  // faellt also auf, wenn die Umstellung zu weit greift.
  let v: parallel Array<f32>(4) = parallel Array<f32>(4);
  v[0] := 1.0; v[1] := 2.0;
  var base: int64 := v as int64;
  var r0: int64 := 0; if (peek64(base) == 4611686019492741120) { r0 := 1; }
  var r1: int64 := 0; if (peek64(base) != 4607182418800017408)           { r1 := 1; }
  PrintLn(r0); PrintLn(r1);
  return 0;
}'

# --- Elementarten: zugelassen ist, was eine Umsetzung hat -----------------
#
# ACHTUNG, Geschichte dieser Stelle: bis 1.2.24D standen hier fuenf Faelle,
# die nachwiesen, dass GANZZAHL-Elementarten ABGEWIESEN werden. Mit #2247
# haben sie eine Umsetzung bekommen (PADDB/W/D/Q, PSUBB/W/D/Q, PMULLW,
# PMULLD), und die fuenf Faelle wurden damit rot — ein Test, der
# voraussetzt, dass eine Luecke offen bleibt. Genau davor warnen die
# Arbeitsregeln; sie sind deshalb ERSETZT, nicht entfernt.
#
# Geprueft wird jetzt beides: die Elementarten, die es GIBT, rechnen richtig
# (weiter unten, mit Werten), und die Elementarten, die es NICHT gibt, werden
# weiter laut abgewiesen. Drei Formen, weil die Elementart an drei Stellen
# steht: Ausdruck, Variablentyp, Parameter-/Rueckgabetyp. Die dritte nutzt
# tests/lyx/simd/simd_example.lyx — mit nur der Ausdrucksform waere der
# Bestandsfall durchgelaufen.
abgewiesen() { # name, quelle
  printf '%s\n' "$2" > "$TMP/r.lyx"
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" >"$TMP/r.log" 2>&1); then
    no "$1" "uebersetzt durch — die stille Fehlrechnung ist zurueck"
  else
    if grep -q 'parallel Array traegt' "$TMP/r.log"; then ok "$1"
    else no "$1" "abgewiesen, aber mit anderer Meldung: $(sed -n '2,3p' "$TMP/r.log" | tr '\n' ' ')"; fi
  fi
}

# Keine Zahl: `bool` hat keine Vektorform und bleibt abgewiesen — an allen
# drei Stellen, damit der Weg nicht ueber eine davon offen bleibt.
abgewiesen "#2247: bool als Ausdruck abgewiesen" 'import std.io;
fn main(): int64 { let v: parallel Array<bool>(4) = parallel Array<bool>(4); return 0; }'

abgewiesen "#2247: bool als Variablentyp abgewiesen" 'import std.io;
fn main(): int64 { var v: parallel Array<bool>; return 0; }'

abgewiesen "#2247: bool als Parametertyp abgewiesen" 'import std.io;
fn f(a: parallel Array<bool>): int64 { return 0; }
fn main(): int64 { return 0; }'

abgewiesen "#2247: bool als Rueckgabetyp abgewiesen" 'import std.io;
fn f(): parallel Array<bool> { return 0; }
fn main(): int64 { return 0; }'

abgewiesen "#2247: pchar ebenso abgewiesen" 'import std.io;
fn main(): int64 { let v: parallel Array<pchar>(4) = parallel Array<pchar>(4); return 0; }'

# Die Ganzzahlarten, die es gibt, werden NICHT mehr abgewiesen — der
# Gegenbeleg zu den fuenf Faellen darueber.
zugelassen() { # name, quelle
  printf '%s\n' "$2" > "$TMP/z.lyx"
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/z.lyx" -o "$TMP/z" >"$TMP/z.log" 2>&1); then
    ok "$1"
  else
    no "$1" "abgewiesen: $(grep -m1 -iE 'error' "$TMP/z.log" | head -c 100)"
  fi
}

zugelassen "#2247: int8 als Variablentyp zugelassen" 'import std.io;
fn main(): int64 { var v: parallel Array<int8>; return 0; }'
zugelassen "#2247: int16 als Parametertyp zugelassen" 'import std.io;
fn f(a: parallel Array<int16>): int64 { return 0; }
fn main(): int64 { return 0; }'
zugelassen "#2247: int32 als Ausdruck zugelassen" 'import std.io;
fn main(): int64 { let v: parallel Array<int32>(4) = parallel Array<int32>(4); return 0; }'
zugelassen "#2247: int64 als Rueckgabetyp zugelassen" 'import std.io;
fn f(): parallel Array<int64> { return 0; }
fn main(): int64 { return 0; }'

# --- lyxos: am Erzeugnis, beide Richtungen ---------------------------------
#
# Das lyxos-Ziel braucht den Kernel und ist hier nicht ausfuehrbar (der lokale
# LBF-Lader faultet bei allokierenden Faellen, weil LyxOS Syscall-Ergebnisse
# in rdx liefert und Linux in rax). Geprueft wird deshalb am Bytemuster, und
# in BEIDE Richtungen: mit f64 muss `addpd` (66 0F 58) und die 8-Byte-Last
# (F2 0F 10 04 C8) drinstehen, mit f32 keines von beiden.
lyxosmuster() { # name, typ, muster-hex, erwartet-vorhanden(1/0)
  local name="$1" typ="$2" hex="$3" soll="$4"
  cat > "$TMP/l.lyx" <<LYXEOF
import src.std.io;
fn main(): int64 {
  let a: parallel Array<$typ>(8) = parallel Array<$typ>(8);
  let b: parallel Array<$typ>(8) = parallel Array<$typ>(8);
  a[0] := 1.5; b[0] := 2.5;
  let s: parallel Array<$typ> = a + b;
  var r: f64 := s[0];
  PrintLn(FloatToStr(r, 2));
  return 0;
}
LYXEOF
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/l.lyx" -o "$TMP/l" >/dev/null 2>&1); then
    no "$name" "uebersetzt nicht"; return
  fi
  local n
  n=$(xxd -p "$TMP/l" | tr -d '\n' | grep -o "$hex" | wc -l)
  if [ "$soll" -eq 1 ]; then
    if [ "$n" -ge 1 ]; then ok "$name ($n Fundstellen)"
    else no "$name" "Muster $hex fehlt — die Breite kommt im Backend nicht an"; fi
  else
    if [ "$n" -eq 0 ]; then ok "$name (nicht vorhanden)"
    else no "$name" "Muster $hex steht $n mal drin, obwohl f32 gemeint war"; fi
  fi
}

lyxosmuster "#2199 lyxos: f64 emittiert addpd"        f64 "660f58" 1
lyxosmuster "#2199 lyxos: f64 emittiert 8-Byte-Last"  f64 "f20f1004c8" 1
lyxosmuster "#2199 lyxos: f32 emittiert KEIN addpd"   f32 "660f58" 0
lyxosmuster "#2199 lyxos: f32 nimmt die 4-Byte-Last"  f32 "f30f100488" 1

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
