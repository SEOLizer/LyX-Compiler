#!/usr/bin/env bash
# tests/strsafecharat_regex_2364_test.sh — #2364, Teil 2: Zeichenzugriff mit
# bekannter Laenge statt `StrSafeCharAt` in den Schleifen von std/regex.lyx.
#
# `StrSafeCharAt` bestimmt fuer seinen Bereichscheck die Laenge selbst
# (`StrLen`), ist also O(Laenge) JE ZEICHEN. In einer Schleife ueber den Text
# wird daraus quadratischer Aufwand. `std/regex.lyx` hatte 68 solche Aufrufe;
# die Textzugriffe in den Abgleichschleifen sind der beherrschende Posten.
#
# DER VERSUCHSAUFBAU MUSS DEN FALL ERZEUGEN (Lehre aus #2341): nicht jeder
# Regex-Lauf ist algorithmisch linear. Ein Suchlauf ohne Treffer probiert JEDE
# Startposition; kostet eine Position O(Resttext) — etwa `[0-9]+` auf Ziffern —
# ist der Lauf schon im Entwurf O(n^2) und bliebe auch nach der Umstellung
# quadratisch, als Sonde also unbrauchbar.
# BERICHTIGUNG (#2369): fuer ein EINZELNES Atom gilt das nicht. `[0-9]` auf
# lauter Buchstaben scheitert je Position nach O(1) Schritten, der Lauf ist
# linear — und war trotzdem quadratisch, weil `matchHere` je Position
# `StrLen` neu bestimmte. Diese Sonde steht in
# tests/strlen_je_aufruf_2369_test.sh.
# Gemessen wird deshalb ein Lauf, der algorithmisch EINEN Durchgang braucht:
# `[0-9]+` auf einen Text aus lauter Ziffern. Der gierige Teil laeuft einmal
# von vorn nach hinten durch; quadratisch ist daran allein der Zeichenzugriff.
# Beide Maschinen werden getrennt gemessen, weil sie getrennte Schleifen
# haben: der deutende Weg (`RegexSearchSpan` → `_reMatchIn`) und der
# uebersetzte (`RegexSearchCompiled` → `regexRunAt`).
#
# Ebenfalls NICHT als Sonde taugt `RegexCountMatches`: es ruft je Treffer
# `regexSearchFrom`, und das bestimmt `StrLen(text)` neu — ein Posten je
# AUFRUF, nicht je Zeichen, und von dieser Aenderung unberuehrt. Bei n
# Treffern bleibt das O(n^2). Eigener Punkt, hier bewusst ausgespart.
#
# Schwelle 800 %: deutlich ueber dem linearen Wert 400 und deutlich unter dem
# quadratischen 1600.
#
# DIE LAENGEN STAMMEN AUS EINER GEMESSENEN REIHE, nicht aus einem Paar (Lehre
# aus #2352). Am Stand vor der Umstellung, i5-8250U, taskset -c 2, ein Lauf je
# Groesse: 1600/3200/6400/12800/25600/51200 Ziffern kosteten deutend
# 349/946/2848/10254/35247/148885 us und uebersetzt
# 308/700/1821/5561/18555/77886 us. Die Faktoren je Verdopplung wachsen von
# 2,7 auf 4,2 — der quadratische Posten wird erst oberhalb von etwa 6000
# Zeichen beherrschend, unterhalb deckt ihn der lineare Aufwand des
# Abgleichs zu. Mit 800/3200 Zeichen lag das Verhaeltnis bei 820 % und waere
# damit knapp an der Schwelle entlanggelaufen; gemessen wird deshalb bei
# 6400 gegen 25600.

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

// Text aus k Ziffern, davor drei Buchstaben: "abc" + k mal '7'
fn baueText(k: int64): pchar {
  var puf: int64 := alloc(k + 8);
  poke8(puf + 0, 97); poke8(puf + 1, 98); poke8(puf + 2, 99);
  var i: int64 := 0;
  while (i < k) { poke8(puf + 3 + i, 55); i := i + 1; }
  poke8(puf + 3 + k, 0);
  return puf as pchar;
}

// Deutender Weg: ein gieriger Durchgang ueber alle Ziffern.
fn messeDeutend(k: int64): int64 {
  var t: pchar := baueText(k);
  var sz: int64 := alloc(8);
  var ez: int64 := alloc(8);
  var t0: int64 := NowUs() as int64;
  var w: int64 := 0;
  var summe: int64 := 0;
  while (w < 3) {
    if (RegexSearchSpan("[0-9]+"c, t, sz, ez)) { summe := summe + peek64(ez) - peek64(sz); }
    w := w + 1;
  }
  var t1: int64 := NowUs() as int64;
  if (summe != 3 * k) { PrintStrLn("WERT_FALSCH_DEUTEND"c); }
  return t1 - t0;
}

// Uebersetzter Weg: dieselbe Spanne, aber ueber regexRunAt.
fn messeUebersetzt(k: int64): int64 {
  var t: pchar := baueText(k);
  var prog: pchar := alloc(4096) as pchar;
  var pl: int64 := RegexCompile("[0-9]+"c, prog, 4096);
  if (pl < 1) { PrintStrLn("COMPILE_FEHLT"c); return 0; }
  var t0: int64 := NowUs() as int64;
  var w: int64 := 0;
  var summe: int64 := 0;
  while (w < 3) {
    summe := summe + RegexSearchCompiled(prog, pl, t);
    w := w + 1;
  }
  var t1: int64 := NowUs() as int64;
  if (summe != 9) { PrintStrLn("WERT_FALSCH_UEBERSETZT"c); }
  return t1 - t0;
}

fn main(): int64 {
  // 1. Werte zuerst — ohne sie misst der Rest Unsinn.
  var t: pchar := baueText(5);          // "abc77777"
  var sz: int64 := alloc(8);
  var ez: int64 := alloc(8);
  if (RegexSearchSpan("[0-9]+"c, t, sz, ez)) {
    PrintStr("span_von="c); PrintStrLn(IntToStr(peek64(sz)));
    PrintStr("span_bis="c); PrintStrLn(IntToStr(peek64(ez)));
  } else {
    PrintStrLn("span_von=KEINTREFFER"c);
  }
  PrintStr("such="c); PrintStrLn(IntToStr(RegexSearch("[0-9]+"c, t)));
  PrintStr("kein="c); PrintStrLn(IntToStr(RegexSearch("[xyz]+"c, t)));
  var prog: pchar := alloc(4096) as pchar;
  var pl: int64 := RegexCompile("[0-9]+"c, prog, 4096);
  PrintStr("comp="c); PrintStrLn(IntToStr(RegexSearchCompiled(prog, pl, t)));
  PrintStr("gruppe="c); PrintStrLn(IntToStr(RegexSearch("(ab)c"c, t)));

  // 2. Skalierung, je Maschine getrennt.
  var warm1: int64 := messeDeutend(1600);
  var kd: int64 := messeDeutend(6400);
  var gd: int64 := messeDeutend(25600);
  PrintStr("deut_klein_us="c); PrintStrLn(IntToStr(kd));
  PrintStr("deut_gross_us="c); PrintStrLn(IntToStr(gd));

  var warm2: int64 := messeUebersetzt(1600);
  var ku: int64 := messeUebersetzt(6400);
  var gu: int64 := messeUebersetzt(25600);
  PrintStr("ueb_klein_us="c); PrintStrLn(IntToStr(ku));
  PrintStr("ueb_gross_us="c); PrintStrLn(IntToStr(gu));
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

pruefe() { # $1 Name, $2 erwartet
  v="$(hol "$1")"
  if [ "$v" = "$2" ]; then ok "$1 = $2"; else no "$1" "'$v' statt $2"; fi
}
# "abc77777": Ziffern ab Index 3, Spanne [3,8)
pruefe span_von 3
pruefe span_bis 8
pruefe such 3
pruefe kein -1
pruefe comp 3
pruefe gruppe 0
if echo "$AUS" | grep -q WERT_FALSCH; then
  no "Wert im Messlauf" "$(echo "$AUS" | grep -m1 WERT_FALSCH) — der Messlauf trifft nicht die ganze Ziffernfolge"
else
  ok "Wert auch im Messlauf stabil (Spanne = ganze Ziffernfolge)"
fi
if echo "$AUS" | grep -q COMPILE_FEHLT; then no "RegexCompile" "lieferte keine Programmlaenge"; fi

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
      no "Skalierung $1" "vierfache Laenge kostet ${V}% (klein=${KL}us, gross=${GR}us) — ueber der Schwelle 800%, ein Zeichenzugriff bestimmt offenbar noch die Laenge selbst"
    fi
  fi
}
skal "deutend" "$(hol deut_klein_us)" "$(hol deut_gross_us)"
skal "uebersetzt" "$(hol ueb_klein_us)" "$(hol ueb_gross_us)"

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
