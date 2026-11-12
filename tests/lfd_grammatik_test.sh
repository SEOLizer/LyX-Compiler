#!/usr/bin/env bash
# tests/lfd_grammatik_test.sh — #1397.
#
# `lfd-ebnf.md` (v0.1.0) und `std/lfd_parser.lyx` beschrieben zwei verschiedene
# Sprachen: die Grammatikdatei großgeschriebene Schlüsselwörter (`Form`,
# `Layout`, `Button`), einen Bezeichner je Element, eine `Format:`-Kopfzeile und
# Widget-Typen, die es nie gab. Wer sich an die Datei hielt, bekam
# `expected 'form'`.
#
# Entschieden wurde: **der Parser ist maßgeblich**, die Grammatik zieht nach.
#
# DIESER TEST HÄLT DIE GRAMMATIKDATEI AN DER SPRACHE FEST. Eine Doku-Änderung
# allein verrottet beim nächsten Parser-Umbau wieder — deshalb wird hier jede
# Aussage der Datei gemessen: das vollständige Beispiel aus Abschnitt 5 muss
# fehlerfrei gelesen werden, und jede Form, die Abschnitt 8 ausdrücklich
# ausschließt, muss abgewiesen werden.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Baut EIN Programm, das alle Fälle misst — jeder Aufruf des Compilers kostet
# hier mehrere Sekunden, und die Fälle sind unabhängig voneinander.
cat > "$TMP/p.lyx" <<'LYXEOF'
import std.io;
import std.lfd_parser;

// Gibt "ok" aus, wenn der Text gelesen wurde, sonst "rot".
fn liest(txt: pchar): void {
  var n: int64 := LFDParseString(txt);
  if (n > 0 && LFDGetErrorCount(0) == 0) { PrintStr("ok "); } else { PrintStr("rot "); }
}

// Gibt "abgewiesen" aus, wenn der Text NICHT gelesen wurde.
fn weistAb(txt: pchar): void {
  var n: int64 := LFDParseString(txt);
  if (n <= 0 || LFDGetErrorCount(0) > 0) { PrintStr("abgewiesen "); } else { PrintStr("ANGENOMMEN "); }
}

fn main(): int64 {
  // --- Abschnitt 5: das vollstaendige Beispiel ----------------------------
  PrintStr("beispiel: ");
  liest("form \"Konfiguration\" { vertical { label \"Einstellungen\" { align: \"center\" } groupbox \"Optionen\" { vertical { checkbox \"Automatisch speichern\" { onchange: \"set-auto-save\" } checkbox \"Benachrichtigungen anzeigen\" { onchange: \"set-notifications\" } } } horizontal { button \"OK\" { width: 100 onclick: \"save-config\" } button \"Abbrechen\" { onclick: \"cancel\" } } } }"c);
  PrintLn("");

  // --- Abschnitt 1: Titel optional, kein Bezeichner ------------------------
  PrintStr("grundstruktur: ");
  liest("form { vertical { button { } } }"c);          // ohne Titel
  liest("form \"T\" { }"c);                             // mit Titel, leer
  liest("form { button \"OK\" }"c);                     // Widget ohne Block
  PrintLn("");

  // --- Abschnitt 3: Schluesselwoerter sind klein ---------------------------
  PrintStr("kleinschreibung: ");
  liest("form { vertical { button \"OK\" { } } }"c);
  weistAb("Form \"X\" { Vertical { Button \"OK\" { } } }"c);
  PrintLn("");

  // --- Abschnitt 3: Container und Widgets ----------------------------------
  PrintStr("container: ");
  liest("form { layout { } }"c);
  liest("form { grid { } }"c);
  liest("form { stack { } }"c);
  liest("form { tabwidget { } }"c);
  liest("form { splitter { } }"c);
  PrintLn("");

  PrintStr("widgets: ");
  liest("form { input { } }"c);
  liest("form { radiobutton { } }"c);
  liest("form { combobox { } }"c);
  liest("form { spinbox { } }"c);
  liest("form { slider { } }"c);
  liest("form { listbox { } }"c);
  liest("form { textedit { } }"c);
  liest("form { progressbar { } }"c);
  liest("form { image { } }"c);
  liest("form { custom { } }"c);
  PrintLn("");

  // --- Abschnitt 4: Properties ---------------------------------------------
  PrintStr("properties: ");
  liest("form { label { text: \"x\" } }"c);
  liest("form { label { tooltip: \"x\" } }"c);
  liest("form { label { enabled: true } }"c);
  liest("form { label { visible: false } }"c);
  liest("form { label { width: 100 } }"c);
  liest("form { label { height: 50 } }"c);
  liest("form { label { onclick: \"a\" } }"c);
  liest("form { label { onchange: \"b\" } }"c);
  liest("form { label { align: \"center\" } }"c);   // beliebiger Bezeichner
  PrintLn("");

  // --- Abschnitt 8: was die Grammatik NICHT beschreibt ---------------------
  PrintStr("ausgeschlossen: ");
  weistAb("Format: \"LFD v1.0\"\nform { }"c);        // Kopfzeile
  weistAb("form { webview \"x\" { } }"c);            // Widget-Typ gibt es nicht
  PrintLn("");

  return 0;
}
LYXEOF

if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
  echo "FAIL Messprogramm uebersetzt nicht"
  echo "--- 0 PASS, 1 FAIL"
  exit 1
fi

AUSGABE="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
if [ "$rc" -ge 128 ]; then
  echo "FAIL Messprogramm stuerzt ab (rc=$rc)"
  echo "--- 0 PASS, 1 FAIL"
  exit 1
fi

pruef() { # name, zeilenpraefix, erwarteter rest
  zeile="$(echo "$AUSGABE" | grep "^$2" | head -1)"
  ist="${zeile#$2}"
  if [ "$ist" = "$3" ]; then ok "$1"; else no "$1" "'$ist' erwartet '$3'"; fi
}

pruef "#1397: Beispiel aus Abschnitt 5 wird gelesen"     "beispiel: "        "ok "
pruef "#1397: Titel optional, Widget ohne Block"          "grundstruktur: "   "ok ok ok "
pruef "#1397: klein wird gelesen, gross abgewiesen"       "kleinschreibung: " "ok abgewiesen "
pruef "#1397: alle Container-Typen"                       "container: "       "ok ok ok ok ok "
pruef "#1397: alle Widget-Typen"                          "widgets: "         "ok ok ok ok ok ok ok ok ok ok "
pruef "#1397: Properties samt freiem Bezeichner"          "properties: "      "ok ok ok ok ok ok ok ok ok "
pruef "#1397: Kopfzeile und webview bleiben ausgeschlossen" "ausgeschlossen: " "abgewiesen abgewiesen "

# ===========================================================================
# Die Datei selbst
# ===========================================================================

SPEC="$ROOT/lfd-ebnf.md"
if [ ! -f "$SPEC" ]; then
  no "#1397: lfd-ebnf.md vorhanden" "Datei fehlt"
else
  ok "#1397: lfd-ebnf.md vorhanden"

  # Die alten, nie umgesetzten Formen duerfen nicht wieder als GRAMMATIK
  # dastehen. Erwaehnt werden sie in Abschnitt 8 ausdruecklich als
  # ausgeschlossen — geprueft wird deshalb die EBNF-Zeile, nicht das Wort.
  if grep -qE '^Form-Block +::=.*"Form"' "$SPEC"; then
    no "#1397: keine grossgeschriebene Form-Regel" "Regel mit \"Form\" steht wieder da"
  else
    ok "#1397: keine grossgeschriebene Form-Regel"
  fi

  if grep -qE '^Widget-Type +::=.*"Button"' "$SPEC"; then
    no "#1397: keine grossgeschriebenen Widget-Typen" "Regel mit \"Button\" steht wieder da"
  else
    ok "#1397: keine grossgeschriebenen Widget-Typen"
  fi

  # Der Parser ist maßgeblich — das muss in der Datei stehen, sonst ist die
  # Entscheidung beim nächsten Widerspruch wieder offen.
  if grep -qi "maßgeblich\|massgeblich" "$SPEC"; then
    ok "#1397: die Entscheidung steht in der Datei"
  else
    no "#1397: die Entscheidung steht in der Datei" "kein Hinweis auf den Parser als Massgabe"
  fi
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
