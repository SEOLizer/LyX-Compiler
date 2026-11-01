#!/usr/bin/env bash
# tools/bench_netz.sh — Benchmark 1 der Suite: Funktionsnetz, lyxc gegen GCC/Clang (#2332).
#
#   tools/bench_netz.sh [-f FUNKTIONEN] [-m MODULE] [-w DATENSAETZE]
#                       [-n BUILDS] [-r LAEUFE] [-c LYXC] [-j JOBS]
#                       [--nur-pruefen] [--md DATEI]
#
#   -f/-m/-w  Groesse (Vorgabe 1-S: 2000 Funktionen, 20 Module, 200 Datensaetze)
#   -n        Uebersetzungen je Messpfad, Median daraus (Vorgabe 5)
#   -r        Laufzeitmessungen, Median daraus (Vorgabe 10)
#   -j        Jobs fuer den parallelen C-Build (Vorgabe: nproc)
#   --nur-pruefen   nur Korrektheit, nicht messen
#
# Reihenfolge (nicht verhandelbar):
#
#   1. KORREKTHEIT, ausserhalb jeder Zeitmessung. Lyx-Fassung, C-Fassung und
#      die UNABHAENGIGE Referenz (tools/bench_netz_ref.py, Auswerter ueber der
#      Funktionstabelle) muessen dieselbe Pruefsumme liefern — zusaetzlich bei
#      wenigen Datensaetzen, wo die deutende Referenz noch rechenbar ist.
#      Weicht eine ab, wird gemeldet und NICHT gemessen.
#   2. Uebersetzungszeit auf ZWEI ausdruecklich benannten Messpfaden
#      (work/vorabcheck-2332.md, Punkt 2), je Median mit min/max,
#      dazu CPU-Zeit und Spitzen-RSS des Compilers:
#        A  Quelltext -> ausfuehrbare Datei
#           lyxc: ein Aufruf, schreibt die ELF-Datei selbst, KEINE eigene
#                 Linkphase. GCC/Clang: alle Uebersetzungseinheiten in einem
#                 Aufruf. Zusaetzlich parallel (-j) als EIGENE Zahl — ein
#                 paralleler C-Build ist keine Compilereigenschaft, sondern
#                 eine Eigenschaft des Aufrufs, und darf den seriellen Wert
#                 nicht ersetzen.
#        B  Quelltext -> Objektdateien, Linken separat
#           GCC/Clang: `-c` je Datei, danach `ld` ueber die Objekte.
#           lyxc: `--emit=obj` erzeugt EIN Objekt der ganzen Uebersetzung
#                 (kein Objekt je Modul). Die Zahl steht in der Spalte mit
#                 diesem Vermerk, nicht als vergleichbares Gegenstueck.
#   3. Laufzeit des Erzeugnisses, Median aus -r Laeufen mit min/max.
#
# Was nicht gemessen wird, weil es nicht existiert: LTO und PGO fuer lyxc
# (work/vorabcheck-2332.md, Punkt 3).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
F=2000; M=20; W=200; N=5; R=10; J="$(nproc)"; NUR=0; MD=""

while [ $# -gt 0 ]; do
  case "$1" in
    -f) F="$2"; shift 2 ;;
    -m) M="$2"; shift 2 ;;
    -w) W="$2"; shift 2 ;;
    -n) N="$2"; shift 2 ;;
    -r) R="$2"; shift 2 ;;
    -j) J="$2"; shift 2 ;;
    -c) LYXC="$(readlink -f "$2")"; shift 2 ;;
    --nur-pruefen) NUR=1; shift ;;
    --md) MD="$2"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekanntes Argument: $1" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
Q="$TMP/q"
PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 2"
HAT_CLANG=0; command -v clang >/dev/null 2>&1 && HAT_CLANG=1
HAT_TCC=0;   command -v tcc   >/dev/null 2>&1 && HAT_TCC=1

med()  { printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END{print v[int((NR+1)/2)]}'; }
mini() { printf '%s\n' "$@" | sort -n | head -1; }
maxi() { printf '%s\n' "$@" | sort -n | tail -1; }

echo "=== Benchmark 1: grosse Codebasis mit Funktionsnetz (#2332) ==="
echo "Datum:   $(date +%Y-%m-%d\ %H:%M)"
echo "CPU:     $(LC_ALL=C lscpu | sed -n 's/^Model name: *//p'), $(nproc) Threads"
echo "Groesse: $F Funktionen, $M Module, $W Datensaetze je Lauf"
echo "Compiler: $("$LYXC" --version 2>&1 | head -1); $(gcc --version | head -1)$([ $HAT_CLANG -eq 1 ] && echo "; $(clang --version|head -1)")$([ $HAT_TCC -eq 1 ] && echo "; $(tcc -v 2>&1|head -1)")"
echo "Laeufe:  $N Uebersetzungen, $R Laufzeitmessungen, Median mit min/max"
echo "Systemlast (1 min) vor dem Lauf: $(cut -d' ' -f1 /proc/loadavg)"
[ $HAT_CLANG -eq 1 ] || echo "HINWEIS: clang fehlt (sudo apt install clang) — Spalte bleibt leer, nicht 0."
[ $HAT_TCC -eq 1 ]   || echo "HINWEIS: tcc fehlt (sudo apt install tcc) — Spalte bleibt leer, nicht 0."
echo

python3 -I "$ROOT/tools/gen_bench_netz.py" -f "$F" -m "$M" -w "$W" -o "$Q" || exit 1
echo "  Quelle: $(cat "$Q"/*.lyx | wc -l) Zeilen Lyx, $(cat "$Q"/*.c "$Q"/netz.h | wc -l) Zeilen C, $(ls "$Q"/*.lyx | wc -l) Lyx-Dateien, $(ls "$Q"/*.c | wc -l) C-Dateien"
echo

# ---------------------------------------------------------------- 1. Korrektheit
# Die deutende Referenz ist langsam; sie laeuft mit wenigen Datensaetzen. Der
# Vergleich der uebersetzten Fassungen laeuft zusaetzlich mit der vollen Zahl.
baue_lyx() { ( cd "$ROOT" && ulimit -v 8000000; timeout 1800 "$LYXC" --std-path="$ROOT" -I "$Q" "$Q/netz.lyx" -o "$1" ); }
baue_gcc() { ( ulimit -v 8000000; timeout 1800 gcc -O2 -I "$Q" -o "$1" "$Q/netz.c" "$Q/netz_h.c" "$Q"/netz_k*.c ); }
baue_clang() { ( ulimit -v 8000000; timeout 1800 clang -O2 -I "$Q" -o "$1" "$Q/netz.c" "$Q/netz_h.c" "$Q"/netz_k*.c ); }
# TCC optimiert nicht und kennt kein -O2; der Schalter waere Zierrat. Die
# Zeile heisst deshalb "tcc (ohne Optimierung)" und nicht "tcc -O2".
baue_tcc() { ( ulimit -v 8000000; timeout 1800 tcc -I "$Q" -o "$1" "$Q/netz.c" "$Q/netz_h.c" "$Q"/netz_k*.c ); }

echo "--- Korrektheit (ausserhalb der Zeitmessung) ---"
if ! baue_lyx "$TMP/lyx" >"$TMP/lyx.log" 2>&1; then
  echo "FEHLER: Lyx-Fassung uebersetzt nicht: $(grep -iE 'error|parse' "$TMP/lyx.log" | head -2 | tr '\n' ' ')"; exit 1
fi
if ! baue_gcc "$TMP/gcc" >"$TMP/gcc.log" 2>&1; then
  echo "FEHLER: C-Fassung uebersetzt nicht: $(grep -iE 'error' "$TMP/gcc.log" | head -2 | tr '\n' ' ')"; exit 1
fi
KLEIN=3
REF="$(timeout 3600 python3 -I "$ROOT/tools/bench_netz_ref.py" "$Q/netz_spec.json" "$KLEIN" | tr '\n' ' ' | sed 's/ *$//')"
L_K="$( ulimit -c 0; cd "$TMP" && ./lyx "$KLEIN" | tr '\n' ' ' | sed 's/ *$//')"
C_K="$( ulimit -c 0; cd "$TMP" && ./gcc "$KLEIN" | tr '\n' ' ' | sed 's/ *$//')"
if [ "$REF" = "$L_K" ] && [ "$REF" = "$C_K" ]; then
  echo "PASS  $KLEIN Datensaetze: Lyx == C == Referenz  ($REF)"
else
  echo "FEHLER Pruefsummen weichen ab — nicht gemessen."
  echo "  Referenz: $REF"; echo "  Lyx:      $L_K"; echo "  C:        $C_K"; exit 1
fi
L_V="$( ulimit -c 0; cd "$TMP" && ./lyx "$W" | tr '\n' ' ' | sed 's/ *$//')"
C_V="$( ulimit -c 0; cd "$TMP" && ./gcc "$W" | tr '\n' ' ' | sed 's/ *$//')"
if [ "$L_V" = "$C_V" ]; then
  echo "PASS  $W Datensaetze: Lyx == C  ($L_V)"
else
  echo "FEHLER $W Datensaetze: Lyx '$L_V', C '$C_V' — nicht gemessen."; exit 1
fi
if [ $HAT_TCC -eq 1 ]; then
  if baue_tcc "$TMP/tcc" >"$TMP/tcc.log" 2>&1; then
    T_V="$( ulimit -c 0; cd "$TMP" && ./tcc "$W" | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$T_V" = "$C_V" ]; then echo "PASS  tcc-Fassung gleiche Pruefsumme"
    else echo "FEHLER tcc: '$T_V' — tcc wird nicht gemessen."; HAT_TCC=0; fi
  else
    echo "FEHLER tcc uebersetzt nicht: $(grep -iE 'error' "$TMP/tcc.log" | head -2 | tr '\n' ' ') — wird nicht gemessen."; HAT_TCC=0
  fi
fi
if [ $HAT_CLANG -eq 1 ]; then
  if baue_clang "$TMP/clang" >"$TMP/clang.log" 2>&1; then
    CL_V="$( ulimit -c 0; cd "$TMP" && ./clang "$W" | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$CL_V" = "$C_V" ]; then echo "PASS  clang-Fassung gleiche Pruefsumme"
    else echo "FEHLER clang: '$CL_V' — clang wird nicht gemessen."; HAT_CLANG=0; fi
  else
    echo "FEHLER clang uebersetzt nicht — wird nicht gemessen."; HAT_CLANG=0
  fi
fi
[ "$NUR" -eq 0 ] || exit 0
echo

# ------------------------------------------------- 2. Uebersetzungszeit, 2 Pfade
# mess NAME BEFEHL... — Median der Wandzeit in ms, dazu CPU-Zeit und Spitzen-RSS
# des letzten Laufs (/usr/bin/time, weil die Shell kein RSS kennt).
ZEILEN=()
# VORHER (optional, vor jedem gemessenen Lauf, NICHT in der Zeit): Befehl, der
# die Voraussetzung herstellt. Der Linkschritt braucht die Objektdateien — die
# loeschte der Aufraeumschritt bis 2026-10-31 unmittelbar vor der Messung, und
# der Lauf schlug fehl statt zu messen.
VORHER=""
# OHNE_PIN=1 nimmt die Kernbindung heraus. Ein paralleler Bau auf EINEM Kern
# ist kein paralleler Bau: bis 2026-10-31 lief `gcc -P 8` unter `taskset -c 2`
# und war mit 33 s genauso langsam wie der serielle Lauf (CPU-Zeit == Wandzeit
# verriet es). Fuer alles Serielle bleibt die Bindung, weil ohne sie der Median
# bei kleinen Unterschieden das Vorzeichen kippt.
OHNE_PIN=0
mess() {
  local name="$1"; shift
  local ts=() i t0 pin="$PIN"
  [ "$OHNE_PIN" -eq 0 ] || pin=""
  for ((i = 0; i < N; i++)); do
    rm -f "$TMP"/o_*.o "$TMP/ziel" 2>/dev/null
    if [ -n "$VORHER" ]; then
      $VORHER >/dev/null 2>&1 || { echo "FEHLER $name: Vorbereitung misslang"; return 1; }
    fi
    t0=$(date +%s%N)
    if ! ( $pin "$@" ) >"$TMP/m.log" 2>&1; then
      echo "FEHLER $name: Lauf $i misslang — $(grep -iE 'error' "$TMP/m.log" | head -1)"; return 1
    fi
    ts+=( $(( ($(date +%s%N) - t0) / 1000000 )) )
  done
  local rss cpu
  rm -f "$TMP"/o_*.o "$TMP/ziel" 2>/dev/null
  [ -z "$VORHER" ] || $VORHER >/dev/null 2>&1
  read -r cpu rss < <( /usr/bin/time -f "%U %M" $pin "$@" 2>&1 >/dev/null | tail -1 )
  printf "  %-34s %7s ms (min %s, max %s)   CPU %ss, Spitzen-RSS %s MiB\n" \
    "$name" "$(med "${ts[@]}")" "$(mini "${ts[@]}")" "$(maxi "${ts[@]}")" "$cpu" "$(( ${rss:-0} / 1024 ))"
  ZEILEN+=("$name|$(med "${ts[@]}")|$(mini "${ts[@]}")|$(maxi "${ts[@]}")|$cpu|$(( ${rss:-0} / 1024 ))")
}

# Hilfsskripte, weil die Messpfade mehrere Befehle sind.
cat > "$TMP/c_seriell.sh" <<SH
#!/bin/bash
"\$1" -O2 -I "$Q" -o "$TMP/ziel" "$Q/netz.c" "$Q/netz_h.c" "$Q"/netz_k*.c
SH
cat > "$TMP/c_parallel.sh" <<SH
#!/bin/bash
ls "$Q"/netz.c "$Q"/netz_h.c "$Q"/netz_k*.c | xargs -P $J -I{} \
  bash -c 'o="$TMP/o_\$(basename {} .c).o"; "\$0" -O2 -I "$Q" -c {} -o "\$o"' "\$1" || exit 1
"\$1" -O2 -o "$TMP/ziel" "$TMP"/o_*.o
SH
cat > "$TMP/c_obj.sh" <<SH
#!/bin/bash
for f in "$Q"/netz.c "$Q"/netz_h.c "$Q"/netz_k*.c; do
  "\$1" -O2 -I "$Q" -c "\$f" -o "$TMP/o_\$(basename "\$f" .c).o" || exit 1
done
SH
cat > "$TMP/c_link.sh" <<SH
#!/bin/bash
"\$1" -O2 -o "$TMP/ziel" "$TMP"/o_*.o
SH
cat > "$TMP/t_seriell.sh" <<SH
#!/bin/bash
tcc -I "$Q" -o "$TMP/ziel" "$Q/netz.c" "$Q/netz_h.c" "$Q"/netz_k*.c
SH
cat > "$TMP/t_obj.sh" <<SH
#!/bin/bash
for f in "$Q"/netz.c "$Q"/netz_h.c "$Q"/netz_k*.c; do
  tcc -I "$Q" -c "\$f" -o "$TMP/o_\$(basename "\$f" .c).o" || exit 1
done
SH
cat > "$TMP/t_link.sh" <<SH
#!/bin/bash
tcc -o "$TMP/ziel" "$TMP"/o_*.o
SH
cat > "$TMP/t_parallel.sh" <<SH
#!/bin/bash
ls "$Q"/netz.c "$Q"/netz_h.c "$Q"/netz_k*.c | xargs -P $J -I{} \
  bash -c 'tcc -I "$Q" -c {} -o "$TMP/o_\$(basename {} .c).o"' || exit 1
tcc -o "$TMP/ziel" "$TMP"/o_*.o
SH
chmod +x "$TMP"/c_*.sh "$TMP"/t_*.sh

echo "--- Messpfad A: Quelltext -> ausfuehrbare Datei ---"
mess "lyxc (ELF direkt, keine Linkphase)" "$LYXC" --std-path="$ROOT" -I "$Q" "$Q/netz.lyx" -o "$TMP/ziel"
[ $HAT_TCC -eq 1 ] && mess "tcc (ohne Optimierung, seriell)" "$TMP/t_seriell.sh"
[ $HAT_TCC -eq 1 ] && { OHNE_PIN=1; mess "tcc (parallel -P $J, ohne Kernbindung)" "$TMP/t_parallel.sh"; OHNE_PIN=0; }
mess "gcc -O2 (ein Aufruf, seriell)" "$TMP/c_seriell.sh" gcc
OHNE_PIN=1; mess "gcc -O2 (parallel -P $J, ohne Kernbindung)" "$TMP/c_parallel.sh" gcc; OHNE_PIN=0
if [ $HAT_CLANG -eq 1 ]; then
  mess "clang -O2 (ein Aufruf, seriell)" "$TMP/c_seriell.sh" clang
  OHNE_PIN=1; mess "clang -O2 (parallel -P $J, ohne Kernbindung)" "$TMP/c_parallel.sh" clang; OHNE_PIN=0
fi
echo
echo "--- Messpfad B: Quelltext -> Objektdateien (Linken separat) ---"
mess "lyxc --emit=obj (EIN Objekt, ganze Uebersetzung)" "$LYXC" --std-path="$ROOT" --emit=obj -I "$Q" "$Q/netz.lyx" -o "$TMP/ziel"
if [ $HAT_TCC -eq 1 ]; then
  mess "tcc -c je Datei" "$TMP/t_obj.sh"
  VORHER="$TMP/t_obj.sh"; mess "tcc Linken der Objekte" "$TMP/t_link.sh"; VORHER=""
fi
mess "gcc -O2 -c je Datei" "$TMP/c_obj.sh" gcc
VORHER="$TMP/c_obj.sh gcc"; mess "gcc Linken der Objekte" "$TMP/c_link.sh" gcc; VORHER=""
if [ $HAT_CLANG -eq 1 ]; then
  mess "clang -O2 -c je Datei" "$TMP/c_obj.sh" clang
  VORHER="$TMP/c_obj.sh clang"; mess "clang Linken der Objekte" "$TMP/c_link.sh" clang; VORHER=""
fi

# ------------------------------------------------------------------ 3. Laufzeit
echo
echo "--- Laufzeit des Erzeugnisses ($W Datensaetze, $R Laeufe) ---"
LZEILEN=()
laufzeit() {
  local name="$1" bin="$2" ts=() i t0
  for ((i = 0; i < R; i++)); do
    t0=$(date +%s%N)
    ( ulimit -c 0; $PIN "$bin" "$W" ) >/dev/null 2>&1
    ts+=( $(( ($(date +%s%N) - t0) / 1000000 )) )
  done
  printf "  %-34s %7s ms (min %s, max %s)   Erzeugnis %s KiB\n" \
    "$name" "$(med "${ts[@]}")" "$(mini "${ts[@]}")" "$(maxi "${ts[@]}")" "$(( $(stat -c%s "$bin") / 1024 ))"
  LZEILEN+=("$name|$(med "${ts[@]}")|$(mini "${ts[@]}")|$(maxi "${ts[@]}")|$(( $(stat -c%s "$bin") / 1024 ))")
}
laufzeit "lyxc" "$TMP/lyx"
[ $HAT_TCC -eq 1 ] && laufzeit "tcc (ohne Optimierung)" "$TMP/tcc"
laufzeit "gcc -O2" "$TMP/gcc"
[ $HAT_CLANG -eq 1 ] && laufzeit "clang -O2" "$TMP/clang"

echo
echo "Pruefsumme: $C_V"
echo "Systemlast (1 min) nach dem Lauf: $(cut -d' ' -f1 /proc/loadavg)"
echo "LTO/PGO: fuer lyxc nicht unterstuetzt (work/vorabcheck-2332.md) — nicht gemessen."

if [ -n "$MD" ]; then
  {
    echo "# Benchmark 1: grosse Codebasis mit Funktionsnetz — $F Funktionen, $M Module"
    echo
    echo "Stand: $(date +%Y-%m-%d) · $(LC_ALL=C lscpu | sed -n 's/^Model name: *//p') ·"
    echo "$N Uebersetzungen und $R Laufzeitmessungen je Eintrag, Median mit min/max ·"
    echo "$("$LYXC" --version 2>&1 | head -1), $(gcc --version | head -1)."
    echo "Erhoben mit \`tools/bench_netz.sh -f $F -m $M -w $W -n $N -r $R\`."
    echo "Pruefsumme Lyx == C == unabhaengige Referenz: \`$C_V\`."
    echo
    echo "## Uebersetzungszeit"
    echo
    echo "| Messpfad | Median | min/max | CPU | Spitzen-RSS |"
    echo "|---|---|---|---|---|"
    for z in "${ZEILEN[@]}"; do IFS='|' read -r n m lo hi cpu rss <<<"$z"
      echo "| $n | ${m} ms | ${lo}/${hi} ms | ${cpu} s | ${rss} MiB |"; done
    echo
    echo "## Laufzeit ($W Datensaetze)"
    echo
    echo "| Fassung | Median | min/max | Erzeugnis |"
    echo "|---|---|---|---|"
    for z in "${LZEILEN[@]}"; do IFS='|' read -r n m lo hi gr <<<"$z"
      echo "| $n | ${m} ms | ${lo}/${hi} ms | ${gr} KiB |"; done
    echo
    echo "## Grenzen"
    echo
    echo "- Messpfad B ist fuer lyxc **kein** Gegenstueck zu \`gcc -c\`: \`--emit=obj\` erzeugt"
    echo "  ein Objekt der ganzen Uebersetzung, nicht eines je Modul."
    echo "- Der parallele C-Build steht als eigene Zahl und laeuft OHNE Kernbindung"
    echo "  (auf einem Kern waere er keiner); er ersetzt den seriellen Wert nicht."
    echo "- Alle uebrigen Zeiten sind auf einen Kern gebunden (\`taskset -c 2\`)."
    echo "- LTO und PGO gibt es fuer lyxc nicht (work/vorabcheck-2332.md)."
    echo "- Die Referenz ist ein Auswerter ueber der Funktionstabelle"
    echo "  (\`tools/bench_netz_ref.py\`), keine dritte Uebersetzung; sie laeuft mit"
    echo "  $KLEIN Datensaetzen ausserhalb der Zeitmessung."
    [ $HAT_CLANG -eq 1 ] || echo "- clang war nicht installiert — Spalte fehlt, statt 0 zu melden."
    [ $HAT_TCC -eq 1 ] || echo "- tcc war nicht installiert — Spalte fehlt, statt 0 zu melden."
    [ $HAT_TCC -eq 1 ] && echo "- **tcc steht ohne Optimierungsschalter**: TCC optimiert nicht, \`-O2\` waere Zierrat."
  } > "$MD"
  echo; echo "Markdown: $MD"
fi
