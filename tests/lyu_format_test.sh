#!/usr/bin/env bash
# tests/lyu_format_test.sh — #2014 Stufen 1–4: die `.lyu` BESCHREIBT ihre Unit.
#
# Bis 1.2.16A trug eine `.lyu` Namen, Konstantenwerte (Stufe 1) und — fuer
# IR-Ziele — Code, aber keine Signaturen und kein Layout. Ohne die `.lyx`
#   - war sema fail-open: jedes Symbol kam als "user" ohne Knoten herein,
#     falsche Argumentzahl und unbekanntes Feld gingen durch;
#   - brach der x86-Codegen jede Unit mit Funktion/Struct/Klasse ab;
#   - kannte der IR-Weg weder Struct-Groesse noch Klassenlayout noch die
#     Konstanten (`BREITE` "ohne bekannte Herkunft").
# Dazu kam ein Defekt MIT Quelle: `var p: TPunkt;` mit importiertem Struct
# bekam auf arm64 keinen Speicher (SIGSEGV).
#
# Gemessen wird der WERT, mit weggelegter Quelle (der Resolver bevorzugt die
# .lyx — sie liegt deshalb NIE im Suchpfad), auf x86_64 und arm64 gleich, und
# gegen den Lauf MIT Quelle. Gegenseiten: sema meldet gegen die .lyu, x86 weist
# einen Aufruf ohne Objektcode laut ab (Stufe 5 fehlt), eine .lyu fuer das
# andere Backend wird am LAYOUT erkannt, eine alte .lyu (ohne Flagbit 16) wird
# weiter gelesen wie bisher.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ]; then echo "FAIL qemu fuer arm64 fehlt — NICHT gemessen"; exit 1; fi

mkdir -p "$TMP/quelle/demo"
cat > "$TMP/quelle/demo/bib.lyx" <<'EOF'
unit demo.bib;
pub con BREITE: int64 := 1920;
pub con NEG: int64 := 0 - 7;
pub con GROSS: int64 := 4294967296;
pub type TPunkt = struct { x: int64; y: int64; z: int64; };
pub fn Summe(a: int64, b: int64): int64 { return a + b; }
pub fn PunktSumme(p: TPunkt): int64 { return p.x + p.y + p.z; }
pub fn Skal(x: int64, f: int64 = 3): int64 { return x * f; }
pub type TBasis = class {
  pub a: int64;
  pub b: int64;
  pub fn Init(v: int64) { self.a := v; self.b := v * 2; }
  pub fn Wert(): int64 { return self.a + self.b; }
  pub virtual fn Art(): int64 { return 1; }
};
pub type TFlach = class {
  pub u: int64;
  pub v: int64;
  pub fn Prod(): int64 { return self.u * self.v; }
};
EOF

# px: nutzt nur, was ohne Objektcode geht — Konstanten, Struct-Layout (Feld,
# Wertuebergabe an EIGENE Funktion), Klassenlayout (geerbte Felder in einer
# eigenen Methode), virtuelle Dispatch auf die eigene Ueberschreibung.
cat > "$TMP/px.lyx" <<'EOF'
import demo.bib;
import std.io;
type TAbl = class extends TBasis {
  pub c: int64;
  pub override fn Art(): int64 { return 2; }
  pub fn Summe3(): int64 { return self.a + self.b + self.c; }
};
fn PS(p: TPunkt): int64 { return p.x * 100 + p.y * 10 + p.z; }
fn main(): int64 {
  var p: TPunkt;
  p.x := 1; p.y := 2; p.z := 3;
  PrintStr(IntToStr(BREITE)); PrintStr(" ");
  PrintStr(IntToStr(NEG)); PrintStr(" ");
  PrintStr(IntToStr(GROSS)); PrintStr(" ");
  PrintStr(IntToStr(PS(p))); PrintStr(" ");
  var o: TAbl := new TAbl();
  o.a := 5; o.b := 10; o.c := 9;
  PrintStr(IntToStr(o.Summe3())); PrintStr(" ");
  var bb: TBasis := o;
  PrintStr(IntToStr(bb.a)); PrintStr(" ");
  var fl: TFlach := new TFlach();
  fl.u := 6; fl.v := 7;
  PrintStr(IntToStr(fl.u * fl.v)); PrintStr(" ");
  PrintLn(IntToStr(bb.Art()));
  return 0;
}
EOF
SOLL_X="1920 -7 4294967296 123 24 5 42 2"

# pa: dazu Funktionen und Methoden der Unit — Code nur auf dem IR-Weg (arm64).
cat > "$TMP/pa.lyx" <<'EOF'
import demo.bib;
import std.io;
type TAbl = class extends TBasis {
  pub c: int64;
  pub override fn Art(): int64 { return 2; }
};
fn main(): int64 {
  var p: TPunkt;
  p.x := 1; p.y := 2; p.z := 3;
  PrintStr(IntToStr(Summe(3, 4))); PrintStr(" ");
  PrintStr(IntToStr(PunktSumme(p))); PrintStr(" ");
  PrintStr(IntToStr(Skal(5, 4))); PrintStr(" ");
  var o: TAbl := new TAbl();
  o.Init(5); o.c := 9;
  PrintStr(IntToStr(o.Wert())); PrintStr(" ");
  PrintStr(IntToStr(o.a + o.b + o.c)); PrintStr(" ");
  var bb: TBasis := o;
  var ba: TBasis := new TBasis();
  ba.Init(1);
  PrintStr(IntToStr(ba.Art())); PrintStr(" ");
  var fl: TFlach := new TFlach();
  fl.u := 6; fl.v := 7;
  PrintStr(IntToStr(fl.Prod())); PrintStr(" ");
  PrintLn(IntToStr(bb.Art()));
  return 0;
}
EOF
SOLL_A="7 6 20 15 24 1 42 2"

# --- .lyu je Ziel aus der Quelle, dann liegt die Quelle NICHT im Suchpfad ---
for t in x86_64 arm64; do
  mkdir -p "$TMP/lyu_$t/demo"
  if ! ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target="$t" --std-path="$ROOT" \
          "$TMP/quelle/demo/bib.lyx" -o "$TMP/lyu_$t/demo/bib.lyu" ) >"$TMP/cu_$t.log" 2>&1; then
    nok "--compile-unit fuer $t schlaegt fehl"; grep -v Copyright "$TMP/cu_$t.log" | head -3
  fi
done

lauf() {  # ziel, binary
  if [ "$1" = arm64 ]; then ( ulimit -v 4000000; timeout 30 "$QEMU_ARM64" "$2" 2>&1 )
  else ( ulimit -v 4000000; timeout 30 "$2" 2>&1 ); fi
}
baue() {  # ziel, inc, prog, out
  rm -f "$4"
  ( cd / && ulimit -v 8000000 && timeout 180 "$LYXC" --target="$1" --std-path="$ROOT" -I "$2" "$3" -o "$4" ) >"$4.log" 2>&1
}

echo "--- Werte mit Quelle und nur mit .lyu ---"
for t in x86_64 arm64; do
  baue "$t" "$TMP/quelle" "$TMP/px.lyx" "$TMP/mq_$t"
  mq="$(lauf "$t" "$TMP/mq_$t")"
  baue "$t" "$TMP/lyu_$t" "$TMP/px.lyx" "$TMP/oq_$t"
  if [ ! -f "$TMP/oq_$t" ]; then
    nok "$t nur .lyu: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/oq_$t.log"))"
    continue
  fi
  oq="$(lauf "$t" "$TMP/oq_$t")"
  if [ "$mq" = "$SOLL_X" ] && [ "$oq" = "$SOLL_X" ]; then
    ok "$t: Konstante/Struct/Klasse ohne Quelle = mit Quelle ($oq)"
  else
    nok "$t: mit Quelle '$mq', nur .lyu '$oq', erwartet '$SOLL_X'"
  fi
done

# arm64: Funktionen, Methoden (eigene, geerbte, virtuelle) aus der .lyu — ihr
# Code kommt als IR mit.
baue arm64 "$TMP/quelle" "$TMP/pa.lyx" "$TMP/aq"
aq="$(lauf arm64 "$TMP/aq")"
baue arm64 "$TMP/lyu_arm64" "$TMP/pa.lyx" "$TMP/ao"
ao="$( [ -f "$TMP/ao" ] && lauf arm64 "$TMP/ao" )"
if [ "$aq" = "$SOLL_A" ] && [ "$ao" = "$SOLL_A" ]; then
  ok "arm64: Funktion, Struct-Parameter, Methode, geerbt, virtuell — nur .lyu = Quelle ($ao)"
else
  nok "arm64 pa: mit Quelle '$aq', nur .lyu '$ao' ($(grep -m1 -iE 'error' "$TMP/ao.log")), erwartet '$SOLL_A'"
fi

echo "--- x86: Aufruf ohne Objektcode wird laut abgewiesen (Stufe 5 fehlt) ---"
baue x86_64 "$TMP/lyu_x86_64" "$TMP/pa.lyx" "$TMP/xo"
if [ -f "$TMP/xo" ]; then
  nok "x86 nur .lyu: Programm mit Funktionsaufruf uebersetzt — ohne Code waere das still falsch"
elif grep -q "ohne Objektcode" "$TMP/xo.log"; then
  ok "x86 nur .lyu: Aufruf ohne Objektcode abgewiesen, kein Erzeugnis"
else
  nok "x86 nur .lyu: abgewiesen, aber ohne Begruendung ($(grep -m1 -iE 'error' "$TMP/xo.log"))"
fi
# Eine nicht ueberschriebene virtuelle Methode der .lyu: ihr VMT-Platz zeigt
# auf einen Rumpf, der sich meldet — nicht auf 0.
cat > "$TMP/pv.lyx" <<'EOF'
import demo.bib;
import std.io;
type TOhne = class extends TBasis { pub c: int64; };
fn main(): int64 {
  var o: TOhne := new TOhne();
  var b: TBasis := o;
  PrintLn(IntToStr(b.Art()));
  return 0;
}
EOF
baue x86_64 "$TMP/lyu_x86_64" "$TMP/pv.lyx" "$TMP/pv"
if [ -f "$TMP/pv" ]; then
  pv="$(lauf x86_64 "$TMP/pv")"; rc=$?
  if printf '%s' "$pv" | grep -q "TBasis.Art liegt nur als .lyu vor"; then
    ok "x86: geerbte virtuelle Methode ohne Code meldet sich zur Laufzeit (kein Sprung nach 0)"
  else
    nok "x86: geerbte virtuelle Methode ohne Code: '$pv' rc=$rc"
  fi
else
  nok "x86 pv uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/pv.log"))"
fi

echo "--- sema prueft gegen die .lyu ---"
cat > "$TMP/fs.lyx" <<'EOF'
import demo.bib;
import std.io;
fn main(): int64 {
  var p: TPunkt;
  p.w := 1;
  PrintLn(IntToStr(Summe(3)));
  var o: TBasis := new TBasis();
  o.q := 3;
  o.Init(1, 2);
  return 0;
}
EOF
for inc in quelle lyu_x86_64; do
  baue x86_64 "$TMP/$inc" "$TMP/fs.lyx" "$TMP/fs_$inc"
  grep -E "sema error" "$TMP/fs_$inc.log" | sed 's/^.*sema error/sema error/' > "$TMP/fs_$inc.txt"
done
n="$(wc -l < "$TMP/fs_lyu_x86_64.txt")"
if [ "$n" -eq 4 ] && cmp -s "$TMP/fs_quelle.txt" "$TMP/fs_lyu_x86_64.txt" \
   && grep -q "unknown field 'w'" "$TMP/fs_lyu_x86_64.txt" \
   && grep -q "Argument-Anzahl im Aufruf von 'Summe'" "$TMP/fs_lyu_x86_64.txt" \
   && grep -q "unknown field 'q'" "$TMP/fs_lyu_x86_64.txt" \
   && grep -q "Methodenaufruf von 'Init'" "$TMP/fs_lyu_x86_64.txt"; then
  ok "sema: unbekanntes Feld und falsche Argumentzahl gegen die .lyu wie gegen die Quelle (4 Meldungen)"
else
  nok "sema gegen .lyu: $n Meldungen, mit Quelle $(wc -l < "$TMP/fs_quelle.txt")"; cat "$TMP/fs_lyu_x86_64.txt"
fi
# Gegenseite: das korrekte Programm bekommt KEINE sema-Meldung.
if grep -q "sema error" "$TMP/oq_x86_64.log"; then nok "sema meldet am korrekten Programm"
else ok "sema: korrektes Programm ohne Meldung gegen die .lyu"; fi

echo "--- Layout: eine .lyu fuer das andere Backend wird erkannt ---"
# TFlach hat keine virtuelle Methode: x86 legt ihre Felder ab +8, der IR-Weg ab 0.
baue arm64 "$TMP/lyu_x86_64" "$TMP/px.lyx" "$TMP/kx"
if [ ! -f "$TMP/kx" ] && grep -q "Layout von 'TFlach' weicht ab" "$TMP/kx.log"; then
  ok "x86-.lyu auf arm64: Layoutabweichung gemeldet, kein Erzeugnis"
else
  nok "x86-.lyu auf arm64: nicht gemeldet ($(grep -m1 -iE 'error|Layout' "$TMP/kx.log"))"
fi
baue x86_64 "$TMP/lyu_arm64" "$TMP/px.lyx" "$TMP/ka"
if [ ! -f "$TMP/ka" ] && grep -q "Layout von 'TFlach' weicht ab" "$TMP/ka.log"; then
  ok "arm64-.lyu auf x86: Layoutabweichung gemeldet, kein Erzeugnis"
else
  nok "arm64-.lyu auf x86: nicht gemeldet ($(grep -m1 -iE 'error|Layout' "$TMP/ka.log"))"
fi

echo "--- --unit-info nennt Typnamen und Layout ---"
info="$( cd "$ROOT" && timeout 60 "$LYXC" --unit-info "$TMP/lyu_x86_64/demo/bib.lyu" 2>&1 )"
if printf '%s\n' "$info" | grep -q "pub fn PunktSumme(p: TPunkt): int64" \
   && printf '%s\n' "$info" | grep -q "Layout TBasis: Groesse 24, Typwort 1, a@8/8, b@16/8" \
   && printf '%s\n' "$info" | grep -q "pub virtual fn Art(): int64;"; then
  ok "--unit-info: Signatur mit Typnamen (TPunkt statt user), Layout, virtual"
else
  nok "--unit-info unvollstaendig"; printf '%s\n' "$info" | sed -n '/Deklar/,$p' | head -20
fi

echo "--- Abwaertsvertraeglichkeit: alte .lyu (ohne Flagbit 16) ---"
# Kopf: 4 Magic, 2 Version, 1 Arch, 1 Flags -> Flags bei Offset 7.
alt="$TMP/alt/demo"; mkdir -p "$alt"
python3 - "$TMP/lyu_x86_64/demo/bib.lyu" "$alt/bib.lyu" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
assert d[7] & 16, "Flagbit 16 fehlt in der neuen .lyu"
d[7] &= ~16
open(sys.argv[2], 'wb').write(d)
PY
baue x86_64 "$TMP/alt" "$TMP/px.lyx" "$TMP/al"
if [ ! -f "$TMP/al" ] && grep -q "Quelle der importierten Unit nicht lesbar" "$TMP/al.log"; then
  ok "alte .lyu: gelesen wie bisher — Unit mit Struct/Klasse ohne Quelle abgewiesen"
else
  nok "alte .lyu: Verhalten geaendert ($(grep -m1 -iE 'error' "$TMP/al.log"))"
fi
ainfo="$( cd "$ROOT" && timeout 60 "$LYXC" --unit-info "$alt/bib.lyu" 2>&1 )"
if printf '%s\n' "$ainfo" | grep -qE "fn[[:space:]]+Summe[[:space:]]+int64" && ! printf '%s\n' "$ainfo" | grep -q "Deklarationen"; then
  ok "alte .lyu: --unit-info liest die Symboltabelle, keine Deklarationen"
else
  nok "alte .lyu: --unit-info falsch"
fi
# Nur Konstanten, alte Form: Stufe 1 traegt weiter.
mkdir -p "$TMP/k/demo"
cat > "$TMP/kq.lyx" <<'EOF'
unit demo.kon;
pub con K1: int64 := 41;
EOF
cat > "$TMP/kp.lyx" <<'EOF'
import demo.kon;
import std.io;
fn main(): int64 { PrintLn(IntToStr(K1 + 1)); return 0; }
EOF
( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --std-path="$ROOT" "$TMP/kq.lyx" -o "$TMP/k/demo/kon.lyu" ) >/dev/null 2>&1
python3 - "$TMP/k/demo/kon.lyu" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read()); d[7] &= ~16; open(sys.argv[1], 'wb').write(d)
PY
baue x86_64 "$TMP/k" "$TMP/kp.lyx" "$TMP/kpx"
kv="$( [ -f "$TMP/kpx" ] && lauf x86_64 "$TMP/kpx" )"
if [ "$kv" = "42" ]; then ok "alte .lyu nur mit Konstanten: Wert wie bisher (42)"
else nok "alte .lyu nur mit Konstanten: '$kv'"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
