#!/usr/bin/env bash
# tests/exception_unwind_test.sh — #1242, #1241, #1281.
#
# Drei Löcher im Ausnahmeweg, alle von derselben Art: der geradlinige Durchlauf
# war verdrahtet, der Fehlerweg nicht.
#
# #1242: `try { … } finally { … }` OHNE catch verschluckte die Ausnahme. Das
# finally lief, danach lief das Programm weiter und endete mit rc=0 — aus einem
# gemeldeten Fehler wurde stiller Erfolg.
#
# #1241: Verließ eine Funktion ihren Rumpf per `throw`, liefen ihre `defer`
# nicht. Genau im Fehlerfall — dem einzigen, für den man `defer CloseFile(fd)`
# schreibt — leckte der Deskriptor.
#
# #1281: `throw` erzeugte in ir_lower gar nichts; für die IR-Backends war es
# ein No-op, das Programm lief weiter und endete mit rc=0.
#
# Geprüft wird der WEG, nicht bloß das Ergebnis: die Tests vergleichen die
# REIHENFOLGE der Ausgaben (LIFO der defers, finally vor der Weiterreichung)
# und den Exit-Code. Ein Test, der nur "kam etwas an" prüft, wäre vor dem Fix
# grün gewesen — das finally lief ja.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe, erwarteter exit-code
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" != "$3" ]; then no "$1" "'$got' erwartet '$3'"; return; fi
  if [ "$rc" != "$4" ]; then no "$1" "exit=$rc erwartet $4 (Ausgabe stimmte)"; return; fi
  ok "$1"
}

# ===========================================================================
# #1242 — try/finally ohne catch reicht weiter
# ===========================================================================

out "finally ohne catch verschluckt nicht mehr" 'import std.io;
fn main(): int64 {
  try { throw 99; } finally { PrintLn("f"); }
  PrintLn("DANACH");
  return 0;
}' "f" 1

out "dasselbe in einer Unterfunktion erreicht den Aufrufer" 'import std.io;
fn F(): int64 { try { throw 99; } finally { PrintLn("f"); } return 0; }
fn main(): int64 { F(); PrintLn("DANACH"); return 0; }' "f" 1

# Die Weiterreichung endet beim nächsten Handler — nicht im Programmabbruch.
out "aeusseres catch faengt die weitergereichte Ausnahme" 'import std.io;
fn F(): int64 { try { throw 8; } finally { PrintLn("innen-f"); } return 0; }
fn main(): int64 {
  try { F(); } catch (e: int64) { PrintLn("aussen-c"); }
  PrintLn("DANACH");
  return 0;
}' "innen-f
aussen-c
DANACH" 0

# Gegenprobe: mit catch wird NICHT weitergereicht, und der geradlinige
# Durchlauf bleibt unberuehrt. Ohne diese beiden waere ein Rethrow, der immer
# feuert, ebenfalls gruen.
out "mit catch bleibt die Ausnahme gefangen" 'import std.io;
fn main(): int64 {
  try { throw 5; } catch (e: int64) { PrintLn("c"); } finally { PrintLn("f"); }
  PrintLn("DANACH");
  return 0;
}' "c
f
DANACH" 0

out "ohne Ausnahme laeuft finally genau einmal" 'import std.io;
fn main(): int64 {
  try { PrintLn("t"); } finally { PrintLn("f"); }
  PrintLn("DANACH");
  return 0;
}' "t
f
DANACH" 0

# ===========================================================================
# #1241 — defer läuft, wenn die Funktion per throw verlassen wird
# ===========================================================================

out "defer laeuft auf dem throw-Weg" 'import std.io;
fn F(): int64 { defer PrintLn("D-LAEUFT"); throw 3; return 0; }
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn("catch"); } return 0; }' "D-LAEUFT
catch" 0

# Reihenfolge: LIFO, wie auf dem return-Weg. Ein Test mit nur EINEM defer
# haette eine umgekehrte Kette nicht bemerkt.
out "mehrere defers laufen in LIFO-Reihenfolge" 'import std.io;
fn F(): int64 { defer PrintLn("d1"); defer PrintLn("d2"); defer PrintLn("d3"); throw 1; return 0; }
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn("c"); } return 0; }' "d3
d2
d1
c" 0

# Der throw ohne jeden Handler bricht ab — die defers laufen trotzdem vorher.
out "defer laeuft auch vor dem Abbruch ohne Handler" 'import std.io;
fn main(): int64 { defer PrintLn("d"); throw 4; return 0; }' "d" 1

# Zusammenspiel: defer im try, defer im Rahmen, finally, aeusseres catch.
# Die Reihenfolge ist die Aussage — sie unterscheidet die Ebenen voneinander.
out "Ebenen laufen in der richtigen Reihenfolge ab" 'import std.io;
fn F(): int64 {
  defer PrintLn("d-aussen");
  try { defer PrintLn("d-innen"); throw 2; } finally { PrintLn("f"); }
  return 0;
}
fn main(): int64 { try { F(); } catch (e: int64) { PrintLn("c"); } return 0; }' "d-innen
f
d-aussen
c" 0

# Gegenprobe: auf dem return-Weg laeuft der defer weiterhin genau einmal.
out "return-Weg unveraendert" 'import std.io;
fn F(): int64 { defer PrintLn("d"); return 7; }
fn main(): int64 { PrintLn(IntToStr(F())); return 0; }' "d
7" 0

# ===========================================================================
# #1281 — throw ist auf den IR-Backends kein No-op mehr
# ===========================================================================
# Nativ ausgeführt über lbf_run wie in den übrigen lyxos-Suiten; der Exit-Code
# des LBF-Programms ist das Ergebnis. Vorher erzeugte `throw` gar keinen Code:
# das Programm lief in die nächste Zeile und endete mit 0.

lyxos_exit() { # name, quelltext, erwarteter exit-code
  printf '%s' "$2" > "$TMP/l.lyx"
  if ! "$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/l.lyx" -o "$TMP/l.lyxnative" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht fuer lyxos"; return
  fi
  printf 'import src.tools.lbf.loader;\nfn main(): int64 { lbf_run("%s/l.lyxnative"c); return 111; }' "$TMP" > "$TMP/lr.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/lr.lyx" -o "$TMP/lr" >/dev/null 2>&1
  timeout 10 "$TMP/lr" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq "$3" ]; then ok "$1 (=$rc)"; else no "$1" "exit=$rc erwartet $3"; fi
}

lyxos_exit "lyxos: throw bricht mit 1 ab" 'fn main(): int64 { throw 9; return 0; }' 1
lyxos_exit "lyxos: ohne throw unveraendert"  'fn main(): int64 { return 7; }' 7

# Gegenprobe: try/catch bleibt für dieses Ziel abgewiesen — eine stille
# Fehlübersetzung wäre schlimmer als die Meldung.
printf 'fn main(): int64 { try { return 1; } catch (e: int64) { return 2; } }' > "$TMP/tc.lyx"
msg="$("$LYXC" --std-path="$ROOT" --target=lyxos "$TMP/tc.lyx" -o "$TMP/tc.lyxnative" 2>&1)"
if [ -f "$TMP/tc.lyxnative" ]; then
  no "lyxos: try/catch wird gemeldet" "uebersetzt, statt zu melden"
else
  case "$msg" in *"#1281"*) ok "lyxos: try/catch wird gemeldet" ;;
                 *) no "lyxos: try/catch wird gemeldet" "Meldung nennt #1281 nicht: $msg" ;; esac
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
