#!/usr/bin/env bash
# tools/next_version.sh — die naechste Compilerversion berechnen und setzen.
#
# Schema:  MAJOR.MINOR.TAG + Suffix
#
#   TAG     zaehlt die BUILD-TAGE hoch, nicht die Kalendertage: der erste Build
#           an einem neuen Tag erhoeht ihn um eins und setzt den Suffix auf A.
#   Suffix  zaehlt die Kompilate INNERHALB eines Tages:
#             A B C … Z   dann   BA BB … BZ   dann   CA … CZ   usw.
#           `AA` gibt es nicht — nach Z folgt BA.
#
#   1.0.12A  = 12. Build-Tag, erstes Kompilat
#   1.0.12B  = derselbe Tag, zweites Kompilat
#   1.0.13A  = naechster Tag mit einem Build, erstes Kompilat
#
# Warum ueberhaupt ein Skript: die Version steht an FUENF lebenden Stellen
# (Makefile, README-Badge, vier Strings in src/lyxc.lyx, Kopf von ebnf.md, die
# .TH-Kopfzeile von man/lyxc.1 samt gepackter Paketkopie und das Version-Feld
# in lyx-compiler/DEBIAN/control).
# Von Hand gepflegt laufen die auseinander; `tests/version_consistency_test.sh`
# faengt das ab, aber besser gar nicht erst entstehen lassen.
#
# HISTORISCHE Angaben bleiben unberuehrt. Saetze wie „bis 1.0.11D war das so"
# in sema.lyx, ebnf.md §20.1 oder unter work/ beschreiben einen Zeitpunkt;
# mitzuziehen wuerde sie falsch machen. Das Skript fasst deshalb nur die fuenf
# bekannten Stellen an, nicht jedes Vorkommen der Zeichenkette. In man/lyxc.1
# heisst das: nur die .TH-Kopfzeile, nicht der Kommentar darueber, der den
# Stand nennt, gegen den die OPTIONEN-Liste geprueft wurde (#1766).
#
# Aufruf:
#   tools/next_version.sh            # naechste Version berechnen und setzen
#   tools/next_version.sh --dry-run  # nur anzeigen
#   tools/next_version.sh 1.0.14A    # eine bestimmte Version setzen
#
# ACHTUNG Reihenfolge: erst die Version setzen, DANN den Fixpunkt bauen und ihn
# als Seed verankern. Umgekehrt ist `make singularity` sofort wieder rot — die
# Version steckt im Compiler-Binary, ein Bump erzeugt also einen neuen Fixpunkt.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$ROOT/Makefile"
README="$ROOT/README.md"
LYXC="$ROOT/src/lyxc.lyx"
EBNF="$ROOT/ebnf.md"
MAN="$ROOT/man/lyxc.1"                                    # #1766
CONTROL="$ROOT/lyx-compiler/DEBIAN/control"               # #1955
MANPKG="$ROOT/lyx-compiler/usr/share/man/man1/lyxc.1.gz"  # #1766

DRY=0
WANT=""
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    -*) echo "unbekannte Option: $a" >&2; exit 2 ;;
    *)  WANT="$a" ;;
  esac
done

cur=$(sed -n 's/^VERSION  *:= *\([0-9A-Za-z.]*\).*/\1/p' "$MAKEFILE" | head -1)
curdate=$(sed -n 's/^VERSION_DATE  *:= *\([0-9-]*\).*/\1/p' "$MAKEFILE" | head -1)
if [ -z "$cur" ]; then echo "FAIL VERSION nicht im Makefile gefunden" >&2; exit 1; fi

today=$(date +%Y-%m-%d)

# Suffix <-> laufende Nummer.  A..Z = 1..26, BA..BZ = 27..52, CA..CZ = 53..78
suffix_to_num() { # $1 = Suffix
  local s="$1" n=${#1}
  if [ "$n" -eq 1 ]; then
    printf '%s' $(( $(LC_ALL=C printf '%d' "'$s") - 64 ))
  elif [ "$n" -eq 2 ]; then
    local a=$(( $(LC_ALL=C printf '%d' "'${s:0:1}") - 64 ))
    local b=$(( $(LC_ALL=C printf '%d' "'${s:1:1}") - 64 ))
    printf '%s' $(( (a - 1) * 26 + b ))
  else
    echo "FAIL Suffix '$s' hat mehr als zwei Buchstaben — Schema deckt das nicht ab" >&2
    exit 1
  fi
}

num_to_suffix() { # $1 = laufende Nummer ab 1
  local i="$1"
  if [ "$i" -le 26 ]; then
    printf "\\$(printf '%03o' $(( i + 64 )))"
  else
    local a=$(( (i - 1) / 26 + 1 ))
    local b=$(( (i - 1) % 26 + 1 ))
    if [ "$a" -gt 26 ]; then
      echo "FAIL mehr als 676 Kompilate an einem Tag — Schema erschoepft" >&2
      exit 1
    fi
    printf "\\$(printf '%03o' $(( a + 64 )))\\$(printf '%03o' $(( b + 64 )))"
  fi
}

if [ -n "$WANT" ]; then
  next="$WANT"
else
  base=${cur%%[A-Z]*}                 # 1.0.12
  suf=${cur#"$base"}                  # A
  major=${base%%.*}; rest=${base#*.}
  minor=${rest%%.*}; day=${rest#*.}
  if [ "$curdate" != "$today" ]; then
    next="$major.$minor.$(( day + 1 ))A"
  else
    n=$(suffix_to_num "$suf") || exit 1
    next="$base$(num_to_suffix $(( n + 1 )))"
  fi
fi

echo "aktuell:  $cur   (gesetzt am ${curdate:-unbekannt})"
echo "naechste: $next  (heute $today)"
[ "$DRY" -eq 1 ] && exit 0
if [ "$cur" = "$next" ]; then echo "nichts zu tun"; exit 0; fi

# Die fuenf lebenden Stellen.
sed -i "s/^VERSION   := .*/VERSION   := $next/"                              "$MAKEFILE"
sed -i "s/^VERSION_DATE := .*/VERSION_DATE := $today/"                       "$MAKEFILE"
grep -q '^VERSION_DATE' "$MAKEFILE" || sed -i "/^VERSION   := /a VERSION_DATE := $today" "$MAKEFILE"
sed -i "s/version-v$cur-blue/version-v$next-blue/"                           "$README"
sed -i "s/\"$cur\"c/\"$next\"c/g; s/lyxc $cur (bootstrap)/lyxc $next (bootstrap)/; s/lyxc $cur — Copyright/lyxc $next — Copyright/" "$LYXC"
# #1955: Das Debian-Paket traegt die Version ein siebtes Mal. Die Pruefung in
# tests/version_consistency_test.sh kannte die Stelle schon, das SETZEN hier
# nicht — also meldete der Bump jedes Mal einen Fehlschlag, den jemand von Hand
# nachziehen musste. Pruefung und Setzung sind zwei Aufzaehlungen derselben
# Sache; eine neue Stelle gehoert in BEIDE.
if [ -f "$CONTROL" ]; then
  sed -i "s/^Version:[[:space:]]*.*/Version: $next/" "$CONTROL"
else
  echo "WARNUNG lyx-compiler/DEBIAN/control fehlt — Version nicht nachgezogen" >&2
fi
sed -i "1s/^# Lyx $cur /# Lyx $next /"                                       "$EBNF"
sed -i "3s/gegen lyxc $cur geprueft/gegen lyxc $next geprueft/"              "$EBNF"
sed -i "3s/^> Stand [0-9-]*,/> Stand $today,/"                               "$EBNF"

# #1766: Die Handbuchseite traegt die Version in ihrer .TH-Kopfzeile, und
# tests/manpage_test.sh haelt sie gegen `lyxc --version`. Bis hierher zog das
# Skript sie nicht mit — `make test` wurde damit nach JEDEM Bump rot, bis
# jemand die Zeile von Hand nachtrug. Ersetzt wird ausschliesslich die
# .TH-Zeile; die Kommentarzeile darueber nennt den Stand, gegen den die
# OPTIONEN-Liste geprueft wurde, und ist eine historische Angabe.
if [ -f "$MAN" ]; then
  sed -i "s/^\.TH LYXC 1 \"[0-9-]*\" \"lyxc [0-9A-Za-z.]*\"/.TH LYXC 1 \"$today\" \"lyxc $next\"/" "$MAN"
  # Die Paketkopie muss inhaltsgleich bleiben, sonst meldet manpage_test.sh sie
  # als veraltet. gzip -9n laesst Zeitstempel und Namen weg, damit zwei
  # Baulaeufe dieselbe Pruefsumme ergeben — dieselben Schalter wie in
  # tools/make_deb.sh.
  if [ -f "$MANPKG" ]; then
    gzip -9nc "$MAN" > "$MANPKG"
    chmod 644 "$MANPKG"
  fi
else
  echo "WARNUNG man/lyxc.1 fehlt — Kopfzeile nicht nachgezogen" >&2
fi

echo
bash "$ROOT/tests/version_consistency_test.sh"
echo
echo "Jetzt: make bootstrap, dann den Fixpunkt als src/lyxc_bootstrap verankern"
echo "und mit 'make singularity' bestaetigen (S3 == S4)."
