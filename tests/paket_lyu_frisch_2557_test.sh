#!/usr/bin/env bash
# tests/paket_lyu_frisch_2557_test.sh — sind die eingecheckten Vorkompilate
# AKTUELL, nicht nur vorhanden? (#2557)
#
# WARUM DIESER TEST EXISTIERT. tests/paket_lyu_vollstaendig_test.sh prueft, DASS
# zu jeder Quelle ein .lyu im Paketbaum liegt (#2444). Das ist eine Invariante,
# und sie war erfuellt, waehrend 90 von 503 Dateien VERALTET waren: die Dateien
# lagen da, nur mit altem Inhalt. Gefunden wurde das beim Umsetzen von #2536 --
# nicht von einem Waechter, sondern weil ein Bau sie neu erzeugte und git den
# Unterschied zeigte.
#
# Entstanden sind sie in #2550: dort wurde std/net/syscalls.lyx geaendert, ohne
# den Baum neu zu erzeugen; betroffen war die Importhuelle darum herum
# (std/net/**, std/cloud/**, std/db/**, std/crypto/**, uuid, thread, process).
#
# Das ist genau die Klasse, vor der CLAUDE.md warnt: "Ein Test, der nur eine
# INVARIANTE prueft, ist blind fuer das falsche Ergebnis darin. Den WERT
# messen, die WIRKUNG, nicht das Vorhandensein."
#
# WAS EINE VERALTETE .lyu KOSTET. Sie traegt den OBJEKTCODE des alten Stands.
# Ein Programm, das nur gegen den Paketbaum uebersetzt, bekommt damit die alte
# Fassung einer Funktion, waehrend die Quelle im Repo laengst eine andere
# beschreibt -- und der Unterschied zeigt sich erst zur Laufzeit.
#
# WARUM EINE STICHPROBE. Ein Vollvergleich uebersetzt 503 Units und dauert so
# lange wie `make precompile-units`; das gehoert nicht in jeden Testlauf. Die
# Stichprobe nimmt Units, die VIEL IMPORTIEREN -- genau die, die eine
# Quellaenderung anderswo nachzieht. Der typische Fall ist damit abgedeckt, der
# vollstaendige Nachweis bleibt `make units-baeume` plus git-Status.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
_pp="$(dirname "$0")/lib/paket_pfad.sh"; [ -f "$_pp" ] || _pp="$(dirname "$0")/../lib/paket_pfad.sh"; . "$_pp"
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: sha256sum fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

# Importschwere Units: eine Quellaenderung in std/net oder std/crypto zieht
# genau diese nach. Der Satz ist FEST, damit der Test immer dasselbe messen
# kann -- eine zufaellige Auswahl waere mal gruen und mal rot.
STICHPROBE="
std/net/http.lyx
std/net/socket.lyx
std/net/syscalls.lyx
std/net/tls13.lyx
std/cloud/s3.lyx
std/crypto/x509.lyx
std/db/postgres.lyx
std/uuid.lyx
std/thread.lyx
std/process.lyx
"

echo "--- Vorkompilate der Stichprobe gegen einen Neubau ---"
echo "    (Schalter aus dem Makefile: ${PKG_OBJCODE:-<keine>})"
geprueft=0; alt=0; fehlt=0
for q in $STICHPROBE; do
  rel="${q#std/}"
  lyu="$PKG_UNITS/std/${rel%.lyx}.lyu"
  if [ ! -s "$lyu" ]; then
    # Fehlen ist Sache von paket_lyu_vollstaendig_test -- hier nur vermerken,
    # damit eine verschobene Datei nicht als "frisch" durchgeht.
    fehlt=$((fehlt+1)); echo "    (fehlt, nicht Sache dieses Tests: $q)"
    continue
  fi
  [ -f "$ROOT/$q" ] || { echo "    (Quelle fehlt: $q)"; continue; }
  neu="$TMP/$(echo "$rel" | tr / _).lyu"
  if ! ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" $PKG_OBJCODE \
           --compile-unit "$q" -o "$neu" ) >"$TMP/bau.log" 2>&1; then
    echo "    (uebersetzt nicht, uebersprungen: $q)"
    continue
  fi
  [ -s "$neu" ] || { echo "    (kein Erzeugnis: $q)"; continue; }
  geprueft=$((geprueft+1))
  a="$(sha256sum "$lyu" | cut -c1-16)"
  b="$(sha256sum "$neu" | cut -c1-16)"
  if [ "$a" != "$b" ]; then
    alt=$((alt+1))
    echo "    VERALTET $q  eingecheckt $a, neu gebaut $b"
  fi
done

if [ "$geprueft" -lt 5 ]; then
  pr no "nur $geprueft von 10 Units pruefbar -- die Stichprobe misst zu wenig"
else
  pr ok "$geprueft Units der Stichprobe vergleichbar gebaut"
fi

if [ "$alt" -eq 0 ]; then
  pr ok "keine veraltete .lyu in der Stichprobe"
else
  # #2622: Bis dahin stand hier nur "'make units-baeume' fahren und das
  # Ergebnis einchecken". Das war NICHT ausreichend, solange die Musterregel
  # die Importe nicht kannte -- genau das war getan worden, und der Baum blieb
  # gemischt. Seit build/unit_deps.mk die Huelle nachtraegt, genuegt der Lauf;
  # fuehrt er nicht zum Ziel, fehlt die Abhaengigkeitsdatei.
  pr no "$alt von $geprueft Vorkompilaten sind veraltet -- 'make units-baeume' fahren und das Ergebnis einchecken.
       Bleibt der Baum danach gemischt, fehlt build/unit_deps.mk (#2622): 'bash tools/unit_deps.sh' muss durchlaufen."
fi

echo "--- Der Vergleich muss einen Unterschied auch FINDEN ---"
# Ein Test, der nur gruen meldet, belegt nicht, dass er messen KANN. Der Fall
# wird deshalb ERZEUGT, und zwar selbsttragend: dieselbe Unit ein zweites Mal
# uebersetzen, aber OHNE die Paketschalter. Eine .lyu ohne Objektabbild muss
# sich von einer mit unterscheiden -- tut sie es nicht, vergleicht der Test
# etwas, das gegen Inhaltsaenderungen blind ist.
#
# Der Baum bleibt dabei unberuehrt; beide Dateien entstehen im Scratchpad.
if [ -f "$ROOT/std/uuid.lyx" ]; then
  mit="$TMP/mit.lyu"; ohne="$TMP/ohne.lyu"
  ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" $PKG_OBJCODE \
      --compile-unit std/uuid.lyx -o "$mit" ) >/dev/null 2>&1
  ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" \
      --compile-unit std/uuid.lyx -o "$ohne" ) >/dev/null 2>&1
  if [ -s "$mit" ] && [ -s "$ohne" ]; then
    h1="$(sha256sum "$mit" | cut -c1-16)"
    h2="$(sha256sum "$ohne" | cut -c1-16)"
    if [ "$h1" != "$h2" ]; then
      pr ok "der Hashvergleich findet einen Unterschied ($h1 gegen $h2)"
    else
      pr no "zwei verschieden gebaute .lyu haben denselben Hash -- der Vergleich ist blind"
    fi
    # Und die Richtung stimmt: die MIT Schaltern gebaute ist die groessere.
    s1=$(stat -c%s "$mit"); s2=$(stat -c%s "$ohne")
    if [ "$s1" -gt "$s2" ]; then
      pr ok "mit Objektabbild groesser als ohne ($s1 > $s2 Byte)"
    else
      pr no "mit Objektabbild nicht groesser ($s1 gegen $s2) -- PKG_OBJCODE greift nicht"
    fi
  else
    pr no "Gegenprobe: eine der beiden Fassungen entstand nicht"
    pr no "Richtung nicht pruefbar"
  fi
else
  pr no "std/uuid.lyx fehlt -- Gegenprobe nicht moeglich"
  pr no "Richtung nicht pruefbar"
fi

echo
echo "paket_lyu_frisch_2557_test: PASS=$PASS FAIL=$FAIL"
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
