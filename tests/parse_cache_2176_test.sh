#!/usr/bin/env bash
# tests/parse_cache_2176_test.sh — #2176: eine Unit wird einmal geparst.
#
# Bis 1.2.26A las und parste der Codegen jede importierte Unit ein zweites Mal
# selbst (strace: 81 verschiedene Units, 163 Dateioeffnungen). sema hinterlegt
# ihren Baum jetzt in src/parse_cache.lyx, der Codegen uebernimmt ihn.
#
# Geprueft wird die WIRKUNG an den Zaehlern der Zeitlinie, nicht die Zeit: eine
# Zusicherung ueber Takte haengt an der Rechengeschwindigkeit (so wurde
# integrity_test.sh in #2298 rot). Die Zaehler sagen, was wirklich passiert
# ist — wie viele Baeume hinterlegt und wie viele uebernommen wurden.
#
# Dazu die Korrektheitsseite, denn ein geteilter Baum ist genau dann gefaehrlich,
# wenn er UNVOLLSTAENDIG weitergegeben wird:
#   * der Wert aus einer importierten Konstante muss stimmen (sie kam bei
#     einem frueheren Fehler dieser Art still als 0 an, #1966),
#   * eine Funktion aus dem Import muss laufen,
#   * zwei Units, die sich gegenseitig nicht kennen, duerfen sich nicht
#     vermischen: gleiche Knotennummern in verschiedenen Tabellen sind der
#     Normalfall, nicht die Ausnahme.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/u"
cat > "$TMP/u/eins.lyx" <<'LYX'
unit u.eins;
pub con EINS_WERT: int64 := 4711;
pub fn einsMal(x: int64): int64 { return x * 3; }
LYX
cat > "$TMP/u/zwei.lyx" <<'LYX'
unit u.zwei;
pub con ZWEI_WERT: int64 := 1234;
pub fn zweiPlus(x: int64): int64 { return x + 7; }
LYX
cat > "$TMP/haupt.lyx" <<'LYX'
unit main;
import std.io;
import u.eins;
import u.zwei;
fn main(): int64 {
  PrintStr("eins="c); PrintInt(EINS_WERT);
  PrintStr(" zwei="c); PrintInt(ZWEI_WERT);
  PrintStr(" f="c); PrintInt(einsMal(5));
  PrintStr(" g="c); PrintInt(zweiPlus(5));
  PrintStr("\n"c);
  return 0;
}
LYX

# ------------------------------------------------------------------
# A. Die Werte. Gegengerechnet: 4711, 1234, 5*3 = 15, 5+7 = 12.
# ------------------------------------------------------------------
if ! (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" -I"$TMP" --time-trace="$TMP/tt.json" "$TMP/haupt.lyx" -o "$TMP/haupt" >"$TMP/bau.log" 2>&1); then
  no "uebersetzen" "$(grep -m1 -iE 'error|lyxc:' "$TMP/bau.log")"
else
  got=$( cd "$TMP" && timeout 30 ./haupt 2>&1 )
  erw="eins=4711 zwei=1234 f=15 g=12"
  if [ "$got" = "$erw" ]; then ok "werte: $got"; else no "werte" "'$got' erwartet '$erw'"; fi
fi

# ------------------------------------------------------------------
# B. Die Zaehler: jede hinterlegte Unit wird auch uebernommen.
#
# Gleichheit ist die scharfe Form. "Treffer > 0" waere auch erfuellt, wenn nur
# eine von vielen Units aus dem Cache kaeme — und der Rest weiter doppelt
# geparst wuerde, also genau der Zustand, den dieser Test ausschliessen soll.
# ------------------------------------------------------------------
if [ -f "$TMP/tt.json" ]; then
  werte=$(python3 -I -c "
import json,sys
d=json.load(open('$TMP/tt.json'))
ev=d['traceEvents'] if isinstance(d,dict) else d
for e in ev:
    a=e.get('args',{})
    if 'parse_cache_treffer' in a:
        print(a['parse_cache_eintraege'], a['parse_cache_treffer']); break
else:
    print('-1 -1')
" 2>/dev/null)
  ein=${werte%% *}; tre=${werte##* }
  if [ "$ein" = "-1" ]; then
    no "zaehler" "keine parse_cache-Zaehler in der Zeitlinie"
  elif [ "$ein" -lt 2 ]; then
    no "zaehler" "nur $ein Baum hinterlegt, erwartet mindestens 2 (u.eins, u.zwei)"
  elif [ "$ein" != "$tre" ]; then
    no "zaehler" "$ein hinterlegt, aber nur $tre uebernommen — der Rest wird doppelt geparst"
  else
    ok "zaehler: $ein Baeume hinterlegt, $tre uebernommen"
  fi
else
  no "zaehler" "keine Zeitlinie entstanden"
fi

# ------------------------------------------------------------------
# C. Ohne Zeitlinie darf sich nichts aendern: die Zaehler sind Messung, der
#    Cache wirkt immer. Dasselbe Erzeugnis, Byte fuer Byte.
# ------------------------------------------------------------------
if (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" -I"$TMP" "$TMP/haupt.lyx" -o "$TMP/haupt2" >"$TMP/bau2.log" 2>&1); then
  if cmp -s "$TMP/haupt" "$TMP/haupt2"; then ok "erzeugnis ohne --time-trace bitgleich"
  else no "erzeugnis" "mit und ohne --time-trace verschieden"; fi
else
  no "zweiter bau" "$(grep -m1 -iE 'error|lyxc:' "$TMP/bau2.log")"
fi

# ------------------------------------------------------------------
# D. #2314: ein Treffer heisst auch, dass NICHT gelesen wurde.
#
# Bis 1.2.26B teilte der Cache nur den Baum: der Codegen las die Datei
# vorher trotzdem vollstaendig und verwarf den Puffer gleich wieder
# (164 Oeffnungen fuer 82 Dateien im Selbstbau). `lesen_gespart` muss
# deshalb GLEICH `treffer` sein — jede uebernommene Unit ist eine
# eingesparte Lesung. Steht die Zahl darunter, liest noch jemand doppelt.
# ------------------------------------------------------------------
if [ -f "$TMP/tt.json" ]; then
  w2=$(python3 -I -c "
import json
d=json.load(open('$TMP/tt.json'))
ev=d['traceEvents'] if isinstance(d,dict) else d
for e in ev:
    a=e.get('args',{})
    if 'parse_cache_treffer' in a:
        print(a['parse_cache_treffer'], a.get('parse_cache_lesen_gespart','-1')); break
else:
    print('-1 -1')
" 2>/dev/null)
  tre2=${w2%% *}; gesp=${w2##* }
  if [ "$gesp" = "-1" ]; then
    no "lesen_gespart" "Zaehler parse_cache_lesen_gespart fehlt in der Zeitlinie"
  elif [ "$gesp" != "$tre2" ]; then
    no "lesen_gespart" "$tre2 Treffer, aber nur $gesp ohne Lesung — der Rest wird doppelt gelesen"
  else
    ok "lesen_gespart: $gesp von $tre2 Treffern ohne zweite Lesung"
  fi
fi

# ------------------------------------------------------------------
# E. #2314 an der WIRKUNG: jede Unit wird genau einmal geoeffnet.
#
# Der Zaehler oben sagt, was der Compiler ueber sich selbst meldet; hier
# zaehlt das Betriebssystem mit. Ohne strace wird uebersprungen, nicht
# stillschweigend fuer gut erklaert.
# ------------------------------------------------------------------
if command -v strace >/dev/null 2>&1; then
  if (cd "$TMP" && timeout 300 strace -f -e trace=openat,open -o "$TMP/op.txt" \
        "$LYXC" --std-path="$ROOT" -I"$TMP" "$TMP/haupt.lyx" -o "$TMP/haupt3" >"$TMP/bau3.log" 2>&1); then
    mehrfach=$(grep -o '"[^"]*u/[a-z]*\.lyx"' "$TMP/op.txt" | sort | uniq -c | awk '$1 > 1 {print $2" ("$1"x)"}')
    anz=$(grep -o '"[^"]*u/[a-z]*\.lyx"' "$TMP/op.txt" | sort -u | wc -l)
    if [ "$anz" -lt 2 ]; then
      no "oeffnungen" "nur $anz Unit-Datei(en) in der strace-Ausgabe gefunden — Zaehlung greift nicht"
    elif [ -n "$mehrfach" ]; then
      no "oeffnungen" "mehrfach geoeffnet: $mehrfach"
    else
      ok "oeffnungen: $anz Units, jede genau einmal geoeffnet"
    fi
  else
    no "strace-lauf" "$(grep -m1 -iE 'error|lyxc:' "$TMP/bau3.log")"
  fi
else
  echo "SKIP oeffnungen: strace nicht vorhanden"
fi

# ------------------------------------------------------------------
# F. #2314: der Pfad der Unit kommt mit aus dem Cache.
#
# Beim Treffer oeffnet der Codegen die Datei nicht mehr und kennt ihren Pfad
# also nicht aus eigener Anschauung. Daran haengt aber, wo `@embed` einer
# importierten Unit sucht: relativ zu IHRER Datei, nicht zum Hauptprogramm
# (#1971). Die Vorlage liegt deshalb NUR in u/ — findet der Compiler sie,
# stimmt der Pfad; fehlt er, bricht die Uebersetzung ab oder nimmt eine
# fremde Datei.
#
# Gegenseite: dieselbe Vorlage liegt mit ANDEREM Inhalt neben dem
# Hauptprogramm. Ein Test, der nur "uebersetzt durch" prueft, waere auch
# erfuellt, wenn die falsche Datei genommen wuerde.
#
# Dieser Teil waere vor #2314 GRUEN gewesen — er ist eine Klammer um den neuen
# Weg, keine Wiedergabe des Defekts: bis dahin kannte der Codegen den Pfad aus
# seiner eigenen Lesung. Rot wird er, sobald der Pfad nicht mehr aus dem Cache
# mitkommt. Die Defektseite von #2314 prueft Teil E.
# ------------------------------------------------------------------
mkdir -p "$TMP/r/u"
printf 'aus-der-unit' > "$TMP/r/u/vorlage.txt"
printf 'aus-dem-hauptprogramm' > "$TMP/r/vorlage.txt"
cat > "$TMP/r/u/drei.lyx" <<'LYX'
unit u.drei;
pub fn DreiText(): pchar { return @embed("vorlage.txt"); }
pub fn DreiLen(): int64 { return @embed_len("vorlage.txt"); }
LYX
cat > "$TMP/r/haupt.lyx" <<'LYX'
unit main;
import std.io;
import u.drei;
fn main(): int64 { PrintStr(DreiText()); PrintStr("\n"c); return 0; }
LYX
if (cd "$TMP/r" && timeout 200 "$LYXC" --std-path="$ROOT" -I"$TMP/r" "$TMP/r/haupt.lyx" -o "$TMP/r/haupt" >"$TMP/r/bau.log" 2>&1); then
  istr=$( cd "$TMP/r" && timeout 30 ./haupt 2>&1 )
  if [ "$istr" = "aus-der-unit" ]; then
    ok "embed-pfad: @embed der Unit aus u/ genommen"
  elif [ "$istr" = "aus-dem-hauptprogramm" ]; then
    no "embed-pfad" "Vorlage neben dem Hauptprogramm genommen — der Pfad der Unit fehlt (#1971/#2314)"
  else
    no "embed-pfad" "unerwartete Ausgabe '$istr'"
  fi
else
  no "embed-pfad" "$(grep -v Copyright "$TMP/r/bau.log" | grep -m1 -iE 'error|lyxc:')"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
