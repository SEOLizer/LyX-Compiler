#!/usr/bin/env bash
# tests/strlen_schleifen_2352_test.sh — #2352: die Laenge einer Zeichenkette
# gehoert vor die Schleife, nicht in ihre Bedingung.
#
# 15 Schleifen im Bestand bestimmten die Laenge je Durchlauf neu, 9 davon in
# std/url.lyx auf dem heissen Weg jeder URL-Zerlegung. Das macht die Schleife
# quadratisch in der Laenge.
#
# WAS DIESER TEST PRUEFT UND WARUM NICHT DAS NAHELIEGENDE. Ein Werttest waere
# vor der Aenderung GENAUSO GRUEN gewesen: die Fassung mit `StrLen` in der
# Bedingung rechnet richtig, nur langsam. Geprueft wird deshalb die
# SKALIERUNG — vervierfachte Laenge bei linearem Aufwand kostet etwa das
# Vierfache, bei quadratischem das Sechzehnfache. Das Verhaeltnis ist
# maschinenunabhaengiger als eine absolute Zeit, weil beide Messungen
# dieselbe Stoerung tragen.
#
# GEMESSEN auf 1.2.30A (i5-8250U, taskset), eigene Schleife mit und ohne
# vorgezogene Laenge, mit der SIMD-StrLen aus #2351:
#
#   n        Bedingung      vorgezogen   Faktor
#   4096        460 us          4 us      115x
#   16384      6508 us         14 us      465x
#   65536    117612 us         55 us     2138x
#   262144  2024158 us        202 us    10021x
#
# Die Vervierfachung kostete in der Bedingungsfassung 14,1x / 18,1x / 17,2x
# (quadratisch), vorgezogen 3,5x (linear). Bei 262144 Zeichen also zwei
# Sekunden statt zwei Zehntelmillisekunden.
#
# Die Schwelle unten ist 8: deutlich ueber dem linearen Wert 4 und deutlich
# unter dem gemessenen quadratischen 17. Ein Test, der knapp an 4 liegt, waere
# auf einer belasteten Maschine rot, ohne dass etwas kaputt ist.

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

// Eine Query-Zeichenkette aus k Paaren, der gesuchte Name steht am ENDE —
// so laeuft die Suche ueber die ganze Laenge und nicht nur ueber den Anfang.
fn baueQuery(k: int64): pchar {
  var puf: int64 := alloc(k * 10 + 32);
  var p: int64 := 0;
  var i: int64 := 0;
  while (i < k) {
    poke8(puf + p, 97); p := p + 1;           // 'a'
    poke8(puf + p, 61); p := p + 1;           // '='
    poke8(puf + p, 49); p := p + 1;           // '1'
    poke8(puf + p, 38); p := p + 1;           // '&'
    i := i + 1;
  }
  poke8(puf + p, 122); p := p + 1;            // 'z'
  poke8(puf + p, 61);  p := p + 1;            // '='
  poke8(puf + p, 55);  p := p + 1;            // '7'
  poke8(puf + p, 0);
  return puf as pchar;
}

fn messe(k: int64): int64 {
  var q: pchar := baueQuery(k);
  var t0: int64 := NowUs() as int64;
  var r: int64 := 0;
  var w: int64 := 0;
  while (w < 5) {
    var v: pchar := GetQueryParam(q, "z"c);
    r := r + StrLen(v);
    w := w + 1;
  }
  var t1: int64 := NowUs() as int64;
  if (r != 5) { PrintStrLn("WERT_FALSCH"c); }
  return t1 - t0;
}

fn main(): int64 {
  // Wert zuerst: die Zerlegung muss stimmen, sonst misst der Rest Unsinn.
  var q: pchar := baueQuery(200);
  PrintStr("wert_z="c);  PrintStrLn(GetQueryParam(q, "z"c));
  PrintStr("wert_a="c);  PrintStrLn(GetQueryParam(q, "a"c));
  PrintStr("wert_leer="c); PrintStrLn(GetQueryParam(q, "fehlt"c));

  // Aufwaermen, damit der erste Lauf nicht die Seitenfehler aller anderen traegt.
  var warm: int64 := messe(500);
  var klein: int64 := messe(1000);
  var gross: int64 := messe(4000);
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

# 1. Der Wert. Ohne ihn misst der Rest Unsinn.
if [ "$(hol wert_z)" = "7" ]; then ok "GetQueryParam(z) = 7"; else no "wert_z" "'$(hol wert_z)' statt 7"; fi
if [ "$(hol wert_a)" = "1" ]; then ok "GetQueryParam(a) = 1"; else no "wert_a" "'$(hol wert_a)' statt 1"; fi
if [ -z "$(hol wert_leer)" ]; then ok "GetQueryParam(fehlt) ist leer"; else no "wert_leer" "'$(hol wert_leer)' statt leer"; fi
if echo "$AUS" | grep -q WERT_FALSCH; then no "Wert im Messlauf" "GetQueryParam lieferte in der Messschleife etwas anderes"; else ok "Wert auch im Messlauf stabil"; fi

# 2. Die Skalierung. Das ist die eigentliche Aussage.
KL="$(hol klein_us)"; GR="$(hol gross_us)"
if [ -z "$KL" ] || [ -z "$GR" ]; then
  no "Messwerte" "klein='$KL' gross='$GR'"
elif [ "$KL" -lt 1 ]; then
  # Zu schnell zum Verhaeltnisbilden: dann ist der quadratische Term ohnehin weg.
  ok "vierfache Laenge unter der Messauflaesung (klein=${KL}us, gross=${GR}us)"
else
  V=$(( GR * 100 / KL ))
  if [ "$V" -lt 800 ]; then
    ok "vierfache Laenge kostet ${V}% (linear ~400%, quadratisch ~1600%)"
  else
    no "Skalierung" "vierfache Laenge kostet ${V}% (klein=${KL}us, gross=${GR}us) — ueber der Schwelle 800%, die Laenge wird offenbar je Durchlauf neu bestimmt"
  fi
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
