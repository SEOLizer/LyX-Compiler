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

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
LIST="${1:?Listendatei fehlt}"
NAME="${2:-Suite}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Bekannt rote Tests: sie laufen mit, ihr Fehlschlag bricht den Lauf aber nicht
# ab. Jeder Eintrag braucht ein Issue — sonst verschwindet er hier lautlos.
declare -A KNOWN_RED=(
  [lexer_float_dot_test]="#1011 Unterstrich im Float-Literal"
  [meta_safe_test]="#1017 GetPageHash"
  [pdf_text_test]="#1017 pdf_text"
  [pg_08_test]="#1017 pg_08"
  [usb_wp8_test]="#1017 usb_wp8"
  [usb_wp21_test]="#1017 usb_wp21"
  [do_test_transport]="#1017 do_test_transport"
  [wp06_macos_socket]="#1017 macOS-Socket-Test auf Linux"
  [edi06_desadv_test]="#1016 Absturz nach allen PASS (Speicherfehler)"
)

pass=0; fail=0; known=0; failed_names=""

while read -r t; do
  case "$t" in ''|\#*) continue ;; esac
  src="$ROOT/tests/$t.lyx"
  [ -f "$src" ] || { echo "FEHLT   $t (Datei nicht vorhanden)"; fail=$((fail+1)); continue; }

  if ! timeout 120 "$LYXC" --std-path="$ROOT" "$src" -o "$TMP/b" >/dev/null 2>&1; then
    verdict=red; detail="uebersetzt nicht"
  else
    out=$(timeout 30 "$TMP/b" 2>&1); rc=$?
    nf=$(printf '%s' "$out" | grep -ciE "FAIL" || true)
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
