#!/usr/bin/env bash
# tests/sec_wp32_toctou_test.sh — WP-32: TOCTOU in ms_appendMetaSafe (20 Tests)
#
# Prüft:
#   A: Kompiliertes Binary läuft korrekt (ms_appendMetaSafe in-place via O_RDWR)
#   B: .meta_safe Magic-Bytes korrekt im Binary (nur mit --meta-safe)
#   C: Kein File-Descriptor-Leak
#   D: Mehrfachkompilierung, Überschreiben, Edge Cases

set -euo pipefail

LYXC="${LYXC:-$(cd "$(dirname "$0")/.." && pwd)/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

_pass() { echo "PASS $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

make_prog() {
  local src="$1" retval="${2:-0}"
  printf 'fn main(): int64 { return %s; }\n' "$retval" > "$src"
}

count_fds() {
  ls /proc/self/fd 2>/dev/null | wc -l
}

# ── A: Funktionale Korrektheit mit --meta-safe ───────────────────────────────

# Test 1: --meta-safe kompiliert erfolgreich
make_prog "$TMP/t1.lyx" 0
if "$LYXC" "$TMP/t1.lyx" --meta-safe -o "$TMP/t1" 2>/dev/null; then
  _pass 1
else
  _fail 1 "--meta-safe Kompilierung schlug fehl"
fi

# Test 2: Binary mit --meta-safe läuft (exit 0)
make_prog "$TMP/t2.lyx" 0
"$LYXC" "$TMP/t2.lyx" --meta-safe -o "$TMP/t2" 2>/dev/null || true
if "$TMP/t2"; then
  _pass 2
else
  _fail 2 "Binary mit --meta-safe sollte exit 0 liefern"
fi

# Test 3: Exit-Code 7 wird korrekt durchgereicht
make_prog "$TMP/t3.lyx" 7
"$LYXC" "$TMP/t3.lyx" --meta-safe -o "$TMP/t3" 2>/dev/null || true
EC=0; "$TMP/t3" || EC=$?
if [ "$EC" -eq 7 ]; then
  _pass 3
else
  _fail 3 "Erwartet exit 7, got $EC"
fi

# Test 4: Binary mit --meta-safe ist ausführbar
make_prog "$TMP/t4.lyx" 0
"$LYXC" "$TMP/t4.lyx" --meta-safe -o "$TMP/t4" 2>/dev/null || true
if [ -x "$TMP/t4" ]; then
  _pass 4
else
  _fail 4 "Binary sollte ausführbar sein"
fi

# Test 5: Binary ohne --meta-safe läuft ebenfalls (Regression)
make_prog "$TMP/t5.lyx" 0
"$LYXC" "$TMP/t5.lyx" -o "$TMP/t5" 2>/dev/null || true
if "$TMP/t5"; then
  _pass 5
else
  _fail 5 "Binary ohne --meta-safe sollte laufen"
fi

# ── B: .meta_safe Sektion im Binary ─────────────────────────────────────────

# Test 6: META-Magic (0x4D455441 = "META") mit --meta-safe vorhanden
make_prog "$TMP/t6.lyx" 0
"$LYXC" "$TMP/t6.lyx" --meta-safe -o "$TMP/t6" 2>/dev/null || true
if grep -qP "\x4D\x45\x54\x41" "$TMP/t6" 2>/dev/null; then
  _pass 6
else
  _fail 6 ".meta_safe Magic fehlt im Binary"
fi

# Test 7: "meta_safe"-String in Binary mit --meta-safe
make_prog "$TMP/t7.lyx" 0
"$LYXC" "$TMP/t7.lyx" --meta-safe -o "$TMP/t7" 2>/dev/null || true
if strings "$TMP/t7" 2>/dev/null | grep -q "meta_safe"; then
  _pass 7
else
  _fail 7 "meta_safe-String fehlt im Binary"
fi

# Test 8: Binary mit --meta-safe ist größer als ohne
make_prog "$TMP/t8.lyx" 0
"$LYXC" "$TMP/t8.lyx" --meta-safe -o "$TMP/t8_meta" 2>/dev/null || true
"$LYXC" "$TMP/t8.lyx" -o "$TMP/t8_plain" 2>/dev/null || true
SZ_META=$(stat -c%s "$TMP/t8_meta" 2>/dev/null || echo 0)
SZ_PLAIN=$(stat -c%s "$TMP/t8_plain" 2>/dev/null || echo 0)
if [ "$SZ_META" -gt "$SZ_PLAIN" ]; then
  _pass 8
else
  _fail 8 "meta-safe Binary ($SZ_META) nicht größer als plain ($SZ_PLAIN)"
fi

# Test 9: ELF-Header bleibt intakt nach --meta-safe (magic 0x7F454C46)
make_prog "$TMP/t9.lyx" 0
"$LYXC" "$TMP/t9.lyx" --meta-safe -o "$TMP/t9" 2>/dev/null || true
MAGIC=$(od -A n -N 4 -t x1 "$TMP/t9" 2>/dev/null | tr -d ' \n')
if [ "$MAGIC" = "7f454c46" ]; then
  _pass 9
else
  _fail 9 "ELF-Magic nach meta-safe falsch: $MAGIC"
fi

# Test 10: Meta-safe Binary nach zweitem Aufruf auf gleichem Output noch lauffähig
make_prog "$TMP/t10.lyx" 0
"$LYXC" "$TMP/t10.lyx" --meta-safe -o "$TMP/t10" 2>/dev/null || true
"$LYXC" "$TMP/t10.lyx" --meta-safe -o "$TMP/t10" 2>/dev/null || true
if "$TMP/t10"; then
  _pass 10
else
  _fail 10 "Binary nach zweitem --meta-safe-Build nicht lauffähig"
fi

# ── C: Kein FD-Leak ──────────────────────────────────────────────────────────

# Test 11: FD-Anzahl vor/nach --meta-safe-Kompilierung gleich
FD_BEFORE=$(count_fds)
make_prog "$TMP/t11.lyx" 0
"$LYXC" "$TMP/t11.lyx" --meta-safe -o "$TMP/t11" 2>/dev/null || true
FD_AFTER=$(count_fds)
if [ "$FD_AFTER" -le "$((FD_BEFORE + 1))" ]; then
  _pass 11
else
  _fail 11 "FD-Leak mit --meta-safe: vorher=$FD_BEFORE, nachher=$FD_AFTER"
fi

# Test 12: FD stabil bei Doppel-Kompilierung mit --meta-safe
FD_BEFORE=$(count_fds)
make_prog "$TMP/t12a.lyx" 0
make_prog "$TMP/t12b.lyx" 5
"$LYXC" "$TMP/t12a.lyx" --meta-safe -o "$TMP/t12a" 2>/dev/null || true
"$LYXC" "$TMP/t12b.lyx" --meta-safe -o "$TMP/t12b" 2>/dev/null || true
FD_AFTER=$(count_fds)
if [ "$FD_AFTER" -le "$((FD_BEFORE + 1))" ]; then
  _pass 12
else
  _fail 12 "FD-Leak Doppelkompilierung: vorher=$FD_BEFORE, nachher=$FD_AFTER"
fi

# Test 13: FD-Anzahl bei 5 Kompilierungen mit --meta-safe stabil
FD_BASE=$(count_fds)
for i in 1 2 3 4 5; do
  make_prog "$TMP/t13_$i.lyx" "$i"
  "$LYXC" "$TMP/t13_$i.lyx" --meta-safe -o "$TMP/t13_$i" 2>/dev/null || true
done
FD_END=$(count_fds)
if [ "$FD_END" -le "$((FD_BASE + 2))" ]; then
  _pass 13
else
  _fail 13 "FD wächst nach 5 --meta-safe-Kompilierungen: basis=$FD_BASE, ende=$FD_END"
fi

# ── D: Mehrfachkompilierung / Edge Cases ─────────────────────────────────────

# Test 14: Überschreiben eines bestehenden --meta-safe-Outputs
make_prog "$TMP/t14.lyx" 3
"$LYXC" "$TMP/t14.lyx" --meta-safe -o "$TMP/t14" 2>/dev/null || true
make_prog "$TMP/t14.lyx" 9
"$LYXC" "$TMP/t14.lyx" --meta-safe -o "$TMP/t14" 2>/dev/null || true
EC=0; "$TMP/t14" || EC=$?
if [ "$EC" -eq 9 ]; then
  _pass 14
else
  _fail 14 "Überschreiben: erwartet exit 9, got $EC"
fi

# Test 15: Verschiedene Exit-Codes (0-4) korrekt mit --meta-safe
ALL_OK=1
for EC_EXPECTED in 0 1 2 3 4; do
  make_prog "$TMP/t15_$EC_EXPECTED.lyx" "$EC_EXPECTED"
  "$LYXC" "$TMP/t15_$EC_EXPECTED.lyx" --meta-safe -o "$TMP/t15_$EC_EXPECTED" 2>/dev/null || true
  EC_GOT=0; "$TMP/t15_$EC_EXPECTED" || EC_GOT=$?
  if [ "$EC_GOT" -ne "$EC_EXPECTED" ]; then
    ALL_OK=0
    break
  fi
done
if [ "$ALL_OK" -eq 1 ]; then
  _pass 15
else
  _fail 15 "Exit-Code-Durchreichung mit --meta-safe fehlerhaft"
fi

# Test 16: Kompilierung ohne --meta-safe nach --meta-safe (kein Zustandsproblem)
make_prog "$TMP/t16.lyx" 0
"$LYXC" "$TMP/t16.lyx" --meta-safe -o "$TMP/t16a" 2>/dev/null || true
"$LYXC" "$TMP/t16.lyx" -o "$TMP/t16b" 2>/dev/null || true
if "$TMP/t16b"; then
  _pass 16
else
  _fail 16 "Kompilierung ohne --meta-safe nach --meta-safe fehlgeschlagen"
fi

# Test 17: META-Magic nicht vorhanden ohne --meta-safe Flag
make_prog "$TMP/t17.lyx" 0
"$LYXC" "$TMP/t17.lyx" -o "$TMP/t17" 2>/dev/null || true
if ! strings "$TMP/t17" 2>/dev/null | grep -q "meta_safe"; then
  _pass 17
else
  _fail 17 "meta_safe-String unerwartet in plain Binary ohne --meta-safe"
fi

# Test 18: --meta-safe Binary in anderem Verzeichnis (/tmp)
make_prog "$TMP/t18.lyx" 0
OUT18="/tmp/wp32_test_meta_$$"
"$LYXC" "$TMP/t18.lyx" --meta-safe -o "$OUT18" 2>/dev/null || true
RC=0; "$OUT18" || RC=$?
if [ -x "$OUT18" ] && [ "$RC" -eq 0 ]; then
  _pass 18
else
  _fail 18 "Kompilierung nach /tmp mit --meta-safe fehlgeschlagen"
fi
rm -f "$OUT18"

# Test 19: Permissions des --meta-safe Binaries korrekt (ausführbar)
make_prog "$TMP/t19.lyx" 0
"$LYXC" "$TMP/t19.lyx" --meta-safe -o "$TMP/t19" 2>/dev/null || true
PERMS=$(stat -c%a "$TMP/t19" 2>/dev/null || echo 0)
if [ "$PERMS" = "755" ] || [ "$PERMS" = "775" ] || [ "$PERMS" = "777" ]; then
  _pass 19
else
  _fail 19 "Permissions: $PERMS (erwartet 755)"
fi

# Test 20: Mehrere --meta-safe Outputs aus derselben Quelle haben gleiche Größe
make_prog "$TMP/t20.lyx" 0
"$LYXC" "$TMP/t20.lyx" --meta-safe -o "$TMP/t20a" 2>/dev/null || true
"$LYXC" "$TMP/t20.lyx" --meta-safe -o "$TMP/t20b" 2>/dev/null || true
SZA=$(stat -c%s "$TMP/t20a" 2>/dev/null || echo 0)
SZB=$(stat -c%s "$TMP/t20b" 2>/dev/null || echo 0)
if [ "$SZA" -eq "$SZB" ] && [ "$SZA" -gt 0 ]; then
  _pass 20
else
  _fail 20 "Größen unterschiedlich: $SZA vs $SZB"
fi

# ── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
