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
LYXC="$ROOT/lyxc"
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
# --- 0x0200-Block-Builtins (kernel-adoptiert): compile-only (LyxOS-Nrn ≠ Linux) ---
compile_ok "lseek_compiles"    'fn main(): int64 { return lseek(3, 0, 2); }'
compile_ok "stat_compiles"     'fn main(): int64 { var s: int64 := 0; return stat("f", s); }'
compile_ok "lstat_compiles"    'fn main(): int64 { var s: int64 := 0; return lstat("f", s); }'
compile_ok "symlink_compiles"  'fn main(): int64 { return symlink("a", "b"); }'
compile_ok "nanosleep_compiles" 'fn main(): int64 { var ts: int64 := 0; return nanosleep(ts, 0); }'
compile_ok "rmdir_compiles"    'fn main(): int64 { return rmdir("d"); }'
compile_ok "eprintint_compiles" 'fn main(): int64 { EPrintInt(42); return 0; }'
compile_ok "argvget_compiles"  'fn main(): int64 { var av: int64 := 0; var p: pchar := ArgvGet(av, 0); return 0; }'
compile_ok "fork_compiles"     'fn main(): int64 { return sys_fork(); }'
compile_ok "execve_compiles"   'fn main(): int64 { return sys_execve("x", 0, 0); }'
compile_ok "wait4_compiles"    'fn main(): int64 { var s: int64 := 0; return sys_wait4(1, s, 0); }'
# pipe/truncate sind keine sema-Builtins (lyxc nutzt sie nicht) → sema lehnt vor lowerCall ab;
# die lowerCall/emit-Einträge (id 231/232) liegen bereit falls sie je registriert werden.

# (EPrintFloat ist sema-bekannt aber nicht für lyxos gelowert → muss laut scheitern)
compile_fail "hardened_catchall" 'fn main(): int64 { EPrintFloat(1.0); return 0; }' "unbekannter Builtin"

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
