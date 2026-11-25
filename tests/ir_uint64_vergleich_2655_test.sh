#!/usr/bin/env bash
# tests/ir_uint64_vergleich_2655_test.sh — #2655: ein Vergleich mit `as uint64`
# muss auf JEDEM Ziel vorzeichenlos rechnen.
#
# Bis 1.2.49A hatte der Cast auf dem IR-Weg keine Wirkung: arm64, riscv64 und
# lyxos rechneten STILL vorzeichenbehaftet, x86 richtig. `_irVorzeichenlos`
# stand in ir_lower schon da, wurde aber nur fuer `>>` befragt (#2236) — eine
# Operatorgruppe war nicht nachgezogen.
#
# Gemessen wird in fuenf Teilen, und jeder hat seine Gegenrichtung:
#
#   1. alle vier Ordnungsoperatoren mit Werten, die sich genau in der
#      Vorzeichenfrage unterscheiden
#   2. Gegenprobe OHNE Cast — muss vorzeichenbehaftet bleiben. Ohne sie waere
#      der Test auch von einer Fassung erfuellt, die alles vorzeichenlos
#      rechnet, und das waere die Lücke in der anderen Richtung
#   3. Konstantenfaltung gegen Laufzeit: derselbe Vergleich einmal mit
#      Literalen (faltet ir_optimize) und einmal ueber Variablen (rechnet das
#      Backend) muss dasselbe ergeben — sonst rechnet der Compiler anders als
#      sein Erzeugnis
#   4. `BnCmp` aus std/crypto/bignum.lyx: der belegte Schaden
#   5. RSA-PSS mit dem Vektor aus #2652: eine GUELTIGE Signatur muss angenommen
#      werden, eine um EIN BIT verfaelschte weiterhin abgewiesen. Ein Test, der
#      nur die gueltige prueft, waere auch von "nimmt alles an" erfuellt.
#
# Die Werte in Teil 1: 4392601989105751763 ist vorzeichenbehaftet positiv,
# 0 - 6156384499570790705 vorzeichenbehaftet negativ, aber vorzeichenLOS die
# groessere Zahl. Jeder Operator gibt also unter den beiden Deutungen ein
# anderes Ergebnis — genau das Paar, an dem #2652 hing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

ZIELE="linux"
[ -n "$QEMU_ARM64" ]   && ZIELE="$ZIELE arm64"   || echo "HINWEIS: Emulator fuer arm64 fehlt"
[ -n "$QEMU_RISCV64" ] && ZIELE="$ZIELE riscv"   || echo "HINWEIS: Emulator fuer riscv fehlt"

SPKI_HEX="30820122300d06092a864886f70d01010105000382010f003082010a0282010100aa9020ea625caecfdef5b28adeab1e8d61709b3e4080cc9d96485e09e9dc3c3be21141f93fe5a6e1087b241bcef1b2dd1cf75fa446b57ab671b7c35e99e98168a662a379f65a4c2ebf185643862eb80f690b6f93f95d1251a7ca727789e98bdc6c6afb4950f95dbecfd03bc4f032e1a762432c9ab91867d4af9af837952aa8a242d499f143aceb05f18ec19fc06cbdf1ecbff2a8267a52cacaf7d402b08f1fcd34ecebd71098cd20e7b8b1da45babda1fec1b18c261b172b05d0dafd84144b372c025d0159b9fc850fefd45408feff9e5d47775fcb0b1acacfafc99b651765d1d92758d7be323b6b35683ae503a96af0d79787c94aa4436cb1f9fbc30a2f9adb0203010001"
SIG_HEX="3cf5a83c705296d303906994edec3abd167acd92c9ddeddf4a9ef7983c73c7529a66b54a565e210d6b3001fbb589b8e419ae9fb9897438a8023b83f013ed3bfbdf3429f1277b4672bfcdd5ea2fc45ce57d55edfe88529a1eab41bbb500d3adee7afb2f2364fb6ef7d116b6e3ad92949648d182b17ef051b858f73ee6256f180c0c686da669e38c01e056188fc2a4f0c617d167d6e41a4690a24bccb129f4fbadfff3f2b414a7d86f87b000423cb7198719d3a36069b4458c6b806612979b4d8a9cbae55c6d4efebcc8bde659f72d0cea63f808abbc75e905ac6bfec63c110ff1adee1147b21ecd4250ae0dc592c1aff6e469dbfd23ce31024347770493359957"
HASH_HEX="01b89879464e2f98b296772ab3c53b751dd313077f71bcfba1132009af4c17f0"

cat > "$TMP/p.lyx" <<'EOS'
import std.io;
import std.string;
import std.alloc;
import std.crypto.bignum;
import std.crypto.rsa_native;

fn hexZiffer(c: int64): int64 {
  if (c >= 48 && c <= 57) { return c - 48; }
  if (c >= 97 && c <= 102) { return c - 87; }
  if (c >= 65 && c <= 70) { return c - 55; }
  return 0 - 1;
}

// Hex-Zeichenkette in einen Puffer; liefert die Bytezahl oder -1.
fn hexEin(s: pchar, ziel: int64): int64 {
  var i: int64 := 0;
  var n: int64 := 0;
  while (StrCharAt(s, i) != 0) {
    var h: int64 := hexZiffer(StrCharAt(s, i));
    var l: int64 := hexZiffer(StrCharAt(s, i + 1));
    if (h < 0 || l < 0) { return 0 - 1; }
    poke8(ziel + n, h * 16 + l);
    n := n + 1;
    i := i + 2;
  }
  return n;
}

fn jn(b: bool): pchar { if (b) { return "ja"c; } return "nein"c; }

fn main(): int64 {
  // --- Teil 1: die vier Ordnungsoperatoren ueber Variablen ---
  var x: int64 := 4392601989105751763;
  var y: int64 := 0 - 6156384499570790705;
  Print("lauf-gt "); PrintLn(jn((x as uint64) >  (y as uint64)));
  Print("lauf-lt "); PrintLn(jn((x as uint64) <  (y as uint64)));
  Print("lauf-ge "); PrintLn(jn((x as uint64) >= (y as uint64)));
  Print("lauf-le "); PrintLn(jn((x as uint64) <= (y as uint64)));

  // --- Teil 2: Gegenprobe ohne Cast, muss vorzeichenbehaftet bleiben ---
  Print("ohne-gt "); PrintLn(jn(x > y));
  Print("ohne-lt "); PrintLn(jn(x < y));

  // --- Teil 3: Konstantenfaltung (Literale) gegen Laufzeit ---
  Print("falt-gt "); PrintLn(jn((4392601989105751763 as uint64) >  ((0 - 6156384499570790705) as uint64)));
  Print("falt-lt "); PrintLn(jn((4392601989105751763 as uint64) <  ((0 - 6156384499570790705) as uint64)));
  Print("falt-ge "); PrintLn(jn((4392601989105751763 as uint64) >= ((0 - 6156384499570790705) as uint64)));
  Print("falt-le "); PrintLn(jn((4392601989105751763 as uint64) <= ((0 - 6156384499570790705) as uint64)));

  // --- Teil 4: BnCmp, der belegte Schaden ---
  var a: int64 := alloc(512);
  var b: int64 := alloc(512);
  BnZero(a, 2); BnZero(b, 2);
  poke64(a + 8, 4392601989105751763);        // oberes Glied signed positiv
  poke64(b + 8, 0 - 6156384499570790705);    // oberes Glied signed negativ
  Print("bncmp "); PrintLn(IntToStr(BnCmp(a, b, 2)));
  Print("bncmp-umgekehrt "); PrintLn(IntToStr(BnCmp(b, a, 2)));
  Print("bncmp-gleich "); PrintLn(IntToStr(BnCmp(a, a, 2)));

  // --- Teil 5: RSA-PSS mit dem Vektor aus #2652 ---
  var spki: int64 := alloc(1024);
  var sig: int64  := alloc(1024);
  var hsh: int64  := alloc(128);
  var spkiN: int64 := hexEin(SPKI_HEX, spki);
  var sigN: int64  := hexEin(SIG_HEX, sig);
  var hshN: int64  := hexEin(HASH_HEX, hsh);
  if (spkiN < 0 || sigN < 0 || hshN != 32) { PrintLn("vektor-fehler"); return 1; }
  var key: int64 := alloc(RsaSchluesselGroesse());
  if (!RsaPubAusSpki(spki, spkiN, key)) { PrintLn("key-fehler"); return 1; }
  Print("pss-gueltig "); PrintLn(jn(RsaVerifyPss(key, 32, hsh, sig, sigN)));
  // Gegenrichtung: ein gekipptes Bit muss weiterhin abgewiesen werden.
  poke8(sig + 100, peek8(sig + 100) ^ 1);
  Print("pss-gekippt "); PrintLn(jn(RsaVerifyPss(key, 32, hsh, sig, sigN)));
  return 0;
}
EOS
# Die Vektoren als Konstanten voranstellen (die Datei oben nutzt die Namen).
{
  echo "con SPKI_HEX: pchar := \"$SPKI_HEX\"c;"
  echo "con SIG_HEX: pchar := \"$SIG_HEX\"c;"
  echo "con HASH_HEX: pchar := \"$HASH_HEX\"c;"
  cat "$TMP/p.lyx"
} > "$TMP/q.lyx"
# con-Zeilen muessen HINTER die Importe: Datei neu zusammensetzen.
{
  grep '^import' "$TMP/p.lyx"
  echo "con SPKI_HEX: pchar := \"$SPKI_HEX\"c;"
  echo "con SIG_HEX: pchar := \"$SIG_HEX\"c;"
  echo "con HASH_HEX: pchar := \"$HASH_HEX\"c;"
  grep -v '^import' "$TMP/p.lyx"
} > "$TMP/r.lyx"

for z in $ZIELE; do
  case "$z" in
    linux) OPT="--target=linux"; Q="" ;;
    arm64) OPT="--target=arm64"; Q="$QEMU_ARM64" ;;
    riscv) OPT="--target=riscv"; Q="$QEMU_RISCV64" ;;
  esac
  if ! "$LYXC" --std-path="$ROOT" $OPT "$TMP/r.lyx" -o "$TMP/r_$z" >"$TMP/bau_$z.log" 2>&1; then
    nok "$z: uebersetzt nicht ($(grep -oE 'error:.*' "$TMP/bau_$z.log" | head -1))"
    continue
  fi
  A="$($Q "$TMP/r_$z" 2>&1)"
  hol() { echo "$A" | grep -oE "^$1 .*" | awk '{print $2}'; }

  # Teil 1: vorzeichenlos -> x < y, also gt/ge nein, lt/le ja
  [ "$(hol lauf-gt)" = "nein" ] && ok "$z: > vorzeichenlos" || nok "$z: > ist '$(hol lauf-gt)', erwartet nein (vorzeichenlos)"
  [ "$(hol lauf-lt)" = "ja" ]   && ok "$z: < vorzeichenlos" || nok "$z: < ist '$(hol lauf-lt)', erwartet ja"
  [ "$(hol lauf-ge)" = "nein" ] && ok "$z: >= vorzeichenlos" || nok "$z: >= ist '$(hol lauf-ge)', erwartet nein"
  [ "$(hol lauf-le)" = "ja" ]   && ok "$z: <= vorzeichenlos" || nok "$z: <= ist '$(hol lauf-le)', erwartet ja"

  # Teil 2: ohne Cast vorzeichenbehaftet -> x > y
  [ "$(hol ohne-gt)" = "ja" ]   && ok "$z: ohne Cast bleibt vorzeichenbehaftet" || nok "$z: ohne Cast > ist '$(hol ohne-gt)', erwartet ja"
  [ "$(hol ohne-lt)" = "nein" ] && ok "$z: ohne Cast < bleibt vorzeichenbehaftet" || nok "$z: ohne Cast < ist '$(hol ohne-lt)', erwartet nein"

  # Teil 3: Faltung muss der Laufzeit gleichen
  gleich=1
  for o in gt lt ge le; do
    [ "$(hol falt-$o)" = "$(hol lauf-$o)" ] || gleich=0
  done
  [ "$gleich" = "1" ] && ok "$z: Konstantenfaltung gleicht der Laufzeit" \
                       || nok "$z: Faltung weicht ab (falt gt/lt/ge/le = $(hol falt-gt)/$(hol falt-lt)/$(hol falt-ge)/$(hol falt-le), lauf = $(hol lauf-gt)/$(hol lauf-lt)/$(hol lauf-ge)/$(hol lauf-le))"

  # Teil 4: BnCmp
  [ "$(hol bncmp)" = "-1" ]            && ok "$z: BnCmp vorzeichenlos (-1)" || nok "$z: BnCmp ist '$(hol bncmp)', erwartet -1"
  [ "$(hol bncmp-umgekehrt)" = "1" ]   && ok "$z: BnCmp umgekehrt (1)"      || nok "$z: BnCmp umgekehrt ist '$(hol bncmp-umgekehrt)', erwartet 1"
  [ "$(hol bncmp-gleich)" = "0" ]      && ok "$z: BnCmp gleich (0)"         || nok "$z: BnCmp gleich ist '$(hol bncmp-gleich)', erwartet 0"

  # Teil 5: RSA-PSS, beide Richtungen
  [ "$(hol pss-gueltig)" = "ja" ]   && ok "$z: gueltige PSS-Signatur angenommen" || nok "$z: gueltige PSS-Signatur ABGELEHNT (#2652)"
  [ "$(hol pss-gekippt)" = "nein" ] && ok "$z: gekippte PSS-Signatur abgewiesen" || nok "$z: gekippte PSS-Signatur ANGENOMMEN"
done

echo "---"
echo "$PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
