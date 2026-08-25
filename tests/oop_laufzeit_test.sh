#!/usr/bin/env bash
# tests/oop_laufzeit_test.sh — Klassen auf den IR-Zielen AUSFUEHREN (#1767).
#
# Gemeldet war ein Page Fault unter --target=lyxos beim `new` (CR2 = 0x46).
# Die Ursache lag nicht im lyxos-Backend, sondern in ir_lower: seit #1388
# liegen die Parameter hinter dem Kratzstreifen (IR_BARG_SLOTS), der Zweig
# fuer `self` lud aber weiter aus Slot 0. Der Prolog spillt das Objektregister
# nach Slot 8, gelesen wurde Slot 0 — also ein uninitialisierter Stapelwert als
# Objektbasis, und der Konstruktor schrieb sein erstes Feld dorthin.
#
# Dasselbe traf jedes andere IR-Ziel. arm64 und riscv lassen sich hier
# ausfuehren, lyxos nicht — sie sind der Nachweis fuer eine Strecke, die alle
# drei teilen. Zusaetzlich deckte der Fall auf riscv einen zweiten Defekt auf:
# STORE_FIELD nahm den Feld-Offset aus imm statt aus dem DEST-Feld, jedes Feld
# landete also auf Offset 0.
#
# Seit #1773 deckt der Test auch den Dispatch ab: virtuell (extends +
# override) und ueber den Interface-Typ. Der Interface-Aufruf hatte bis dahin
# keine Aufloesung — er landete in der rumpflosen Methode der
# Interface-Deklaration, also in einer LEEREN Funktion, und lieferte, was
# zufaellig im Rueckgaberegister stand.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

lauf() { # ziel, binary  → Exit-Code oder 255 wenn kein Emulator
  case "$1" in
    riscv) command -v qemu-riscv64-static >/dev/null || return 255
           timeout 10 qemu-riscv64-static "$2" >/dev/null 2>&1; return $? ;;
    arm64) command -v qemu-aarch64-static >/dev/null || return 255
           timeout 10 qemu-aarch64-static "$2" >/dev/null 2>&1; return $? ;;
  esac
  return 255
}

run() { # name, quelltext, erwarteter exit-code
  for ziel in arm64 riscv; do
    printf "%s" "$2" > "$TMP/c.lyx"
    if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" --target=$ziel -o "$TMP/c" >"$TMP/c.log" 2>&1); then
      echo "FAIL $1 ($ziel): uebersetzt nicht: $(grep -m1 -iE 'error|Builtin-ID|Opcode' "$TMP/c.log")"
      FAIL=$((FAIL+1)); continue
    fi
    lauf "$ziel" "$TMP/c"; rc=$?
    if [ "$rc" -eq 255 ]; then
      echo "PASS $1 ($ziel, nur uebersetzt — kein Emulator)"; PASS=$((PASS+1))
    elif [ "$rc" -eq "$3" ]; then
      echo "PASS $1 ($ziel = $rc)"; PASS=$((PASS+1))
    else
      echo "FAIL $1 ($ziel): exit=$rc erwartet $3"; FAIL=$((FAIL+1))
    fi
  done
}

# Der Kern der Meldung: der Konstruktor schrieb seine Felder ueber einen
# Muellzeiger. Auf lyxos war das ein Page Fault, auf arm64 und riscv ein
# Segfault (139).
run "konstruktor_und_methode" \
  'pub type TWert = class { a: int64; b: int64; fn Create() { self.a := 42; self.b := 7; } fn Hole(): int64 { return self.a + self.b; } } fn main(): int64 { var w: TWert := new TWert(); return w.Hole(); }' 49

# Konstruktor mit Argument: self liegt im Param-Slot, die expliziten Parameter
# dahinter — die Verschiebung um methodParamBase muss stimmen.
run "konstruktor_mit_arg" \
  'pub type TP = class { x: int64; fn Create(v: int64) { self.x := v; } fn Wert(): int64 { return self.x; } } fn main(): int64 { var p: TP := new TP(37); return p.Wert(); }' 37

# Methode mit eigenem Argument: self UND Parameter muessen ankommen.
run "methode_mit_arg" \
  'pub type TP = class { x: int64; fn Create(v: int64) { self.x := v; } fn Add(d: int64): int64 { return self.x + d; } } fn main(): int64 { var p: TP := new TP(30); return p.Add(12); }' 42

# Drittes Feld: STORE_FIELD nahm den Offset aus imm (immer 0) — jedes Feld
# ueberschrieb das vorige, und nur das zuletzt geschriebene war lesbar.
run "drei_felder" \
  'pub type TD = class { a: int64; b: int64; c: int64; fn Create() { self.a := 1; self.b := 2; self.c := 3; } fn Summe(): int64 { return self.a * 100 + self.b * 10 + self.c; } } fn main(): int64 { var d: TD := new TD(); return d.Summe(); }' 123

# Feld schreiben, nachdem das Objekt steht — derselbe Weg, andere Richtung.
run "feld_nachtraeglich" \
  'pub type TS = class { v: int64; fn Create() { self.v := 5; } fn Setze(n: int64) { self.v := n; } fn Wert(): int64 { return self.v; } } fn main(): int64 { var s: TS := new TS(); s.Setze(23); return s.Wert(); }' 23

# ---------------------------------------------------------------------------
# Dispatch (#1773)
# ---------------------------------------------------------------------------
# Virtuell: ohne `virtual`/`override` ist der statische Aufruf richtig, mit
# ihnen muss die Methode der WIRKLICHEN Klasse laufen.
run "statisch_ohne_virtual" \
  'pub type TB = class { fn Create() {} fn W(): int64 { return 1; } } pub type TA = class extends TB { fn Create() {} fn W(): int64 { return 2; } } fn main(): int64 { var o: TB := new TA(); return o.W(); }' 1
run "virtuell_mit_override" \
  'pub type TB = class { fn Create() {} virtual fn W(): int64 { return 1; } } pub type TA = class extends TB { fn Create() {} override fn W(): int64 { return 2; } } fn main(): int64 { var o: TB := new TA(); return o.W(); }' 2

# Interface: die implementierende Methode braucht KEIN `virtual` — die Zusage
# steckt im `implements` (ebnf.md §Interfaces).
run "interface_einfach" \
  'pub type IWert = interface { fn Hole(): int64; } pub type TWert = class implements IWert { a: int64; b: int64; fn Create() { self.a := 42; self.b := 7; } fn Hole(): int64 { return self.a + self.b; } } fn Mach(): IWert { return new TWert() as IWert; } fn main(): int64 { var w: IWert := Mach(); return w.Hole(); }' 49
# Zwei Klassen an einem Interface: der Aufruf muss die richtige treffen.
run "interface_zwei_klassen" \
  'pub type IF = interface { fn W(): int64; } pub type TA = class implements IF { fn Create() {} fn W(): int64 { return 10; } } pub type TB = class implements IF { fn Create() {} fn W(): int64 { return 20; } } fn hol(n: int64): IF { if n == 0 { return new TA() as IF; } return new TB() as IF; } fn main(): int64 { var a: IF := hol(0); var b: IF := hol(1); return a.W() + b.W(); }' 30
# Felder: die type-id belegt Offset 0, die Felder ruecken um acht Byte nach
# hinten. Vor #1773 trugen Klassen mit `implements` keine type-id.
run "interface_mit_feldern" \
  'pub type IF = interface { fn W(): int64; } pub type TA = class implements IF { x: int64; y: int64; fn Create() { self.x := 3; self.y := 4; } fn W(): int64 { return self.x * self.y; } } fn main(): int64 { var a: IF := new TA() as IF; return a.W(); }' 12
run "interface_mit_argument" \
  'pub type IF = interface { fn Add(d: int64): int64; } pub type TA = class implements IF { x: int64; fn Create() { self.x := 30; } fn Add(d: int64): int64 { return self.x + d; } } fn main(): int64 { var a: IF := new TA() as IF; return a.Add(12); }' 42
run "zwei_interfaces" \
  'pub type I1 = interface { fn A(): int64; } pub type I2 = interface { fn B(): int64; } pub type T = class implements I1, I2 { fn Create() {} fn A(): int64 { return 5; } fn B(): int64 { return 7; } } fn main(): int64 { var x: I1 := new T() as I1; var y: I2 := new T() as I2; return x.A() + y.B(); }' 12
# Erbe: die Ableitung ueberschreibt, das Interface fuehrt die Basis.
run "interface_ueber_erbe" \
  'pub type IF = interface { fn W(): int64; } pub type TBase = class implements IF { fn Create() {} fn W(): int64 { return 1; } } pub type TAbl = class extends TBase { fn Create() {} override fn W(): int64 { return 9; } } fn main(): int64 { var a: IF := new TAbl() as IF; return a.W(); }' 9

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
