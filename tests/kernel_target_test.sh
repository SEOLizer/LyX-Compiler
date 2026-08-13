#!/usr/bin/env bash
# tests/kernel_target_test.sh — #1389.
#
# Unter einem freistehenden Kernel läuft kein Linux. Jeder `syscall`, den der
# Compiler von sich aus einbaut, trifft dort ins Leere. Genau das passierte:
# `__lyx_canary_init` rief `getrandom`, und der Kernel starb beim Eintritt in
# main() mit einem Page Fault — noch vor der ersten eigenen Anweisung.
#
# Gebaut wurde der Kernel ohne Zielangabe, also als Linux-Programm. Das war
# nicht nachlässig: `--target=lyxos-kernel` erzeugte einen LBF-Container, Byte
# für Byte denselben wie `--target=lyxos`. Ein freistehendes ELF gab es nicht.
#
# GEPRÜFT WIRD AN DEN BYTES, an festen Offsets. Ausführen lässt sich das
# Ergebnis auf diesem Rechner nicht: die Kernel-Fassung endet mit `hlt`, und
# das ist im Benutzermodus eine Schutzverletzung. Ein Test, der bloß
# "übersetzt" prüft, wäre auch grün geblieben, als der getrandom-Aufruf noch
# drinstand — er stand ja in einem Binary, das sich anstandslos erzeugen ließ.
#
# Die Längenprüfung ist kein Beiwerk: die Handler stehen an KONSTANTEN Offsets
# (CG_H_STRLEN=79, CG_H_STACK_FAIL=1275, CG_H_CANARY_INIT=1345, …). Ist eine
# Fassung auch nur ein Byte kürzer, zeigt jeder Aufruf danach mitten in einen
# Befehl. Deshalb wird hier nachgesehen, was an den Nachbaroffsets steht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

printf 'fn main(): int64 { return 0; }\n' > "$TMP/k.lyx"

"$LYXC" --std-path="$ROOT" "$TMP/k.lyx" --target=lyxos-kernel -o "$TMP/kern" >/dev/null 2>&1
"$LYXC" --std-path="$ROOT" "$TMP/k.lyx" -o "$TMP/linux" >/dev/null 2>&1

if [ ! -f "$TMP/kern" ]; then
  echo "FAIL --target=lyxos-kernel uebersetzt ueberhaupt nicht"
  echo "--- 0 PASS, 1 FAIL"; exit 1
fi

# Bytes an einem Code-Offset lesen (Offset relativ zum Anfang des Codes, so wie
# die CG_H_*-Konstanten zaehlen).
bytes() { # datei, offset, laenge
  python3 - "$1" "$2" "$3" <<'PY'
import struct,sys
d=open(sys.argv[1],'rb').read()
entry=struct.unpack_from('<Q',d,24)[0]; ph=struct.unpack_from('<Q',d,32)[0]
off=struct.unpack_from('<Q',d,ph+8)[0]; va=struct.unpack_from('<Q',d,ph+16)[0]
c=off+(entry-va)
print(d[c+int(sys.argv[2]):c+int(sys.argv[2])+int(sys.argv[3])].hex())
PY
}

hat() { # name, ist, soll-praefix
  case "$2" in
    "$3"*) ok "$1" ;;
    *) no "$1" "$2" ;;
  esac
}

# ===========================================================================
# Das Ziel erzeugt jetzt ein freistehendes ELF statt eines LBF-Containers
# ===========================================================================

magic="$(od -An -tx1 -N4 "$TMP/kern" | tr -d ' ')"
if [ "$magic" = "7f454c46" ]; then ok "lyxos-kernel erzeugt ein ELF"
else no "lyxos-kernel erzeugt ein ELF" "Magic $magic (LYX! waere 4c595821)"; fi

# Gegenprobe zur Begruendung der Umwidmung: --target=lyxos ist unveraendert LBF.
"$LYXC" --std-path="$ROOT" "$TMP/k.lyx" --target=lyxos -o "$TMP/lbf" >/dev/null 2>&1
m2="$(od -An -tx1 -N4 "$TMP/lbf" | tr -d ' ')"
if [ "$m2" = "4c595821" ]; then ok "lyxos bleibt LBF"
else no "lyxos bleibt LBF" "Magic $m2"; fi

# ===========================================================================
# Die drei Handler, die von sich aus einen Syscall absetzten
# ===========================================================================

# _start: kein prlimit64 (b8 2e 01 00 00), kein exit — argc/argv auf 0, dann
# call main, dann anhalten.
s="$(bytes "$TMP/kern" 0 12)"
hat "_start beginnt ohne Syscall (xor edi/esi)" "$s" "31ff31f6"

# __lyx_canary_init: RDTSC statt getrandom.
c="$(bytes "$TMP/kern" 1345 27)"
hat "canary_init beginnt mit rdtsc" "$c" "0f31"
case "$c" in
  *0f05*) no "canary_init enthaelt keinen syscall" "0f05 im Handler: $c" ;;
  *) ok "canary_init enthaelt keinen syscall" ;;
esac
case "$c" in
  *c3*) ok "canary_init kehrt zurueck (ret)" ;;
  *) no "canary_init kehrt zurueck (ret)" "kein c3: $c" ;;
esac

# __lyx_stack_fail: cli; hlt; jmp -3 statt write+exit.
f="$(bytes "$TMP/kern" 1275 8)"
hat "stack_fail haelt an (cli/hlt/jmp -3)" "$f" "faf4ebfd"

# ===========================================================================
# Im GESAMTEN Kernel-Binary steht keine der beiden Syscall-Nummern mehr
# ===========================================================================

alle="$(od -An -tx1 -v "$TMP/kern" | tr -d ' \n')"
case "$alle" in
  *48c7c03e010000*) no "kein getrandom (318) mehr im Binary" "mov rax,318 gefunden" ;;
  *) ok "kein getrandom (318) mehr im Binary" ;;
esac
case "$alle" in
  *b82e010000*) no "kein prlimit64 (302) mehr im Binary" "mov eax,302 gefunden" ;;
  *) ok "kein prlimit64 (302) mehr im Binary" ;;
esac

# ===========================================================================
# Die festen Offsets stimmen weiterhin — sonst zeigt jeder Aufruf daneben
# ===========================================================================

# Direkt hinter _start (Offset 79) beginnt _lyx_strlen mit `test rdi, rdi`.
hat "Offset 79: _lyx_strlen steht noch da (test rdi,rdi)" "$(bytes "$TMP/kern" 79 3)" "4885ff"
# Und dieselbe Stelle im Linux-Binary — der Beleg, dass 79 wirklich die Grenze ist.
hat "Offset 79 im Linux-Binary ebenso" "$(bytes "$TMP/linux" 79 3)" "4885ff"
# Hinter canary_init (1345+27=1372) beginnt __lyx_f64_to_str_chk. Was dort steht,
# muss in beiden Fassungen identisch sein.
a="$(bytes "$TMP/kern" 1372 16)"; b="$(bytes "$TMP/linux" 1372 16)"
if [ "$a" = "$b" ]; then ok "Offset 1372: gleicher Handler in beiden Fassungen"
else no "Offset 1372: gleicher Handler in beiden Fassungen" "kernel=$a linux=$b"; fi
# Und der letzte Handler vor dem Benutzercode (CG_H_MAP_STR = 1478).
a="$(bytes "$TMP/kern" 1478 16)"; b="$(bytes "$TMP/linux" 1478 16)"
if [ "$a" = "$b" ]; then ok "Offset 1478: gleicher Handler in beiden Fassungen"
else no "Offset 1478: gleicher Handler in beiden Fassungen" "kernel=$a linux=$b"; fi

# ===========================================================================
# TARGET_OS meldet OS_BARE — sonst nimmt bedingte Uebersetzung den Linux-Zweig
# ===========================================================================

printf 'fn main(): int64 { return TARGET_OS; }\n' > "$TMP/os.lyx"
"$LYXC" --std-path="$ROOT" "$TMP/os.lyx" -o "$TMP/os_linux" >/dev/null 2>&1
if [ -f "$TMP/os_linux" ]; then
  "$TMP/os_linux"; rc=$?
  if [ "$rc" -eq 1 ]; then ok "TARGET_OS ist OS_LINUX auf dem Standardziel"
  else no "TARGET_OS ist OS_LINUX auf dem Standardziel" "rc=$rc"; fi
else
  no "TARGET_OS ist OS_LINUX auf dem Standardziel" "uebersetzt nicht"
fi

# Die Kernel-Fassung laesst sich hier nicht ausfuehren (hlt). Der Wert steht
# aber als Rueckgabewert im Code: `mov eax, 4` vor dem Epilog.
"$LYXC" --std-path="$ROOT" "$TMP/os.lyx" --target=lyxos-kernel -o "$TMP/os_kern" >/dev/null 2>&1
if [ -f "$TMP/os_kern" ]; then
  ak="$(od -An -tx1 -v "$TMP/os_kern" | tr -d ' \n')"
  # movabs rax, 4 → 48 b8 04 00 00 00 00 00 00 00
  case "$ak" in
    *48b80400000000000000*) ok "TARGET_OS ist OS_BARE (4) auf dem Kernel-Ziel" ;;
    *) no "TARGET_OS ist OS_BARE (4) auf dem Kernel-Ziel" "movabs rax,4 fehlt im Code" ;;
  esac
  # Gegenprobe: das Standardziel traegt an derselben Stelle die 1. Beide
  # Muster in beiden Fassungen zu pruefen schliesst aus, dass hier bloss
  # irgendeine 4 irgendwo im Binary gefunden wurde.
  case "$(od -An -tx1 -v "$TMP/os_linux" | tr -d ' \n')" in
    *48b80100000000000000*) ok "Standardziel traegt an derselben Stelle die 1" ;;
    *) no "Standardziel traegt an derselben Stelle die 1" "movabs rax,1 fehlt" ;;
  esac
else
  no "TARGET_OS ist OS_BARE (4) auf dem Kernel-Ziel" "uebersetzt nicht"
fi

# ===========================================================================
# Was unveraendert bleiben muss
# ===========================================================================

# Das Standardziel behaelt getrandom UND laeuft. Ohne diese Gegenprobe koennte
# der Fix schlicht ueberall den Canary entschaerft haben.
case "$(od -An -tx1 -v "$TMP/linux" | tr -d ' \n')" in
  *48c7c03e010000*) ok "Standardziel behaelt getrandom" ;;
  *) no "Standardziel behaelt getrandom" "mov rax,318 fehlt" ;;
esac

printf 'import std.io;\nfn main(): int64 { PrintLn("lauft"); return 0; }\n' > "$TMP/run.lyx"
"$LYXC" --std-path="$ROOT" "$TMP/run.lyx" -o "$TMP/run" >/dev/null 2>&1
if [ -f "$TMP/run" ]; then
  got="$("$TMP/run" 2>&1)"; rc=$?
  if [ "$got" = "lauft" ] && [ "$rc" -eq 0 ]; then ok "Standardziel laeuft unveraendert"
  else no "Standardziel laeuft unveraendert" "'$got' rc=$rc"; fi
else
  no "Standardziel laeuft unveraendert" "uebersetzt nicht"
fi

# Das Importtor (WP-KM-01) gilt weiter: POSIX-Units haben im Kernel nichts zu
# suchen. Es haengt an kernelMode und wuerde durch die Zielumwidmung stumm
# ausfallen, wenn dabei etwas verrutscht waere.
msg="$("$LYXC" --std-path="$ROOT" "$TMP/run.lyx" --target=lyxos-kernel -o "$TMP/x" 2>&1)"
case "$msg" in
  *"kernel error"*"POSIX"*) ok "POSIX-Importtor gilt weiterhin" ;;
  *) no "POSIX-Importtor gilt weiterhin" "$(echo "$msg" | head -1)" ;;
esac

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
