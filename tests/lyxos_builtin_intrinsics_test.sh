#!/usr/bin/env bash
# tests/lyxos_builtin_intrinsics_test.sh — Memory-Intrinsics auf --target=lyxos.
# Regression für fix/lyxos-builtin-misdispatch: peek/poke/StrCharAt/StrSetChar fielen in
# ir_lower.lowerCall auf den stillen id=1=PrintStr-Catch-all → write()-Syscall statt
# Byte-Load/Store (fb-Garbling in lbfwin: DrawString liest Glyphen via peek8, FillWinFb
# schreibt via poke64). Fix: echte CALL_BUILTIN-ids 200-207 (movzx/mov im Backend) +
# gehärteter Catch-all (harter Compile-Fehler statt stiller PrintStr-Default).
#
# Reads auf rodata sind im compute-only-Harness (lbf_run, sys_exit=Linux 60) direkt
# verifizierbar. Stores brauchen echtes beschreibbares lyxos-Memory (alloc=new/IRO_ALLOC,
# &local=STUB-01 offen) → hier compile-only geprüft; Byte-Encoding disasm-verifiziert.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run() { # name, source, expected-exit
  printf "%s" "$2" > "$TMP/c.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >/dev/null 2>&1
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/c.lyxnative"c); return 111; }' "$TMP" > "$TMP/r.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1
  timeout 5 "$TMP/r" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS $1 (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $1: exit=$rc erwartet $3"; FAIL=$((FAIL+1)); fi
}

compile_ok() { # name, source — muss FEHLERFREI nach lyxos compilieren
  printf "%s" "$2" > "$TMP/c.lyx"
  if LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >/dev/null 2>&1 \
     && [ -f "$TMP/c.lyxnative" ]; then echo "PASS $1 (compile)"; PASS=$((PASS+1));
  else echo "FAIL $1: compile fehlgeschlagen"; FAIL=$((FAIL+1)); fi
}

compile_fail() { # name, source, expected-message — muss mit Meldung ABBRECHEN, kein Binary
  printf "%s" "$2" > "$TMP/c.lyx"
  rm -f "$TMP/c.lyxnative"
  local out
  out=$(LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" 2>&1)
  if [ ! -f "$TMP/c.lyxnative" ] && echo "$out" | grep -q "$3"; then
    echo "PASS $1 (compile-fail: $3)"; PASS=$((PASS+1));
  else echo "FAIL $1: erwartete Meldung '$3' / kein Binary"; FAIL=$((FAIL+1)); fi
  rm -f "$TMP/c.lyxnative"
}

# --- Reads auf rodata (Laufzeit-verifiziert) ---
run "peek8_rodata"      'fn main(): int64 { return peek8("Z"); }' 90
run "peek64_rodata_low" 'fn main(): int64 { return peek64("ABCDEFGH") & 0xFF; }' 65
run "peek32_rodata_low" 'fn main(): int64 { return peek32("ABCD") & 0xFF; }' 65
run "StrCharAt_0"       'fn main(): int64 { return StrCharAt("Z", 0); }' 90
run "StrCharAt_idx2"    'fn main(): int64 { return StrCharAt("ABCDEF", 2); }' 67

# --- WP-STUB: bisher still verworfene Ops (NOT/BITNOT pure-compute, runtime-verifiziert) ---
run "bitnot"  'fn main(): int64 { var x: int64 := 240; var y: int64 := ~x; return y & 0xFF; }' 15
run "not_zero" 'fn main(): int64 { var x: int64 := 0; return !x; }' 1
run "not_nonzero" 'fn main(): int64 { var x: int64 := 5; return !x; }' 0

# --- WP-CTOR: Konstruktor-Args (new C(args) → ClassName_Create(self,args)). Runtime=Kernel (new→mmap). ---
compile_ok "ctor_args" 'type C = class { a: int64; fn Create(p: int64) { self.a := p; } fn A(): int64 { return self.a; } };
fn main(): int64 { var c: C := new C(11); return c.A(); }' 

# --- WP-XMOD-OOP: virtuelle Dispatch + Vererbung (Registry type-id); Runtime=Kernel (new→mmap) ---
compile_ok "virtual_override" 'type A = class { val: int64; virtual fn S(): int64 { return 0; } };
type D = class extends A { override fn S(): int64 { return 42; } };
fn main(): int64 { var a: A := new D(); return a.S(); }'
compile_ok "field_heavy" 'type H = class { a:int64; b:int64; c:int64; d:int64; e:int64; f:int64; fn G(): int64 { return self.f; } };
fn main(): int64 { var h: H := new H(); return h.G(); }' 

# --- WP-OPCODE-REST: Div/Mod durch 0 → kontrollierter Panic (Exit 1) statt SIGFPE ---
run "div_by_zero_panic"  'fn main(): int64 { var z: int64 := 0; var a: int64 := 10; return a / z; }' 1
run "mod_by_zero_panic"  'fn main(): int64 { var z: int64 := 0; var a: int64 := 10; return a % z; }' 1
run "div_ok_unaffected"  'fn main(): int64 { var a: int64 := 20; var b: int64 := 4; return a / b; }' 5

# --- WP-F64: f64-Pipeline (Literale/Arith/Casts/sqrt) runtime-verifiziert (pure compute) ---
run "f64_add"   'fn main(): int64 { var a: f64 := 2.0; var b: f64 := 3.0; return (a + b) as int64; }' 5
run "f64_mul"   'fn main(): int64 { var a: f64 := 3.0; var b: f64 := 4.0; return (a * b) as int64; }' 12
run "f64_div"   'fn main(): int64 { var a: f64 := 10.0; var b: f64 := 4.0; return (a / b) as int64; }' 2
run "f64_sub"   'fn main(): int64 { var a: f64 := 9.5; var b: f64 := 2.5; return (a - b) as int64; }' 7
run "f64_sqrt"  'fn main(): int64 { var f: f64 := 16.0; return sqrt(f) as int64; }' 4
run "f64_itof_ftoi" 'fn main(): int64 { var i: int64 := 7; var f: f64 := i as f64; return f as int64; }' 7
run "f64_cmp"   'fn main(): int64 { var a: f64 := 3.0; var b: f64 := 2.0; if a > b { return 1; } return 0; }' 1

# --- WP-ADDR: @local (Adresse-von) runtime ---
run "addr_read"  'fn main(): int64 { var x: int64 := 42; var p: int64 := @x; return peek64(p); }' 42
run "addr_write" 'fn main(): int64 { var x: int64 := 5; var p: int64 := @x; poke64(p, 99); return x; }' 99
# --- WP-F64-CMP: ucomisd (korrekt auch für NEGATIVE f64; vorher Integer-CMP der Bits) ---
run "f64_cmp_neg"     'fn main(): int64 { var a: f64 := 0.0 - 5.0; var b: f64 := 0.0 - 2.0; if a < b { return 1; } return 0; }' 1
run "f64_cmp_neg_pos" 'fn main(): int64 { var a: f64 := 0.0 - 1.0; var b: f64 := 1.0; if a < b { return 7; } return 0; }' 7
run "f64_cmp_eq"      'fn main(): int64 { var a: f64 := 2.5; var b: f64 := 2.5; if a == b { return 3; } return 0; }' 3

# --- WP-SIMD: parallel Array<f32> (aligned mmap + f32-Element + vektorisierte SSE2-Binops) ---
run "simd_store_load" 'fn main(): int64 { let v: parallel Array<f32>(4) = parallel Array<f32>(4); v[0] := 7.0; return v[0] as int64; }' 7
run "simd_add" 'fn main(): int64 { let a: parallel Array<f32>(4) = parallel Array<f32>(4); let b: parallel Array<f32>(4) = parallel Array<f32>(4); a[0] := 2.0; b[0] := 3.0; let c: parallel Array<f32> = a + b; return c[0] as int64; }' 5
run "simd_mul" 'fn main(): int64 { let a: parallel Array<f32>(4) = parallel Array<f32>(4); let b: parallel Array<f32>(4) = parallel Array<f32>(4); a[2] := 6.0; b[2] := 7.0; let c: parallel Array<f32> = a * b; return c[2] as int64; }' 42
run "simd_neg" 'fn main(): int64 { let a: parallel Array<f32>(4) = parallel Array<f32>(4); a[1] := 5.0; let b: parallel Array<f32> = -a; return (0 - (b[1] as int64)); }' 5

# --- WP-WSP: Kernel-Systemprimitive (Atomics runtime; cpu-ctrl privileged = compile-only) ---
run "atomic_store_load" 'fn main(): int64 { var x: int64 := 10; var p: int64 := @x; atomic_store(p, 42); return atomic_load(p); }' 42
run "atomic_fetch_add"  'fn main(): int64 { var x: int64 := 10; var p: int64 := @x; var old: int64 := atomic_fetch_add(p, 5); return x; }' 15
run "atomic_cas_ok"     'fn main(): int64 { var x: int64 := 10; var p: int64 := @x; atomic_cas(p, 10, 99); return x; }' 99
run "atomic_cas_fail"   'fn main(): int64 { var x: int64 := 10; var p: int64 := @x; atomic_cas(p, 7, 99); return x; }' 10
run "wsp_pause_fences"  'fn main(): int64 { cpu_pause(); fence_sfence(); fence_lfence(); fence_mfence(); return 5; }' 5
compile_ok "wsp_cpuctrl" 'fn main(): int64 { cpu_cli(); cpu_sti(); cpu_hlt(); var v: int64 := cpu_rdmsr(0); cpu_wrmsr(0, 1); return 0; }' 
# --- WP-VOLATILE: @volatile-Local — Read wird nicht von DCE eliminiert (MMIO). Runtime-neutral. ---
compile_ok "volatile_decl" '@volatile var g: int64 := 0; fn main(): int64 { @volatile var x: int64 := 5; x; return x; }' 
# --- WP-ALIGN: @align(n) array/heap-backed Local → n-aligned Allokation (over-alloc+round) ---
compile_ok "align_array" 'fn main(): int64 { @align(4096) var buf: int64[8]; buf[0] := 7; return buf[0]; }' 

# --- peek16 Word-Read (Laufzeit, rodata) ---
run "peek16_low"  'fn main(): int64 { return peek16("AB") & 0xFF; }' 65
run "peek16_high" 'fn main(): int64 { return (peek16("AB") >> 8) & 0xFF; }' 66

# --- Stores + memcpy: compile-only (Byte-Encoding disasm-verifiziert) ---
compile_ok "poke8_compiles"      'var a: int64[4]; fn main(): int64 { poke8(a, 77); return 0; }'
compile_ok "poke32_compiles"     'var a: int64[4]; fn main(): int64 { poke32(a, 1000); return 0; }'
compile_ok "poke64_compiles"     'var a: int64[4]; fn main(): int64 { poke64(a, 999); return 0; }'
compile_ok "poke16_compiles"     'var a: int64[4]; fn main(): int64 { poke16(a, 4660); return 0; }'
compile_ok "memcpy_compiles"     'var a: int64[4]; fn main(): int64 { memcpy(a, "XYZ", 3); return 0; }'
compile_ok "StrSetChar_compiles" 'var a: int64[4]; fn main(): int64 { StrSetChar(a as pchar, 0, 88); return 0; }'

# --- Gruppe A: POSIX-File-Builtins → flache §10.4-Syscalls (compile-only;
#     LyxOS-Syscall-Nrn ≠ Linux → kein lbf_run-Runtime auf Linux; Disasm-verifiziert) ---
compile_ok "open_compiles"   'fn main(): int64 { var fd: int64 := open("f", 0, 0); return 0; }'
compile_ok "read_compiles"   'fn main(): int64 { var fd: int64 := 3; read(fd, "b", 1); return 0; }'
compile_ok "write_compiles"  'fn main(): int64 { var fd: int64 := 1; write(fd, "b", 1); return 0; }'
compile_ok "close_compiles"  'fn main(): int64 { close(3); return 0; }'
compile_ok "unlink_compiles" 'fn main(): int64 { unlink("f"); return 0; }'
compile_ok "rename_compiles" 'fn main(): int64 { rename("a", "b"); return 0; }'
compile_ok "mkdir_compiles"  'fn main(): int64 { mkdir("d", 0); return 0; }'
compile_ok "exit_compiles"   'fn main(): int64 { exit(0); return 0; }'

# --- Gehärteter Catch-all: sema-bekannter aber nicht gelowerter Builtin → harter Fehler ---
# --- 0x0200-Block-Builtins: melden jetzt, statt zu bauen (#1734) ---
#
# Diese Faelle standen bis 1.1.4M als compile_ok in der Liste, mit dem Vermerk
# "kernel-adoptiert". Das war eine Annahme, keine Messung: die Nummern stammen
# aus der hex-gruppierten Entwurfs-ABI (0x0204 lseek, 0x0205 stat, 0x0213
# symlink, 0x020C pipe, 0x020D truncate), und im Kernel gibt es sie nicht.
# Implementiert sind flach 0-228 und 300-326 (LyxOS-Team gegen kernel/ring3.lyx,
# work/lyxos/antwort-lyxos.md).
#
# "Baut durch" war also die falsche Erwartung -- der erzeugte Aufruf ging ins
# Leere. Seit 1.1.5A bricht der Bau mit Builtin-ID und Nummer ab, und genau das
# wird hier geprueft. Wo es eine echte Nummer gibt (lseek waere 8, pipe waere
# 320 pipe2), ist das Folgearbeit unter #1734; sie wird nicht hier per Annahme
# entschieden, denn dieselbe Sorte Annahme steht ja am Anfang dieses Absatzes.
compile_fail "lseek_meldet"    'fn main(): int64 { return lseek(3, 0, 2); }' "gibt es in LyxOS nicht"
compile_fail "stat_meldet"     'fn main(): int64 { var s: int64 := 0; return stat("f", s); }' "gibt es in LyxOS nicht"
compile_fail "lstat_meldet"    'fn main(): int64 { var s: int64 := 0; return lstat("f", s); }' "gibt es in LyxOS nicht"
compile_fail "symlink_meldet"  'fn main(): int64 { return symlink("a", "b"); }' "gibt es in LyxOS nicht"
compile_ok "nanosleep_compiles" 'fn main(): int64 { var ts: int64 := 0; return nanosleep(ts, 0); }'
compile_fail "pipe_meldet"     'fn main(): int64 { var a: int64 := 0; var b: int64 := 0; return pipe(a, b, 0); }' "gibt es in LyxOS nicht"
compile_fail "truncate_meldet" 'fn main(): int64 { return truncate(3, 100); }' "gibt es in LyxOS nicht"
compile_fail "rmdir_meldet"    'fn main(): int64 { return rmdir("d"); }' "gibt es in LyxOS nicht"
compile_ok "eprintint_compiles" 'fn main(): int64 { EPrintInt(42); return 0; }'
compile_ok "argvget_compiles"  'fn main(): int64 { var av: int64 := 0; var p: pchar := ArgvGet(av, 0); return 0; }'
compile_ok "fork_compiles"     'fn main(): int64 { return sys_fork(); }'
compile_ok "execve_compiles"   'fn main(): int64 { return sys_execve("x", 0, 0); }'
compile_ok "wait4_compiles"    'fn main(): int64 { var s: int64 := 0; return sys_wait4(1, s, 0); }'
# pipe/truncate sind keine sema-Builtins (lyxc nutzt sie nicht) → sema lehnt vor lowerCall ab;
# die lowerCall/emit-Einträge (id 231/232) liegen bereit falls sie je registriert werden.

# --- OOP-Vererbung: geerbtes Feld (compile-only; new→mmap nr9 nicht via lbf_run/Linux testbar,
#     Runtime-Verifikation auf echtem LyxOS-Kernel). Fix: _fieldOffsetIn/_typeSizeOf basis-rekursiv. ---
compile_ok "oop_inherited_field" 'type A = class { val: int64; virtual fn S(): int64 { return 0; } };
type D = class extends A { override fn S(): int64 { return self.val + 1; } fn C(v: int64) { self.val := v; } };
fn main(): int64 { var d: D := new D(); d.C(41); return d.val; }'
# WP-VMT: virtuelle Dispatch über Basis-Pointer (a:A hält D → D.S override). Runtime=Kernel (=42).
compile_ok "oop_virtual_dispatch" 'type A = class { val: int64; virtual fn S(): int64 { return 0; } };
type D = class extends A { override fn S(): int64 { return self.val + 1; } fn C(v: int64) { self.val := v; } };
fn main(): int64 { var d: D := new D(); d.C(41); var a: A := d; return a.S(); }'

# --- Float-Memory-Intrinsics (ids 253-256) ---
# Gleiche Lücke wie 200-207: in sema registriert, in codegen_x86 (ELF) inline emittiert,
# im lyxos-Pfad aber nicht gelowert → liefen in den (inzwischen fail-loud) Catch-all.
# Reads sind auf rodata runtime-prüfbar: die ASCII-Bytes ergeben definierte Floats
# ("AAAA" als f32 = 12.078431, "AAAAAAAA" als f64 = 2261634.5098) — das prüft zugleich
# die f32→f64-Weitung von peek32f, nicht nur dass überhaupt geladen wird.
run "peek32f_rodata" 'fn main(): int64 { var v: f64 := peek32f("AAAA"); if (v > 12.0 && v < 12.1) { return 55; } return 1; }' 55
run "peekf64_rodata" 'fn main(): int64 { var v: f64 := peekf64("AAAAAAAA"); if (v > 2261634.0 && v < 2261635.0) { return 56; } return 1; }' 56
run "peek32f_other"  'fn main(): int64 { var v: f64 := peek32f("@@@@"); if (v > 3.0 && v < 3.01) { return 57; } return 1; }' 57

# Stores brauchen beschreibbares Memory (wie poke64 oben) → compile-only.
compile_ok "pokef64_compiles" 'fn main(): int64 { var b: int64 := mmap(0, 4096, 3, 34, 0-1, 0); pokef64(b, 2.5); return 0; }'
compile_ok "poke32f_compiles" 'fn main(): int64 { var b: int64 := mmap(0, 4096, 3, 34, 0-1, 0); poke32f(b, 1.5); return 0; }'

# (EPrintFloat ist sema-bekannt aber nicht für lyxos gelowert → muss laut scheitern)
compile_fail "hardened_catchall" 'fn main(): int64 { EPrintFloat(1.0); return 0; }' "unbekannter Builtin"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
