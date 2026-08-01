#!/usr/bin/env bash
# tests/builtin_id_test.sh — Builtin-IDs sind eindeutig vergeben (Issue #1037).
#
# Die ID in IRO_CALL_BUILTIN ist ein globaler Namensraum über alle Backends,
# vergeben wurde sie aber pro Backend-Zweig ad hoc. `Printf` und `mem_barrier()`
# trugen beide die 10: auf Linux-ARM64 emittierte Printf eine Speicherbarriere
# und gab nichts aus, auf Windows-ARM64 landete mem_barrier im Printf-Helfer —
# in beiden Fällen ohne Meldung, weil der Aufruf einen falschen, aber
# vorhandenen Handler traf.
#
# Geprüft wird deshalb statisch am Quelltext, dass jede in ir_lower.lyx
# vergebene allgemeine ID (< 20) in src/backend/_builtin_ids.md steht UND der
# dortige Eintrag den lowernden Aufrufer nennt. Dieselbe ID für mehrere
# Aufrufer ist erlaubt, wenn sie dieselbe Operation brauchen — `PrintStr` und
# `PrintLn` teilen sich die 1, beide werden zu `write(1, ptr, len)`. Die ID
# benennt die emittierte Operation, nicht den Namen im Quelltext; ein nicht
# eingetragener Aufrufer gilt als Kollision.
#
# Zusätzlich: kein ARM64-Zweig darf eine unbehandelte ID still durchfallen
# lassen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IR="$ROOT/src/ir_lower.lyx"
DOC="$ROOT/src/backend/_builtin_ids.md"
ARM="$ROOT/src/backend/arm64/emit_arm64.lyx"
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --- 1. Doppelvergabe ---------------------------------------------------
# Je Fundstelle die ID und den Namen des Builtins aus dem nächststehenden
# Kommentar bzw. dem seq()-Vergleich davor. Mehrere Fundstellen mit demselben
# Namen sind erlaubt (PrintStr hat drei Pfade: Literal, Zahl, Variable).
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
awk '
  /self\.seq\(fname, fnlen, "/ {
    match($0, /"[^"]+"/); name = substr($0, RSTART+1, RLENGTH-2)
  }
  /irAddInstrDirect\(IRO_CALL_BUILTIN/ {
    if (match($0, /-1, [0-9]+\)/)) {
      id = substr($0, RSTART+4, RLENGTH-5)
      print id "\t" name
    }
  }
' "$IR" | sort -u > "$tmp"

bad=""
n=0
while IFS=$'\t' read -r id name; do
  [ "$id" -lt 20 ] || continue
  n=$((n+1))
  row=$(grep -E "^\| *$id \|" "$DOC")
  if [ -z "$row" ]; then
    bad="$bad ${id}:${name}(kein-Eintrag)"
  elif ! echo "$row" | grep -q "\`$name\`"; then
    bad="$bad ${id}:${name}(nicht-eingetragen)"
  fi
done < "$tmp"

if [ -z "$bad" ]; then
  ok "alle $n allgemeinen Zuordnungen stehen in _builtin_ids.md"
else
  no "Zuordnung nicht belegt" "$bad"
  echo "    Entweder ist die ID doppelt vergeben (echte Kollision, umnummerieren),"
  echo "    oder der Aufrufer nutzt dieselbe Operation zu Recht — dann in"
  echo "    src/backend/_builtin_ids.md in die Spalte 'Lowering von' eintragen."
fi

# --- 3. Kein stiller Durchfall im ARM64-Backend -------------------------
# Beide Zweige von emitBuiltinCall müssen eine unbehandelte ID melden.
n=$(grep -c "_builtinUnsupported(id," "$ARM")
if [ "$n" -ge 2 ]; then
  ok "ARM64: beide Zweige melden unbehandelte IDs"
else
  no "ARM64: unbehandelte ID faellt still durch" "nur $n Meldezweig(e) gefunden"
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
