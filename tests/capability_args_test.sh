#!/usr/bin/env bash
# tests/capability_args_test.sh — #1108: Capability-ARGUMENTE.
#
# Die Capability-EBENE selbst greift und ist anderswo abgedeckt: ohne `fs.read`
# bricht ein Dateizugriff zur Laufzeit mit SIGSYS ab, und ein erfundener
# Capability-NAME wird abgewiesen. Ungeprueft blieben die Argumente:
#
#   * `fs.read(zzz_arg: "x")` und `fs.read(pfad: "/tmp")` uebersetzten
#     kommentarlos — die Wertebereichspruefung sah nur bekannte Schluessel an
#     und fiel fuer alles andere auf "in Ordnung".
#   * `fs.read(path: "/tmp")` wird NICHT durchgesetzt: die Sandbox wirkt als
#     Ja/Nein. Eine Annotation, die eine Beschraenkung ausdrueckt und sie nicht
#     einhaelt, erzeugt eine Sicherheitszusage, die es nicht gibt.
#   * Die Bereichsform von PortSpec (§22) parste nicht.
#
# Geprueft wird deshalb, was der Compiler MELDET. Ein Test, der nur schaut, ob
# etwas uebersetzt, waere bei jedem dieser Punkte gruen gewesen — genau das war
# der Befund.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Uebersetzt NICHT, und die Meldung enthaelt den Text.
rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if ! echo "$got" | grep -q "$3"; then
    echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | grep -iE 'error|warning' | head -1)'"; FAIL=$((FAIL+1)); return
  fi
  if [ -f "$TMP/c" ]; then
    echo "FAIL $1: gemeldet, aber trotzdem uebersetzt"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
}

# Uebersetzt, meldet dabei aber eine Warnung mit diesem Text.
warns() { # name, quelltext, erwarteter warntext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (gewarnt)"; PASS=$((PASS+1))
  else echo "FAIL $1: keine Warnung — '$(echo "$got" | grep -iE 'warning' | head -1)'"; FAIL=$((FAIL+1)); fi
}

# Uebersetzt ohne Meldung zu den Capability-Argumenten.
quiet() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ ! -f "$TMP/c" ]; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  if echo "$got" | grep -qE "Capability-Argument|Capability nimmt"; then
    echo "FAIL $1: meldet etwas zu Argumenten, obwohl keine da sind"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 (still)"; PASS=$((PASS+1))
}

M='fn main(): int64 { return 0; }'

# --- 1. Argumentnamen werden geprueft ------------------------------------
rejects "erfundener Argumentname" \
  "@capabilities([fs.read(zzz_arg: \"x\"), system.exit])
$M" "unbekanntes Capability-Argument"

# Der Tippfehler aus dem Issue: `pfad` statt `path`. Er fiel doppelt nicht auf
# — nicht beim Uebersetzen, und zur Laufzeit ohnehin nicht.
rejects "Tippfehler pfad statt path" \
  "@capabilities([fs.read(pfad: \"/tmp\"), system.exit])
$M" "unbekanntes Capability-Argument"

rejects "Argument an einer Capability ohne Argumente" \
  "@capabilities([system.time(foo: 1), system.exit])
$M" "diese Capability nimmt keine Argumente"

rejects "falscher Schluessel an hardware.gpio" \
  "@capabilities([hardware.gpio(pinnummer: 4)])
$M" "unbekanntes Capability-Argument"

# Der Wertebereich wird weiterhin geprueft — die Namenspruefung darf ihn nicht
# verdraengen.
rejects "gueltiger Name, Wert ausserhalb des Bereichs" \
  "@capabilities([hardware.gpio(pin: 999)])
$M" "Pin außerhalb"

# --- 2. Gueltige Namen werden als folgenlos gemeldet ----------------------
warns "path an fs.read" \
  "@capabilities([fs.read(path: \"/tmp\"), system.exit])
$M" "NICHT durchgesetzt"

warns "pin an hardware.gpio" \
  "@capabilities([hardware.gpio(pin: 4)])
$M" "NICHT durchgesetzt"

# --- 3. PortSpec: die Bereichsform aus §22 --------------------------------
warns "PortSpec-Bereich parst" \
  "@capabilities([network.tcp.connect(host: \"example.com\":8000-9000), system.exit])
$M" "NICHT durchgesetzt"

warns "PortSpec Einzelport" \
  "@capabilities([network.tcp.connect(host: \"example.com\":8000), system.exit])
$M" "NICHT durchgesetzt"

warns "PortSpec Wildcard" \
  "@capabilities([network.tcp.connect(host: \"example.com\":*), system.exit])
$M" "NICHT durchgesetzt"

rejects "PortSpec-Bereich verdreht" \
  "@capabilities([network.tcp.connect(host: \"a\":9000-8000)])
$M" "Endport liegt vor dem Startport"

# --- 4. Gegenproben -------------------------------------------------------
# Ohne Argumente darf nichts gemeldet werden; sonst waere jede Capability
# betroffen und die Meldung wertlos.
quiet "Capabilities ohne Argumente" \
  "@capabilities([fs.read, fs.write, system.exit, system.memory.heap])
$M"

quiet "gar keine Capability-Annotation" "$M"

# Der Capability-NAME wird weiterhin geprueft — die Argumentpruefung darf ihn
# nicht ueberdecken.
rejects "erfundene Capability" \
  "@capabilities([zzz.erfunden])
$M" "unbekannte Capability"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
