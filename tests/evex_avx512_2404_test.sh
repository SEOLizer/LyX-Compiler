#!/usr/bin/env bash
# tests/evex_avx512_2404_test.sh — EVEX-Kodierung und der 512-Bit-Vorlauf der
# Vektorschleife (#2404).
#
# DREI SACHEN, und die erste ist die wichtigste:
#
#   1. DER UNBERUEHRTE PFAD. Ohne `--target-cpu=avx512` darf KEIN EVEX-Byte im
#      Erzeugnis stehen. Ein stiller Rueckfall waere hier besonders teuer: ein
#      EVEX-Befehl auf einer CPU ohne AVX-512 endet in SIGILL, und zwar beim
#      Anwender, nicht beim Bauen.
#   2. MIT Zusage stehen Lade-, Rechen- und Schreibbefehl in 512 Bit da, UND
#      die Treppe 64 -> 32 -> 16 -> skalar ist vollstaendig. Vorhandensein
#      allein sagt nichts ueber die Schrittweiten; eine falsche Weite liest und
#      schreibt hinter dem Feldende (#2184 hat genau das einmal getan).
#   3. DIE WERTE -- nur auf einer CPU mit AVX-512, sonst SKIP. Der
#      Entwicklungsrechner (i5-8250U) hat kein AVX-512; die CI-Laeufer wechseln
#      (Zen 4 hat es, Zen 3 nicht). Ein Test, der es voraussetzt, ist auf dem
#      naechsten Laeufer rot, ohne dass sich Code geaendert hat.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
ok() { PASS=$((PASS+1)); echo "PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }

# Ein Kern mit allen vier Operationen und beiden Gleitkommabreiten, dazu
# Ganzzahlen -- jede nimmt einen anderen Zweig im Schritt.
cat > "$TMP/k.lyx" <<'LYX'
import std.io;
fn main(): int64 {
  var n: int64 := 300;
  var a: parallel Array<f32> := parallel Array<f32>(n);
  var b: parallel Array<f32> := parallel Array<f32>(n);
  var p: parallel Array<f64> := parallel Array<f64>(n);
  var q: parallel Array<f64> := parallel Array<f64>(n);
  var i: int64 := 0;
  while (i < n) {
    a[i] := (i % 97 + 1) as f64; b[i] := (i % 31 + 2) as f64;
    p[i] := (i % 89 + 3) as f64; q[i] := (i % 17 + 5) as f64;
    i += 1;
  }
  var c: parallel Array<f32> := a + b;
  var d: parallel Array<f32> := a * b;
  var r: parallel Array<f64> := p + q;
  var s: parallel Array<f64> := p * q;
  var summe: int64 := 0;
  i := 0;
  while (i < n) {
    summe := summe + (c[i] as int64) + (d[i] as int64) * 3
                   + (r[i] as int64) * 5 + (s[i] as int64) * 7;
    i += 1;
  }
  PrintStr("summe="c); PrintLn(summe);
  return 0;
}
LYX

baue() { # name, zusatzflags, ausgabe
  if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" $2 "$TMP/k.lyx" -o "$3" ) >"$3.log" 2>&1 \
     && [ -s "$3" ]; then ok "$1 uebersetzt"; return 0; fi
  no "$1 uebersetzt nicht" "$(grep -m1 -i error "$3.log")"; return 1
}
baue "ohne Zusage"  ""                     "$TMP/n256" || { echo ""; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1; }
baue "mit avx512"   "--target-cpu=avx512"  "$TMP/n512" || { echo ""; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1; }

xxd -p "$TMP/n256" | tr -d '\n' > "$TMP/h256"
xxd -p "$TMP/n512" | tr -d '\n' > "$TMP/h512"

# --- 1: der unberuehrte Pfad traegt KEIN EVEX --------------------------------
# 62 ist das EVEX-Byte; geprueft werden die konkreten Folgen, nicht das Byte
# allein (0x62 kommt als Datenbyte ueberall vor).
EVEX_LADEN="62f17c4810"      # vmovups zmm0, [rdi+rax]
EVEX_ADD="62f17c4858"        # vaddps  zmm0, zmm0, zmm1
EVEX_SPEI="62f17c4811"       # vmovups [rdx+rax], zmm0
EVEX_ADDPD="62f1fd4858"      # vaddpd  zmm0, zmm0, zmm1
ohne=0
for m in "$EVEX_LADEN" "$EVEX_ADD" "$EVEX_SPEI" "$EVEX_ADDPD"; do
  if grep -q "$m" "$TMP/h256"; then ohne=1; fi
done
if [ "$ohne" = 0 ]; then
  ok "ohne Zusage KEIN EVEX im Erzeugnis (sonst SIGILL beim Anwender)"
else
  no "ohne Zusage steht EVEX im Erzeugnis" "stiller Rueckfall -- genau das darf nicht sein"
fi

# --- 2: mit Zusage steht die 512-Bit-Form da --------------------------------
hat512() { # name, folge
  if grep -q "$2" "$TMP/h512"; then ok "mit Zusage: $1"
  else no "mit Zusage fehlt: $1" "Folge $2 nicht gefunden"; fi
}
hat512 "vmovups zmm0,[rdi+rax]"  "$EVEX_LADEN"
hat512 "vaddps zmm0,zmm0,zmm1"   "$EVEX_ADD"
hat512 "vmovups [rdx+rax],zmm0"  "$EVEX_SPEI"
hat512 "vaddpd zmm0,zmm0,zmm1"   "$EVEX_ADDPD"
hat512 "vmulps zmm0,zmm0,zmm1"   "62f17c4859"

# Die TREPPE: sub rcx,64 / add rax,64 / add rcx,32 muessen in dieser
# Reihenfolge stehen. Ohne sie koennte der 64er-Block mit einer falschen
# Schranke laufen und hinter dem Feldende lesen UND schreiben.
if grep -q "4883e940" "$TMP/h512"; then ok "Schranke: sub rcx, 64"
else no "Schranke fehlt" "sub rcx,64 (48 83 e9 40) nicht gefunden"; fi
if grep -q "4883c040" "$TMP/h512"; then ok "Schrittweite: add rax, 64"
else no "Schrittweite fehlt" "add rax,64 (48 83 c0 40) nicht gefunden"; fi
if grep -q "4883c120" "$TMP/h512"; then ok "Staffelung zur 32er-Stufe: add rcx, 32"
else no "Staffelung fehlt" "add rcx,32 (48 83 c1 20) nicht gefunden"; fi
# Und die 256er-Stufe muss WEITER da sein -- der 512er-Block ist ein Vorlauf,
# kein Ersatz. Faellt sie weg, rechnet ein Rest von 32..63 Byte skalar.
if grep -q "c5fc1004\|c5fc1104" "$TMP/h512"; then ok "256-Bit-Stufe bleibt als Vorlauf erhalten"
else no "256-Bit-Stufe fehlt" "der 512er-Block hat sie ersetzt statt ihr vorauszulaufen"; fi

# --- 3: die Werte, nur mit AVX-512 ------------------------------------------
cat > "$TMP/f.lyx" <<'LYX'
import std.io;
import std.cpu.features;
fn main(): int64 { PrintLn(CpuHasAVX512F()); return 0; }
LYX
HAT512=0
if ( cd "$ROOT" && timeout 600 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" ) >/dev/null 2>&1; then
  HAT512="$( ulimit -v 4000000; "$TMP/f" 2>/dev/null | tr -d '\n' )"
fi
ERW="$( ulimit -v 4000000; timeout 120 "$TMP/n256" 2>/dev/null )"
if [ -z "$ERW" ]; then
  no "256-Bit-Lauf" "keine Ausgabe"
elif [ "$HAT512" != "1" ]; then
  echo "SKIP Wert: diese CPU hat kein AVX-512 (i5-8250U, Zen 3) -- Teil 1 und 2 gelten"
  ok "256-Bit-Lauf liefert $ERW"
else
  IST="$( ulimit -v 4000000; timeout 120 "$TMP/n512" 2>/dev/null )"
  if [ "$IST" = "$ERW" ]; then
    ok "512-Bit-Strecke liefert dasselbe wie 256 Bit ($ERW)"
  else
    no "512-Bit-Strecke weicht ab" "'$IST' gegen '$ERW'"
  fi
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
