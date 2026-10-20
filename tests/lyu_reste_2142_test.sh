#!/usr/bin/env bash
# tests/lyu_reste_2142_test.sh — #2142: Reste beim Einbinden einer .lyu.
#
# Bis 1.2.16A:
#   (1) Eine .lyu-Unit U, die die Quell-Unit X (mit Laufzeit-Anfangswert)
#       importiert, bringt X samt Anfangswert mit. Importiert das Programm X
#       ZUSAETZLICH als Quelle, lief der Anfangswert zweimal, und X' Variablen
#       gab es doppelt: U las die eine, das Programm die andere.
#   (2) Die .lyu wurde im Vorlauf und im Deklarationsdurchgang je einmal
#       angehaengt (getrennte Gesehen-Listen).
#   (3) Die .lyu trug keine Enum-Varianten (`E.Zzz` uebersetzte, fail-open)
#       und keine Namen ihrer Modulvariablen (auf dem IR-Weg nicht
#       ansprechbar: "keine bekannte Herkunft").
#
# Gemessen wird die WIRKUNG: ein Zaehler im Anfangswert (laeuft er genau
# einmal?), derselbe Wert ueber U und ueber das Programm, ein Schreibzugriff
# des Programms, den U sieht; Enum-Werte aus der .lyu; die Zahl der Anhaenge
# an der Architekturwarnung, die je Anhang genau einmal kommt. Gegenseiten:
# unbekannter Enum-Member und private Modulvariable werden abgewiesen.
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

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {
  case "$1" in
    x86_64) ( ulimit -v 4000000; timeout 60 "$2" ) 2>&1 ;;
    arm64)  ( ulimit -v 4000000; timeout 60 "$QEMU_ARM64" "$2" ) 2>&1 ;;
    riscv)  ( ulimit -v 4000000; timeout 60 "$QEMU_RISCV64" "$2" ) 2>&1 ;;
  esac
}
uebersetze() {
  local log="$1"; shift
  ( cd "$ROOT" && ulimit -v 8000000 && timeout 300 "$LYXC" "$@" ) >"$log" 2>&1
}

# X liegt als QUELLE im Suchpfad, U nur als .lyu (seine Quelle anderswo).
mkdir -p "$TMP/pfad/demo" "$TMP/usrc/demo"
cat > "$TMP/pfad/demo/x.lyx" <<'EOF'
unit demo.x;
pub var zaehler: int64 := 0;
fn _zaehle(): int64 { zaehler := zaehler + 1; return 42; }
pub var wert: int64 := _zaehle();
pub fn XWert(): int64 { return wert; }
EOF
cat > "$TMP/usrc/demo/u.lyx" <<'EOF'
unit demo.u;
import demo.x;
pub enum Farbe { Rot, Gruen = 5, Blau }
pub var uZahl: int64 := 7;
pub var uZaehler: int64 := 0;
var uPriv: int64 := 11;
fn _uz(): int64 { uZaehler := uZaehler + 1; return 3; }
pub var uInit: int64 := _uz();
pub fn UWert(): int64 { return XWert() + zaehler * 100; }
pub fn UZahl(): int64 { return uZahl + uPriv * 0; }
EOF
cat > "$TMP/init.lyx" <<'EOF'
import demo.u;
import demo.x;
import std.io;
fn main(): int64 {
  PrintStr(IntToStr(zaehler)); PrintStr(" ");
  PrintLn(IntToStr(UWert()));
  return 0;
}
EOF
cat > "$TMP/glob.lyx" <<'EOF'
import demo.u;
import std.io;
fn main(): int64 {
  PrintStr(IntToStr(uZaehler)); PrintStr(" ");
  PrintStr(IntToStr(uZahl)); PrintStr(" ");
  uZahl := 9;
  PrintStr(IntToStr(UZahl())); PrintStr(" ");
  PrintStr(IntToStr(Farbe.Gruen)); PrintStr(" ");
  PrintLn(IntToStr(Farbe.Blau));
  return 0;
}
EOF
printf 'import demo.u;\nfn main(): int64 { return Farbe.Lila; }\n' > "$TMP/lila.lyx"
printf 'import demo.u;\nfn main(): int64 { return uPriv; }\n' > "$TMP/priv.lyx"

for ziel in arm64 riscv; do
  rm -f "$TMP/pfad/demo/u.lyu"
  if ! uebersetze "$TMP/cu_$ziel.log" --compile-unit --target=$ziel --std-path="$ROOT" -I "$TMP/pfad" \
         "$TMP/usrc/demo/u.lyx" -o "$TMP/pfad/demo/u.lyu"; then
    nok "$ziel: --compile-unit von U scheitert: $(grep -v Copyright "$TMP/cu_$ziel.log" | head -1)"; continue
  fi
  # (1) Anfangswert von X genau einmal, X' Variable EINE
  if uebersetze "$TMP/i_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/pfad" "$TMP/init.lyx" -o "$TMP/i_$ziel"; then
    ist="$(lauf $ziel "$TMP/i_$ziel")"
    if [ "$ist" = "1 142" ]; then ok "$ziel: Anfangswert von X laeuft genau einmal, U und Programm sehen dieselbe Variable"
    else nok "$ziel: Init/Variable: erwartet '1 142' (Zaehler 1, U sieht ihn), bekommen '$ist'"; fi
  else nok "$ziel: init.lyx uebersetzt nicht: $(grep -v Copyright "$TMP/i_$ziel.log" | grep -m1 -i 'error\|lyxc:')"; fi
  # (3) Modulvariablen und Enum aus der .lyu
  if uebersetze "$TMP/g_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/pfad" "$TMP/glob.lyx" -o "$TMP/g_$ziel"; then
    ist="$(lauf $ziel "$TMP/g_$ziel")"
    if [ "$ist" = "1 7 9 5 6" ]; then ok "$ziel: Modulvariablen (lesen, schreiben, U sieht es) und Enum-Werte aus der .lyu"
    else nok "$ziel: Global/Enum: erwartet '1 7 9 5 6', bekommen '$ist'"; fi
  else nok "$ziel: glob.lyx uebersetzt nicht: $(grep -v Copyright "$TMP/g_$ziel.log" | grep -m1 -i 'error\|lyxc:')"; fi
  # Gegenseiten
  if uebersetze "$TMP/l_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/pfad" "$TMP/lila.lyx" -o "$TMP/l_$ziel"; then
    nok "$ziel: Farbe.Lila uebersetzt"
  elif grep -q "unbekannter Enum-Member 'Lila'" "$TMP/l_$ziel.log"; then ok "$ziel: unbekannter Enum-Member aus der .lyu wird von sema gemeldet"
  else nok "$ziel: Farbe.Lila: falsche Meldung: $(grep -v Copyright "$TMP/l_$ziel.log" | head -1)"; fi
  if uebersetze "$TMP/pv_$ziel.log" --target=$ziel --std-path="$ROOT" -I "$TMP/pfad" "$TMP/priv.lyx" -o "$TMP/pv_$ziel"; then
    nok "$ziel: private Modulvariable der .lyu ist von aussen ansprechbar"
  else ok "$ziel: private Modulvariable der .lyu bleibt unsichtbar"; fi
done

# Private Variable steht nicht im Anhang, die oeffentlichen schon.
info="$( cd "$ROOT" && "$LYXC" --unit-info "$TMP/pfad/demo/u.lyu" 2>&1 )"
if echo "$info" | grep -q "Farbe Rot=0 Gruen=5 Blau=6" && echo "$info" | grep -qP "^    uZahl\t" \
   && ! echo "$info" | grep -qP "^    uPriv\t"; then
  ok "--unit-info: Enum-Varianten mit Werten, oeffentliche Modulvariablen, keine private"
else nok "--unit-info: Anhang unvollstaendig: $(echo "$info" | grep -A2 'Enums\|Modulvar' | head -4)"; fi

# (2) EIN Anhang: die Warnung ueber die fremde Architektur kommt je Anhang
# genau einmal (die .lyu liegt fuer riscv vor, uebersetzt wird fuer arm64).
printf 'import demo.u;\nfn main(): int64 { return 0; }\n' > "$TMP/nur.lyx"
uebersetze "$TMP/zw.log" --target=arm64 --std-path="$ROOT" -I "$TMP/pfad" "$TMP/nur.lyx" -o "$TMP/zw"
n=$(grep -c "andere Architektur" "$TMP/zw.log")
if [ "$n" = 1 ]; then ok "die .lyu wird genau einmal angehaengt (Vorlauf und Deklarationsdurchgang teilen eine Liste)"
else nok "die .lyu wird $n-mal angehaengt"; fi

# Enum-Varianten auch auf x86 aus einer reinen Enum-.lyu
mkdir -p "$TMP/x86/demo"
printf 'unit demo.farben;\npub enum Ton { Do, Re = 7, Mi }\n' > "$TMP/x86_farben.lyx"
printf 'import demo.farben;\nimport std.io;\nfn main(): int64 { PrintStr(IntToStr(Ton.Re)); PrintStr(" "); PrintStr(IntToStr(Ton.Mi)); PrintStr(" "); PrintLn(IntToStr(Mi)); return 0; }\n' > "$TMP/ton.lyx"
printf 'import demo.farben;\nfn main(): int64 { return Ton.Fa; }\n' > "$TMP/fa.lyx"
cp "$TMP/x86_farben.lyx" "$TMP/x86/farben_quelle.lyx"
if uebersetze "$TMP/xc.log" --compile-unit --std-path="$ROOT" "$TMP/x86/farben_quelle.lyx" -o "$TMP/x86/demo/farben.lyu" \
   && uebersetze "$TMP/xt.log" --std-path="$ROOT" -I "$TMP/x86" "$TMP/ton.lyx" -o "$TMP/xt"; then
  ist="$(lauf x86_64 "$TMP/xt")"
  if [ "$ist" = "7 8 8" ]; then ok "x86_64: Enum aus einer .lyu ohne Quelle nutzbar"
  else nok "x86_64: Enum aus .lyu: erwartet '7 8 8', bekommen '$ist'"; fi
else nok "x86_64: Enum-.lyu uebersetzt nicht: $(grep -hv Copyright "$TMP/xc.log" "$TMP/xt.log" | grep -m1 -i 'error\|lyxc:')"; fi
if uebersetze "$TMP/xf.log" --std-path="$ROOT" -I "$TMP/x86" "$TMP/fa.lyx" -o "$TMP/xf"; then
  nok "x86_64: Ton.Fa uebersetzt"
elif grep -q "unbekannter Enum-Member 'Fa'" "$TMP/xf.log"; then ok "x86_64: unbekannter Enum-Member aus der .lyu gemeldet"
else nok "x86_64: Ton.Fa: falsche Meldung: $(grep -v Copyright "$TMP/xf.log" | head -1)"; fi

echo "lyu_reste_2142: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
