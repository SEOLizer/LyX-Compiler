#!/usr/bin/env bash
# Integration test runner for tests/lyx/**/*.lyx
#
# Usage:
#   ./tests/run_lyx_tests.sh                # run all tests
#   ./tests/run_lyx_tests.sh --update       # regenerate .expected files
#   ./tests/run_lyx_tests.sh bootstrap      # only tests whose path contains "bootstrap"
#   ./tests/run_lyx_tests.sh --timeout 30   # custom timeout in seconds (default: 60)
#
# A test passes when:
#   - It has a .expected-error file → the COMPILE must fail and its message must
#     contain the text from that file (#1153)
#   - It has a .expected-exit file  → the exit code must be exactly that number
#     (#1153; fuer Tests, die ihr Ergebnis ueber den Rueckgabewert melden)
#   - It has a .expected file  → stdout must match (trailing newlines normalised)
#   - It has no .expected file → exit code must be 0 (or 42, s.u.)
#
# Library units (no "fn main" in source) are skipped automatically.
#
# tests/lyx-geraet.txt fuehrt Tests, die ein GERAET oder einen DIENST brauchen
# (Soundkarte, MySQL-Server): sie werden UEBERSETZT, aber nicht ausgefuehrt.
#
# Exit code: 0 if all tests pass, 1 if any fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/tests/lyx"
LYXC="${LYXC:-$REPO_ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$REPO_ROOT/.lyx_test_tmp"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

UPDATE=0
TIMEOUT=60
FILTER=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update|-u)    UPDATE=1;      shift ;;
    --timeout|-t)  TIMEOUT="$2";  shift 2 ;;
    *)             FILTER+=("$1"); shift ;;
  esac
done

mkdir -p "$TMP"
BIN="$TMP/_test_bin"

PASS=0; FAIL=0; SKIP=0; KNOWN=0; UNEXPECTED_GREEN=""

# Bekannt rote Tests (tests/known-red.txt): sie laufen mit, ihr Fehlschlag
# bricht den Lauf aber nicht ab. Jeder Eintrag traegt ein Issue — sonst
# verschwindet ein Defekt hier lautlos. Wird ein bekannt roter Test gruen,
# ist DAS ein Fehlschlag: der Eintrag gehoert dann entfernt, sonst deckt die
# Liste mit der Zeit Tests ab, die laengst wieder laufen.
#
# Ein Eintrag darf mit ` !flaky` enden. Das heisst: der Test ist nicht bloss
# rot, sondern nichtdeterministisch — er wird gemeldet, faerbt den Lauf aber in
# keine Richtung. Diese Ausnahme gibt es nur, weil ein Test, dessen Ergebnis
# Stack-Muell ist (tests/lyx/arrays/test_bounds.lyx, #1156), sonst zufaellig
# "wieder gruen" melden wuerde. Sie braucht wie jeder Eintrag ein Issue.
declare -A KNOWN_RED=()
KNOWN_RED_FILE="$REPO_ROOT/tests/known-red.txt"
if [[ -f "$KNOWN_RED_FILE" ]]; then
  while read -r line; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" == *" !flaky" ]]; then
      KNOWN_RED["${line% !flaky}"]=flaky
    else
      KNOWN_RED["$line"]=1
    fi
  done < "$KNOWN_RED_FILE"
fi

# #1153: Tests, die ein GERAET oder einen DIENST auf dem Rechner brauchen.
# Sie werden uebersetzt, aber nicht ausgefuehrt — "uebersetzen ja, ausfuehren
# nein".
#
# Warum nicht einfach in known-red.txt lassen: dort stehen DEFEKTE. Ein Test,
# der eine Soundkarte braucht und keine findet, ist keiner — er misst nur, dass
# dieser Rechner keine hat. In einer Liste mit echten Defekten verwaessert er
# die Aussage, und niemand raeumt sie je ab.
#
# Das Uebersetzen bleibt scharf: bricht es ab, ist das ein FEHLSCHLAG. Genau
# das haelt die Tests am Leben, waehrend ihr Lauf hier nichts messen kann.
declare -A NUR_UEBERSETZEN=()
GERAET_FILE="$REPO_ROOT/tests/lyx-geraet.txt"
if [[ -f "$GERAET_FILE" ]]; then
  while read -r line; do
    line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    NUR_UEBERSETZEN["$line"]=1
  done < "$GERAET_FILE"
fi

# Ergebnis einer Pruefung verbuchen. Erst hier faellt die Entscheidung, damit
# die KNOWN_RED-Behandlung an genau einer Stelle sitzt.
verdict() {
  local status="$1" rel="$2" detail="${3:-}"
  if [[ "${KNOWN_RED[$rel]:-}" == flaky ]]; then
    echo -e "${YELLOW}FLAKY${RESET} $rel  ${detail}  (nichtdeterministisch, bekannt)"
    KNOWN=$((KNOWN+1))
  elif [[ "$status" == pass ]]; then
    if [[ -n "${KNOWN_RED[$rel]+x}" ]]; then
      echo -e "${YELLOW}GRUEN${RESET} $rel  (steht in known-red.txt — Eintrag entfernen)"
      UNEXPECTED_GREEN="$UNEXPECTED_GREEN $rel"
      FAIL=$((FAIL+1))
    else
      echo -e "${GREEN}PASS ${RESET} $rel"
      PASS=$((PASS+1))
    fi
  elif [[ -n "${KNOWN_RED[$rel]+x}" ]]; then
    echo -e "${YELLOW}ROT  ${RESET} $rel  $detail  (bekannt rot)"
    KNOWN=$((KNOWN+1))
  else
    echo -e "${RED}FAIL ${RESET} $rel  $detail"
    FAIL=$((FAIL+1))
  fi
}

run_test() {
  local lyx_file="$1"
  local rel="${lyx_file#$REPO_ROOT/}"
  local name
  name="$(basename "$lyx_file" .lyx)"
  local expected_file="${lyx_file%.lyx}.expected"

  # Filter
  if [[ ${#FILTER[@]} -gt 0 ]]; then
    local match=0
    for f in "${FILTER[@]}"; do
      [[ "$lyx_file" == *"$f"* ]] && match=1 && break
    done
    [[ $match -eq 0 ]] && { SKIP=$((SKIP+1)); return; }
  fi

  # Skip library units (no fn main)
  if ! grep -q 'fn main' "$lyx_file" 2>/dev/null; then
    echo -e "${YELLOW}SKIP ${RESET} $rel  (no fn main — library unit)"
    SKIP=$((SKIP+1))
    return
  fi

  # #1153: Negativtest. Liegt neben der Datei ein .expected-error, MUSS die
  # Uebersetzung scheitern und ihre Meldung den dort hinterlegten Text
  # enthalten. Ohne diese Form sah ein Test, der eine Ablehnung prueft, wie ein
  # kaputter Test aus — und landete in known-red.txt, wo er nichts zu suchen
  # hat.
  #
  # Geprueft wird ein TEILSTRING, nicht der ganze Wortlaut: die Meldung darf
  # sich weiterentwickeln, die Aussage nicht.
  local error_file="${lyx_file%.lyx}.expected-error"
  if [[ -f "$error_file" ]]; then
    local want_err neg_out
    want_err="$(cat "$error_file")"
    want_err="${want_err#"${want_err%%[![:space:]]*}"}"
    want_err="${want_err%"${want_err##*[![:space:]]}"}"
    if neg_out=$(timeout "$TIMEOUT" "$LYXC" "$lyx_file" -o "$BIN" 2>&1); then
      verdict fail "$rel" "[negativtest] uebersetzte klaglos, erwartet war: ${want_err}"
    elif [[ "$neg_out" == *"$want_err"* ]]; then
      verdict pass "$rel"
    else
      verdict fail "$rel" "[negativtest] andere Meldung als erwartet (${want_err})"
    fi
    return
  fi

  # Compile
  local compile_err
  if ! compile_err=$(timeout "$TIMEOUT" "$LYXC" "$lyx_file" -o "$BIN" 2>&1); then
    local msg
    msg=$(echo "$compile_err" | grep -i "error\|parse\|fail" | head -1)
    if [[ $UPDATE -eq 1 ]]; then
      echo -e "${YELLOW}SKIP ${RESET} $rel  (compile error — skipping update)"
      FAIL=$((FAIL+1))
    else
      verdict fail "$rel" "[compile] ${msg}"
    fi
    return
  fi

  # #1153: Geraet oder Dienst noetig — uebersetzt ist er, ausgefuehrt wird er
  # nicht. Das Uebersetzen war die scharfe Haelfte und ist gerade gelungen.
  if [[ -n "${NUR_UEBERSETZEN[$rel]+x}" ]]; then
    echo -e "${YELLOW}GERAET${RESET} $rel  (uebersetzt; Ausfuehrung braucht Geraet/Dienst)"
    KNOWN=$((KNOWN+1))
    return
  fi

  # Run
  local actual_stdout actual_exit=0
  actual_stdout=$(timeout "$TIMEOUT" "$BIN" 2>&1) || actual_exit=$?
  if [[ $actual_exit -eq 124 ]]; then
    verdict fail "$rel" "[timeout after ${TIMEOUT}s]"
    return
  fi

  # Update mode
  if [[ $UPDATE -eq 1 ]]; then
    printf '%s' "$actual_stdout" > "$expected_file"
    echo -e "${GREEN}UPD  ${RESET} $rel  (exit:$actual_exit)"
    PASS=$((PASS+1))
    return
  fi

  # #1153: Erwarteter Rueckgabewert. Manche Tests melden ihr Ergebnis ueber
  # exit(), nicht ueber die Ausgabe — `as/test_defer_lifo` etwa rechnet die
  # LIFO-Reihenfolge zu 2*16+1 = 33 aus und uebergibt sie an exit(). Der Runner
  # kannte nur 0 (und seit #1696 die 42), also war ein solcher Test rot,
  # obwohl er das Richtige tat.
  #
  # Die Zahl steht in einer eigenen Datei, NICHT im Quelltext-Kommentar: sie
  # gehoert zur Pruefung, nicht zur Erklaerung. Und sie wird nur dort angelegt,
  # wo der Test seinen Erwartungswert selbst herleitet — einen beobachteten
  # Wert festzuschreiben hiesse, den Ist-Zustand zum Soll zu erklaeren.
  local exit_file="${lyx_file%.lyx}.expected-exit"
  if [[ -f "$exit_file" ]]; then
    local want_exit
    want_exit="$(tr -d '[:space:]' < "$exit_file")"
    if [[ "$actual_exit" == "$want_exit" ]]; then
      verdict pass "$rel"
    else
      verdict fail "$rel" "[exit=$actual_exit erwartet $want_exit]"
    fi
    return
  fi

  # Compare
  if [[ -f "$expected_file" ]]; then
    local expected_stdout
    expected_stdout=$(cat "$expected_file")
    if [[ "$actual_stdout" == "$expected_stdout" ]]; then
      verdict pass "$rel"
    else
      verdict fail "$rel" "[output mismatch]"
      diff <(echo "$expected_stdout") <(echo "$actual_stdout") \
        | head -10 | sed 's/^/       /'
    fi
  else
    # #1696: Die Erfolgskonvention im Bestand ist uneinheitlich — manche Tests
    # enden mit 0, manche mit 42. `run_lyx_suite.sh` traegt das seit jeher
    # (Zeile 79: `rc -eq 0 || rc -eq 42`), dieser Runner nicht. Damit urteilten
    # zwei Runner ueber dieselben Dateien verschieden.
    #
    # Aufgefallen an tests/lyx/as/test_defer_early_return.lyx: der Eintrag
    # wurde aus tests/known-red.txt gestrichen, ausdruecklich mit der
    # Begruendung "42 ist im Bestand die Erfolgskonvention — der Runner wertet
    # sie inzwischen als gruen". Fuer den anderen Runner galt das nie, und
    # seither war der Test hier rot.
    if [[ $actual_exit -eq 0 || $actual_exit -eq 42 ]]; then
      verdict pass "$rel"
    else
      verdict fail "$rel" "[exit=$actual_exit]"
    fi
  fi
}

total=$(find "$TEST_DIR" -name "*.lyx" | wc -l)
echo "=== Lyx integration tests ($total .lyx files in tests/lyx/) ==="
echo ""

while IFS= read -r -d '' f; do
  run_test "$f"
done < <(find "$TEST_DIR" -name "*.lyx" -print0 | sort -z)

echo ""
echo "=== Results: $PASS passed, $KNOWN known red/geraet, $FAIL failed, $SKIP skipped ==="
if [[ -n "$UNEXPECTED_GREEN" ]]; then
  echo "Wieder gruen, Eintrag in tests/known-red.txt streichen:$UNEXPECTED_GREEN"
fi

[[ $FAIL -eq 0 ]]
