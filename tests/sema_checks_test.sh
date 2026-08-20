#!/usr/bin/env bash
# tests/sema_checks_test.sh — #1264, #1238, #1237, #1261, #1295.
#
# Fünf Prüfungen, die fail-open waren: sie urteilten nur über das, was in
# DERSELBEN Datei stand, und schwiegen zu allem anderen.
#
# #1264: Stelligkeit und Typen wurden nur bei freien Funktionen der eigenen
# Datei geprüft. `Add(1)` auf eine importierte Funktion mit zwei Parametern
# übersetzte klaglos — der fehlende Wert kam vom Stack. Methoden waren
# unabhängig von der Unit-Grenze ungeprüft.
#
# #1238: Struct- und Klassenwerte in int64-Zielen (und umgekehrt) wurden nicht
# gemeldet, weil TY_USER keiner Typklasse zugeordnet war.
#
# #1237: Die `unit`-Zeile war Dekoration — der Import löst über den Dateipfad
# auf, und niemand verglich den deklarierten Namen damit.
#
# #1261: Eine geschachtelte Funktion nahm kein Attribut an; `@stack_limit(64)`
# ergab dort `undefined function 'stack_limit'`.
#
# #1295: Die Dimensionsprüfung von dim/utype endete an der Unit-Grenze — eine
# Länge liess sich einer Zeit zuweisen, also genau das, wogegen Einheitentypen
# antreten.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Hilfsmodule für die Unit-Grenze
mkdir -p "$TMP/mm" "$TMP/uu"
cat > "$TMP/mm/lib.lyx" <<'EOF'
unit mm.lib;
pub fn Add(a: int64, b: int64): int64 { return a + b; }
pub fn WithDefault(a: int64, b: int64 = 5): int64 { return a - b; }
EOF
cat > "$TMP/mm/units.lyx" <<'EOF'
unit mm.units;
pub dim Laenge;
pub dim Zeit;
pub utype Meter:   Laenge = 1.0;
pub utype Sekunde: Zeit   = 1.0;
EOF

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 30 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

rejects() { # name, quelltext, erwartetes Textstueck
  printf '%s\n' "$2" > "$TMP/r.lyx"; rm -f "$TMP/r"
  msg="$("$LYXC" --std-path="$ROOT" -I "$TMP" "$TMP/r.lyx" -o "$TMP/r" 2>&1)"
  if [ -f "$TMP/r" ]; then no "$1" "uebersetzt, statt zu melden"; return; fi
  case "$msg" in *"$3"*) ok "$1" ;; *) no "$1" "Meldung nennt '$3' nicht: $msg" ;; esac
}

# ===========================================================================
# #1264 — Stelligkeit über die Unit-Grenze und bei Methoden
# ===========================================================================

rejects "importierte Funktion: zu wenige Argumente" 'import std.io;
import mm.lib;
fn main(): int64 { PrintLn(IntToStr(Add(1))); return 0; }' "falsche Argument-Anzahl"

rejects "importierte Funktion: zu viele Argumente" 'import std.io;
import mm.lib;
fn main(): int64 { PrintLn(IntToStr(Add(1, 2, 3))); return 0; }' "falsche Argument-Anzahl"

out "importierte Funktion: richtige Anzahl bleibt gueltig" 'import std.io;
import mm.lib;
fn main(): int64 { PrintLn(IntToStr(Add(1, 2))); return 0; }' "3"

# #1342: Vorgabewerte einer IMPORTIERTEN Funktion werden jetzt eingesetzt. Der
# Codegen findet die Deklaration zwar weiterhin nur in der eigenen Modulkette,
# schreibt aber beim Einlesen der Unit die KONSTANTEN Vorgaben ab und setzt
# sie am Aufrufpunkt ein. Vorher stand hier ein `rejects` — davor druckte der
# Aufruf -140735687454702, also einen Wert vom Stack.
out "ausgelassener Vorgabewert einer importierten Funktion wird eingesetzt" 'import std.io;
import mm.lib;
fn main(): int64 { PrintLn(IntToStr(WithDefault(10))); return 0; }' "5"

out "vollstaendig angegeben rechnet richtig" 'import std.io;
import mm.lib;
fn main(): int64 { PrintLn(IntToStr(WithDefault(10, 5))); return 0; }' "5"

rejects "Methode: zu wenige Argumente" 'import std.io;
type C = class { fn M(a: int64, b: int64): int64 { return a + b; } };
fn main(): int64 {
  var c: C := new C();
  PrintLn(IntToStr(c.M(1)));
  return 0;
}' "Methodenaufruf"

out "Methode: richtige Anzahl bleibt gueltig" 'import std.io;
type C = class { fn M(a: int64, b: int64): int64 { return a + b; } };
fn main(): int64 {
  var c: C := new C();
  PrintLn(IntToStr(c.M(1, 2)));
  return 0;
}' "3"

# ===========================================================================
# #1238 — Struct/Klasse gegen int64
# ===========================================================================

rejects "Struct in int64-Ziel wird gemeldet" 'import std.io;
type S = struct { v: int64; };
fn main(): int64 { var s: S; var x: int64 := s; return 0; }' "Struct/Klasse gegeben"

rejects "int64 in Struct-Ziel wird gemeldet" 'import std.io;
type S = struct { v: int64; };
fn main(): int64 { var x: int64 := 5; var s: S := x; return 0; }' "Struct/Klasse erwartet"

# Die 97 Fundstellen aus dem Bericht waren zum groessten Teil ALIASE: ein
# `type date = int64` galt als zusammengesetzter Typ. Diese Gegenprobe haelt
# fest, dass ein Alias sein Grundtyp IST — ohne sie waere die Pruefung
# unbrauchbar.
out "Typalias ist sein Grundtyp" 'import std.io;
type dd = int64;
fn F(): dd { var x: int64 := 5; return x; }
fn main(): int64 { var y: int64 := F(); PrintLn(IntToStr(y)); return 0; }' "5"

out "Alias-Kette bleibt zuweisbar" 'import std.io;
type meine_zeit = int64;
fn G(t: meine_zeit): int64 { return t * 2; }
fn main(): int64 { var t: meine_zeit := 21; PrintLn(IntToStr(G(t))); return 0; }' "42"

# ===========================================================================
# #1237 — unit-Name gegen Importpfad
# ===========================================================================

cat > "$TMP/uu/falsch.lyx" <<'EOF'
unit voellig.anderer.name;
pub fn QF(): int64 { return 3; }
EOF
cat > "$TMP/uu/richtig.lyx" <<'EOF'
unit uu.richtig;
pub fn QR(): int64 { return 7; }
EOF
cat > "$TMP/uu/ohnezeile.lyx" <<'EOF'
pub fn QO(): int64 { return 9; }
EOF

rejects "abweichender unit-Name wird gemeldet" 'import uu.falsch;
fn main(): int64 { return QF(); }' "unit-Name stimmt nicht mit dem Importpfad"

out "passender unit-Name uebersetzt" 'import std.io;
import uu.richtig;
fn main(): int64 { PrintLn(IntToStr(QR())); return 0; }' "7"

# 139 der 530 Dateien im Bestand haben gar keine unit-Zeile. Sie zur Pflicht zu
# machen waere eine Sprachaenderung — hier steht der Beleg, dass es bei der
# NAMENSpruefung bleibt.
out "fehlende unit-Zeile bleibt zulaessig" 'import std.io;
import uu.ohnezeile;
fn main(): int64 { PrintLn(IntToStr(QO())); return 0; }' "9"

# ===========================================================================
# #1261 — Attribute an geschachtelten Funktionen
# ===========================================================================

out "Attribut an geschachtelter fn wird angenommen" 'import std.io;
fn Aussen(): int64 {
  @stack_limit(4096)
  fn Innen(): int64 { return 7; }
  return Innen();
}
fn main(): int64 { PrintLn(IntToStr(Aussen())); return 0; }' "7"

rejects "@stack_limit greift dort auch" 'import std.io;
fn Aussen(): int64 {
  @stack_limit(8)
  fn Innen(): int64 { var a: int64 := 1; var b: int64 := 2; var c: int64 := 3; var d: int64 := 4; return a+b+c+d; }
  return Innen();
}
fn main(): int64 { PrintLn(IntToStr(Aussen())); return 0; }' "stack_limit"

# Der Aufrufgraph schrieb Aufrufe "der zuletzt davorstehenden fn" zu. Der
# Knoten einer geschachtelten Funktion entsteht MITTEN im Rumpf der aeusseren,
# also vor dem Aufruf — die Kante zeigte auf sie selbst, und @wcet meldete an
# einer schleifenfoermigen Funktion "ist rekursiv". Geprueft wird deshalb die
# BEGRUENDUNG, nicht nur der Fehlschlag.
printf 'import std.io;\nfn Aussen(): int64 {\n  @wcet(3)\n  fn Innen(): int64 { var s: int64 := 0; for i := 1 to 10 { s := s + 1; } return s; }\n  return Innen();\n}\nfn main(): int64 { PrintLn(IntToStr(Aussen())); return 0; }\n' > "$TMP/w.lyx"
rm -f "$TMP/w"
wmsg="$("$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" 2>&1)"
if [ -f "$TMP/w" ]; then no "@wcet an geschachtelter fn" "Ueberschreitung nicht gemeldet"
elif echo "$wmsg" | grep -q "rekursiv"; then no "@wcet an geschachtelter fn" "als rekursiv gemeldet (Aufrufgraph-Fehler)"
elif echo "$wmsg" | grep -q "10 Iterationen"; then ok "@wcet an geschachtelter fn nennt die richtige Begruendung"
else no "@wcet an geschachtelter fn" "unerwartete Meldung: $wmsg"; fi

rejects "unbekanntes Attribut dort wird gemeldet" 'import std.io;
fn Aussen(): int64 {
  @tippfehler(3)
  fn Innen(): int64 { return 7; }
  return Innen();
}
fn main(): int64 { PrintLn(IntToStr(Aussen())); return 0; }' "unbekanntes Attribut"

# ===========================================================================
# #1295 — Dimensionen über die Unit-Grenze
# ===========================================================================

rejects "importierte Einheiten: Dimensionswechsel wird gemeldet" 'import mm.units;
fn main(): int64 { var m: Meter := 5; var s: Sekunde := m; return s as int64; }' "Dimensionsgrenzen"

out "importierte Einheiten: gleiche Dimension bleibt gueltig" 'import std.io;
import mm.units;
fn main(): int64 { var m: Meter := 5; var m2: Meter := m; PrintLn(IntToStr(m2 as int64)); return 0; }' "5"

rejects "std.units: Grad an Sekunden wird gemeldet" 'import std.units;
fn main(): int64 { var w: deg := 90; var d: s := w; return d as int64; }' "Dimensionsgrenzen"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
