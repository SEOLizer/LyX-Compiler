#!/usr/bin/env bash
# tests/sec_tls_hostname_test.sh — SEC-BUG-04: TLS Hostname-Verifikation (Quellcode-Check)
#
# TLSConnect MUSS: hostname==0 ablehnen, SSL_VERIFY_PEER setzen, die Zertifikatskette
# prüfen (SSL_get_verify_result == X509_V_OK) UND den Hostnamen gegen das Cert prüfen
# (X509_check_host). Fehlt letzteres → MITM mit gültigem Cert für andere Domain.
# Regressionsschutz (vgl. WP-37: dokumentierte Fixes können still verschwinden).

TLS="std/net/tls.lyx"
PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# 1: hostname==0 → Verbindung abgelehnt (kein Skip)
if grep -qE "if \(hostname == 0\)" "$TLS"; then _pass 1; else _fail 1 "hostname==0-Guard fehlt (Verify-Skip möglich)"; fi

# 2: SSL_VERIFY_PEER gesetzt
if grep -qE "SSL_set_verify\(ssl, SSL_VERIFY_PEER" "$TLS"; then _pass 2; else _fail 2 "SSL_VERIFY_PEER nicht gesetzt"; fi

# 3: Zertifikatskette geprüft (== X509_V_OK)
if grep -qE "SSL_get_verify_result" "$TLS" && grep -qE "X509_V_OK" "$TLS"; then _pass 3; else _fail 3 "Chain-Verify (X509_V_OK) fehlt"; fi

# 4: Hostname gegen Cert geprüft — X509_check_host AUFGERUFEN (nicht nur deklariert)
if grep -qE ":= X509_check_host\(cert" "$TLS"; then _pass 4; else _fail 4 "X509_check_host wird nicht aufgerufen (Hostname-Skip → MITM)"; fi

# 5: X509_check_host-Ergebnis enforced (Fehlschlag → Verbindung abgebrochen)
if grep -qE "hostOk != 1" "$TLS"; then _pass 5; else _fail 5 "X509_check_host-Ergebnis nicht enforced"; fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
