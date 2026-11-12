#!/usr/bin/env bash
# tests/doku_zusagen_test.sh — #1254: die Zusagen, auf die sich die Doku beruft.
#
# Die Doku-Erhebung stellte vier Fragen an den Compiler statt an den Text.
# Beantwortet werden sie hier durch Code, nicht durch Prosa — und der Test
# haelt die Antworten fest, damit die Doku sich darauf berufen kann:
#
#   PrintF64          48 Fundstellen. Als Builtin ergaenzt (statt 48 Stellen
#                     umzuschreiben) — geprueft, dass es wirklich druckt.
#   PdfAddImageFile   Die Doku zeigte PdfAddImage(doc, "logo.png"). Den
#                     Dateiweg gibt es jetzt; beide Haelften waren schon da.
#   new T[n]          Die Erhebung meldete "expected (, got [". Nachgemessen
#                     mit 1.1.6E: es GEHT, auch mit Groesse zur Laufzeit. Die
#                     Doku hatte recht, der Compiler hat aufgeholt — nur die
#                     Grammatik nennt die Form nicht.
#   PdfAttachFile     Signatur unveraendert (doc, filename, data, dataLen) —
#                     die Doku uebergab dort einen Beschreibungstext.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

# --- PrintF64 --------------------------------------------------------------
# Nicht nur "uebersetzt": die Zahl muss auch herauskommen. Ein Builtin, das
# nichts druckt, waere aus Sicht der Doku genauso falsch wie ein fehlendes.
cat > "$TMP/f.lyx" <<'EOF'
fn main(): int64 { PrintF64(3.75); return 0; }
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" >"$TMP/f.log" 2>&1; then
  AUS=$("$TMP/f" 2>&1 | tr -d '\r\n ')
  case "$AUS" in
    3.75*) ok "PrintF64 druckt (${AUS})" ;;
    *)     no "PrintF64 druckt" "erhalten '${AUS}'" ;;
  esac
else
  no "PrintF64 uebersetzt" "$(grep -m1 -iE 'error' "$TMP/f.log")"
fi

# --- new T[n] gibt es doch -------------------------------------------------
# Gemessen wird der SPEICHER, nicht der Bau: eine Form, die uebersetzt und
# einen unbrauchbaren Zeiger liefert, waere schlimmer als eine, die meldet.
# Die Groesse steht absichtlich in einer Variablen — der Fall aus der Doku.
cat > "$TMP/n.lyx" <<'EOF'
fn main(): int64 {
  var n: int64 := 1000;
  var b: int64 := new uint8[n];
  if (b == 0) { return 1; }
  poke8(b, 7);
  poke8(b + 999, 9);
  var c: int64 := new int64[4];
  if (c == 0) { return 2; }
  poke64(c, 111);
  poke64(c + 24, 222);
  if (peek64(c) + peek64(c + 24) != 333) { return 3; }
  return peek8(b) + peek8(b + 999);
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/n.lyx" -o "$TMP/n" >"$TMP/n.log" 2>&1; then
  "$TMP/n"; RC=$?
  if [ "$RC" = "16" ]; then ok "new T[n] belegt Speicher, auch mit Groesse zur Laufzeit"
  else no "new T[n] belegt Speicher" "rc=$RC (1/2=Nullzeiger, 3=int64-Feld falsch, 16=in Ordnung)"; fi
else
  no "new T[n] uebersetzt" "$(grep -m1 -iE 'error' "$TMP/n.log") — die Erhebung zu #1254 meldete genau das, es galt aber nur bis 1.0.14J"
fi
# Und der Weg, den die Doku stattdessen zeigen soll, muss tragen.
cat > "$TMP/a.lyx" <<'EOF'
import std.alloc;
fn main(): int64 {
  var n: int64 := 16;
  var b: int64 := alloc(n);
  poke8(b, 65);
  var c: int64 := peek8(b);
  free(b, n);
  return c;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/a.lyx" -o "$TMP/a" >"$TMP/a.log" 2>&1; then
  "$TMP/a"; RC=$?
  if [ "$RC" = "65" ]; then ok "alloc(n) traegt ebenfalls"
  else no "alloc(n) traegt ebenfalls" "rc=$RC statt 65"; fi
else
  no "alloc(n) uebersetzt" "$(grep -m1 -iE 'error' "$TMP/a.log")"
fi

# --- PdfAddImageFile -------------------------------------------------------
# Ein echtes PNG (RGBA, 4x3) wird erzeugt, eingebettet und die geschriebene
# Datei nachgesehen. "Gibt keinen Fehler" reicht hier nicht: das Bild muss im
# PDF ankommen, mit den richtigen Massen.
python3 - "$TMP/logo.png" <<'PY'
import zlib, struct, sys
w, h = 4, 3
roh = b''
for y in range(h):
    roh += b'\x00' + b''.join(bytes([(x*60) % 256, (y*80) % 256, 128, 255]) for x in range(w))
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
open(sys.argv[1], 'wb').write(
    b'\x89PNG\r\n\x1a\n'
    + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(roh))
    + chunk(b'IEND', b''))
PY

cat > "$TMP/p.lyx" <<EOF
import std.pdf.builder;
import std.pdf.page;
import std.pdf.imagefile;
fn main(): int64 {
  var doc: int64 := PdfNew();
  if (doc == 0) { return 1; }
  var seite: int64 := PdfAddPage(doc, 595.0, 842.0);
  var idx: int64 := PdfAddImageFile(doc, "$TMP/logo.png"c);
  if (idx < 0) { return 2; }
  if (PdfSave(doc, "$TMP/bild.pdf"c) != 0) { return 3; }
  return 42;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/p.log" 2>&1; then
  "$TMP/p" >/dev/null 2>&1; RC=$?
  if [ "$RC" = "42" ]; then ok "PdfAddImageFile bettet ein PNG ein"
  else no "PdfAddImageFile bettet ein PNG ein" "rc=$RC (1=kein doc, 2=Bild abgelehnt, 3=Save)"; fi
  if [ -s "$TMP/bild.pdf" ]; then
    if python3 - "$TMP/bild.pdf" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
fehlt = [k for k in (b'%PDF-1.', b'/Image', b'/DeviceRGB', b'/Width 4', b'/Height 3') if k not in d]
sys.exit(1 if fehlt else 0)
PY
    then ok "das PDF traegt das Bild mit den richtigen Massen"
    else no "das PDF traegt das Bild" "Breite/Hoehe oder Farbraum fehlen"; fi
  else
    no "das PDF wird geschrieben"
  fi
else
  no "PdfAddImageFile uebersetzt" "$(grep -m1 -iE 'error|undefined' "$TMP/p.log")"
fi

# --- PdfAttachFile: Signatur unveraendert ----------------------------------
# Die Doku uebergab hier einen Beschreibungstext, wo die Nutzdaten stehen.
# Der Test haelt die echte Stelligkeit fest, damit die Korrektur ein Ziel hat.
if grep -q "pub fn PdfAttachFile(doc: int64, filename: pchar, data: int64, dataLen: int64)" "$ROOT/std/pdf/attach.lyx"; then
  ok "PdfAttachFile nimmt weiterhin (doc, filename, data, dataLen)"
else
  no "PdfAttachFile-Signatur" "die Doku-Korrektur zielt auf eine andere Stelligkeit"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
