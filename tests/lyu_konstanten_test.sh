#!/usr/bin/env bash
# tests/lyu_konstanten_test.sh — #2014 Stufe 1: Konstantenwerte in der .lyu,
# und #2033: die Laengenangaben der eingebauten Konstanten.
#
# Bis 1.2.5G trug eine `.lyu` Namen und Typen, aber KEINE Werte. Der Codegen
# brach beim Import ohne Quelle ausdruecklich ab — mit der Begruendung "ohne
# diesen Abbruch kaeme jede Konstante daraus still als 0 an". Genau diese
# Luecke schliesst der Konstantenabschnitt.
#
# GEMESSEN WIRD DER WERT, nicht die Uebersetzbarkeit: ein Test auf "uebersetzt
# durch" waere auch von einer Fassung erfuellt, die den Abbruch einfach
# entfernt — und dann kaeme wieder still die 0, vor der die alte Meldung
# gewarnt hat.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

echo "--- #2033: Laengenangaben der eingebauten Konstanten ---"
#
# `cg_addCon("MAP_ANONYMOUS"c, 12, 32)` — der Name hat 13 Zeichen. Die
# Konstante lag als "MAP_ANONYMOU" in der Tabelle, `MAP_ANONYMOUS` fand sie
# nie und wurde still 0. sema kennt den Namen und liess ihn durch; erst diese
# Kombination macht daraus einen stillen Fehler.
cat > "$TMP/mapc.lyx" <<'EOF'
unit main;
import std.io;
fn main(): int64 {
  PrintLn(IntToStr(MAP_ANONYMOUS));
  PrintLn(IntToStr(MAP_ANON));
  PrintLn(IntToStr(MAP_PRIVATE));
  PrintLn(IntToStr(PROT_RW));
  return 0;
}
EOF
if ( cd "$ROOT" && timeout 120 "$LYXC" "$TMP/mapc.lyx" -o "$TMP/mapc" ) >"$TMP/mapc.log" 2>&1; then
  aus="$(timeout 60 "$TMP/mapc" 2>&1 | tr '\n' '|')"
  if [ "$aus" = "32|34|2|3|" ]; then
    ok "MAP_ANONYMOUS=32, MAP_ANON=34, MAP_PRIVATE=2, PROT_RW=3"
  else
    nok "eingebaute Konstanten falsch: [$aus] (erwartet 32|34|2|3|)"
  fi
else
  nok "das Konstanten-Pruefprogramm uebersetzt nicht"
fi

# Der eigentliche Waechter: JEDE Laengenangabe gegen die Zeichenzahl. Ohne ihn
# bringt die naechste hinzugefuegte Zeile denselben Fehler mit, und er faellt
# wieder erst am falschen WERT auf.
n_falsch="$(python3 - "$ROOT/src/codegen_x86.lyx" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
bad = [(m.group(1), len(m.group(1)), int(m.group(2)))
       for m in re.finditer(r'cg_addCon\("([^"]+)"c,\s*(\d+),', s)
       if len(m.group(1)) != int(m.group(2))]
for b in bad:
    print("  %s: %d Zeichen, angegeben %d" % b, file=sys.stderr)
print(len(bad))
PY
)"
if [ "$n_falsch" = "0" ]; then
  ok "alle Laengenangaben in cg_addBuiltinCons stimmen mit der Zeichenzahl ueberein"
else
  nok "$n_falsch Laengenangabe(n) falsch — siehe stderr"
fi

echo
echo "--- #2014 Stufe 1: Konstantenwerte ueberleben ohne die Quelle ---"
mkdir -p "$TMP/w/bib"
cat > "$TMP/w/bib/werte.lyx" <<'EOF'
unit bib.werte;
pub con MAX: int64 := 42;
pub con MIN: int64 := 0 - 7;
pub con GROSS: int64 := 4294967296;
pub con MASKE: int64 := 1 << 8;
pub con NAME: pchar := "biblio";
pub con ESC: pchar := "a\tb";
EOF
cat > "$TMP/w/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.werte;
fn main(): int64 {
  PrintLn(IntToStr(MAX));
  PrintLn(IntToStr(MIN));
  PrintLn(IntToStr(GROSS));
  PrintLn(IntToStr(MASKE));
  PrintLn(NAME);
  PrintLn(ESC);
  PrintLn(IntToStr(StrLen(NAME)));
  return 0;
}
EOF
# Erwartung nachgerechnet: 1 << 8 = 256; "a\tb" sind drei Zeichen, davon eines
# ein Tabulator; StrLen("biblio") = 6.
ERW="42|-7|4294967296|256|biblio|a	b|6|"

( cd "$TMP/w" && timeout 120 "$LYXC" --compile-unit bib/werte.lyx -o bib/werte.lyu ) >"$TMP/cu.log" 2>&1
if [ ! -f "$TMP/w/bib/werte.lyu" ]; then
  nok "die Unit laesst sich nicht vorkompilieren"; echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi

# Referenz MIT Quelle — sonst vergleicht der Test zwei Fehler.
if ( cd "$TMP/w" && timeout 120 "$LYXC" --std-path="$ROOT" haupt.lyx -o mit ) >"$TMP/mit.log" 2>&1; then
  aus="$(cd "$TMP/w" && timeout 60 ./mit 2>/dev/null | tr '\n' '|')"
  if [ "$aus" = "$ERW" ]; then
    ok "mit Quelle: die nachgerechneten Werte kommen heraus"
  else
    nok "mit Quelle unerwartet: [$aus]"
  fi
else
  nok "mit Quelle uebersetzt das Programm nicht"
fi

# Jetzt die QUELLE WEGNEHMEN — nur die .lyu bleibt.
mv "$TMP/w/bib/werte.lyx" "$TMP/werte.weg"
if ( cd "$TMP/w" && timeout 120 "$LYXC" --std-path="$ROOT" haupt.lyx -o ohne ) >"$TMP/ohne.log" 2>&1; then
  aus="$(cd "$TMP/w" && timeout 60 ./ohne 2>/dev/null | tr '\n' '|')"
  if [ "$aus" = "$ERW" ]; then
    ok "OHNE Quelle: dieselben Werte — inkl. 0-7, 2^32, Schiebeausdruck und Escape"
  else
    nok "OHNE Quelle weichen die Werte ab: [$aus] (erwartet [$ERW])"
  fi
else
  nok "OHNE Quelle bricht die Uebersetzung ab: $(grep -m1 -E 'error' "$TMP/ohne.log")"
fi

# GEGENPROBE 1: Sobald die Unit etwas enthaelt, das der Abschnitt NICHT traegt
# — eine Funktion braucht Code (Stufe 5) —, muss der Abbruch bleiben. Ohne
# diese Haelfte waere der Test auch von einer Fassung erfuellt, die den
# Abbruch pauschal entfernt; dann kaeme wieder still die 0.
mkdir -p "$TMP/f/bib"
cat > "$TMP/f/bib/mitfn.lyx" <<'EOF'
unit bib.mitfn;
pub con W: int64 := 5;
pub fn Doppel(x: int64): int64 { return x * 2; }
EOF
cat > "$TMP/f/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.mitfn;
fn main(): int64 { PrintLn(IntToStr(W)); PrintLn(IntToStr(Doppel(4))); return 0; }
EOF
( cd "$TMP/f" && timeout 120 "$LYXC" --compile-unit bib/mitfn.lyx -o bib/mitfn.lyu ) >/dev/null 2>&1
mv "$TMP/f/bib/mitfn.lyx" "$TMP/mitfn.weg"
if ( cd "$TMP/f" && timeout 120 "$LYXC" --std-path="$ROOT" haupt.lyx -o hx ) >"$TMP/hx.log" 2>&1; then
  nok "eine Unit MIT Funktion ging ohne Quelle durch — der Code fehlt, das Ergebnis waere still falsch"
else
  if grep -q "Quelle der importierten Unit nicht lesbar" "$TMP/hx.log"; then
    ok "Unit mit Funktion wird ohne Quelle weiterhin abgewiesen (Code fehlt, Stufe 5)"
  else
    nok "abgewiesen, aber mit anderer Begruendung: $(grep -m1 -E 'error' "$TMP/hx.log")"
  fi
fi

# GEGENPROBE 2: Eine Konstante, deren Wert sich NICHT ausrechnen laesst, darf
# nicht mit einem geratenen Wert in der Bibliothek landen. Sie fehlt im
# Abschnitt — und weil damit etwas verloren ginge, bleibt der Abbruch.
mkdir -p "$TMP/u/bib"
cat > "$TMP/u/bib/unklar.lyx" <<'EOF'
unit bib.unklar;
pub var BASIS: int64 := 5;
pub con ABGELEITET: int64 := BASIS;
EOF
cat > "$TMP/u/haupt.lyx" <<'EOF'
unit main;
import std.io;
import bib.unklar;
fn main(): int64 { PrintLn(IntToStr(ABGELEITET)); return 0; }
EOF
( cd "$TMP/u" && timeout 120 "$LYXC" --compile-unit bib/unklar.lyx -o bib/unklar.lyu ) >"$TMP/u.log" 2>&1
if [ -f "$TMP/u/bib/unklar.lyu" ]; then
  mv "$TMP/u/bib/unklar.lyx" "$TMP/unklar.weg"
  if ( cd "$TMP/u" && timeout 120 "$LYXC" --std-path="$ROOT" haupt.lyx -o hu ) >"$TMP/hu.log" 2>&1; then
    wert="$(cd "$TMP/u" && timeout 60 ./hu 2>/dev/null)"
    nok "nicht ausrechenbare Konstante ging ohne Quelle durch und lieferte [$wert]"
  else
    ok "nicht ausrechenbare Konstante: kein geratener Wert, der Abbruch bleibt"
  fi
else
  ok "die Unit mit nicht ausrechenbarer Konstante wird schon beim Vorkompilieren abgewiesen"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
