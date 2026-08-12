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
case "$ARCH" in
  amd64|i386|arm64|armhf|riscv64|ppc64el|s390x) ;;
  all) fehler "Architektur 'all' passt nicht zu einem Paket mit Binary in usr/local/bin." ;;
  *)   echo "WARNUNG: '$ARCH' ist kein üblicher dpkg-Architekturname (dpkg-architecture -L)." >&2 ;;
esac

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

# Debian-Policy 5.6.1: Paketnamen bestehen aus Kleinbuchstaben, Ziffern und
# '+-.'. 'Lyx-Compiler' verletzt das; dpkg-deb baut trotzdem, apt und die
# Repository-Werkzeuge nehmen es später übel. Nicht stillschweigend ändern —
# der Name ist die Installationsidentität.
PKGNAME="$(grep -m1 '^Package:' "$CONTROL" | sed 's/^Package:[[:space:]]*//')"
if [ "$PKGNAME" != "$(echo "$PKGNAME" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "WARNUNG: Paketname '$PKGNAME' enthält Großbuchstaben (Debian-Policy 5.6.1 verlangt Kleinschreibung)." >&2
  echo "         Umbenennen ist eine bewusste Entscheidung — installierte Pakete heißen dann anders." >&2
fi

echo "control: Version $VERSION, Architecture $ARCH"

# ── 5. Bauen ─────────────────────────────────────────────────────────────────
mkdir -p "$OUTDIR"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$DEB"

# ── 6. Nachprüfen, was tatsächlich im Paket liegt ────────────────────────────
if [ "$VERIFY" -eq 1 ]; then
  echo "Prüfe das fertige Paket..."
  # Ein Feld je Aufruf: bei mehreren stellt dpkg-deb den Feldnamen voran.
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
  echo "  Version/Architektur stimmen, lyxc identisch, $n_units .lyx-Quelltexte enthalten."
fi

echo ""
echo "Paket fertig: $DEB  ($(du -h "$DEB" | cut -f1))"
