#!/usr/bin/env bash
# tests/weiche_schluesselwoerter_test.sh — #1745.
#
# `layout` und `widget` waren HARTE Schluesselwoerter, obwohl sie nur in der
# LFD-Untersprache etwas bedeuten. Damit waren zwei Bezeichner gesperrt, die in
# einer Oberflaechenbibliothek naheliegen — `vega/font.lyx` hatte einen
# Parameter `layout` und uebersetzte nicht.
#
# Der zweite Teil des Tickets: eine Parse-Meldung in einer importierten Unit
# lief als "unknown return type" in einer ganz anderen Datei weiter. Wer die
# Ausgabe von unten liest, sucht dann am falschen Ende.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

rechnet() {   # Name, Quelle, erwarteter Rueckgabewert
  printf '%s' "$2" > "$TMP/w.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w.out" >"$TMP/w.log" 2>&1; then
    no "$1" "$(grep -iE 'parse error|sema error' "$TMP/w.log" | head -1)"
    return
  fi
  "$TMP/w.out"; local rc=$?
  if [ "$rc" = "$3" ]; then ok "$1 (= $3)"; else no "$1" "Ergebnis $rc statt $3"; fi
}

# --- Die drei Stellen aus der Meldung, fuer beide Woerter ------------------
rechnet "layout als Parameter" 'fn f(align: int64, layout: int64): int64 { return align + layout; }
fn main(): int64 { return f(1, 2); }' 3

rechnet "layout als lokale Variable" 'fn main(): int64 { var layout: int64 := 5; return layout; }' 5

rechnet "layout als Feldname" 'type T = class { layout: int64; };
fn main(): int64 { var t: T := new T(); t.layout := 9; return t.layout; }' 9

rechnet "widget als Parameter" 'fn f(widget: int64): int64 { return widget * 2; }
fn main(): int64 { return f(21); }' 42

rechnet "widget als Feldname" 'type T = class { widget: int64; };
fn main(): int64 { var t: T := new T(); t.widget := 7; return t.widget; }' 7

# Beide zusammen, und daneben die Nachbarn, die schon frei waren.
rechnet "layout und widget nebeneinander" 'fn f(layout: int64, widget: int64, style: int64, view: int64): int64 {
  return layout + widget + style + view;
}
fn main(): int64 { return f(1, 2, 4, 8); }' 15

# --- Die LFD-Untersprache muss weiter gehen --------------------------------
# Ohne diese Gegenprobe waere "weich machen" gleichbedeutend mit "abschalten".
if "$LYXC" --std-path="$ROOT" "$ROOT/examples/graphics/qt_layout_simple.lyx" -o "$TMP/lfd.out" >"$TMP/lfd.log" 2>&1; then
  ok "LFD-Formular uebersetzt weiterhin"
else
  no "LFD-Formular uebersetzt weiterhin" "$(grep -m1 -iE 'parse error|sema error' "$TMP/lfd.log")"
fi

# --- Fehlerkaskade nach einem nicht lesbaren Import ------------------------
mkdir -p "$TMP/k/paket"
cat > "$TMP/k/paket/kaputt.lyx" <<'EOF'
unit paket.kaputt;
pub type TDing = class { wert: int64; };
pub fn MachDing(: int64): int64 { return 1; }
EOF
cat > "$TMP/k/app.lyx" <<'EOF'
import paket.kaputt;
fn main(): int64 { var d: TDing := new TDing(); return MachDing(1); }
EOF
AUS=$(cd "$TMP/k" && "$LYXC" -I . app.lyx -o "$TMP/k/a.out" 2>&1)
if echo "$AUS" | grep -q "parse error in imported module"; then
  ok "der Parse-Fehler im Import wird genannt"
else
  no "der Parse-Fehler im Import wird genannt"
fi
# Die Folgemeldungen ueber Symbole DIESER Unit duerfen nicht mehr kommen: nach
# einem nicht lesbaren Import ist die Symboltabelle unvollstaendig, jede
# Aussage ueber unbekannte Namen waere geraten.
if echo "$AUS" | grep -qE "unknown type in var decl|undefined function"; then
  no "keine Folgemeldungen ueber Symbole des kaputten Imports" "$(echo "$AUS" | grep -E 'unknown type|undefined function' | head -1)"
else
  ok "keine Folgemeldungen ueber Symbole des kaputten Imports"
fi
if echo "$AUS" | grep -q "Symboltabelle unvollstaendig"; then
  ok "der Abbruch wird begruendet"
else
  no "der Abbruch wird begruendet" "die Pruefung endet, sagt aber nicht warum"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
