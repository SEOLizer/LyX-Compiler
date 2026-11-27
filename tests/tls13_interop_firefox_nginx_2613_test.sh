#!/usr/bin/env bash
# tests/tls13_interop_firefox_nginx_2613_test.sh — #2613, Rest aus #2096
# Abnahmekriterium 1 und 2: die beiden Gegenstellen, die beim Nachmessen in
# PR #2612 aus UMGEBUNGSgruenden fehlten und nicht, weil sie nicht pruefbar
# waeren.
#
#   1. Firefox (NSS) gegen UNSEREN Server. Firefox prueft Zertifikate
#      ausschliesslich gegen seine eigene NSS-Datenbank (cert9.db im Profil),
#      nicht gegen den System-Store. Das ist ein dritter Pruefpfad neben
#      OpenSSL (s_client, Python, curl) und BoringSSL (Chromium).
#   2. nginx als Gegenstelle fuer UNSEREN Client. Wert ist die ANDERE
#      Serverseite als `openssl s_server`: eigene Reihenfolge der
#      Erweiterungen, eigene Ticket- und ALPN-Behandlung, HTTP/1.1 mit
#      Keep-Alive.
#
# Punkt 3 des Issues (oeffentliche Hosts) steht bewusst NICHT hier, sondern
# als abgekoppeltes Werkzeug in tools/tls_hosts_probe.lyx mit Standvermerk
# unter work/tls/hosts-stand.md: ein Test, der an einem fremden Dienst im Netz
# haengt, wird rot, wenn dort jemand ein Zertifikat tauscht, und misst dann
# nichts ueber uns.
#
# ── BEIDE SEITEN, nicht nur die gute ──────────────────────────────────────
# Ein Lauf, der nur zeigt "Firefox hat geladen", waere auch von einem Firefox
# erfuellt, der gar nicht prueft. Zu jeder Richtung gehoert deshalb die
# Gegenprobe:
#   * Firefox mit UNSERER CA im Profil: der Server muss die Anfrage sehen.
#   * Firefox mit LEEREM Profil: er darf sie NICHT sehen.
#   * unser Client gegen nginx mit UNSERER Wurzel: Antwort muss ankommen.
#   * unser Client mit FREMDER Wurzel: er muss abweisen.
#
# ── Warum die Wirkung und nicht die Meldung ───────────────────────────────
# Gemessen wird, ob der SERVER die Anfrage dieses Clients gelesen hat, bzw. ob
# unser CLIENT den Rumpf von nginx gelesen hat. Firefox' eigene Ausgabe ist
# dafuer unbrauchbar: headless meldet er einen Zertifikatsfehler nicht auf
# stderr, und sein Exitcode ist auch bei der Fehlerseite 0. Scheitert die
# Kettenpruefung, bricht er den Handschlag VOR der Anfrage ab — "der Server
# hat GET gesehen" ist damit die Aussage, die wir brauchen.
#
# ── Snap-Firefox ──────────────────────────────────────────────────────────
# Gemessen auf dieser Maschine: /usr/bin/firefox ist ein Snap (161.0). Ein
# Snap ist eingesperrt und kann ein Profil unter /tmp NICHT lesen. Das Profil
# liegt deshalb unter $HOME, wenn Firefox ein Snap ist, und wird danach
# geraeumt. Ohne diese Unterscheidung startet Firefox mit einem leeren Profil
# und die Gegenprobe oben wuerde zur Hauptprobe.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"

PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
no()  { echo "FAIL $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
FFHOME=""
raeumen() {
  pkill -f "tls_srv_2613" 2>/dev/null
  [ -n "${NGPID:-}" ] && kill "$NGPID" 2>/dev/null
  pkill -x firefox 2>/dev/null
  rm -rf "$TMP"
  [ -n "$FFHOME" ] && rm -rf "$FFHOME"
}
trap raeumen EXIT

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl fehlt — ohne Zertifikate ist nichts messbar"
  echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0
fi

# ── Zertifikate: eigene CA, Blatt auf localhost, dazu eine FREMDE CA ──────
mkdir -p "$TMP/certs"
( cd "$TMP/certs"
  openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.pem -days 365 \
    -nodes -subj "/CN=Aurum 2613 CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
  openssl req -newkey rsa:2048 -keyout key.pem -out leaf.csr -nodes \
    -subj "/CN=localhost"
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' > ext.cnf
  openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -sha256 -days 365 \
    -extfile ext.cnf -out cert.pem
  cat cert.pem ca.pem > kette.pem
  openssl req -x509 -newkey rsa:2048 -keyout fremd.key -out fremd.pem -days 365 \
    -nodes -subj "/CN=fremde CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
) > "$TMP/openssl.log" 2>&1
for f in ca.pem cert.pem key.pem kette.pem fremd.pem; do
  [ -s "$TMP/certs/$f" ] || { echo "SKIP openssl erzeugte $f nicht"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
done

PORT="${INTEROP_2613_PORT:-18974}"
freierPort() {
  while ss -ltn 2>/dev/null | grep -q ":$PORT "; do PORT=$((PORT+1)); done
  echo "$PORT"
}
warteAufPort() {   # port, sekunden
  local p="$1" g="$2" i=0
  while [ "$i" -lt "$((g * 10))" ]; do
    ss -ltn 2>/dev/null | grep -q ":$p " && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

# ── Teil 1: Firefox (NSS) gegen unseren Server ────────────────────────────
if ! command -v certutil >/dev/null 2>&1; then
  echo "SKIP Firefox: certutil fehlt (Paket libnss3-tools) — die Test-CA ist"
  echo "     ohne sie nicht in die NSS-Datenbank einzutragen, und ein Lauf mit"
  echo "     abgeschalteter Pruefung belegt weniger als der Chromium-Lauf in"
  echo "     tests/tls13_interop_clients_2096_test.sh"
elif ! command -v firefox >/dev/null 2>&1; then
  echo "SKIP Firefox: nicht im Pfad"
else
  # Ein Snap kommt an /tmp nicht heran -> Profil unter $HOME.
  if [ -d /snap/firefox ] || readlink -f "$(command -v firefox)" | grep -q '^/snap/'; then
    # NICHT versteckt: gemessen, dass ein Snap ein Profil unter ~/.<name>
    # nicht lesen kann. Firefox faellt dann auf das STANDARDprofil zurueck und
    # meldet "Firefox is already running" — der Lauf sieht dann wie ein
    # TLS-Befund aus, obwohl er nie bei unserem Server war.
    FFHOME="$(mktemp -d "$HOME/aurum2613.XXXXXX")"
    PROFBASIS="$FFHOME"
    echo "    (Firefox ist ein Snap — Profil unter \$HOME, nicht unter /tmp)"
  else
    PROFBASIS="$TMP"
  fi

  if ! "$LYXC" --std-path="$ROOT" "$ROOT/tools/tls_server.lyx" -o "$TMP/tls_srv_2613" \
       > "$TMP/b_srv.log" 2>&1; then
    no "tools/tls_server.lyx uebersetzt" "$(tail -3 "$TMP/b_srv.log" | tr '\n' ' ')"
  else
    ff_lauf() {   # profil, logname -> gibt die Serverausgabe zurueck
      local prof="$1" name="$2" p
      p="$(freierPort)"; PORT=$((PORT+1))
      # N=0 (endlos) und nicht N=1: Firefox oeffnet mehr als eine Verbindung
      # (Vorverbindung, favicon). Mit N=1 beendet sich der Server nach der
      # ersten, und die eigentliche Anfrage landet an einem toten Port.
      ( ulimit -v 6000000 -c 0; "$TMP/tls_srv_2613" "$p" "$TMP/certs/kette.pem" \
          "$TMP/certs/key.pem" "$TMP/certs/ca.pem" N=0 http11 \
          > "$TMP/srv_$name.txt" 2>&1 & )
      warteAufPort "$p" 20 || echo "    HINWEIS: Server lauscht nach 20 s nicht auf $p"
      # Ein noch laufender Firefox nimmt den naechsten Aufruf an sich ("already
      # running") und das neue Profil wird nie benutzt. `pkill -x`, nicht
      # `pkill -f`: das Muster "firefox" trifft sonst diese Zeile selbst.
      pkill -x firefox 2>/dev/null
      local w=0
      while pgrep -x firefox >/dev/null 2>&1 && [ "$w" -lt 50 ]; do sleep 0.2; w=$((w+1)); done
      timeout 90 firefox --headless --profile "$prof" \
        --screenshot "$prof/schuss.png" "https://localhost:$p/" \
        > "$TMP/ff_$name.log" 2>&1
      # Auf die WIRKUNG warten, statt blind zu schlafen: der Server gibt je
      # vollendetem Handschlag eine Zeile `verbindung N version …` aus.
      local i=0
      while [ "$i" -lt 100 ]; do
        grep -qE 'verbindung [0-9]+ version 772' "$TMP/srv_$name.txt" 2>/dev/null && break
        sleep 0.1; i=$((i+1))
      done
      pkill -f tls_srv_2613 2>/dev/null
      cat "$TMP/srv_$name.txt" 2>/dev/null
    }

    # (a) mit unserer CA in der NSS-Datenbank
    PROF="$PROFBASIS/ff_mit"
    mkdir -p "$PROF"
    certutil -N -d "sql:$PROF" --empty-password > "$TMP/certutil.log" 2>&1
    certutil -A -d "sql:$PROF" -n aurum-2613-ca -t "CT,," \
      -i "$TMP/certs/ca.pem" >> "$TMP/certutil.log" 2>&1
    if ! certutil -L -d "sql:$PROF" 2>/dev/null | grep -q 'aurum-2613-ca'; then
      no "Test-CA in der NSS-Datenbank" "$(tail -2 "$TMP/certutil.log" | tr '\n' ' ')"
    else
      ok "Test-CA steht in der NSS-Datenbank (certutil -L)"
      # Gemessen wird der VOLLENDETE HANDSCHLAG (`verbindung N version 772`,
      # 772 = TLS 1.3). Das ist bei TLS 1.3 die Aussage ueber die
      # Kettenpruefung: der Client schickt sein Finished erst, NACHDEM er
      # Certificate und CertificateVerify geprueft hat; scheitert die
      # Pruefung, bricht er stattdessen mit einem Zertifikatsalert ab.
      #
      # Nicht gemessen wird die Anfragezeile: tools/tls_server.lyx gibt die
      # Anfrage nicht aus. Hier stand zuerst `grep "GET /"` — das Kriterium
      # war damit von diesem Werkzeug grundsaetzlich nicht erfuellbar, und der
      # Test meldete rot, obwohl Firefox die Kette angenommen hatte. Die
      # Anfragezeile kommt aus dem Testprogramm von
      # tests/tls13_interop_clients_2096_test.sh, nicht aus diesem Werkzeug.
      aus_mit="$(ff_lauf "$PROF" mit)"
      hs_mit="$(printf '%s' "$aus_mit" | grep -cE 'verbindung [0-9]+ version 772')"
      if [ "$hs_mit" -ge 1 ]; then
        ok "Firefox (NSS) gegen unseren Server: $hs_mit Handschlag/Handschlaege vollendet (TLS 1.3, Kette aus der NSS-Datenbank angenommen)"
      else
        no "Firefox (NSS) gegen unseren Server" "kein vollendeter Handschlag: $(printf '%s' "$aus_mit" | tr '\n' ' ' | head -c 200)"
      fi

      # (b) Gegenprobe: LEERES Profil, dieselbe Kette -> muss scheitern
      PROF2="$PROFBASIS/ff_ohne"
      mkdir -p "$PROF2"
      certutil -N -d "sql:$PROF2" --empty-password >> "$TMP/certutil.log" 2>&1
      aus_ohne="$(ff_lauf "$PROF2" ohne)"
      # Die Gegenprobe ist nur dann eine Aussage, wenn der Hauptfall GETRAGEN
      # hat. Sonst ist "Firefox kam nicht an" bloss die Wiederholung des
      # Fehlschlags von oben — genau so stand hier einmal ein PASS, waehrend
      # Firefox in BEIDEN Laeufen nie bei unserem Server war.
      hs_ohne="$(printf '%s' "$aus_ohne" | grep -cE 'verbindung [0-9]+ version 772')"
      if [ "$hs_mit" -lt 1 ]; then
        echo "    (Gegenprobe nicht ausgewertet: der Hauptfall trug nicht, sie waere hier gegenstandslos)"
      elif [ "$hs_ohne" -ge 1 ]; then
        no "Gegenprobe Firefox ohne Vertrauensanker" "$hs_ohne Handschlag(e) TROTZDEM vollendet — Firefox prueft hier nichts, der Hauptfall belegt dann auch nichts"
      else
        ok "Gegenprobe: ohne Vertrauensanker vollendet Firefox keinen Handschlag ($hs_mit mit Anker gegen $hs_ohne ohne)"
      fi
    fi
  fi
fi

# ── Teil 2: nginx als Gegenstelle fuer unseren Client ─────────────────────
if ! command -v nginx >/dev/null 2>&1; then
  echo "SKIP nginx: nicht im Pfad — die andere Serverseite neben s_server fehlt"
else
  cat > "$TMP/cli.lyx" <<'LYXEOF'
// Erzeugt von tests/tls13_interop_firefox_nginx_2613_test.sh (#2613).
// Unser TLS-1.3-Client gegen eine fremde Serverseite (nginx), mit
// Kettenpruefung gegen eine MITGEGEBENE Wurzel -- so laesst sich dieselbe
// Verbindung einmal mit der richtigen und einmal mit einer fremden Wurzel
// fahren, und die zweite MUSS scheitern.
unit main;

// Bewusst ohne @capabilities: das Gegenstueck in
// tests/tls13_interop_clients_2096_test.sh hat auch keine, und eine zu enge
// Liste wuerde hier als Laufzeitabbruch erscheinen und wie ein TLS-Befund
// aussehen. Die Rechteliste ist Sache von tools/, nicht eines Testprogramms.
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.net.socket;
import std.crypto.der;
import std.crypto.x509;
import std.net.tls13;

fn ladeDer(pfad: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(8192);
  var n: int64 := ReadFile(pfad, pem as pchar, 8191);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, "CERTIFICATE"c as int64, 11, derOut, 4096);
}

fn main(): int64 {
  var port: int64 := StrToInt(GetArg(1) as pchar);
  var caPfad: pchar := GetArg(2) as pchar;
  var host: pchar := "localhost"c;

  var dCa: int64 := alloc(8192);
  var lCa: int64 := ladeDer(caPfad, dCa);
  if (lCa <= 0) { PrintLn("CA-NICHT-LESBAR"); return 1; }
  var trust: int64 := alloc(16); poke64(trust, dCa); poke64(trust + 8, lCa);

  var cfg: int64 := alloc(TlsConfigGroesse());
  var alpn: pchar := "http/1.1"c;
  TlsConfigNeu(cfg, 2);
  TlsConfigTrust(cfg, trust, 1);
  TlsConfigHost(cfg, host as int64, StrLen(host));
  TlsConfigAlpn(cfg, alpn as int64, StrLen(alpn));
  TlsConfigKettePruefen(cfg, 1);
  TlsConfigZeit(cfg, 1800000000);

  var conn: TCPConn := TCPConnect(0x7F000001, port);
  var c: int64 := TlsNeu(cfg);
  var puf: int64 := alloc(32768);
  var runden: int64 := 0;
  while (!TlsFertig(c) && runden < 200) {
    var rc: int64 := TlsSchritt(c);
    if (rc < 0) { Print("ABGEWIESEN "); PrintInt(rc); Print(" "); PrintLn(TlsFehlerText(rc)); return 2; }
    var m: int64 := TlsAusgabe(c, puf, 32768);
    if (m > 0) { TCPConnWrite(conn, puf as pchar, m); }
    if (!TlsFertig(c)) {
      var n: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n <= 0) { PrintLn("VERBINDUNG-WEG"); return 3; }
      TlsFuetter(c, puf, n);
    }
    runden := runden + 1;
  }
  if (!TlsFertig(c)) { PrintLn("HANDSCHLAG-UNFERTIG"); return 4; }
  Print("handschlag-fertig suite "); PrintInt(TlsSuite(c)); PrintLn("");

  var frage: pchar := "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"c;
  TlsSchreibe(c, frage as int64, StrLen(frage));
  var m2: int64 := TlsAusgabe(c, puf, 32768);
  if (m2 > 0) { TCPConnWrite(conn, puf as pchar, m2); }

  // #2418/#2675: ZUERST den entschluesselten Puffer fragen, dann den Socket.
  var ein: int64 := alloc(8192);
  var gelesen: int64 := 0;
  runden := 0;
  while (gelesen <= 0 && runden < 100) {
    gelesen := TlsLese(c, ein, 8192);
    if (gelesen <= 0) {
      var n2: int64 := TCPConnRead(conn, puf as pchar, 32768);
      if (n2 > 0) { TlsFuetter(c, puf, n2); }
      gelesen := TlsLese(c, ein, 8192);
      if (n2 <= 0 && gelesen <= 0) { runden := 100; }
    }
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
  if ! ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/cli.lyx" -o "$TMP/cli2613" ) \
       > "$TMP/b_cli.log" 2>&1; then
    no "Client uebersetzt" "$(grep -m1 -i error "$TMP/b_cli.log")"
  else
    NPORT="$(freierPort)"; PORT=$((PORT+1))
    mkdir -p "$TMP/ng/logs" "$TMP/ng/body" "$TMP/ng/proxy" "$TMP/ng/fastcgi" "$TMP/ng/uwsgi" "$TMP/ng/scgi"
    cat > "$TMP/ng/nginx.conf" <<NGEOF
worker_processes 1;
daemon off;
pid $TMP/ng/nginx.pid;
error_log $TMP/ng/logs/error.log warn;
events { worker_connections 64; }
http {
  access_log $TMP/ng/logs/access.log;
  client_body_temp_path $TMP/ng/body;
  proxy_temp_path $TMP/ng/proxy;
  fastcgi_temp_path $TMP/ng/fastcgi;
  uwsgi_temp_path $TMP/ng/uwsgi;
  scgi_temp_path $TMP/ng/scgi;
  server {
    listen 127.0.0.1:$NPORT ssl;
    server_name localhost;
    ssl_certificate     $TMP/certs/kette.pem;
    ssl_certificate_key $TMP/certs/key.pem;
    ssl_protocols TLSv1.3;
    location / { default_type text/plain; return 200 "nginx fuer Lyx\n"; }
  }
}
NGEOF
    nginx -c "$TMP/ng/nginx.conf" -p "$TMP/ng" > "$TMP/ng/start.log" 2>&1 &
    NGPID=$!
    if ! warteAufPort "$NPORT" 20; then
      no "nginx lauscht" "$(tail -3 "$TMP/ng/logs/error.log" "$TMP/ng/start.log" 2>/dev/null | tr '\n' ' ')"
    else
      ok "nginx $(nginx -v 2>&1 | sed 's|.*/||') lauscht auf $NPORT (TLSv1.3)"

      # (a) richtige Wurzel: die Antwort muss ankommen
      aus="$(timeout 60 "$TMP/cli2613" "$NPORT" "$TMP/certs/ca.pem" 2>&1)"
      rc=$?
      fehlend=""
      printf '%s' "$aus" | grep -q 'handschlag-fertig suite' || fehlend="$fehlend handschlag"
      printf '%s' "$aus" | grep -q 'nginx fuer Lyx'          || fehlend="$fehlend nutzdaten"
      printf '%s' "$aus" | grep -q '200 OK'                  || fehlend="$fehlend status"
      if [ "$rc" -eq 0 ] && [ -z "$fehlend" ]; then
        ok "unser Client -> nginx: Handschlag, Kette geprueft, Rumpf gelesen"
      else
        no "unser Client -> nginx" "rc=$rc, gefallen:$fehlend, Ausgabe: $(printf '%s' "$aus" | tr '\n' ' ' | head -c 220)"
      fi

      # (b) Gegenprobe: FREMDE Wurzel -> muss abweisen
      aus2="$(timeout 60 "$TMP/cli2613" "$NPORT" "$TMP/certs/fremd.pem" 2>&1)"
      rc2=$?
      if [ "$rc2" -ne 0 ] && ! printf '%s' "$aus2" | grep -q 'nginx fuer Lyx'; then
        ok "Gegenprobe: mit fremder Wurzel weist unser Client nginx ab (rc=$rc2)"
      else
        no "Gegenprobe fremde Wurzel" "rc=$rc2 und Rumpf gelesen — die Kettenpruefung greift nicht: $(printf '%s' "$aus2" | tr '\n' ' ' | head -c 220)"
      fi
    fi
    kill "$NGPID" 2>/dev/null
  fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
