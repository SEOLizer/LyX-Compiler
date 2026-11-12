#!/usr/bin/env bash
# tests/sec_ffi_failclosed_test.sh — FFI-Sandbox Fail-Closed (Audit SEC-BUG-01/02-Folge)
#
# Früher: unbekannte extern fn → FFI_CLASS_SAFE (Fail-Open) → Sandbox-Bypass.
# Jetzt: FFI_CLASS_UNKNOWN → in User-Code fail-closed (erfordert @cap(...)),
# in vertrauenswürdigen std.*/src.*-Units erlaubt.
# Verhaltenstest: kompiliert echte Programme und prüft Akzeptanz/Ablehnung.

LYXC="${LYXC:-$(cd "$(dirname "$0")/.." && pwd)/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
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

# 5 (S3): PROCESS-Extern (fork) in User-Code OHNE @cap → abgelehnt
#
# #1179: Die drei Sonden unten trugen keine link-Klausel. Seit 1.0.16J ist die
# Pflicht, und die Sonden waeren aus DIESEM Grund abgewiesen worden — Nr. 5 und
# 7 waeren also aus dem falschen Grund gruen geblieben, Nr. 6 (die eine
# Annahme erwartet) rot. Mit link messen alle drei wieder das, was ihr Name
# sagt: die FFI-Klasse und das @cap-Opt-in.
cat > "$TMP/t5.lyx" << 'EOF'
extern fn fork(): int64 link "libc.so.6";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t5.lyx" -o "$TMP/t5" >/dev/null 2>&1; then
  _fail 5 "User-fork() ohne @cap kompilierte (PROCESS-Klasse-Bypass)"
else _pass 5; fi

# 6 (S3): fork MIT @cap → erlaubt (Opt-in)
cat > "$TMP/t6.lyx" << 'EOF'
@cap(process.spawn)
extern fn fork(): int64 link "libc.so.6";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t6.lyx" -o "$TMP/t6" >/dev/null 2>&1; then _pass 6
else _fail 6 "fork() mit @cap abgelehnt (Opt-in kaputt)"; fi

# 7 (S3): unbekannte Extern in User-Code OHNE @cap → abgelehnt
cat > "$TMP/t7.lyx" << 'EOF'
extern fn weird_nolink_sym(x: int64): int64 link "libweird.so";
fn main(): int64 { return 0; }
EOF
if "$LYXC" "$TMP/t7.lyx" -o "$TMP/t7" >/dev/null 2>&1; then
  _fail 7 "unbekannte no-link-Extern ohne @cap kompilierte (Fail-Open no-link)"
else _pass 7; fi

# 8 (#1179): die link-lose Form wird als solche gemeldet — vorher wurde sie
# angenommen und das Symbol nie gebunden, der Aufruf lieferte still 0.
cat > "$TMP/t8.lyx" << 'EOF'
@cap(process.spawn)
extern fn fork(): int64;
fn main(): int64 { return 0; }
EOF
out8=$("$LYXC" "$TMP/t8.lyx" -o "$TMP/t8" 2>&1)
if [ ! -f "$TMP/t8" ] && echo "$out8" | grep -q "link-Klausel"; then _pass 8
else _fail 8 "fehlende link-Klausel blieb unbeanstandet"; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
