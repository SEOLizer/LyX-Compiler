#!/usr/bin/env bash
# tools/bench_compile.sh — Messgeschirr fuer die Uebersetzungszeit (#2174).
#
#   tools/bench_compile.sh [-n LAEUFE] [-c COMPILER] [QUELLE ...]
#
# Uebersetzt jede Quelle LAEUFE-mal (Vorgabe 10) und meldet den Median der
# Wandzeit, dazu min/max und die Messumgebung. Ohne Quelle: der Selbstbau
# (src/lyxc.lyx). Mit --time-trace je Quelle einmal zusaetzlich die
# Phasenaufteilung. Zahlen nur direkt nacheinander vergleichen — die Last der
# Maschine verschiebt sie stark.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N=10; LYXC="$ROOT/lyxc"
while getopts "n:c:" o; do
  case $o in n) N=$OPTARG ;; c) LYXC=$(readlink -f "$OPTARG") ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || set -- src/lyxc.lyx
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Compiler: $LYXC ($("$LYXC" --version 2>&1 | head -1))"
echo "CPU: $(LC_ALL=C lscpu | sed -n 's/^Model name: *//p'), $(nproc) Threads, $(LC_ALL=C free -g | awk '/^Mem/{print $2}') GB RAM"
echo "Laeufe je Quelle: $N"
for src in "$@"; do
  ts=()
  for ((i = 0; i < N; i++)); do
    t0=$(date +%s%N)
    ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$src" -o "$TMP/b" >/dev/null 2>&1 ) || { echo "FEHLER: $src uebersetzt nicht"; exit 1; }
    ts+=( $(( ($(date +%s%N) - t0) / 1000000 )) )
  done
  sortiert=( $(printf '%s\n' "${ts[@]}" | sort -n) )
  med=${sortiert[$((N / 2))]}
  echo "$src: Median ${med} ms (min ${sortiert[0]}, max ${sortiert[$((N - 1))]})"
  ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" --time-trace="$TMP/t.json" "$src" -o "$TMP/b" >/dev/null 2>&1 )
  python3 -I - "$TMP/t.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["traceEvents"]:
    print(f"  {e['name']:<18} {e['dur'] / 1000:>9.0f} ms")
o = d["otherData"]
print(f"  CPU {o['cpu_us'] / 1000:.0f} ms, Spitzen-RSS {o['peak_rss_kb'] / 1024:.0f} MB")
PY
done
