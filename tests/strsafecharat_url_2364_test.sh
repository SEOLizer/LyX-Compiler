#!/usr/bin/env bash
# tests/strsafecharat_url_2364_test.sh — #2364: Zeichenzugriff mit bekannter
# Laenge statt `StrSafeCharAt` in den Schleifen von std/url.lyx.
#
# `StrSafeCharAt` bestimmt fuer seinen Bereichscheck die Laenge selbst
# (`StrLen`), ist also O(Laenge) JE ZEICHEN. In einer Schleife ueber die ganze
# Zeichenkette wird daraus quadratischer Aufwand. `std/url.lyx` hatte 79
# solche Aufrufe; alle sind auf `charAtN(s, i, n)` umgestellt — gleiche
# Semantik einschliesslich -1 ausserhalb, die Laenge kommt vom Aufrufer.
#
# GEPRUEFT WIRD DIE SKALIERUNG, NICHT DER WERT. Die quadratische Fassung
# rechnet richtig, nur langsam; ein Werttest waere vorher wie nachher gruen
# gewesen. Vervierfachte Laenge kostet bei linearem Aufwand etwa das
# Vierfache, bei quadratischem das Sechzehnfache. Das Verhaeltnis ist
# maschinenunabhaengiger als eine absolute Zeit, weil beide Messungen
# dieselbe Stoerung tragen.
#
# Die Werte werden TROTZDEM geprueft, und zwar zuerst: ohne sie misst der
# Rest Unsinn. Dazu kommen die bestehenden Suiten
# tests/lyx/stdlib/test_url_queryparam.lyx und test_url_c5.lyx, die alle
# oeffentlichen Wege abdecken (Parse, Build, Encode, Decode, QueryGet,
# QuerySet, Resolve) und wortgleich dasselbe liefern muessen wie vorher.
#
# Schwelle 800 %: deutlich ueber dem linearen Wert 400 und deutlich unter dem
# quadratischen 1600. Ein Test, der knapp an 400 liegt, waere auf einer
# belasteten Maschine rot, ohne dass etwas kaputt ist.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/sk.lyx" <<'EOF'
import std.io;
import std.string;
import std.time;
import std.url;

// Eine URL mit langem Pfad: "https://example.com/" + k mal "abcdefgh/"
fn baueUrl(k: int64): pchar {
  var puf: int64 := alloc(k * 9 + 64);
  var vor: pchar := "https://example.com/"c;
  var p: int64 := 0;
  var i: int64 := 0;
  while (i < 20) { poke8(puf + p, StrCharAt(vor, i)); p := p + 1; i := i + 1; }
  i := 0;
  while (i < k) {
    var j: int64 := 0;
    while (j < 8) { poke8(puf + p, 97 + j); p := p + 1; j := j + 1; }
    poke8(puf + p, 47); p := p + 1;
    i := i + 1;
  }
  poke8(puf + p, 0);
  return puf as pchar;
}

fn messe(k: int64): int64 {
  var u: pchar := baueUrl(k);
  var t0: int64 := NowUs() as int64;
  var w: int64 := 0;
  var summe: int64 := 0;
  while (w < 3) {
    summe := summe + StrLen(GetPath(u));          // Schleife ueber die ganze URL
    summe := summe + StrLen(GetHostname(u));      // Parse-Weg
    if (Equals(u, u)) { summe := summe + 1; }  // Zeichenvergleich ueber alles
    w := w + 1;
  }
  var t1: int64 := NowUs() as int64;
  if (summe < 1) { PrintStrLn("WERT_FALSCH"c); }
  return t1 - t0;
}

fn main(): int64 {
  var u: pchar := baueUrl(3);
  PrintStr("host="c);   PrintStrLn(GetHostname(u));
  PrintStr("pfadlen="c); PrintStrLn(IntToStr(StrLen(GetPath(u))));
  PrintStr("gleich="c);  if (Equals(u, u)) { PrintStrLn("ja"c); } else { PrintStrLn("nein"c); }

  var warm: int64 := messe(400);
  var klein: int64 := messe(800);
  var gross: int64 := messe(3200);
  PrintStr("klein_us="c); PrintStrLn(IntToStr(klein));
  PrintStr("gross_us="c); PrintStrLn(IntToStr(gross));
  return 0;
}
EOF

if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" sk.lyx -o sk ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
AUS="$( cd "$TMP" && timeout 300 ./sk 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc, Ausgabe: $(echo "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt und laeuft"
hol() { echo "$AUS" | sed -n "s/^$1=//p"; }

# 1. Werte: k = 3 ergibt "https://example.com/" + 3 x 9 Zeichen = Pfad "/abcdefgh/abcdefgh/abcdefgh/"
# `GetHostname` liefert einen ZEIGER IN DIE URL und schneidet nicht ab, gibt
# also "example.com/abcdefgh/..." zurueck. Das ist VORBESTEHEND und nicht
# Gegenstand dieser Aenderung: gegengeprueft gegen die installierte stdlib von
# vor #2352/#2364, die wortgleich dasselbe liefert. Als eigener Punkt
# gemeldet; hier wird deshalb der ANFANG geprueft, damit der Test nicht die
# Eigenart festschreibt und beim Beheben rot wird.
case "$(hol host)" in
  example.com*) ok "GetHostname beginnt mit example.com" ;;
  *) no "host" "'$(hol host)' beginnt nicht mit example.com" ;;
esac
if [ "$(hol pfadlen)" = "28" ]; then ok "Pfadlaenge = 28"; else no "pfadlen" "'$(hol pfadlen)' statt 28"; fi
if [ "$(hol gleich)" = "ja" ]; then ok "Equals(u, u) = ja"; else no "gleich" "'$(hol gleich)'"; fi
if echo "$AUS" | grep -q WERT_FALSCH; then no "Wert im Messlauf" "die Zerlegung lieferte im Messlauf nichts"; else ok "Wert auch im Messlauf stabil"; fi

# 2. Die Skalierung.
KL="$(hol klein_us)"; GR="$(hol gross_us)"
if [ -z "$KL" ] || [ -z "$GR" ]; then
  no "Messwerte" "klein='$KL' gross='$GR'"
elif [ "$KL" -lt 1 ]; then
  ok "vierfache Laenge unter der Messauflaesung (klein=${KL}us, gross=${GR}us)"
else
  V=$(( GR * 100 / KL ))
  if [ "$V" -lt 800 ]; then
    ok "vierfache Laenge kostet ${V}% (linear ~400%, quadratisch ~1600%)"
  else
    no "Skalierung" "vierfache Laenge kostet ${V}% (klein=${KL}us, gross=${GR}us) — ueber der Schwelle 800%, ein Zeichenzugriff bestimmt offenbar noch die Laenge selbst"
  fi
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
