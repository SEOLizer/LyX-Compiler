#!/usr/bin/env bash
# tests/strlen_je_aufruf_2369_test.sh — #2369: Laengen DURCHREICHEN statt sie
# je Aufruf neu zu bestimmen (std/regex.lyx).
#
# #2364 hat den Posten JE ZEICHEN beseitigt (`StrSafeCharAt` bestimmte seine
# Bereichsgrenze selbst). Uebrig blieb ein Posten JE AUFRUF: `matchHere`,
# `_reMatchIn` und `regexSearchFrom` bestimmten bei jedem Aufruf erneut
# `StrLen(pattern)` und `StrLen(text)`. Diese Funktionen laufen
#
#   * je Startposition der Suche      (regexSearchFrom -> matchHere)
#   * je Rekursionsebene              (_reMatchIn ruft sich selbst)
#   * je Treffer                      (RegexCountMatches, RegexReplaceInto,
#                                      RegexFindAll rufen regexSearchFrom)
#
# womit aus einem O(Laenge)-Posten je Aufruf wieder quadratischer Aufwand wird.
#
# ZWEI SONDEN, weil es zwei verschiedene Vervielfacher sind:
#
#   suche   `[0-9]` auf lauter Buchstaben — KEIN Treffer. Jede der n
#           Startpositionen scheitert nach O(1) Atomschritten, der Lauf ist
#           also algorithmisch linear; quadratisch war daran allein das StrLen
#           je Aufruf. (Berichtigung zur Begruendung in
#           tests/strsafecharat_regex_2364_test.sh: dort steht, ein Suchlauf
#           ohne Treffer sei "schon im Entwurf quadratisch". Das gilt nur fuer
#           Muster, deren Arbeit je Position mit dem Resttext waechst, etwa
#           `[0-9]+` auf Ziffern — nicht fuer ein einzelnes Atom.)
#
#   zaehlen `[0-9]` auf lauter Ziffern — n Treffer, also n Aufrufe von
#           regexSearchFrom und matchHere. Je Aufruf vorher ein StrLen ueber
#           den ganzen Text.
#
# GEPRUEFT WIRD DIE SKALIERUNG: die alte Fassung rechnet richtig, nur langsam.
# Vervierfachte Laenge kostet linear etwa das Vierfache, quadratisch das
# Sechzehnfache. Gemessen am Stand vor der Aenderung (i5-8250U, taskset -c 2),
# 16000 gegen 64000 Zeichen: suche 9249 -> 130360 us = 1409 %, zaehlen
# 37506 -> 593762 us = 1583 %. Danach 2753 -> 11110 = 404 % und
# 5457 -> 22649 = 415 %. Schwelle 800 %: deutlich ueber dem linearen Wert und
# deutlich unter dem quadratischen.
#
# Die Laengen stammen aus einer Reihe ueber sieben Groessen, nicht aus einem
# Paar: bei 4000 gegen 16000 lag die suche-Sonde bei 770 % und waere unter der
# Schwelle geblieben, obwohl der Posten da war.
#
# Je Groesse wird der MEDIAN AUS DREI MESSUNGEN genommen. Mit einer einzelnen
# Messung streute das Verhaeltnis zwischen 209 % und 490 % und kippte im
# Vollauf auf 819 % — der Test war damit von der Last der Maschine abhaengig,
# nicht vom Code.
#
# Die WERTE werden zuerst geprueft, sonst misst der Rest Unsinn.

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
import std.regex;

fn baueBuchstaben(k: int64): pchar {
  var puf: int64 := alloc(k + 8);
  var i: int64 := 0;
  while (i < k) { poke8(puf + i, 97 + (i % 26)); i := i + 1; }
  poke8(puf + k, 0);
  return puf as pchar;
}

fn baueZiffern(k: int64): pchar {
  var puf: int64 := alloc(k + 8);
  var i: int64 := 0;
  while (i < k) { poke8(puf + i, 55); i := i + 1; }
  poke8(puf + k, 0);
  return puf as pchar;
}

// #2369: MEDIAN AUS DREI MESSUNGEN je Groesse. Eine Einzelmessung streute
// zwischen 209 % und 490 % und kippte im Vollauf (make test, belastete
// Maschine) auf 819 % — ueber die Schwelle, ohne dass etwas kaputt war. Der
// Median von drei Laeufen ist gegen einen einzelnen Ausschlag unempfindlich,
// und die Reihenfolge klein/gross wechselt dabei nicht: beide Groessen tragen
// dieselbe Stoerung.
fn median3(a: int64, b: int64, c: int64): int64 {
  if (a > b) { var t: int64 := a; a := b; b := t; }
  if (b > c) { var t2: int64 := b; b := c; c := t2; }
  if (a > b) { var t3: int64 := a; a := b; b := t3; }
  return b;
}

// Der Text wird EINMAL je Groesse gebaut und dann mehrfach durchsucht. Die
// Allokation gehoerte sonst zur Messung: std/alloc.lyx mappt je Allokation,
// und bei der kleinen Groesse ueberwog dieser Posten das Gemessene so stark,
// dass das Verhaeltnis auf 200 % fiel — UNTER den linearen Wert 400 %, was
// nicht sein kann. Ein Messwert, der unter der eigenen Untergrenze liegt,
// misst etwas anderes als gemeint.
fn messeSucheN(t: pchar, k: int64, mal: int64): int64 {
  var t0: int64 := NowUs() as int64;
  var w: int64 := 0;
  while (w < mal) {
    if (RegexSearch("[0-9]"c, t) != 0 - 1) { PrintStrLn("WERT_FALSCH_SUCHE"c); }
    w := w + 1;
  }
  return (NowUs() as int64) - t0;
}

fn messeZaehlenN(t: pchar, k: int64, mal: int64): int64 {
  var t0: int64 := NowUs() as int64;
  var w: int64 := 0;
  while (w < mal) {
    if (RegexCountMatches("[0-9]"c, t) != k) { PrintStrLn("WERT_FALSCH_ZAEHLEN"c); }
    w := w + 1;
  }
  return (NowUs() as int64) - t0;
}

fn main(): int64 {
  // 1. Werte zuerst, an kurzen Eingaben mit gegengerechneter Erwartung.
  var bu: pchar := baueBuchstaben(10);                 // "abcdefghij"
  var zi: pchar := baueZiffern(10);                    // "7777777777"
  PrintStr("kein="c);    PrintStrLn(IntToStr(RegexSearch("[0-9]"c, bu)));
  PrintStr("treffer="c); PrintStrLn(IntToStr(RegexSearch("[0-9]"c, zi)));
  PrintStr("anzahl="c);  PrintStrLn(IntToStr(RegexCountMatches("[0-9]"c, zi)));
  PrintStr("anzahl2="c); PrintStrLn(IntToStr(RegexCountMatches("[0-9][0-9]"c, zi)));
  PrintStr("gemischt="c);PrintStrLn(IntToStr(RegexSearch("[0-9]"c, "abc7def"c)));
  PrintStr("anker="c);   PrintStrLn(IntToStr(RegexSearch("^[0-9]"c, "abc7"c)));
  PrintStr("gruppe="c);  PrintStrLn(IntToStr(RegexSearch("(ab)+c"c, "zzababc"c)));
  var sz: int64 := alloc(8);
  var ez: int64 := alloc(8);
  if (RegexSearchSpan("[0-9]+"c, "abc777z"c, sz, ez)) {
    PrintStr("span="c); PrintStr(IntToStr(peek64(sz))); PrintStr(","c); PrintStrLn(IntToStr(peek64(ez)));
  } else {
    PrintStrLn("span=KEINTREFFER"c);
  }

  // 2. Skalierung, je Sonde getrennt.
  // Beide Groessen tragen GLEICH VIELE Wiederholungen — eine ungleiche Zahl
  // wuerde das Verhaeltnis selbst verschieben.
  var bk: pchar := baueBuchstaben(16000);
  var bg: pchar := baueBuchstaben(64000);
  var zk: pchar := baueZiffern(16000);
  var zg: pchar := baueZiffern(64000);
  var warm: int64 := messeSucheN(bk, 16000, 1) + messeZaehlenN(zk, 16000, 1);
  var ks: int64 := median3(messeSucheN(bk, 16000, 5), messeSucheN(bk, 16000, 5), messeSucheN(bk, 16000, 5));
  var gs: int64 := median3(messeSucheN(bg, 64000, 5), messeSucheN(bg, 64000, 5), messeSucheN(bg, 64000, 5));
  var kz: int64 := median3(messeZaehlenN(zk, 16000, 5), messeZaehlenN(zk, 16000, 5), messeZaehlenN(zk, 16000, 5));
  var gz: int64 := median3(messeZaehlenN(zg, 64000, 5), messeZaehlenN(zg, 64000, 5), messeZaehlenN(zg, 64000, 5));
  PrintStr("suche_klein_us="c);   PrintStrLn(IntToStr(ks));
  PrintStr("suche_gross_us="c);   PrintStrLn(IntToStr(gs));
  PrintStr("zaehlen_klein_us="c); PrintStrLn(IntToStr(kz));
  PrintStr("zaehlen_gross_us="c); PrintStrLn(IntToStr(gz));
  return 0;
}
EOF

if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" sk.lyx -o sk ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
AUS="$( cd "$TMP" && timeout 600 ./sk 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc, Ausgabe: $(echo "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt und laeuft"
hol() { echo "$AUS" | sed -n "s/^$1=//p"; }

pruefe() { v="$(hol "$1")"; if [ "$v" = "$2" ]; then ok "$1 = $2"; else no "$1" "'$v' statt $2"; fi; }
pruefe kein -1          # keine Ziffer in "abcdefghij"
pruefe treffer 0        # "7777777777" trifft an Position 0
pruefe anzahl 10        # zehn einstellige Treffer
pruefe anzahl2 5        # zweistellig: fuenf nicht ueberlappende Treffer
pruefe gemischt 3       # "abc7def" — die 7 steht an Index 3
pruefe anker -1         # `^[0-9]` darf in "abc7" NICHT greifen (#1313)
pruefe gruppe 2         # "zzababc": `(ab)+c` beginnt bei Index 2
pruefe span 3,6         # "abc777z": Ziffern in [3,6)
if echo "$AUS" | grep -q WERT_FALSCH; then
  no "Wert im Messlauf" "$(echo "$AUS" | grep -m1 WERT_FALSCH)"
else
  ok "Werte auch in den Messlaeufen stabil"
fi

skal() { # $1 Name, $2 klein, $3 gross
  KL="$2"; GR="$3"
  if [ -z "$KL" ] || [ -z "$GR" ]; then
    no "Messwerte $1" "klein='$KL' gross='$GR'"
  elif [ "$KL" -lt 1 ]; then
    ok "$1: vierfache Laenge unter der Messaufloesung (klein=${KL}us, gross=${GR}us)"
  else
    V=$(( GR * 100 / KL ))
    if [ "$V" -lt 800 ]; then
      ok "$1: vierfache Laenge kostet ${V}% (linear ~400%, quadratisch ~1600%)"
    else
      no "Skalierung $1" "vierfache Laenge kostet ${V}% (klein=${KL}us, gross=${GR}us) — ueber der Schwelle 800%, eine Laenge wird offenbar noch je Aufruf neu bestimmt"
    fi
  fi
}
skal "suche"   "$(hol suche_klein_us)"   "$(hol suche_gross_us)"
skal "zaehlen" "$(hol zaehlen_klein_us)" "$(hol zaehlen_gross_us)"

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
