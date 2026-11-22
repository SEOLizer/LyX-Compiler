#!/usr/bin/env bash
# tests/tls13_rss_2096_test.sh — #2096 Abnahmekriterium 9: "10 000
# Handschlaege hintereinander ohne Wachstum des RSS".
#
# Gemessen wird im PROGRAMM, nicht am Prozessende: `/usr/bin/time -f %M`
# nennt nur das Maximum und kann ein Leck nicht von einem einmaligen
# Anfassen unterscheiden. Dieses Programm liest alle 1000 Handschlaege
# `/proc/self/statm` und gibt die Seitenzahl aus; geurteilt wird auf die
# STEIGUNG zwischen dem ersten Messpunkt (nach 1000, Arena warm) und dem
# letzten.
#
# Ein Test auf "RSS bleibt unter X" waere eine Invariante und damit blind
# fuer ein langsames Leck (#1829). Deshalb der Vergleich zweier Messpunkte
# desselben Laufs.
#
# Je Runde werden BEIDE Zustaende mit TlsNeu angelegt und mit TlsFrei
# freigegeben; ein vollstaendiger Handschlag laeuft dazwischen. Damit misst
# der Test genau die Frage des Kriteriums: haelt die Bibliothek nach einem
# Handschlag etwas fest?
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
cat > "$TMP/certs/tlssrvkey_sec1.pem" <<'PEMEOF'
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEILz0u3TzvByU/nZzJld31M3kI3LS5aeZUDxSbRwJ7tzroAoGCCqGSM49
AwEHoUQDQgAEdOxbKlmgcLxj6O8MeBZe6YpqzlgNY7JpiFZAaOOohGmg/xacbmaH
f5CwcxQhoiOLFfrcTFsPdslblkpwxYcguw==
-----END EC PRIVATE KEY-----
PEMEOF

cat > "$TMP/r.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.crypto.pkey;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

fn roh(b: int64, n: int64): void {
  var i: int64 := 0;
  while (i < n) { PrintChar(peek8(b + i)); i := i + 1; }
  PrintLn("");
}

// Ein Handschlag zwischen zwei Zustaenden im selben Programm.
// Liefert 0 bei Erfolg, sonst den Fehlercode der Seite, die scheitert.
fn handschlag(sv: int64, cl: int64, kipp: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) { TlsFuetter(sv, puf, n); }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) {
      // Ein Byte im letzten Record des Serverflugs kippen: das trifft das
      // AEAD-Tag des Finished, der Client muss die Entschluesselung ablehnen.
      if (kipp == 1) { poke8(puf + m - 1, peek8(puf + m - 1) ^ 1); }
      TlsFuetter(cl, puf, m);
    }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return -98;
}

fn rssSeiten(): int64 {
  // /proc/self/statm: Feld 2 ist die Zahl der residenten Seiten.
  var puf: int64 := alloc(256);
  var n: int64 := ReadFile("/proc/self/statm"c, puf as pchar, 255);
  if (n <= 0) { free(puf, 256); return 0 - 1; }
  var i: int64 := 0;
  while (i < n && peek8(puf + i) != 32) { i := i + 1; }
  i := i + 1;
  var wert: int64 := 0;
  while (i < n && peek8(puf + i) >= 48 && peek8(puf + i) <= 57) {
    wert := wert * 10 + (peek8(puf + i) - 48);
    i := i + 1;
  }
  free(puf, 256);
  return wert;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096); var lSrv := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dSk: int64 := alloc(4096);  var lSk := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0) { PrintLn("LADEFEHLER"); return 1; }

  var kette: int64 := alloc(16); poke64(kette, dSrv); poke64(kette + 8, lSrv);
  var trust: int64 := alloc(16); poke64(trust, dCa);  poke64(trust + 8, lCa);

  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());
  var host: pchar := "nexus.example"c;
  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS, 1800000000);
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigZeit(cfgC, 1800000000);

  var runde: int64 := 0;
  var fehler: int64 := 0;
  while (runde < RUNDENMARKER) {
    var sv: int64 := TlsNeu(cfgS);
    var cl: int64 := TlsNeu(cfgC);
    var rc: int64 := handschlag(sv, cl, 0);
    if (rc != 0) {
      Print("HANDSCHLAG-FEHLER runde "); PrintInt(runde); Print(" rc "); PrintInt(rc); PrintLn("");
      fehler := fehler + 1;
      runde := RUNDENMARKER;
    }
    TlsFrei(sv);
    TlsFrei(cl);
    runde := runde + 1;
    if (runde % INTERVALLMARKER == 0) {
      Print("rss nach "); PrintInt(runde); Print(" seiten "); PrintInt(rssSeiten()); PrintLn("");
    }
  }
  Print("fehler "); PrintInt(fehler); PrintLn("");
  Print("fertig "); PrintInt(runde); PrintLn("");
  return 0;
}

LYXEOF
sed -i "s|CERTDIRMARKER|$TMP/certs|" "$TMP/r.lyx"
RUNDEN="${RUNDEN:-10000}"
# Zehn Messpunkte, egal wie viele Runden gefahren werden. Mit festen 1000
# hatte ein kuerzerer Lauf (RUNDEN=200 beim Entwickeln) NULL Messpunkte und
# der Test urteilte auf Luft.
INTERVALL=$(( RUNDEN / 10 )); [ "$INTERVALL" -lt 1 ] && INTERVALL=1
sed -i "s|RUNDENMARKER|$RUNDEN|; s|INTERVALLMARKER|$INTERVALL|" "$TMP/r.lyx"

if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" ) >"$TMP/log" 2>&1; then
  echo "FAIL uebersetzt nicht: $(grep -m1 -i error "$TMP/log")"; exit 1
fi
[ -x "$TMP/r" ] || { echo "FAIL kein Erzeugnis (#1682)"; exit 1; }

# Erster Lauf von neuem Code gedeckelt (CLAUDE.md): ohne Deckel sucht der
# OOM-Killer sich den groessten Verbraucher im System, nicht den Schuldigen.
( ulimit -v 4000000 -c 0; /usr/bin/time -f 'MAXRSS_KB=%M LAUFZEIT=%e' "$TMP/r" ) > "$TMP/aus.txt" 2> "$TMP/zeit.txt"
RC=$?
cat "$TMP/zeit.txt"
grep -E '^rss nach |^fehler |^fertig |HANDSCHLAG-FEHLER' "$TMP/aus.txt" | sed 's/^/    /'

P=0; F=0
ok()  { echo "PASS $1"; P=$((P+1)); }
bad() { echo "FAIL $1${2:+ -- $2}"; F=$((F+1)); }

[ "$RC" = 0 ] || bad "Lauf" "Exitcode $RC"
grep -q "^fehler 0$" "$TMP/aus.txt" && ok "alle $RUNDEN Handschlaege liefen durch" \
  || bad "Handschlaege" "$(grep -m1 'HANDSCHLAG-FEHLER\|^fehler ' "$TMP/aus.txt")"

ERSTE=$(grep -m1 '^rss nach ' "$TMP/aus.txt" | awk '{print $5}')
LETZTE=$(grep '^rss nach ' "$TMP/aus.txt" | tail -1 | awk '{print $5}')
MESSPUNKTE=$(grep -c '^rss nach ' "$TMP/aus.txt")
echo "    Messpunkte: $MESSPUNKTE, RSS am ersten Messpunkt: ${ERSTE:-?} Seiten, am Ende: ${LETZTE:-?} Seiten"
if [ -n "${ERSTE:-}" ] && [ -n "${LETZTE:-}" ] && [ "$ERSTE" -gt 0 ]; then
  # Schwelle 5 %: ein Leck je Handschlag waere bei 9000 weiteren Runden um
  # Groessenordnungen darueber, eine Arena, die sich einmal einschwingt,
  # darunter. Die ZAHLEN stehen im Protokoll, damit ein Zuwachs darunter
  # nicht unsichtbar bleibt.
  GRENZE=$(( ERSTE + ERSTE / 20 ))
  if [ "$LETZTE" -le "$GRENZE" ]; then
    ok "RSS waechst ueber $RUNDEN Handschlaege nicht (${ERSTE} -> ${LETZTE} Seiten, Grenze ${GRENZE})"
  else
    bad "RSS" "${ERSTE} -> ${LETZTE} Seiten (Grenze ${GRENZE}) — Wachstum je Handschlag"
  fi
else
  bad "Messpunkte" "keine RSS-Zeilen in der Ausgabe"
fi

echo "--- $P PASS, $F FAIL"
[ "$F" -eq 0 ] || exit 1
echo "ALL PASS"
