#!/usr/bin/env bash
# tests/debug_tools_reste_test.sh — #2144: Reste aus Tanz E/F.
#
# Bis 1.2.16A:
#   1. addr2line fand im Lyx-DWARF weder Funktion noch Zeile (statisch und
#      .so): die CU trug kein DW_AT_stmt_list (die Zeilentabelle gehoerte zu
#      keiner CU), es gab eine einzige Sequenz, deren Ende auf dem ANFANG der
#      letzten Funktion stand, und das statische ELF hatte keinen .text-
#      Abschnitt (addr2line sucht die Adresse zuerst in einem SHF_ALLOC-
#      Abschnitt). Laufzeithelfer bekamen eine erfundene Zeile 1.
#   2. --meta-safe nahm Codeoffset 176 und Basis 0x400000 fest an und
#      ERSETZTE die Abschnittstabelle: mit --debug verschwanden .debug_* —
#      kein addr2line, kein gdb mehr. Auf anderen Zielen (arm64 ...) wurde der
#      Schalter still verworfen. (--shared weist ihn seit #2124 ab: eine .so
#      hat keine feste Ladeadresse, code_start_va waere erfunden.)
#   3. Der Bump-Allokator (`new`, StrConcat) und die IR-Backends (alloc)
#      prueften das mmap-Ergebnis nicht: -ENOMEM lief als Zeiger weiter, der
#      erste Zugriff faultete (rc 139 ohne Aussage).
#   4. sema: `fn _typeName` stand zweimal in der Klasse (die zweite war nie
#      erreichbar — bei gleichnamigen Methoden gilt die erste).
#   5. _irEingebauteKonst gab fuer lyxos die O_*-Zugriffsarten von Linux aus;
#      der LyxOS-Kernel zaehlt O_READ=1, O_WRITE=2, O_RDWR=3 (kernel/vfs.lyx).
#
# Gemessen wird die WIRKUNG: was addr2line/gdb ausgeben, was das Programm bei
# erzwungenem mmap-Fehler meldet und mit welchem Status es endet, welche Werte
# ein lyxos-Programm fuer O_* sieht. Gegenseiten jeweils mit.
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

for w in addr2line readelf; do
  command -v "$w" >/dev/null 2>&1 || { echo "FAIL $w fehlt — NICHT gemessen"; exit 1; }
done
if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

baue() {  # quelle, ausgabe, weitere Schalter...
  local q="$1" o="$2"; shift 2
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$q" -o "$o" "$@" ) >"$TMP/bl.log" 2>&1
}
fehlertext() { grep -m1 -iE 'error' "$TMP/bl.log"; }

# low_pc einer Funktion aus .debug_info (readelf liest, nicht lyxc).
low_pc() {  # datei, name
  readelf --debug-dump=info "$1" 2>/dev/null | awk -v n="$2" '
    /DW_AT_name/ { split($0, a, ": "); nm = a[length(a)] }
    /DW_AT_low_pc/ && nm == n { print $NF; exit }'
}
# Adresse + 5 (mitten im Prolog, nicht genau am Anfang)
plus5() { printf '0x%x' $(( $1 + 5 )); }

cat > "$TMP/p.lyx" <<'EOF'
fn quadrat(x: int64): int64 {
  return x * x;
}

fn summe(a: int64, b: int64): int64 {
  return quadrat(a) + b;
}

fn main(): int64 {
  var r: int64 := summe(3, 4);
  return r - 13;
}
EOF

# addr2line: Funktion und Datei:Zeile fuer drei Funktionen.
pruefe_a2l() {  # etikett, datei
  local f soll a aus
  for f in quadrat:1 summe:5 main:9; do
    soll="${f#*:}"; f="${f%%:*}"
    a="$(low_pc "$2" "$f")"
    if [ -z "$a" ]; then nok "$1: $f fehlt in .debug_info"; continue; fi
    aus="$(addr2line -f -e "$2" "$(plus5 "$a")" | tr '\n' '|')"
    if [ "$aus" = "$f|p.lyx:$soll|" ] || [[ "$aus" == "$f|"*"/p.lyx:$soll|" ]]; then ok "$1: addr2line $f -> [$aus]"
    else nok "$1: addr2line $f -> [$aus] statt [$f|...p.lyx:$soll|]"; fi
  done
}

# --- 1a. statisches ELF -------------------------------------------------------
if baue "$TMP/p.lyx" "$TMP/p" --debug; then
  pruefe_a2l "statisch" "$TMP/p"
  # Gegenseite: ein Laufzeithelfer hat keine Quellzeile — keine erfundene 1.
  a="$(low_pc "$TMP/p" __lyx_stack_fail)"
  if [ -n "$a" ]; then
    aus="$(addr2line -f -e "$TMP/p" "$(plus5 "$a")" | tr '\n' '|')"
    if [ "$aus" = "__lyx_stack_fail|??:?|" ] || [ "$aus" = "__lyx_stack_fail|??:0|" ]; then ok "statisch: Helfer ohne Quellzeile [$aus]"
    else nok "statisch: Helfer [$aus] statt [__lyx_stack_fail|??:?|]"; fi
  else nok "statisch: __lyx_stack_fail fehlt in .debug_info"; fi
  # Gegenseite: eine Adresse ausserhalb des Codes trifft nichts.
  aus="$(addr2line -f -e "$TMP/p" 0x10 | tr '\n' '|')"
  if [ "$aus" = "??|??:0|" ]; then ok "statisch: Adresse ausserhalb [$aus]"
  else nok "statisch: Adresse ausserhalb [$aus] statt [??|??:0|]"; fi
  # Das Programm laeuft unveraendert.
  timeout 10 "$TMP/p"; rc=$?
  if [ "$rc" = "0" ]; then ok "statisch: --debug-Programm laeuft (rc 0)"; else nok "statisch: rc=$rc"; fi
  # gdb: bt mit Funktion und Zeile.
  if command -v gdb >/dev/null 2>&1; then
    a="$(low_pc "$TMP/p" quadrat)"
    printf 'set debuginfod enabled off\nbreak *%s\nrun\nbt\ninfo line *%s\n' "$a" "$(plus5 "$(low_pc "$TMP/p" summe)")" > "$TMP/g.cmd"
    timeout 60 gdb -batch -nx -x "$TMP/g.cmd" "$TMP/p" > "$TMP/g.log" 2>&1
    bt="$(grep -E '^#[0-9]' "$TMP/g.log" | sed -E 's/^#[0-9]+ +(0x[0-9a-f]+ in )?//; s|^([A-Za-z_0-9]+) \(\) at .*/([^/]+)$|\1:\2|' | tr '\n' ' ')"
    if [ "$bt" = "quadrat:p.lyx:1 summe:p.lyx:5 main:p.lyx:9 " ]; then ok "gdb bt: [$bt]"
    else nok "gdb bt: [$bt] statt [quadrat:p.lyx:1 summe:p.lyx:5 main:p.lyx:9 ]"; fi
    if grep -qE 'Line 5 of ".*p\.lyx"' "$TMP/g.log"; then ok "gdb info line: Zeile 5 in summe"
    else nok "gdb info line: $(grep -m1 -iE 'line|Zeile' "$TMP/g.log")"; fi
  else
    echo "HINWEIS gdb fehlt — bt/info line nicht gemessen (addr2line oben schon)"
  fi
else nok "statisch --debug uebersetzt nicht ($(fehlertext))"; fi

# --- 1b. .so (--debug --shared, #2135) ----------------------------------------
cat > "$TMP/lib.lyx" <<'EOF'
pub fn quadrat(x: int64): int64 {
  return x * x;
}

pub fn summe(a: int64, b: int64): int64 {
  return quadrat(a) + b;
}

fn main(): int64 {
  return summe(3, 4);
}
EOF
# Dieselben Zeilen wie oben, aber unter dem Namen p.lyx, damit pruefe_a2l passt.
mkdir -p "$TMP/so"; cp "$TMP/lib.lyx" "$TMP/so/p.lyx"
if baue "$TMP/so/p.lyx" "$TMP/so/p.so" --shared --debug; then
  pruefe_a2l ".so" "$TMP/so/p.so"
else nok ".so --debug uebersetzt nicht ($(fehlertext))"; fi

# --- 1c. arm64: --debug erzeugt dort kein DWARF (Hinweis, kein Nachweis) ------
# Der IR-Weg schreibt keine .debug_*-Abschnitte; das ist ein eigenes Thema
# (siehe Bericht zu #2144) und wird hier nur festgehalten, nicht geprueft.

# --- 2. --meta-safe -----------------------------------------------------------
cat > "$TMP/ms.lyx" <<'EOF'
import std.meta_safe;
fn quadrat(x: int64): int64 { return x * x; }
fn main(): int64 {
  PrintInt(quadrat(6)); Print(" ");
  PrintInt(MetaSafeFormatVersion()); Print(" ");
  PrintInt(MetaSafeVerify()); Print(" ");
  PrintInt(MetaSafeVerifyMemory()); Print("\n");
  return 0;
}
EOF
if baue "$TMP/ms.lyx" "$TMP/ms" --meta-safe --debug; then
  s="$(readelf -SW "$TMP/ms" 2>&1)"
  n=0; for a in .debug_info .debug_line .text .meta_safe; do echo "$s" | grep -q " $a " && n=$((n+1)); done
  if [ "$n" = "4" ]; then ok "--meta-safe --debug: .debug_info/.debug_line/.text/.meta_safe alle da"
  else nok "--meta-safe --debug: nur $n von 4 Abschnitten ($(echo "$s" | grep -oE '\] \.[a-z_]+' | tr '\n' ' '))"; fi
  a="$(low_pc "$TMP/ms" quadrat)"
  aus="$(addr2line -f -e "$TMP/ms" "$(plus5 "${a:-0}")" | tr '\n' '|')"
  case "$aus" in "quadrat|"*"ms.lyx:2|") ok "--meta-safe --debug: addr2line [$aus]" ;;
                 *) nok "--meta-safe --debug: addr2line [$aus] statt [quadrat|...ms.lyx:2|]" ;; esac
  # Format und Pruefung ueber std.meta_safe: v2, Datei heil, geladener Code heil.
  aus="$(timeout 10 "$TMP/ms" 2>&1 | tr '\n' '|')"
  if [ "$aus" = "36 2 0 0|" ]; then ok "--meta-safe --debug: std.meta_safe meldet v2, Datei und Speicher heil [$aus]"
  else nok "--meta-safe --debug: std.meta_safe [$aus] statt [36 2 0 0|]"; fi
else nok "--meta-safe --debug uebersetzt nicht ($(fehlertext))"; fi
# Gegenseite: ohne --debug weiterhin genau NULL/.meta_safe/.shstrtab.
cat > "$TMP/m0.lyx" <<'EOF'
fn main(): int64 { return 0; }
EOF
if baue "$TMP/m0.lyx" "$TMP/m0" --meta-safe; then
  sec="$(readelf -SW "$TMP/m0" | grep -oE '\] \.[a-z_]+' | sed 's/\] //' | tr '\n' ' ')"
  if [ "$sec" = ".meta_safe .shstrtab " ]; then ok "--meta-safe ohne --debug: [$sec]"
  else nok "--meta-safe ohne --debug: [$sec] statt [.meta_safe .shstrtab ]"; fi
  # code_start_va im Kopf = e_entry (0x4000b0): der Schreiber meldet ihn.
  off="$(readelf -SW "$TMP/m0" | awk '/\.meta_safe/{print $5}')"
  va="$(od -An -t x8 -j $(( 0x$off + 24 )) -N 8 "$TMP/m0" | tr -d ' ')"
  ent="$(LC_ALL=C readelf -h "$TMP/m0" | awk '/Entry point/{print $NF}')"
  if [ "0x${va#"${va%%[!0]*}"}" = "$ent" ]; then ok "--meta-safe: code_start_va = e_entry ($ent)"
  else nok "--meta-safe: code_start_va 0x$va, e_entry $ent"; fi
else nok "--meta-safe uebersetzt nicht ($(fehlertext))"; fi
# Gegenseite: arm64 und --emit=obj weisen --meta-safe laut ab, --shared weiter (#2124).
for v in "--target=arm64" "--emit=obj" "--shared"; do
  rm -f "$TMP/mx"
  if baue "$TMP/m0.lyx" "$TMP/mx" --meta-safe $v; then
    nok "--meta-safe $v: still uebersetzt (rc 0)"
  elif grep -q -- "--meta-safe" "$TMP/bl.log"; then ok "--meta-safe $v: laut abgewiesen"
  else nok "--meta-safe $v: rc!=0, aber keine Meldung zu --meta-safe ($(fehlertext))"; fi
done

# --- 3. mmap-Fehler: Meldung statt Absturz ------------------------------------
MSG="Speicheranforderung fehlgeschlagen (mmap)"
# x86 `new` ueber den Bump-Allokator, Fehler per ulimit -v erzwungen.
cat > "$TMP/viel.lyx" <<'EOF'
type K = class { a: int64; b: int64; };
fn main(): int64 {
  var i: int64 := 0;
  var k: K := new K();
  while (i < 50000000) { k := new K(); k.a := i; i := i + 1; }
  PrintInt(k.a); Print("\n");
  return 0;
}
EOF
if baue "$TMP/viel.lyx" "$TMP/viel"; then
  aus="$( (ulimit -v 65536; timeout 60 "$TMP/viel") 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "1" ] && [ "$aus" = "$MSG" ]; then ok "x86 new unter ulimit -v: Meldung, rc 1"
  else nok "x86 new unter ulimit -v: rc=$rc, stderr [$aus]"; fi
  # Gegenseite: ohne Deckel laeuft dasselbe Programm durch.
  aus="$(timeout 120 "$TMP/viel" 2>&1)"; rc=$?
  if [ "$rc" = "0" ] && [ "$aus" = "49999999" ]; then ok "x86 new ohne Deckel: [$aus] rc 0"
  else nok "x86 new ohne Deckel: [$aus] rc=$rc"; fi
else nok "viel.lyx uebersetzt nicht ($(fehlertext))"; fi
# x86 StrConcat ueber den Bump-Allokator (Groesse zur Laufzeit), ebenfalls gedeckelt.
cat > "$TMP/kette.lyx" <<'EOF'
fn main(): int64 {
  var s: pchar := "abcdefghijklmnopqrstuvwxyz0123456789"c;
  var i: int64 := 0;
  var t: pchar := s;
  while (i < 50000000) { t := StrConcat(s, s); i := i + 1; }
  PrintInt(StrLen(t)); Print("\n");
  return 0;
}
EOF
if baue "$TMP/kette.lyx" "$TMP/kette"; then
  aus="$( (ulimit -v 65536; timeout 60 "$TMP/kette") 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "1" ] && [ "$aus" = "$MSG" ]; then ok "x86 StrConcat unter ulimit -v: Meldung, rc 1"
  else nok "x86 StrConcat unter ulimit -v: rc=$rc, stderr [$aus]"; fi
else nok "kette.lyx uebersetzt nicht ($(fehlertext))"; fi
# IR-Backends: StrNew -> IRO_ALLOC -> mmap (wie `new`). 2^46 Byte scheitert immer
# (ENOMEM), ohne Deckel — ulimit -v traefe unter qemu den Emulator selbst.
cat > "$TMP/gross.lyx" <<'EOF'
fn main(): int64 {
  var p: int64 := StrNew(70368744177664) as int64;
  poke64(p, 7);
  PrintInt(peek64(p)); Print("\n");
  return 0;
}
EOF
cat > "$TMP/klein.lyx" <<'EOF'
fn main(): int64 {
  var p: int64 := StrNew(64) as int64;
  poke64(p + 8, 4711);
  PrintInt(peek64(p + 8)); Print("\n");
  return 0;
}
EOF
for t in arm64 riscv; do
  q="$QEMU_ARM64"; [ "$t" = riscv ] && q="$QEMU_RISCV64"
  if baue "$TMP/gross.lyx" "$TMP/g_$t" --target=$t; then
    aus="$(timeout 30 "$q" "$TMP/g_$t" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" = "1" ] && [ "$aus" = "$MSG" ]; then ok "$t StrNew(2^46): Meldung, rc 1"
    else nok "$t StrNew(2^46): rc=$rc, stderr [$aus]"; fi
  else nok "$t gross.lyx uebersetzt nicht ($(fehlertext))"; fi
  if baue "$TMP/klein.lyx" "$TMP/k_$t" --target=$t; then
    aus="$(timeout 30 "$q" "$TMP/k_$t" 2>&1)"; rc=$?
    if [ "$rc" = "0" ] && [ "$aus" = "4711" ]; then ok "$t StrNew(64): [$aus] rc 0 (Gegenseite)"
    else nok "$t StrNew(64): [$aus] rc=$rc"; fi
  else nok "$t klein.lyx uebersetzt nicht ($(fehlertext))"; fi
done
# x86 StrNew(2^46): bis 1.2.16A ohne Pruefung (#2144), jetzt dieselbe Meldung.
if baue "$TMP/gross.lyx" "$TMP/g_x86"; then
  aus="$(timeout 30 "$TMP/g_x86" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "1" ] && [ "$aus" = "$MSG" ]; then ok "x86 StrNew(2^46): Meldung, rc 1"
  else nok "x86 StrNew(2^46): rc=$rc, stderr [$aus]"; fi
fi

# --- 4. sema: eine Fassung von _typeName --------------------------------------
n="$(grep -c 'fn _typeName' "$ROOT/src/sema.lyx")"
if [ "$n" = "1" ]; then ok "sema: _typeName genau einmal"; else nok "sema: _typeName ${n}-mal"; fi
# Wirkung: der Meldungstext nennt void beim Namen (die zweite Fassung kannte
# void, die geltende erste nicht — dort stand "?").
cat > "$TMP/v.lyx" <<'EOF'
fn nichts() { }
fn main(): int64 {
  var s: pchar := "a"c;
  var x: int64 := s + nichts();
  return 0;
}
EOF
baue "$TMP/v.lyx" "$TMP/v"; rc=$?
m="$(grep -m1 -E 'Operator \+' "$TMP/bl.log")"
case "$m" in *"pchar und void"*) ok "sema: Meldung nennt void [$m]" ;;
             *) nok "sema: rc=$rc, Meldung [$m] nennt void nicht" ;; esac
# Gegenseite: die Namen der uebrigen Typen bleiben (int64 aus derselben Liste).
printf 'fn main(): int64 {\n  var s: pchar := "a"c;\n  var b: bool := true;\n  var x: int64 := s + b;\n  return 0;\n}\n' > "$TMP/v2.lyx"
baue "$TMP/v2.lyx" "$TMP/v2"; rc=$?
m="$(grep -m1 -E 'Operator \+' "$TMP/bl.log")"
case "$m" in *"pchar und bool"*) ok "sema: Meldung nennt bool [$m]" ;;
             *) nok "sema: rc=$rc, Meldung [$m] statt 'pchar und bool'" ;; esac

# --- 5. lyxos: O_* nach dem Kernel --------------------------------------------
# Lauf ueber den lokalen LBF-Lader (nur Ganzzahl, siehe CLAUDE.md).
cat > "$TMP/o.lyx" <<'EOF'
fn main(): int64 {
  return O_RDONLY * 100 + O_WRONLY * 10 + O_RDWR + (O_CREAT + O_TRUNC + O_APPEND - 1600) * 1000;
}
EOF
if ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" --target=lyxos "$TMP/o.lyx" -o "$TMP/o.lyxnative" ) >"$TMP/bl.log" 2>&1; then
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/o.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  ( cd "$ROOT" && LYX_STD_PATH="$ROOT/std" timeout 200 "$LYXC" "$TMP/r.lyx" -o "$TMP/r" ) >/dev/null 2>&1
  timeout 10 "$TMP/r" >/dev/null 2>&1; rc=$?
  # O_READ=1, O_WRITE=2, O_RDWR=3 -> 123; CREAT+TRUNC+APPEND = 1600 -> +0
  if [ "$rc" = "123" ]; then ok "lyxos: O_RDONLY/O_WRONLY/O_RDWR = 1/2/3 (Kernel), Rest wie Linux (=$rc)"
  else nok "lyxos: O_* ergibt $rc statt 123"; fi
else nok "lyxos o.lyx uebersetzt nicht ($(fehlertext))"; fi
# Gegenseite: Linux-Ziele behalten 0/1/2 (=12).
for t in x86_64 arm64; do
  if baue "$TMP/o.lyx" "$TMP/o_$t" --target=$t; then
    if [ "$t" = arm64 ]; then timeout 30 "$QEMU_ARM64" "$TMP/o_$t"; rc=$?; else timeout 10 "$TMP/o_$t"; rc=$?; fi
    if [ "$rc" = "12" ]; then ok "$t: O_* wie Linux (=$rc)"; else nok "$t: O_* ergibt $rc statt 12"; fi
  else nok "$t o.lyx uebersetzt nicht ($(fehlertext))"; fi
done

echo "debug_tools_reste: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ]
