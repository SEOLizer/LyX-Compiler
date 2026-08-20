#!/usr/bin/env bash
# tests/run_lyx_suite.sh — führt eine Liste von .lyx-Tests aus und beurteilt sie.
#
# Warum ein eigener Runner: die Erfolgskonvention ist im Bestand uneinheitlich.
# Manche Tests liefern 0, manche 42, und die `edi*`-Familie druckt „ALL PASS"
# und endet trotzdem mit Exit 1. Wer stur auf Exit 0 prüft, meldet grüne Tests
# als rot — genau daran wäre eine naive Verdrahtung gescheitert.
#
# Deshalb entscheidet die AUSGABE: eine `FAIL`-Zeile ist rot, `PASS`/`OK:` ohne
# `FAIL` ist grün. Der Exit-Code zählt nur, wenn die Ausgabe nichts hergibt —
# und ein Absturz (Signal, rc >= 128) ist immer rot, auch bei vorheriger
# PASS-Ausgabe.
#
# Aufruf:  run_lyx_suite.sh <listendatei> [name]
# Die Listendatei enthält einen Testnamen je Zeile (ohne .lyx), `#` ist Kommentar.
# Hinter dem Namen dürfen Übersetzungsoptionen stehen, die NUR dieser Test
# braucht — etwa `meta_safe_test --meta-safe`. Ohne diese Möglichkeit lief
# meta_safe_test zwangsläufig rot: er prüft eine ELF-Sektion, die der Compiler
# nur mit dieser Option anlegt (#1017).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
LIST="${1:?Listendatei fehlt}"
NAME="${2:-Suite}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Bekannt rote Tests: sie laufen mit, ihr Fehlschlag bricht den Lauf aber nicht
# ab. Jeder Eintrag braucht ein Issue — sonst verschwindet er hier lautlos.
declare -A KNOWN_RED=(
  # #1299 ist behoben: das Array-Literal steht jetzt im Datenbereich, der Test
  # urteilt selbst (PASS/FAIL) statt nur zu drucken. Der Eintrag ist damit weg —
  # so verlangt es die Regel, denn ein gruen gewordener Eintrag faerbt das Ziel
  # rot, bis er verschwindet.
  [__keine__]=""
)

pass=0; fail=0; known=0; failed_names=""

while read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  # Erstes Wort = Testname, Rest = testeigene Übersetzungsoptionen.
  # Ein `#` beendet die Zeile — sonst landete der Kommentar als Option beim
  # Compiler.
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//')"
  t="${line%% *}"
  if [ "$line" = "$t" ]; then extra=""; else extra="${line#* }"; fi
  src="$ROOT/tests/$t.lyx"
  [ -f "$src" ] || { echo "FEHLT   $t (Datei nicht vorhanden)"; fail=$((fail+1)); continue; }

  # #1150: `!compileonly` unter den Optionen heisst "uebersetzen, nicht
  # ausfuehren". Gebraucht fuer Tests, die fuer ein ANDERES Ziel uebersetzen
  # (win64, macos, arm64): ihr Ergebnis liesse sich hier nicht starten, ihr
  # UEBERSETZEN ist aber genau das, was sie pruefen. Ohne die Moeglichkeit
  # blieben sie entweder rot oder muessten geloescht werden — beides verliert
  # die Abdeckung.
  compileonly=0
  case " $extra " in *" !compileonly "*) compileonly=1; extra="${extra//!compileonly/}" ;; esac

  if ! timeout 120 "$LYXC" $extra --std-path="$ROOT" "$src" -o "$TMP/b" >/dev/null 2>&1; then
    verdict=red; detail="uebersetzt nicht"
  elif [ "$compileonly" -eq 1 ]; then
    verdict=green; detail="uebersetzt (nicht ausgefuehrt)"
  else
    out=$(timeout 30 "$TMP/b" 2>&1); rc=$?
    # #1017: FAIL nur als MARKIERUNG am Zeilenanfang und GROSS geschrieben.
    # Vorher war es eine Teilzeichenkettensuche ohne Ruecksicht auf Gross- und
    # Kleinschreibung — sie traf gewoehnliche Woerter in gruenen Zeilen
    # ("OK: upool in_use=0 after failed submit", "lseek failure",
    # "PGTxFailed on null safe") und faerbte drei einwandfreie Tests rot.
    nf=$(printf '%s' "$out" | grep -cE "^[[:space:]]*FAIL" || true)
    np=$(printf '%s' "$out" | grep -ciE "PASS|OK:" || true)
    if   [ "$rc" -ge 128 ]; then verdict=red;   detail="Absturz (rc=$rc)"
    elif [ "$rc" -eq 124 ]; then verdict=red;   detail="Zeitueberschreitung"
    elif [ "$nf" -gt 0 ];   then verdict=red;   detail="$nf FAIL-Zeile(n)"
    elif [ "$np" -gt 0 ];   then verdict=green; detail="$np PASS"
    elif [ "$rc" -eq 0 ] || [ "$rc" -eq 42 ]; then verdict=green; detail="rc=$rc, keine Ausgabe"
    else verdict=red; detail="rc=$rc ohne Ausgabe"
    fi
  fi

  if [ "$verdict" = green ]; then
    pass=$((pass+1))
  elif [ -n "${KNOWN_RED[$t]+x}" ]; then
    known=$((known+1)); echo "BEKANNT ROT  $t — ${KNOWN_RED[$t]}"
  else
    fail=$((fail+1)); failed_names="$failed_names $t"
    echo "FAIL    $t ($detail)"
  fi
done < "$LIST"

echo "$NAME: $pass gruen, $known bekannt rot, $fail unerwartet rot"
if [ "$fail" -gt 0 ]; then
  echo "Unerwartet rot:$failed_names"
  exit 1
fi
exit 0
