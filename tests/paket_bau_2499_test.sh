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

# Die Architekturebenen. #2569: hier stand "genau eine, und sie heisst wie
# LYU_ARCH". Das war dieselbe Ein-Baum-Annahme wie in tools/make_deb.sh -- die
# Annahme lag an DREI Stellen, nicht einer. Seit #2536 kann das Paket mehrere
# Baeume tragen (`make deb LYU_BAEUME="x86_64 lyxos"`), und dann ist die
# zusaetzliche Ebene gewollt. Gefordert bleibt, dass die Ebene des BAUZIELS
# dabei ist -- ohne sie waere das Paket fuer diese Architektur unbrauchbar.
EBENEN="$(ls "$T/aus/usr/include/lyx/units" 2>/dev/null)"
if printf '%s\n' "$EBENEN" | grep -qx "$PKG_ARCH"; then
  pr ok "im Paket liegt die Ebene units/$PKG_ARCH/ ($(printf '%s' "$EBENEN" | tr '\n' ' '))"
else
  pr no "Ebene units/$PKG_ARCH/ fehlt; vorhanden: '$(printf '%s' "$EBENEN" | tr '\n' ' ')'"
fi

# Zu jeder Unit der Quelle ein Vorkompilat IM PAKET. Die Zahl im Baum prueft
# tests/paket_lyu_vollstaendig_test.sh -- hier zaehlt, was ausgeliefert wird.
#
# #2569: JE BAUM, und je Baum gegen die Quell-Units MINUS der erklaerten
# Luecken dieses Ziels. Die Summe ueber alle Baeume zu nehmen hiesse, dass
# zwei halb gefuellte Baeume die Pruefung erfuellen.
SOLL=$(find std data -name '*.lyx' | wc -l)
mehrbaum_ok=1
for ebene in $EBENEN; do
  a_ausn="tools/dist_units_ausnahmen_$ebene.txt"
  n_a=0
  [ -f "$a_ausn" ] && n_a="$(grep -cE '^[^#[:space:]].*#' "$a_ausn")"
  soll_e=$(( SOLL - n_a ))
  ist_e=$(find "$T/aus/usr/include/lyx/units/$ebene" -name '*.lyu' 2>/dev/null | wc -l)
  if [ "$ist_e" -eq "$soll_e" ]; then
    pr ok "Baum $ebene: $ist_e Vorkompilate, so viele wie Units minus $n_a erklaerte Luecken"
  else
    pr no "Baum $ebene: $ist_e Vorkompilate, erwartet $soll_e ($SOLL Units minus $n_a)"
    mehrbaum_ok=0
  fi
done
[ "$mehrbaum_ok" = "1" ] || true

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

# ── #2569: MEHRERE Vorkompilatbaeume ────────────────────────────────────────
#
# `make deb LYU_BAEUME="x86_64 lyxos"` konnte NIE durchlaufen: die Pruefung in
# tools/make_deb.sh zaehlte die .lyu ueber ALLE Baeume und verglich die Summe
# gegen die Zahl der Quell-Units (503 + 495 = 998 gegen 503). Die zweite
# Stelle war nicht nachgezogen -- units-baeume lernte mit #2536 mehrere
# Baeume, diese Pruefung nicht, obwohl das Makefile die Form selbst bewirbt.
#
# Der zweite Baum wird hier KOPIERT, nicht uebersetzt: geprueft wird die
# ZAEHLUNG je Baum, nicht der Codegen eines Ziels -- ein `--target`-Lauf ueber
# 503 Units dauerte Minuten und haette denselben Befund gebracht. Genommen
# wird `linux-arm64`, weil es dafuer eine ECHTE Ausnahmeliste gibt (genau ein
# Eintrag): so misst der Test die Rechnung "Quell-Units minus erklaerte
# Luecken" an einer Liste des Bestands statt an einer erfundenen.
#
# AUFRUF DIREKT, nicht ueber `make deb`: das Ziel haengt an `units-baeume` und
# baut eine entfernte .lyu vor der Pruefung NEU. Eine Sabotage ueber `make`
# wird weggebaut, und die Probe kommt gruen heraus, ohne etwas zu messen --
# genau so war der erste Versuch wertlos.
B2="lyx-compiler/usr/include/lyx/units/linux-arm64"
AUSN2="tools/dist_units_ausnahmen_linux-arm64.txt"
if [ ! -d lyx-compiler/usr/include/lyx/units/x86_64 ] || [ ! -f "$AUSN2" ]; then
  echo "SKIP #2569: x86_64-Baum oder $AUSN2 fehlt"
else
  rm -rf "$B2"
  cp -r lyx-compiler/usr/include/lyx/units/x86_64 "$B2"
  # Die erklaerten Luecken dieses Ziels entfernen -- so sieht der Baum aus,
  # wie ihn `units-baeume` fuer dieses Ziel hinterlaesst.
  n_ausn=0
  while IFS= read -r q; do
    rel="${q#*/}"; pfx="${q%%/*}"
    rm -f "$B2/$pfx/${rel%.lyx}.lyu"
    n_ausn=$((n_ausn+1))
  done < <(grep -E '^[^#[:space:]].*#' "$AUSN2" | awk '{print $1}')
  n_soll_all="$(find std data -name '*.lyx' | wc -l)"
  erwartet=$(( n_soll_all - n_ausn ))

  # (a) unveraendert: muss gruen sein und BEIDE Baeume nennen.
  if out="$(bash tools/make_deb.sh "$(dpkg --print-architecture)" 2>&1)"; then
    if printf '%s' "$out" | grep -q "Baum linux-arm64: $erwartet .lyu (Soll $erwartet)"; then
      pr ok "#2569 zwei Baeume: linux-arm64 mit $erwartet .lyu anerkannt ($n_soll_all Units minus $n_ausn)"
    else
      pr no "#2569 Paket gebaut, aber der zweite Baum wird nicht je Baum gezaehlt"
      printf '%s\n' "$out" | grep -E "Baum |FEHLER" | sed 's/^/    /'
    fi
  else
    pr no "#2569 Paketbau mit zwei Baeumen scheitert"
    printf '%s\n' "$out" | grep -E "FEHLER" | sed 's/^/    /'
  fi

  # (b) und (c) BEIDE Richtungen: eine Pruefung, die nur die richtige Zahl
  # bestaetigt, waere auch von einer viel zu weiten Zaehlung erfuellt.
  weg="$B2/std/base64.lyu"
  if [ -f "$weg" ]; then
    mv "$weg" "$weg.beiseite"
    if bash tools/make_deb.sh "$(dpkg --print-architecture)" >/dev/null 2>&1; then
      pr no "#2569 eine FEHLENDE .lyu im zweiten Baum fiel nicht auf"
    else
      pr ok "#2569 eine fehlende .lyu im zweiten Baum wird gemeldet"
    fi
    mv "$weg.beiseite" "$weg"
  fi
  cp "$B2/std/base64.lyu" "$B2/std/zz_pruefzusatz.lyu" 2>/dev/null
  if bash tools/make_deb.sh "$(dpkg --print-architecture)" >/dev/null 2>&1; then
    pr no "#2569 eine UEBERZAEHLIGE .lyu im zweiten Baum fiel nicht auf"
  else
    pr ok "#2569 eine ueberzaehlige .lyu im zweiten Baum wird gemeldet"
  fi
  rm -rf "$B2"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: der Paketbau laeuft und das Paket traegt sich selbst"
