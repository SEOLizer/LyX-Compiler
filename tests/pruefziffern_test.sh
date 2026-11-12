#!/usr/bin/env bash
# #1690 / #1689 — Pruefziffern der std.validate-Familie gegen Referenzwerte.
#
# Die Methode stammt aus dem CRC32-Fall: eine Pruefsumme sieht auch dann
# plausibel aus, wenn sie die falsche Variante rechnet. Nur ein Abgleich mit
# veroeffentlichten Beispielen zeigt es. Genau so fielen hier zwei Units auf:
#   * ISSN vertauschte die Randfaelle der Mod-11-Rechnung (rest 1 galt als
#     ungueltig statt als 'X', rest 10 lieferte 'X' statt '1').
#   * LEI rechnete Mod 97 mit der IBAN-Umstellung, die ISO 17442 nicht kennt,
#     und wies dadurch ausnahmslos jede gueltige LEI ab.
#
# Die uebrigen Units sind mitgeprueft, damit dieselbe Klasse dort nicht
# unbemerkt entsteht. Erwartete Rueckgaben sind bewusst je Unit notiert: die
# Familie ist uneinheitlich (0/Fehlercode bei den meisten, 1/0 bei Luhn).

ROOT="$(cd "$(dirname "$0")" && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

cat > "$TMP/p.lyx" <<'EOF'
import std.io;
import std.validate.issn;
import std.validate.lei;
import std.validate.iban;
import std.validate.isin;
import std.validate.bic;
import std.validate.orcid;
import std.validate.vin;
import std.validate.iso6346;
import std.validate.us_cusip;
import std.validate.cas;
import std.validate.nl_bsn;
import std.validate.ch_ahv;
import std.validate.luhn;

fn z(name: pchar, got: int64, want: int64): void {
  if (got == want) { Print("PASS "); PrintLn(name); }
  else { Print("FAIL "); Print(name); Print(": "); Print(IntToStr(got)); Print(" statt "); PrintLn(IntToStr(want)); }
}

fn main(): int64 {
  // ISSN — kanonische Beispiele. 0 = gueltig, 3 = ISSN_ERR_CHECK.
  z("ISSN 0317-8471 gueltig", ISSNValidate("0317-8471"), 0);
  z("ISSN 0378-5955 gueltig", ISSNValidate("0378-5955"), 0);
  z("ISSN 2434-561X gueltig", ISSNValidate("2434-561X"), 0);
  z("ISSN 0317-8472 falsch",  ISSNValidate("0317-8472"), 3);
  // Randfaelle der Mod-11-Rechnung: 49 ist '1', 88 ist 'X'.
  z("ISSN Pruefziffer 0317-847 ist 1", ISSNCheckDigit("0317-847"), 49);
  z("ISSN Pruefziffer 2434-561 ist X", ISSNCheckDigit("2434-561"), 88);

  // LEI — ISO 17442, Mod 97 ueber die gesamte Kette. 0 = gueltig, 3 = Check.
  z("LEI 5493001KJTIIGC8Y1R12 gueltig", LEIValidate("5493001KJTIIGC8Y1R12" as int64), 0);
  z("LEI 529900T8BM49AURSDO55 gueltig", LEIValidate("529900T8BM49AURSDO55" as int64), 0);
  z("LEI 5493001KJTIIGC8Y1R13 falsch",  LEIValidate("5493001KJTIIGC8Y1R13" as int64), 3);

  // Die uebrigen Units: 0 = gueltig, ausser Luhn (1 = gueltig, 0 = nicht).
  z("IBAN DE89370400440532013000", IBANValidate("DE89370400440532013000"), 0);
  z("IBAN GB82WEST12345698765432", IBANValidate("GB82WEST12345698765432"), 0);
  z("IBAN DE89370400440532013001 falsch", IBANValidate("DE89370400440532013001"), 3);
  z("ISIN US0378331005", ISINValidate("US0378331005" as int64), 0);
  z("ISIN DE0005557508", ISINValidate("DE0005557508" as int64), 0);
  z("BIC DEUTDEFF", BICValidate("DEUTDEFF"), 0);
  z("BIC DEUTDEFF500", BICValidate("DEUTDEFF500"), 0);
  z("ORCID 0000-0002-1825-0097", ORCIDValidate("0000-0002-1825-0097" as int64), 0);
  z("VIN 1HGBH41JXMN109186", VINValidate("1HGBH41JXMN109186" as int64), 0);
  z("Container CSQU3054383", ContainerValidate("CSQU3054383" as int64), 0);
  z("CUSIP 037833100", USCUSIPValidate("037833100" as int64), 0);
  z("CAS 7732-18-5 Wasser", CASValidate("7732-18-5" as int64), 0);
  z("BSN 111222333", NLBSNValidate("111222333" as int64), 0);
  z("AHV 756.1234.5678.97", CHAHVValidate("756.1234.5678.97" as int64), 0);
  z("Luhn 79927398713 gueltig", LuhnValidate("79927398713"), 1);
  z("Luhn 79927398714 falsch", LuhnValidate("79927398714"), 0);
  return 0;
}
EOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/c.log" 2>&1; then
  echo "FAIL Referenzprogramm uebersetzt nicht:"
  grep -i error "$TMP/c.log" | head -5
  echo "Ergebnis: 0 PASS, 1 FAIL"
  exit 1
fi

ausgabe="$("$TMP/p" 2>&1)"
echo "$ausgabe"
PASS=$(printf '%s\n' "$ausgabe" | grep -c '^PASS ')
FAIL=$(printf '%s\n' "$ausgabe" | grep -c '^FAIL ')

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
