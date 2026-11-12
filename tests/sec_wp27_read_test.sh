#!/usr/bin/env bash
# tests/sec_wp27_read_test.sh — WP-27: read()-Fehlerbehandlung OOB (Quellcode-Check)
#
# read() ungeprüft → bei EINTR (rc<0) oder partiellem Read (rc<size) entstehen
# OOB-Schreibzugriffe (poke8(buf-1)) bzw. Arena-Müll als verarbeitete Daten.
# Diese Tests verankern die Guards im Compiler-Quellcode (Regressionsschutz —
# vgl. WP-37, wo ein als ✅ dokumentierter Fix nie im Code war).

PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

SEMA="src/sema.lyx"
CG="src/codegen_x86.lyx"
# Quelltext, kein Compiler-Aufruf: das Script durchsucht die Datei mit grep.
# Der Name hiess frueher LYXC und log damit ueber seinen Inhalt (#1707).
# Deshalb bindet das Script auch die Ressourcengrenze aus #1294 nicht ein.
LYXC_SRC="src/lyxc.lyx"
KEYGEN="src/lyxc_keygen.lyx"

# 1: _sema_readFile partial-read-Guard
if grep -q "bytesRead != size" "$SEMA"; then _pass 1; else _fail 1 "_sema_readFile partial-read-Guard fehlt"; fi

# 2: cg_readFile (codegen) partial-read-Guard
if grep -A12 "fn cg_readFile" "$CG" | grep -q "bytesRead != size"; then _pass 2; else _fail 2 "cg_readFile partial-read-Guard fehlt"; fi

# 3: --unit-info EINTR-Guard (uiSz < 0)
if grep -q "if uiSz < 0" "$LYXC_SRC"; then _pass 3; else _fail 3 "--unit-info EINTR-Guard fehlt"; fi

# 4: ELF section-header read-Guard
if grep -q "!= shdrsSize" "$LYXC_SRC"; then _pass 4; else _fail 4 "ELF shdrs read-Guard fehlt"; fi

# 5: ELF shstrtab read-Guard
if grep -q "!= strsSize" "$LYXC_SRC"; then _pass 5; else _fail 5 "ELF strtab read-Guard fehlt"; fi

# 6: License-Payload read-Guard (16 Bytes)
if grep -q "16) != 16" "$LYXC_SRC"; then _pass 6; else _fail 6 "License-Payload read-Guard fehlt"; fi

# 7: kein nackter ungeprüfter cg_readFile-read mehr (Regression)
# (lyxc_keygen.lyx ist gitignored → kein Repo-Test dafür)
if grep -A12 "fn cg_readFile" "$CG" | grep -qE "^\s*read\(fd, buf as pchar, size\);\s*$"; then
  _fail 7 "ungeprüfter read() in cg_readFile noch vorhanden"
else _pass 7; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
