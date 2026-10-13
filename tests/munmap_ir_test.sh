#!/usr/bin/env bash
# tests/munmap_ir_test.sh — #2052: `munmap(p, n)` gibt auf den IR-Zielen
# wirklich frei, und zwar genau n Bytes.
#
# Bis 1.2.11A senkte ir_lower `munmap(ptr, size)` zu IRO_FREE(ptr) ab — das
# zweite Argument wurde nicht ausgewertet, und arm64 wie riscv setzten die
# Laenge fest auf 0. Linux weist munmap mit Laenge 0 ab (EINVAL). Auf beiden
# Zielen gab der Aufruf also nie etwas frei; x86 tat es richtig.
#
# Bemerkt hat das niemand, weil ein gescheitertes munmap nichts kaputt macht:
# das Programm laeuft durch und liefert, was es liefern soll. Ein Test auf
# "uebersetzt" oder auf das Rechenergebnis waere vor dem Fix gruen gewesen.
#
# GEMESSEN WIRD DESHALB DER ZUGRIFF DANACH: eine freigegebene Seite gibt es
# nicht mehr, der Schreibzugriff darauf endet mit SIGSEGV (rc 139). Und die
# andere Seite: was NICHT freigegeben wurde, muss weiter beschreibbar sein —
# ein munmap, das zu viel freigibt, war gerade erst #2050.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
ulimit -c 0 2>/dev/null   # die Abstuerze hier sind gewollt

# $1 Beschreibung, $2 Quelle, $3 erwarteter Rueckgabewert
alle_ziele() {
  local was="$1" src="$2" erw="$3" ziel
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_${ziel}" pre=""
    if ! ( cd "$ROOT" && timeout 300 "$LYXC" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
      continue
    fi
    case "$ziel" in
      arm64) [ -n "$QEMU_ARM64" ]   || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_ARM64" ;;
      riscv) [ -n "$QEMU_RISCV64" ] || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_RISCV64" ;;
    esac
    # In einer Subshell, damit die Meldung der Shell ueber das Signal nicht
    # in die Ausgabe des Tests laeuft.
    local rc
    rc="$( ( timeout 60 $pre "$bin" >/dev/null 2>&1 ) 2>/dev/null; echo $? )"
    if [ "$rc" = "$erw" ]; then ok "$was [$ziel] (rc=$rc)"
    else nok "$was [$ziel]: rc=$rc statt $erw"; fi
  done
}

echo "--- GEGENPROBE: ohne munmap ist die Seite beschreibbar ---"
#
# Zuerst der Fall, an dem die folgenden haengen: derselbe Zugriff, nur ohne
# Freigabe davor. Liefe schon der mit 139 aus, bewiese die 139 weiter unten
# nichts ueber munmap.
cat > "$TMP/ohne.lyx" <<'EOF'
unit main;
fn main(): int64 {
  var p: int64 := mmap(0, 8192, 3, 34, 0 - 1, 0);
  poke64(p, 7);
  poke64(p, 9);
  return 5;
}
EOF
alle_ziele "ohne munmap bleibt die Seite beschreibbar" "$TMP/ohne.lyx" 5

echo
echo "--- #2052: nach munmap(p, n) ist die Seite WEG ---"
#
# Der eigentliche Nachweis. Vor dem Fix lief dieses Programm auf arm64 und
# riscv mit rc 5 durch: munmap(p, 0) scheiterte, die Seite blieb.
cat > "$TMP/weg.lyx" <<'EOF'
unit main;
fn main(): int64 {
  var p: int64 := mmap(0, 8192, 3, 34, 0 - 1, 0);
  poke64(p, 7);
  munmap(p, 8192);
  poke64(p, 9);
  return 5;
}
EOF
alle_ziele "Zugriff nach munmap endet mit SIGSEGV" "$TMP/weg.lyx" 139

echo
echo "--- #2052: freigegeben wird GENAU die angegebene Laenge ---"
#
# Die andere Seite, und nach #2050 die wichtigere: ein munmap, das mehr
# freigibt als verlangt, nimmt lebenden Speicher mit. Zwei Seiten angefordert,
# die ERSTE freigegeben — die zweite muss stehen bleiben.
cat > "$TMP/genau.lyx" <<'EOF'
unit main;
fn main(): int64 {
  var p: int64 := mmap(0, 16384, 3, 34, 0 - 1, 0);
  poke64(p + 8192, 7);
  munmap(p, 8192);
  poke64(p + 8192, 9);
  if (peek64(p + 8192) != 9) { return 1; }
  return 6;
}
EOF
alle_ziele "die zweite Seite ueberlebt die Freigabe der ersten" "$TMP/genau.lyx" 6

# Und dieselbe Lage von der anderen Seite: die erste IST weg.
cat > "$TMP/erste.lyx" <<'EOF'
unit main;
fn main(): int64 {
  var p: int64 := mmap(0, 16384, 3, 34, 0 - 1, 0);
  munmap(p, 8192);
  poke64(p, 9);
  return 6;
}
EOF
alle_ziele "die freigegebene erste Seite ist weg" "$TMP/erste.lyx" 139

echo
echo "--- #2052: der Laengenausdruck wird AUSGEWERTET ---"
#
# Das zweite Argument wurde auf dem IR-Weg gar nicht abgesenkt. Ein Ausdruck
# mit Seiteneffekt lief dort nicht, auf x86 schon — dasselbe Programm, je
# nach Ziel ein anderes Ergebnis. Gezaehlt wird die Auswertung.
cat > "$TMP/seite.lyx" <<'EOF'
unit main;
var gZaehler: int64 := 0;
fn laenge(): int64 { gZaehler := gZaehler + 1; return 8192; }
fn main(): int64 {
  var p: int64 := mmap(0, 8192, 3, 34, 0 - 1, 0);
  munmap(p, laenge());
  return gZaehler + 40;
}
EOF
alle_ziele "der Laengenausdruck laeuft genau einmal" "$TMP/seite.lyx" 41

echo
echo "--- #2052: der Rueckgabewert kommt an ---"
#
# 0 bei Erfolg. Fuer sich allein waere diese Pruefung schwach — ein Zweig,
# der nichts tut und zufaellig 0 im Slot stehen hat, erfuellte sie auch.
# Deshalb steht sie hinter den Zugriffspruefungen und daneben der Fehlerfall:
# eine nicht seitenausgerichtete Adresse MUSS abgewiesen werden.
cat > "$TMP/rueck.lyx" <<'EOF'
unit main;
fn main(): int64 {
  var p: int64 := mmap(0, 8192, 3, 34, 0 - 1, 0);
  var schief: int64 := munmap(p + 1, 4096);
  if (schief == 0) { return 1; }
  var gut: int64 := munmap(p, 8192);
  if (gut != 0) { return 2; }
  return 42;
}
EOF
alle_ziele "munmap liefert 0 bei Erfolg und einen Fehler bei schiefer Adresse" "$TMP/rueck.lyx" 42

echo
echo "--- dispose gibt weiterhin NICHTS frei (wie auf x86) ---"
#
# IRO_FREE kommt auch aus `dispose`, dort ohne Laenge. Die Backends erzeugen
# dann keinen Systemaufruf — vorher setzten sie einen ab, der nur scheitern
# konnte. Am Verhalten aendert das nichts, und genau das wird hier gehalten:
# das Objekt ist nach `dispose` noch lesbar, auf allen drei Zielen gleich.
#
# Wer `dispose` eines Tages wirklich freigeben laesst, macht diesen Fall rot —
# zu Recht, denn dann muss x86 mitziehen (CGN_DISPOSE in codegen_x86.lyx).
cat > "$TMP/disp.lyx" <<'EOF'
unit main;
type K = class { v: int64; };
fn main(): int64 {
  var k: K := new K();
  k.v := 7;
  dispose k;
  return k.v;
}
EOF
alle_ziele "nach dispose ist das Objekt noch lesbar" "$TMP/disp.lyx" 7

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
