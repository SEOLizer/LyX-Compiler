#!/usr/bin/env bash
# tests/ffi_link_caps_test.sh — #1287, #1179, #1231.
#
# Drei stille Fehlfunktionen an der FFI- und Capability-Grenze.
#
# #1287: `@cap(...)` an einem `extern fn` schaltete den Aufruf AB. Der Parser
# legt die Annotation in child2 ab — genau dem Feld, das der Codegen als
# "hat einen Rumpf" liest. Die Deklaration lief damit als gewöhnliche Funktion
# durch und wurde als LEERER Rumpf emittiert: kein DT_NEEDED, kein PLT, das
# Binary blieb statisch, und der Aufruf tat nichts. Ausgerechnet die
# Annotation, mit der jemand sagt "ich weiß, was ich tue".
#
# #1179: Eine `extern fn`-Deklaration OHNE link-Klausel wurde angenommen; das
# Symbol wurde nie gebunden und der Aufruf lieferte still 0. Weil 0 bei vielen
# C-Funktionen ein gültiger Wert ist, fiel das nirgends auf — auch nicht in der
# eigenen Standardbibliothek, die 33 solcher Deklarationen trug.
#
# #1231: `grant`/`restrict` am Import werden geprüft, aber nicht durchgesetzt.
# Der Sicherheits-Score vergab dafür trotzdem bis zu +10 und wies damit eine
# Eindämmung aus, die es nicht gibt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

run_rc() { # name, quelltext, erwarteter exit-code
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  timeout 30 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$1"; else no "$1" "exit=$rc erwartet $3"; fi
}

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

nonzero() { # name, quelltext — die Ausgabe muss eine Zahl != 0 sein
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  case "$got" in
    ""|0) no "$1" "lieferte '$got' — genau der stille Nullwert aus #1179" ;;
    *[!0-9]*) no "$1" "keine Zahl: '$got'" ;;
    *) ok "$1 (=$got)" ;;
  esac
}

rejects() { # name, quelltext, erwartetes Textstueck der Meldung
  printf '%s\n' "$2" > "$TMP/r.lyx"; rm -f "$TMP/r"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
  if [ -f "$TMP/r" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $msg" ;; esac
}

# ===========================================================================
# #1287 — @cap schaltet den FFI-Aufruf nicht mehr ab
# ===========================================================================

# Der Repro aus dem Bericht: _exit(42) muss den Prozess mit 42 beenden. Vorher
# lief das Programm weiter und endete mit 7.
run_rc "@cap: extern-Aufruf wirkt wirklich" '@cap(system.exit)
extern fn _exit(status: int64): void link "libc.so.6";
fn main(): int64 { _exit(42); return 7; }' 42

# Der Beweis dafuer, dass wirklich gebunden wird: ohne DT_NEEDED bliebe das
# Binary statisch. Ein Ergebnistest allein saehe den Unterschied nicht, wenn
# der Aufruf zufaellig denselben Wert liefert.
printf '@cap(system.exit)\nextern fn _exit(status: int64): void link "libc.so.6";\nfn main(): int64 { _exit(42); return 7; }\n' > "$TMP/dyn.lyx"
rm -f "$TMP/dyn"; "$LYXC" --std-path="$ROOT" "$TMP/dyn.lyx" -o "$TMP/dyn" >/dev/null 2>&1
if [ -f "$TMP/dyn" ] && file "$TMP/dyn" | grep -q "dynamically linked"; then
  ok "@cap: Binary ist dynamisch gelinkt (DT_NEEDED vorhanden)"
else
  no "@cap: Binary ist dynamisch gelinkt (DT_NEEDED vorhanden)" "$(file "$TMP/dyn" 2>&1)"
fi

# Gegenprobe: der Weg ohne Annotation war nie kaputt und bleibt es nicht.
out "ohne Annotation unveraendert" 'extern fn strlen(s: pchar): int64 link "libc.so.6";
fn main(): int64 { Print(strlen("abcdefg"c)); Print("\n"); return 0; }' "7"

# ===========================================================================
# #1179 — link-Klausel ist Pflicht
# ===========================================================================

rejects "fehlende link-Klausel wird gemeldet" '@capabilities([system.exit, system.memory.heap, system.time])
import std.io;
extern fn time(t: int64): int64;
fn main(): int64 { PrintLn(IntToStr(time(0))); return 0; }' "link-Klausel fehlt"

nonzero "mit link-Klausel kommt ein echter Wert" '@capabilities([system.exit, system.memory.heap, system.time])
import std.io;
extern fn time(tloc: int64): int64 link "libc.so.6";
fn main(): int64 { PrintLn(IntToStr(time(0))); return 0; }'

# ── Die Standardbibliothek trug 33 solcher Deklarationen. Diese Funktionen
#    gaben allesamt still 0 zurueck; geprueft wird deshalb, dass ein ECHTER
#    Wert herauskommt, nicht bloss dass es uebersetzt.

nonzero "std.time.Now liefert eine echte Zeit" '@capabilities([system.exit, system.memory.heap, system.time])
import std.io;
import std.time;
fn main(): int64 { PrintLn(IntToStr(Now())); return 0; }'

nonzero "std.time.NowMs liefert Millisekunden" '@capabilities([system.exit, system.memory.heap, system.time])
import std.io;
import std.time;
fn main(): int64 { PrintLn(IntToStr(NowMs())); return 0; }'

nonzero "std.os.get_pid liefert die eigene PID" '@capabilities([system.exit, system.memory.heap])
import std.io;
import std.os;
fn main(): int64 { PrintLn(IntToStr(get_pid())); return 0; }'

nonzero "std.os.malloc liefert Speicher" '@capabilities([system.exit, system.memory.heap])
import std.io;
import std.alloc;
fn main(): int64 { var p: int64 := malloc(64); PrintLn(IntToStr(p)); return 0; }'

# Umgebung ohne libc: envp liegt beim Start hinter argv.
out "std.env liest die Umgebung ohne libc" '@capabilities([system.exit, system.memory.heap])
import std.io;
import std.env;
fn main(): int64 {
  var v: pchar := EnvLookupRaw("LYX_TEST_MARKER"c);
  if (v == 0 as pchar) { PrintLn("nicht-gesetzt"); return 0; }
  PrintLn(v);
  return 0;
}' "nicht-gesetzt"

printf '@capabilities([system.exit, system.memory.heap])\nimport std.io;\nimport std.env;\nfn main(): int64 {\n  var v: pchar := EnvLookupRaw("LYX_TEST_MARKER"c);\n  if (v == 0 as pchar) { PrintLn("nicht-gesetzt"); return 0; }\n  PrintLn(v);\n  return 0;\n}\n' > "$TMP/e.lyx"
rm -f "$TMP/e"; "$LYXC" --std-path="$ROOT" "$TMP/e.lyx" -o "$TMP/e" >/dev/null 2>&1
got="$(LYX_TEST_MARKER=gesetzt-42 timeout 30 "$TMP/e" 2>&1)"
if [ "$got" = "gesetzt-42" ]; then ok "gesetzte Variable wird gefunden"; else no "gesetzte Variable wird gefunden" "'$got'"; fi

# std/alloc: malloc/realloc/free liefen ueber nie gebundene libc-Symbole.
out "malloc/realloc/free arbeiten zusammen" '@capabilities([system.exit, system.memory.heap])
import std.io;
import std.alloc;
fn main(): int64 {
  var p: int64 := malloc(64);
  if (p == 0) { PrintLn("FAIL"); return 1; }
  poke64(p, 4711);
  var q: int64 := realloc_mem(p, 256);
  PrintLn(IntToStr(peek64(q)));
  free_mem(q);
  var c: int64 := calloc(4, 8);
  PrintLn(IntToStr(peek64(c)));
  return 0;
}' "4711
0"

# ===========================================================================
# #1231 — der Score behauptet keine Eindaemmung mehr
# ===========================================================================

printf '@capabilities([system.exit, system.memory.heap, fs.read])\nimport std.io;\nimport std.fs grant [];\nfn main(): int64 { return 0; }\n' > "$TMP/gr.lyx"
msg="$("$LYXC" --std-path="$ROOT" "$TMP/gr.lyx" -o "$TMP/gr" 2>&1)"
case "$msg" in
  *"Grant-Modell"*"nicht erzwungen"*|*"grant wird ohnehin nicht erzwungen"*)
    ok "Score weist das Grant-Modell als nicht erzwungen aus" ;;
  *) no "Score weist das Grant-Modell als nicht erzwungen aus" "Zeile fehlt: $(echo "$msg" | grep -i grant)" ;;
esac

case "$msg" in
  *"+10: Grant-Modell"*) no "keine Punkte mehr fuer blosse grant-Angaben" "vergibt weiterhin +10" ;;
  *) ok "keine Punkte mehr fuer blosse grant-Angaben" ;;
esac

# Die Obergrenze muss mitwandern — sonst waere der Wert gegen eine Summe
# gemessen, die niemand mehr erreichen kann.
case "$msg" in
  *"/35"*) ok "Obergrenze auf 35 gesenkt" ;;
  *) no "Obergrenze auf 35 gesenkt" "$(echo "$msg" | grep -i 'Sicherheits-Score')" ;;
esac

# Gegenprobe: die Modulebene wirkt weiterhin. Ohne fs.read bricht seccomp den
# Zugriff ab (SIGSYS = 159) — DAS ist die Eindaemmung, die es wirklich gibt.
run_rc "Modulebene wirkt weiterhin: fs.read fehlt, seccomp bricht ab" '@capabilities([system.exit, system.memory.heap])
import std.io;
import std.fs;
fn main(): int64 { if (FileExists("/etc/hostname"c)) { PrintLn("gelesen"); } return 0; }' 159

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
