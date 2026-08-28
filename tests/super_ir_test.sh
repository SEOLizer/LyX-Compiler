#!/usr/bin/env bash
# tests/super_ir_test.sh — `super.Methode()` auf dem gemeinsamen IR-Weg (#1841).
#
# `return super.Wert(a) + 100;` brach die Uebersetzung ab:
#   lyxc: --target=arm64: unbekannter Builtin/Funktion: Wert
# auf arm64, riscv UND lyxos; --target=linux lieferte 115. Wieder der
# gemeinsame IR-Weg, nicht das lyxos-Backend (#1786, #1787, #1798, #1842).
#
# URSACHE (src/ir_lower.lyx, lowerCall): der Parser baut `super.M(args)` als
# NK_CALL mit der MARKE 3 und ohne Empfaengerknoten (#1091). lowerCall kannte
# Marke 2 (generisch) und Marke 1 (Methode), Marke 3 nicht — der Aufruf fiel
# bis in die Builtin-Aufloesung durch. NK_SUPER_CALL samt `lowerSuperCall` war
# toter Altbestand: eine Huelle ohne Emission, die der Parser nie erzeugt.
#
# Gemessen wird der WERT, nicht die Uebersetzbarkeit. Der entscheidende Fall
# ist `super.F()` in einem `override fn F()`: wer dort ueber die VMT geht,
# ruft sich selbst — das Programm haengt oder stirbt am Stapel, statt still
# falsch zu rechnen. Ein Test, der nur "uebersetzt" prueft, saehe beides nicht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

fall() {  # name, quelle, erwarteter Rueckgabewert
  printf '%s\n' "$2" > "$TMP/s.lyx"
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
      echo "FAIL $ziel/$1: uebersetzt nicht: $(grep -im1 'error\|unbekannt' "$TMP/s.log")"; FAIL=$((FAIL+1)); continue
    fi
    timeout 30 $q "$TMP/s.out" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$3" ]; then echo "PASS $ziel/$1 (=$rc)"; PASS=$((PASS+1));
    else echo "FAIL $ziel/$1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
  done
}

B='pub type TBasis = class {
  x: int64;
  fn Create(): void { self.x := 1; }
  virtual fn Wert(a: int64): int64 { return a + 10; }
};'

# Der Fall aus dem Issue. 5+10 = 15, +100 = 115.
fall "super_im_override" \
  "$B
pub type TAbleitung = class extends TBasis {
  fn Create(): void { self.x := 2; }
  override fn Wert(a: int64): int64 { return super.Wert(a) + 100; }
};
fn main(): int64 { var d: TBasis := new TAbleitung(); return d.Wert(5); }" 115

# DIREKT, nicht ueber die VMT: die Basisfassung muss laufen, obwohl das Objekt
# eine Ableitung ist. Ginge der Aufruf ueber die VMT, riefe sich das Override
# selbst — endlos. Ein Wert-Test allein saehe den Unterschied nicht, deshalb
# ist der erwartete Wert hier die SUMME beider Ebenen.
fall "super_ruft_nicht_sich_selbst" \
  "$B
pub type TAbleitung = class extends TBasis {
  fn Create(): void { self.x := 2; }
  override fn Wert(a: int64): int64 { return super.Wert(a) * 2; }
};
fn main(): int64 { var d: TAbleitung := new TAbleitung(); return d.Wert(5); }" 30

# `self` muss das laufende Objekt sein, nicht ein leerer Zeiger: die
# Basismethode liest ein Feld, das der Konstruktor der ABLEITUNG gesetzt hat.
fall "super_sieht_das_eigene_self" \
  'pub type TB = class {
  x: int64;
  fn Create(): void { self.x := 1; }
  virtual fn Hol(): int64 { return self.x; }
};
pub type TA = class extends TB {
  fn Create(): void { self.x := 7; }
  override fn Hol(): int64 { return super.Hol(); }
};
fn main(): int64 { var d: TA := new TA(); return d.Hol(); }' 7

# Mehrere Argumente — die argBase-Konvention muss stimmen, sonst kommen sie
# verschoben an (dieselbe Falle wie beim Methodenaufruf daneben).
fall "super_mit_drei_argumenten" \
  'pub type TB = class {
  fn Create(): void { }
  virtual fn S(a: int64, b: int64, c: int64): int64 { return a * 100 + b * 10 + c; }
};
pub type TA = class extends TB {
  fn Create(): void { }
  override fn S(a: int64, b: int64, c: int64): int64 { return super.S(a, b, c); }
};
fn main(): int64 { var d: TA := new TA(); return d.S(1, 2, 3); }' 123

# Ohne Argumente und ueber zwei Ebenen: super in der MITTLEREN Klasse muss die
# oberste treffen, nicht wieder sich selbst.
fall "super_ueber_zwei_ebenen" \
  'pub type TB = class { fn Create(): void { } virtual fn W(): int64 { return 1; } };
pub type TM = class extends TB { fn Create(): void { } override fn W(): int64 { return super.W() + 10; } };
pub type TU = class extends TM { fn Create(): void { } override fn W(): int64 { return super.W() + 100; } };
fn main(): int64 { var d: TU := new TU(); return d.W(); }' 111

# Eine NICHT ueberschriebene Basismethode ueber super — der Name steht nur in
# der Basis, die Aufloesung muss die Kette hochlaufen.
fall "super_auf_nicht_ueberschriebene_methode" \
  'pub type TB = class { fn Create(): void { } fn Nur(): int64 { return 9; } virtual fn W(): int64 { return 0; } };
pub type TA = class extends TB { fn Create(): void { } override fn W(): int64 { return super.Nur(); } };
fn main(): int64 { var d: TA := new TA(); return d.W(); }' 9

# lyxos: nicht ausfuehrbar (LBF-Lader fuehrt unter Linux aus, rax statt rdx),
# also am ERZEUGNIS gemessen: es muss ueberhaupt eine Datei entstehen — vorher
# brach die Uebersetzung ab und es entstand keine.
printf '%s\npub type TAbleitung = class extends TBasis {\n  fn Create(): void { self.x := 2; }\n  override fn Wert(a: int64): int64 { return super.Wert(a) + 100; }\n};\nfn main(): int64 { var d: TBasis := new TAbleitung(); return d.Wert(5); }\n' "$B" > "$TMP/l.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/l.lyx" --target=lyxos -o "$TMP/l.lbf" >"$TMP/l.log" 2>&1 && [ -s "$TMP/l.lbf" ]; then
  echo "PASS lyxos/uebersetzt_und_erzeugt_abbild"; PASS=$((PASS+1))
else
  echo "FAIL lyxos/uebersetzt_und_erzeugt_abbild: $(grep -im1 'error\|unbekannt' "$TMP/l.log")"; FAIL=$((FAIL+1))
fi

# Gegenprobe an der MELDUNG: super ohne Basisklasse muss laut scheitern, nicht
# still 0 liefern. Ein stiller Default waere hier der naechste #1789.
printf 'pub type TE = class { fn Create(): void { } fn W(): int64 { return super.W(); } };\nfn main(): int64 { var e: TE := new TE(); return e.W(); }\n' > "$TMP/e.lyx"
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/e.lyx" --target=arm64 -o "$TMP/e.out" >"$TMP/e.log" 2>&1; then
  echo "FAIL super_ohne_basis_meldet: uebersetzt klaglos"; FAIL=$((FAIL+1))
else
  echo "PASS super_ohne_basis_meldet"; PASS=$((PASS+1))
fi

echo "== super_ir_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
