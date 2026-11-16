#!/usr/bin/env bash
# tests/crypto_rsa_crt_test.sh — #2096: RSA-Signatur mit chinesischem Restsatz.
#
# Gemessen wird die WIRKUNG, in beide Richtungen:
#   1. Der CRT-Weg wird nach PKCS#8 wirklich genommen (RsaHatCrt), nach einem
#      reinen oeffentlichen Schluessel nicht.
#   2. Beide Wege liefern dieselbe PKCS#1-Signatur, Byte fuer Byte. PKCS#1
#      ist deterministisch — ein Vergleich hat hier also Aussagekraft, PSS
#      waere wegen des frischen Salzes dafuer untauglich.
#   3. Der CRT-Weg ist deutlich schneller. Geprueft wird mit Faktor >= 2,
#      obwohl rund 4 erwartet sind: der Test soll die Wirkung belegen und
#      nicht auf einer belegten CI-Maschine am Rauschen scheitern.
#   4. Ein eingestreuter Rechenfehler in dq fuehrt NICHT zu einer falschen
#      Signatur, sondern zum Fehlschlag: die Gegenprobe s^e mod n faengt ihn.
#      Das ist der Kern des Fehlerangriffs von Boneh/DeMillo/Lipton — eine
#      herausgegebene falsche CRT-Signatur verraet die Faktorisierung.
#   5. Dieselben Punkte fuer 3072 Bit, damit die Breitenrechnung (halb =
#      glieder/2) nicht nur in einem Fall stimmt.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if ! command -v openssl >/dev/null 2>&1; then
  echo "SKIP openssl nicht im Pfad (Schluesselerzeugung)"; exit 0
fi
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/k2048.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$TMP/k3072.pem" 2>/dev/null
openssl rsa -in "$TMP/k2048.pem" -pubout -out "$TMP/p2048.pem" 2>/dev/null
[ -s "$TMP/k2048.pem" ] || { echo "SKIP openssl erzeugt keinen Schluessel"; exit 0; }

cat > "$TMP/s.lyx" <<'LYXEOF'
unit main;
import std.io;
import std.string;
import std.alloc;
import std.fs;
import std.crypto.der;
import std.crypto.sha256;
import std.crypto.rsa_native;

fn ladeDer(pfad: pchar, label: pchar, derOut: int64): int64 {
  var pem: int64 := alloc(16384);
  var n: int64 := ReadFile(pfad, pem as pchar, 16383);
  if (n <= 0) { return -1; }
  return PemDekodiere(pem, n, label as int64, StrLen(label), derOut, 8192);
}

fn melde(name: pchar, wert: int64): void {
  Print(name); Print(" "); PrintInt(wert); PrintLn("");
}

// Eine Reihe PKCS#1-Signaturen; gibt die Laenge der letzten zurueck.
fn reihe(key: int64, hash: int64, sig: int64, runden: int64): int64 {
  var l: int64 := 0;
  var i: int64 := 0;
  while (i < runden) { l := RsaSignPkcs1(key, 32, hash, sig); i := i + 1; }
  return l;
}

fn main(): int64 {
  var pfad: pchar := GetArg(1) as pchar;
  var modus: pchar := GetArg(2) as pchar;        // "pruef" oder "zeit-crt"/"zeit-d"
  var runden: int64 := 1;
  if (GetArgC() > 3) { runden := StrToInt(GetArg(3) as pchar); }

  var der: int64 := alloc(8192);
  var l: int64 := ladeDer(pfad, "PRIVATE KEY"c, der);
  if (l <= 0) { PrintLn("LADEFEHLER"); return 1; }
  var key: int64 := alloc(RsaSchluesselGroesse());
  if (!RsaPrivAusPkcs8(der, l, key)) { PrintLn("SCHLUESSELFEHLER"); return 1; }

  var text: pchar := "Nachricht fuer den chinesischen Restsatz"c;
  var hash: int64 := alloc(32);
  SHA256(text as int64, StrLen(text), hash);
  var sigA: int64 := alloc(512);
  var sigB: int64 := alloc(512);

  if (StrCharAt(modus, 0) == 122) {              // 'z' — Zeitmessung
    if (StrCharAt(modus, 5) == 100) { RsaCrtAus(key); }   // "zeit-d"
    melde("crt"c, RsaHatCrt(key));
    melde("laenge"c, reihe(key, hash, sigA, runden));
    return 0;
  }

  // --- Pruefmodus ---
  melde("hat-crt"c, RsaHatCrt(key));
  melde("crt-glieder"c, RsaCrtGlieder(key));
  var lA: int64 := RsaSignPkcs1(key, 32, hash, sigA);
  melde("crt-signatur-laenge"c, lA);
  melde("crt-signatur-gueltig"c, RsaVerifyPkcs1(key, 32, hash, sigA, lA));

  // dasselbe ohne CRT, aus einem frisch gelesenen Schluessel
  var key2: int64 := alloc(RsaSchluesselGroesse());
  RsaPrivAusPkcs8(der, l, key2);
  RsaCrtAus(key2);
  melde("zweiter-hat-crt"c, RsaHatCrt(key2));
  var lB: int64 := RsaSignPkcs1(key2, 32, hash, sigB);
  var gleich: int64 := 1;
  if (lA != lB) { gleich := 0; }
  else {
    var i: int64 := 0;
    while (i < lA) { if (peek8(sigA + i) != peek8(sigB + i)) { gleich := 0; } i := i + 1; }
  }
  melde("beide-wege-bitgleich"c, gleich);

  // --- Fehlerangriff: ein gekipptes Bit in dq ---
  var key3: int64 := alloc(RsaSchluesselGroesse());
  RsaPrivAusPkcs8(der, l, key3);
  var dq: int64 := RsaCrtFeld(key3, 3);
  poke64(dq, peek64(dq) ^ 1);
  var lC: int64 := RsaSignPkcs1(key3, 32, hash, sigB);
  melde("verfaelschtes-dq-laenge"c, lC);
  // Nichts darf herausgegeben werden; schon gar nichts Gueltiges.
  var gueltig: int64 := 0;
  if (lC > 0) { if (RsaVerifyPkcs1(key3, 32, hash, sigB, lC)) { gueltig := 1; } }
  melde("verfaelschtes-dq-gueltig"c, gueltig);

  // ... und ein gekipptes Bit in p, das die Reduktion selbst trifft
  var key4: int64 := alloc(RsaSchluesselGroesse());
  RsaPrivAusPkcs8(der, l, key4);
  var pp: int64 := RsaCrtFeld(key4, 0);
  poke64(pp, peek64(pp) ^ 4);
  melde("verfaelschtes-p-laenge"c, RsaSignPkcs1(key4, 32, hash, sigB));
  return 0;
}
LYXEOF

cd "$ROOT"
"$LYXC" "$TMP/s.lyx" --std-path=. -o "$TMP/s" > "$TMP/build.log" 2>&1
if [ ! -x "$TMP/s" ]; then
  echo "FAIL: Testprogramm laesst sich nicht uebersetzen"; tail -20 "$TMP/build.log"; exit 1
fi

fails=0
pruefe() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 = '$2', erwartet '$3'"; fails=$((fails + 1)); fi
}

for bits in 2048 3072; do
  ( ulimit -v 4000000 -c 0; "$TMP/s" "$TMP/k$bits.pem" pruef > "$TMP/out$bits.txt" 2>&1 )
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "FAIL: Testprogramm abgebrochen (rc=$rc, $bits Bit)"; cat "$TMP/out$bits.txt"; exit 1
  fi
  echo "--- $bits Bit"; cat "$TMP/out$bits.txt"
  hole() { grep -m1 "^$1 " "$TMP/out$bits.txt" | cut -d' ' -f2-; }
  erwGlieder=16; [ "$bits" = 3072 ] && erwGlieder=24
  pruefe "$bits hat-crt"                "$(hole hat-crt)" 1
  pruefe "$bits crt-glieder"            "$(hole crt-glieder)" "$erwGlieder"
  pruefe "$bits crt-signatur-laenge"    "$(hole crt-signatur-laenge)" "$((bits / 8))"
  pruefe "$bits crt-signatur-gueltig"   "$(hole crt-signatur-gueltig)" 1
  pruefe "$bits zweiter-hat-crt"        "$(hole zweiter-hat-crt)" 0
  pruefe "$bits beide-wege-bitgleich"   "$(hole beide-wege-bitgleich)" 1
  # Die Gegenprobe muss zuschlagen: Laenge 0, also keine Signatur.
  pruefe "$bits verfaelschtes-dq-laenge"  "$(hole verfaelschtes-dq-laenge)" 0
  pruefe "$bits verfaelschtes-dq-gueltig" "$(hole verfaelschtes-dq-gueltig)" 0
  pruefe "$bits verfaelschtes-p-laenge"   "$(hole verfaelschtes-p-laenge)" 0
done

# --- Zeitmessung, A/B-Paar: dieselbe Reihe einmal mit und einmal ohne CRT ---
ms() {
  local s0 s1
  s0=$(date +%s%N)
  ( ulimit -v 4000000 -c 0; "$TMP/s" "$TMP/k2048.pem" "$1" 20 > "$TMP/z_$1.txt" 2>&1 )
  s1=$(date +%s%N)
  echo $(( (s1 - s0) / 1000000 ))
}
tCrt=$(ms zeit-crt)
tD=$(ms zeit-d)
grep -q "^crt 1" "$TMP/z_zeit-crt.txt" || { echo "FAIL: Messlauf lief ohne CRT"; fails=$((fails+1)); }
grep -q "^crt 0" "$TMP/z_zeit-d.txt"   || { echo "FAIL: Messlauf lief mit CRT"; fails=$((fails+1)); }
echo "--- 20 Signaturen 2048 Bit: mit CRT ${tCrt} ms, ueber d ${tD} ms"
if [ "$tCrt" -le 0 ]; then tCrt=1; fi
faktor=$(( tD * 10 / tCrt ))
echo "--- Faktor ${faktor} Zehntel (erwartet >= 20)"
if [ "$faktor" -lt 20 ]; then
  echo "FAIL: CRT bringt weniger als Faktor 2 (mit ${tCrt} ms, ohne ${tD} ms)"
  fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"
exit 1
