#!/usr/bin/env bash
# tests/tls13_hrr_gruppen_test.sh — #2096 Stufe-1-Reste: secp256r1 als
# Schluesseltausch, HelloRetryRequest, KeyUpdate, mehrere Ketten nach SNI
# samt Hot-Reload, Widerruf-Hook.
#
# Gemessen wird die WIRKUNG, nicht das Vorhandensein:
#   - secp256r1: beide Seiten melden Gruppe 23 (0x0017) und tragen Daten
#   - HRR: der Server kann nur secp256r1, der Client bietet x25519 zuerst an.
#     Der Handschlag kommt trotzdem zustande UND endet in Gruppe 23; dass es
#     wirklich ein HRR war, zeigt die Zahl der ClientHellos (zwei).
#   - KeyUpdate: nach dem Wechsel tragen die Daten weiter. Ohne Verarbeitung
#     der Nachricht waere das Ergebnis -5 (Tag falsch) — darum ist dieser
#     Test vor dem Fix rot.
#   - SNI: der passende Eintrag wird genommen; ein Austausch im Betrieb wirkt
#     beim naechsten Handschlag (Hot-Reload), mit derselben Konfiguration.
#   - fehlt der Standardeintrag und der Client schickt kein SNI: -11
#   - Widerruf-Hook: liefert er != 0, endet die Verbindung mit -15; liefert er
#     0, kommt sie zustande.
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

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 4096);
}

// Widerruf-Hooks: einer lehnt jedes Zertifikat ab, einer nimmt jedes an.
// Beide lesen den Satz wirklich, damit der Hook nicht nur ein Rueckgabewert
// ist: ohne Serienummer gaebe es auch kein Urteil.
fn hookAblehnen(satz: int64): int64 {
  if (X509SerienNrLen(satz) <= 0) { return 9; }
  return 1;
}

fn hookAnnehmen(satz: int64): int64 {
  if (X509SerienNrLen(satz) <= 0) { return 9; }
  return 0;
}

// Ein Handschlag zwischen zwei Zustaenden im selben Programm. `chZaehler`
// nimmt die Zahl der ClientHellos auf (Typbyte 1 im ersten Klartextrecord) —
// damit ist ein HelloRetryRequest nachweisbar und nicht nur vermutet.
fn handschlag(sv: int64, cl: int64, chZaehler: int64): int64 {
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  if (chZaehler != 0) { poke64(chZaehler, 0); }
  while (runden < 40) {
    var rcC: int64 := TlsSchritt(cl);
    if (rcC < 0) { free(puf, 32768); return rcC; }
    var n: int64 := TlsAusgabe(cl, puf, 32768);
    if (n > 0) {
      // Unverschluesselter Handschlagrecord mit ClientHello?
      if (chZaehler != 0 && n > 5) {
        if ((peek8(puf) & 255) == 22 && (peek8(puf + 5) & 255) == 1) {
          poke64(chZaehler, peek64(chZaehler) + 1);
        }
      }
      TlsFuetter(sv, puf, n);
    }
    var rcS: int64 := TlsSchritt(sv);
    if (rcS < 0) { free(puf, 32768); return rcS; }
    var m: int64 := TlsAusgabe(sv, puf, 32768);
    if (m > 0) { TlsFuetter(cl, puf, m); }
    if (TlsFertig(cl) && TlsFertig(sv)) { free(puf, 32768); return 0; }
    if (n == 0 && m == 0) { free(puf, 32768); return -99; }
    runden := runden + 1;
  }
  free(puf, 32768);
  return -98;
}

// Nutzlast in beide Richtungen: 1 wenn beide Seiten das Richtige lesen.
fn traegtDaten(sv: int64, cl: int64): int64 {
  var puf: int64 := alloc(32768);
  var ein: int64 := alloc(4096);
  var hin: pchar := "ping"c;
  var her: pchar := "pong"c;
  var ok: int64 := 1;
  if (TlsSchreibe(cl, hin as int64, 4) != 4) { ok := 0; }
  var n: int64 := TlsAusgabe(cl, puf, 32768);
  TlsFuetter(sv, puf, n);
  var g: int64 := TlsLese(sv, ein, 4096);
  if (g != 4) { ok := 0; }
  else {
    if (peek8(ein) != 112 || peek8(ein + 3) != 103) { ok := 0; }
  }
  if (TlsSchreibe(sv, her as int64, 4) != 4) { ok := 0; }
  n := TlsAusgabe(sv, puf, 32768);
  TlsFuetter(cl, puf, n);
  g := TlsLese(cl, ein, 4096);
  if (g != 4) { ok := 0; }
  free(puf, 32768); free(ein, 4096);
  return ok;
}

fn main(): int64 {
  var basis: pchar := "CERTDIRMARKER"c;
  var dCa: int64 := alloc(4096);  var lCa: int64 := ladeDer(StrConcat(basis, "/tlsca.pem"c), "CERTIFICATE"c, dCa);
  var dSrv: int64 := alloc(4096); var lSrv: int64 := ladeDer(StrConcat(basis, "/tlssrv.pem"c), "CERTIFICATE"c, dSrv);
  var dCli: int64 := alloc(4096); var lCli: int64 := ladeDer(StrConcat(basis, "/tlscli.pem"c), "CERTIFICATE"c, dCli);
  var dSk: int64 := alloc(4096);  var lSk: int64 := ladeDer(StrConcat(basis, "/tlssrvkey.pem"c), "PRIVATE KEY"c, dSk);
  var dCk: int64 := alloc(4096);  var lCk: int64 := ladeDer(StrConcat(basis, "/tlsclikey.pem"c), "PRIVATE KEY"c, dCk);
  if (lCa <= 0 || lSrv <= 0 || lSk <= 0 || lCli <= 0 || lCk <= 0) { PrintLn("LADEFEHLER"); return 1; }

  var kette: int64 := alloc(16);  poke64(kette, dSrv);  poke64(kette + 8, lSrv);
  var kKette: int64 := alloc(16); poke64(kKette, dCli); poke64(kKette + 8, lCli);
  var trust: int64 := alloc(16);  poke64(trust, dCa);   poke64(trust + 8, lCa);

  var host: pchar := "nexus.example"c;
  var cfgS: int64 := alloc(TlsConfigGroesse());
  var cfgC: int64 := alloc(TlsConfigGroesse());

  // ---------------------------------------------------------------- Fall 1
  // secp256r1 auf beiden Seiten
  TlsConfigNeu(cfgS, 1);
  TlsConfigKette(cfgS, kette, 1, dSk, lSk);
  TlsConfigZeit(cfgS, 1800000000);
  TlsConfigGruppen(cfgS, TlsGruppeSecp256r1());
  TlsConfigNeu(cfgC, 2);
  TlsConfigTrust(cfgC, trust, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigZeit(cfgC, 1800000000);
  TlsConfigGruppen(cfgC, TlsGruppeSecp256r1());

  var sv: int64 := TlsNeu(cfgS);
  var cl: int64 := TlsNeu(cfgC);
  var zaehler: int64 := alloc(8);
  Print("p256-handschlag "); PrintInt(handschlag(sv, cl, zaehler)); PrintLn("");
  Print("p256-gruppe "); PrintInt(TlsGruppe(cl)); Print(" "); PrintInt(TlsGruppe(sv)); PrintLn("");
  Print("p256-hellos "); PrintInt(peek64(zaehler)); PrintLn("");
  Print("p256-daten "); PrintInt(traegtDaten(sv, cl)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // ---------------------------------------------------------------- Fall 2
  // x25519 auf beiden Seiten (Gegenprobe: der Bestandsweg bleibt heil)
  TlsConfigGruppen(cfgS, TlsGruppeX25519());
  TlsConfigGruppen(cfgC, TlsGruppeX25519());
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("x25519-handschlag "); PrintInt(handschlag(sv, cl, zaehler)); PrintLn("");
  Print("x25519-gruppe "); PrintInt(TlsGruppe(cl)); PrintLn("");
  Print("x25519-hellos "); PrintInt(peek64(zaehler)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // ---------------------------------------------------------------- Fall 3
  // HelloRetryRequest: der Client bietet x25519 zuerst an, der Server kann
  // nur secp256r1.
  TlsConfigGruppen(cfgS, TlsGruppeSecp256r1());
  TlsConfigGruppen(cfgC, 0);                       // 0 = beide, x25519 zuerst
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("hrr-handschlag "); PrintInt(handschlag(sv, cl, zaehler)); PrintLn("");
  Print("hrr-gruppe "); PrintInt(TlsGruppe(cl)); Print(" "); PrintInt(TlsGruppe(sv)); PrintLn("");
  Print("hrr-hellos "); PrintInt(peek64(zaehler)); PrintLn("");
  Print("hrr-daten "); PrintInt(traegtDaten(sv, cl)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // ---------------------------------------------------------------- Fall 4
  // Keine gemeinsame Gruppe: -4, kein stiller Rueckfall
  TlsConfigGruppen(cfgS, TlsGruppeSecp256r1());
  TlsConfigGruppen(cfgC, TlsGruppeX25519());
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("keine-gruppe "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // ---------------------------------------------------------------- Fall 5
  // KeyUpdate in beide Richtungen
  TlsConfigGruppen(cfgS, 0); TlsConfigGruppen(cfgC, 0);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("ku-handschlag "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  var puf: int64 := alloc(32768);
  var ein: int64 := alloc(4096);
  // Client erneuert seinen Schreibschluessel und verlangt dasselbe vom Server
  Print("ku-senden "); PrintInt(TlsKeyUpdateSenden(cl, true)); PrintLn("");
  var n2: int64 := TlsAusgabe(cl, puf, 32768);
  TlsFuetter(sv, puf, n2);
  // Der Server verarbeitet das KeyUpdate beim Lesen (noch keine Nutzdaten)
  Print("ku-server-liest-leer "); PrintInt(TlsLese(sv, ein, 4096)); PrintLn("");
  n2 := TlsAusgabe(sv, puf, 32768);
  Print("ku-server-antwortet "); PrintInt(n2 > 0); PrintLn("");
  TlsFuetter(cl, puf, n2);
  Print("ku-client-liest-leer "); PrintInt(TlsLese(cl, ein, 4096)); PrintLn("");
  Print("ku-daten-danach "); PrintInt(traegtDaten(sv, cl)); PrintLn("");
  // noch ein Wechsel, diesmal vom Server und ohne Anforderung
  Print("ku2-senden "); PrintInt(TlsKeyUpdateSenden(sv, false)); PrintLn("");
  n2 := TlsAusgabe(sv, puf, 32768);
  TlsFuetter(cl, puf, n2);
  TlsLese(cl, ein, 4096);
  Print("ku2-daten-danach "); PrintInt(traegtDaten(sv, cl)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // ---------------------------------------------------------------- Fall 6
  // Mehrere Ketten nach SNI, dann Hot-Reload desselben Eintrags.
  // Eintrag 0 traegt zunaechst die FALSCHE Kette (client.example) — der
  // Client lehnt sie ab (-6). Danach wird derselbe Eintrag im Betrieb auf
  // die richtige Kette umgestellt, ohne neue Konfiguration.
  var tab: int64 := alloc(3 * TlsKetteEintragGroesse());
  var nexus: pchar := "nexus.example"c;
  var joker: pchar := "*.nexus.example"c;
  TlsKetteEintrag(tab, 0, nexus as int64, StrLen(nexus), kKette, 1, dCk, lCk);
  TlsKetteEintrag(tab, 1, joker as int64, StrLen(joker), kette, 1, dSk, lSk);
  TlsKetteEintrag(tab, 2, 0, 0, kette, 1, dSk, lSk);
  TlsConfigKetten(cfgS, tab, 3);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("sni-falsche-kette "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  TlsKetteEintrag(tab, 0, nexus as int64, StrLen(nexus), kette, 1, dSk, lSk);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("sni-hot-reload "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  Print("sni-gesehen "); PrintInt(TlsSniLen(sv)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // Jokereintrag: Client verlangt a.nexus.example. Das Zertifikat passt
  // namentlich nicht (-6), aber der Eintrag wurde gewaehlt — belegt durch
  // das SNI, das der Server gesehen hat.
  var sub: pchar := "a.nexus.example"c;
  TlsConfigHost(cfgC, sub as int64, StrLen(sub));
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("sni-joker "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  Print("sni-joker-name "); PrintInt(TlsSniLen(sv)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);
  TlsConfigHost(cfgC, host as int64, StrLen(host));

  // Kein SNI vom Client und kein Standardeintrag: -11 statt irgendein
  // fremdes Zertifikat.
  TlsConfigKetten(cfgS, tab, 1);
  TlsConfigHost(cfgC, 0, 0);
  TlsConfigKettePruefen(cfgC, 0);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("sni-ohne-standard "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);
  TlsConfigKettePruefen(cfgC, 1);
  TlsConfigHost(cfgC, host as int64, StrLen(host));
  TlsConfigKetten(cfgS, 0, 0);

  // ---------------------------------------------------------------- Fall 7
  // Widerruf-Hook, beide Richtungen des Urteils
  TlsConfigWiderrufHook(cfgC, hookAblehnen as int64);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("widerruf-abgelehnt "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  TlsConfigWiderrufHook(cfgC, hookAnnehmen as int64);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("widerruf-angenommen "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  // Server-Seite: der Hook urteilt ueber das Client-Zertifikat (mTLS)
  TlsConfigWiderrufHook(cfgC, 0);
  TlsConfigClientAuth(cfgS, 2);
  TlsConfigTrust(cfgS, trust, 1);
  TlsConfigKette(cfgC, kKette, 1, dCk, lCk);
  TlsConfigWiderrufHook(cfgS, hookAblehnen as int64);
  sv := TlsNeu(cfgS); cl := TlsNeu(cfgC);
  Print("widerruf-mtls-abgelehnt "); PrintInt(handschlag(sv, cl, 0)); PrintLn("");
  TlsFrei(sv); TlsFrei(cl);

  free(puf, 32768); free(ein, 4096);
  return 0;
}
LYXEOF

sed -i "s#CERTDIRMARKER#$TMP/certs#" "$TMP/s.lyx"

cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Testprogramm laesst sich nicht uebersetzen"
  tail -20 "$TMP/build.log"
  exit 1
fi

( ulimit -v 4000000; "$TMP/s" > "$TMP/out.txt" 2>&1 )
rc=$?
if [ "$rc" -ge 128 ]; then
  echo "FAIL: Testprogramm abgebrochen (rc=$rc)"
  cat "$TMP/out.txt"
  exit 1
fi
cat "$TMP/out.txt"

fails=0
pruefe() {
  local name="$1" erwartet="$2"
  local ist
  ist="$(grep -m1 "^$name " "$TMP/out.txt" | cut -d' ' -f2-)"
  if [ "$ist" != "$erwartet" ]; then
    echo "FAIL: $name = '$ist', erwartet '$erwartet'"
    fails=$((fails + 1))
  fi
}

# secp256r1 (Gruppe 0x0017 = 23), ein ClientHello, Daten tragen
pruefe p256-handschlag 0
pruefe p256-gruppe "23 23"
pruefe p256-hellos 1
pruefe p256-daten 1

# x25519 (Gruppe 0x001d = 29) unveraendert
pruefe x25519-handschlag 0
pruefe x25519-gruppe 29
pruefe x25519-hellos 1

# HelloRetryRequest: zwei ClientHellos, Ergebnis secp256r1
pruefe hrr-handschlag 0
pruefe hrr-gruppe "23 23"
pruefe hrr-hellos 2
pruefe hrr-daten 1

# keine gemeinsame Gruppe
pruefe keine-gruppe -4

# KeyUpdate
pruefe ku-handschlag 0
pruefe ku-senden 0
pruefe ku-server-liest-leer 0
pruefe ku-server-antwortet 1
pruefe ku-client-liest-leer 0
pruefe ku-daten-danach 1
pruefe ku2-senden 0
pruefe ku2-daten-danach 1

# SNI und Hot-Reload
pruefe sni-falsche-kette -6
pruefe sni-hot-reload 0
pruefe sni-gesehen 13
pruefe sni-joker -6
pruefe sni-joker-name 15
pruefe sni-ohne-standard -11

# Widerruf-Hook
pruefe widerruf-abgelehnt -15
pruefe widerruf-angenommen 0
pruefe widerruf-mtls-abgelehnt -15

if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "$fails FAIL"
exit 1
