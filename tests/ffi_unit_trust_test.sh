#!/usr/bin/env bash
# tests/ffi_unit_trust_test.sh — FFI-Trust-Grenze von --compile-unit.
#
# Beim Import gelten std.*/src.*-Units als Binding-Layer (TCB): ihre Externs
# dürfen FFI_CLASS_UNKNOWN sein. Als ROOT-Modul war dieselbe Unit dagegen
# untrusted — dadurch ließen sich 15 stdlib-Units nicht mehr zu .lyu
# vorkompilieren, was `make package` betraf, nicht nur den Compile-Sweep.
#
# Das Vertrauen kommt jetzt vom PFAD, den der Aufrufer angibt (std/, src/, data/),
# nicht aus einer Selbstauskunft der Datei. Dieser Test hält beide Seiten fest:
# die stdlib-Unit compiliert, und Code außerhalb des Baums bleibt fail-closed —
# auch dann, wenn er sich selbst `unit std.x;` nennt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$ROOT/std/_ffi_trust_probe.lyx"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- 1. stdlib-Unit im std-Baum: unbekanntes FFI-Symbol erlaubt (TCB) ---
cat > "$ROOT/std/_ffi_trust_probe.lyx" <<'EOF'
unit std._ffi_trust_probe;
extern fn some_unknown_probe_symbol(a: int64): int64 link "libprobe.so";
pub fn probe(): int64 { return some_unknown_probe_symbol(1); }
EOF
rm -f "$TMP/probe.lyu"
"$LYXC" --compile-unit "$ROOT/std/_ffi_trust_probe.lyx" -o "$TMP/probe.lyu" >/dev/null 2>&1
if [ -f "$TMP/probe.lyu" ]; then ok "std_tree_unit_trusted"
else no "std_tree_unit_trusted" "stdlib-Unit ließ sich nicht vorkompilieren"; fi

# --- 2. Gleiche Datei AUSSERHALB des Baums: fail-closed, trotz `unit std.*` ---
cp "$ROOT/std/_ffi_trust_probe.lyx" "$TMP/outside.lyx"
rm -f "$TMP/outside.lyu"
out=$("$LYXC" --compile-unit "$TMP/outside.lyx" -o "$TMP/outside.lyu" 2>&1)
if [ ! -f "$TMP/outside.lyu" ] && echo "$out" | grep -q "Fail-Closed"; then ok "outside_tree_fail_closed"
else no "outside_tree_fail_closed" "Selbstauskunft 'unit std.*' reichte für Vertrauen — Bypass"; fi

# --- 3. Normales Programm bleibt fail-closed ---
cat > "$TMP/prog.lyx" <<'EOF'
extern fn some_unknown_probe_symbol(a: int64): int64 link "libprobe.so";
fn main(): int64 { return some_unknown_probe_symbol(1); }
EOF
rm -f "$TMP/prog"
out=$("$LYXC" "$TMP/prog.lyx" -o "$TMP/prog" 2>&1)
if [ ! -f "$TMP/prog" ] && echo "$out" | grep -q "Fail-Closed"; then ok "program_fail_closed"
else no "program_fail_closed" "User-Programm durfte unbekanntes FFI-Symbol deklarieren"; fi

# --- 4. Blacklist gilt auch im std-Baum (execve bleibt verboten) ---
cat > "$ROOT/std/_ffi_trust_probe.lyx" <<'EOF'
unit std._ffi_trust_probe;
extern fn execve(path: pchar, argv: pchar, envp: pchar): int64;
pub fn f(): int64 { return 0; }
EOF
rm -f "$TMP/bl.lyu"
out=$("$LYXC" --compile-unit "$ROOT/std/_ffi_trust_probe.lyx" -o "$TMP/bl.lyu" 2>&1)
if [ ! -f "$TMP/bl.lyu" ] && echo "$out" | grep -q "Blacklist"; then ok "blacklist_still_enforced"
else no "blacklist_still_enforced" "Vertrauen hat die FFI-Blacklist ausgehebelt"; fi

# --- 5. stdlib-interne Builtins ohne link-String bleiben erlaubt ---
cat > "$ROOT/std/_ffi_trust_probe.lyx" <<'EOF'
unit std._ffi_trust_probe;
extern fn fork(): int64;
pub fn f(): int64 { return fork(); }
EOF
rm -f "$TMP/fk.lyu"
"$LYXC" --compile-unit "$ROOT/std/_ffi_trust_probe.lyx" -o "$TMP/fk.lyu" >/dev/null 2>&1
if [ -f "$TMP/fk.lyu" ]; then ok "stdlib_builtin_exempt"
else no "stdlib_builtin_exempt" "fork wurde im std-Baum abgelehnt"; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
