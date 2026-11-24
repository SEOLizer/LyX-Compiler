#!/usr/bin/env bash
# tests/paket_units_erhalt_2633_test.sh — ueberlebt ein lokal gebauter
# Unit-Baum das Hochruesten des Pakets? (#2633)
#
# BEFUND. Die Installation von 1.2.47B entfernte /usr/include/lyx/units/lyxos/;
# danach war jeder Bau mit --target=lyxos tot, und lyxc meldete die fehlenden
# Namen in den PAKETDATEIEN des Benutzers (vega/forms.lyx: undefined function
# 'NowMs') statt an der Ursache. Mechanik: ein frueheres Paket hatte den Baum
# mitgeliefert, das neue liefert ihn nicht -- dpkg raeumt beim Hochruesten weg,
# was aus seinem alten Dateiverzeichnis verschwunden ist.
#
# GEMESSEN WIRD DIE WIRKUNG, und zwar auf BEIDEN Seiten (#1823):
#   1. ohne die Maintainer-Skripte verschwindet der lokale Baum (Gegenprobe --
#      ein Test, der nur den Erfolgsfall zeigt, waere auch von einem Skript
#      erfuellt, das nichts tut),
#   2. mit ihnen ueberlebt er INHALTLICH (nicht nur das Verzeichnis),
#   3. einen Baum, den das Paket MITBRINGT, ueberschreibt die Paketfassung --
#      die Sicherung darf ihn nicht zurueckholen,
#   4. bricht das Hochruesten ab, stehen die Baeume wieder da.
#
# Das Hochruesten wird in einem Ersatzwurzelverzeichnis nachgestellt (DPKG_ROOT,
# den Schalter kennt dpkg selbst): der Test braucht damit kein root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRE="$ROOT/lyx-compiler/DEBIAN/preinst"
POST="$ROOT/lyx-compiler/DEBIAN/postinst"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

# Ausgangslage: ein vom Paket gelieferter Baum x86_64 und ein lokal gebauter
# lyxos daneben, wie ihn `make precompile-units LYU_ARCH=lyxos` erzeugt.
lege_aus() { # wurzel
  local b="$1/usr/include/lyx/units"
  mkdir -p "$b/x86_64/std/net" "$b/lyxos/std/net"
  echo ALT   > "$b/x86_64/std/net/socket.lyu"
  echo LOKAL > "$b/lyxos/std/net/socket.lyu"
  echo LOKAL > "$b/lyxos/std/time.lyu"
}

# Was dpkg beim Hochruesten tut: die Baeume des NEUEN Pakets auspacken und
# alles loeschen, was im alten Dateiverzeichnis stand und im neuen fehlt.
dpkg_nachstellen() { # wurzel, baeume-des-neuen-pakets...
  local w="$1"; shift
  local b="$w/usr/include/lyx/units"
  # Aufraeumen nach altem Dateiverzeichnis (x86_64 UND lyxos waren darin).
  local a
  for a in x86_64 lyxos; do
    [ -d "$b/$a" ] && rm -rf "$b/$a"
  done
  for a in "$@"; do
    mkdir -p "$b/$a/std/net"
    echo NEU > "$b/$a/std/net/socket.lyu"
  done
}

for f in "$PRE" "$POST"; do
  [ -x "$f" ] && pr ok "$(basename "$f") ist vorhanden und ausfuehrbar" \
              || pr fail "$(basename "$f") fehlt oder ist nicht ausfuehrbar"
done

# ── 1. Gegenprobe: ohne die Skripte ist der Baum weg ────────────────────────
echo "--- Gegenprobe: Hochruesten ohne Maintainer-Skripte ---"
W="$TMP/ohne"; lege_aus "$W"
dpkg_nachstellen "$W" x86_64
if [ -e "$W/usr/include/lyx/units/lyxos/std/time.lyu" ]; then
  pr fail "Gegenprobe greift nicht -- der nachgestellte Lauf loescht nichts"
else
  pr ok "Gegenprobe: ohne Skripte ist units/lyxos nach dem Hochruesten weg"
fi

# ── 2. Mit den Skripten ueberlebt er ────────────────────────────────────────
echo "--- Hochruesten mit preinst/postinst ---"
W="$TMP/mit"; lege_aus "$W"
DPKG_ROOT="$W" sh "$PRE" upgrade 1.2.46A >/dev/null
dpkg_nachstellen "$W" x86_64
DPKG_ROOT="$W" sh "$POST" configure 1.2.46A >"$TMP/post.log"
B="$W/usr/include/lyx/units"
[ "$(cat "$B/lyxos/std/time.lyu" 2>/dev/null)" = LOKAL ] \
  && pr ok "units/lyxos ueberlebt mit seinem INHALT" \
  || pr fail "units/lyxos fehlt oder ist leer nach dem Hochruesten"
[ "$(cat "$B/lyxos/std/net/socket.lyu" 2>/dev/null)" = LOKAL ] \
  && pr ok "units/lyxos behaelt seine lokale Fassung" \
  || pr fail "units/lyxos/std/net/socket.lyu nicht die lokale Fassung"
[ "$(cat "$B/x86_64/std/net/socket.lyu" 2>/dev/null)" = NEU ] \
  && pr ok "units/x86_64 traegt die NEUE Paketfassung" \
  || pr fail "units/x86_64 traegt nicht die Paketfassung"
if [ -z "$(find "$B" -maxdepth 1 -name '.vorher-*' -print -quit)" ]; then
  pr ok "keine .vorher-Reste"
else
  pr fail "Sicherungsverzeichnisse bleiben stehen: $(find "$B" -maxdepth 1 -name '.vorher-*')"
fi
grep -q "units/lyxos erhalten" "$TMP/post.log" \
  && pr ok "postinst sagt, dass es den Baum erhalten hat" \
  || pr fail "postinst erhaelt den Baum stumm"

# ── 3. Baum IM Paket: die Paketfassung gilt ─────────────────────────────────
echo "--- Baum, den das Paket mitbringt ---"
W="$TMP/beide"; lege_aus "$W"
DPKG_ROOT="$W" sh "$PRE" upgrade 1.2.46A >/dev/null
dpkg_nachstellen "$W" x86_64 lyxos
DPKG_ROOT="$W" sh "$POST" configure 1.2.46A >/dev/null
B="$W/usr/include/lyx/units"
[ "$(cat "$B/lyxos/std/net/socket.lyu" 2>/dev/null)" = NEU ] \
  && pr ok "mitgelieferter Baum behaelt die Paketfassung" \
  || pr fail "die Sicherung hat die Paketfassung ueberschrieben"
[ -z "$(find "$B" -maxdepth 1 -name '.vorher-*' -print -quit)" ] \
  && pr ok "keine .vorher-Reste (mitgelieferter Baum)" \
  || pr fail "Sicherung bleibt stehen, obwohl das Paket den Baum bringt"

# ── 4. Abbruch des Hochruestens ─────────────────────────────────────────────
echo "--- abort-upgrade stellt zurueck ---"
W="$TMP/abbruch"; lege_aus "$W"
DPKG_ROOT="$W" sh "$PRE" upgrade 1.2.46A >/dev/null
DPKG_ROOT="$W" sh "$PRE" abort-upgrade 1.2.46A >/dev/null
B="$W/usr/include/lyx/units"
[ "$(cat "$B/lyxos/std/time.lyu" 2>/dev/null)" = LOKAL ] && \
[ "$(cat "$B/x86_64/std/net/socket.lyu" 2>/dev/null)" = ALT ] \
  && pr ok "nach abort-upgrade stehen beide Baeume wieder da" \
  || pr fail "abort-upgrade laesst Baeume fehlen"

echo ""
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
