#!/usr/bin/env bash
# tests/array_field_len_test.sh — #1154 und #1155: Felder und Laenge an Arrays.
#
# #1154: Ein Feldzugriff auf einen Typ ohne benannte Felder wurde kommentarlos
# angenommen und lieferte 0. `a.foobar` war damit ein stiller Nullwert statt
# einer Meldung — und `a.len`, das die Doku als Feld des Fat-Pointers fuehrt,
# war von einem Tippfehler nicht zu unterscheiden.
#
# #1155: `len()` meldete bei einem Array-Literal immer die ANFANGSlaenge.
# `push` schrieb den Wert tatsaechlich ab, `pop` gab ihn zurueck — nur der
# Zaehler blieb stehen. Eine Schleife ueber ein aufgebautes Array lief also
# ueber die Startlaenge, ohne dass etwas abstuerzte.
#
# Beides wird an der AUSFUEHRUNG bzw. an der Meldung gemessen. Ein Test, der
# nur schaut, ob etwas uebersetzt, waere in beiden Faellen vorher gruen
# gewesen: #1154 uebersetzte klaglos, #1155 lief ohne Absturz durch.
#
# Jede Verschaerfung kommt mit der Gegenprobe: zu #1154 muessen die vier
# echten Zugriffe (length/len/cap/data) weiter durchgehen, sonst waere eine
# Pruefung, die ALLES abweist, ebenso gruen. Zu #1155 muss die Literal-Laenge
# dort Schranke BLEIBEN, wo das Array nicht waechst — sonst haette #1156
# stillschweigend seine Wirkung verloren.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Laeuft durch und liefert genau diese Ausgabe.
out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

# Wird schon beim Uebersetzen abgewiesen.
rejects() { # name, quelltext, erwartete meldung
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  got=$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if echo "$got" | grep -q "$3"; then echo "PASS $1 (abgewiesen)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht abgewiesen — '$(echo "$got" | tail -1)'"; FAIL=$((FAIL+1)); fi
}

KOPF='import src.std.io;'

# --- #1154: unbekannter Feldname meldet sich -------------------------------
# Bis 1.0.15A ergab jeder dieser Zugriffe still 0.
rejects "Tippfehler an einem Array" "$KOPF
fn main(): int64 {
    var a: array<int64> := [10, 20, 30];
    PrintLn(IntToStr(a.foobar));
    return 0;
}" "unknown field 'foobar'"

rejects "Feldzugriff auf int64" "$KOPF
fn main(): int64 {
    var n: int64 := 5;
    PrintLn(IntToStr(n.egal));
    return 0;
}" "unknown field 'egal'"

rejects "Feldzugriff auf bool" "$KOPF
fn main(): int64 {
    var b: bool := true;
    if (b.wahr) { return 1; }
    return 0;
}" "unknown field 'wahr'"

# --- #1154 Gegenprobe: die echten Zugriffe bleiben ------------------------
# `length` gab es vorher schon; `len` und `cap` lieferten 0 statt der Werte,
# die die Doku an dieser Stelle beschreibt.
out "length, len und cap liefern die Werte" "$KOPF
fn main(): int64 {
    var a: array<int64> := [10, 20, 30];
    PrintLn(IntToStr(a.length));
    PrintLn(IntToStr(a.len));
    PrintLn(IntToStr(a.cap));
    return 0;
}" "3
3
3"

out "data zeigt auf das erste Element" "$KOPF
fn main(): int64 {
    var a: array<int64> := [10, 20, 30];
    PrintLn(IntToStr(peek64(a.data)));
    return 0;
}" "10"

# --- #1155: die Laenge folgt push und pop ---------------------------------
# Der Weg zaehlt, nicht das Ergebnis: gemessen wird die Laenge NACH jeder
# Operation. Vor der Aenderung stand hier dreimal 3.
out "len folgt push und pop" "$KOPF
fn main(): int64 {
    var l: array<int64> := [10, 20, 30];
    PrintLn(IntToStr(len(l)));
    l.push(40);
    PrintLn(IntToStr(len(l)));
    PrintLn(IntToStr(l[3]));
    var v: int64 := l.pop();
    PrintLn(IntToStr(v));
    PrintLn(IntToStr(len(l)));
    return 0;
}" "3
4
40
40
3"

out "a.len folgt push ebenso" "$KOPF
fn main(): int64 {
    var a: array<int64> := [1, 2];
    a.push(3);
    a.push(4);
    PrintLn(IntToStr(a.len));
    return 0;
}" "4"

# Die Schleife ueber den BESTAND — das ist die praktische Folge von #1155.
out "Schleife laeuft ueber den Bestand, nicht die Startlaenge" "$KOPF
fn main(): int64 {
    var l: array<int64> := [1, 2];
    l.push(3);
    var summe: int64 := 0;
    var i: int64 := 0;
    while (i < len(l)) { summe := summe + l[i]; i := i + 1; }
    PrintLn(IntToStr(summe));
    return 0;
}" "6"

# --- #1155 Gegenprobe: ohne Wachstum bleibt die Schranke ------------------
# Waere die Literal-Laenge generell keine Schranke mehr, waeren diese beiden
# gruen durchgelaufen — und #1156 haette seine Wirkung verloren.
rejects "Literal ohne push: Index hinter dem Ende bleibt Fehler" "$KOPF
fn main(): int64 {
    var arr := [1, 2, 3];
    return arr[3];
}" "Index liegt ausserhalb"

rejects "feste Groesse: Index hinter dem Ende bleibt Fehler" "$KOPF
fn main(): int64 {
    let arr: int64[3] = [1, 2, 3];
    PrintLn(IntToStr(arr[5]));
    return 0;
}" "Index liegt ausserhalb"

# Und die feste Groesse meldet weiter ihre Groesse, nicht ein Laengenfeld.
out "feste Groesse: len bleibt die deklarierte Groesse" "$KOPF
fn main(): int64 {
    let arr: int64[3] = [1, 2, 3];
    PrintLn(IntToStr(len(arr)));
    return 0;
}" "3"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
