#!/usr/bin/env bash
# tools/bench_vergleich.sh — lyxc gegen TCC, GCC, Clang und Cranelift (#2332).
#
#   tools/bench_vergleich.sh [-n LAEUFE] [-f FUNKTIONEN] [-w WDH] [-c LYXC]
#                            [-l] [--md DATEI]
#
#   -n LAEUFE       Uebersetzungen je Compiler, Median daraus (Vorgabe 5)
#   -f FUNKTIONEN   Groesse der Last (Vorgabe 2000 Funktionen)
#   -w WDH          Wiederholungen beim Laufzeitteil (Vorgabe 2000); 0 = nur
#                   Pruefsumme, keine Laufzeitmessung
#   -c LYXC         anderer lyxc (Vorgabe ./lyxc)
#   -l              nur auflisten, welche Compiler da sind und welche fehlen
#   --md DATEI      Ergebnis zusaetzlich als Markdown-Tabelle schreiben
#
# Gemessen wird der GANZE Weg Quelle -> lauffaehiges Programm, denn das ist,
# was „Kompiliergeschwindigkeit" im Alltag heisst. Das ist fuer lyxc kein
# Vorteil und kein Nachteil mit Sternchen: lyxc schreibt die ELF-Datei
# selbst, die C-Compiler rufen `ld`, rustc ruft es ebenfalls. Wer nur die
# Codeerzeugung vergleichen will, misst etwas anderes — dann -c/-C-Varianten
# ergaenzen, nicht diese Zahlen umdeuten.
#
# Reihenfolge wie in tools/bench_runtime.sh, und sie ist nicht verhandelbar:
#   1. KORREKTHEIT. Jede Fassung gibt `checksum=<zahl>` aus. Weicht eine ab,
#      wird sie NICHT gemessen, sondern gemeldet. Eine Zeit zu einem
#      Programm, das etwas anderes rechnet, sieht aus wie ein Ergebnis.
#   2. Dann die Zeit als Median mehrerer Laeufe, mit min/max.
#   3. Dann Groesse des Erzeugnisses und Laufzeit.
#
# Ein fehlender Compiler wird MIT GRUND genannt, nicht uebergangen — sonst
# liest sich eine halbe Tabelle wie eine vollstaendige. Was fehlt, sagt -l.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
N=5; FUNK=2000; WDH=2000; NUR_LISTE=0; MD=""

while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -f) FUNK="$2"; shift 2 ;;
    -w) WDH="$2"; shift 2 ;;
    -c) LYXC="$(readlink -f "$2")"; shift 2 ;;
    -l) NUR_LISTE=1; shift ;;
    --md) MD="$2"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekanntes Argument: $1" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------- Compilertabelle
# Je Eintrag: id | Sprache | Anzeigename | Pruefbefehl | Uebersetzungsbefehl.
# Im Uebersetzungsbefehl steht %Q fuer die Quelle und %Z fuer das Ziel.
# Cranelift ist kein eigenes Programm, sondern ein Backend von rustc; der
# Pruefbefehl muss deshalb die Backend-Bibliothek belegen, nicht nur rustc.
CRANELIFT_SO="$(ls "$HOME"/.rustup/toolchains/nightly-*/lib/rustlib/*/codegen-backends/librustc_codegen_cranelift-*.so 2>/dev/null | head -1)"
COMPILER=(
  "lyxc|lyx|lyxc|test -x $LYXC|$LYXC --std-path=$ROOT %Q -o %Z"
  "tcc|c|tcc|command -v tcc|tcc -o %Z %Q"
  "gcc-O0|c|gcc -O0|command -v gcc|gcc -O0 -o %Z %Q"
  "gcc-O2|c|gcc -O2|command -v gcc|gcc -O2 -o %Z %Q"
  "gcc-O3n|c|gcc -O3 -march=native|command -v gcc|gcc -O3 -march=native -o %Z %Q"
  "clang-O0|c|clang -O0|command -v clang|clang -O0 -o %Z %Q"
  "clang-O2|c|clang -O2|command -v clang|clang -O2 -o %Z %Q"
  "cranelift|rust|rustc cranelift -O0|test -n '$CRANELIFT_SO'|rustc +nightly -Zcodegen-backend=cranelift -Copt-level=0 -o %Z %Q"
  "rustc-O0|rust|rustc llvm -O0|command -v rustc|rustc +nightly -Copt-level=0 -o %Z %Q"
  "rustc-O2|rust|rustc llvm -O2|command -v rustc|rustc +nightly -Copt-level=2 -o %Z %Q"
)

version() { # id -> Versionszeile, einzeilig
  case "$1" in
    lyxc) "$LYXC" --version 2>&1 | head -1 ;;
    tcc) tcc -v 2>&1 | head -1 ;;
    gcc-*) gcc --version 2>&1 | head -1 ;;
    clang-*) clang --version 2>&1 | head -1 ;;
    cranelift) echo "$(rustc +nightly --version 2>&1 | head -1) + $(basename "$CRANELIFT_SO")" ;;
    rustc-*) rustc +nightly --version 2>&1 | head -1 ;;
  esac
}

DA=(); FEHLT=()
for e in "${COMPILER[@]}"; do
  IFS='|' read -r id spr name pruef bau <<<"$e"
  if eval "$pruef" >/dev/null 2>&1; then DA+=("$e"); else FEHLT+=("$id"); fi
done

hinweis() { # id -> wie man ihn bekommt
  case "$1" in
    tcc) echo "sudo apt install tcc" ;;
    clang-*) echo "sudo apt install clang" ;;
    cranelift) echo "rustup toolchain install nightly -c rustc-codegen-cranelift-preview" ;;
    rustc-*) echo "rustup toolchain install nightly" ;;
    lyxc) echo "make bootstrap" ;;
    *) echo "unbekannt" ;;
  esac
}

if [ "$NUR_LISTE" -eq 1 ]; then
  echo "vorhanden:"
  for e in "${DA[@]}"; do IFS='|' read -r id spr name pruef bau <<<"$e"
    printf "  %-12s %s\n" "$id" "$(version "$id")"; done
  if [ ${#FEHLT[@]} -gt 0 ]; then
    echo "fehlt:"
    for id in "${FEHLT[@]}"; do printf "  %-12s %s\n" "$id" "$(hinweis "$id")"; done
  fi
  exit 0
fi

if [ ${#DA[@]} -lt 2 ]; then
  echo "FEHLER: weniger als zwei Compiler vorhanden — nichts zu vergleichen." >&2
  for id in "${FEHLT[@]}"; do printf "  fehlt %-12s %s\n" "$id" "$(hinweis "$id")" >&2; done
  exit 1
fi

# -------------------------------------------------------------------- Umgebung
CPU="$(LC_ALL=C lscpu | sed -n 's/^Model name: *//p')"
LAST_VOR="$(cut -d' ' -f1 /proc/loadavg)"
echo "=== lyxc gegen TCC/GCC/Clang/Cranelift — Uebersetzungszeit (#2332) ==="
echo "Datum:   $(date +%Y-%m-%d\ %H:%M)"
echo "CPU:     $CPU, $(nproc) Threads, $(LC_ALL=C free -g | awk '/^Mem/{print $2}') GB RAM"
echo "Last:    $FUNK Funktionen je Fassung, generiert von tools/gen_bench_last.sh"
echo "Laeufe:  $N Uebersetzungen je Compiler (Median), Laufzeit mit $WDH Wiederholungen"
echo "Systemlast (1 min) vor dem Lauf: $LAST_VOR"
# Die Groessenspalte vergleicht NICHT drei Sprachen miteinander: rustc bindet
# die Rust-Standardbibliothek statisch ein (ein paar MB), lyxc und die
# C-Compiler linken gegen die vorhandene libc bzw. schreiben die ELF-Datei
# selbst. Innerhalb einer Sprache ist die Spalte aussagekraeftig, quer nicht.
if [ ${#FEHLT[@]} -gt 0 ]; then
  echo "NICHT gemessen, weil nicht vorhanden:"
  for id in "${FEHLT[@]}"; do printf "  %-12s -> %s\n" "$id" "$(hinweis "$id")"; done
fi
echo

"$ROOT/tools/gen_bench_last.sh" -n "$FUNK" -o "$TMP/q" >/dev/null || exit 1
wc -l "$TMP/q"/last.* | sed 's/^/  /' | grep -v insgesamt
echo

# `taskset` auf einen Kern: ohne Pinning kippt der Median bei kleinen
# Unterschieden das Vorzeichen (CLAUDE.md, Takte: taskset + Median).
PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 2"

med() { printf '%s\n' "$@" | sort -n | awk '{v[NR]=$1} END{print v[int((NR+1)/2)]}'; }
mini() { printf '%s\n' "$@" | sort -n | head -1; }
maxi() { printf '%s\n' "$@" | sort -n | tail -1; }

SOLL=""; ZEILEN=(); FEHLER=0
for e in "${DA[@]}"; do
  IFS='|' read -r id spr name pruef bau <<<"$e"
  case "$spr" in
    lyx) Q="$TMP/q/last.lyx" ;;
    c)   Q="$TMP/q/last.c" ;;
    rust) Q="$TMP/q/last.rs" ;;
  esac
  Z="$TMP/bin.$id"
  befehl="${bau//%Q/$Q}"; befehl="${befehl//%Z/$Z}"

  # 1. Korrektheit zuerst: uebersetzen, laufen lassen, Pruefsumme vergleichen.
  if ! ( cd "$TMP" && ulimit -v 8000000; eval "timeout 900 $befehl" ) >"$TMP/log.$id" 2>&1; then
    echo "FEHLER $name: uebersetzt die Last nicht — $(grep -iE 'error|fehler' "$TMP/log.$id" | head -2 | tr '\n' ' ')"
    FEHLER=1; continue
  fi
  got="$( ulimit -c 0; cd "$TMP" && timeout 300 "$Z" 1 2>/dev/null )"
  if [ -z "$SOLL" ]; then SOLL="$got"; fi
  if [ "$got" != "$SOLL" ]; then
    echo "FEHLER $name: Pruefsumme '$got', erwartet '$SOLL' — nicht gemessen."
    FEHLER=1; continue
  fi

  # 2. Uebersetzungszeit.
  zt=()
  for ((i = 0; i < N; i++)); do
    rm -f "$Z"
    t0=$(date +%s%N)
    ( cd "$TMP" && ulimit -v 8000000; eval "timeout 900 $PIN $befehl" ) >/dev/null 2>&1 \
      || { echo "FEHLER $name: Lauf $i misslang"; FEHLER=1; break; }
    zt+=( $(( ($(date +%s%N) - t0) / 1000000 )) )
  done
  [ ${#zt[@]} -eq "$N" ] || continue
  cmed=$(med "${zt[@]}")

  # 3. Groesse und Laufzeit des Erzeugnisses.
  groesse=$(( $(stat -c%s "$Z") / 1024 ))
  lmed="-"
  if [ "$WDH" -gt 0 ]; then
    lt=()
    for ((i = 0; i < 3; i++)); do
      t0=$(date +%s%N)
      ( ulimit -c 0; cd "$TMP" && timeout 600 $PIN "$Z" "$WDH" ) >/dev/null 2>&1
      lt+=( $(( ($(date +%s%N) - t0) / 1000000 )) )
    done
    lmed=$(med "${lt[@]}")
  fi

  printf "%-22s uebersetzen %6s ms (min %s, max %s)  Erzeugnis %5s KiB  Laufzeit %7s ms\n" \
    "$name" "$cmed" "$(mini "${zt[@]}")" "$(maxi "${zt[@]}")" "$groesse" "$lmed"
  ZEILEN+=("$id|$name|$cmed|$(mini "${zt[@]}")|$(maxi "${zt[@]}")|$groesse|$lmed|$(version "$id")")
done

echo
echo "Pruefsumme aller gemessenen Fassungen: $SOLL"
echo "Systemlast (1 min) nach dem Lauf: $(cut -d' ' -f1 /proc/loadavg)"

# Verhaeltnis zu lyxc — ohne lyxc in der Liste gibt es keinen Bezugspunkt,
# dann wird auch keiner erfunden.
BASIS=""
for z in "${ZEILEN[@]}"; do IFS='|' read -r id _ cmed _ _ _ _ _ <<<"$z"; [ "$id" = lyxc ] && BASIS="$cmed"; done
if [ -n "$BASIS" ] && [ "$BASIS" -gt 0 ]; then
  echo
  echo "Uebersetzungszeit im Verhaeltnis zu lyxc (> 1 = langsamer als lyxc):"
  for z in "${ZEILEN[@]}"; do IFS='|' read -r id name cmed _ _ _ _ _ <<<"$z"
    printf "  %-22s %s\n" "$name" "$(awk -v a="$cmed" -v b="$BASIS" 'BEGIN{printf "%.2f", a/b}')"
  done
fi

if [ -n "$MD" ]; then
  {
    echo "# Uebersetzungszeit: lyxc gegen TCC/GCC/Clang/Cranelift"
    echo
    echo "Stand: $(date +%Y-%m-%d) · $CPU · Last: $FUNK Funktionen (tools/gen_bench_last.sh) ·"
    echo "$N Uebersetzungen je Compiler, Median der Wandzeit, Quelle -> lauffaehiges Programm."
    echo "Pruefsumme aller Fassungen gleich: \`$SOLL\`. Erhoben mit \`tools/bench_vergleich.sh\`."
    echo
    echo "| Compiler | Uebersetzen (Median) | min/max | Erzeugnis | Laufzeit ($WDH Wdh.) | Verhaeltnis zu lyxc | Version |"
    echo "|---|---|---|---|---|---|---|"
    for z in "${ZEILEN[@]}"; do IFS='|' read -r id name cmed cmin cmax gr lz ver <<<"$z"
      v="-"; [ -n "$BASIS" ] && v="$(awk -v a="$cmed" -v b="$BASIS" 'BEGIN{printf "%.2f", a/b}')"
      echo "| \`$name\` | ${cmed} ms | ${cmin}/${cmax} ms | ${gr} KiB | ${lz} ms | $v | ${ver} |"
    done
    if [ ${#FEHLT[@]} -gt 0 ]; then
      echo
      echo "Nicht gemessen, weil nicht installiert:"
      for id in "${FEHLT[@]}"; do echo "- \`$id\` — \`$(hinweis "$id")\`"; done
    fi
  } > "$MD"
  echo; echo "Markdown: $MD"
fi

[ "$FEHLER" -eq 0 ] || exit 1
