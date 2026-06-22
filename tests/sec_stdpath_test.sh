#!/usr/bin/env bash
# tests/sec_stdpath_test.sh — S2 (V1.1): --std-path= off-by-one Regression (Source-Guard)
#
# Bug: "--std-path=" ist 11 Zeichen; lyxc.lyx nahm arg+10 → stdPath="=PATH".
# Behavior-Test unzuverlässig (Resolver hat mehrere Fallback-Pfade), daher
# Quellcode-Guard auf die korrekte Offset-Konstante.

LYXC_SRC="src/lyxc.lyx"
PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1: korrekter Offset arg+11 nach --std-path=-Prefix-Check
if grep -A2 'StrStartsWith(arg, "--std-path=")' "$LYXC_SRC" | grep -qE "stdPath := arg \+ 11"; then
  _pass 1
else _fail 1 "stdPath-Offset != arg+11 (--std-path= ist 11 Zeichen → off-by-one)"; fi

# 2: der buggy arg+10 darf NICHT mehr da sein
if grep -A2 'StrStartsWith(arg, "--std-path=")' "$LYXC_SRC" | grep -qE "stdPath := arg \+ 10"; then
  _fail 2 "buggy arg+10 noch vorhanden (liefert stdPath=\"=PATH\")"
else _pass 2; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
