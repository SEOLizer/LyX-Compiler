#!/usr/bin/env bash
# tests/tls13_interop_openssl_test.sh — #2096 Etappe E: Interop-Nachweis
# gegen OpenSSL. Abnahmekriterium 1 und 2 aus #2096 (Server- und Client-Rolle
# gegen `openssl s_client`/`s_server`).
#
# Geprueft wird:
#   1. Unser Server gegen `openssl s_client` mit allen drei Cipher-Suites;
#      openssl muss TLSv1.3, die Suite, das Zertifikat ("Verify return code:
#      0") und unsere Antwortdaten melden.
#   2. Unser Server mit verlangtem Client-Zertifikat: mit Zertifikat Erfolg,
#      OHNE Zertifikat Abbruch mit Fehler -6. Beide Richtungen, weil ein Test
#      nur des guten Falls auch von einem Server erfuellt waere, der jedes
#      Client-Zertifikat durchlaesst.
#   3. Unser Client gegen `openssl s_server`, einmal ohne und einmal mit
#      Client-Zertifikat (mTLS); openssl muss unsere Kette verifizieren.
#
# Ohne openssl im Pfad wird der Test uebersprungen (SKIP), ohne freie Ports
# ebenfalls — ein roter Test aus Umgebungsgruenden sagt nichts ueber den Code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl nicht im Pfad"; exit 0
fi
OSSLV="$(openssl version 2>/dev/null)"
if ! openssl s_client -help 2>&1 | grep -q tls1_3; then
  echo "SKIP openssl ohne TLS-1.3-Unterstuetzung ($OSSLV)"; exit 0
fi
echo "openssl: $OSSLV"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; pkill -f "s_server -accept 1856" 2>/dev/null' EXIT
mkdir -p "$TMP/certs"
cat > "$TMP/certs/tlsca.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBbzCCARSgAwIBAgICcAEwCgYIKoZIzj0EAwIwLDEVMBMGA1UEAwwMQXVydW0g
VExTIENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLDEVMBMGA1UEAwwMQXVydW0gVExTIENBMRMwEQYDVQQKDApB
dXJ1bSBUZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3a2NfJ1/mpoyEWsT
ZrFd+TJWJE7e1cQ5xO5Zw/A9omNflfqqok62KU6XK0b8E0P915QVTMzLGBPP7499
Nia5H6MmMCQwEgYDVR0TAQH/BAgwBgEB/wIBATAOBgNVHQ8BAf8EBAMCAYYwCgYI
KoZIzj0EAwIDSQAwRgIhAJVCkdPFKLxMlKaT0gXw/hMmfQEaCgGGv6qoAKwYGMWx
AiEAo1GhCrHunvjleL0bTnKRZU+YBsxiioPZnWgeZdv31hc=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/tlssrv.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBmDCCAT6gAwIBAgICcAIwCgYIKoZIzj0EAwIwLDEVMBMGA1UEAwwMQXVydW0g
VExTIENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLTEWMBQGA1UEAwwNbmV4dXMuZXhhbXBsZTETMBEGA1UECgwK
QXVydW0gVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABHTsWypZoHC8Y+jv
DHgWXumKas5YDWOyaYhWQGjjqIRpoP8WnG5mh3+QsHMUIaIjixX63ExbD3bJW5ZK
cMWHILujTzBNMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQM
MAoGCCsGAQUFBwMBMBgGA1UdEQQRMA+CDW5leHVzLmV4YW1wbGUwCgYIKoZIzj0E
AwIDSAAwRQIgLbQ23G518d+0Qfc53GILrqRqLnKDStz4OoWM30aaBAwCIQDm5qne
WcrM+NpXO9SoDgQnNHBO4eVJQz0AMAWx5o9TLg==
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/tlscli.pem" <<'PEMEOF'
-----BEGIN CERTIFICATE-----
MIIBmTCCAUCgAwIBAgICcAMwCgYIKoZIzj0EAwIwLDEVMBMGA1UEAwwMQXVydW0g
VExTIENBMRMwEQYDVQQKDApBdXJ1bSBUZXN0MB4XDTI2MDEwMTAwMDAwMFoXDTM2
MDEwMTAwMDAwMFowLjEXMBUGA1UEAwwOY2xpZW50LmV4YW1wbGUxEzARBgNVBAoM
CkF1cnVtIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQQTvnNJvH7YFb8
4aPQ2rgyIrx1XKoj3KwB/BpJ6UCtPEfuA20/CH2J/gXHDuOey/atCtBmPKiyNlIv
2fZ2UYG4o1AwTjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUE
DDAKBggrBgEFBQcDAjAZBgNVHREEEjAQgg5jbGllbnQuZXhhbXBsZTAKBggqhkjO
PQQDAgNHADBEAiAu1/fgtKNRBtZJvtZu3IqLsaMst+bRW29tX4xgXpwKOQIgMI1Z
fqdJ/rIfmP/4hc4u7jppKePTkBGF7sSwR+MlZH8=
-----END CERTIFICATE-----
PEMEOF
cat > "$TMP/certs/tlssrvkey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvPS7dPO8HJT+dnMm
V3fUzeQjctLlp5lQPFJtHAnu3OuhRANCAAR07FsqWaBwvGPo7wx4Fl7pimrOWA1j
smmIVkBo46iEaaD/FpxuZod/kLBzFCGiI4sV+txMWw92yVuWSnDFhyC7
-----END PRIVATE KEY-----
PEMEOF
cat > "$TMP/certs/tlsclikey.pem" <<'PEMEOF'
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgy5ggUJLLoLYZlsds
oU0nVjQBYMN7nm7Wtlp5f/Xb16uhRANCAAQQTvnNJvH7YFb84aPQ2rgyIrx1XKoj
3KwB/BpJ6UCtPEfuA20/CH2J/gXHDuOey/atCtBmPKiyNlIv2fZ2UYG4
-----END PRIVATE KEY-----
PEMEOF

cat > "$TMP/srv.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.net.socket;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  // GetArg liefert einen Zeiger auf die Zeichenkette, keine Zahl — ohne
  // StrToInt landet das Programm auf einem zufaelligen Port.
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var dSrv: int64 := alloc(4096); var lSrv := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dCa: int64 := alloc(4096);  var lCa := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSk: int64 := alloc(4096);  var lSk := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  if (lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }
  var kette: int64 := alloc(32);
  poke64(kette, dSrv); poke64(kette + 8, lSrv);
  poke64(kette + 16, dCa); poke64(kette + 24, lCa);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var alpn: pchar := "h2,http/1.1"c;
  TlsConfigNeu(cfg, 1);
  TlsConfigKette(cfg, kette, 2, dSk, lSk);
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigZeit(cfg, 1800000000);
  // Zweites Argument: Client-Zertifikat verlangen (mTLS)
  if (GetArgC() > 2) {
    var trust: int64 := alloc(16);
    poke64(trust, dCa); poke64(trust + 8, lCa);
    TlsConfigTrust(cfg, trust, 1);
    TlsConfigClientAuth(cfg, 2);
  }

  var l: TCPListener := TCPListenerNew();
  TCPListenerSetReuseAddr(l);
  if (TCPListenerBindTo(l, 0, port) != 0) { PrintLn("BINDFEHLER"); return 1; }
  TCPListenerListen(l, 4);
  PrintLn("bereit");

  var conn: TCPConn := TCPListenerAccept(l);
  var c: int64 := TlsNeu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!TlsFertig(c) && runden < 200) {
    var rc: int64 := TlsSchritt(c);
    if (rc < 0) { Print("FEHLER "); PrintInt(rc); Print(" "); PrintLn(TlsFehlerText(rc)); return 1; }
    var m: int64 := TlsAusgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!TlsFertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 1; }
      TlsFuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!TlsFertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 1; }
  var pz: int64 := TlsPeerZertifikat(c);
  if (pz != 0) { Print("client-zertifikat-geprueft "); PrintInt(X509SubjectLen(pz) > 0); PrintLn(""); }
  Print("handschlag-fertig suite "); PrintInt(TlsSuite(c));
  Print(" alpn ");
  var i: int64 := 0;
  while (i < TlsAlpnLen(c)) { PrintChar(peek8(TlsAlpnPos(c) + i)); i := i + 1; }
  PrintLn("");

  // Anfrage lesen, Antwort senden
  var ein: int64 := alloc(4096);
  var gelesen: int64 := 0;
  runden := 0;
  while (gelesen <= 0 && runden < 100) {
    var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
    if (n2 > 0) { TlsFuetter(c, puf, n2); }
    gelesen := TlsLese(c, ein, 4096);
    if (n2 <= 0 && gelesen <= 0) { runden := 100; }
    runden := runden + 1;
  }
  Print("empfangen "); PrintInt(gelesen); Print(" ");
  i := 0;
  while (i < gelesen) { if (peek8(ein + i) >= 32) { PrintChar(peek8(ein + i)); } i := i + 1; }
  PrintLn("");
  var antwort: pchar := "HTTP/1.0 200 OK\r\nContent-Length: 12\r\n\r\nLyx TLS 1.3\n"c;
  TlsSchreibe(c, antwort as int64, StrLen(antwort));
  var m2: int64 := TlsAusgabe(c, puf, 32768);
  TCPConnWrite(conn, puf as pchar, m2);
  TlsSchliessen(c);
  m2 := TlsAusgabe(c, puf, 32768);
  if (m2 > 0) { TCPConnWrite(conn, puf as pchar, m2); }
  PrintLn("fertig");
  TCPConnClose(conn);
  TCPListenerClose(l);
  return 0;
}
LYXEOF
cat > "$TMP/cli.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.net.socket;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var mtls: int64 := GetArgC() - 2;
  var dCa: int64 := alloc(4096);  var lCa := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dCli: int64 := alloc(4096); var lCli := ladeDer(StrConcat(basis, "/tlscli.pem"c), "CERTIFICATE"c, dCli);
  var dCk: int64 := alloc(4096);  var lCk := ladeDer(StrConcat(basis, "/tlsclikey.pem"c), "PRIVATE KEY"c, dCk);
  var trust: int64 := alloc(16); poke64(trust, dCa); poke64(trust + 8, lCa);
  var kette: int64 := alloc(16); poke64(kette, dCli); poke64(kette + 8, lCli);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var host: pchar := "nexus.example"c;
  var alpn: pchar := "http/1.1"c;
  TlsConfigNeu(cfg, 2);
  TlsConfigTrust(cfg, trust, 1);
  TlsConfigHost(cfg, host as int64, StrLen(host));
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigZeit(cfg, 1800000000);
  if (mtls > 0) { TlsConfigKette(cfg, kette, 1, dCk, lCk); }

  var conn: TCPConn := TCPConnect(0x7F000001, port);
  var c: int64 := TlsNeu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!TlsFertig(c) && runden < 200) {
    var rc: int64 := TlsSchritt(c);
    if (rc < 0) { Print("FEHLER "); PrintInt(rc); Print(" "); PrintLn(TlsFehlerText(rc)); return 1; }
    var m: int64 := TlsAusgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!TlsFertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 1; }
      TlsFuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!TlsFertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 1; }
  Print("handschlag-fertig suite "); PrintInt(TlsSuite(c)); PrintLn("");
  var pz: int64 := TlsPeerZertifikat(c);
  Print("serverzertifikat-geprueft ");
  if (pz != 0) { PrintInt(1); } else { PrintInt(0); }
  PrintLn("");

  var frage: pchar := "ping aus Lyx\n"c;
  TlsSchreibe(c, frage as int64, StrLen(frage));
  var m2: int64 := TlsAusgabe(c, puf, 32768);
  TCPConnWrite(conn, puf as pchar, m2);

  var ein: int64 := alloc(4096);
  var gelesen: int64 := 0;
  runden := 0;
  while (gelesen <= 0 && runden < 50) {
    var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
    if (n2 > 0) { TlsFuetter(c, puf, n2); }
    gelesen := TlsLese(c, ein, 4096);
    if (n2 <= 0) { runden := 50; }
    runden := runden + 1;
  }
  Print("antwort "); PrintInt(gelesen); Print(" ");
  var i: int64 := 0;
  while (i < gelesen) { if (peek8(ein + i) >= 32) { PrintChar(peek8(ein + i)); } i := i + 1; }
  PrintLn("");
  TlsSchliessen(c);
  m2 := TlsAusgabe(c, puf, 32768);
  if (m2 > 0) { TCPConnWrite(conn, puf as pchar, m2); }
  TCPConnClose(conn);
  return 0;
}
LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/srv.lyx" "$TMP/cli.lyx"

for prog in srv cli; do
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/$prog.lyx" -o "$TMP/$prog" ) >"$TMP/log_$prog" 2>&1; then
    echo "FAIL $prog uebersetzt nicht: $(grep -m1 -i error "$TMP/log_$prog")"; exit 1
  fi
  [ -x "$TMP/$prog" ] || { echo "FAIL $prog: kein Erzeugnis (#1682)"; exit 1; }
done

PASS=0; FAIL=0
pruefe() {  # name, bedingung-erfuellt(0/1)
  if [ "$2" = 1 ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1"; FAIL=$((FAIL+1)); fi
}

PORT=18560
freierPort() {
  while ss -ltn 2>/dev/null | grep -q ":$PORT "; do PORT=$((PORT+1)); done
  echo "$PORT"
}

# --- 1. unser Server gegen s_client, drei Suites ---
for suite in TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256; do
  p="$(freierPort)"; PORT=$((PORT+1))
  ( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" > "$TMP/srv_$suite.txt" 2>&1 ) &
  sleep 1.5
  # -ign_eof, sonst beendet s_client die Verbindung beim EOF auf stdin, bevor
  # unsere Antwort da ist — die Pruefung auf die Nutzdaten waere dann immer rot.
  ( printf 'GET / HTTP/1.0\r\n\r\n'; sleep 3 ) | timeout 25 openssl s_client \
     -connect "127.0.0.1:$p" -ign_eof \
     -servername nexus.example -CAfile "$TMP/certs/tlsca.pem" -alpn h2,http/1.1 \
     -ciphersuites "$suite" -tls1_3 > "$TMP/os_$suite.txt" 2>&1
  wait
  ok=1
  grep -q "Cipher is $suite" "$TMP/os_$suite.txt" || ok=0
  grep -q "Verify return code: 0 (ok)" "$TMP/os_$suite.txt" || ok=0
  grep -q "Lyx TLS 1.3" "$TMP/os_$suite.txt" || ok=0
  grep -q "empfangen 18 GET / HTTP/1.0" "$TMP/srv_$suite.txt" || ok=0
  pruefe "Server gegen s_client, $suite" "$ok"
  if [ "$ok" != 1 ]; then
    echo "  openssl: $(grep -E 'Cipher is|Verify return code' "$TMP/os_$suite.txt" | tr '\n' ' ')"
    echo "  lyx:     $(tr '\n' ' ' < "$TMP/srv_$suite.txt")"
  fi
done

# --- 2. unser Server mit verlangtem Client-Zertifikat ---
p="$(freierPort)"; PORT=$((PORT+1))
( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" mtls > "$TMP/srv_mtls.txt" 2>&1 ) &
sleep 1.5
printf 'GET / HTTP/1.0\r\n\r\n' | timeout 25 openssl s_client -connect "127.0.0.1:$p" \
   -servername nexus.example -CAfile "$TMP/certs/tlsca.pem" \
   -cert "$TMP/certs/tlscli.pem" -key "$TMP/certs/tlsclikey.pem" -tls1_3 \
   > "$TMP/os_mtls.txt" 2>&1
wait
ok=1
grep -q "client-zertifikat-geprueft 1" "$TMP/srv_mtls.txt" || ok=0
grep -q "Verify return code: 0 (ok)" "$TMP/os_mtls.txt" || ok=0
pruefe "Server verlangt Client-Zertifikat: mit Zertifikat Erfolg" "$ok"

p="$(freierPort)"; PORT=$((PORT+1))
( ulimit -v 4000000 -c 0; "$TMP/srv" "$p" mtls > "$TMP/srv_mtls2.txt" 2>&1 ) &
sleep 1.5
printf 'x' | timeout 25 openssl s_client -connect "127.0.0.1:$p" \
   -CAfile "$TMP/certs/tlsca.pem" -tls1_3 > "$TMP/os_mtls2.txt" 2>&1
wait
ok=0
grep -q "FEHLER -6" "$TMP/srv_mtls2.txt" && ok=1
pruefe "Server verlangt Client-Zertifikat: ohne eines abgewiesen (-6)" "$ok"

# --- 3. unser Client gegen s_server ---
for modus in ohne mit; do
  p="$(freierPort)"; PORT=$((PORT+1))
  rm -f "$TMP/fifo_$modus"; mkfifo "$TMP/fifo_$modus"
  if [ "$modus" = mit ]; then
    openssl s_server -accept "$p" -cert "$TMP/certs/tlssrv.pem" -key "$TMP/certs/tlssrvkey.pem" \
      -CAfile "$TMP/certs/tlsca.pem" -Verify 2 -tls1_3 < "$TMP/fifo_$modus" \
      > "$TMP/os_srv_$modus.txt" 2>&1 &
  else
    openssl s_server -accept "$p" -cert "$TMP/certs/tlssrv.pem" -key "$TMP/certs/tlssrvkey.pem" \
      -tls1_3 -alpn http/1.1 < "$TMP/fifo_$modus" > "$TMP/os_srv_$modus.txt" 2>&1 &
  fi
  ( printf 'pong aus openssl\n'; sleep 8 ) > "$TMP/fifo_$modus" &
  sleep 1.5
  if [ "$modus" = mit ]; then
    ( ulimit -v 4000000 -c 0; timeout 25 "$TMP/cli" "$p" mtls ) > "$TMP/cli_$modus.txt" 2>&1
  else
    ( ulimit -v 4000000 -c 0; timeout 25 "$TMP/cli" "$p" ) > "$TMP/cli_$modus.txt" 2>&1
  fi
  pkill -f "s_server -accept $p" 2>/dev/null
  ok=1
  grep -q "handschlag-fertig suite 4865" "$TMP/cli_$modus.txt" || ok=0
  grep -q "serverzertifikat-geprueft 1" "$TMP/cli_$modus.txt" || ok=0
  grep -q "antwort 17 pong aus openssl" "$TMP/cli_$modus.txt" || ok=0
  if [ "$modus" = mit ]; then
    grep -q "CN=client.example" "$TMP/os_srv_$modus.txt" || ok=0
  fi
  pruefe "Client gegen s_server, $modus Client-Zertifikat" "$ok"
  if [ "$ok" != 1 ]; then echo "  lyx: $(tr '\n' ' ' < "$TMP/cli_$modus.txt")"; fi
done

echo "--- $PASS PASS, $FAIL FAIL"
if [ "$FAIL" != 0 ]; then exit 1; fi
echo "ALL PASS"
exit 0
