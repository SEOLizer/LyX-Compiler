#!/usr/bin/env bash
# tests/tls13_kette_gegenprobe_2647_test.sh — prueft ein TLS-CLIENT die Kette
# wirklich? (#2647)
#
# BEFUND. Gemeldet wurde ein Client, der den Handschlag zu einem echten Server
# zu Ende bringt, OHNE die Kette zu pruefen: leere Vertrauensliste und falscher
# Pruefname wurden akzeptiert, auch mit ausdruecklichem
# `TlsConfigKettePruefen(cfg, 1)`. Die Verbindung ist dann verschluesselt, aber
# nicht authentifiziert.
#
# WARUM DIESER TEST FEHLTE, obwohl es Kettentests gibt: die vorhandenen pruefen
# `X509PruefeKette` ISOLIERT, und die weist eine leere Liste korrekt ab. Was
# fehlte, ist die Frage, ob der HANDSCHLAG sie ruft. Ein Positivtest kann das
# nicht beantworten -- eine Pruefung, die immer "ja" sagt, laesst den guten
# Fall genauso durch (#1829: die Invariante war erfuellt, das Ergebnis falsch).
#
# VIER FAELLE, und der erste und der letzte sind die Gegenproben:
#
#   voll      vollstaendige Liste, richtiger Name  -> Handschlag MUSS gelingen
#   leer      Liste mit 0 Einträgen                -> MUSS scheitern
#   falsch    richtige Liste, falscher Pruefname   -> MUSS scheitern
#   ohne      Pruefung ausdruecklich AUS, Liste 0  -> MUSS gelingen
#
# Ohne "voll" waere der Test auch von einem Client erfuellt, der ueberhaupt
# nichts zustandebringt. Ohne "ohne" waere er auch von einer Fassung erfuellt,
# die jede leere Liste abweist, selbst wenn der Aufrufer die Pruefung bewusst
# abgeschaltet hat -- das waere eine Verschaerfung ohne Befund.
#
# GEBAUT WIRD ZWEIMAL: aus der QUELLE und gegen den PAKETBAUM (.lyu mit
# Objektcode). Der Melder baute gegen die installierten .lyu, und ein Test, der
# nur den Quellweg kennt, koennte einen Defekt im Vorkompilat nicht sehen.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -f "s_server -accept 189[0-9][0-9]" 2>/dev/null' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

command -v openssl >/dev/null 2>&1 || { echo "SKIP openssl fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
command -v ss >/dev/null 2>&1      || { echo "SKIP ss fehlt (Portsuche)"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

# --- Zertifikate zur Laufzeit: CA plus Blatt auf nexus.example -------------
mkdir -p "$TMP/c"
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/c/cakey.pem" 2>/dev/null
openssl req -x509 -new -key "$TMP/c/cakey.pem" -sha256 -days 3650 \
  -subj "/CN=aurum-test-ca-2647" -out "$TMP/c/ca.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/c/srvkey.pem" 2>/dev/null
openssl req -new -key "$TMP/c/srvkey.pem" -subj "/CN=nexus.example" -out "$TMP/c/srv.csr" 2>/dev/null
openssl x509 -req -in "$TMP/c/srv.csr" -CA "$TMP/c/ca.pem" -CAkey "$TMP/c/cakey.pem" \
  -sha256 -days 3650 -extfile <(printf 'subjectAltName=DNS:nexus.example\nextendedKeyUsage=serverAuth\n') \
  -out "$TMP/c/srv.pem" 2>/dev/null
for f in ca.pem srv.pem srvkey.pem; do
  [ -s "$TMP/c/$f" ] || { echo "SKIP: openssl erzeugt $f nicht"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
done

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
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var modus: pchar := GetArg(2) as pchar;        // voll | leer | falsch | ohne

  var dCa: int64 := alloc(8192);
  var lCa: int64 := ladeDer("CADERMARKER"c, "CERTIFICATE"c, dCa);
  if (lCa <= 0) { PrintLn("CA-FEHLT"c); return 1; }
  var trust: int64 := alloc(16); poke64(trust, dCa); poke64(trust + 8, lCa);

  var wn: int64 := 1;
  var pruefen: int64 := 1;
  var host: pchar := "nexus.example"c;
  if (StrCmp(modus, "leer"c) == 0)   { wn := 0; }
  if (StrCmp(modus, "falsch"c) == 0) { host := "ganz-sicher-nicht-dieser-host.invalid"c; }
  if (StrCmp(modus, "ohne"c) == 0)   { wn := 0; pruefen := 0; }

  var cfg: int64 := alloc(TlsConfigGroesse());
  TlsConfigNeu(cfg, 2);
  TlsConfigKettePruefen(cfg, pruefen);
  TlsConfigTrust(cfg, trust, wn);
  TlsConfigHost(cfg, host as int64, StrLen(host));
  TlsConfigZeit(cfg, 1800000000);

  var conn: TCPConn := TCPConnect(0x7F000001, port);
  var c: int64 := TlsNeu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!TlsFertig(c) && runden < 200) {
    var rc: int64 := TlsSchritt(c);
    if (rc < 0) { Print("ABBRUCH "c); PrintInt(rc); PrintLn(""c); return 1; }
    var m: int64 := TlsAusgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!TlsFertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"c); return 1; }
      TlsFuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!TlsFertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"c); return 1; }
  Print("HANDSCHLAG-FERTIG suite "c); PrintInt(TlsSuite(c)); PrintLn(""c);
  return 0;
}
LYXEOF
sed -i "s|CADERMARKER|$TMP/c/ca.pem|" "$TMP/cli.lyx"

PORT=18980
freierPort() { while ss -ltn 2>/dev/null | grep -q ":$PORT "; do PORT=$((PORT+1)); done; echo "$PORT"; PORT=$((PORT+1)); }

# Ein Fall: Server starten, Client fahren, Ausgabe zurueckgeben.
fahre() { # bin, modus -> Ausgabe auf stdout, rc in $RC
  local bin="$1" modus="$2" p
  p="$(freierPort)"
  rm -f "$TMP/fifo"; mkfifo "$TMP/fifo"
  openssl s_server -accept "$p" -cert "$TMP/c/srv.pem" -key "$TMP/c/srvkey.pem" \
     -tls1_3 -quiet < "$TMP/fifo" > "$TMP/srv.txt" 2>&1 &
  ( printf 'pong\n'; sleep 6 ) > "$TMP/fifo" &
  local i; for i in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ":$p " && break; sleep 0.25; done
  ( ulimit -v 4000000 -c 0; timeout 25 "$bin" "$p" "$modus" ) > "$TMP/out.txt" 2>&1
  RC=$?
  pkill -f "s_server -accept $p" 2>/dev/null
  rm -f "$TMP/fifo"
  tr '\n' ' ' < "$TMP/out.txt"
}

PAKET="$ROOT/lyx-compiler/usr/include/lyx/units/x86_64"
for weg in quelle paket; do
  if [ "$weg" = quelle ]; then
    ( cd "$ROOT" && "$LYXC" "$TMP/cli.lyx" --std-path="$ROOT" -o "$TMP/cli_$weg" ) >"$TMP/bau.log" 2>&1 || {
      pr fail "$weg: Client uebersetzt nicht: $(grep -m1 -iE 'error|fehler' "$TMP/bau.log")"; continue; }
  else
    [ -f "$PAKET/std/crypto/x509.lyu" ] || { echo "    (SKIP paket: $PAKET ohne crypto/)"; continue; }
    ( cd "$TMP" && "$LYXC" "$TMP/cli.lyx" -I "$PAKET" -o "$TMP/cli_$weg" ) >"$TMP/bau.log" 2>&1 || {
      pr fail "$weg: Client uebersetzt nicht: $(grep -m1 -iE 'error|fehler' "$TMP/bau.log")"; continue; }
  fi
  echo "--- Weg: $weg ---"

  AUS="$(fahre "$TMP/cli_$weg" voll)"
  case "$AUS" in
    *HANDSCHLAG-FERTIG*) pr ok "$weg/voll: Handschlag gelingt (sonst belegt der Rest nichts)" ;;
    *) pr fail "$weg/voll: Handschlag gelingt NICHT: $AUS" ;;
  esac

  AUS="$(fahre "$TMP/cli_$weg" leer)"
  case "$AUS" in
    *HANDSCHLAG-FERTIG*) pr fail "$weg/leer: Handschlag mit LEERER Vertrauensliste gelungen (#2647): $AUS" ;;
    *ABBRUCH*)           pr ok "$weg/leer: leere Vertrauensliste bricht ab ($AUS)" ;;
    *)                   pr fail "$weg/leer: weder fertig noch Abbruch: $AUS" ;;
  esac

  AUS="$(fahre "$TMP/cli_$weg" falsch)"
  case "$AUS" in
    *HANDSCHLAG-FERTIG*) pr fail "$weg/falsch: Handschlag mit FALSCHEM Pruefnamen gelungen (#2647): $AUS" ;;
    *ABBRUCH*)           pr ok "$weg/falsch: falscher Pruefname bricht ab ($AUS)" ;;
    *)                   pr fail "$weg/falsch: weder fertig noch Abbruch: $AUS" ;;
  esac

  AUS="$(fahre "$TMP/cli_$weg" ohne)"
  case "$AUS" in
    *HANDSCHLAG-FERTIG*) pr ok "$weg/ohne: abgeschaltete Pruefung bleibt erlaubt" ;;
    *) pr fail "$weg/ohne: abgeschaltete Pruefung wird abgewiesen -- Verschaerfung ohne Befund: $AUS" ;;
  esac
done

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
