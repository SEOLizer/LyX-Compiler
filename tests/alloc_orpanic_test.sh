#!/usr/bin/env bash
# tests/alloc_orpanic_test.sh — #1398.
#
# `malloc_orpanic` versprach dem Namen nach einen Abbruch bei Speichermangel
# und wiederholte den Versuch stattdessen endlos:
#
#   while (ptr == 0) { ptr := malloc(size); }
#
# Wiederholen konnte nie helfen. `malloc` liefert 0 in drei Fällen: Größe <= 0,
# Größe > 1 GiB, und mmap scheitert. Die ersten beiden hängen allein am
# Argument — die Bedingung ändert sich nie. Beim dritten gibt es niemanden, der
# nebenher Speicher freigeben könnte: dieses Programm hängt ja in der Schleife.
#
# DER TEST MISST DIE ZEIT, nicht nur den Rückgabewert. Vor dem Fix wäre er in
# eine Zeitüberschreitung gelaufen — genau das ist der Defekt. Eine Prüfung auf
# „liefert nicht 0" wäre nie fertig geworden und hätte gar nichts gemeldet.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

bau() { # datei, quelltext
  printf '%s\n' "$2" > "$TMP/$1.lyx"; rm -f "$TMP/$1"
  "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >/dev/null 2>&1
}

# ===========================================================================
# Der Kern: die Funktion kehrt zurueck, statt zu drehen
# ===========================================================================

# 2 GiB liegt ueber der 1-GiB-Grenze von alloc. Vor dem Fix war das der
# deterministisch endlose Fall: malloc lieferte immer 0, und die Bedingung
# konnte sich nicht aendern.
bau ueber 'import std.io;
import std.alloc;
fn main(): int64 {
  PrintLn("vorher");
  var q: int64 := malloc_orpanic(2000000000);
  PrintLn("nie erreicht");
  return 0;
}'
if [ -x "$TMP/ueber" ]; then
  start="$(date +%s)"
  ausgabe="$(timeout 10 "$TMP/ueber" 2>&1)"; rc=$?
  dauer=$(( $(date +%s) - start ))
  if [ "$rc" -eq 124 ]; then
    no "2 GiB: bricht ab statt zu drehen" "Zeitueberschreitung nach 10 s — die Endlosschleife ist zurueck"
  else
    if [ "$dauer" -le 5 ]; then ok "2 GiB: bricht ab statt zu drehen"
    else no "2 GiB: bricht ab statt zu drehen" "dauerte ${dauer}s"; fi
  fi

  # Der Abbruch muss auch als solcher erkennbar sein — Exit 0 waere ein
  # stiller Durchmarsch.
  if [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ]; then ok "2 GiB: Exitcode meldet den Abbruch ($rc)"
  else no "2 GiB: Exitcode meldet den Abbruch" "rc=$rc"; fi

  # Und die Meldung muss sagen, worum es ging. "out of memory" allein liesse
  # offen, ob der Speicher alle war oder die Anforderung unzulaessig.
  case "$ausgabe" in
    *"malloc_orpanic"*"2000000000"*) ok "2 GiB: die Meldung nennt die Groesse" ;;
    *) no "2 GiB: die Meldung nennt die Groesse" "$(echo "$ausgabe" | tail -2 | tr '\n' ' ')" ;;
  esac

  # Was vor dem Abbruch lief, muss geschrieben sein — sonst waere unklar, wo
  # das Programm stand.
  case "$ausgabe" in
    vorher*) ok "2 GiB: Ausgabe vor dem Abbruch ist da" ;;
    *) no "2 GiB: Ausgabe vor dem Abbruch ist da" "$(echo "$ausgabe" | head -1)" ;;
  esac
else
  no "2 GiB: bricht ab statt zu drehen" "uebersetzt nicht"
  no "2 GiB: Exitcode meldet den Abbruch" "uebersetzt nicht"
  no "2 GiB: die Meldung nennt die Groesse" "uebersetzt nicht"
  no "2 GiB: Ausgabe vor dem Abbruch ist da" "uebersetzt nicht"
fi

# Groesse 0 ist der zweite Fall, in dem malloc immer 0 liefert — ebenfalls
# vorher endlos.
bau null 'import std.io;
import std.alloc;
fn main(): int64 { var p: int64 := malloc_orpanic(0); PrintLn("nie erreicht"); return 0; }'
if [ -x "$TMP/null" ]; then
  timeout 10 "$TMP/null" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 124 ]; then no "Groesse 0: bricht ab" "Zeitueberschreitung"
  elif [ "$rc" -ne 0 ]; then ok "Groesse 0: bricht ab"
  else no "Groesse 0: bricht ab" "Exit 0 — durchmarschiert"; fi
else
  no "Groesse 0: bricht ab" "uebersetzt nicht"
fi

# ===========================================================================
# Gegenprobe: der Normalfall bleibt unveraendert
# ===========================================================================

bau gut 'import std.io;
import std.alloc;
fn main(): int64 {
  var p: int64 := malloc_orpanic(64);
  if (p == 0) { PrintLn("null"); return 1; }
  poke64(p, 4711);
  PrintStr(IntToStr(peek64(p))); PrintStr(" ");
  var q: int64 := malloc_orpanic(1048576);
  if (q == 0) { PrintLn("null"); return 1; }
  poke64(q + 1048568, 42);
  PrintLn(IntToStr(peek64(q + 1048568)));
  return 0;
}'
if [ -x "$TMP/gut" ]; then
  got="$(timeout 30 "$TMP/gut" 2>&1)"; rc=$?
  if [ "$got" = "4711 42" ] && [ "$rc" -eq 0 ]; then ok "gueltige Anforderungen liefern nutzbaren Speicher"
  else no "gueltige Anforderungen liefern nutzbaren Speicher" "'$got' rc=$rc"; fi
else
  no "gueltige Anforderungen liefern nutzbaren Speicher" "uebersetzt nicht"
fi

# malloc_safe ist der Nachbar, der 0 zurueckgeben SOLL — er darf nicht
# mitabbrechen. Der Unterschied zwischen beiden ist der Zweck von #1398.
bau safe 'import std.io;
import std.alloc;
fn main(): int64 {
  PrintStr(IntToStr(malloc_safe(2000000000))); PrintStr(" ");
  var p: int64 := malloc_safe(64);
  if (p != 0) { PrintLn("ok"); } else { PrintLn("null"); }
  return 0;
}'
if [ -x "$TMP/safe" ]; then
  got="$(timeout 30 "$TMP/safe" 2>&1)"; rc=$?
  if [ "$got" = "0 ok" ] && [ "$rc" -eq 0 ]; then ok "malloc_safe meldet weiterhin 0, ohne abzubrechen"
  else no "malloc_safe meldet weiterhin 0, ohne abzubrechen" "'$got' rc=$rc"; fi
else
  no "malloc_safe meldet weiterhin 0, ohne abzubrechen" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
