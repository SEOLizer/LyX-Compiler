#!/usr/bin/env bash
# tests/riscv_ffi_2162_test.sh — #2162: FFI (`extern fn`) auf riscv64 nach LP64D.
#
# Bis 1.2.17B hatte riscv keinen FFI-Weg: IRO_CALL_EXTERN brach laut ab
# ("kennt Opcode 84 nicht"), einen dynamischen ELF-Schreiber gab es nicht.
# Jetzt:
#   - Argumente nach LP64D: Ganzzahlen/Zeiger in a0..a7, Gleitkomma in
#     fa0..fa7 getrennt gezaehlt, f32 als single; ist die Gleitkommareihe
#     voll, geht der Wert nach der GANZZAHLREGEL weiter (a-Register, dann
#     Stapel). Variadische Argumente in der Ganzzahlreihe.
#   - Rueckgabe aus fa0 (f64/f32) oder a0, schmale Ganzzahlen erweitert.
#   - GOT hinter den Modulvariablen, R_RISCV_64, PT_INTERP
#     /lib/ld-linux-riscv64-lp64d.so.1, Start ueber __libc_start_main
#     (--no-libc-init: direkt).
#
# Die Gegenseite sind echte, von clang nach LP64D uebersetzte Funktionen:
# tests/lib/rv_binder.c, statisch mit dem Android-NDK gebaut, bindet das
# Erzeugnis unter qemu-riscv64 (kein riscv-glibc-Sysroot auf dem Testrechner).
# Ohne NDK wird nur am Erzeugnis gemessen.
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

if [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer riscv64 fehlt — NICHT gemessen"; exit 1; fi

uebersetze() {  # quelle ausgabe [optionen]
  local f="$1" o="$2"; shift 2
  ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" --target=riscv64 "$@" "$f" -o "$o" ) >"$o.log" 2>&1
}

NDKBIN=""
for d in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" $(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1); do
  [ -n "$d" ] || continue
  b=$(ls -d "$d"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)
  if [ -n "$b" ] && [ -x "$b/clang" ]; then NDKBIN="$b"; break; fi
done
BINDER=""
if [ -n "$NDKBIN" ]; then
  for api in 35 37; do
    "$NDKBIN/clang" --target=riscv64-linux-android$api -static -O1 "$ROOT/tests/lib/rv_binder.c" -o "$TMP/binder" -lm >"$TMP/cc.log" 2>&1 && { BINDER="$TMP/binder"; break; }
  done
  [ -n "$BINDER" ] || nok "NDK vorhanden, aber der riscv-Binder baut nicht: $(head -1 "$TMP/cc.log")"
else
  echo "HINWEIS kein Android-NDK — riscv-FFI nur am Erzeugnis gemessen, nicht ausgefuehrt"
fi

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
@cap(system.ffi)
extern fn t_var(n: int64, ...): f64 link "libtest.so";
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
  PrintLn(FloatToStr(t_var(2, 1.5, 2.25), 2));
  zaehler := zaehler + 2;
  PrintInt(zaehler); PrintLn("");
  return 0;
}
EOF
# pow 1024 | atan2 pi/4 | powf (single in fa0/fa1) | labs (nur Ganzzahl) |
# t_misch 1*1000+2*100+3*10+4 (a0,fa0,a1,fa1) | t_halbf 3/2 als single |
# t_fd 1.5*10+0.25 | int32 -1 | uint32 max | int8 -2 | t_viele 0.5 + Summe
# k*k (k=1..9; die neunte Ganzzahl auf dem Stapel) | t_acht fa0..fa7 = 36 |
# t_neun_i 36+18 | t_var 1*1.5 + 2*2.25 = 6.00 (variadisch in a1/a2) |
# Modulvariable im dynamisch gelinkten Abbild.
SOLL="1024.0|0.785398|8.0|5|1234.0|1.50|15.25|-1|4294967295|-2|285.5|36.0|54|6.00|42|"

if uebersetze "$TMP/ffi.lyx" "$TMP/ffi"; then
  ok "FFI-Programm uebersetzt"
  # Am Erzeugnis: dynamisch, richtiger Lader, NEEDED fuer jede Bibliothek.
  kopf="$(python3 -I - "$TMP/ffi" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
phoff, = struct.unpack_from('<Q', b, 32); phn, = struct.unpack_from('<H', b, 56)
flags, = struct.unpack_from('<I', b, 48)
interp = '-'; dyn = None
for i in range(phn):
    t, f, off, va, pa, fs, ms, al = struct.unpack_from('<IIQQQQQQ', b, phoff + i * 56)
    if t == 3: interp = b[off:off + fs].rstrip(b'\0').decode()
    if t == 2: dyn = (off, fs)
need = []; strtab = None
if dyn:
    ents = [struct.unpack_from('<qQ', b, dyn[0] + k * 16) for k in range(dyn[1] // 16)]
    for tag, val in ents:
        if tag == 5: strtab = val - 0x400000
    for tag, val in ents:
        if tag == 1: need.append(b[strtab + val:b.index(b'\0', strtab + val)].decode())
print(interp, hex(flags), ','.join(need))
PY
)"
  if [ "$kopf" = "/lib/ld-linux-riscv64-lp64d.so.1 0x5 libm.so.6,libc.so.6,libtest.so" ]; then ok "Erzeugnis: Lader, lp64d-Flags, NEEDED [$kopf]"
  else nok "Erzeugnis: [$kopf] statt [/lib/ld-linux-riscv64-lp64d.so.1 0x5 libm.so.6,libc.so.6,libtest.so]"; fi
  if [ -n "$BINDER" ]; then
    aus="$(cd "$TMP" && timeout 60 "$QEMU_RISCV64" "$BINDER" "$TMP/ffi" 2>&1 | tr '\n' '|')"; rc=${PIPESTATUS[0]}
    if [ "$aus" = "$SOLL" ] && [ "$rc" = "0" ]; then ok "FFI gegen clang-Code: [$aus]"
    else nok "FFI gegen clang-Code: [$aus] rc=$rc statt [$SOLL]"; fi
  fi
else
  nok "FFI-Programm uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/ffi.log"))"
fi

# --- Rueckgabewert von main ueber __libc_start_main und mit --no-libc-init -----
cat > "$TMP/rc.lyx" <<'EOF'
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
fn main(): int64 { var r: f64 := pow(2.0, 5.0); return r as int64; }
EOF
for opt in "" "--no-libc-init"; do
  name="mit libc-Start"; [ -n "$opt" ] && name="--no-libc-init"
  if uebersetze "$TMP/rc.lyx" "$TMP/rc" $opt; then
    if [ -n "$BINDER" ]; then
      (cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$BINDER" "$TMP/rc" >/dev/null 2>&1); rc=$?
      [ "$rc" = "32" ] && ok "pow(2,5) als Rueckgabe [$name]: rc=$rc" || nok "pow(2,5) als Rueckgabe [$name]: rc=$rc statt 32"
    fi
    # Gegenseite am Erzeugnis: __libc_start_main steht nur MIT libc-Start drin.
    if grep -q "__libc_start_main" "$TMP/rc"; then lsm=1; else lsm=0; fi
    if [ -z "$opt" ] && [ "$lsm" = 1 ]; then ok "[$name]: __libc_start_main gebunden"
    elif [ -n "$opt" ] && [ "$lsm" = 0 ]; then ok "[$name]: kein __libc_start_main"
    else nok "[$name]: __libc_start_main-Bindung=$lsm"; fi
  else nok "rc.lyx [$name] uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/rc.log"))"; fi
done

# --- Gleitkomma jenseits des achten Parameters: laut abgewiesen ---------------
# Die Signaturmaske der Deklaration fuehrt acht Parameter; dahinter ist die
# Klasse unbekannt (wie auf arm64, #2140). Kein stiller Weg in a-Register.
cat > "$TMP/zehn.lyx" <<'EOF'
@cap(system.ffi)
extern fn t_zehn_d(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64): f64 link "libtest.so";
fn main(): int64 { var r: f64 := t_zehn_d(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 2.0, 3.0); return r as int64; }
EOF
if uebersetze "$TMP/zehn.lyx" "$TMP/zehn"; then nok "zehn doubles: uebersetzt (Klasse ab dem neunten unbekannt)"
elif grep -q "ab dem neunten" "$TMP/zehn.log"; then ok "zehn doubles: laut abgewiesen"
else nok "zehn doubles: $(grep -m1 -iE 'error' "$TMP/zehn.log")"; fi

# --- Gegenseite: ohne extern fn bleibt das Erzeugnis statisch ------------------
printf 'fn main(): int64 { return 7; }\n' > "$TMP/st.lyx"
if uebersetze "$TMP/st.lyx" "$TMP/st"; then
  if python3 -I -c "
import struct,sys
b=open(sys.argv[1],'rb').read(); po,=struct.unpack_from('<Q',b,32); n,=struct.unpack_from('<H',b,56)
sys.exit(1 if any(struct.unpack_from('<I',b,po+i*56)[0] in (2,3) for i in range(n)) else 0)" "$TMP/st"; then
    (cd "$TMP" && timeout 30 "$QEMU_RISCV64" "$TMP/st"); rc=$?
    [ "$rc" = 7 ] && ok "ohne extern fn: statisch, rc=7" || nok "ohne extern fn: rc=$rc statt 7"
  else nok "ohne extern fn: PT_INTERP/PT_DYNAMIC im Erzeugnis"; fi
else nok "st.lyx uebersetzt nicht"; fi

# --- --shared: eine riscv-.so, von C geladen und gerufen ------------------------
# Bis 1.2.17B schrieb `--target=riscv64 --shared` still ein statisches
# PROGRAMM. Jetzt ET_DYN mit Exporten (DT_HASH), Huellen fuer Gleitkomma
# (C: fa-Register, Lyx: a-Register), extern fn in der .so ueber den GOT.
cat > "$TMP/lib.lyx" <<'EOF'
type Meter = f64;
@cap(system.ffi)
extern fn pow(b: f64, e: f64): f64 link "libm.so.6";
@export
fn rechne(a: f64, b: int64): f64 { return a * 2.0 + (b as f64); }
@export
fn mischen(n: int64, x: f32, y: Meter, m: int64): f64 { return (x as f64) + y + ((n * 10 + m) as f64); }
@export
fn ganz(a: int64, b: int64): int64 { return a * 10 + b; }
@export
fn viertel(x: f32): f32 { return x / 4.0; }
@export
fn kubik(x: f64): f64 { return pow(x, 3.0); }
@export
fn fmt(a: f64): int64 { var s: pchar := FloatToStr(a); return StrLen(s); }
EOF
if uebersetze "$TMP/lib.lyx" "$TMP/lib.so" --shared; then
  typ="$(python3 -I -c "import struct,sys; print(struct.unpack_from('<H', open(sys.argv[1],'rb').read(), 16)[0])" "$TMP/lib.so")"
  [ "$typ" = 3 ] && ok ".so: ET_DYN" || nok ".so: e_type=$typ statt 3 (ET_DYN)"
  if [ -n "$NDKBIN" ]; then
    LADER=""
    for api in 35 37; do
      "$NDKBIN/clang" --target=riscv64-linux-android$api -static -O1 "$ROOT/tests/lib/rv_solader.c" -o "$TMP/solader" -lm >"$TMP/cc2.log" 2>&1 && { LADER="$TMP/solader"; break; }
    done
    if [ -n "$LADER" ]; then
      aus="$(cd "$TMP" && timeout 60 "$QEMU_RISCV64" "$LADER" "$TMP/lib.so" 2>&1)"; rc=$?
      # rechne(1.5,3)=6 | mischen(4,0.5f,10.25,2)=52.75 (a0,fa0,fa1,a1) |
      # ganz ohne Huelle | viertel(5f)=1.25 als single | kubik(2)=8 ueber pow
      # aus libm (GOT in der .so) | fmt(2.5)="2.500000" mit Merkwerten in
      # s1..s11, die danach unveraendert sein muessen.
      if [ "$aus" = "6.0 52.75 42 1.25 8.0 fmt=8 verloren=-" ] && [ "$rc" = 0 ]; then ok ".so von C gerufen: [$aus]"
      else nok ".so von C gerufen: [$aus] rc=$rc statt [6.0 52.75 42 1.25 8.0 fmt=8 verloren=-]"; fi
    else nok "NDK vorhanden, aber der .so-Lader baut nicht: $(head -1 "$TMP/cc2.log")"; fi
  fi
else nok ".so uebersetzt nicht ($(grep -m1 -iE 'error|fehler' "$TMP/lib.so.log"))"; fi
# Gegenseite: --shared ohne @export ist ein Fehler, keine leere .so.
printf 'fn f(a: int64): int64 { return a; }\n' > "$TMP/leer.lyx"
if uebersetze "$TMP/leer.lyx" "$TMP/leer.so" --shared; then nok ".so ohne @export: uebersetzt"
elif grep -q "keine @export" "$TMP/leer.so.log"; then ok ".so ohne @export: laut abgewiesen"
else nok ".so ohne @export: $(grep -m1 -iE 'error' "$TMP/leer.so.log")"; fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
