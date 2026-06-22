#!/usr/bin/env bash
# tests/sec_ffi_failclosed_test.sh — FFI-Sandbox Fail-Closed (Audit SEC-BUG-01/02-Folge)
#
# Früher: unbekannte extern fn → FFI_CLASS_SAFE (Fail-Open) → Sandbox-Bypass.
# Jetzt: FFI_CLASS_UNKNOWN → in User-Code fail-closed (erfordert @cap(...)),
# in vertrauenswürdigen std.*/src.*-Units erlaubt.
# Verhaltenstest: kompiliert echte Programme und prüft Akzeptanz/Ablehnung.

LYXC="$(cd "$(dirname "$0")/.." && pwd)/lyxc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1: unbekannte extern OHNE @cap → MUSS abgelehnt werden (Fail-Closed)
cat > "$TMP/t1.lyx" << 'EOF'
extern fn weird_evil_sym(x: int64): int64 link "weird_evil_sym";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t1.lyx" -o "$TMP/t1" >/dev/null 2>&1; then
  _fail 1 "unbekannte extern OHNE @cap kompilierte (Fail-Open-Bypass!)"
else _pass 1; fi

# 2: unbekannte extern MIT @cap → erlaubt (expliziter Opt-in)
cat > "$TMP/t2.lyx" << 'EOF'
@cap(fs.read)
extern fn weird_evil_sym(x: int64): int64 link "weird_evil_sym";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t2.lyx" -o "$TMP/t2" >/dev/null 2>&1; then _pass 2
else _fail 2 "unbekannte extern MIT @cap wurde abgelehnt (Opt-in kaputt)"; fi

# 3: known-safe extern (memcpy) → erlaubt (kein False-Positive)
cat > "$TMP/t3.lyx" << 'EOF'
extern fn memcpy(d: int64, s: int64, n: int64): int64 link "memcpy";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t3.lyx" -o "$TMP/t3" >/dev/null 2>&1; then _pass 3
else _fail 3 "known-safe memcpy abgelehnt (False-Positive)"; fi

# 4: blacklisted link-Target via Alias (SEC-BUG-01-Regression) → abgelehnt
cat > "$TMP/t4.lyx" << 'EOF'
extern fn harmless(cmd: int64): int64 link "system";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t4.lyx" -o "$TMP/t4" >/dev/null 2>&1; then
  _fail 4 "link-Alias auf system kompilierte (SEC-BUG-01-Regression!)"
else _pass 4; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
