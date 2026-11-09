#!/usr/bin/env bash
# tools/lpm_std_paket.sh — die stdlib-Quellen als LPM-Paket `std` bauen (#2448).
#
# Warum es dieses Skript gibt: seit #2447 liefert das Debian-Paket keinen
# Lyx-Quellcode mehr. Der x86-Codegen uebersetzt importierte Units aber aus
# ihrer QUELLE (#2449, gemessen 192 von 489 Importen), also braucht es einen
# Bezugsweg. Das ist dieses Paket.
#
# ES WIRD IN EIN EIGENES VERZEICHNIS EXPORTIERT, nicht im Repo gepackt.
# `lpm pack` nimmt ALLES aus dem Verzeichnis, in dem die lyx.toml liegt (bis
# Tiefe 4, lpm/core/pack.lyx: PK_DEPTH_MAX). Eine lyx.toml im aurum-Wurzel-
# verzeichnis wuerde also src/, tests/ und den Paketbaum mit einpacken.
#
# GEMESSENE GRENZEN von lpm, die den Zuschnitt bestimmen. Gemessen an 0.1.3;
# 0.1.4 ist ein reiner Fassungswechsel (der Diff sind sieben Zeilen mit
# Versionszeichenketten), die Zahlen gelten unveraendert:
#
#   MF_MAX_UNITS = 4096 (manifest.lyx:28). War in 0.1.2 noch 32, und MfAddUnit
#                       machte beim Ueberlauf stillschweigend `return` -- ein
#                       [build.units] mit 500 Eintraegen verlor 468 davon ohne
#                       Meldung. 0.1.3 fasst 4096, zaehlt Verluste in
#                       mUnitsLost und bricht mit PK_ERR_UNITS ab. Deshalb
#                       traegt dieses Paket den Abschnitt wieder.
#   PK_MAX_FILES = 4096 (pack.lyx:50), war 512 -- bei 503 Dateien blieben neun
#                       Luft. Die Pruefung unten bleibt, aber mit Abstand.
#   PK_DEPTH_MAX = 8    (pack.lyx:56), war 4; std/cloud/gcp/x.lyx liegt auf 4.
#   SvParse             (semver.lyx:24) liest X.Y.Z und ignoriert den Rest
#                       STILL: "1.2.34B" wird zu 1.2.34. Die Paketversion ist
#                       deshalb eine eigene, reine X.Y.Z -- die Compilerfassung
#                       steht in der description.
#
# WELCHE UNITS [build.units] ERREICHT -- gemessen, nicht angenommen:
#
#   lpm resolve <paket>.<unit> schneidet den Namen am LETZTEN '/'
#   (cmdUnitPath, lpm/cli/commands.lyx:1593): "std.net.http" wird zu Paket
#   "std/net" mit Schluessel "http", NICHT zu Paket "std" mit Schluessel
#   "net.http". Gemessen an einer Probe:
#
#     lpm resolve stdprobe.fs --entry   -> .../std/fs.lyx          (geht)
#     lpm resolve stdprobe.net.types    -> "stdprobe/net fuehrt
#                                          'types' nicht unter [build.units]"
#
#   Eingetragen werden deshalb die EINSTUFIGEN Units (141 Stueck: std.fs,
#   std.io, ...). Die 359 mehrstufigen (std.net.http, std.cloud.gcp.jwt, ...)
#   sind ueber lpm resolve nicht erreichbar -- dafuer braeuchte es eigene
#   Pakete std/net, std/cloud/gcp und so weiter.
#
#   Fuer den HEUTIGEN Bezugsweg ist das ohne Belang: `lyxc` ruft lpm nicht auf
#   (die Compiler-Integration ist nicht umgesetzt, siehe
#   lyx-lpm/docs/compiler-integration.md), und ueber LYX_STD_PATH auf das
#   Cache-Verzeichnis funktionieren ALLE 500 Units, weil dort Pfade zaehlen
#   und die Dateien ihre Verzeichnisstruktur behalten.
#
# Aufruf:
#   tools/lpm_std_paket.sh                 # bauen und packen
#   tools/lpm_std_paket.sh --version 0.2.0 # Fassung vorgeben
#   tools/lpm_std_paket.sh --outdir DIR    # Ablage des .lxpkg
#
# Veroeffentlicht wird NICHT von hier: `lpm publish` ist ein Schritt nach
# draussen und zuruecknehmen geht nur von Hand am Server.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

VERSION=""
OUTDIR="$ROOT/dist"
EXPORT=""
# Paketname. Entschieden am 2026-11-09: `lyx-std-dev`, nicht `std`.
#
# Was das kostet, gehoert hierher und nicht in eine Fussnote: `lpm resolve`
# bildet den IMPORTNAMEN auf den PAKETNAMEN ab. Unter `lyx-std-dev` findet
# `lpm resolve std.fs` das Paket also NICHT -- wohl aber
# `lpm resolve lyx-std-dev.fs`. Fuer den heutigen Bezugsweg (LYX_STD_PATH auf
# das Cache-Verzeichnis) ist das ohne Belang, denn dort zaehlen Pfade. Fuer die
# kuenftige Compiler-Integration (lyx-lpm/docs/compiler-integration.md) ist es
# eine Festlegung: ein Paket, das `import std.*` automatisch bedient, muesste
# `std` heissen.
NAME="lyx-std-dev"

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --outdir)    OUTDIR="$2"; shift 2 ;;
    --outdir=*)  OUTDIR="${1#*=}"; shift ;;
    --export)    EXPORT="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --name=*)    NAME="${1#*=}"; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *)           echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

fehler() { echo "FEHLER: $*" >&2; exit 1; }

command -v lpm >/dev/null || fehler "lpm nicht gefunden (PATH: ~/.local/bin)."

# ── Fassung ──────────────────────────────────────────────────────────────────
# Keine Ableitung aus der Compilerversion: deren Suffix (1.2.34B) faellt in
# SvParse still weg, zwei Bauten eines Tages waeren dieselbe Paketversion.
if [ -z "$VERSION" ]; then
  [ -f "$ROOT/dist/$NAME-version.txt" ] \
    && VERSION="$(cat "$ROOT/dist/$NAME-version.txt")" \
    || VERSION="0.1.0"
fi
# Nur Zeichen, die lpm zulaesst ([a-z0-9_/.-], keine Grossbuchstaben, keine
# ".."-Segmente). Ein abgewiesener Name faellt sonst erst beim publish auf --
# nach dem Packen.
case "$NAME" in
  *[!a-z0-9_/.-]*) fehler "Paketname '$NAME' hat unzulaessige Zeichen (erlaubt: a-z 0-9 _ / . -)." ;;
  *..*)            fehler "Paketname '$NAME' hat ein '..'-Segment." ;;
  ""|-*)           fehler "Paketname '$NAME' ist leer oder beginnt mit '-'." ;;
esac
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*)
      rest="${VERSION##*.}"
      case "$rest" in *[!0-9]*) fehler "Fassung '$VERSION' ist kein reines X.Y.Z.
        SvParse (lpm) liest X.Y.Z und verwirft den Rest STILL -- aus '1.2.34B'
        wird 1.2.34, und zwei Bauten waeren eine Fassung." ;; esac ;;
  *)  fehler "Fassung '$VERSION' ist kein X.Y.Z." ;;
esac

LYXC_V="$(./lyxc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[A-Z]*' || echo unbekannt)"

[ -n "$EXPORT" ] || EXPORT="$(mktemp -d)"
mkdir -p "$EXPORT" "$OUTDIR"

echo "Paket $NAME $VERSION (gebaut gegen lyxc $LYXC_V)"

# ── Quellen exportieren ──────────────────────────────────────────────────────
# Nur .lyx und die READMEs: die .lyu gehoeren ins deb, nicht hierher, und ein
# Paket mit beiden Formen brachte die Doppelablage zurueck, die #2447 beendet
# hat (der Resolver zieht .lyx vor .lyu).
for q in std data; do
  [ -d "$q" ] || fehler "Quellverzeichnis '$q' fehlt."
  mkdir -p "$EXPORT/$q"
  (cd "$q" && find . \( -name '*.lyx' -o -name 'README.md' \) -print0) \
    | (cd "$q" && xargs -0 -I{} cp --parents {} "$EXPORT/$q/")
done

n_lyx="$(find "$EXPORT" -name '*.lyx' | wc -l)"
n_soll="$(find std data -name '*.lyx' | wc -l)"
[ "$n_lyx" -eq "$n_soll" ] || fehler "$n_lyx von $n_soll Units exportiert."
n_lyu="$(find "$EXPORT" -name '*.lyu' | wc -l)"
[ "$n_lyu" -eq 0 ] || fehler "$n_lyu .lyu im Export -- hier gehoeren nur Quellen hin."

# ── Manifest ─────────────────────────────────────────────────────────────────
cat > "$EXPORT/lyx.toml" <<TOML
[package]
name        = "$NAME"
version     = "$VERSION"
author      = "Andreas Röne <andreas.roene@seolizer.de>"
license     = "MIT"
description = "Lyx-Standardbibliothek (Quelltexte), passend zu lyxc $LYXC_V"

# Einstieg: std.io ist die Unit, die praktisch jedes Programm zuerst braucht.
[build]
entry = "std/io.lyx"

# Die EINSTUFIGEN Units. Der Schluessel ist das Namenssegment hinter dem
# Paketnamen: "fs" bedient \`import std.fs\`.
#
# Die mehrstufigen (std.net.http, std.cloud.gcp.jwt, ...) fehlen hier mit
# Absicht. \`lpm resolve\` schneidet den Namen am LETZTEN '/' (cmdUnitPath,
# lpm/cli/commands.lyx), sucht also ein Paket "std/net" mit Schluessel "http"
# statt Paket "std" mit Schluessel "net.http" -- gemessen:
#
#     lpm resolve <paket>.fs --entry   -> .../std/fs.lyx
#     lpm resolve <paket>.net.types    -> "fuehrt 'types' nicht unter
#                                          [build.units]"
#
# Ein Eintrag "net.types" waere also nicht falsch, sondern wirkungslos, und
# ein wirkungsloser Eintrag ist schlimmer als keiner: er behauptet eine
# Zusicherung, die es nicht gibt.
#
# Ueber den heutigen Bezugsweg sind ALLE Units erreichbar, auch die
# mehrstufigen:
#
#     lpm install $NAME
#     export LYX_STD_PATH=~/.lpm/cache/$NAME/$VERSION
#
# Dort loest der Compiler ueber PFADE auf -- \`import std.cloud.gcp.jwt\`
# findet std/cloud/gcp/jwt.lyx, weil die Dateien ihre Verzeichnisstruktur
# behalten.
[build.units]
TOML

# Eintraege erzeugen, nicht pflegen: 141 Zeilen von Hand gehen beim ersten
# neuen Modul schief.
# NUR std/: das Paket heisst "std", und der Schluessel ist das Segment hinter
# DIESEM Namen. Die Units unter data/ heissen `import data.core` -- sie gehoeren
# zum Paketnamen "data", den dieses Paket nicht traegt, und bekommen deshalb
# keinen Eintrag. Beim ersten Anlauf standen sie mit drin, und "data/io.lyx"
# erhielt denselben Schluessel "io" wie "std/io.lyx": ein doppelter Schluessel,
# von dem einer still gewinnt. Ueber LYX_STD_PATH sind die data-Units
# unverandert erreichbar, dort zaehlt der Pfad.
while IFS= read -r f; do
  key="$(basename "$f" .lyx)"
  printf '%-14s = "%s"\n' "$key" "$f" >> "$EXPORT/lyx.toml"
done < <(find std -maxdepth 1 -name '*.lyx' | sort)

# Gegenprobe: kein Schluessel zweimal. Ein doppelter Eintrag ist in TOML nicht
# verboten, und lpm nimmt dann einen davon -- welchen, sagt niemand.
# Nur innerhalb des Abschnitts zaehlen: die Kopfzeilen (name, version, author,
# license, description, entry) haben dieselbe Form "wort = wert" und wurden beim
# ersten Anlauf mitgezaehlt -- 130 Units erschienen als 136 Eintraege.
units_zeilen() { awk '/^\[build\.units\]/{s=1;next} /^\[/{s=0} s&&/=/{print $1}' "$1"; }
doppelt="$(units_zeilen "$EXPORT/lyx.toml" | sort | uniq -d)"
[ -z "$doppelt" ] || fehler "doppelte Schluessel in [build.units]: $(echo $doppelt | tr '\n' ' ')"

n_units_eintrag="$(units_zeilen "$EXPORT/lyx.toml" | wc -l)"

# ── Grenzen pruefen, bevor lpm sie trifft ────────────────────────────────────
printf '  %4d einstufige Units unter [build.units] (von %d; die %d mehrstufigen\n' \
       "$n_units_eintrag" "$n_soll" "$((n_soll - n_units_eintrag))"
printf '       sind nur ueber LYX_STD_PATH erreichbar, nicht ueber lpm resolve)\n'

# Die Grenzen stehen in lpm/core/pack.lyx und sind mit 0.1.3 gestiegen
# (PK_MAX_FILES 512 -> 4096, PK_DEPTH_MAX 4 -> 8). Hier stehen sie als Zahl,
# weil ein Lauf gegen ein aelteres lpm sonst erst beim Packen scheitert -- mit
# PK_ERR_LIMIT und ohne Hinweis darauf, WAS zu gross ist.
PK_FILES_MAX=4096
PK_TIEFE_MAX=8
n_dateien="$(find "$EXPORT" -type f | wc -l)"
luft=$((PK_FILES_MAX - n_dateien))
printf '  %4d Units, %4d Dateien im Paket (PK_MAX_FILES %d, Luft %d)\n' \
       "$n_lyx" "$n_dateien" "$PK_FILES_MAX" "$luft"
if [ "$n_dateien" -gt "$PK_FILES_MAX" ]; then
  fehler "$n_dateien Dateien -- lpm packt hoechstens $PK_FILES_MAX (PK_MAX_FILES)."
elif [ "$luft" -lt 50 ]; then
  echo "  WARNUNG: nur noch $luft Dateien Luft bis PK_MAX_FILES ($PK_FILES_MAX)." >&2
fi
tief="$(cd "$EXPORT" && find . -type f | awk -F/ '{print NF-1}' | sort -rn | head -1)"
[ "${tief:-0}" -le "$PK_TIEFE_MAX" ] \
  || fehler "Verzeichnistiefe $tief -- lpm packt bis $PK_TIEFE_MAX (PK_DEPTH_MAX)."

# ── Packen, zweimal ──────────────────────────────────────────────────────────
# Reproduzierbarkeit ist kein Nebenziel: die Pruefsumme steht in lyx.lock der
# Verbraucher. Zweimal packen und vergleichen ist der einzige Nachweis.
# Logdateien und die erste Kopie liegen AUSSERHALB des Exports. `lpm pack`
# nimmt alles aus dem Verzeichnis -- eine Logdatei darin landete im zweiten
# Archiv und machte den Vergleich wertlos. Genau so ist diese Pruefung beim
# ersten Anlauf falsch rot geworden.
WERK="$(mktemp -d)"
trap 'rm -rf "$WERK"' EXIT

(cd "$EXPORT" && lpm pack) > "$WERK/pack1.log" 2>&1 \
  || { sed -n '1,20p' "$WERK/pack1.log" >&2; fehler "lpm pack fehlgeschlagen."; }
pkg="$(find "$EXPORT" -maxdepth 1 -name '*.lxpkg' | head -1)"
[ -n "$pkg" ] || fehler "kein .lxpkg entstanden."
sha1="$(sha256sum "$pkg" | cut -d' ' -f1)"
mv "$pkg" "$WERK/erst.lxpkg"
(cd "$EXPORT" && lpm pack) > "$WERK/pack2.log" 2>&1 || fehler "zweiter lpm pack fehlgeschlagen."
pkg="$(find "$EXPORT" -maxdepth 1 -name '*.lxpkg' | head -1)"
sha2="$(sha256sum "$pkg" | cut -d' ' -f1)"
if [ "$sha1" != "$sha2" ]; then
  echo "  erst: $sha1" >&2
  echo "  dann: $sha2" >&2
  fehler "lpm pack ist nicht reproduzierbar. Das Handbuch sagt, es sei es --
        pruefen, ob im Exportverzeichnis zwischen den Laeufen etwas entstanden
        ist (lpm packt ALLES daraus), sonst ist es ein lpm-Defekt."
fi

ziel="$OUTDIR/$NAME-$VERSION.lxpkg"
cp "$pkg" "$ziel"
# Das Archiv NICHT im Exportverzeichnis liegen lassen: `lpm pack` ueberspringt
# vorhandene .lxpkg zwar, aber es zaehlt bei jeder Pruefung der Dateizahl mit
# und verschiebt damit den Abstand zu PK_MAX_FILES um eins.
rm -f "$pkg"
echo "$VERSION" > "$OUTDIR/$NAME-version.txt"

grep -i "warning" "$WERK/pack2.log" | head -5
echo ""
echo "Paket fertig: $ziel  ($(du -h "$ziel" | cut -f1))"
echo "  SHA256 (zweimal gleich): $sha1"
echo ""
echo "Veroeffentlichen (eigener Schritt, nicht hier):"
echo "  cd $EXPORT && lpm publish"
echo "Beziehen:"
echo "  lpm install $NAME && export LYX_STD_PATH=~/.lpm/cache/$NAME/$VERSION"
