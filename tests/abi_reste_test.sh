#!/usr/bin/env bash
# tests/abi_reste_test.sh — #2140: die ABI-Reste auf arm64, riscv, lyxos, xtensa.
#
# Bis 1.2.16A:
#   (1) arm64: IRO_CALL_EXTERN trug keinen Typ. Jedes Argument ging nach
#       x0..x7, auch f64 — AAPCS64 fuehrt Gleitkommawerte aber getrennt in
#       d0..d7. `pow(2.0, 10.0)` bekam in d0/d1 Zufallswerte, das Ergebnis
#       wurde aus x0 statt d0 gelesen. Eine int-Rueckgabe (`int32`) kam ohne
#       Vorzeichenerweiterung: aus -1 wurde 4294967295 (vgl. #1607 auf x86).
#       Nebenbei: ein dynamisch gelinktes arm64-Erzeugnis (jedes mit `extern
#       fn`) hatte keine Modulvariablen — der Schreiber backte ihre Adressen
#       nicht, schon `import std.io` lief damit ueber Adresse 0.
#       Ein Gleitkommaparameter ab dem neunten lief auf x86 und arm64 still
#       als Ganzzahl (die Signaturmaske reicht nur ueber acht).
#   (2) riscv: s11 (x27, callee-saved) diente als Hilfsregister ohne Sicherung.
#   (3) lyxos: ein Aufruf einer C-Funktion lieferte still 0.
#   (4) xtensa: Aufrufe mit mehr als sechs Argumenten wurden abgewiesen, der
#       Callee verwarf die Parameter ab dem siebten still (#1782).
#
# GEMESSEN WIRD GEGEN ECHTEN C-CODE. arm64: kein aarch64-glibc auf dem Rechner,
# also baut der Test mit dem Android-NDK einen statischen Binder
# (tests/lib/a64_binder.c), der die GLOB_DAT-Plaetze auf von clang nach AAPCS64
# uebersetzte Funktionen setzt (libm + Testfunktionen, deren Ergebnis die Lage
# jedes Arguments erkennen laesst). riscv: tests/lib/rv_rufer.c ruft main als
# C-Funktion und vergleicht s1..s11 davor und danach. Ohne NDK bleiben die
# Pruefungen am Erzeugnis (Befehlsfolgen); dann steht ein HINWEIS da.
# x86 dient mit libm als Vergleich.
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

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ] || [ -z "$QEMU_XTENSA" ]; then
  echo "FAIL qemu fuer arm64/riscv/xtensa fehlt — NICHT gemessen"; exit 1
fi

uebersetze() {  # ziel, quelle, ausgabe  -> rc
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target="$1" "$2" -o "$3" ) >"$3.log" 2>&1
}

# --- NDK: statische Helfer fuer arm64 und riscv64 ----------------------------
NDKBIN=""
for d in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" $(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1); do
  [ -n "$d" ] || continue
  b=$(ls -d "$d"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)
  if [ -n "$b" ] && [ -x "$b/clang" ]; then NDKBIN="$b"; break; fi
done
BINDER=""; RUFER=""
if [ -n "$NDKBIN" ]; then
  "$NDKBIN/clang" --target=aarch64-linux-android30 -static -O1 "$ROOT/tests/lib/a64_binder.c" -o "$TMP/binder" -lm >"$TMP/cc1.log" 2>&1 && BINDER="$TMP/binder"
  "$NDKBIN/clang" --target=riscv64-linux-android35 -static -O1 "$ROOT/tests/lib/rv_rufer.c" -o "$TMP/rufer" >"$TMP/cc2.log" 2>&1 \
    || "$NDKBIN/clang" --target=riscv64-linux-android37 -static -O1 "$ROOT/tests/lib/rv_rufer.c" -o "$TMP/rufer" >"$TMP/cc2.log" 2>&1
  [ -x "$TMP/rufer" ] && RUFER="$TMP/rufer"
  [ -n "$BINDER" ] || nok "NDK vorhanden, aber der arm64-Binder baut nicht: $(head -1 "$TMP/cc1.log")"
  [ -n "$RUFER" ]  || nok "NDK vorhanden, aber der riscv-Rufer baut nicht: $(head -1 "$TMP/cc2.log")"
else
  echo "HINWEIS kein Android-NDK — arm64-FFI und riscv-s11 nur am Erzeugnis gemessen, nicht ausgefuehrt"
fi

# =============================================================================
# (1) arm64: FFI nach AAPCS64
# =============================================================================
cat > "$TMP/ffi.lyx" <<'EOF'
import std.io;
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
@cap(system.ffi)
extern fn atan2(y: f64, x: f64): f64 link "libm.so.6";
@cap(system.ffi)
extern fn powf(b: f32, e: f32): f32 link "libm.so.6";
@cap(system.ffi)
extern fn labs(x: int64): int64 link "libc.so.6";
@cap(system.ffi)
extern fn t_misch(a: int64, x: f64, b: int64, y: f64): f64 link "libtest.so";
@cap(system.ffi)
extern fn t_halbf(x: f32): f32 link "libtest.so";
@cap(system.ffi)
extern fn t_fd(a: f32, b: f64): f64 link "libtest.so";
@cap(system.ffi)
extern fn t_minus_eins(): int32 link "libtest.so";
@cap(system.ffi)
extern fn t_u32_max(): uint32 link "libtest.so";
@cap(system.ffi)
extern fn t_s8(): int8 link "libtest.so";
@cap(system.ffi)
extern fn t_viele(f: f64, a: int64, b: int64, c: int64, d: int64, e: int64, g: int64, h: int64, i: int64, j: int64): f64 link "libtest.so";
@cap(system.ffi)
extern fn t_acht(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64): f64 link "libtest.so";
@cap(system.ffi)
extern fn t_neun_i(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64): int64 link "libtest.so";
var zaehler: int64 := 40;
fn main(): int64 {
  PrintLn(FloatToStr(pow(2.0, 10.0), 1));
  PrintLn(FloatToStr(atan2(1.0, 1.0), 6));
  PrintLn(FloatToStr(powf(2.0, 3.0), 1));
  PrintInt(labs(0 - 5)); PrintLn("");
  PrintLn(FloatToStr(t_misch(1, 2.0, 3, 4.0), 1));
  PrintLn(FloatToStr(t_halbf(3.0), 2));
  PrintLn(FloatToStr(t_fd(1.5, 0.25), 2));
  PrintInt(t_minus_eins()); PrintLn("");
  PrintInt(t_u32_max()); PrintLn("");
  PrintInt(t_s8()); PrintLn("");
  PrintLn(FloatToStr(t_viele(0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9), 1));
  PrintLn(FloatToStr(t_acht(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0), 1));
  PrintInt(t_neun_i(1, 1, 1, 1, 1, 1, 1, 1, 2)); PrintLn("");
  zaehler := zaehler + 2;
  PrintInt(zaehler); PrintLn("");
  return 0;
}
EOF
# pow 1024 | atan2 pi/4 | powf (f32 rein/raus) | labs (nur Ganzzahl) |
# t_misch 1*1000+2*100+3*10+4 | t_halbf 3/2 in s0 | t_fd 1.5*10+0.25 |
# int32 -1 | uint32 max | int8 -2 | t_viele 0.5 + Summe k*k (k=1..9; zwei
# Ganzzahlen auf dem Stapel) | t_acht d0..d7 = 36 | t_neun_i 36+18 |
# Modulvariable im dynamisch gelinkten Abbild.
SOLL="1024.0|0.785398|8.0|5|1234.0|1.50|15.25|-1|4294967295|-2|285.5|36.0|54|42|"

for t in arm64 android-arm64; do
  rm -f "$TMP/ffi.$t"
  if ! uebersetze $t "$TMP/ffi.lyx" "$TMP/ffi.$t"; then
    nok "(1) FFI [$t]: uebersetzt nicht ($(grep -m1 -i error "$TMP/ffi.$t.log"))"; continue
  fi
  if [ -n "$BINDER" ]; then
    aus="$(timeout 60 "$QEMU_ARM64" "$BINDER" "$TMP/ffi.$t" 2>&1 | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$SOLL" ] && [ "$rc" = "0" ]; then ok "(1) FFI gegen clang-Code [$t]: [$aus]"
    else nok "(1) FFI gegen clang-Code [$t]: [$aus] rc=$rc statt [$SOLL]"; fi
  fi
done

# Am Erzeugnis (laeuft auch ohne NDK): die Befehlsfolge um den pow-Aufruf.
# Gesucht wird FMOV d0,x9 ; FMOV d1,x9 ; … BLR x9 ; FMOV x0,d0 — und als
# Gegenseite bei labs (nur Ganzzahl): kein FMOV in d vor, keins aus d nach dem
# Aufruf.
cat > "$TMP/folge.py" <<'EOF'
import struct, sys
b = open(sys.argv[1], 'rb').read()
w = [struct.unpack_from('<I', b, i)[0] for i in range(0x1000, len(b) - 3, 4)]
BLR = 0xD63F0120
def folge():
    for i, x in enumerate(w):
        if x != BLR: continue
        vor = w[max(0, i - 12):i]
        nach = w[i + 1:i + 3]
        yield vor, nach
erg = []
for vor, nach in folge():
    d_ein = sorted(x & 31 for x in vor if (x & 0xFFFFFFE0) == 0x9E670120)   # FMOV d_k, x9
    d_aus = 0x9E660000 in nach                                              # FMOV x0, d0
    erg.append('%s/%d' % (','.join('d%d' % k for k in d_ein) or '-', d_aus))
print(' '.join(erg))
EOF
cat > "$TMP/f_pow.lyx" <<'EOF'
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
fn main(): int64 { var r: f64 := pow(2.0, 5.0); return r as int64; }
EOF
cat > "$TMP/f_labs.lyx" <<'EOF'
@cap(system.ffi)
extern fn labs(x: int64): int64 link "libc.so.6";
fn main(): int64 { return labs(0 - 42); }
EOF
for t in arm64 android-arm64; do
  if uebersetze $t "$TMP/f_pow.lyx" "$TMP/fp.$t" && uebersetze $t "$TMP/f_labs.lyx" "$TMP/fl.$t"; then
    p="$(python3 "$TMP/folge.py" "$TMP/fp.$t")"; l="$(python3 "$TMP/folge.py" "$TMP/fl.$t")"
    # Der erste BLR ist der Aufruf aus main (der Startrumpf nutzt BLR x8).
    case " $p " in *" d0,d1/1 "*) ok "(1) Erzeugnis pow [$t]: d0,d1 rein, d0 raus ($p)";; *) nok "(1) Erzeugnis pow [$t]: [$p] statt d0,d1/1";; esac
    case " $l " in *"d"[0-9]*|*"/1"*) nok "(1) Gegenseite labs [$t]: Gleitkommaregister bei reiner Ganzzahl ($l)";; *) ok "(1) Gegenseite labs [$t]: keine d-Register ($l)";; esac
    # Dieselben Erzeugnisse ohne Modulvariablen ausgefuehrt: der Wert kommt
    # als Rueckgabe, unabhaengig vom Globals-Fehler im dynamischen Abbild.
    if [ -n "$BINDER" ]; then
      timeout 30 "$QEMU_ARM64" "$BINDER" "$TMP/fp.$t" >/dev/null 2>&1; rc=$?
      [ "$rc" = "32" ] && ok "(1) pow(2,5) ohne Globals [$t]: rc=$rc" || nok "(1) pow(2,5) ohne Globals [$t]: rc=$rc statt 32"
      timeout 30 "$QEMU_ARM64" "$BINDER" "$TMP/fl.$t" >/dev/null 2>&1; rc=$?
      [ "$rc" = "42" ] && ok "(1) Gegenseite labs(-42) [$t]: rc=$rc" || nok "(1) Gegenseite labs(-42) [$t]: rc=$rc statt 42"
    fi
  else
    nok "(1) Erzeugnis [$t]: uebersetzt nicht"
  fi
done

# Gegenseite der Typinformation: dieselben Aufrufe auf x86 gegen libm.
cat > "$TMP/x86.lyx" <<'EOF'
import std.io;
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
@cap(system.ffi)
extern fn atan2(y: f64, x: f64): f64 link "libm.so.6";
@cap(system.ffi)
extern fn powf(b: f32, e: f32): f32 link "libm.so.6";
@cap(system.ffi)
extern fn labs(x: int64): int64 link "libc.so.6";
fn main(): int64 {
  PrintLn(FloatToStr(pow(2.0, 10.0), 1));
  PrintLn(FloatToStr(atan2(1.0, 1.0), 6));
  PrintLn(FloatToStr(powf(2.0, 3.0), 1));
  PrintInt(labs(0 - 5)); PrintLn("");
  return 0;
}
EOF
if uebersetze linux "$TMP/x86.lyx" "$TMP/x86"; then
  aus="$(timeout 30 "$TMP/x86" 2>&1 | tr '\n' '|')"
  if [ "$aus" = "1024.0|0.785398|8.0|5|" ]; then ok "(1) Vergleich x86/libm: [$aus]"; else nok "(1) Vergleich x86/libm: [$aus]"; fi
else nok "(1) Vergleich x86: uebersetzt nicht"; fi

# Ein Gleitkommaparameter ab dem neunten: die Maske kennt ihn nicht — laut,
# auf beiden Wegen. Gegenseite: dieselbe Lage als Ganzzahl geht durch.
cat > "$TMP/neun_f.lyx" <<'EOF'
@cap(system.ffi)
extern fn t_neun_f(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, x: f64): f64 link "libtest.so";
fn main(): int64 { var r: f64 := t_neun_f(1, 2, 3, 4, 5, 6, 7, 8, 1.5); return 0; }
EOF
for t in linux arm64; do
  uebersetze $t "$TMP/neun_f.lyx" "$TMP/n9.$t"; rc=$?
  if [ "$rc" != "0" ] && grep -q "neunten.*#2140" "$TMP/n9.$t.log"; then ok "(1) f64 als 9. Parameter [$t]: laut"
  else nok "(1) f64 als 9. Parameter [$t]: rc=$rc ($(grep -m1 -i error "$TMP/n9.$t.log"))"; fi
done
cat > "$TMP/neun_i.lyx" <<'EOF'
@cap(system.ffi)
extern fn t_neun_i(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, g: int64, h: int64, i: int64): int64 link "libtest.so";
fn main(): int64 { return t_neun_i(1, 1, 1, 1, 1, 1, 1, 1, 2); }
EOF
if uebersetze arm64 "$TMP/neun_i.lyx" "$TMP/n9i"; then
  if [ -n "$BINDER" ]; then
    timeout 30 "$QEMU_ARM64" "$BINDER" "$TMP/n9i" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "54" ]; then ok "(1) Gegenseite int64 als 9. Parameter: rc=$rc"; else nok "(1) Gegenseite int64 als 9. Parameter: rc=$rc statt 54"; fi
  else ok "(1) Gegenseite int64 als 9. Parameter: uebersetzt"; fi
else nok "(1) Gegenseite int64 als 9. Parameter: uebersetzt nicht"; fi

# Funktionszeiger: Lyx fuehrt f64 intern in Ganzzahlregistern; ein Zeiger auf
# eine C-Funktion waere beim Aufruf ABI-falsch. Die Adresse einer extern fn
# ist deshalb kein Wert — laut auf beiden Wegen (keine Huelle, s. #2140).
cat > "$TMP/zeiger.lyx" <<'EOF'
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
type T = fn(f64, f64): f64;
fn main(): int64 { var f: T := pow; var r: f64 := f(2.0, 10.0); return r as int64; }
EOF
for t in linux arm64; do
  uebersetze $t "$TMP/zeiger.lyx" "$TMP/z.$t"; rc=$?
  if [ "$rc" != "0" ] && [ ! -s "$TMP/z.$t" ]; then ok "(1) Adresse einer extern fn [$t]: abgewiesen"
  else nok "(1) Adresse einer extern fn [$t]: rc=$rc, Erzeugnis entstanden"; fi
done

# =============================================================================
# (2) riscv: s11 ist callee-saved
# =============================================================================
python3 - "$TMP/gross.lyx" <<'EOF'
import sys
L = ['fn main(): int64 {']
for i in range(300): L.append('  var v%d: int64 := %d;' % (i, i))
L += ['  return v299 + v1 - 258;', '}']
open(sys.argv[1], 'w').write('\n'.join(L) + '\n')
EOF
if uebersetze riscv "$TMP/gross.lyx" "$TMP/gross.rv"; then
  # Rahmen > 2 KB: Prolog und Slotzugriffe gehen ueber s11 (#2061).
  if [ -n "$RUFER" ]; then
    aus="$(timeout 30 "$QEMU_RISCV64" "$RUFER" "$TMP/gross.rv" 2>&1)"
    if [ "$aus" = "ret=42 verloren=-" ]; then ok "(2) C ruft Lyx, grosser Rahmen: [$aus]"
    else nok "(2) C ruft Lyx, grosser Rahmen: [$aus] statt [ret=42 verloren=-]"; fi
  fi
  # Am Erzeugnis: sd s11,16(sp) im Prolog, ld s11,16(sp) im Epilog.
  n="$(python3 -c "
import struct,sys
b=open(sys.argv[1],'rb').read()
w=[struct.unpack_from('<I',b,i)[0] for i in range(0,len(b)-3,4)]
print(w.count(0x01B13823), w.count(0x01013D83))" "$TMP/gross.rv")"
  case "$n" in "0 "*|*" 0") nok "(2) Erzeugnis: sd/ld s11 fehlt ($n)";; *) ok "(2) Erzeugnis: sd/ld s11,16(sp) vorhanden ($n)";; esac
  timeout 30 "$QEMU_RISCV64" "$TMP/gross.rv" >/dev/null 2>&1; rc=$?
  [ "$rc" = "42" ] && ok "(2) grosser Rahmen laeuft: rc=$rc" || nok "(2) grosser Rahmen laeuft: rc=$rc statt 42"
else nok "(2) riscv: uebersetzt nicht ($(grep -m1 -i error "$TMP/gross.rv.log"))"; fi
# Die Stapelargumente liegen jetzt bei s0+32 (ueber s0/ra/s11): zehn Parameter.
cat > "$TMP/zehn.lyx" <<'EOF'
fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64, h: int64, i: int64, j: int64, k: int64): int64 {
  return a + b + c + d + e + g + h + i + (j << 3) + (k << 5);
}
fn main(): int64 { return f(1, 1, 1, 1, 1, 1, 1, 1, 2, 1); }
EOF
if uebersetze riscv "$TMP/zehn.lyx" "$TMP/zehn.rv"; then
  timeout 30 "$QEMU_RISCV64" "$TMP/zehn.rv" >/dev/null 2>&1; rc=$?
  [ "$rc" = "56" ] && ok "(2) zehn Parameter (zwei auf dem Stapel): rc=$rc" || nok "(2) zehn Parameter: rc=$rc statt 56"
  if [ -n "$RUFER" ]; then
    aus="$(timeout 30 "$QEMU_RISCV64" "$RUFER" "$TMP/zehn.rv" 2>&1)"
    [ "$aus" = "ret=56 verloren=-" ] && ok "(2) C ruft Lyx, kleiner Rahmen: [$aus]" || nok "(2) C ruft Lyx, kleiner Rahmen: [$aus]"
  fi
else nok "(2) zehn Parameter: uebersetzt nicht"; fi

# =============================================================================
# (3) lyxos: extern fn laut statt still 0
# =============================================================================
cat > "$TMP/lx.lyx" <<'EOF'
@cap(system.ffi)
extern fn labs(x: int64): int64 link "libc.so.6";
fn main(): int64 { return labs(0 - 5); }
EOF
uebersetze lyxos "$TMP/lx.lyx" "$TMP/lx"; rc=$?
if [ "$rc" != "0" ] && grep -q "labs.*#2140" "$TMP/lx.log"; then ok "(3) lyxos extern fn: laut"
else nok "(3) lyxos extern fn: rc=$rc ($(grep -m1 -i error "$TMP/lx.log"))"; fi
printf 'fn main(): int64 { return 5; }\n' > "$TMP/lx0.lyx"
uebersetze lyxos "$TMP/lx0.lyx" "$TMP/lx0" && [ -s "$TMP/lx0" ] && ok "(3) Gegenseite lyxos ohne extern: uebersetzt" || nok "(3) Gegenseite lyxos ohne extern"

# =============================================================================
# (4) xtensa: Parameter ab dem siebten ueber den Stapel
# =============================================================================
xt() {  # name, quelltext, erwarteter exit-code
  printf '%s\n' "$2" > "$TMP/xt.lyx"; rm -f "$TMP/xt.elf" "$TMP/xt.run"
  if ! uebersetze esp32 "$TMP/xt.lyx" "$TMP/xt.elf"; then nok "(4) $1: uebersetzt nicht ($(grep -m1 -i error "$TMP/xt.elf.log"))"; return; fi
  if ! python3 "$ROOT/tests/lib/xtensa_huelle.py" "$TMP/xt.elf" "$TMP/xt.run" >/dev/null 2>&1; then nok "(4) $1: Huelle"; return; fi
  timeout 60 "$QEMU_XTENSA" "$TMP/xt.run" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$3" ] && ok "(4) $1: rc=$rc" || nok "(4) $1: rc=$rc statt $3"
}
# Gewichte ueber Schiebungen (MULL hat keiner der qemu-Kerne, s. xtensa_laufzeit_test.sh).
xt "sieben Argumente" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64, h: int64): int64 { return a + b + c + d + e + g + (h << 1); } fn main(): int64 { return f(1, 2, 3, 4, 5, 6, 10); }' 41
xt "zehn Argumente" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64, h: int64, i: int64, j: int64, k: int64): int64 { return a + b + c + d + e + g + h + (i << 1) + (j << 2) + (k << 4); } fn main(): int64 { var x: int64 := 1; return f(x, 0, 0, 0, 0, 0, 1, 2, 3, 4); }' 82
xt "acht Argumente, geschachtelt" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64, h: int64, i: int64): int64 { return h - i; } fn h2(): int64 { return f(1, 2, 3, 4, 5, 6, 50, 8); } fn main(): int64 { var v: int64 := 3; var r: int64 := h2(); return r + v - 3; }' 42
# Gegenseite: sechs Argumente bleiben im Registerweg.
xt "sechs Argumente" 'fn f(a: int64, b: int64, c: int64, d: int64, e: int64, g: int64): int64 { return a + b + c + d + e + (g << 1); } fn main(): int64 { return f(1, 2, 3, 4, 5, 10); }' 35

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
