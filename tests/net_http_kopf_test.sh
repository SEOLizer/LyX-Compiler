#!/usr/bin/env bash
# tests/net_http_kopf_test.sh — #1452, #1453, #1346.
#
#   #1452  HTTPGetHeader schnitt den Wert nicht am Zeilenende ab: der Aufrufer
#          bekam den gesuchten Wert PLUS alle folgenden Kopfzeilen.
#   #1453  HTTPResponse.headerCount blieb immer 0 — eine Schleife darueber lief
#          null Mal und sah aus wie "Antwort ohne Header".
#   #1346  HTTPSGet/HTTPSPost sendeten den Requestpuffer ab Offset 0 mit fest
#          verdrahteten 4096 Byte. Der Puffer hat aber 16 Byte Metadatenkopf —
#          der Server sah keine gueltige Requestzeile und antwortete 400.
#
# GEMESSEN WIRD GEGEN EINEN EIGENEN SERVER auf dem Rechner, nicht gegen eine
# Gegenstelle im Netz: die Kopfzeilen sind dann bekannt und der Test sagt
# dasselbe auf einer Maschine ohne Internet. Fuer #1346 braucht es TLS —
# dafuer gibt es hier keinen lokalen Server, der Fall wird gegen die
# Gegenstelle aus der Meldung geprueft und uebersprungen, wenn sie fehlt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; PASS=0; FAIL=0
SRVPID=""
aufraeumen() { [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$TMP"; }
trap aufraeumen EXIT
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP kein python3 — ohne Gegenstelle ist nichts zu messen"
  echo "--- 0 PASS, 0 FAIL"; exit 0
fi

PORT=$(( 18600 + ($$ % 900) ))

# Ein Server mit bekannten Kopfzeilen. Absichtlich dabei:
#   * ein Wert mit Leerzeichen und Semikolon (Content-Type)
#   * "X-Server" VOR "Server": ohne Zeilenanker faende die Suche nach
#     "Server" die falsche Zeile
python3 - "$PORT" >/dev/null 2>&1 <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
body = b"hallo"
head = (b"HTTP/1.1 200 OK\r\n"
        b"X-Server: falsch\r\n"
        b"Content-Type: text/html; charset=utf-8\r\n"
        b"Server: lyxtest\r\n"
        b"X-Leer:\r\n"
        b"Content-Length: %d\r\n\r\n" % len(body))
while True:
    try:
        c, _ = s.accept()
        c.recv(65536)
        c.sendall(head + body)
        c.close()
    except Exception:
        break
PY
SRVPID=$!
sleep 1

cat > "$TMP/h.lyx" <<EOF
import std.io;
import std.net.http;
fn main(): int64 {
  var req: HTTPRequest;
  req.method := HTTP_GET;
  req.host := "127.0.0.1" as int64;
  req.path := "/" as int64;
  req.port := $PORT;
  req.headers := 0;
  req.body := 0;
  req.bodySize := 0;
  var resp: HTTPResponse := HTTPSend(req);
  PrintStr(IntToStr(resp.statusCode)); PrintStr("|");
  PrintStr(IntToStr(resp.headerCount)); PrintStr("|");
  PrintStr(HTTPGetHeader(resp, "Content-Type" as int64) as pchar); PrintStr("|");
  PrintStr(HTTPGetHeader(resp, "Server" as int64) as pchar); PrintStr("|");
  PrintStr(HTTPGetHeader(resp, "Content-Type" as int64) as pchar); PrintStr("|");
  PrintStr(IntToStr(HTTPGetHeader(resp, "X-Gibtsnicht" as int64))); PrintStr("|");
  PrintStr(HTTPGetHeader(resp, "x-server" as int64) as pchar); PrintStr("|");
  PrintStr(HTTPGetHeader(resp, "X-Leer" as int64) as pchar); PrintStr("|");
  PrintLn("");
  HTTPResponseFree(resp);
  return 0;
}
EOF

if "$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" >/dev/null 2>&1; then
  got="$(timeout 30 "$TMP/h" 2>&1)"; rc=$?
  soll="200|5|text/html; charset=utf-8|lyxtest|text/html; charset=utf-8|0|falsch||"
  if [ "$rc" -ge 128 ]; then
    no "#1452/#1453: Kopfzeilen einzeln und gezaehlt" "ABSTURZ (rc=$rc)"
  elif [ "$got" = "$soll" ]; then
    ok "#1452/#1453: Kopfzeilen einzeln und gezaehlt"
  else
    no "#1452/#1453: Kopfzeilen einzeln und gezaehlt" "'$got' erwartet '$soll'"
  fi
else
  no "#1452/#1453: Kopfzeilen einzeln und gezaehlt" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/h.lyx" -o "$TMP/h" 2>&1 | grep -i error | head -1)"
fi

# ===========================================================================
# #1346 — HTTPS ueber die Komfortfunktion
# ===========================================================================

if command -v curl >/dev/null 2>&1 && curl -s -o /dev/null -m 10 https://lpm.seolizer.de/index.json 2>/dev/null; then
  printf 'import std.io;\nimport std.net.https;\nfn main(): int64 {\n  var r: HTTPResponse := HTTPSGet("lpm.seolizer.de"c, "/index.json"c);\n  PrintLn(IntToStr(r.statusCode));\n  return 0;\n}\n' > "$TMP/s.lyx"
  if "$LYXC" --std-path="$ROOT" "$TMP/s.lyx" -o "$TMP/s" >/dev/null 2>&1; then
    got="$(timeout 60 "$TMP/s" 2>&1)"
    if [ "$got" = "200" ]; then ok "#1346: HTTPSGet liefert 200 statt 400"
    else no "#1346: HTTPSGet liefert 200 statt 400" "'$got'"; fi
  else
    no "#1346: HTTPSGet liefert 200 statt 400" "uebersetzt nicht"
  fi
else
  echo "SKIP keine TLS-Gegenstelle erreichbar — #1346 nicht messbar"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
