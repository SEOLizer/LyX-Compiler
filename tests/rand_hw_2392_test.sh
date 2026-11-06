#!/usr/bin/env bash
# tests/rand_hw_2392_test.sh — RDRAND/RDSEED als ZUSATZ-Entropie (#2392).
#
# std/crypto/rand.lyx nutzte ausschliesslich getrandom(2). Neu sind
# RandHwRdrand/RandHwRdseed und das Einmischen in RandBytesExact.
#
# Die Rolle ist festgelegt und wird hier geprueft: **getrandom bleibt die
# Quelle**, die Hardwarewoerter kommen per XOR HINZU. Darum sind die
# Prueffragen andere als bei einem Zufallstest:
#
#   1. Der Rueckgabewert ist der ERFOLG, nicht der Wert. Ein Wert allein ist
#      nicht von "der Befehl lieferte nichts" zu unterscheiden — genau der
#      stille Default, der bei einer Zufallsquelle vorhersagbare Bytes heisst.
#   2. Die Befehle stehen im Erzeugnis (48 0F C7 F0 / F8) — sonst waere gruen
#      auch ohne jede Hardwareinstruktion erreichbar.
#   3. Beide Wege liefern die geforderte Laenge: mit Einmischen und ohne
#      (RandHwMischen(0)), kurze Anforderungen mit Schwanz unter acht Byte
#      inbegriffen. Ohne diesen Schalter waere der Weg ohne Hardwarequelle auf
#      dieser CPU nicht erreichbar (#1823).
#   4. Der Beitrag ist WIRKSAM: mit einem festgehaltenen getrandom-Teil laesst
#      sich das nicht direkt messen, aber der Befehl liefert in 1000 Aufrufen
#      verschiedene Woerter — ein festklemmender Generator (immer derselbe
#      Wert, immer 0) faellt damit auf.
#   5. Was NICHT geprueft werden kann: die statistische Qualitaet. Dafuer ist
#      dieser Test der falsche Ort — und eine Pruefung "sieht zufaellig aus"
#      waere ein Invariantentest, der jahrelang einen echten Defekt verdeckt
#      (#1829).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

bytefolge() { python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read()
m = bytes.fromhex(sys.argv[2])
n = 0; i = d.find(m)
while i >= 0:
    n += 1; i = d.find(m, i + 1)
print(n)" "$1" "$2"; }

cat > "$TMP/r.lyx" <<'EOF'
unit main;
import std.io;
import std.alloc;
import std.cpu.features;
import std.crypto.rand;

fn main(): int64 {
  PrintStr("rdrand_bit="c); PrintLn(CpuHasRDRAND());
  PrintStr("rdseed_bit="c); PrintLn(CpuHasRDSEED());
  PrintStr("hw="c);         PrintLn(RandHwVorhanden());

  var w: int64 := alloc(8);
  var erfolge: int64 := 0;
  var verschieden: int64 := 0;
  var nullen: int64 := 0;
  var vor: int64 := 0;
  var i: int64 := 0;
  while (i < 1000) {
    if (RandHwRdrand(w) != 0) {
      erfolge := erfolge + 1;
      if (peek64(w) == 0) { nullen := nullen + 1; }
      if (i > 0 && peek64(w) != vor) { verschieden := verschieden + 1; }
      vor := peek64(w);
    }
    i := i + 1;
  }
  PrintStr("rdrand_erfolge="c);    PrintLn(erfolge);
  PrintStr("rdrand_verschieden="c); PrintLn(verschieden);
  PrintStr("rdrand_nullen="c);     PrintLn(nullen);

  var seedErfolge: int64 := 0;
  i := 0;
  while (i < 100) { if (RandHwRdseed(w) != 0) { seedErfolge := seedErfolge + 1; } i := i + 1; }
  PrintStr("rdseed_erfolge="c); PrintLn(seedErfolge);

  // Beide Wege: mit und ohne Einmischen, lange und kurze Anforderung.
  var buf: int64 := alloc(64);
  RandHwMischen(0);
  PrintStr("ohne_32="c); PrintLn(RandBytesExact(buf, 32));
  PrintStr("ohne_12="c); PrintLn(RandBytesExact(buf, 12));
  RandHwMischen(1);
  PrintStr("mit_32="c);  PrintLn(RandBytesExact(buf, 32));
  PrintStr("mit_12="c);  PrintLn(RandBytesExact(buf, 12));
  PrintStr("mit_1="c);   PrintLn(RandBytesExact(buf, 1));
  PrintStr("mit_64="c);  PrintLn(RandBytesExact(buf, 64));

  // Die Hauptquelle bleibt laut: RandInt64 bricht bei getrandom-Fehler ab
  // (hier nur belegt, dass sie im Normalfall einen Wert liefert).
  var v: int64 := RandInt64();
  var w2: int64 := RandInt64();
  PrintStr("int64_verschieden="c);
  if (v != w2) { PrintLn(1); } else { PrintLn(0); }
  return 0;
}
EOF

if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

AUS="$( cd "$TMP" && timeout 120 ./r 2>&1 )"; rc=$?
hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc — $(printf '%s' "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi

if [ "$(hol rdrand_bit)" = "1" ]; then
  ok "diese CPU hat RDRAND — die Befehle werden wirklich ausgefuehrt"
  [ "$(hol hw)" = "1" ] && ok "RandHwVorhanden() meldet die Faehigkeit" \
    || no "RandHwVorhanden" "'$(hol hw)' trotz gesetztem CPUID-Bit"
  E="$(hol rdrand_erfolge)"
  if [ "${E:-0}" -ge 990 ]; then ok "RDRAND: $E von 1000 Aufrufen erfolgreich"
  else no "RDRAND-Erfolgsrate" "$E von 1000 — bei zehn Versuchen je Aufruf ist das zu wenig"; fi
  V="$(hol rdrand_verschieden)"
  if [ "${V:-0}" -ge 990 ]; then ok "$V aufeinanderfolgende Werte verschieden (kein festklemmender Generator)"
  else no "RDRAND-Werte" "nur $V von 999 verschieden"; fi
  [ "$(hol rdrand_nullen)" = "0" ] && ok "kein einziger Erfolg mit Wert 0" \
    || no "RDRAND-Nullen" "$(hol rdrand_nullen) Erfolge lieferten 0 — der Fehlschlagwert"
else
  echo "HINWEIS: diese CPU hat kein RDRAND. Die Erfolgs- und Wertpruefungen"
  echo "         entfallen; auf einer CPU mit RDRAND gegenmessen."
  [ "$(hol hw)" = "0" ] && ok "ohne CPUID-Bit meldet RandHwVorhanden() 0" \
    || no "RandHwVorhanden" "meldet 1 ohne CPUID-Bit"
fi

if [ "$(hol rdseed_bit)" = "1" ]; then
  S="$(hol rdseed_erfolge)"
  if [ "${S:-0}" -ge 90 ]; then ok "RDSEED: $S von 100 Aufrufen erfolgreich"
  else no "RDSEED-Erfolgsrate" "$S von 100"; fi
else
  echo "HINWEIS: kein RDSEED auf dieser CPU (RDRAND ohne RDSEED gibt es, z. B. Ivy Bridge)."
fi

for p in "ohne_32:32" "ohne_12:12" "mit_32:32" "mit_12:12" "mit_1:1" "mit_64:64"; do
  n="${p%%:*}"; w="${p#*:}"
  if [ "$(hol "$n")" = "$w" ]; then ok "$n liefert $w Byte"
  else no "$n" "'$(hol "$n")' statt $w"; fi
done

[ "$(hol int64_verschieden)" = "1" ] && ok "zwei RandInt64 sind verschieden" \
  || no "RandInt64" "zweimal derselbe Wert"

RD="$(bytefolge "$TMP/r" 480fc7f0)"
SD="$(bytefolge "$TMP/r" 480fc7f8)"
if [ "$RD" -ge 1 ]; then ok "Erzeugnis enthaelt RDRAND (48 0F C7 F0), $RD mal"
else no "RDRAND im Erzeugnis" "$RD Vorkommen"; fi
if [ "$SD" -ge 1 ]; then ok "Erzeugnis enthaelt RDSEED (48 0F C7 F8), $SD mal"
else no "RDSEED im Erzeugnis" "$SD Vorkommen"; fi

# Die Rolle muss im Quelltext festgeschrieben bleiben: getrandom ist die
# Quelle, die Hardware mischt per XOR ein. Ein spaeterer Umbau, der RDRAND
# zur Quelle macht, soll hier auffallen.
if grep -q "sys_getrandom" "$ROOT/std/crypto/rand.lyx" && grep -q '\^ peek64(hw)' "$ROOT/std/crypto/rand.lyx"; then
  ok "getrandom bleibt die Quelle, die Hardware wird per XOR eingemischt"
else
  no "Rolle" "entweder getrandom oder das XOR-Einmischen fehlt in std/crypto/rand.lyx"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
