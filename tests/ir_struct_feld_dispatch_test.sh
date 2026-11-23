#!/usr/bin/env bash
# tests/ir_struct_feld_dispatch_test.sh -- zwei Defekte des IR-Wegs (#2611, #2628).
#
#   #2611  Ein Feld vom WERT-STRUCT-Typ liegt inline im Objekt. Die Zuweisung
#          `self.Clip := MkR(0, 0, w, h)` legte aber nur EIN Wort ab: die
#          ADRESSE der Struktur. Das Lesen nimmt (seit #2542) die Feldadresse
#          und las damit genau diesen Zeiger als `Clip.Left` -- ein Rechteck
#          aus Muell, das jede Schnittmenge leer machte, ohne irgendetwas
#          auszuloesen. Dazu kannten die Inline-Fragen nur die EIGENE Unit:
#          bei einer importierten Klasse fiel die Antwort auf 0, der Zugriff
#          nahm den LOAD-Zweig und `z.Clip.Left` von aussen faultete.
#
#   #2628  Die virtuelle Dispatch erzeugte einen Vergleichszweig nur fuer eine
#          Unterklasse, die die Methode SELBST ueberschreibt. Bei drei Stufen
#          (`C extends B extends A`, nur B ueberschreibt) entstand fuer tid==C
#          kein Zweig: der Aufruf ueber eine `A`-Referenz landete im Nachspann
#          und rief A -- 1 statt 2.
#
# GEPRUEFT WIRD DER WERT bzw. der Rueckgabecode, nicht die Uebersetzung: beide
# Faelle uebersetzten klaglos und rechneten still falsch.
#
# WARUM HIER KEIN lyxos: der lokale LBF-Lader fuehrt das Abbild unter LINUX
# aus; alles, was Speicher anfordert (hier jedes `new`), bekaeme eine
# Muelladresse (#1832). Gemessen wird darum auf arm64 und riscv -- derselbe
# Weg durch ir_lower, auf dem beide Defekte gemeldet wurden -- und x86 als
# Gegenprobe: dort war es immer richtig, und eine Aenderung an ir_lower, die
# den x86-Pfad beruehrt, faellt hier auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen

# name, quelltext (Hauptprogramm), erwarteter Rueckgabewert, [unit-quelltext]
fall() {
  printf '%s\n' "$2" > "$TMP/p.lyx"
  if [ -n "$4" ]; then printf '%s\n' "$4" > "$TMP/istru2611.lyx"; fi
  for ziel in linux arm64 riscv; do
    local q=""
    if [ "$ziel" = "arm64" ]; then
      [ -n "$QEMU_ARM64" ] && q="$QEMU_ARM64"
      if [ -z "$q" ]; then echo "SKIP arm64/$1: qemu fehlt -- ohne Laufzeit misst das nichts"; continue; fi
    elif [ "$ziel" = "riscv" ]; then
      [ -n "$QEMU_RISCV64" ] && q="$QEMU_RISCV64"
      if [ -z "$q" ]; then echo "SKIP riscv/$1: qemu fehlt -- ohne Laufzeit misst das nichts"; continue; fi
    fi
    if ! timeout 200 "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/p.lyx" --target="$ziel" -o "$TMP/p.out" >"$TMP/p.log" 2>&1; then
      echo "FAIL $ziel/$1: uebersetzt nicht: $(grep -im1 error "$TMP/p.log")"; FAIL=$((FAIL+1)); continue
    fi
    timeout 30 $q "$TMP/p.out" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $ziel/$1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $ziel/$1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  done
}

# ===========================================================================
# #2611 -- Wert-Struct als Feld
# ===========================================================================

# Der Kern: in der Methode gelesen muss dasselbe herauskommen wie von aussen.
# Gemessen wird die SUMME zweier Felder beider Wege; der alte Zustand gab in
# der Methode einen Haldenzeiger und faellt damit nicht zufaellig richtig aus.
fall "wertstruct_feld_innen_wie_aussen" \
'type TR = struct { Left: int64; Top: int64; Right: int64; Bottom: int64; };
fn MkR(l: int64, t: int64, r: int64, b: int64): TR {
  var x: TR; x.Left := l; x.Top := t; x.Right := r; x.Bottom := b; return x;
}
type TZ = class {
  Clip: TR;
  org: int64;
  fn Create(w: int64): void { self.org := 3; self.Clip := MkR(1, 2, w, 4); }
  fn InnenL(): int64 { return self.Clip.Left; }
  fn InnenR(): int64 { return self.Clip.Right; }
};
fn main(): int64 {
  var z: TZ := new TZ(40);
  if (z.InnenL() != z.Clip.Left) { return 11; }
  if (z.InnenR() != z.Clip.Right) { return 12; }
  if (z.InnenL() != 1) { return 13; }
  if (z.InnenR() != 40) { return 14; }
  if (z.org != 3) { return 15; }
  return 0;
}' 0

# Das Nachbarfeld darf die Kopie nicht abbekommen: 32 Byte Clip, dann org.
# Mit einem Wort-Store stand bei +8 noch die 0 des frischen Objekts.
fall "wertstruct_feld_struct_in_struct" \
'type TR = struct { a: int64; b: int64; };
fn MkR(a: int64, b: int64): TR { var x: TR; x.a := a; x.b := b; return x; }
type TS = struct { innen: TR; z: int64; };
fn main(): int64 {
  var s: TS;
  s.z := 9;
  s.innen := MkR(5, 6);
  if (s.innen.a != 5) { return 21; }
  if (s.innen.b != 6) { return 22; }
  if (s.z != 9) { return 23; }
  return 0;
}' 0

# Die Zuweisung ist eine KOPIE, keine Umbiegung: das Original bleibt heil.
fall "wertstruct_feld_ist_kopie" \
'type TR = struct { a: int64; b: int64; };
type TS = struct { innen: TR; };
fn main(): int64 {
  var q: TR; q.a := 1; q.b := 2;
  var s: TS;
  s.innen := q;
  s.innen.a := 7;
  if (q.a != 1) { return 31; }
  if (s.innen.a != 7) { return 32; }
  if (s.innen.b != 2) { return 33; }
  return 0;
}' 0

# IMPORTIERTE Klasse: dieselbe Frage nach der Inline-Lage, aber die
# Deklaration steht in einer anderen Unit. Von aussen gelesen faultete das,
# nachdem die Zuweisung richtig kopierte -- die Inline-Antwort kannte nur die
# eigene Unit.
fall "wertstruct_feld_importierte_klasse" \
'import istru2611;
fn main(): int64 {
  var z: TZ := new TZ(940, 620);
  if (z.ClipLinks() != 0) { return 41; }
  if (z.Clip.Left != 0) { return 42; }
  if (z.ClipRechts() != 940) { return 43; }
  if (z.Clip.Right != 940) { return 44; }
  if (!RContains(z.Clip, 2, 0)) { return 45; }
  if (!z.Treffer(2, 0)) { return 46; }
  return 0;
}' 0 \
'unit istru2611;
pub type TR = struct { Left: int64; Top: int64; Right: int64; Bottom: int64; };
pub fn MkR(l: int64, t: int64, r: int64, b: int64): TR {
  var x: TR; x.Left := l; x.Top := t; x.Right := r; x.Bottom := b; return x;
}
pub fn RContains(r: TR, x: int64, y: int64): bool {
  if (x < r.Left) { return false; }
  if (y < r.Top) { return false; }
  if (x >= r.Right) { return false; }
  if (y >= r.Bottom) { return false; }
  return true;
}
pub type TZ = class {
  Clip: TR;
  org_x: int64;
  org_y: int64;
  fn Create(w: int64, h: int64): void {
    self.org_x := 0; self.org_y := 0;
    self.Clip := MkR(0, 0, w, h);
  }
  fn Treffer(x: int64, y: int64): bool {
    if (!RContains(self.Clip, x + self.org_x, y + self.org_y)) { return false; }
    return true;
  }
  fn ClipLinks(): int64 { return self.Clip.Left; }
  fn ClipRechts(): int64 { return self.Clip.Right; }
};'

# GEGENPROBE: ein Feld vom KLASSEN-Typ ist eine Referenz und darf NICHT
# kopiert werden -- sonst zeigte das Feld auf eine Kopie und jede Aenderung am
# Original waere unsichtbar.
fall "klassenfeld_bleibt_referenz" \
'type TK = class { x: int64; };
type TH = class { k: TK; };
fn main(): int64 {
  var k: TK := new TK();
  k.x := 5;
  var h: TH := new TH();
  h.k := k;
  k.x := 9;
  if (h.k.x != 9) { return 51; }
  return 0;
}' 0

# ===========================================================================
# #2628 -- dritte Vererbungsstufe ueber eine Basisreferenz
# ===========================================================================

fall "dispatch_dritte_stufe" \
'type A = class { wert: int64; virtual fn Wer(): int64 { return 1; } };
type B = class extends A { override fn Wer(): int64 { return 2; } };
type C = class extends B { };
fn main(): int64 {
  var b: B := new B();
  var c: C := new C();
  var bb: A := b;
  var cc: A := c;
  if (bb.Wer() != 2) { return 61; }
  if (cc.Wer() != 2) { return 62; }
  if (c.Wer() != 2) { return 63; }
  return 0;
}' 0

# Vierte Stufe, und die unterste ueberschreibt wieder: jede Referenz auf
# dieselbe Instanz muss dieselbe Fassung treffen.
fall "dispatch_vierte_stufe" \
'type A = class { virtual fn Wer(): int64 { return 1; } };
type B = class extends A { override fn Wer(): int64 { return 2; } };
type C = class extends B { };
type D = class extends C { override fn Wer(): int64 { return 4; } };
fn main(): int64 {
  var d: D := new D();
  var da: A := d;
  var db: B := d;
  var dc: C := d;
  if (da.Wer() != 4) { return 71; }
  if (db.Wer() != 4) { return 72; }
  if (dc.Wer() != 4) { return 73; }
  if (d.Wer() != 4) { return 74; }
  return 0;
}' 0

# GEGENPROBE zur Dispatch: die BASIS selbst bleibt bei ihrer eigenen Fassung.
# Ein Test, der nur zeigt, dass die Unterklassen richtig treffen, waere auch
# von einer Dispatch erfuellt, die jedem Objekt die unterste Fassung gibt.
fall "dispatch_basis_bleibt_basis" \
'type A = class { virtual fn Wer(): int64 { return 1; } };
type B = class extends A { override fn Wer(): int64 { return 2; } };
type C = class extends B { };
fn main(): int64 {
  var a: A := new A();
  var aa: A := a;
  if (aa.Wer() != 1) { return 81; }
  if (a.Wer() != 1) { return 82; }
  return 0;
}' 0

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
