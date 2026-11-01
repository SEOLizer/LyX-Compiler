#!/usr/bin/env bash
# tests/arith_vertrag_test.sh — Arithmetikvertrag der Benchmark-Suite (#2332).
#
# Die Suite aus work/bench-suite-spezifikation.md vergleicht denselben
# Algorithmus in Lyx und C. Das setzt einen gemeinsamen Arithmetikvertrag
# voraus, und zwar BELEGT, nicht angenommen: echte Rotation braucht
# Modulo-2^64-Semantik, Maskierung unterhalb einer Ueberlaufschwelle bildet
# das nicht gleichwertig ab.
#
# Dieser Test haelt die GEMESSENEN Eigenschaften von lyxc fest, auf denen die
# Suite aufsetzt. Faellt eine weg, bricht nicht erst der Benchmark, sondern
# hier — mit Namen der Eigenschaft:
#
#   1. uint64 ist wirklich vorzeichenlos: `>>` logisch, Vergleich, Division
#      und Rest vorzeichenlos.
#   2. Arithmetik rechnet modulo 2^64, ohne Abbruch (int64 und uint64).
#   3. Literale bis 2^64-1 tragen das richtige Bitmuster.
#   4. rotl/rotr rotieren 64 Bit exakt.
#   5. int64-`>>` ist arithmetisch (Vorzeichen wird fortgesetzt).
#   6. Es gibt KEIN `>>>`. Wer logisch schieben will, nimmt uint64.
#
# Jede Erwartung ist ein Bitmuster, kein Wertebereich: ein Test, der nur eine
# Invariante prueft, ist blind fuer das falsche Ergebnis darin (CLAUDE.md).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# fall NAME ERWARTET RUMPF — uebersetzt den Rumpf und vergleicht die Ausgabe.
fall() {
  local name="$1" soll="$2" rumpf="$3"
  { echo "import std.io;"; echo "fn main(): int64 {"; echo "$rumpf"; echo "  return 0;"; echo "}"; } > "$TMP/$name.lyx"
  if ! ( cd "$ROOT" && ulimit -v 4000000 && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/$name.lyx" -o "$TMP/$name" ) >"$TMP/$name.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -iE 'error|parse' "$TMP/$name.log" | head -1)"; return
  fi
  local got; got="$( ulimit -c 0; cd "$TMP" && timeout 30 "./$name" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' )"
  if [ "$got" = "$soll" ]; then ok "$name"; else no "$name" "'$got', erwartet '$soll'"; fi
}

# 1. uint64 ist vorzeichenlos. 2^64-1 >> 1 == 0x7FFFFFFFFFFFFFFF.
fall u64_shr_logisch "9223372036854775807" \
  '  var a: uint64 := 18446744073709551615;
  PrintLn((a >> 1) as int64);'

# 2^64-1 > 1 gilt nur vorzeichenlos; signiert waere es -1 < 1.
fall u64_vergleich "1" \
  '  var a: uint64 := 18446744073709551615;
  var b: uint64 := 1;
  if (a > b) { PrintLn(1); } else { PrintLn(0); }'

# (2^64-1)/2 == 0x7FFFFFFFFFFFFFFF, (2^64-1)%1000 == 615. Signiert waere es 0 und -615.
fall u64_div_mod "9223372036854775807 615" \
  '  var a: uint64 := 18446744073709551615;
  PrintLn((a / 2) as int64);
  PrintLn((a % 1000) as int64);'

# 2. Modulo 2^64, kein Abbruch: INT64_MAX+1 kippt auf INT64_MIN,
#    (2^64-1)+2 == 1, und 0x9E3779B97F4A7C15 * 3 mod 2^64 ist exakt.
fall mod2_64 "-9223372036854775808 1 3668340012 2111796287" \
  '  var s: int64 := 9223372036854775807;
  PrintLn(s + 1);
  var u: uint64 := 18446744073709551615;
  PrintLn((u + 2) as int64);
  var g: uint64 := 11400714819323198485;
  var p: uint64 := g * 3;
  PrintLn((p >> 32) as int64);
  PrintLn((p & 4294967295) as int64);'

# 3. Literal 2^64-1 traegt das Bitmuster aller Einsen (als int64 gelesen: -1).
fall literal_2_64 "-1" \
  '  var a: int64 := 18446744073709551615;
  PrintLn(a);'

# 4. Rotation exakt: 0x8000000000000001 rotl 1 == 0x3,
#    rotr 1 == 0xC000000000000000 (obere 32 Bit 0xC0000000).
fall rot64_exakt "3 3221225472" \
  '  var a: int64 := 9223372036854775809;
  PrintLn(rotl(a, 1));
  var b: uint64 := rotr(a, 1) as uint64;
  PrintLn((b >> 32) as int64);'

# 5. int64-`>>` setzt das Vorzeichen fort.
fall int64_shr_arithmetisch "-4" \
  '  var a: int64 := 0 - 8;
  PrintLn(a >> 1);'

# 6. `>>>` gibt es NICHT — und das soll laut scheitern, nicht still etwas
#    anderes bedeuten. Wer das aendert, muss diesen Test anfassen.
printf 'import std.io;\nfn main(): int64 { var a: int64 := 0 - 8; PrintLn(a >>> 1); return 0; }\n' > "$TMP/ushr.lyx"
if ( cd "$ROOT" && ulimit -v 4000000 && timeout 120 "$LYXC" --std-path="$ROOT" "$TMP/ushr.lyx" -o "$TMP/ushr" ) >"$TMP/ushr.log" 2>&1; then
  no "kein_ushr" "\`>>>\` uebersetzt jetzt — Vertrag in work/bench-suite-spezifikation.md nachziehen"
else
  ok "kein_ushr (logisch schieben heisst uint64)"
fi

# 7. Gegenprobe in C: dieselben Bitmuster mit uint64_t/int64_t. Weicht C ab,
#    ist der gemeinsame Vertrag kaputt, nicht lyxc.
if command -v gcc >/dev/null 2>&1; then
  cat > "$TMP/ref.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
int main(void) {
    uint64_t a = 18446744073709551615ULL;
    printf("%lld\n", (long long)(a >> 1));
    printf("%d\n", a > 1ULL ? 1 : 0);
    printf("%lld\n%lld\n", (long long)(a / 2), (long long)(a % 1000));
    uint64_t u = a + 2, g = 11400714819323198485ULL, p = g * 3;
    printf("%lld\n", (long long)(int64_t)(9223372036854775807LL + 1ULL));
    printf("%lld\n%lld\n%lld\n", (long long)u, (long long)(p >> 32), (long long)(p & 4294967295ULL));
    uint64_t r = 9223372036854775809ULL;
    printf("%lld\n", (long long)((r << 1) | (r >> 63)));
    printf("%lld\n", (long long)(((r >> 1) | (r << 63)) >> 32));
    printf("%lld\n", (long long)(((int64_t)-8) >> 1));
    return 0;
}
CEOF
  if gcc -O2 -o "$TMP/ref" "$TMP/ref.c" 2>"$TMP/ref.log"; then
    soll="9223372036854775807 1 9223372036854775807 615 -9223372036854775808 1 3668340012 2111796287 3 3221225472 -4"
    got="$("$TMP/ref" | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$got" = "$soll" ]; then ok "C-Gegenprobe: gleiche Bitmuster"
    else no "C-Gegenprobe" "'$got', erwartet '$soll'"; fi
  else
    echo "HINWEIS: C-Gegenprobe uebersprungen — gcc uebersetzt ref.c nicht."
  fi
else
  echo "HINWEIS: C-Gegenprobe uebersprungen — gcc fehlt."
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
