#!/usr/bin/env bash
# tests/ir_inline_feld_test.sh -- inline liegende Aggregatfelder auf dem IR-Weg (#2542).
#
# `feld: [32]TR` als Klassenfeld hatte beim Schreiben die Basisadresse 0:
# `self.feld[0] := s` landete bei `0 + i*8` und faultete (CR2 = 0x10,
# `mov [rdx+rcx*8], rax` mit rdx=0). Gemeldet fuer --target=lyxos, gemessen
# aber ebenso auf arm64 und riscv -- der gemeinsame IR-Weg, wie schon bei
# #1786, #1787 und #1798. Auf --target=linux (AST-Weg) war derselbe
# Quelltext immer richtig.
#
# URSACHE (src/ir_lower.lyx): der IR-Weg gab JEDEM Klassenfeld acht Byte und
# gab das im Entwurfskommentar als Absicht aus ("Klasse: acht Byte je Feld",
# "Inline liegende Felder behaelt der IR-Weg als Zeiger zu acht Byte"). Ein
# `[32]TR` war damit ein nie gefuellter Zeigerplatz; der Elementzugriff las
# ihn als Basis. Der x86-Weg rechnet dagegen die echte Breite
# (cg_buildClassLayout, #1052/#1513) und behandelt den Feldnamen als ADRESSE
# (cg_emitInlineArrayAddr). Vier Stellen waren nachzuziehen: Layoutbreite,
# Feldzugriff (Adresse statt Laden), Elementzugriff (kein {cap,len}-Kopf,
# Schrittweite = Elementbreite) und die Zuweisung an ein Element
# (Struct-KOPIE statt Ablegen eines Wortes).
#
# Geprueft wird der WERT ueber den Rueckgabewert, nicht "laeuft durch": nach
# den ersten drei Stellen lief das Programm fehlerfrei und lieferte
# 0 / Adresse / 0. "Uebersetzt wieder" ist keine Aussage ueber "rechnet
# richtig" (#1789).
#
# WARUM HIER KEIN lyxos: der lokale LBF-Lader fuehrt das Abbild unter LINUX
# aus (Syscall-Ergebnis in rax statt rdx), und `new` fordert Speicher an --
# dieselbe Grenze wie in ir_struct_test.sh. arm64 und riscv gehen denselben
# Weg durch ir_lower.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

S='pub type TR = struct { a: int64; b: int64; c: int64; d: int64; };'

. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
fall() {  # name, rumpf, erwarteter Rueckgabewert
  printf '%s\n%s\n' "$S" "$2" > "$TMP/s.lyx"
  # linux als Gegenprobe: dort war es immer richtig. Beruehrt eine Aenderung
  # an ir_lower den AST-Weg, faellt es hier auf.
  for ziel in linux arm64 riscv; do
    local q=""
    if [ "$ziel" = "arm64" ]; then
      [ -n "$QEMU_ARM64" ] && q="$QEMU_ARM64"
      if [ -z "$q" ]; then echo "SKIP arm64/$1: qemu fehlt -- ohne Laufzeit misst das nichts"; continue; fi
    elif [ "$ziel" = "riscv" ]; then
      [ -n "$QEMU_RISCV64" ] && q="$QEMU_RISCV64"
      if [ -z "$q" ]; then echo "SKIP riscv/$1: qemu fehlt -- ohne Laufzeit misst das nichts"; continue; fi
    fi
    if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" --target="$ziel" -o "$TMP/s.out" >"$TMP/s.log" 2>&1; then
      echo "FAIL $ziel/$1: uebersetzt nicht: $(grep -im1 error "$TMP/s.log")"; FAIL=$((FAIL+1)); continue
    fi
    timeout 30 $q "$TMP/s.out" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $ziel/$1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $ziel/$1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  done
}

# --- 1. Die Form aus dem Issue: [N]TStruct als Klassenfeld ------------------
# Drei Ablagen, dann das erste Element zurueck. Vor dem Fix: SIGSEGV (139).
fall "inline_array_struct" \
  'pub type TBox = class {
  tiefe: int64;
  feld:  [32]TR;
  fn Create(): void { self.tiefe := 0; }
  fn Ablegen(v: int64): void {
    var s: TR;
    s.a := v; s.b := v + 1; s.c := v + 2; s.d := v + 3;
    self.feld[self.tiefe] := s;
    self.tiefe := self.tiefe + 1;
  }
  fn Holen(i: int64): int64 { var r: TR := self.feld[i]; return r.a; }
};
fn main(): int64 { var b: TBox := new TBox(); b.Ablegen(7); b.Ablegen(9); return b.Holen(0); }' 7

# Das ZWEITE Element: deckt die Schrittweite ab. Mit Schrittweite acht statt
# 32 kam hier der zweite Int64 des ERSTEN Elements heraus, nicht die 9.
fall "inline_array_schrittweite" \
  'pub type TBox = class {
  tiefe: int64;
  feld:  [32]TR;
  fn Create(): void { self.tiefe := 0; }
  fn Ablegen(v: int64): void {
    var s: TR;
    s.a := v; s.b := v + 1; s.c := v + 2; s.d := v + 3;
    self.feld[self.tiefe] := s;
    self.tiefe := self.tiefe + 1;
  }
  fn Holen(i: int64): int64 { var r: TR := self.feld[i]; return r.a; }
};
fn main(): int64 { var b: TBox := new TBox(); b.Ablegen(7); b.Ablegen(9); return b.Holen(1); }' 9

# ALLE vier Woerter eines Elements, nicht nur das erste: eine Kopie, die nur
# das fuehrende Wort schreibt, waere von den Faellen darueber erfuellt.
fall "inline_array_ganze_struktur" \
  'pub type TBox = class {
  feld: [8]TR;
  fn Create(): void { }
  fn Setzen(): void { var s: TR; s.a := 1; s.b := 2; s.c := 3; s.d := 4; self.feld[2] := s; }
  fn Summe(): int64 { var r: TR := self.feld[2]; return r.a + r.b + r.c + r.d; }
};
fn main(): int64 { var b: TBox := new TBox(); b.Setzen(); return b.Summe(); }' 10

# --- 2. Das Feld DAHINTER darf nicht ueberlappt werden ----------------------
# Die x86-Seite nennt genau das als Grund fuer die echte Breite (#1052:
# "ohne das ueberlappte das Folgefeld die Arraydaten"). Mit acht Byte fuer
# `feld` lag `hinten` INNERHALB der Arraydaten und wurde beim Schreiben
# des nullten Elements ueberschrieben.
fall "folgefeld_bleibt_heil" \
  'pub type TBox = class {
  vorn:  int64;
  feld:  [4]TR;
  hinten: int64;
  fn Create(): void { self.vorn := 3; self.hinten := 5; }
  fn Setzen(): void { var s: TR; s.a := 99; s.b := 99; s.c := 99; s.d := 99; self.feld[0] := s; }
};
fn main(): int64 { var b: TBox := new TBox(); b.Setzen(); return b.vorn + b.hinten; }' 8

# --- 3. Inline-STRUCT als Klassenfeld --------------------------------------
# Nicht im Issue gemeldet, aber beim Messen gefunden: derselbe
# Entwurfskommentar nennt "Struct-Feld" in einem Atemzug mit `[N]T`, und
# dasselbe Programm faultete auf arm64 und riscv.
fall "inline_struct_feld" \
  'pub type TBox = class {
  vorn:  int64;
  inner: TR;
  hinten: int64;
  fn Create(): void { self.vorn := 11; self.hinten := 99; }
  fn Setzen(v: int64): void { self.inner.a := v; self.inner.b := v + 1; }
  fn Hol(): int64 { return self.inner.a + self.inner.b; }
};
fn main(): int64 { var b: TBox := new TBox(); b.Setzen(20); return b.Hol(); }' 41

fall "inline_struct_nachbarn_heil" \
  'pub type TBox = class {
  vorn:  int64;
  inner: TR;
  hinten: int64;
  fn Create(): void { self.vorn := 11; self.hinten := 99; }
  fn Setzen(v: int64): void { self.inner.a := v; self.inner.b := v; self.inner.c := v; self.inner.d := v; }
};
fn main(): int64 { var b: TBox := new TBox(); b.Setzen(77); return b.vorn + b.hinten - 10; }' 100

# --- 4. SKALARE Elemente liefern den WERT, nicht ihre Adresse --------------
# Gegenprobe zur Aenderung selbst: `feld[i]` gibt bei STRUCT-Elementen die
# Adresse (ein Feldzugriff rechnet darauf weiter), bei skalaren Elementen den
# WERT. Ein erster Entwurf behandelte beides gleich -- dann kamen fuer
# `[N]int64` Adressen heraus, wo Zahlen erwartet werden. Dieser Fall haelt
# die Unterscheidung fest.
fall "inline_array_skalar" \
  'pub type TZ = class {
  zahlen: [16]int64;
  fn Create(): void { }
  fn Setzen(): void { self.zahlen[0] := 40; self.zahlen[3] := 2; }
  fn Summe(): int64 { return self.zahlen[0] + self.zahlen[3]; }
};
fn main(): int64 { var z: TZ := new TZ(); z.Setzen(); return z.Summe(); }' 42

# --- 5. Ein LOCAL `var a: [N]T` behaelt seinen {cap,len}-Kopf --------------
# Die Aenderung nimmt den Kopfzuschlag NUR fuer Inline-FELDER weg. Beim
# Local legt der IR-Weg seit #2262 einen Kopf an, und len() liest ihn. Waere
# der Zuschlag dort mit weggefallen, lasen alle Elementzugriffe daneben.
fall "local_array_unberuehrt" \
  'fn main(): int64 { var a: [4]int64; a[0] := 11; a[3] := 31; return a[0] + a[3]; }' 42

echo
echo "ir_inline_feld_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
