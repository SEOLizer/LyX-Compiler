#!/usr/bin/env bash
# tools/bench_runtime.sh — Messgeschirr fuer die LAUFZEIT erzeugten Codes (#2195).
#
#   tools/bench_runtime.sh [-n LAEUFE] [-k chacha|arr_add_f32|arr_int] [--nur-pruefen]
#
# Aus dem Auftrag der CPU-Bestandsaufnahme: ChaCha20-Quarter-Round und
# elementweise Array-Kerne gegen GCC und Clang halten. tools/bench_compile.sh
# messt die UEBERSETZUNGSzeit (#2174) — das hier ist die andere Haelfte.
#
# Reihenfolge, und sie ist nicht verhandelbar:
#
#   1. KORREKTHEIT. Jede Fassung gibt eine Pruefsumme aus. Weichen sie
#      voneinander ab, wird NICHT gemessen, sondern gemeldet. Eine
#      Zeitangabe zu einem Programm, das etwas anderes berechnet, ist
#      schlimmer als keine — sie sieht aus wie ein Ergebnis.
#   2. Dann die Zeit, als Median mehrerer Laeufe mit min/max. Ein Lauf ist
#      keine Messung.
#   3. Dann die Zaehler aus `perf stat`, soweit die Maschine sie hergibt.
#
# Was diese Zahlen NICHT sind: eine Aussage ueber andere Maschinen. Takt,
# Cachegroessen und Last verschieben sie. Nur direkt nacheinander erhobene
# Zahlen sind vergleichbar, und das Protokoll nennt deshalb CPU, Compiler und
# Datum mit.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
N=5
KERN=""
NUR_PRUEFEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -k) KERN="$2"; shift 2 ;;
    --nur-pruefen) NUR_PRUEFEN=1; shift ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unbekanntes Argument: $1" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Dass `perf` installiert ist, heisst NICHT, dass es zaehlen darf:
# kernel.perf_event_paranoid >= 3 verbietet es ohne Rechte. Das wird hier
# ausprobiert statt angenommen — sonst bleibt die Zaehlerspalte leer und der
# Bericht sieht aus, als haette die Maschine keine Zahlen hergeben wollen.
HAT_PERF=0; PERF_GRUND=""
if command -v perf >/dev/null 2>&1; then
  if perf stat -x, -e instructions /bin/true >/dev/null 2>&1; then
    HAT_PERF=1
  else
    PERF_GRUND="perf ist da, darf aber nicht zaehlen (kernel.perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?'))"
  fi
else
  PERF_GRUND="perf ist nicht installiert"
fi
command -v clang >/dev/null 2>&1 && HAT_CLANG=1 || HAT_CLANG=0

echo "=== Laufzeitmessung, $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "CPU:      $(LC_ALL=C lscpu | sed -n 's/^Model name: *//p')"
echo "lyxc:     $("$LYXC" --version 2>&1 | head -1)"
echo "gcc:      $(gcc --version 2>/dev/null | head -1)"
if [ "$HAT_CLANG" -eq 1 ]; then echo "clang:    $(clang --version 2>/dev/null | head -1)"; fi
if [ "$HAT_PERF" -eq 0 ]; then
  echo "ZAEHLER:  KEINE — $PERF_GRUND."
  echo "          Gemessen wird nur die Wandzeit. Befehle je Operation, Takte und IPC"
  echo "          fehlen damit; fuer sie braucht es 'sudo sysctl kernel.perf_event_paranoid=1'."
else
  echo "ZAEHLER:  perf stat (Befehle, Takte, IPC)"
fi
echo "Laeufe je Fassung: $N (Median, dazu min/max)"
echo

# Die Groessen sind an den Caches ausgerichtet: ein Feld aus n f32 belegt
# n*4 Byte, und gebraucht werden drei davon. Gemessen wird deshalb bei
# 4 Ki (drei Felder = 48 KiB, im L1), 128 Ki (1,5 MiB, im L2/L3) und 4 Mi
# (48 MiB, ueber dem letzten Cache) — dort entscheidet die Bandbreite.
L1_N=4096;     L1_W=20000
L2_N=131072;   L2_W=600
RAM_N=4194304; RAM_W=20

# --- Hilfen ----------------------------------------------------------------

median_ms() {  # Liste von Millisekunden auf stdin
  sort -n | awk '{v[NR]=$1} END {
    if (NR == 0) { print "-"; exit }
    if (NR % 2) printf "%d", v[(NR+1)/2]; else printf "%d", (v[NR/2] + v[NR/2+1]) / 2
  }'
}

# messe NAME BINARY ARGS...
# Gibt "median min max" in Millisekunden aus.
messe() {
  local bin="$1"; shift
  local ts=()
  local i
  for ((i = 0; i < N; i++)); do
    local t0 t1
    t0=$(date +%s%N)
    ( ulimit -c 0; "$bin" "$@" >/dev/null 2>&1 ) || { echo "LAUFFEHLER"; return 1; }
    t1=$(date +%s%N)
    ts+=( $(( (t1 - t0) / 1000000 )) )
  done
  local med min max
  med=$(printf '%s\n' "${ts[@]}" | median_ms)
  min=$(printf '%s\n' "${ts[@]}" | sort -n | head -1)
  max=$(printf '%s\n' "${ts[@]}" | sort -n | tail -1)
  echo "$med $min $max"
}

# pruefsumme BINARY ARGS...
pruefsumme() {
  local bin="$1"; shift
  ( ulimit -c 0; "$bin" "$@" 2>/dev/null ) | sed -n 's/^checksum=//p' | head -1
}

# zaehler BINARY ARGS...  — eine Zeile mit den perf-Werten, oder leer
zaehler() {
  [ "$HAT_PERF" -eq 1 ] || return 0
  local bin="$1"; shift
  local out
  out=$( ulimit -c 0; perf stat -x, -e instructions,cycles "$bin" "$@" 2>&1 >/dev/null ) || return 0
  local ins cyc
  ins=$(printf '%s\n' "$out" | awk -F, '$3 == "instructions" {print $1}')
  cyc=$(printf '%s\n' "$out" | awk -F, '$3 == "cycles" {print $1}')
  if [ -n "$ins" ] && [ -n "$cyc" ] && [ "$cyc" != "0" ] && [ "$ins" != "<not" ]; then
    awk -v i="$ins" -v c="$cyc" 'BEGIN { printf "%s Befehle, %s Takte, IPC %.2f", i, c, i/c }'
  fi
}

# Groesse des GESAMTEN Befehlsbereichs — nicht die des Kerns. Bei lyxc stehen
# darin Laufzeit und Teile der Standardbibliothek (rund 90 KiB), bei der
# C-Fassung fast nur der Kern. Die Spalte taugt deshalb zum Vergleich
# derselben Sprache ueber Stufen hinweg, NICHT zum Vergleich Lyx gegen C.
# Wer die Kerngroesse braucht, nimmt `objdump -d --disassemble=<symbol>`.
groesse() {
  local bin="$1"
  local n
  n=$(size -A "$bin" 2>/dev/null | awk '$1 == ".text" {print $2}')
  [ -n "$n" ] && echo "$n" || stat -c %s "$bin"
}

FEHLER=0

# --- ein Kern -------------------------------------------------------------
# kern NAME QUELLE_LYX QUELLE_C ARGS...
kern() {
  local name="$1" lyx="$2" cq="$3"; shift 3
  local args=( "$@" )

  echo "--- $name  (${args[*]}) ---"

  # Fassungen bauen. Die Lyx-Seite in allen CPU-Stufen, die etwas aendern
  # koennen; die C-Seite in den ueblichen zwei Graden plus -march=native,
  # damit sichtbar ist, was die Maschine hergibt.
  declare -A bins=()
  if ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$lyx" -o "$TMP/$name.lyx.base" >"$TMP/$name.log" 2>&1 ); then
    bins["lyxc baseline"]="$TMP/$name.lyx.base"
  else
    echo "  FEHLER: $lyx uebersetzt nicht"; sed -n '1,3p' "$TMP/$name.log"; FEHLER=1; return
  fi
  if ( cd "$ROOT" && "$LYXC" --std-path="$ROOT" --target-cpu=avx2 "$lyx" -o "$TMP/$name.lyx.avx2" >/dev/null 2>&1 ); then
    bins["lyxc avx2"]="$TMP/$name.lyx.avx2"
  fi
  if gcc -O2 -o "$TMP/$name.gcc2" "$cq" 2>/dev/null; then bins["gcc -O2"]="$TMP/$name.gcc2"; fi
  if gcc -O3 -march=native -o "$TMP/$name.gcc3" "$cq" 2>/dev/null; then bins["gcc -O3 -march=native"]="$TMP/$name.gcc3"; fi
  if [ "$HAT_CLANG" -eq 1 ]; then
    if clang -O2 -o "$TMP/$name.cl2" "$cq" 2>/dev/null; then bins["clang -O2"]="$TMP/$name.cl2"; fi
    if clang -O3 -march=native -o "$TMP/$name.cl3" "$cq" 2>/dev/null; then bins["clang -O3 -march=native"]="$TMP/$name.cl3"; fi
  fi

  # 1. Korrektheit. Erst wenn alle dasselbe rechnen, wird gemessen.
  local soll="" abweichung=0
  local k
  for k in "${!bins[@]}"; do
    local p
    p=$(pruefsumme "${bins[$k]}" "${args[@]}")
    if [ -z "$p" ]; then
      echo "  FEHLER: $k gibt keine Pruefsumme aus"; abweichung=1; continue
    fi
    if [ -z "$soll" ]; then soll="$p"
    elif [ "$p" != "$soll" ]; then
      echo "  FEHLER: $k rechnet anders (Pruefsumme $p, erwartet $soll)"; abweichung=1
    fi
  done
  if [ "$abweichung" -ne 0 ]; then
    echo "  NICHT GEMESSEN — zuerst die Abweichung klaeren."
    FEHLER=1; return
  fi
  echo "  Pruefsumme $soll in allen ${#bins[@]} Fassungen gleich."
  [ "$NUR_PRUEFEN" -eq 1 ] && { echo; return; }

  # 2. und 3. Zeit und Zaehler.
  local referenz=""
  for k in "lyxc baseline" "lyxc avx2" "gcc -O2" "gcc -O3 -march=native" "clang -O2" "clang -O3 -march=native"; do
    [ -n "${bins[$k]:-}" ] || continue
    local r
    r=$(messe "${bins[$k]}" "${args[@]}") || { echo "  $k: LAUFFEHLER"; FEHLER=1; continue; }
    local med min max
    med=$(echo "$r" | cut -d' ' -f1); min=$(echo "$r" | cut -d' ' -f2); max=$(echo "$r" | cut -d' ' -f3)
    [ -z "$referenz" ] && referenz="$med"
    local verh="-"
    if [ "$med" -gt 0 ] && [ "$referenz" -gt 0 ]; then
      verh=$(awk -v a="$referenz" -v b="$med" 'BEGIN { printf "%.2fx", a/b }')
    fi
    printf "  %-26s %6s ms  (min %s, max %s)  %-8s %7s B .text(ganz)  %s\n" \
      "$k" "$med" "$min" "$max" "$verh" "$(groesse "${bins[$k]}")" "$(zaehler "${bins[$k]}" "${args[@]}")"
  done
  echo "  (Verhaeltnis bezogen auf lyxc baseline; groesser als 1 heisst schneller als diese.)"
  echo "  (.text(ganz) ist der GESAMTE Befehlsbereich — bei lyxc samt Laufzeit und stdlib."
  echo "   Zwischen den Sprachen ist die Spalte deshalb nicht vergleichbar.)"
  echo
}

# --- Laeufe ---------------------------------------------------------------

if [ -z "$KERN" ] || [ "$KERN" = "chacha" ]; then
  # Ganzzahlkern: haengt an Rotationen, nicht an Speicher — eine Groesse genuegt.
  kern "chacha_qr" "bench/chacha_qr.lyx" "$ROOT/bench/chacha_qr.c" 2000000
fi

if [ -z "$KERN" ] || [ "$KERN" = "arr_add_f32" ]; then
  kern "arr_f32_L1"  "bench/arr_add_f32.lyx" "$ROOT/bench/arr_add_f32.c" "$L1_N"  "$L1_W"
  kern "arr_f32_L2"  "bench/arr_add_f32.lyx" "$ROOT/bench/arr_add_f32.c" "$L2_N"  "$L2_W"
  kern "arr_f32_RAM" "bench/arr_add_f32.lyx" "$ROOT/bench/arr_add_f32.c" "$RAM_N" "$RAM_W"
fi

if [ -z "$KERN" ] || [ "$KERN" = "arr_int" ]; then
  # Ganzzahlfelder in 8/16/32 Bit, je add, mul und sum. Dieselben
  # Elementzahlen wie bei f32; bei 8 und 16 Bit belegen die Felder
  # entsprechend weniger Bytes, die Stufen bleiben trotzdem getrennt
  # (4 Ki Elemente im L1, 4 Mi ueber dem letzten Cache).
  for breite in 8 16 32; do
    for op in 1 2 3; do
      case "$op" in 1) opn=add ;; 2) opn=mul ;; 3) opn=sum ;; esac
      kern "int${breite}_${opn}_L1"  "bench/arr_int.lyx" "$ROOT/bench/arr_int.c" "$breite" "$op" "$L1_N"  "$L1_W"
      kern "int${breite}_${opn}_L2"  "bench/arr_int.lyx" "$ROOT/bench/arr_int.c" "$breite" "$op" "$L2_N"  "$L2_W"
      kern "int${breite}_${opn}_RAM" "bench/arr_int.lyx" "$ROOT/bench/arr_int.c" "$breite" "$op" "$RAM_N" "$RAM_W"
    done
  done
fi

if [ "$FEHLER" -ne 0 ]; then
  echo "ERGEBNIS: mindestens ein Kern hat nicht gemessen werden koennen."
  exit 1
fi
echo "ERGEBNIS: alle Kerne gemessen, Pruefsummen gleich."
