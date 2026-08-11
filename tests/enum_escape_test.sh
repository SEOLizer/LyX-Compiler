#!/usr/bin/env bash
# tests/enum_escape_test.sh — #1239, #1240 und #1285.
#
# Drei Faelle desselben Musters: der Compiler nahm etwas an, statt zu melden.
#
# #1239: `E.Zzz` bei einem Enum ohne diesen Member ergab still 0 — ein
# Tippfehler verhielt sich wie der erste Member. Ueberall sonst greift die
# Pruefung (`Garnix.Zzz` meldet ein unbekanntes Symbol, `s.zzz` ein unbekanntes
# Feld); nur der Enum fiel heraus.
#
# #1240: `enum E { A, A }` wurde angenommen. Welche Deklaration gewinnt, ist
# aus dem Quelltext nicht ablesbar — bei `enum E { A = 1, A = 7 }` wird die
# Frage sichtbar.
#
# #1285: Eine unbekannte Escape-Sequenz wurde zum blossen Zeichen: aus
# "A\x42C" wurde "Ax42C". Das hatte ein echtes Opfer — std/crt.lyx baut seine
# Farbausgabe auf "\x1b[…m" auf und lieferte den sichtbaren Text "x1b[31m"
# statt der ANSI-Sequenz. `\xHH` ist jetzt umgesetzt (und in ebnf.md §1
# nachgetragen), alles Uebrige wird gemeldet.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "Exit 0 — nicht abgewiesen"; return; fi
  if echo "$got" | grep -q "$3"; then ok "$1 (abgewiesen)"
  else no "$1" "andere Meldung — '$(echo "$got" | tail -1)'"; fi
}

KOPF='import src.std.io;'

# ===========================================================================
# #1239 — unbekannter Enum-Member
# ===========================================================================

rejects "unbekannter Enum-Member" "$KOPF
enum E { A, B }
fn main(): int64 { PrintLn(IntToStr(E.Zzz)); return 0; }" "unbekannter Enum-Member"

# Gegenprobe: vorhandene Member liefern weiterhin ihren Wert — sonst waere die
# Pruefung zu weit gefasst.
out "vorhandene Enum-Member unveraendert" "$KOPF
enum E { A, B, C }
fn main(): int64 {
  PrintLn(IntToStr(E.A));
  PrintLn(IntToStr(E.B));
  PrintLn(IntToStr(E.C));
  return 0;
}" "0
1
2"

out "Enum mit ausdruecklichen Werten" "$KOPF
enum E { A = 5, B = 9 }
fn main(): int64 { PrintLn(IntToStr(E.B)); return 0; }" "9"

# ===========================================================================
# #1240 — doppelter Member-Name
# ===========================================================================

rejects "doppelter Member-Name" "$KOPF
enum E { A, A }
fn main(): int64 { PrintLn(IntToStr(E.A)); return 0; }" "Member-Name doppelt vergeben"

rejects "doppelt mit verschiedenen Werten" "$KOPF
enum E { A = 1, A = 7 }
fn main(): int64 { PrintLn(IntToStr(E.A)); return 0; }" "Member-Name doppelt vergeben"

# Gegenprobe: verschiedene Namen bleiben erlaubt, auch mit gleichem WERT —
# das ist zulaessig und darf nicht mit abgewiesen werden.
out "gleicher Wert unter verschiedenen Namen bleibt erlaubt" "$KOPF
enum E { A = 3, B = 3 }
fn main(): int64 { PrintLn(IntToStr(E.A)); PrintLn(IntToStr(E.B)); return 0; }" "3
3"

# ===========================================================================
# #1285 — Escape-Sequenzen
# ===========================================================================

out "\\xHH wird zum Byte" "$KOPF
fn main(): int64 { PrintLn(\"\\x41\\x42\"); return 0; }" "AB"

out "der Repro aus dem Bericht" "$KOPF
fn main(): int64 { PrintLn(\"A\\x42C\"); return 0; }" "ABC"

# Die bekannten Sequenzen bleiben, wie sie waren.
out "bekannte Sequenzen unveraendert" "$KOPF
fn main(): int64 { PrintLn(\"a\\tb\\\\c\"); return 0; }" "a	b\\c"

rejects "unbekannte Sequenz wird gemeldet" "$KOPF
fn main(): int64 { PrintLn(\"a\\qb\"); return 0; }" "unbekannte Escape-Sequenz"

rejects "\\x ohne zwei Hexziffern" "$KOPF
fn main(): int64 { PrintLn(\"a\\xZZb\"); return 0; }" "zwei Hexziffern"

# Das eigentliche Opfer: std/crt.lyx baut seine Farbausgabe auf \\x1b auf und
# lieferte den sichtbaren Text statt der Sequenz. Geprueft wird das erste Byte
# (ESC = 27), nicht die ganze Zeichenkette — der Rest ist Terminal-Konvention.
printf '%s\n' 'import std.io;
import std.crt;
fn main(): int64 {
  var s: pchar := FgSequence(red);
  PrintLn(IntToStr(s[0]));
  return 0;
}' > "$TMP/crt.lyx"
if "$LYXC" --std-path="$ROOT" "$TMP/crt.lyx" -o "$TMP/crt" >/dev/null 2>&1; then
  got="$("$TMP/crt" 2>&1)"
  if [ "$got" = "27" ]; then ok "std.crt liefert die echte ANSI-Sequenz (ESC = 27)"
  else no "std.crt ANSI" "erstes Byte '$got' erwartet 27 (vorher 120 = 'x')"; fi
else
  no "std.crt ANSI" "uebersetzt nicht"
fi

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
