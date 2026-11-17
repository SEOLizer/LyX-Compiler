#!/usr/bin/env bash
# tests/sec_tls_hostname_test.sh — SEC-BUG-04: Hostname- und Kettenprüfung
# dürfen nicht still verschwinden (Quelltext-Wächter für BEIDE Umsetzungen).
#
# Die Zusage, die hier bewacht wird, ist eine einzige: **ein TLS-Client prüft
# die Kette UND den Hostnamen, und er überspringt keines von beiden still.**
# Fehlt die Namensprüfung, genügt dem Angreifer ein gültiges Zertifikat für
# eine andere Domain.
#
# Seit #2096 gibt es dafür ZWEI Umsetzungen, und beide werden bewacht:
#
#   std/net/tls.lyx          die native (std.net.tls13 darunter)
#   std/net/tls_openssl.lyx  die FFI-Fassung (weiter benutzbar)
#
# Vorher stand hier nur die zweite Liste, und sie suchte OpenSSL-Aufrufe
# (SSL_VERIFY_PEER, X509_check_host) in std/net/tls.lyx. Nach dem Tausch der
# Umsetzung schlug das fehl — nicht weil die Prüfung fehlte, sondern weil sie
# jetzt anders heißt. Ein Wächter, der die METHODE festschreibt statt die
# Zusage, wird bei jeder Umstellung rot und sagt nichts über Sicherheit.
#
# ── Grenze dieses Tests, ausdrücklich ──────────────────────────────────────
# Das hier ist ein Quelltext-Wächter: er prüft das VORHANDENSEIN von Zeilen,
# nicht ihre Wirkung. Die Wirkung steht in tests/tls_nativ_test.sh, und dort
# wird sie GEMESSEN: TLSConnect ohne Hostnamen wird abgewiesen, ein Server
# mit fremden Vertrauensankern wird abgewiesen, und ein echter Handschlag
# gegen den eigenen Server läuft durch. Dieser Test allein wäre blind für
# eine Zeile, die zwar da ist, aber nichts tut — deshalb gibt es beide.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NATIV="std/net/tls.lyx"
FFI="std/net/tls_openssl.lyx"
TLS13="std/net/tls13.lyx"
PASS=0; FAIL=0
_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# ── Die native Fassung ────────────────────────────────────────────────────
for f in "$NATIV" "$TLS13"; do
  [ -f "$f" ] || { _fail "nativ" "$f fehlt"; }
done

# n1: hostname == 0 wird abgewiesen, nicht uebersprungen.
if grep -qE '\(hostname as int64\) == 0' "$NATIV" \
   && grep -qE 'TLSC_KEIN_HOST' "$NATIV"; then
  _pass "n1 (nativ: hostname==0 wird abgewiesen)"
else
  _fail "n1" "der hostname==0-Riegel fehlt in $NATIV → Namenspruefung ueberspringbar"
fi

# n2: ein leerer Name zaehlt wie keiner.
if grep -qE 'hostLen <= 0' "$NATIV"; then
  _pass "n2 (nativ: leerer Name gilt als keiner)"
else
  _fail "n2" "ein leerer Hostname wird in $NATIV nicht abgewiesen"
fi

# n3: die Kettenpruefung wird EINGESCHALTET, nicht dem Standard ueberlassen.
if grep -qE 'TlsConfigKettePruefen\(cfg, 1\)' "$NATIV"; then
  _pass "n3 (nativ: Kettenpruefung ausdruecklich an)"
else
  _fail "n3" "$NATIV schaltet die Kettenpruefung nicht ausdruecklich ein"
fi

# n4: der Name geht in die Konfiguration — ohne ihn kann tls13 nicht pruefen.
if grep -qE 'TlsConfigHost\(cfg, hostname as int64, hostLen\)' "$NATIV"; then
  _pass "n4 (nativ: Hostname geht an die Konfiguration)"
else
  _fail "n4" "$NATIV uebergibt den Hostnamen nicht an die Konfiguration"
fi

# n5: tls13 gibt den Namen an X509PruefeKette weiter. Ohne das waere n4
#     eine Zeile ohne Wirkung — genau der Fall, fuer den dieser Wachtyp
#     blind ist, darum hier mitgeprueft.
if grep -qE 'X509PruefeKette\(kette, n, TlsCfgTrust\(cfg\)' "$TLS13" \
   && grep -qE 'host, hostLen' "$TLS13"; then
  _pass "n5 (tls13: Name und Trust-Store gehen an X509PruefeKette)"
else
  _fail "n5" "$TLS13 ruft X509PruefeKette nicht mit Host und Trust-Store"
fi

# ── Die FFI-Fassung, solange sie im Baum steht ────────────────────────────
if [ ! -f "$FFI" ]; then
  echo "HINWEIS: $FFI gibt es nicht mehr — die fuenf OpenSSL-Pruefungen entfallen"
else
  if grep -qE "if \(hostname == 0\)" "$FFI"; then _pass "o1 (ffi: hostname==0-Riegel)"; else _fail "o1" "hostname==0-Guard fehlt in $FFI"; fi
  if grep -qE "SSL_set_verify\(ssl, SSL_VERIFY_PEER" "$FFI"; then _pass "o2 (ffi: SSL_VERIFY_PEER)"; else _fail "o2" "SSL_VERIFY_PEER nicht gesetzt"; fi
  if grep -qE "SSL_get_verify_result" "$FFI" && grep -qE "X509_V_OK" "$FFI"; then _pass "o3 (ffi: Kette gegen X509_V_OK)"; else _fail "o3" "Chain-Verify (X509_V_OK) fehlt"; fi
  if grep -qE ":= X509_check_host\(cert" "$FFI"; then _pass "o4 (ffi: X509_check_host wird aufgerufen)"; else _fail "o4" "X509_check_host wird nicht aufgerufen (Hostname-Skip → MITM)"; fi
  if grep -qE "hostOk != 1" "$FFI"; then _pass "o5 (ffi: Ergebnis wird erzwungen)"; else _fail "o5" "X509_check_host-Ergebnis nicht enforced"; fi
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
