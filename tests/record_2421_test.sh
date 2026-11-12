#!/usr/bin/env bash
# #2421 — Struct-Zuweisung an eine Modulvariable kopiert den INHALT.
#
# Bis 1.2.33B überschrieb `g := r` den ZEIGER im 8-Byte-Slot der Globalen.
# Die Globale zeigte danach in den Rahmen des Aufrufers; sobald der
# weiterbenutzt wurde, standen Stapeladressen in den Feldern. Der eigene
# Datenblock der Globalen (#1256/#1299) blieb ungenutzt.
#
# Derselbe Fehler war für Locals schon #1351. Die zweite Stelle wurde damals
# nicht nachgezogen — genau die Fehlerart, die in diesem Baum mehrfach belegt
# ist.
#
# Zwei Nachweise, und der zweite ist der wichtigere: direkt nach der
# Zuweisung stimmt der Wert auch im kaputten Zustand, deshalb prüft der Test
# erst NACH einer tiefen Rekursion — und zusätzlich, dass die Globale nicht
# mitwandert, wenn die Quelle sich ändert.
set -u
ulimit -c 0
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if "$LYXC" --std-path=. tests/record_2421/global.lyx -o "$TMP/g" >"$TMP/b.log" 2>&1; then
  ok "uebersetzt"
  out=$("$TMP/g" 2>&1); rc=$?
  n=$(echo "$out" | grep -c '^PASS ')
  if [ "$rc" = "0" ] && echo "$out" | grep -q '^ALL PASS$'; then
    ok "alle_${n}_pruefungen"
  else
    bad "pruefungen (rc=$rc, PASS=$n)"; echo "$out" | grep '^FAIL' | head -6
  fi
  # Die beiden Zeilen einzeln bestätigen: sie decken je eine Fehlerklasse ab
  # und dürfen nicht in einer Gesamtzahl verschwinden.
  for z in "2 parameter_direkt" "5 zuweisung_kopiert_statt_zu_verweisen" \
           "6 schreiben_in_die_globale_laesst_die_quelle"; do
    if echo "$out" | grep -q "^PASS $z\$"; then ok "kern_${z// /_}"; else bad "kern_${z// /_}"; fi
  done
else
  bad "uebersetzt"; tail -5 "$TMP/b.log"
fi

# Gegenrichtung: eine KLASSE bleibt eine Referenz und wird NICHT kopiert.
# Ohne diese Prüfung wäre der Fix auch von einer Fassung erfüllt, die jedes
# Aggregat kopiert — und damit die Referenzsemantik von Klassen bricht, auf
# die der Bestand sich stützt.
cat > "$TMP/k.lyx" <<'EOF'
unit main;
import std.io;
pub type K = class { a: int64; fn Get(): int64 { return self.a; } };
var g: K;
fn main(): int64 {
  var o: K := new K();
  o.a := 1;
  g := o;
  o.a := 777;
  PrintLn(g.a);
  return 0;
}
EOF
if "$LYXC" --std-path=. "$TMP/k.lyx" -o "$TMP/k" >"$TMP/k.log" 2>&1; then
  kout=$("$TMP/k" 2>&1)
  if [ "$kout" = "777" ]; then
    ok "klasse_bleibt_referenz (Gegenrichtung)"
  else
    bad "klasse_bleibt_referenz — '$kout' statt 777; eine Klasse darf nicht kopiert werden"
  fi
else
  bad "klasse_uebersetzt"; tail -3 "$TMP/k.log"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
