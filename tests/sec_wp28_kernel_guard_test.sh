#!/usr/bin/env bash
# tests/sec_wp28_kernel_guard_test.sh — WP-28: Kernel-Mode-Guard Allowlist (20 tests)
#
# Prüft dass --target=lyxos-kernel:
#   - std.net.* komplett blockt (Allowlist-Ansatz, nicht Blocklist)
#   - std.fs.*, std.thread.*, std.os.*, std.io.* blockt
#   - 5 reine Frame-Units weiterhin erlaubt

set -euo pipefail

LYXC="${LYXC:-$(cd "$(dirname "$0")/.." && pwd)/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

make_lyx() {
  local file="$1"
  local mod="$2"
  printf 'unit test.wp28;\nimport %s;\nfn main() {}\n' "$mod" > "$file"
}

expect_blocked() {
  local n="$1" mod="$2"
  make_lyx "$TMP/t.lyx" "$mod"
  if "$LYXC" "$TMP/t.lyx" --target=lyxos-kernel -o "$TMP/t" 2>/dev/null; then
    _fail "$n" "$mod: expected kernel error, compiler succeeded"
  else
    _pass "$n"
  fi
}

expect_allowed() {
  local n="$1" mod="$2"
  make_lyx "$TMP/t.lyx" "$mod"
  if "$LYXC" "$TMP/t.lyx" --target=lyxos-kernel -o "$TMP/t" 2>/dev/null; then
    _pass "$n"
  else
    _fail "$n" "$mod: expected allowed, got kernel error"
  fi
}

# ── Tests 1-5: std.net.* — verbotene Syscall-Module (Allowlist: alles außer Frame-Units) ──
expect_blocked  1 "std.net"
expect_blocked  2 "std.net.socket"
expect_blocked  3 "std.net.epoll"       # WP-28: war Blocklist-Lücke — jetzt korrekt geblockt
expect_blocked  4 "std.net.http"
expect_blocked  5 "std.net.tls"

# ── Tests 6-8: Weitere std.net.* Lücken die Blocklist verpasste ──────────────
expect_blocked  6 "std.net.dns"
expect_blocked  7 "std.net.syscalls"
expect_blocked  8 "std.net.mqtt"

# ── Tests 9-10: std.net.dhcp / std.net.arp (nur .frame ist erlaubt) ──────────
expect_blocked  9 "std.net.dhcp"
expect_blocked 10 "std.net.arp"

# ── Tests 11-14: std.fs / std.thread / std.os / std.io ───────────────────────
expect_blocked 11 "std.fs"
expect_blocked 12 "std.thread"
expect_blocked 13 "std.os"
expect_blocked 14 "std.io"

# ── Tests 15-17: Submodule bleiben verboten ───────────────────────────────────
expect_blocked 15 "std.fs.ext"
expect_blocked 16 "std.thread.pool"
expect_blocked 17 "std.io.stream"

# ── Tests 18-20: Erlaubte reine Frame-Units ───────────────────────────────────
expect_allowed 18 "std.net.eth"
expect_allowed 19 "std.net.ipv4"
expect_allowed 20 "std.net.udp"

# Tests 21-22 (arp.frame / dhcp.frame) geprüft in net_frame_test.lyx

echo ""
echo "WP-28: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
