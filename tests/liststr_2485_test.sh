#!/usr/bin/env bash
# tests/liststr_2485_test.sh — #2485: ListStr* in std.list.
#
# BEFUND. Eine Liste von Zeichenketten gab es in der stdlib nicht; sie lag nur
# als TStringList im lyx-vcl-Paket (vega/lists.lyx). Eine so grundlegende
# Datenstruktur gehoert in den Compiler.
#
# WAS HIER GEPRUEFT WIRD, und zwar an der WIRKUNG statt am Vorhandensein:
# jeder Fall gibt einen Wert aus, der falsch waere, wenn die Umsetzung falsch
# ist. "Funktion existiert" oder "Laenge plausibel" wuerde die Fehler
# verdecken, um die es hier geht.
#
# DIE ZENTRALE ZUSAGE IST DAS EIGENTUM. Die Liste legt eine eigene Kopie an.
# Geprueft wird das so, wie es sonst niemand merkt: der Quellpuffer wird NACH
# dem Einfuegen ueberschrieben, und die Liste muss weiter den alten Text
# liefern. Haelt sie bloss den Zeiger, fliegt genau das auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# pruef <name> <rumpf> <erwartete Ausgabe>
pruef() {
  { printf 'unit main;\nimport std.io;\nimport std.list;\n'
    printf 'fn Zeig(l: int64): void { var j: pchar := ListStrJoin(l, "|"c); PrintLn(j); ListStrJoinFree(j); }\n'
    printf 'fn main(): int64 {\n'
    printf '%s' "$2"
    printf '\n  return 0;\n}\n'; } > "$TMP/p.lyx"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >"$TMP/log" 2>&1; then
    echo "FAIL $1: uebersetzt nicht"
    grep -iE "error" "$TMP/log" | head -2 | sed 's/^/    /'
    FAIL=$((FAIL+1)); return
  fi
  local got
  got="$( ulimit -v 2000000 -c 0; timeout 30 "$TMP/p" 2>&1 )"
  local rc=$?
  if [ "$rc" != "0" ]; then
    echo "FAIL $1: Lauf endete mit rc=$rc (Ausgabe: '$got')"
    FAIL=$((FAIL+1)); return
  fi
  if [ "$got" != "$3" ]; then
    echo "FAIL $1: '$got' statt '$3'"
    FAIL=$((FAIL+1)); return
  fi
  echo "PASS $1 ($3)"
  PASS=$((PASS+1))
}

echo "-- Grundrechnung --"
pruef "Add gibt den Index, Len zaehlt mit" '
  var l: int64 := ListStrNew();
  PrintLn(IntToStr(ListStrAdd(l, "a"c)));
  PrintLn(IntToStr(ListStrAdd(l, "b"c)));
  PrintLn(IntToStr(ListStrLen(l)));
  ListStrFree(l);' '0
1
2'

pruef "Get liefert den Text, LengthOf die Laenge" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "hallo"c);
  PrintLn(ListStrGet(l, 0));
  PrintLn(IntToStr(ListStrLengthOf(l, 0)));
  ListStrFree(l);' 'hallo
5'

pruef "leere Liste und Grenzen" '
  var l: int64 := ListStrNew();
  if (ListStrIsEmpty(l)) { PrintLn("leer"c); }
  PrintLn(IntToStr(ListStrLen(l)));
  PrintLn(IntToStr(ListStrLengthOf(l, 0)));
  PrintLn(IntToStr(ListStrIndexOf(l, "x"c)));
  ListStrFree(l);' 'leer
0
-1
-1'

echo "-- Eigentum: die Liste KOPIERT --"
pruef "Quellpuffer nach dem Einfuegen geaendert" '
  var buf: int64 := alloc(8);
  poke8(buf, 65); poke8(buf + 1, 66); poke8(buf + 2, 0);
  var l: int64 := ListStrNew();
  ListStrAdd(l, buf as pchar);
  poke8(buf, 88); poke8(buf + 1, 89);
  PrintLn(ListStrGet(l, 0));
  PrintLn(buf as pchar);
  ListStrFree(l);' 'AB
XY'

pruef "Set ersetzt und gibt den alten Eintrag frei" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "alt"c);
  if (ListStrSet(l, 0, "neuer"c)) { PrintLn(ListStrGet(l, 0)); }
  PrintLn(IntToStr(ListStrLengthOf(l, 0)));
  if (!ListStrSet(l, 7, "x"c)) { PrintLn("Grenze haelt"c); }
  ListStrFree(l);' 'neuer
5
Grenze haelt'

echo "-- Umstellen --"
pruef "InsertAt, RemoveAt, Remove" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "a"c); ListStrAdd(l, "c"c);
  ListStrInsertAt(l, 1, "b"c);
  Zeig(l);
  ListStrRemoveAt(l, 0);
  Zeig(l);
  if (ListStrRemove(l, "c"c)) { Zeig(l); }
  if (!ListStrRemove(l, "weg"c)) { PrintLn("nicht da"c); }
  ListStrFree(l);' 'a|b|c
b|c
b
nicht da'

pruef "Sort, SortDesc, Exchange" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "birne"c); ListStrAdd(l, "apfel"c); ListStrAdd(l, "citrone"c);
  ListStrSort(l);
  Zeig(l);
  ListStrSortDesc(l);
  Zeig(l);
  ListStrExchange(l, 0, 2);
  Zeig(l);
  if (!ListStrExchange(l, 0, 9)) { PrintLn("Grenze haelt"c); }
  ListStrFree(l);' 'apfel|birne|citrone
citrone|birne|apfel
apfel|birne|citrone
Grenze haelt'

pruef "SortedPos auf sortierter Liste" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "a"c); ListStrAdd(l, "c"c); ListStrAdd(l, "e"c);
  PrintLn(IntToStr(ListStrSortedPos(l, "a"c)));
  PrintLn(IntToStr(ListStrSortedPos(l, "b"c)));
  PrintLn(IntToStr(ListStrSortedPos(l, "f"c)));
  ListStrFree(l);' '0
1
3'

echo "-- Clone, Clear, Join, Split --"
pruef "Clone ist unabhaengig" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "eins"c);
  var k: int64 := ListStrClone(l);
  ListStrSet(l, 0, "geaendert"c);
  PrintLn(ListStrGet(l, 0));
  PrintLn(ListStrGet(k, 0));
  ListStrFree(k);
  ListStrFree(l);' 'geaendert
eins'

pruef "Clear leert, Liste bleibt benutzbar" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "a"c); ListStrAdd(l, "b"c);
  ListStrClear(l);
  PrintLn(IntToStr(ListStrLen(l)));
  ListStrAdd(l, "neu"c);
  PrintLn(ListStrGet(l, 0));
  ListStrFree(l);' '0
neu'

pruef "Join mit Trenner, leere Liste" '
  var l: int64 := ListStrNew();
  ListStrAdd(l, "a"c); ListStrAdd(l, "bb"c);
  var j: pchar := ListStrJoin(l, ", "c);
  PrintLn(j);
  ListStrJoinFree(j);
  var e: int64 := ListStrNew();
  var j2: pchar := ListStrJoin(e, ","c);
  if (peek8(j2 as int64) == 0) { PrintLn("leer"c); }
  ListStrJoinFree(j2);
  ListStrFree(e);
  ListStrFree(l);' 'a, bb
leer'

pruef "Split behaelt leere Felder" '
  var z: int64 := ListStrSplit("a,,bc,"c, 44);
  PrintLn(IntToStr(ListStrLen(z)));
  PrintLn(IntToStr(ListStrLengthOf(z, 1)));
  PrintLn(ListStrGet(z, 2));
  PrintLn(IntToStr(ListStrLengthOf(z, 3)));
  ListStrFree(z);' '4
0
bc
0'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: ListStr* in std.list"
exit 0
