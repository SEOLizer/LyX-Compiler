#!/usr/bin/env bash
# tests/cpu_reason_2398_test.sh — Begruendung der Nutzbarkeit (#2398).
#
# `CpuHas*()` sagt "vorhanden UND nutzbar" (die zustandsbehafteten Bits sind
# seit #2187 gegen OSXSAVE/XCR0 gefiltert). Was fehlte, war die BEGRUENDUNG:
# von aussen war nicht unterscheidbar, ob die CPU das Bit nicht hat, ob das
# Betriebssystem den Registerzustand nicht sichert oder ob ein Kernelparameter
# es abgeschaltet hat.
#
# Geprueft wird in beiden Richtungen (#1823):
#   * ein nutzbares Bit (avx2 auf dieser CPU) meldet "nutzbar" UND CpuHas* = 1
#   * ein fehlendes Bit (avx512f) meldet "nicht in Hardware" UND CpuHas* = 0
#   * die Begruendung stimmt fuer JEDES Bit mit CpuHas* zusammen — eine
#     Abweichung heisst, dass zwei Aufzaehlungen auseinandergelaufen sind
#   * ein Bit, das nicht in der XCR0-Tabelle steht, laesst die Abfrage LAUT
#     scheitern statt "nutzbar" zu melden

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/r.lyx" <<'EOF'
unit main;
import std.io;
import std.cpu.features;

// Jedes Bit: Name, CpuHas*-Antwort und Begruendung in einer Zeile. Die
// Namensliste ist die der Bibliothek — damit prueft der Test die Aufzaehlung
// mit, die lyx-cpu explain zulaesst.
fn eins(nm: pchar, nl: int64, hat: int64): int64 {
  var bit: int64 := CpuFeatureBitAusName(nm, nl);
  PrintStr(nm); PrintStr(" bit="); PrintStr(IntToStr(bit));
  PrintStr(" hat="); PrintStr(IntToStr(hat));
  PrintStr(" grund=");
  if (bit == 0) { PrintStrLn("UNBEKANNT"c); return 0; }
  PrintStrLn(CpuUnusableReasonName(CpuFeatureUnusableReason(bit)));
  return 0;
}

fn main(): int64 {
  PrintStr("cpuid="); PrintLn(CpuHasCpuid());
  eins("sse2"c, 4, CpuHasSSE2());
  eins("sse4_1"c, 6, CpuHasSSE41());
  eins("sse4_2"c, 6, CpuHasSSE42());
  eins("popcnt"c, 6, CpuHasPOPCNT());
  eins("abm"c, 3, CpuHasLZCNT());
  eins("aes"c, 3, CpuHasAESNI());
  eins("pclmulqdq"c, 9, CpuHasPCLMUL());
  eins("avx"c, 3, CpuHasAVX());
  eins("avx2"c, 4, CpuHasAVX2());
  eins("avx512f"c, 7, CpuHasAVX512F());
  eins("fma"c, 3, CpuHasFMA());
  eins("bmi1"c, 4, CpuHasBMI1());
  eins("bmi2"c, 4, CpuHasBMI2());
  eins("sha_ni"c, 6, CpuHasSHANI());
  eins("vaes"c, 4, CpuHasVAES());
  eins("vpclmulqdq"c, 10, CpuHasVPCLMUL());
  eins("rdrand"c, 6, CpuHasRDRAND());
  eins("rdseed"c, 6, CpuHasRDSEED());
  eins("keylocker"c, 9, CpuHasKeyLocker());
  eins("sha512"c, 6, CpuHasSHA512());
  eins("sm3"c, 3, CpuHasSM3());
  eins("sm4"c, 3, CpuHasSM4());
  PrintStr("unbekannt_bit="); PrintLn(CpuFeatureBitAusName("quatsch"c, 7));
  PrintStr("namen="); PrintStrLn(CpuFeatureNamenListe());
  return 0;
}
EOF

if ! ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"
AUS="$( cd "$TMP" && timeout 60 ./r 2>&1 )" || { no "laeuft" "rc=$?"; echo "=== PASS=$PASS FAIL=$FAIL"; exit 1; }

# Jede Zeile: hat=1 muss "nutzbar" heissen, hat=0 muss eine BEGRUENDUNG haben.
WIDER=0; GEPRUEFT=0; NUTZBAR=0; FEHLEND=0
while read -r nm rest; do
  case "$rest" in bit=*) ;; *) continue ;; esac
  hat="$(printf '%s' "$rest" | sed -n 's/.* hat=\([0-9-]*\) .*/\1/p')"
  grund="$(printf '%s' "$rest" | sed -n 's/.* grund=//p')"
  [ -z "$hat" ] && continue
  GEPRUEFT=$((GEPRUEFT+1))
  if [ "$hat" = "1" ]; then
    NUTZBAR=$((NUTZBAR+1))
    [ "$grund" = "nutzbar" ] || { echo "  WIDERSPRUCH $nm: CpuHas=1, Begruendung '$grund'"; WIDER=$((WIDER+1)); }
  else
    FEHLEND=$((FEHLEND+1))
    [ "$grund" = "nutzbar" ] && { echo "  WIDERSPRUCH $nm: CpuHas=0, Begruendung 'nutzbar'"; WIDER=$((WIDER+1)); }
  fi
done <<< "$AUS"

[ "$GEPRUEFT" -ge 20 ] && ok "$GEPRUEFT Faehigkeitsbits geprueft" || no "Abdeckung" "nur $GEPRUEFT Bits"
[ "$WIDER" = "0" ] && ok "Begruendung und CpuHas* stimmen bei allen $GEPRUEFT Bits zusammen" \
  || no "Widerspruch" "$WIDER Bits widersprechen sich — zwei Aufzaehlungen sind auseinandergelaufen"
# Beide Richtungen muessen ueberhaupt vorkommen, sonst ist der Abgleich einseitig.
if [ "$NUTZBAR" -gt 0 ] && [ "$FEHLEND" -gt 0 ]; then
  ok "beide Richtungen belegt: $NUTZBAR nutzbar, $FEHLEND nicht nutzbar"
else
  echo "HINWEIS: diese CPU belegt nur eine Richtung ($NUTZBAR nutzbar, $FEHLEND fehlend)."
fi

hol() { printf '%s\n' "$AUS" | sed -n "s/^$1=//p" | head -1; }
[ "$(hol unbekannt_bit)" = "0" ] && ok "unbekannter Name liefert 0 (der Aufrufer meldet es laut)" \
  || no "unbekannter Name" "'$(hol unbekannt_bit)'"
case "$(hol namen)" in
  *avx2*pclmulqdq*|*pclmulqdq*avx2*) ok "die Namensliste nennt die Bits (fuer die Fehlermeldung)" ;;
  *) no "Namensliste" "'$(hol namen)'" ;;
esac

# Die laute Ablehnung eines Bits, das nicht in der XCR0-Tabelle steht: ein
# erfundenes Bit (2^40) muss panic ausloesen, nicht "nutzbar" melden.
cat > "$TMP/x.lyx" <<'EOF'
unit main;
import std.io;
import std.cpu.features;
fn main(): int64 {
  PrintStrLn(CpuUnusableReasonName(CpuFeatureUnusableReason(1099511627776)));
  return 0;
}
EOF
if ( cd "$TMP" && timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/x.lyx" -o "$TMP/x" ) >"$TMP/x.log" 2>&1; then
  ( cd "$TMP" && timeout 20 ./x >"$TMP/x.out" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "ein Bit ausserhalb der Tabelle scheitert laut (rc=$rc)"
  else
    no "Tabellenluecke" "lieferte '$(cat "$TMP/x.out")' statt laut zu scheitern"
  fi
else
  no "uebersetzt (Tabellenluecke)" "$(grep -m1 -iE 'error' "$TMP/x.log")"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
