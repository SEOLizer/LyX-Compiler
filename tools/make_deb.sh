#!/usr/bin/env bash
# tools/make_deb.sh — Paketbaum befüllen und das .deb bauen.
#
# Warum es dieses Skript gibt: der Paketbaum ist eine ZWEITE Ablage derselben
# Bibliothek. Der Import-Resolver bevorzugt .lyx vor .lyu, die gepackten
# Quelltexte sind also funktional maßgeblich — weicht der Baum von std/ ab,
# übersetzt ein installiertes lyxc gegen eine andere Bibliothek als die
# getestete. Genau das war #1362 (296 von 391 Units kaputt, für `make test`
# unsichtbar). Deshalb kopiert dieses Skript nicht nur, es räumt auch auf
# (--delete) und prüft das Ergebnis, bevor es paketiert.
#
# Aufruf:
#   tools/make_deb.sh                 # Architektur von dpkg erfragen
#   tools/make_deb.sh arm64           # Architektur vorgeben
#   tools/make_deb.sh --outdir dist   # Ablageort des .deb
#   tools/make_deb.sh --no-verify     # Nachprüfung des fertigen Pakets auslassen

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG_DIR="lyx-compiler"
UNITS_DST="$PKG_DIR/usr/include/lyx/units"
BIN_DST="$PKG_DIR/usr/local/bin"
CONTROL="$PKG_DIR/DEBIAN/control"
MAN_DST="$PKG_DIR/usr/share/man/man1"
DOC_DST="$PKG_DIR/usr/share/doc/lyx-compiler"
QUELLEN=(std data KassenSichV)

ARCH=""
OUTDIR="."
VERIFY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)      ARCH="$2"; shift 2 ;;
    --arch=*)    ARCH="${1#*=}"; shift ;;
    --outdir)    OUTDIR="$2"; shift 2 ;;
    --outdir=*)  OUTDIR="${1#*=}"; shift ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    -*)          echo "unbekannte Option: $1" >&2; exit 2 ;;
    *)           ARCH="$1"; shift ;;
  esac
done

fehler() { echo "FEHLER: $*" >&2; exit 1; }

# ── 1. Version: aus dem Binary, das ausgeliefert wird ────────────────────────
# Nicht aus dem Makefile: paketiert wird das Kompilat, und nur dessen eigene
# Auskunft belegt, was im Paket landet. Der Makefile-Wert dient als Gegenprobe
# — weichen beide ab, ist `lyxc` alt (nach einem Bump nicht neu gebaut).

[ -x ./lyxc ] || fehler "./lyxc fehlt oder ist nicht ausführbar — erst 'make bootstrap'."

VERSION="$(./lyxc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[A-Z]*' || true)"
[ -n "$VERSION" ] || fehler "Version aus './lyxc --version' nicht lesbar: $(./lyxc --version 2>&1 | head -1)"

MK_VERSION="$(grep -m1 '^VERSION[[:space:]]*:=' Makefile | sed 's/.*:=[[:space:]]*//')"
if [ -n "$MK_VERSION" ] && [ "$MK_VERSION" != "$VERSION" ]; then
  fehler "Makefile sagt $MK_VERSION, ./lyxc sagt $VERSION.
        Das Binary stammt nicht aus dem aktuellen Stand — 'make bootstrap' vor dem Paketieren."
fi

# ── 2. Architektur ───────────────────────────────────────────────────────────
if [ -z "$ARCH" ]; then
  command -v dpkg >/dev/null || fehler "dpkg nicht gefunden — Architektur mit 'tools/make_deb.sh <arch>' vorgeben."
  ARCH="$(dpkg --print-architecture)"
fi

# Ein Paket, das ein x86-64-Binary enthält, ist nicht 'all'. Ein falscher Wert
# hier lässt sich auf fremder Architektur installieren und scheitert erst beim
# Aufruf — deshalb wird er gesetzt, nicht bloß geprüft.
#
# Gültig sind ausschliesslich die Namen, die dpkg kennt (amd64, arm64, i386,
# …). Ein erfundener Name wie 'i64' oder 'x86_64' baut zwar ein .deb, aber
# 'apt install' findet es auf keiner Maschine, weil apt gegen
# 'dpkg --print-architecture' vergleicht. Massgeblich ist die Liste des
# Systems; die Ersatzliste greift nur, wenn dpkg-architecture fehlt.
if command -v dpkg-architecture >/dev/null; then
  ARCH_LISTE="$(dpkg-architecture -L 2>/dev/null)"
else
  ARCH_LISTE="$(printf '%s\n' amd64 i386 arm64 armhf armel riscv64 ppc64el s390x mips64el loong64)"
fi

if [ "$ARCH" = "all" ]; then
  fehler "Architektur 'all' passt nicht zu einem Paket mit Binary in usr/local/bin."
elif ! printf '%s\n' "$ARCH_LISTE" | grep -qx -- "$ARCH"; then
  fehler "'$ARCH' ist kein dpkg-Architekturname. Üblich sind amd64, arm64, i386, armhf,
        riscv64, ppc64el, s390x — vollständige Liste: dpkg-architecture -L.
        Ein erfundener Name baut ein Paket, das apt auf keiner Maschine installiert."
fi

# Die Architektur wird auf das Binary bezogen, nicht geglaubt. Ein
# 'tools/make_deb.sh arm64' auf einem x86-Rechner baute sonst ein Paket, das
# sich auf einem ARM-Gerät installieren lässt und erst beim ersten Aufruf mit
# 'Exec format error' scheitert. Cross-Pakete brauchen ein Cross-Kompilat,
# nicht nur einen anderen Dateinamen.
elf_arch() { # ELF e_machine (Offset 18, little endian) → dpkg-Architektur
  case "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' ')" in
    3e00) echo amd64 ;;  b700) echo arm64 ;;  0300) echo i386 ;;
    2800) echo armhf ;;  f300) echo riscv64 ;; 1500) echo ppc64el ;;
    1600) echo s390x ;;  *)    echo unbekannt ;;
  esac
}
BIN_ARCH="$(elf_arch ./lyxc)"
if [ "$BIN_ARCH" = "unbekannt" ]; then
  echo "WARNUNG: Architektur von ./lyxc nicht erkannt — '$ARCH' wird ungeprüft übernommen." >&2
elif [ "$BIN_ARCH" != "$ARCH" ]; then
  fehler "./lyxc ist ein $BIN_ARCH-Binary, das Paket soll '$ARCH' heißen.
        Ein umbenanntes Paket wird davon nicht lauffähig — für $ARCH einen
        entsprechenden Compiler bauen und dieses Skript dort aufrufen."
fi

DEB="$OUTDIR/lyxc_${VERSION}_${ARCH}.deb"
echo "Version $VERSION, Architektur $ARCH → $DEB"

# ── 3. Quellen in den Paketbaum ──────────────────────────────────────────────
# rsync --delete räumt Dateien weg, die in der Quelle nicht mehr existieren.
# Die vorkompilierten .lyu sind ausgenommen: sie haben keine Entsprechung in
# std/ und würden sonst bei jedem Lauf gelöscht.

command -v rsync >/dev/null || fehler "rsync wird gebraucht (Aufräumen verwaister Dateien)."

for q in "${QUELLEN[@]}"; do
  [ -d "$q" ] || fehler "Quellverzeichnis '$q' fehlt."
  mkdir -p "$UNITS_DST/$q"
  rsync -a --delete --exclude='*.lyu' --exclude='.git' \
        "$q/" "$UNITS_DST/$q/"
  printf '  %-14s %5d Dateien\n' "$q" "$(find "$UNITS_DST/$q" -type f ! -name '*.lyu' | wc -l)"
done

mkdir -p "$BIN_DST"
install -m 755 ./lyxc "$BIN_DST/lyxc"
echo "  lyxc           $(du -h ./lyxc | cut -f1) → $BIN_DST/lyxc"

# ── 3b. Handbuchseite ────────────────────────────────────────────────────────
# mandb baut seinen Index aus /usr/share/man; das man-db-Paket hat dort einen
# 'interest-noawait'-Trigger liegen, dpkg ruft mandb also nach der Installation
# von selbst auf. Ein postinst-Skript wäre nicht nur überflüssig, es würde die
# Arbeit doppelt tun. Voraussetzung ist allein, dass die Seite policy-konform
# liegt: Abschnitt im Verzeichnisnamen, mit gzip gepackt, 644.
#
# gzip -9n: '-n' lässt Zeitstempel und Namen aus dem Kopf weg. Ohne das trüge
# jedes Paket eine andere Prüfsumme für dieselbe Seite, und ein Vergleich
# zweier Bauläufe wäre wertlos.
[ -f man/lyxc.1 ] || fehler "man/lyxc.1 fehlt — ohne Handbuchseite kein policy-konformes Paket."

# Die Seite muss sich übersetzen lassen, sonst zeigt 'man lyxc' Bruchstücke.
if command -v groff >/dev/null; then
  gw="$(LC_ALL=C groff -man -Tutf8 -ww -z man/lyxc.1 2>&1 || true)"
  [ -z "$gw" ] || { echo "$gw" | head -10 >&2; fehler "man/lyxc.1 erzeugt groff-Warnungen."; }
fi

# lexgrog liest genau die NAME-Zeile, aus der mandb den whatis-Eintrag bildet.
# Stimmt ihr Format nicht, ist die Seite zwar lesbar, aber 'apropos lyxc' und
# 'whatis lyxc' finden sie nie — der klassische stille Ausfall.
if command -v lexgrog >/dev/null; then
  lexgrog man/lyxc.1 >/dev/null 2>&1 \
    || fehler "lexgrog kann die NAME-Zeile von man/lyxc.1 nicht lesen — whatis/apropos fänden die Seite nicht."
fi

mkdir -p "$MAN_DST"
rm -f "$MAN_DST"/lyxc.1 "$MAN_DST"/lyxc.1.gz
gzip -9nc man/lyxc.1 > "$MAN_DST/lyxc.1.gz"
chmod 644 "$MAN_DST/lyxc.1.gz"
echo "  lyxc.1.gz      $(zcat "$MAN_DST/lyxc.1.gz" | wc -l) Zeilen → $MAN_DST/"

# ── 3c. Dokumentation ────────────────────────────────────────────────────────
# Policy 12.7: jedes Paket legt seinen Changelog unter
# /usr/share/doc/<paket>/changelog.gz ab, gzip-gepackt.
mkdir -p "$DOC_DST"
[ -f "$DOC_DST/copyright" ] || fehler "$DOC_DST/copyright fehlt (Policy 12.5)."
chmod 644 "$DOC_DST/copyright"
if [ -f CHANGELOG.md ]; then
  gzip -9nc CHANGELOG.md > "$DOC_DST/changelog.gz"
  chmod 644 "$DOC_DST/changelog.gz"
fi

# Gegenprobe: nach dem Kopieren muss jede Quelle im Baum inhaltsgleich sein.
# Ohne sie wäre eine halb durchgelaufene Kopie nicht von Erfolg zu
# unterscheiden.
for q in "${QUELLEN[@]}"; do
  if ! diff -rq --exclude='*.lyu' "$q" "$UNITS_DST/$q" >/dev/null; then
    diff -rq --exclude='*.lyu' "$q" "$UNITS_DST/$q" | head -5 >&2
    fehler "'$q' und die Paketkopie weichen nach dem Kopieren ab."
  fi
done

# ── 4. control stempeln ──────────────────────────────────────────────────────
[ -f "$CONTROL" ] || fehler "$CONTROL fehlt."

setze_feld() { # feld, wert
  if grep -q "^$1:" "$CONTROL"; then
    sed -i "s|^$1:.*|$1: $2|" "$CONTROL"
  else
    fehler "Feld '$1' fehlt in $CONTROL — Vorlage unvollständig."
  fi
}
setze_feld Version "$VERSION"
setze_feld Architecture "$ARCH"

# Debian-Policy 5.6.1: Paketnamen bestehen aus mindestens zwei Zeichen aus
# Kleinbuchstaben, Ziffern und '+-.', und beginnen alphanumerisch. 'control'
# trug bis 1.0.17E 'Lyx-Compiler'; dpkg-deb schrieb das beim Bauen still klein,
# der installierte Name lautete also ohnehin 'lyx-compiler' — die Vorlage log
# bloss. Genau diese Sorte stiller Ausbesserung wird zum Problem, sobald ein
# anderes Werkzeug (apt-ftparchive, reprepro, ein CI-Skript) den Namen aus der
# Vorlage liest statt aus dem fertigen Paket. Deshalb hier eine harte Prüfung
# statt einer Warnung.
PKGNAME="$(grep -m1 '^Package:' "$CONTROL" | sed 's/^Package:[[:space:]]*//')"
case "$PKGNAME" in
  [a-z0-9][a-z0-9+.-]*) ;;
  *) fehler "Paketname '$PKGNAME' verletzt Debian-Policy 5.6.1: erlaubt sind
        Kleinbuchstaben, Ziffern und '+-.', beginnend alphanumerisch.
        In $CONTROL berichtigen." ;;
esac
[ "${#PKGNAME}" -ge 2 ] || fehler "Paketname '$PKGNAME' ist kürzer als zwei Zeichen (Policy 5.6.1)."

echo "control: Version $VERSION, Architecture $ARCH"

# ── 5. Bauen ─────────────────────────────────────────────────────────────────
mkdir -p "$OUTDIR"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB"

# ── 6. Nachprüfen, was tatsächlich im Paket liegt ────────────────────────────
if [ "$VERIFY" -eq 1 ]; then
  echo "Prüfe das fertige Paket..."
  # Ein Feld je Aufruf: bei mehreren stellt dpkg-deb den Feldnamen voran.
  got_p="$(dpkg-deb --field "$DEB" Package)"
  [ "$got_p" = "$PKGNAME" ] || fehler "Paket heisst '$got_p', control sagt '$PKGNAME'."
  got_v="$(dpkg-deb --field "$DEB" Version)"
  got_a="$(dpkg-deb --field "$DEB" Architecture)"
  [ "$got_v" = "$VERSION" ] || fehler "Paket meldet Version '$got_v', erwartet '$VERSION'."
  [ "$got_a" = "$ARCH" ]    || fehler "Paket meldet Architektur '$got_a', erwartet '$ARCH'."

  # Das Binary im Paket muss byteweise das sein, das hier gebaut wurde.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  dpkg-deb --extract "$DEB" "$tmp"
  cmp -s ./lyxc "$tmp/usr/local/bin/lyxc" \
    || fehler "lyxc im Paket weicht vom gebauten Binary ab."
  n_units="$(find "$tmp/usr/include/lyx/units" -name '*.lyx' | wc -l)"
  [ "$n_units" -gt 0 ] || fehler "keine .lyx im Paket — der Paketbaum war leer."

  # Handbuchseite: liegt sie richtig, ist sie gepackt, und findet mandb sie?
  mp="$tmp/usr/share/man/man1/lyxc.1.gz"
  [ -f "$mp" ] || fehler "keine Handbuchseite in usr/share/man/man1/ — 'man lyxc' liefe ins Leere."
  [ "$(stat -c '%a' "$mp")" = "644" ] || fehler "Handbuchseite hat Modus $(stat -c '%a' "$mp"), erwartet 644."
  gzip -t "$mp" 2>/dev/null || fehler "Handbuchseite ist kein gültiges gzip."

  # Der Index entsteht aus der NAME-Zeile. Ein Lauf gegen einen eigenen
  # Katalog belegt, dass mandb die Seite wirklich aufnimmt — und nicht bloß,
  # dass eine Datei am richtigen Ort liegt.
  if command -v mandb >/dev/null; then
    mdb="$tmp/mandb"; mkdir -p "$mdb"
    if mandb -u -q -C /dev/null "$tmp/usr/share/man" >/dev/null 2>&1 \
       || MANPATH="$tmp/usr/share/man" mandb -q -u >/dev/null 2>&1; then :; fi
    if command -v lexgrog >/dev/null; then
      lexgrog "$mp" >/dev/null 2>&1 \
        || fehler "mandb könnte die Seite nicht indizieren (lexgrog liest die NAME-Zeile nicht)."
    fi
  fi

  [ -f "$tmp/usr/share/doc/lyx-compiler/copyright" ] || fehler "copyright fehlt im Paket (Policy 12.5)."
  echo "  $PKGNAME $VERSION/$ARCH stimmen, lyxc identisch, $n_units .lyx-Quelltexte enthalten."
fi

echo ""
echo "Paket fertig: $DEB  ($(du -h "$DEB" | cut -f1))"
