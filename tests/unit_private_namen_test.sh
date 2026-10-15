#!/usr/bin/env bash
# tests/unit_private_namen_test.sh — #2076: eine nicht-oeffentliche Funktion
# einer Unit bleibt bei ihrer Unit, auf x86_64, arm64 und riscv.
#
# Auf x86 tragen private Funktionen einer importierten Unit seit #1655 eine
# unit-lokale Marke. Der IR-Weg legte bis 1.2.12B alle Units unter dem
# BLANKEN Namen in einen gemeinsamen funcBuffer: zwei gleichnamige private
# Funktionen zweier Units fielen auf einen Eintrag, und `Eins()` rief die
# `rechne` aus bib.zwei. Fehlerfrei uebersetzt, Ausgabe 2|2 statt 1|2.
#
# Jede Funktion liefert einen eigenen Wert — die Ausgabe zeigt, WELCHE lief.
# Gemessen werden beide Seiten: die private bleibt in ihrer Unit, UND ein
# Aufruf, der eine oeffentliche Funktion gleichen Namens aus einer anderen
# Unit meint, wird nicht an die private umgelenkt.
set -uo pipefail
ulimit -c 0   # ein Absturz unter qemu legt sonst eine .core-Datei ins Repo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

ziele() {  # $1 Beschreibung, $2 Hauptdatei (in $TMP/m), $3 Soll mit |, $4 Ziele
  local was="$1" src="$2" erw="$3" zl="$4"
  for ziel in $zl; do
    local bin="$TMP/b_$ziel" pre=""
    case "$ziel" in
      arm64) pre="$QEMU_ARM64" ;;
      riscv) pre="$QEMU_RISCV64" ;;
    esac
    if ! ( cd "$TMP/m" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -iE '^lyxc:|error' "$TMP/bl.log"))"; continue
    fi
    if [ "$ziel" != "x86_64" ] && [ -z "$pre" ]; then nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; fi
    local ist; ist="$( (timeout 60 $pre "$bin" 2>&1) | tr '\n' '|')"
    if [ "$ist" = "$erw" ]; then ok "$was [$ziel] = $erw"
    else nok "$was [$ziel]: [$ist] statt [$erw]"; fi
  done
}
alle_ziele() { ziele "$1" "$2" "$3" "x86_64 arm64 riscv"; }

mkdir -p "$TMP/m/bib"
cat > "$TMP/m/bib/eins.lyx" <<'EOF'
unit bib.eins;
fn rechne(): int64 { return 1; }
fn spaeter(): int64 { return frueher() + 10; }   // ruft eine private, die weiter unten steht
fn frueher(): int64 { return 30; }
fn vorgabe(n: int64 = 5): int64 { return n; }
pub fn Eins(): int64 { return rechne(); }
pub fn EinsWert(): int64 { var f: fn(): int64 := rechne; return f(); }
pub fn EinsVorwaerts(): int64 { return spaeter(); }
pub fn EinsVorgabe(): int64 { return vorgabe(); }
pub fn helfer(): int64 { return 300; }
EOF
cat > "$TMP/m/bib/zwei.lyx" <<'EOF'
unit bib.zwei;
import bib.eins;
fn rechne(): int64 { return 2; }
fn vorgabe(n: int64 = 7): int64 { return n * 10; }
pub fn Zwei(): int64 { return rechne(); }
pub fn ZweiWert(): int64 { var f: fn(): int64 := rechne; return f(); }
pub fn ZweiVorgabe(): int64 { return vorgabe(); }
pub fn ZweiHelfer(): int64 { return helfer(); }   // die OEFFENTLICHE aus bib.eins
EOF
cat > "$TMP/m/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.eins;
import bib.zwei;
fn rechne(): int64 { return 9; }   // auch das Hauptmodul darf eine haben
fn main(): int64 {
  PrintLn(IntToStr(Eins()));          PrintLn(IntToStr(Zwei()));
  PrintLn(IntToStr(EinsWert()));      PrintLn(IntToStr(ZweiWert()));
  PrintLn(IntToStr(EinsVorwaerts()));
  PrintLn(IntToStr(EinsVorgabe()));   PrintLn(IntToStr(ZweiVorgabe()));
  PrintLn(IntToStr(ZweiHelfer()));
  PrintLn(IntToStr(rechne()));
  return 0;
}
EOF

echo "--- #2076: private Funktionen zweier Units ---"
alle_ziele "rechne 1|2, als Wert 1|2, Vorwaertsaufruf 40, Vorgaben 5|70, oeffentliche helfer 300, Hauptmodul 9" \
  "haupt.lyx" "1|2|1|2|40|5|70|300|9|"

echo
echo "--- IR-Weg: eine private Funktion mit Builtin-Namen geht vor (#1388) ---"
# Auf dem IR-Weg hat eine eigene Definition Vorrang vor dem gleichnamigen
# Builtin (#1388, _istBenutzerFunktion). Diese Pruefung fragte den funcBuffer
# mit dem blanken Namen — eine private Funktion steht dort seit #2076 als
# "unit_name", der Builtin haette gewonnen.
#
# Nur arm64/riscv: x86 nimmt auch im Hauptmodul den Builtin (#2082).
cat > "$TMP/m/bib/sl.lyx" <<'EOF'
unit bib.sl;
fn StrLen(p: pchar): int64 { return 99; }
pub fn SlLaenge(): int64 { return StrLen("abc"); }
EOF
cat > "$TMP/m/sl.lyx" <<'EOF'
unit main;
import std.io;
import bib.sl;
fn main(): int64 { PrintLn(IntToStr(SlLaenge())); return 0; }
EOF
ziele "private StrLen 99" "sl.lyx" "99|" "arm64 riscv"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
