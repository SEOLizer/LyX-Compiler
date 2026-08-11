#!/usr/bin/env bash
# Snapshot test runner for the Lyx compiler.
#
# Usage:
#   ./tests/run_snapshot_tests.sh          # run all snapshot tests
#   ./tests/run_snapshot_tests.sh --update # regenerate .expected/.exit files
#   ./tests/run_snapshot_tests.sh foo bar  # run only tests matching those names
#
# Each test lives in tests/snapshot/ and consists of:
#   NAME.lyx           — the Lyx source program
#   NAME.expected      — expected stdout (runtime) or compiler output (compile_fail)
#   NAME.exit          — expected exit code (optional; defaults to 0)
#   NAME.compile_fail  — marker: test expects the compiler to fail (non-zero exit);
#                        .expected then holds the expected compiler stderr/stdout
#
# Exit code: 0 if all tests pass, 1 if any fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT_DIR="$REPO_ROOT/tests/snapshot"
LYXC="$REPO_ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
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

# Compiler-Banner mit Versionsnummer aus einer Ausgabe entfernen.
strip_banner() {
  printf '%s' "$1" | grep -vE '^lyxc [0-9][^ ]* — Copyright'
}

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

  # compile_fail tests: expect the compiler itself to fail
  local compile_fail_file="${lyx_file%.lyx}.compile_fail"
  if [ -f "$compile_fail_file" ]; then
    local cf_out
    local cf_exit=0
    cf_out=$("$LYXC" "$lyx_file" -o "$bin" 2>&1) || cf_exit=$?
    if [ $UPDATE -eq 1 ]; then
      printf '%s' "$cf_out" > "$expected_file"
      echo -e "${GREEN}UPDATE${RESET} $name  (compile_fail)"
      PASS=$((PASS + 1))
    elif [ $cf_exit -eq 0 ]; then
      echo -e "${RED}FAIL ${RESET} $name  (expected compile error, but compiler succeeded)"
      FAIL=$((FAIL + 1))
    elif [ ! -f "$expected_file" ]; then
      echo -e "${YELLOW}MISS ${RESET} $name  (no .expected — run with --update)"
      FAIL=$((FAIL + 1))
    # Die Copyright-Zeile traegt die Compilerversion und veraltet bei jedem
    # Versionsbump — 14_at_if_syntax_dead erwartete noch 0.9.1A und war
    # deshalb rot, ohne dass sich an der geprueften Fehlermeldung etwas
    # geaendert haette. Verglichen wird die Diagnose, nicht das Banner.
    elif [ "$(strip_banner "$cf_out")" = "$(strip_banner "$(cat "$expected_file")")" ]; then
      echo -e "${GREEN}PASS ${RESET} $name"
      PASS=$((PASS + 1))
    else
      echo -e "${RED}FAIL ${RESET} $name  (compile error output mismatch)"
      diff <(strip_banner "$(cat "$expected_file")") <(strip_banner "$cf_out") | head -10 | sed 's/^/       /'
      FAIL=$((FAIL + 1))
    fi
    return
  fi

  # Extra compiler flags from NAME.flags (one flag per line, optional)
  local extra_flags=()
  local flags_file="${lyx_file%.lyx}.flags"
  if [ -f "$flags_file" ]; then
    while IFS= read -r flag; do
      [ -n "$flag" ] && extra_flags+=("$flag")
    done < "$flags_file"
  fi

  # For --migrate-capabilities: output goes to stdout of the COMPILER, not to a binary
  local is_migrate=0
  for f in "${extra_flags[@]}"; do
    [ "$f" = "--migrate-capabilities" ] && is_migrate=1
  done

  # Compile
  local compile_out
  if ! compile_out=$("$LYXC" "$lyx_file" "${extra_flags[@]}" -o "$bin" 2>/dev/null); then
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
  # For --migrate-capabilities: compiler stdout IS the output (no binary to run)
  local actual_stdout
  local actual_exit=0
  if [ $is_migrate -eq 1 ]; then
    actual_stdout=$("$LYXC" "$lyx_file" "${extra_flags[@]}" -o "$bin" 2>/dev/null) || actual_exit=$?
  else
    actual_stdout=$("$bin" 2>/dev/null) || actual_exit=$?
  fi

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

  # Bei --migrate-capabilities ist die Compilerausgabe das Ergebnis; sie
  # beginnt mit dem Versionsbanner, das bei jedem Bump veraltet (wpt14_migrate_fopen
  # erwartete noch 0.9.1A). Verglichen wird der Inhalt, nicht die Version.
  if [ "$(strip_banner "$actual_stdout")" != "$(strip_banner "$expected_stdout")" ]; then
    ok=0
    echo -e "${RED}FAIL ${RESET} $name  (stdout mismatch)"
    diff <(strip_banner "$expected_stdout") <(strip_banner "$actual_stdout") | head -20 | sed 's/^/       /'
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
