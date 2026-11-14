#!/bin/bash
# Der Paketbau selbst, als Testziel.
#
# WARUM DIESER TEST EXISTIERT: `make deb` hing an keinem Ziel. Zweimal in einer
# Sitzung brach deshalb eine Pfadannahme in tools/make_deb.sh, ohne dass eine
# Pruefung es sah -- aufgefallen ist es erst beim Bauen eines Pakets:
#   #2499  die Vorkompilate zogen nach units/<arch>/, das Skript las weiter
#          den flachen Pfad und haette JEDE Unit als fehlend gemeldet
#   #2499  die Stichprobe uebersetzte ohne --with-objcode neu und verglich
#          eine .lyu MIT Abbild gegen eine OHNE
#
# Geprueft wird nicht das Skript, sondern das ERZEUGNIS: ein Paket bauen,
# auspacken und damit uebersetzen. Das ist, was der Benutzer bekommt.
#
# Der Lauf dauert rund 15 Sekunden, weil die Vorkompilate im Baum liegen --
# `make precompile-units` ist Sache des Makefiles, nicht dieses Skripts.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
_pp="$(dirname "$0")/lib/paket_pfad.sh"; [ -f "$_pp" ] || _pp="$(dirname "$0")/../lib/paket_pfad.sh"; . "$_pp"   # #2499
PASS=0; FAIL=0
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

for w in dpkg-deb dpkg; do
  command -v "$w" >/dev/null 2>&1 || { echo "SKIP: $w fehlt -- der Paketbau ist hier nicht pruefbar"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
done
[ -x "$LYXC" ] || { echo "SKIP: kein ./lyxc"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/aus" "$T/leer"

# Zustand des Arbeitsbaums VOR dem Bau. Das Skript schreibt in den Paketbaum
# (Version in DEBIAN/control, Handbuchseite, Binary); stehen danach Aenderungen
# da, ist entweder der Baum veraltet oder das Skript hinterlaesst etwas.
VOR="$(git -C "$ROOT" status --porcelain 2>/dev/null | sort)"

if bash tools/make_deb.sh amd64 --outdir "$T" > "$T/bau.log" 2>&1; then
  pr ok "tools/make_deb.sh laeuft durch"
else
  pr no "Paketbau scheitert: $(grep -iE 'fehler|error' "$T/bau.log" | head -3)"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi

DEB="$(ls "$T"/*.deb 2>/dev/null | head -1)"
if [ -n "$DEB" ]; then
  pr ok "Paket entstanden ($(du -h "$DEB" | cut -f1))"
else
  pr no "kein .deb im Ausgabeverzeichnis"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi

NACH="$(git -C "$ROOT" status --porcelain 2>/dev/null | sort)"
if [ "$VOR" = "$NACH" ]; then
  pr ok "der Arbeitsbaum ist nach dem Bau unveraendert"
else
  pr no "der Bau hinterlaesst Aenderungen im Baum: $(diff <(printf '%s\n' "$VOR") <(printf '%s\n' "$NACH") | head -4 | tr '\n' ' ')"
fi

dpkg-deb -x "$DEB" "$T/aus" 2>/dev/null

# Die Architekturebene: genau eine, und sie heisst wie LYU_ARCH.
EBENEN="$(ls "$T/aus/usr/include/lyx/units" 2>/dev/null)"
if [ "$EBENEN" = "$PKG_ARCH" ]; then
  pr ok "im Paket liegt genau die Ebene units/$PKG_ARCH/"
else
  pr no "Ebenen unter units/: '$(printf '%s' "$EBENEN" | tr '\n' ' ')' (erwartet '$PKG_ARCH')"
fi

# Zu jeder Unit der Quelle ein Vorkompilat IM PAKET. Die Zahl im Baum prueft
# tests/paket_lyu_vollstaendig_test.sh -- hier zaehlt, was ausgeliefert wird.
SOLL=$(find std data -name '*.lyx' | wc -l)
IST=$(find "$T/aus/usr/include/lyx/units" -name '*.lyu' 2>/dev/null | wc -l)
if [ "$IST" -eq "$SOLL" ]; then
  pr ok "$IST Vorkompilate im Paket, so viele wie Units"
else
  pr no "$IST Vorkompilate im Paket, $SOLL Units in der Quelle"
fi

# Kein Quellcode im Paket (#2447).
QUELL="$(find "$T/aus" \( -name '*.lyx' -o -name '*.pas' -o -name '*.dpr' \) | head -3)"
if [ -z "$QUELL" ]; then
  pr ok "kein Quellcode im Paket"
else
  pr no "Quelldateien im Paket: $(printf '%s ' $QUELL | cut -c1-120)"
fi

# WIRKUNG: mit dem AUSGEPACKTEN Paket uebersetzen und rechnen -- nichts sonst
# in Reichweite. Aus einem leeren Verzeichnis, weil der Import-Resolver das
# Arbeitsverzeichnis vor --std-path bevorzugt: im Repo faende er std/*.lyx und
# der Test waere gruen, ohne das Paket geprueft zu haben.
PBIN="$T/aus/usr/local/bin/lyxc"
PUNITS="$T/aus/usr/include/lyx/units"
cat > "$T/p.lyx" <<'LYX'
import std.io;
import std.string;
fn main(): int64 {
  PrintStrLn(StrConcat("Paket", "-Bau"));
  return StrLen("abcde");
}
LYX
if [ -x "$PBIN" ]; then
  rm -f "$T/p"
  ( cd "$T/leer" && "$PBIN" --std-path="$PUNITS" -I"$PUNITS" "$T/p.lyx" -o "$T/p" ) > "$T/p.log" 2>&1
  if [ -x "$T/p" ]; then
    AUS="$("$T/p" 2>&1)"; RC=$?
    if [ "$AUS" = "Paket-Bau" ] && [ "$RC" -eq 5 ]; then
      pr ok "der Compiler AUS DEM PAKET uebersetzt und rechnet mit dem Paketbaum (Paket-Bau, rc=5)"
    else
      pr no "laeuft, aber falsch: '$AUS' rc=$RC"
    fi
  else
    pr no "uebersetzt nicht mit dem ausgepackten Paket: $(grep -i error "$T/p.log" | head -2)"
  fi
else
  pr no "kein lyxc im Paket unter usr/local/bin/"
fi

# Die Version im Paketnamen muss die des Makefiles sein. Das Skript nimmt sie
# aus dem BINARY -- weicht sie ab, ist das ausgelieferte Kompilat veraltet.
MV="$(grep -m1 -oE '^VERSION[[:space:]]*:=[[:space:]]*[0-9A-Za-z.]+' Makefile | awk '{print $NF}')"
if printf '%s' "$(basename "$DEB")" | grep -q "_${MV}_"; then
  pr ok "Paketname nennt die Makefile-Version ($MV)"
else
  pr no "Paketname '$(basename "$DEB")' passt nicht zur Makefile-Version $MV"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: der Paketbau laeuft und das Paket traegt sich selbst"
