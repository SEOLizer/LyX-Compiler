#!/usr/bin/env bash
# tests/exit_group_test.sh — #1487.
#
# Ein Lyx-Programm beendete sich mit `exit` (Syscall 60). Der beendet nur den
# AUFRUFENDEN THREAD. Solange irgendein anderer Thread lebt, bleibt der Prozess
# stehen — bei reinen Lyx-Programmen fällt das nie auf, aber sobald eine
# FFI-Bibliothek einen Threadpool startet (Mesa/libGL tut das immer), hängt das
# Programm nach `main` unbegrenzt an wartenden Fremdthreads.
#
# Richtig ist `exit_group` (231): er beendet alle Threads der Gruppe.
#
# GEPRÜFT WIRD DER SYSCALL, nicht der Rückgabewert. Ein Programm ohne
# Fremdthreads beendet sich mit beiden Varianten sauber und mit demselben
# Exit-Code — ein Test auf „läuft durch" wäre vor dem Fix grün gewesen.
# Deshalb liest dieser Test mit, was der Prozess tatsächlich absetzt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if ! command -v strace >/dev/null 2>&1; then
  echo "SKIP strace nicht vorhanden — der Syscall laesst sich nicht mitlesen"
  echo "--- 0 PASS, 0 FAIL"
  exit 0
fi

bau() { # datei, quelltext
  printf '%s\n' "$2" > "$TMP/$1.lyx"; rm -f "$TMP/$1"
  "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >/dev/null 2>&1
}

syscall_am_ende() { # datei -> "exit_group" oder "exit"
  # Kein Zeilenanfang-Anker: schreibt das Programm auf stderr (panic tut das),
  # steht die Meldung ohne Zeilenumbruch vor dem Syscall in derselben Zeile.
  strace -e trace=exit,exit_group "$1" 2>&1 >/dev/null | grep -oE '(exit_group|exit)\(' | tail -1 | tr -d '('
}

# ===========================================================================
# Der Programm-Epilog
# ===========================================================================

bau normal 'import std.io;
fn main(): int64 { PrintLn("x"); return 0; }'
if [ -x "$TMP/normal" ]; then
  s="$(syscall_am_ende "$TMP/normal")"
  if [ "$s" = "exit_group" ]; then ok "regulaeres Programmende ruft exit_group"
  else no "regulaeres Programmende ruft exit_group" "'$s'"; fi
else
  no "regulaeres Programmende ruft exit_group" "uebersetzt nicht"
fi

# ===========================================================================
# Das exit()-Builtin
# ===========================================================================

bau mitcode 'fn main(): int64 { exit(3); return 0; }'
if [ -x "$TMP/mitcode" ]; then
  s="$(syscall_am_ende "$TMP/mitcode")"
  if [ "$s" = "exit_group" ]; then ok "exit(3) ruft exit_group"
  else no "exit(3) ruft exit_group" "'$s'"; fi
  "$TMP/mitcode"; rc=$?
  if [ "$rc" -eq 3 ]; then ok "exit(3) setzt den Rueckgabewert weiterhin"
  else no "exit(3) setzt den Rueckgabewert weiterhin" "rc=$rc"; fi
else
  no "exit(3) ruft exit_group" "uebersetzt nicht"
  no "exit(3) setzt den Rueckgabewert weiterhin" "uebersetzt nicht"
fi

# ===========================================================================
# sys_exit bleibt, was es ist
# ===========================================================================

# Wer ausdruecklich SYS_exit ruft, will genau das — einen einzelnen Thread
# beenden. Dieses Builtin darf nicht mitumgestellt werden, sonst gaebe es
# keinen Weg mehr, das auszudruecken.
bau roh 'fn main(): int64 { sys_exit(5); return 0; }'
if [ -x "$TMP/roh" ]; then
  s="$(syscall_am_ende "$TMP/roh")"
  if [ "$s" = "exit" ]; then ok "sys_exit(5) ruft weiterhin exit (Thread-Ende)"
  else no "sys_exit(5) ruft weiterhin exit (Thread-Ende)" "'$s'"; fi
else
  no "sys_exit(5) ruft weiterhin exit (Thread-Ende)" "uebersetzt nicht"
fi

bau rohgruppe 'fn main(): int64 { sys_exit_group(6); return 0; }'
if [ -x "$TMP/rohgruppe" ]; then
  "$TMP/rohgruppe"; rc=$?
  if [ "$rc" -eq 6 ]; then ok "sys_exit_group(6) unveraendert"
  else no "sys_exit_group(6) unveraendert" "rc=$rc"; fi
else
  no "sys_exit_group(6) unveraendert" "uebersetzt nicht"
fi

# ===========================================================================
# Der Abbruchweg
# ===========================================================================

# panic beendet den Prozess — auch dort muss die ganze Gruppe enden, sonst
# haengt ein Programm nach einem Abbruch an fremden Threads, statt zu sterben.
bau abbruch 'fn main(): int64 { panic("aus"); return 0; }'
if [ -x "$TMP/abbruch" ]; then
  s="$(syscall_am_ende "$TMP/abbruch")"
  if [ "$s" = "exit_group" ]; then ok "panic beendet die ganze Prozessgruppe"
  else no "panic beendet die ganze Prozessgruppe" "'$s'"; fi
else
  no "panic beendet die ganze Prozessgruppe" "uebersetzt nicht"
fi

# ===========================================================================
# Gegenprobe: ein Programm mit eigenem Thread haengt nicht mehr
# ===========================================================================

# Der Fall aus der Meldung ohne FFI nachgestellt: ein Thread, der laenger
# lebt als main. Vor dem Fix waere hier die Zeitueberschreitung gekommen.
bau mitthread 'import std.io;
import std.time;
import std.thread;
fn schlaefer(arg: int64): int64 {
  var i: int64 := 0;
  while (i < 100) { Sleep(50); i := i + 1; }
  return 0;
}
fn main(): int64 {
  var t: Thread := ThreadCreate(schlaefer as int64, 0);
  Sleep(30);
  PrintLn("main fertig");
  return 0;
}'
if [ -x "$TMP/mitthread" ]; then
  start="$(date +%s)"
  got="$(timeout 10 "$TMP/mitthread" 2>&1)"; rc=$?
  dauer=$(( $(date +%s) - start ))
  if [ "$rc" -eq 124 ]; then
    no "Programm mit lebendem Thread endet sofort" "Zeitueberschreitung — der Prozess haengt"
  elif [ "$got" = "main fertig" ] && [ "$dauer" -le 3 ]; then
    ok "Programm mit lebendem Thread endet sofort"
  else
    no "Programm mit lebendem Thread endet sofort" "'$got' rc=$rc nach ${dauer}s"
  fi
else
  no "Programm mit lebendem Thread endet sofort" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
