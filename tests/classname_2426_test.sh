#!/usr/bin/env bash
# tests/classname_2426_test.sh — #2426: ClassName() auf allen Zielen.
#
# BEFUND. `ClassName()` ist seit 1.1.3D ein Builtin an jeder Klasse, war aber
# nur in codegen_x86 umgesetzt. Auf dem IR-Weg (lyxos, arm64, riscv) lief der
# Aufruf in die gewoehnliche Methodenaufloesung und scheiterte dort mit
# "Methode nicht aufloesbar". Vor der Meldung aus #1976 war derselbe Fall
# STILL: ClassName() lieferte 0, und ein Vergleich dagegen las Adresse 0 —
# in lyx-vcl betrifft das TControl.IsClass und den Formularlader.
#
# WAS HIER GEMESSEN WIRD: der WERT, nicht die Uebersetzbarkeit. Ein Test, der
# nur prueft, dass der Aufruf durchkommt, waere auch von einem ClassName
# erfuellt, das immer den STATISCHEN Namen liefert — und genau das ist der
# Fall, der leicht passiert: die Variable hat den Typ der Basisklasse, das
# Objekt ist eine Ableitung. Deshalb steht dieser Fall an erster Stelle.
#
# Gemessen wird gegen x86 als Bezugsgroesse: dort war die Semantik immer
# richtig, und die IR-Ziele muessen dasselbe liefern. Eine fest
# hingeschriebene Erwartung allein wuerde nicht zeigen, dass die Ziele
# UEBEREINSTIMMEN.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/cn.lyx" <<'EOF'
import std.io;
pub type TBasis = class {
  fn Create(): void {}
  virtual fn Wer(): int64 { return 1; }
}
pub type TAbleitung = class extends TBasis {
  override fn Wer(): int64 { return 2; }
}
// Ohne virtuelle Methode und ohne `implements` traegt das Objekt KEINE
// type-id; dort ist der statische Name die einzige und richtige Antwort.
pub type TOhne = class {
  fn Create(): void {}
}
fn main(): int64 {
  var b: TBasis := new TAbleitung();
  PrintLn(b.ClassName() as pchar);
  var s: TBasis := new TBasis();
  PrintLn(s.ClassName() as pchar);
  var o: TOhne := new TOhne();
  PrintLn(o.ClassName() as pchar);
  return 0;
}
EOF

# Die Erwartung steht hier ausgeschrieben, damit ein gemeinsamer Fehler aller
# Ziele nicht als Uebereinstimmung durchgeht. Zeile 1 ist der eigentliche
# Punkt: die Variable hat den Typ TBasis, das Objekt ist eine TAbleitung.
ERWARTET=$'TAbleitung\nTBasis\nTOhne'

uebersetze() { # $1 = Ziel ("" = x86), $2 = Ausgabedatei
  local z=""
  [ -n "$1" ] && z="--target=$1"
  (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/cn.lyx" $z -o "$2" \
     >"$TMP/c.log" 2>&1)
}

pruefe() { # $1 = Name, $2 = Ziel, $3 = Startprogramm (leer = direkt)
  local name="$1" ziel="$2" starter="$3"
  if ! uebersetze "$ziel" "$TMP/p"; then
    no "$name uebersetzt" "$(grep -m1 -iE 'error|nicht aufloesbar|Builtin-ID' "$TMP/c.log")"
    return
  fi
  ok "$name uebersetzt"
  if [ -n "$ziel" ] && [ -z "$starter" ]; then
    echo "HINWEIS: $name nicht ausgefuehrt (kein qemu) — der WERT ist damit ungemessen."
    return
  fi
  local aus
  aus="$(timeout 20 $starter "$TMP/p" 2>/dev/null)"
  if [ "$aus" = "$ERWARTET" ]; then
    ok "$name liefert die richtigen Namen"
  else
    no "$name Wert" "erhalten '$(echo "$aus" | tr '\n' '/')' statt '$(echo "$ERWARTET" | tr '\n' '/')'"
  fi
}

pruefe "x86"   ""      ""
pruefe "arm64" arm64   "$QEMU_ARM64"
pruefe "riscv" riscv   "$QEMU_RISCV64"

# lyxos wird nur UEBERSETZT. Ausfuehren laesst sich das Abbild hier nicht: der
# lokale LBF-Lader gibt Syscall-Ergebnisse in rax statt rdx zurueck, womit
# jeder allokierende Builtin — und `new` ist einer — eine Muelladresse
# bekommt. Was der gemeinsame IR-Weg leistet, zeigen arm64 und riscv oben.
if uebersetze lyxos "$TMP/p.lbf"; then
  ok "lyxos uebersetzt"
else
  no "lyxos uebersetzt" "$(grep -m1 -iE 'error|nicht aufloesbar' "$TMP/c.log")"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
