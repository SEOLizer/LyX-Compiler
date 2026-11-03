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
# #2343 Schritt 3: ohne LC_ALL=C gibt awk die Nachkommastelle mit Komma aus,
# und printf "%f" lehnt sie ab ("Ungueltige Zahl") -- die Zeile blieb leer,
# und die Tabelle sah nach einer Messung ohne Wert aus.
LC_ALL=C
export LC_ALL
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

einLauf() { # $@ = Zusatzargumente; gibt eine Dauer in ns aus
  rm -f "$TMP/app" "$TMP/p.json"
  local t0 t1
  t0=$(date +%s%N)
  $PIN "$LYXC" --std-path="$ROOT" "$QUELLE" -o "$TMP/app" "$@" >/dev/null 2>&1
  t1=$(date +%s%N)
  echo $((t1 - t0))
}

# Gemessen wird ABWECHSELND: ein Lauf ohne Schalter, dann einer mit, N mal.
# Blockweise gemessen wanderte die Maschine waehrend des Blocks -- in einem
# ersten Lauf kam `analysis` dadurch 12 % SCHNELLER heraus als `aus`, bei
# einer Spanne von 22 %. Ein Vorzeichen aus einem solchen Aufbau ist Zufall.
paare() { # $@ = Zusatzargumente der B-Fassung; schreibt "a b" je Zeile
  local i=0
  while [ "$i" -lt "$N" ]; do
    local a b
    a=$(einLauf)
    b=$(einLauf "$@")
    echo "$a $b"
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

# Der Median der paarweisen Differenz. Er ist die belastbare Zahl dieses
# Aufbaus: jedes Paar liegt zeitlich beieinander, eine Drift der Maschine
# trifft beide Haelften.
paarkennzahl() { # liest "a b" je Zeile; gibt "medA medB medDiffProzent" aus
  awk '
    { a[NR] = $1; b[NR] = $2; d[NR] = ($2 / $1 - 1) * 100 }
    function med(arr, n,   c, i, j, t) {
      for (i = 1; i <= n; i++) c[i] = arr[i]
      for (i = 1; i < n; i++) for (j = i + 1; j <= n; j++)
        if (c[j] < c[i]) { t = c[i]; c[i] = c[j]; c[j] = t }
      return (n % 2) ? c[(n+1)/2] : (c[n/2] + c[n/2+1]) / 2
    }
    END {
      if (NR == 0) { print "0 0 0"; exit }
      printf "%d %d %.2f\n", med(a, NR), med(b, NR), med(d, NR)
    }'
}

echo "Last:        $QUELLE"
echo "Compiler:    $($LYXC --version 2>&1 | head -1)"
echo "Laeufe:      $N je Fassung${PIN:+, gepinnt auf Kern $KERN}"
echo "Maschine:    $(uname -m), $(nproc) Kerne"
echo

# Rauschboden zuerst: N Paare aus zwei IDENTISCHEN Laeufen ohne Schalter.
# Was dieser Aufbau als Unterschied ausgibt, wo keiner sein kann, ist die
# Schwelle, unter der keine Aussage moeglich ist.
read -r r_a r_b r_d <<<"$(paare | paarkennzahl)"
printf 'Rauschboden (aus gegen aus): %+.2f %%, Median %.1f ms\n\n' "$r_d" \
  "$(awk -v v="$r_a" 'BEGIN{print v/1000000}')"

printf '%-12s %14s %14s %14s %12s\n' Fassung "aus (ms)" "mit (ms)" "Spanne mit" "Paardiff."
for fassung in basic analysis detailed; do
  werte=$(paare --compile-profile="$TMP/p.json" --compile-profile-level="$fassung")
  read -r med_a med_b diff <<<"$(echo "$werte" | paarkennzahl)"
  read -r _ mn mx <<<"$(echo "$werte" | awk '{print $2}' | kennzahl)"
  printf '%-12s %14.1f %14.1f %6.1f-%-7.1f %+11.2f %%\n' \
    "$fassung" \
    "$(awk -v v="$med_a" 'BEGIN{print v/1000000}')" \
    "$(awk -v v="$med_b" 'BEGIN{print v/1000000}')" \
    "$(awk -v v="$mn"    'BEGIN{print v/1000000}')" \
    "$(awk -v v="$mx"    'BEGIN{print v/1000000}')" \
    "$diff"
done

echo
# Die Zeile "Rauschboden" ist die Schwelle: dort stehen zwei identische
# Fassungen gegeneinander, ein Unterschied kann es nicht geben. Was eine
# Fassung darunter ausgibt, ist mit diesem Aufbau nicht nachgewiesen.
echo "Hinweis: die Paardifferenz ist die belastbare Zahl -- jedes Paar liegt"
echo "         zeitlich beieinander, eine Drift trifft beide Haelften. Liegt sie"
echo "         unter dem Rauschboden, ist sie nicht nachgewiesen. Fuer eine"
echo "         belastbare Aussage die Maschine ruhig halten und N erhoehen."
