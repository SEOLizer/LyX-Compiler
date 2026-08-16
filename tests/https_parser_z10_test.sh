#!/usr/bin/env bash
# tests/https_parser_z10_test.sh — #1534, #1539.
#
# Beide Meldungen hatten dieselbe Wurzel: `std/net/https.lyx` zerlegte die
# Antwort SELBST, statt den Parser aus `std/net/http.lyx` zu benutzen — und
# zwar nur die Statuszeile. Was die Kopie nicht mitbekommen hatte, fehlte:
#
#   #1534 Kopfzeilen wurden nicht übernommen (`headersRaw`/`headersSize` blieben
#         ununitialisiert). Kein ETag, kein Content-Type — und `HTTPResponseFree`
#         rief `munmap` auf einen Zeiger aus Stack-Rauschen.
#   #1539 `Transfer-Encoding: chunked` wurde nicht aufgelöst. Kleine Antworten
#         kamen mit Content-Length durch, ab einer gewissen Größe schaltet der
#         Server auf chunked um — und der Rumpf war plötzlich Müll.
#
# Der Parser steht jetzt EINMAL in http.lyx (`HTTPParseResponse`) und liest
# nicht selbst vom Socket; deshalb können TCP- und TLS-Weg ihn teilen.
#
# GEMESSEN WIRD OHNE NETZ: der Test baut Antwortpuffer im Speicher und gibt sie
# dem Parser. Ein Test gegen einen echten Server wäre von dessen Laune abhängig
# — und genau die Umschaltung auf chunked, um die es geht, ließe sich nicht
# erzwingen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'LYXEOF'
import std.io;
import std.alloc;
import std.string;
import std.net.http;

fn schreib(buf: int64, pos: int64, s: pchar): int64 {
  var i: int64 := 0;
  while (StrCharAt(s, i) != 0) { poke8(buf + pos + i, StrCharAt(s, i)); i := i + 1; }
  return pos + i;
}

fn leer(): HTTPResponse {
  var r: HTTPResponse;
  r.statusCode := 0; r.statusText := 0; r.headerCount := 0;
  r.contentLength := 0; r.bodyPtr := 0; r.bodySize := 0;
  r.headersRaw := 0; r.headersSize := 0;
  return r;
}

fn main(): int64 {
  // --- gechunkt, mit Leerzeichen hinter dem Doppelpunkt (so senden es Server)
  var b: int64 := alloc(1024);
  var p: int64 := 0;
  p := schreib(b, p, "HTTP/1.1 200 OK\r\n");
  p := schreib(b, p, "content-type: application/json\r\n");
  p := schreib(b, p, "Transfer-Encoding: chunked\r\n");
  p := schreib(b, p, "ETag: \"abc123\"\r\n");
  p := schreib(b, p, "\r\n");
  p := schreib(b, p, "8\r\n{\"a\": 1}\r\n");
  p := schreib(b, p, "5\r\nrest!\r\n");
  p := schreib(b, p, "0\r\n\r\n");
  var r: HTTPResponse := HTTPParseResponse(leer(), b, p);
  PrintStr("A|"); PrintStr(IntToStr(r.statusCode));
  PrintStr("|"); PrintStr(IntToStr(r.bodySize));
  PrintStr("|"); PrintStr(r.bodyPtr as pchar);
  PrintStr("|"); PrintStr(IntToStr(r.headerCount));
  PrintStr("|"); PrintLn(BoolToStr(r.headersRaw != 0));

  // --- dieselbe Antwort OHNE Leerzeichen: darf nicht schlechter sein
  var b2: int64 := alloc(1024);
  var q: int64 := 0;
  q := schreib(b2, q, "HTTP/1.1 200 OK\r\nTransfer-Encoding:chunked\r\n\r\n");
  q := schreib(b2, q, "3\r\nabc\r\n0\r\n\r\n");
  var r2: HTTPResponse := HTTPParseResponse(leer(), b2, q);
  PrintStr("B|"); PrintStr(IntToStr(r2.bodySize)); PrintStr("|"); PrintLn(r2.bodyPtr as pchar);

  // --- ungechunkt, content-length KLEIN geschrieben (Cloudflare)
  var b3: int64 := alloc(512);
  var t: int64 := 0;
  t := schreib(b3, t, "HTTP/1.1 404 Not Found\r\ncontent-length: 5\r\n\r\nhallo");
  var r3: HTTPResponse := HTTPParseResponse(leer(), b3, t);
  PrintStr("C|"); PrintStr(IntToStr(r3.statusCode));
  PrintStr("|"); PrintStr(IntToStr(r3.contentLength));
  PrintStr("|"); PrintLn(r3.bodyPtr as pchar);

  // --- ungechunkt, GROSS geschrieben: beide Schreibweisen muessen gehen
  var b4: int64 := alloc(512);
  var u: int64 := 0;
  u := schreib(b4, u, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
  var r4: HTTPResponse := HTTPParseResponse(leer(), b4, u);
  PrintStr("D|"); PrintStr(IntToStr(r4.contentLength)); PrintStr("|"); PrintLn(r4.bodyPtr as pchar);

  // --- Kopfzeilen sind auslesbar (das war der Zweck von #1534)
  var hdr: pchar := r.headersRaw as pchar;
  var gefunden: int64 := 0;
  var k: int64 := 0;
  while (k < r.headersSize - 4) {
    if (StrCharAt(hdr, k) == 69 && StrCharAt(hdr, k + 1) == 84 &&
        StrCharAt(hdr, k + 2) == 97 && StrCharAt(hdr, k + 3) == 103) { gefunden := 1; }
    k := k + 1;
  }
  PrintStr("E|"); PrintLn(IntToStr(gefunden));

  // --- Antwort ohne Rumpf: nichts darf gesetzt werden, was spaeter befreit wird
  var b5: int64 := alloc(256);
  var v: int64 := 0;
  v := schreib(b5, v, "HTTP/1.1 204 No Content\r\n\r\n");
  var r5: HTTPResponse := HTTPParseResponse(leer(), b5, v);
  PrintStr("F|"); PrintStr(IntToStr(r5.statusCode));
  PrintStr("|"); PrintStr(IntToStr(r5.bodySize));
  PrintStr("|"); PrintLn(BoolToStr(r5.bodyPtr == 0));

  return 0;
}
LYXEOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
  no "Messprogramm uebersetzt" "$("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
  echo "--- $PASS PASS, $((FAIL)) FAIL"
  exit 1
fi

A="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
if [ "$rc" -ge 128 ]; then
  no "Messprogramm laeuft" "ABSTURZ rc=$rc"
  echo "--- $PASS PASS, $FAIL FAIL"
  exit 1
fi

z() { echo "$A" | grep "^$1|" | head -1; }

[ "$(z A)" = 'A|200|13|{"a": 1}rest!|3|true' ] \
  && ok "#1539: chunked wird aufgeloest (mit Leerzeichen im Header)" \
  || no "#1539: chunked wird aufgeloest (mit Leerzeichen im Header)" "$(z A)"

[ "$(z B)" = "B|3|abc" ] \
  && ok "#1539: chunked auch ohne Leerzeichen" \
  || no "#1539: chunked auch ohne Leerzeichen" "$(z B)"

[ "$(z C)" = "C|404|5|hallo" ] \
  && ok "#1539: ungechunkt mit kleingeschriebenem content-length" \
  || no "#1539: ungechunkt mit kleingeschriebenem content-length" "$(z C)"

[ "$(z D)" = "D|2|ok" ] \
  && ok "#1539: Content-Length gross geschrieben unveraendert" \
  || no "#1539: Content-Length gross geschrieben unveraendert" "$(z D)"

[ "$(z E)" = "E|1" ] \
  && ok "#1534: Kopfzeilen sind auslesbar (ETag gefunden)" \
  || no "#1534: Kopfzeilen sind auslesbar (ETag gefunden)" "$(z E)"

[ "$(z F)" = "F|204|0|true" ] \
  && ok "#1534: Antwort ohne Rumpf setzt keinen Zeiger" \
  || no "#1534: Antwort ohne Rumpf setzt keinen Zeiger" "$(z F)"

# ===========================================================================
# #1534 — die drei HTTPS-Einstiege initialisieren die Felder
# ===========================================================================

# Der gefaehrliche Teil der Meldung: HTTPResponseFree ruft munmap auf
# headersRaw. Wird das Feld nicht gesetzt, entscheidet Stack-Rauschen ueber
# Adresse und Laenge. Geprueft wird im Quelltext, weil ein Laufzeittest eine
# echte TLS-Verbindung braeuchte — und weil genau das Fehlen der Zeile der
# Fehler war.
# Ein awk-Bereichsmuster mit demselben Anfangs- und Endausdruck liefert nur
# EINE Zeile (bekannte Falle) — gezaehlt wird deshalb schlicht, ob es zu jedem
# der drei Einstiege eine Initialisierung gibt.
einstiege="$(grep -c '^pub fn HTTPS\(Get\|Send\|Post\)(' "$ROOT/std/net/https.lyx" || true)"
inits="$(grep -c 'response.headersRaw := 0;' "$ROOT/std/net/https.lyx" || true)"
if [ "$einstiege" = "3" ] && [ "$inits" = "3" ]; then
  ok "#1534: alle drei HTTPS-Einstiege initialisieren headersRaw"
else
  no "#1534: alle drei HTTPS-Einstiege initialisieren headersRaw" "$inits Initialisierungen bei $einstiege Einstiegen"
fi

# ===========================================================================
# Der eigentliche Punkt beider Meldungen: EIN Parser
# ===========================================================================

# https.lyx darf die Statuszeile nicht mehr selbst zerlegen. Bleibt die Kopie
# stehen, laufen die beiden Wege beim naechsten Umbau wieder auseinander —
# genau so sind #1534 und #1539 entstanden.
kopien="$(grep -c 'peek8(buf + i + 4) == 47' "$ROOT/std/net/https.lyx" || true)"
[ "$kopien" = "0" ] \
  && ok "#1534/#1539: https.lyx zerlegt die Statuszeile nicht mehr selbst" \
  || no "#1534/#1539: https.lyx zerlegt die Statuszeile nicht mehr selbst" "$kopien Kopien uebrig"

aufrufe="$(grep -c 'HTTPParseResponse(response, buf' "$ROOT/std/net/https.lyx" || true)"
[ "$aufrufe" = "3" ] \
  && ok "#1534/#1539: alle drei Einstiege nutzen den gemeinsamen Parser" \
  || no "#1534/#1539: alle drei Einstiege nutzen den gemeinsamen Parser" "$aufrufe von 3"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
