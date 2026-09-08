#!/usr/bin/env bash
# tests/lyu_arch_test.sh — #2014: Architekturebene in der .lyu-Ablage.
#
# Sobald eine `.lyu` Maschinencode traegt (Weg C), gilt sie JE ARCHITEKTUR.
# Der Paketbaum bekommt dafuer eine Ebene: `units/<arch>/std/io.lyu`.
#
# WIE GESUCHT WIRD, und das ist der Kern: der Compiler DURCHSUCHT die
# Architekturordner NICHT. Er baut aus seinem `--target` GENAU EINEN Pfad und
# probiert den. Kein Durchprobieren, keine Rangfolge zwischen Architekturen —
# und damit kein Fall, in dem er die falsche erwischt.
#
# Der Griff sitzt an einer Stelle: _sema_readFile stellt JEDEM seiner fuenf
# Suchwege (relativ, Paketwurzeln, -I, --std-path, Installationspfad) die Basis
# voran. Ein architekturpraefigierter RELATIVER Pfad wird dadurch in jedem
# dieser Wege zu `<basis>/<arch>/<pfad>`.
#
# GEMESSEN WIRD DER GEWONNENE PFAD, nicht die Uebersetzbarkeit: `--trace-imports`
# nennt die Datei, die die Aufloesung erwischt hat. Ein Test auf "uebersetzt"
# waere bei jedem dieser Faelle gruen gewesen — auch bei der falschen Datei.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/lib"
printf 'unit lib;\npub fn Woher(): int64 { return 1; }\n' > "$TMP/q.lyx"
printf 'unit main;\nimport lib;\nfn main(): int64 { return 0; }\n' > "$TMP/m.lyx"

# Eine .lyu in die genannte Ablage bauen. Ohne Ziel = x86_64.
baue() {  # verzeichnis, [--target=...]
  mkdir -p "$TMP/lib/$1"
  ( cd "$TMP" && $LYXC ${2:-} --std-path="$ROOT" --compile-unit q.lyx -o "$TMP/lib/$1/lib.lyu" ) >/dev/null 2>&1
}
baue_flach() {
  ( cd "$TMP" && $LYXC --std-path="$ROOT" --compile-unit q.lyx -o "$TMP/lib/lib.lyu" ) >/dev/null 2>&1
}

# Welche Datei hat die Aufloesung erwischt?
gewinner() {  # [--target=...]
  ( cd "$TMP" && $LYXC ${1:-} --trace-imports --std-path="$ROOT" -I "$TMP/lib" m.lyx -o "$TMP/b" 2>&1 ) \
    | grep -A1 "\[import\] lib" | grep -- "->" | head -1 | sed "s|.*$TMP/||"
}

echo "--- #2014: der Compiler greift GENAU seine Architektur ---"

# Drei Ablagen nebeneinander. Das ist die Lage im Paketbaum ab Weg C.
baue x86_64
baue arm64   --target=arm64
baue riscv64 --target=riscv

g="$(gewinner)"
case "$g" in *"lib/x86_64/lib.lyu") ok "x86_64 greift lib/x86_64/" ;;
             *) nok "x86_64 nahm '$g'" ;; esac

g="$(gewinner --target=arm64)"
case "$g" in *"lib/arm64/lib.lyu") ok "arm64 greift lib/arm64/" ;;
             *) nok "arm64 nahm '$g'" ;; esac

g="$(gewinner --target=riscv)"
case "$g" in *"lib/riscv64/lib.lyu") ok "riscv greift lib/riscv64/" ;;
             *) nok "riscv nahm '$g'" ;; esac

echo
echo "--- Vorrang und Rueckfall ---"

# Beide Ablagen vorhanden: die architekturspezifische gewinnt.
baue_flach
g="$(gewinner)"
case "$g" in *"lib/x86_64/lib.lyu") ok "bei beiden Ablagen gewinnt die architekturspezifische" ;;
             *) nok "es gewann '$g'" ;; esac

# GEGENPROBE: ohne Architekturebene greift der bisherige Pfad weiterhin. Ohne
# diesen Rueckfall waeren bestehende Baeume und alle selbst gebauten .lyu
# unbrauchbar — eine rein BESCHREIBENDE .lyu ist ohnehin
# architekturunabhaengig.
rm -rf "$TMP/lib/x86_64" "$TMP/lib/arm64" "$TMP/lib/riscv64"
g="$(gewinner)"
case "$g" in *"lib/lib.lyu") ok "ohne Architekturebene greift der bisherige Pfad" ;;
             *) nok "Rueckfall nahm '$g'" ;; esac

echo
echo "--- die FALSCHE Architektur wird NICHT genommen ---"

# Der sicherheitsrelevante Fall: nur x86_64 liegt vor, gebaut wird fuer arm64.
# Ab Weg C entstuende sonst ein Erzeugnis, das nicht laeuft.
rm -f "$TMP/lib/lib.lyu"
baue x86_64
rm -f "$TMP/b"
aus="$( cd "$TMP" && $LYXC --target=arm64 --std-path="$ROOT" -I "$TMP/lib" m.lyx -o "$TMP/b" 2>&1 )"
if echo "$aus" | grep -q "Modul nicht gefunden"; then
  ok "arm64 nimmt die x86_64-Ablage nicht, sondern meldet"
else
  nok "arm64 meldete nicht — '$(echo "$aus" | grep -i error | head -1)'"
fi
if [ ! -f "$TMP/b" ]; then
  ok "und erzeugt nichts"
else
  nok "es entstand trotzdem ein Erzeugnis"
fi

# GEGENPROBE: mit passender Ablage geht derselbe Aufruf durch. Ohne sie waere
# der Test auch von einer Fassung erfuellt, die JEDEN arm64-Bau abweist.
baue arm64 --target=arm64
g="$(gewinner --target=arm64)"
case "$g" in *"lib/arm64/lib.lyu") ok "mit passender Ablage geht derselbe Aufruf durch" ;;
             *) nok "arm64 fand seine Ablage nicht: '$g'" ;; esac

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
