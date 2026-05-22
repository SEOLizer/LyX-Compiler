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
#   - It has a .expected file  → stdout must match (trailing newlines normalised)
#   - It has no .expected file → exit code must be 0
#
# Library units (no "fn main" in source) are skipped automatically.
#
# Exit code: 0 if all tests pass, 1 if any fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/tests/lyx"
LYXC="$REPO_ROOT/lyxc"
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

PASS=0; FAIL=0; SKIP=0

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

  # Compile
  local compile_err
  if ! compile_err=$(timeout "$TIMEOUT" "$LYXC" "$lyx_file" -o "$BIN" 2>&1); then
    local msg
    msg=$(echo "$compile_err" | grep -i "error\|parse\|fail" | head -1)
    if [[ $UPDATE -eq 1 ]]; then
      echo -e "${YELLOW}SKIP ${RESET} $rel  (compile error — skipping update)"
    else
      echo -e "${RED}FAIL ${RESET} $rel  [compile] ${msg}"
    fi
    FAIL=$((FAIL+1))
    return
  fi

  # Run
  local actual_stdout actual_exit=0
  actual_stdout=$(timeout "$TIMEOUT" "$BIN" 2>&1) || actual_exit=$?
  if [[ $actual_exit -eq 124 ]]; then
    echo -e "${RED}FAIL ${RESET} $rel  [timeout after ${TIMEOUT}s]"
    FAIL=$((FAIL+1))
    return
  fi

  # Update mode
  if [[ $UPDATE -eq 1 ]]; then
    printf '%s' "$actual_stdout" > "$expected_file"
    echo -e "${GREEN}UPD  ${RESET} $rel  (exit:$actual_exit)"
    PASS=$((PASS+1))
    return
  fi

  # Compare
  if [[ -f "$expected_file" ]]; then
    local expected_stdout
    expected_stdout=$(cat "$expected_file")
    if [[ "$actual_stdout" == "$expected_stdout" ]]; then
      echo -e "${GREEN}PASS ${RESET} $rel"
      PASS=$((PASS+1))
    else
      echo -e "${RED}FAIL ${RESET} $rel  [output mismatch]"
      diff <(echo "$expected_stdout") <(echo "$actual_stdout") \
        | head -10 | sed 's/^/       /'
      FAIL=$((FAIL+1))
    fi
  else
    if [[ $actual_exit -eq 0 ]]; then
      echo -e "${GREEN}PASS ${RESET} $rel"
      PASS=$((PASS+1))
    else
      echo -e "${RED}FAIL ${RESET} $rel  [exit=$actual_exit]"
      FAIL=$((FAIL+1))
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
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

[[ $FAIL -eq 0 ]]
