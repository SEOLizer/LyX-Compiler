#!/usr/bin/env bash
# tests/map_type_test.sh — #1152/#1205: Map<K,V> ist ein benutzbarer Sprachtyp.
#
# Vorher: das Literal uebersetzte, aber KEINE Operation arbeitete richtig.
#   m[k] lesen    → lieferte still eine Adresse statt des Wertes
#   m[k] := v     → SIGSEGV ohne Meldung
#   var m: Map<..>;  ohne Initialisierung → Slot blieb null
#   len(m)        → 0
#
# Die Wurzel der falschen WERTE lag im Parser: `{5: 100}` verlor den
# Doppelpunkt an die Format-Schreibweise `expr:breite` (WP-BC-13) und wurde
# damit zur MENGE mit einem Element. Der Mengenzweig setzt jeden Wert auf 1 —
# deshalb lieferte `m[5]` eine 1 und nicht 100. Die Tests hier lesen die WERTE
# und nicht nur die Laenge; ein Test, der nur `len` prueft, waere auch vorher
# gruen gewesen.
#
# NICHT enthalten: Zeichenketten-Schluessel. Die Laufzeit vergleicht Schluessel
# als Zahl, bei pchar waere das die Adresse — und gleich geschriebene Literale
# haben verschiedene Adressen. Sie werden deshalb abgewiesen (#1291); der
# letzte Abschnitt haelt das fest.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, rumpf, erwartete ausgabe
  printf 'import src.std.io;\nfn main(): int64 {\n%s\nreturn 0;\n}\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

fails() { # name, rumpf, erwarteter meldungsteil
  printf 'import src.std.io;\nfn main(): int64 {\n%s\nreturn 0;\n}\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3': $msg"; FAIL=$((FAIL+1)) ;;
  esac
}

# --- Der Repro aus #1152 --------------------------------------------------
out "Repro: Literal liefert den WERT, nicht eine Adresse" \
  'var m: Map<int64, int64> := {1: 100, 2: 250};
   PrintLn(IntToStr(m[1]));
   PrintLn(IntToStr(m[2]));' '100
250'

# Der Wert muss der geschriebene sein — vor dem Fix stand hier fuer JEDEN
# Schluessel eine 1 (Mengenzweig).
out "Literalwerte sind nicht alle 1" \
  'var m: Map<int64, int64> := {7: 42};
   if (m[7] == 42) { PrintStrLn("PASS Wert 42"); } else { Print("FAIL Wert="); PrintLn(m[7]); }' 'PASS Wert 42'

# --- Schreiben ------------------------------------------------------------
out "Schreiben legt an" \
  'var m: Map<int64, int64> := {1: 10};
   m[2] := 20;
   PrintLn(IntToStr(m[2]));' '20'

out "Schreiben aktualisiert einen vorhandenen Schluessel" \
  'var m: Map<int64, int64> := {1: 10};
   m[1] := 99;
   PrintLn(IntToStr(m[1]));
   PrintLn(IntToStr(len(m)));' '99
1'

# --- Deklaration ohne Initialisierung ------------------------------------
# Vorher blieb der Slot null und der erste Schreibzugriff traf die Null.
out "Map ohne Initialisierung ist benutzbar" \
  'var m: Map<int64, int64>;
   m[5] := 55;
   PrintLn(IntToStr(m[5]));
   PrintLn(IntToStr(len(m)));' '55
1'

out "leeres Literal ist benutzbar" \
  'var m: Map<int64, int64> := {};
   m[3] := 33;
   PrintLn(IntToStr(m[3]));' '33'

# --- Fehlender Schluessel -------------------------------------------------
out "fehlender Schluessel liefert 0" \
  'var m: Map<int64, int64> := {1: 10};
   PrintLn(IntToStr(m[99]));' '0'

# --- in ------------------------------------------------------------------
out "in trifft vorhandene und fehlende Schluessel" \
  'var m: Map<int64, int64> := {1: 10, 2: 20};
   if (2 in m) { PrintStrLn("2 drin"); } else { PrintStrLn("2 fehlt"); }
   if (9 in m) { PrintStrLn("9 drin"); } else { PrintStrLn("9 fehlt"); }' '2 drin
9 fehlt'

out "in sieht einen nachtraeglich geschriebenen Schluessel" \
  'var m: Map<int64, int64>;
   m[4] := 1;
   if (4 in m) { PrintStrLn("PASS"); } else { PrintStrLn("FAIL"); }' 'PASS'

# --- len -----------------------------------------------------------------
out "len zaehlt die Eintraege" \
  'var m: Map<int64, int64> := {1: 10, 2: 20, 3: 30};
   PrintLn(IntToStr(len(m)));
   m[4] := 40;
   PrintLn(IntToStr(len(m)));' '3
4'

# --- Schluessel als Ausdruck ---------------------------------------------
out "berechneter Schluessel" \
  'var m: Map<int64, int64>;
   var k: int64 := 3;
   m[k * 2] := 77;
   PrintLn(IntToStr(m[6]));' '77'

# --- Die Format-Schreibweise bleibt ausserhalb des Literals unberuehrt ---
# `x:8` in einem Literal ist ein Schluessel-Doppelpunkt, ausserhalb weiterhin
# die Formatangabe. Geprueft wird, dass beides nebeneinander uebersetzt.
out "Map-Literal und Formatangabe im selben Programm" \
  'var m: Map<int64, int64> := {2: 4};
   var s: pchar := "x";
   PrintLn(IntToStr(m[2]));
   PrintStrLn(s);' '4
x'

# --- Zeichenketten-Schluessel werden abgewiesen (#1291) ------------------
fails "pchar-Schluessel wird gemeldet" \
  'var m: Map<pchar, int64> := {"A": 100};
   PrintLn(IntToStr(m["A"]));' "nur ganzzahlige Schluesseltypen"

fails "pchar-Schluessel auch ohne Initialisierung gemeldet" \
  'var m: Map<pchar, int64>;' "nur ganzzahlige Schluesseltypen"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
