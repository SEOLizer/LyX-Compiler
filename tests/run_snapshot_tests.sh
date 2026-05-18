#!/usr/bin/env bash
# Snapshot test runner for the Lyx compiler.
#
# Usage:
#   ./tests/run_snapshot_tests.sh          # run all snapshot tests
#   ./tests/run_snapshot_tests.sh --update # regenerate .expected/.exit files
#   ./tests/run_snapshot_tests.sh foo bar  # run only tests matching those names
#
# Each test lives in tests/snapshot/ and consists of:
#   NAME.lyx      — the Lyx source program
#   NAME.expected — expected stdout (created/updated by --update)
#   NAME.exit     — expected exit code (optional; defaults to 0)
#
# Exit code: 0 if all tests pass, 1 if any fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT_DIR="$REPO_ROOT/tests/snapshot"
LYXC="$REPO_ROOT/lyxc"
TMP_DIR="/tmp/lyx_snapshot_tests"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

UPDATE=0
FILTER=()

for arg in "$@"; do
  if [ "$arg" = "--update" ] || [ "$arg" = "-u" ]; then
    UPDATE=1
  else
    FILTER+=("$arg")
  fi
done

# Build compiler if not present or stale
if [ ! -x "$LYXC" ]; then
  echo "lyxc not found, building..."
  make -C "$REPO_ROOT/compiler" build
fi

mkdir -p "$TMP_DIR"

PASS=0
FAIL=0
SKIP=0

run_test() {
  local lyx_file="$1"
  local name
  name="$(basename "$lyx_file" .lyx)"
  local expected_file="${lyx_file%.lyx}.expected"
  local exit_file="${lyx_file%.lyx}.exit"
  local bin="$TMP_DIR/$name"

  # Apply name filter if any filters were given
  if [ ${#FILTER[@]} -gt 0 ]; then
    local match=0
    for f in "${FILTER[@]}"; do
      if [[ "$name" == *"$f"* ]]; then
        match=1
        break
      fi
    done
    if [ $match -eq 0 ]; then
      SKIP=$((SKIP + 1))
      return
    fi
  fi

  # Compile
  local compile_out
  if ! compile_out=$("$LYXC" "$lyx_file" -o "$bin" 2>&1); then
    if [ $UPDATE -eq 1 ]; then
      echo -e "${YELLOW}SKIP${RESET}  $name  (compile error — skipping update)"
    else
      echo -e "${RED}ERROR${RESET} $name  (compile failed)"
      echo "       $compile_out" | head -5
    fi
    FAIL=$((FAIL + 1))
    return
  fi

  # Run and capture stdout + exit code
  local actual_stdout
  local actual_exit=0
  actual_stdout=$("$bin" 2>/dev/null) || actual_exit=$?

  local expected_exit=0
  if [ -f "$exit_file" ]; then
    expected_exit=$(cat "$exit_file" | tr -d '[:space:]')
  fi

  if [ $UPDATE -eq 1 ]; then
    printf '%s' "$actual_stdout" > "$expected_file"
    printf '%s\n' "$actual_exit"  > "$exit_file"
    echo -e "${GREEN}UPDATE${RESET} $name  (exit:$actual_exit)"
    PASS=$((PASS + 1))
    return
  fi

  if [ ! -f "$expected_file" ]; then
    echo -e "${YELLOW}MISS ${RESET} $name  (no .expected — run with --update to create)"
    FAIL=$((FAIL + 1))
    return
  fi

  local expected_stdout
  expected_stdout=$(cat "$expected_file")

  local ok=1

  if [ "$actual_stdout" != "$expected_stdout" ]; then
    ok=0
    echo -e "${RED}FAIL ${RESET} $name  (stdout mismatch)"
    diff <(echo "$expected_stdout") <(echo "$actual_stdout") | head -20 | sed 's/^/       /'
  fi

  if [ "$actual_exit" != "$expected_exit" ]; then
    ok=0
    echo -e "${RED}FAIL ${RESET} $name  (exit code: expected $expected_exit, got $actual_exit)"
  fi

  if [ $ok -eq 1 ]; then
    echo -e "${GREEN}PASS ${RESET} $name"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Snapshot tests ($(ls "$SNAPSHOT_DIR"/*.lyx 2>/dev/null | wc -l) tests) ==="
echo ""

for lyx_file in "$SNAPSHOT_DIR"/*.lyx; do
  [ -f "$lyx_file" ] || continue
  run_test "$lyx_file"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed${SKIP:+, $SKIP skipped} ==="

[ $FAIL -eq 0 ]
