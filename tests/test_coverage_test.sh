#!/usr/bin/env bash
# tests/test_coverage_test.sh — jede Testdatei muss in einem Ziel auftauchen.
#
# Der Anlass (Issue #1004): in `tests/` lagen rund 200 Dateien, die von keinem
# Make-Ziel aufgerufen wurden. Darunter waren vier Suiten, die eine
# Compiler-Regression aus PR #988 gefunden hätten — sie lief zwei PRs lang
# unbemerkt, weil die Tests nicht liefen.
#
# Ein Test, der nicht läuft, ist schlimmer als kein Test: er erweckt den
# Eindruck einer Absicherung, die es nicht gibt. Dieselbe Falle gab es schon
# zweimal — `examples/thread_test.lyx` meldete „All tests passed!", ohne je
# einen Thread zu starten (#992), und zwei Suiten fehlten im Ziel, weshalb ein
# Stale-Binary-Drift durchging (PR #841).
#
# Der zweite Anlass (Issue #1112): diese Prüfung selbst sah nur `tests/*.sh`
# und `tests/*.lyx` — flach. Die 621 Dateien in den Unterverzeichnissen waren
# für sie unsichtbar, und sie meldete trotzdem „alle Testdateien sind
# zugeordnet". Eine Abdeckungsprüfung, die nicht überall hinsieht, meldet
# Vollständigkeit über den Ausschnitt, den sie kennt — und sieht dabei genauso
# grün aus wie eine vollständige. Gesucht wird deshalb rekursiv.
#
# Zugeordnet ist eine Datei, wenn eine der vier Aussagen gilt:
#   1. Das Makefile nennt sie beim Namen.
#   2. Sie steht in einer der Suite-Listen `tests/suite-*.txt`.
#   3. Sie steht in `tests/known-red.txt` — läuft also mit, ist bekannt rot und
#      trägt ein Issue.
#   4. Sie liegt unter einem Verzeichnis, das ein Runner vollständig abläuft,
#      und dieser Runner hängt an einem Make-Ziel. Beides wird hier geprüft:
#      ein Runner, der aus dem Makefile verschwindet, macht sein Verzeichnis
#      wieder unzugeordnet — sonst wäre genau die Lücke zurück, die #1112 war.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Dateien, die keine Tests sind. Pfad relativ zu tests/.
is_exempt() {
  case "$1" in
    ppas.sh)                 return 0 ;;  # Artefakt des FPC-Assemblers
    run_lyx_tests.sh)        return 0 ;;  # Runner fuer tests/lyx/
    run_lyx_suite.sh)        return 0 ;;  # Runner der Suiten
    run_snapshot_tests.sh)   return 0 ;;  # Runner fuer tests/snapshot/
    run_external_compile.sh) return 0 ;;  # Runner der externen Suite
    test_coverage_test.sh)   return 0 ;;  # dieses Skript
    data/ns/eins.lyx)        return 0 ;;  # #1262: Pruefdaten, kein Test. Zwei
    data/ns/zwei.lyx)        return 0 ;;  # Units mit gleichnamigen Funktionen,
                                          # die import_namensraum_test.sh
                                          # importiert — allein uebersetzt
                                          # haetten sie kein main und nichts
                                          # zu melden.
    lib/lyxc_guard.sh)       return 0 ;;  # #1294: Bibliothek, kein Test — wird
                                          # von den Scripts eingebunden und vom
                                          # Waechter lyxc_guard_coverage_test.sh
                                          # selbst geprueft
    *)                       return 1 ;;
  esac
}

# Verzeichnisse, die ein Runner vollstaendig ablaeuft: <verzeichnis>|<runner>
# Der Runner muss (a) das Verzeichnis selbst nennen und (b) im Makefile
# aufgerufen werden — beides wird unten geprueft.
DIR_RUNNERS="lyx|tests/run_lyx_tests.sh
snapshot|tests/run_snapshot_tests.sh"

covered_dirs=""
runner_problems=""
while IFS='|' read -r dir runner; do
  [ -z "$dir" ] && continue
  if [ ! -f "$ROOT/$runner" ]; then
    runner_problems="$runner_problems
    $runner fehlt (deckt tests/$dir/ ab)"
    continue
  fi
  if ! grep -q "tests/$dir" "$ROOT/$runner"; then
    runner_problems="$runner_problems
    $runner nennt tests/$dir nicht mehr — laeuft er das Verzeichnis noch ab?"
    continue
  fi
  if ! grep -q "$runner" "$ROOT/Makefile"; then
    runner_problems="$runner_problems
    $runner haengt an keinem Make-Ziel — tests/$dir/ laeuft damit nirgends"
    continue
  fi
  covered_dirs="$covered_dirs $dir"
done <<EOF
$DIR_RUNNERS
EOF

is_dir_covered() {
  for d in $covered_dirs; do
    case "$1" in "$d"/*) return 0 ;; esac
  done
  return 1
}

# known-red.txt einlesen. Jeder Eintrag braucht ein Issue: die Abschnitts-
# ueberschrift darueber muss eine Nummer der Form #1234 tragen. Ohne diese
# Regel wird die Liste zur Ablage fuer alles, was gerade stoert.
KNOWN_RED_FILE="$ROOT/tests/known-red.txt"
known_red_paths=""
known_red_no_issue=""
if [ -f "$KNOWN_RED_FILE" ]; then
  section_issue=""
  while IFS= read -r line; do
    case "$line" in
      \#*|"") case "$line" in *\#[0-9][0-9][0-9]*) section_issue="$line" ;; esac; continue ;;
    esac
    entry="${line%%#*}"
    entry="$(printf '%s' "$entry" | sed -e 's/[[:space:]]*$//' -e 's/[[:space:]]*!flaky$//')"
    [ -z "$entry" ] && continue
    known_red_paths="$known_red_paths
$entry"
    [ -z "$section_issue" ] && known_red_no_issue="$known_red_no_issue $entry"
  done < "$KNOWN_RED_FILE"
fi

is_known_red() {
  printf '%s\n' "$known_red_paths" | grep -qxF "$1"
}

missing=""
count=0

while IFS= read -r f; do
  rel="${f#"$ROOT"/tests/}"
  is_exempt "$rel" && continue
  count=$((count+1))

  is_dir_covered "$rel" && continue
  is_known_red "tests/$rel" && continue

  b="$(basename "$rel")"
  grep -q "$b" "$ROOT/Makefile" && continue
  # Suite-Listen: Pfad relativ zu tests/ ohne Endung, am Zeilenanfang,
  # evtl. mit Optionen oder Kommentar dahinter.
  stem="${rel%.*}"
  grep -qE "^$stem([[:space:]]|$)" "$ROOT"/tests/suite-*.txt 2>/dev/null && continue

  missing="$missing $rel"
done <<EOF
$(find "$ROOT/tests" \( -name '*.sh' -o -name '*.lyx' \) | sort)
EOF

rc=0

if [ -n "$runner_problems" ]; then
  echo "FAIL Verzeichnis-Runner nicht mehr verdrahtet:$runner_problems"
  echo
  rc=1
fi

if [ -n "$known_red_no_issue" ]; then
  echo "FAIL Eintraege in tests/known-red.txt ohne Issue-Nummer im Abschnitt:"
  for m in $known_red_no_issue; do echo "    $m"; done
  echo
  rc=1
fi

if [ -n "$missing" ]; then
  n=$(echo $missing | wc -w)
  echo "FAIL $n Testdatei(en) in keinem Ziel und in keiner Suite-Liste:"
  for m in $missing; do echo "    $m"; done
  echo
  echo "Entweder ins Makefile aufnehmen, in eine der Listen tests/suite-*.txt"
  echo "eintragen (Pfad relativ zu tests/, ohne Endung), bei bekanntem Defekt"
  echo "mit Issue in tests/known-red.txt fuehren — oder, wenn es kein Test ist,"
  echo "in is_exempt() dieses Skripts vermerken."
  rc=1
fi

[ "$rc" -ne 0 ] && exit 1

echo "PASS alle $count Testdateien sind einem Ziel, einer Suite oder einem Runner zugeordnet"
