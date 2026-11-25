#!/usr/bin/env bash
# tests/zielbaum_fehlt_2634_test.sh — nennt lyxc den fehlenden Unit-Baum des
# Ziels, statt die Namen zu melden, die er deshalb nicht aufloesen kann?
# (#2634, abgespalten aus #2633)
#
# BEFUND. Fehlte `/usr/include/lyx/units/<arch>/`, meldete lyxc nicht den
# fehlenden Baum, sondern die unaufloesbaren Namen -- und zwar an ihren
# BENUTZUNGSSTELLEN, also in den Dateien FREMDER Pakete:
#
#   vega/forms.lyx: sema error (line 77): undefined function 'NowMs'
#   gx/alles.lyx:   sema error (line 35): undefined function 'allocZeroed'
#
# Der Fehler wird damit in fremdem Code gesucht, waehrend die Ursache eine
# fehlende Verzeichnisebene im Suchpfad ist. Ein Bausystem, das bei Fehlschlag
# auf ELF ausweicht, baut dann still ein Linux-ELF statt eines LBF -- das
# faellt erst beim Starten in Lyx OS auf.
#
# BEIDE SEITEN WERDEN GEMESSEN (#1823). Ein Test, der nur die neue Meldung
# prueft, waere auch von einer Fassung erfuellt, die IMMER meckert. Deshalb
# drei Gegenproben:
#
#   * Baum DA            -> kein Baumbefund, Uebersetzung laeuft
#   * Tippfehler im QUELLBAU -> kein Baumbefund (ein Quellbaum traegt
#     `std/*.lyx` und gar kein `units/<arch>/`; dort waere das Urteil falsch)
#   * Quellbau fuer dasselbe Ziel -> gruen
#
# Die PRAEMISSE gehoert vor den Fix (steht so im Issue): `--std-path=<leer>`
# reproduziert es NICHT, weil der Installationspfad daneben weiter gilt. Der
# Fall entsteht erst, wenn fuer das Ziel in KEINEM abgesuchten Pfad ein Baum
# liegt. Dieser Test stellt das her, indem er die Wurzel mit
# `--units-install-dir` (#2518) auf ein leeres Verzeichnis umlegt und KEIN
# --std-path setzt -- dann sind alle Pfade kontrolliert.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
ok() { PASS=$((PASS+1)); echo "PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }

cat > "$TMP/m.lyx" <<'LYX'
import std.time;
fn main(): int64 { return NowMs(); }
LYX

# Leere Wurzel: fuer JEDES Ziel fehlt der Baum.
mkdir -p "$TMP/leer"
# Wurzel mit genau einem Baum: x86_64 ist da, arm64 nicht.
mkdir -p "$TMP/einer/x86_64"

lauf() { # ausgabedatei, argumente...
  local out="$1"; shift
  ( cd "$TMP" && "$LYXC" "$@" m.lyx -o "$TMP/p.out" ) > "$out" 2>&1
  return 0
}

# --- 1: fehlender Baum wird GENANNT, und zwar als Ursache -------------------
echo "--- fehlender Zielbaum ---"
rm -f "$TMP/p.out"
lauf "$TMP/l1" --units-install-dir="$TMP/leer" --target=arm64
if grep -q "URSACHE" "$TMP/l1" && grep -q "arm64/" "$TMP/l1"; then
  ok "nennt den fehlenden Baum 'arm64/' als URSACHE"
else
  no "nennt den fehlenden Baum" "$(grep -m1 -i error "$TMP/l1")"
fi
# Der abgesuchte Pfad gehoert dazu -- ohne ihn ist die Meldung keine Auskunft.
if grep -q "$TMP/leer/arm64" "$TMP/l1"; then
  ok "nennt den abgesuchten Pfad samt Befund"
else
  no "nennt den abgesuchten Pfad" "$(tail -3 "$TMP/l1" | tr '\n' ' ')"
fi
# Und KEINE Folgefehler an Benutzungsstellen -- das war der ganze Befund.
if grep -q "undefined function" "$TMP/l1"; then
  no "keine Folgefehler" "$(grep -m1 'undefined function' "$TMP/l1")"
else
  ok "meldet KEINE Folgefehler an den Benutzungsstellen"
fi
if [ -s "$TMP/p.out" ]; then
  no "kein Erzeugnis bei fehlendem Baum" "es ist eines entstanden"
else
  ok "kein Erzeugnis bei fehlendem Baum"
fi

# --- 2: Gegenprobe, Baum DA ------------------------------------------------
# Derselbe Aufruf mit vorhandener Zielebene darf den Befund NICHT tragen.
# Gebaut wird hier nichts Lauffaehiges (der Baum ist leer) -- geprueft wird
# allein, dass das Baumurteil ausbleibt.
echo "--- Gegenproben ---"
mkdir -p "$TMP/einer/arm64"
lauf "$TMP/l2" --units-install-dir="$TMP/einer" --target=arm64
if grep -q "URSACHE" "$TMP/l2"; then
  no "Baum da -> kein Baumurteil" "$(grep -m1 'URSACHE' "$TMP/l2")"
else
  ok "Baum da -> kein Baumurteil"
fi

# --- 3: Gegenprobe, Tippfehler im Quellbau ---------------------------------
printf 'import std.gibtesnicht;\nfn main(): int64 { return 0; }\n' > "$TMP/t.lyx"
( cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t.out" ) > "$TMP/l3" 2>&1
if ! grep -q "Modul nicht gefunden" "$TMP/l3"; then
  no "Tippfehler wird weiter gemeldet" "$(tail -2 "$TMP/l3" | tr '\n' ' ')"
elif grep -q "URSACHE" "$TMP/l3"; then
  no "Tippfehler im Quellbau -> kein Baumurteil" "Baumurteil als Fehlalarm"
else
  ok "Tippfehler im Quellbau: gemeldet, aber ohne Baumurteil"
fi

# --- 4: Gegenprobe, Quellbau fuer dasselbe Ziel ist gruen ------------------
rm -f "$TMP/p2.out"
( cd "$TMP" && "$LYXC" --std-path="$ROOT" --target=arm64 m.lyx -o "$TMP/p2.out" ) > "$TMP/l4" 2>&1
if [ -s "$TMP/p2.out" ] && ! grep -q "URSACHE" "$TMP/l4"; then
  ok "Quellbau fuer arm64: gruen, kein Baumurteil"
else
  no "Quellbau fuer arm64" "$(grep -m1 -iE 'error|URSACHE' "$TMP/l4")"
fi

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
