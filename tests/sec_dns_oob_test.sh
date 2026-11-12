#!/usr/bin/env bash
# tests/sec_dns_oob_test.sh — SEC-BUG-03: DNS rdata OOB-Read + Härtung (Quellcode-Check)
#
# Verankert die DNS-Parser-Bounds-Checks gegen Regression (vgl. WP-37/Verifikations-
# pass-Lehre: dokumentierte Fixes können still verschwinden).

DNS="std/net/dns.lyx"
PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1: rdlength-Bounds-Check (SEC-BUG-03 Kern-Fix) vorhanden
if grep -q "offset + rdlength > bufLen" "$DNS"; then _pass 1; else _fail 1 "rdlength-Bounds-Check fehlt (SEC-BUG-03 Regression)"; fi

# 2: dns_skip_name Pointer-Hop-Cap (gegen zirkuläre Komprimierung / DoS)
if grep -q "ptrHops > 100" "$DNS"; then _pass 2; else _fail 2 "dns_skip_name Pointer-Hop-Cap fehlt"; fi

# 3: dns_skip_name 255-Byte-Namens-Cap (RFC 1035)
if grep -q "totalBytes > 255" "$DNS"; then _pass 3; else _fail 3 "dns_skip_name 255-Byte-Cap fehlt"; fi

# 4: bufLen-Obergrenze (UDP-Maximum)
if grep -q "bufLen > 65535" "$DNS"; then _pass 4; else _fail 4 "bufLen-Obergrenze fehlt"; fi

# 5: KEINE irreführende "64-byte result buffer"-Caller-Doku mehr (würde Overflow provozieren)
if grep -qE "pointer to 64-byte result buffer" "$DNS"; then
  _fail 5 "irreführende 64-byte-Doku noch vorhanden (Caller könnte 64 statt 128 allozieren → OOB-Write)"
else _pass 5; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
