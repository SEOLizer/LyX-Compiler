#!/usr/bin/env bash
# tools/bench_profil_overhead.sh — was kostet --compile-profile? (#2343)
#
# Gemessen wird die UEBERSETZUNGSZEIT derselben Last in vier Fassungen:
# ohne Schalter, basic, analysis, detailed. Ausgegeben werden Median und
# Streuung, nicht ein Mittelwert ueber einen Lauf.
#
# Warum so umstaendlich: ein Gewinn oder Verlust im Bereich weniger Prozent
# kippt auf dieser Maschine ohne Pinning das Vorzeichen. Darum taskset auf
# einen festen Kern, mehrere Wiederholungen und die Spanne im Bericht. Ein
# Null-Overhead-Versprechen gibt dieses Skript nicht her und soll es nicht.
#
# Aufruf:
#   tools/bench_profil_overhead.sh [-n WIEDERHOLUNGEN] [-q QUELLE] [-c LYXC]

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
N=9
QUELLE="$ROOT/src/lyxc.lyx"   # die groesste Last, die das Repo selbst hergibt
KERN=2

while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -q) QUELLE="$2"; shift 2 ;;
    -c) LYXC="$(readlink -f "$2")"; shift 2 ;;
    -k) KERN="$2"; shift 2 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

if [ ! -x "$LYXC" ]; then echo "FEHLER: $LYXC ist nicht ausfuehrbar" >&2; exit 1; fi
if [ ! -f "$QUELLE" ]; then echo "FEHLER: $QUELLE fehlt" >&2; exit 1; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PIN=""
if command -v taskset >/dev/null; then PIN="taskset -c $KERN"; else
  echo "WARNUNG: taskset fehlt — ohne Pinning ist ein Unterschied unter 5 % nicht belastbar" >&2
fi

# Einmal warmlaufen, damit der erste Lauf nicht die Dateisystem-Caches zahlt.
$PIN "$LYXC" --std-path="$ROOT" "$QUELLE" -o "$TMP/warm" >/dev/null 2>&1 || {
  echo "FEHLER: die Last uebersetzt nicht" >&2; exit 1; }

messe() { # $@ = Zusatzargumente; gibt N Dauern in ns aus
  local i=0
  while [ "$i" -lt "$N" ]; do
    rm -f "$TMP/app" "$TMP/p.json"
    local t0 t1
    t0=$(date +%s%N)
    $PIN "$LYXC" --std-path="$ROOT" "$QUELLE" -o "$TMP/app" "$@" >/dev/null 2>&1
    t1=$(date +%s%N)
    echo $((t1 - t0))
    i=$((i + 1))
  done
}

kennzahl() { # liest Dauern von stdin, gibt "median min max" aus
  sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print "0 0 0"; exit }
      m = (NR % 2) ? v[(NR+1)/2] : int((v[NR/2] + v[NR/2+1]) / 2)
      print m, v[1], v[NR]
    }'
}

echo "Last:        $QUELLE"
echo "Compiler:    $($LYXC --version 2>&1 | head -1)"
echo "Laeufe:      $N je Fassung${PIN:+, gepinnt auf Kern $KERN}"
echo "Maschine:    $(uname -m), $(nproc) Kerne"
echo

basis_med=""
printf '%-12s %14s %14s %14s %9s\n' Fassung "Median (ms)" "min (ms)" "max (ms)" "gegen aus"
for fassung in aus basic analysis detailed; do
  case "$fassung" in
    aus)   werte=$(messe) ;;
    *)     werte=$(messe --compile-profile="$TMP/p.json" --compile-profile-level="$fassung") ;;
  esac
  read -r med mn mx <<<"$(echo "$werte" | kennzahl)"
  if [ -z "$basis_med" ]; then
    basis_med="$med"
    rel="—"
  else
    rel=$(awk -v a="$med" -v b="$basis_med" 'BEGIN{ printf "%+.2f %%", (a/b - 1) * 100 }')
  fi
  printf '%-12s %14.1f %14.1f %14.1f %9s\n' \
    "$fassung" \
    "$(awk -v v="$med" 'BEGIN{print v/1000000}')" \
    "$(awk -v v="$mn"  'BEGIN{print v/1000000}')" \
    "$(awk -v v="$mx"  'BEGIN{print v/1000000}')" \
    "$rel"
done

echo
# Die Spanne der Basisfassung ist der Rauschboden. Liegt ein Unterschied
# darunter, ist er mit diesem Aufbau nicht nachgewiesen — das gehoert in den
# Bericht, nicht in eine Fussnote.
echo "Hinweis: Unterschiede innerhalb der min/max-Spanne der Fassung 'aus' sind"
echo "         mit diesem Aufbau nicht nachgewiesen. Fuer eine belastbare Aussage"
echo "         die Maschine ruhig halten und N erhoehen."
