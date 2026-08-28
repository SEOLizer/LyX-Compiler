#!/usr/bin/env bash
# tests/ir_struct_test.sh — lokale Strukturen auf dem IR-Weg (#1835).
#
# `var r: TR; r.L := 1; r.R := 9; return r.L + r.R;` faultete auf arm64 und
# riscv (SIGSEGV), waehrend dasselbe Programm auf --target=linux 10 lieferte.
# Uebersetzt wurde in allen Faellen fehlerfrei und ohne Warnung.
#
# URSACHE (src/ir_lower.lyx, lowerStmt/NK_VAR_DECL): `var a: [N]T` ohne Init
# bekam mit dem ARM64-FIX Heap-Speicher, der Struktur-Fall daneben wurde nie
# nachgezogen. Der Slot blieb uninitialisiert — und `r.L := 1` lowert zu
# IRO_STORE_FIELD(offset, wert, BASIS), wobei Basis der WERT des Slots ist:
# bei einer Klasseninstanz der Heap-Zeiger, bei einer Struktur Muell.
#
# Der x86-Produktiv-Codegen erzeugt direkt aus dem AST und ist nicht betroffen
# — deshalb war dasselbe Programm als ELF richtig und auf jedem IR-Ziel kaputt.
#
# WARUM HIER KEIN lyxos: der lokale LBF-Lader fuehrt das Abbild unter LINUX
# aus. LyxOS liefert Syscall-Ergebnisse in rdx, Linux in rax — eine Struktur
# fordert Speicher an und bekaeme hier eine Muelladresse. Dieselbe Grenze wie
# bei den allokierenden Builtins (#1832). Gemessen wird darum auf arm64 und
# riscv; beide gehen denselben Weg durch ir_lower.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

S='pub type TR = struct { L: int64; R: int64; };'

fall() {  # name, rumpf, erwarteter Rueckgabewert
  printf '%s\n%s\n' "$S" "$2" > "$TMP/s.lyx"
  # x86 als Gegenprobe: dort war es immer richtig, und wenn eine Aenderung an
  # ir_lower den x86-Pfad beruehrt, faellt es hier auf.
  for ziel in linux arm64 riscv; do
    local q=""
    if [ "$ziel" = "arm64" ]; then
      command -v qemu-aarch64-static >/dev/null 2>&1 && q=qemu-aarch64-static
      [ -z "$q" ] && command -v qemu-aarch64 >/dev/null 2>&1 && q=qemu-aarch64
      if [ -z "$q" ]; then echo "SKIP arm64/$1: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
    elif [ "$ziel" = "riscv" ]; then
      command -v qemu-riscv64-static >/dev/null 2>&1 && q=qemu-riscv64-static
      [ -z "$q" ] && command -v qemu-riscv64 >/dev/null 2>&1 && q=qemu-riscv64
      if [ -z "$q" ]; then echo "SKIP riscv/$1: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
    fi
    if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" --target="$ziel" -o "$TMP/s.out" >"$TMP/s.log" 2>&1; then
      echo "FAIL $ziel/$1: uebersetzt nicht: $(grep -im1 error "$TMP/s.log")"; FAIL=$((FAIL+1)); continue
    fi
    timeout 30 $q "$TMP/s.out" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $ziel/$1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $ziel/$1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  done
}

# Die Grundform aus dem Issue. Gemessen wird der WERT, nicht nur "laeuft":
# eine Struktur, die Speicher bekommt, aber an der falschen Stelle liest,
# lieferte sonst unbemerkt 0.
fall "struct_lokal" \
  'fn main(): int64 { var r: TR; r.L := 1; r.R := 9; return r.L + r.R; }' 10

# Uebergabe an eine Funktion — der Lesepfad ueber eine fremde Basis.
fall "struct_als_parameter" \
  'fn S(r: TR): int64 { return r.L + r.R; }
fn main(): int64 { var r: TR; r.L := 1; r.R := 9; return S(r); }' 10

# Rueckgabe: einmal ueber eine Zwischenvariable, einmal direkt als Argument.
# Die zweite Form ist die aus #1834; sie geht auf lyxos noch einen anderen Weg,
# hier deckt sie den IR-Weg ab.
fall "struct_rueckgabe_variable" \
  'fn M(): TR { var r: TR; r.L := 1; r.R := 9; return r; }
fn main(): int64 { var v: TR := M(); return v.L + v.R; }' 10
fall "struct_rueckgabe_direkt" \
  'fn M(): TR { var r: TR; r.L := 1; r.R := 9; return r; }
fn S(r: TR): int64 { return r.L + r.R; }
fn main(): int64 { return S(M()); }' 10

# Interface-Dispatch mit struct-Ergebnis (Form aus #1834).
fall "interface_struct_direkt" \
  'pub type IQ = interface { fn Hol(i: int64): TR; };
pub type TQ = class implements IQ { fn Create(): void { } fn Hol(i: int64): TR { var r: TR; r.L := 1; r.R := 9; return r; } };
fn Drin(r: TR, x: int64): int64 { if (x >= r.L) { if (x <= r.R) { return 7; } } return 0; }
fn main(): int64 { var q: IQ := new TQ(); return Drin(q.Hol(0), 5); }' 7

# Eine Klassenvariable bekommt BEWUSST keinen Speicher aus dieser Aenderung:
# ein ausdrueckliches `null` soll null bleiben, damit eine vergessene
# Instanziierung auffaellt, statt still auf einen leeren Block zu zeigen.
#
# Ganz OHNE Startwert laesst sema eine Klassenvariable gar nicht erst zu
# ("Variable hat Klassentyp ohne Startwert — `new` oder `null` angeben") —
# ein erster Anlauf dieses Falls scheiterte daran. Genau deshalb greift der
# Struktur-Zweig nur bei Strukturen: fuer Klassen gibt es den Fall nicht.
fall "klasse_bleibt_null" \
  'pub type TK = class { a: int64; fn Create(): void { self.a := 5; } };
fn main(): int64 { var k: TK := null; if (k == null) { return 3; } return 4; }' 3

# Drei Felder und ein Feld hinter dem ersten: faende die Groessenrechnung nur
# das erste Feld, schriebe das dritte ueber das Ende hinaus.
fall "drei_felder" \
  'pub type TD = struct { A: int64; B: int64; C: int64; };
fn main(): int64 { var d: TD; d.A := 1; d.B := 2; d.C := 7; return d.A + d.B + d.C; }' 10

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
