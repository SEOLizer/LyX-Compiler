#!/usr/bin/env bash
# tests/new_nullung_test.sh — `new` liefert genullten Speicher (#1848).
#
# Jedes Ziel ausser lyxos bekommt seinen Block vom Betriebssystem genullt:
# Linux liefert frische anonyme Seiten so (x86/arm64/riscv), Windows ueber
# VirtualAlloc. LyxOS nullt NICHT — dieselbe Quelle las sich damit je Ziel
# anders, und zwar still: ein im Konstruktor vergessenes Feld ist unter Linux 0
# und besteht jede !=0-Pruefung, auf dem Geraet ist es Muell.
#
# Daran ist #1847 gestorben. Der Fehler lag im Paket (vega: TApplication.Init
# setzte MainForm nie), aber gefunden werden konnte er nur am Geraet: der
# Zugriff kam als CR2 = 169/176/238 an — FELDABSTAENDE an einem Muellzeiger,
# keine Adressen. Drei Fassungen lang sah es nach einem Compiler-Defekt aus.
#
# Gemessen wird, wo es geht, die WIRKUNG (Feld ist 0), und auf lyxos die
# BYTEFOLGE im Erzeugnis — der lokale LBF-Lader kann allokierende Programme
# nicht ausfuehren (rax statt rdx, #1832).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

# Der Konstruktor setzt NUR a. b und c muessen trotzdem 0 sein — das ist die
# Zusicherung. Ein Test, der alle Felder setzt, wuerde nichts messen.
cat > "$TMP/n.lyx" <<'L'
pub type TA = class {
  a: int64; b: int64; c: int64;
  fn Create(): void { self.a := 1; }
};
fn main(): int64 {
  var o: TA := new TA();
  if (o.b != 0) { return 41; }
  if (o.c != 0) { return 42; }
  return o.a + 6;
}
L

for ziel in linux arm64 riscv; do
  q=""
  if [ "$ziel" = "arm64" ]; then
    command -v qemu-aarch64-static >/dev/null 2>&1 && q=qemu-aarch64-static
    [ -z "$q" ] && command -v qemu-aarch64 >/dev/null 2>&1 && q=qemu-aarch64
    if [ -z "$q" ]; then echo "SKIP arm64: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
  elif [ "$ziel" = "riscv" ]; then
    command -v qemu-riscv64-static >/dev/null 2>&1 && q=qemu-riscv64-static
    [ -z "$q" ] && command -v qemu-riscv64 >/dev/null 2>&1 && q=qemu-riscv64
    if [ -z "$q" ]; then echo "SKIP riscv: qemu fehlt — ohne Laufzeit misst das nichts"; continue; fi
  fi
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" --target="$ziel" -o "$TMP/n.out" >"$TMP/n.log" 2>&1; then
    echo "FAIL $ziel/felder_sind_null: uebersetzt nicht: $(grep -im1 'error' "$TMP/n.log")"; FAIL=$((FAIL+1)); continue
  fi
  timeout 30 $q "$TMP/n.out" >/dev/null 2>&1; rc=$?
  case "$rc" in
    7)  echo "PASS $ziel/felder_sind_null"; PASS=$((PASS+1)) ;;
    41) echo "FAIL $ziel/felder_sind_null: Feld b war nicht 0"; FAIL=$((FAIL+1)) ;;
    42) echo "FAIL $ziel/felder_sind_null: Feld c war nicht 0"; FAIL=$((FAIL+1)) ;;
    *)  echo "FAIL $ziel/felder_sind_null: exit=$rc erwartet 7"; FAIL=$((FAIL+1)) ;;
  esac
done

# lyxos: am Erzeugnis. Die Nullung steht unmittelbar an der Alloc-Stelle —
# `push rax; mov rdi,rax` (50 48 89 C7) vor dem Block, `xor eax,eax; cld;
# rep stosb; pop rax` (31 C0 FC F3 AA 58) danach. Geprueft werden beide
# Haelften: `rep stosb` allein steht auch in MemSet (#1842), die Klammer aus
# push/pop gibt es nur hier.
if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" --target=lyxos -o "$TMP/n.lbf" >"$TMP/l.log" 2>&1; then
  H="$(xxd -p "$TMP/n.lbf" | tr -d '\n')"
  v="$(printf '%s' "$H" | grep -o '504889c7' | wc -l)"
  n="$(printf '%s' "$H" | grep -o '31c0fcf3aa58' | wc -l)"
  if [ "$v" -ge 1 ] && [ "$n" -ge 1 ]; then
    echo "PASS lyxos/nullung_am_alloc (Vorspann $v, Schleife $n)"; PASS=$((PASS+1))
  else
    echo "FAIL lyxos/nullung_am_alloc: Vorspann=$v Schleife=$n — Bytefolge fehlt"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL lyxos/uebersetzt: $(grep -im1 'error' "$TMP/l.log")"; FAIL=$((FAIL+1))
fi

# Freistehende Ziele haben keinen Allokator. `new` muss dort MELDEN, nicht
# still einen Nullzeiger liefern — auf arm-cm seit #1783, auf xtensa erst seit
# #1848. Beide Seiten messen: die Meldung muss kommen UND die Uebersetzung
# scheitern.
for ziel in esp32 arm-cm4; do
  if timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" --target="$ziel" -o "$TMP/n.bare" >"$TMP/b.log" 2>&1; then
    echo "FAIL $ziel/new_meldet: uebersetzt klaglos — stiller Nullzeiger"; FAIL=$((FAIL+1))
  else
    case "$(cat "$TMP/b.log")" in
      *"alloc/new gibt es auf einem freistehenden Ziel nicht"*)
        echo "PASS $ziel/new_meldet"; PASS=$((PASS+1)) ;;
      *) echo "FAIL $ziel/new_meldet: andere Meldung: $(grep -im1 'error' "$TMP/b.log")"; FAIL=$((FAIL+1)) ;;
    esac
  fi
done

echo "== new_nullung_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
