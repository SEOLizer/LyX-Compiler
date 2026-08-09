#!/usr/bin/env bash
# tests/enum_explicit_value_test.sh — #1131 (und #1157): explizite Enum-Werte.
#
# `enum E { A = 10, B = 20 }` lieferte fuer `E.A` den Wert 4294967296 und fuer
# `E.B` 4294967297 — also 2^32 + Positionsindex. Der angegebene Wert spielte
# keine Rolle, auch wenn er mit der impliziten Zaehlung uebereinstimmte.
#
# Ursache: der Wertausdruck haengt am Mitglied als c0, und `cg_buildEnumLayout`
# zaehlte die Kinder als NUTZLAST. `payloadCnt` wurde damit 1, landete in der
# oberen Haelfte des gepackten Ergebnisses ({Wert unten, Nutzlastgroesse oben}),
# und der Tag blieb der Positionsindex. Eine Nutzlast gibt es in der
# Deklaration gar nicht — `EnumMember = Ident [ "=" IntLiteral ]` (ebnf.md §10);
# die Musterform `Ok(wert)` wird beim `match` aufgeloest.
#
# Geprueft wird der WERT. Ein Test auf Uebersetzbarkeit waere immer gruen
# gewesen, und ein Test nur mit rein impliziten Enums haette nichts gemerkt —
# die waren die ganze Zeit korrekt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

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

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

K='import src.std.io;'

# --- Der Repro aus dem Issue ---------------------------------------------
out "Repro: A = 10, B = 20" "$K
enum E { A = 10, B = 20 }
fn main(): int64 { PrintLn(E.A); PrintLn(E.B); return 0; }" '10
20'

# Der Fehler trat auch auf, wenn der explizite Wert der impliziten Zaehlung
# ENTSPRACH — dort faellt nur die 2^32 auf.
out "explizite Werte gleich der Zaehlung" "$K
enum E { A = 0, B = 1, C = 2 }
fn main(): int64 { PrintLn(E.A); PrintLn(E.B); PrintLn(E.C); return 0; }" '0
1
2'

out "einzelnes Mitglied mit Wert" "$K
enum E { A = 100 }
fn main(): int64 { PrintLn(E.A); return 0; }" '100'

# --- Teilweise explizit: der Zaehler laeuft weiter -----------------------
# `A = 5, B, C` ergibt 5, 6, 7 — wie in C. Vorher lieferte A 2^32 und B/C
# fielen auf die Positionszaehlung zurueck (1, 2).
out "teilweise explizit zaehlt weiter" "$K
enum E { A = 5, B, C }
fn main(): int64 { PrintLn(E.A); PrintLn(E.B); PrintLn(E.C); return 0; }" '5
6
7'

out "Wert in der Mitte setzt neu" "$K
enum E { A, B = 10, C }
fn main(): int64 { PrintLn(E.A); PrintLn(E.B); PrintLn(E.C); return 0; }" '0
10
11'

# --- Der Zweck der Sache: Protokollwerte ---------------------------------
out "Protokollkonstanten" "$K
enum Op { GET = 1, PUT = 2, DEL = 255 }
fn main(): int64 { PrintLn(Op.GET); PrintLn(Op.PUT); PrintLn(Op.DEL); return 0; }" '1
2
255'

# Der Vergleich mit einem eingelesenen Wert muss treffen — genau das schlug
# vorher immer fehl.
out "Vergleich mit eingelesenem Wert" "$K
enum Op { GET = 1, DEL = 255 }
fn main(): int64 {
    var v: int64 := 255;
    if (v == Op.DEL) { PrintStrLn(\"del\"c); } else { PrintStrLn(\"nein\"c); }
    return 0;
}" 'del'

# Der Cast schnitt vorher die obere Haelfte ab und lieferte den Positionsindex.
out "Cast nach uint8" "$K
enum Op { DEL = 255 }
fn main(): int64 { var b: int64 := Op.DEL as uint8; PrintLn(b); return 0; }" '255'

out "als Funktionsargument" "$K
enum Op { GET = 7 }
fn F(x: int64): int64 { return x + 1; }
fn main(): int64 { PrintLn(F(Op.GET)); return 0; }" '8'

# --- Konstante Ausdruecke als Wert ---------------------------------------
out "con und Rechnung als Wert" "$K
con BASE: int64 := 16;
enum R { CTRL = BASE, STAT = BASE + 4 }
fn main(): int64 { PrintLn(R.CTRL); PrintLn(R.STAT); return 0; }" '16
20'

# --- match und qualifizierter Zugriff ------------------------------------
out "match ueber explizite Werte" "$K
enum E { A = 10, B = 20 }
fn main(): int64 {
    var x: int64 := E.B;
    match x {
      case E.A => { PrintStrLn(\"A\"c); }
      case E.B => { PrintStrLn(\"B\"c); }
      case _ => { PrintStrLn(\"?\"c); }
    }
    return 0;
}" 'B'

# --- Gegenprobe: rein implizite Enums waren korrekt und bleiben es -------
out "implizites Enum unveraendert" "$K
enum F { X, Y, Z }
fn main(): int64 { PrintLn(F.X); PrintLn(F.Y); PrintLn(F.Z); return 0; }" '0
1
2'

out "match ueber implizites Enum unveraendert" "$K
enum F { X, Y, Z }
fn main(): int64 {
    var v: int64 := F.Y;
    match v {
      case F.X => { PrintStrLn(\"X\"c); }
      case F.Y => { PrintStrLn(\"Y\"c); }
      case _ => { PrintStrLn(\"?\"c); }
    }
    return 0;
}" 'Y'

# Zwei Mitglieder duerfen denselben Wert tragen (Aliasnamen).
out "gleicher Wert zweimal" "$K
enum E { A = 1, B = 1 }
fn main(): int64 { PrintLn(E.A); PrintLn(E.B); return 0; }" '1
1'

# --- Grenzen: melden statt still das Falsche tun -------------------------
# Wert und Nutzlastgroesse teilen sich eine int64 (Wert unten, Groesse oben).
# Ein negativer Wert oder einer jenseits 2^32-1 liefe in die obere Haelfte.
fails "negativer Wert meldet" "$K
enum H { N = 0 - 3 }
fn main(): int64 { PrintLn(H.N); return 0; }" "ausserhalb von 0..4294967295"

fails "Wert jenseits 2^32-1 meldet" "$K
enum H { N = 4294967296 }
fn main(): int64 { PrintLn(H.N); return 0; }" "ausserhalb von 0..4294967295"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
