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
# #1179: Die Sonde trug bis 1.0.16J keine link-Klausel. Das Symbol waere also
# ohnehin nie gebunden worden; geprueft wurde die Blacklist an einer
# Deklaration, die gar nichts bewirkt haette. Jetzt mit link — so trifft der
# Test die Sperre und nicht den Nebeneffekt.
cat > "$ROOT/std/_ffi_trust_probe.lyx" <<'EOF'
unit std._ffi_trust_probe;
extern fn execve(path: pchar, argv: pchar, envp: pchar): int64 link "libc.so.6";
pub fn f(): int64 { return 0; }
EOF
rm -f "$TMP/bl.lyu"
out=$("$LYXC" --compile-unit "$ROOT/std/_ffi_trust_probe.lyx" -o "$TMP/bl.lyu" 2>&1)
if [ ! -f "$TMP/bl.lyu" ] && echo "$out" | grep -q "Blacklist"; then ok "blacklist_still_enforced"
else no "blacklist_still_enforced" "Vertrauen hat die FFI-Blacklist ausgehebelt"; fi

# --- 5. Compiler-eigene Symbole brauchen keine extern-Deklaration ---
#
# #1179: Hier stand die Erwartung, dass eine link-LOSE extern-Deklaration im
# std-Baum zulaessig bleibt ("stdlib-interne Builtins"). Nachgemessen traegt
# diese Konvention nichts: `extern fn fork(): int64;` band nie ein Symbol, der
# Aufruf war ein No-op. Belegt mit 1.0.16F — ein Programm mit `fork()` und
# einer Ausgabe danach druckte EINE Zeile statt zwei, das Kind entstand also
# nie. Die Deklaration liess sich uebersetzen; gewirkt hat sie nicht.
#
# Was der Compiler wirklich bereitstellt, heisst `sys_fork` und braucht GAR
# KEINE Deklaration. Genau das haelt dieser Test jetzt fest, dazu die
# Gegenprobe, dass die link-lose Form auch im std-Baum gemeldet wird.
cat > "$ROOT/std/_ffi_trust_probe.lyx" <<'EOF'
unit std._ffi_trust_probe;
pub fn f(): int64 { return sys_fork(); }
EOF
rm -f "$TMP/fk.lyu"
"$LYXC" --compile-unit "$ROOT/std/_ffi_trust_probe.lyx" -o "$TMP/fk.lyu" >/dev/null 2>&1
if [ -f "$TMP/fk.lyu" ]; then ok "stdlib_builtin_no_decl_needed"
else no "stdlib_builtin_no_decl_needed" "Builtin sys_fork wurde im std-Baum abgelehnt"; fi

cat > "$ROOT/std/_ffi_trust_probe.lyx" <<'EOF'
unit std._ffi_trust_probe;
extern fn fork(): int64;
pub fn f(): int64 { return fork(); }
EOF
rm -f "$TMP/nl.lyu"
out=$("$LYXC" --compile-unit "$ROOT/std/_ffi_trust_probe.lyx" -o "$TMP/nl.lyu" 2>&1)
if [ ! -f "$TMP/nl.lyu" ] && echo "$out" | grep -q "link-Klausel"; then ok "stdlib_linkless_extern_rejected"
else no "stdlib_linkless_extern_rejected" "link-lose Deklaration im std-Baum blieb unbeanstandet"; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
