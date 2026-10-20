#!/usr/bin/env bash
# tests/ir_platzhalter_test.sh — #2141: stille Platzhalter auf dem IR-Weg
# (und einer auf x86).
#
# Bis 1.2.16A:
#   (1) ir_lower: NK_MAP_LIT, NK_SET_LIT und NK_IN_EXPR lieferten einen
#       UNBESCHRIEBENEN Temp — `{1: 100}` war ein Zufallszeiger, `x in a..b`
#       ein Zufallswert. `m[k]`, `m[k] := v`, `len(m)` und `var m: Map<..>;`
#       kannte der IR-Weg ueberhaupt nicht. `a ?? b` wertete IMMER beide
#       Seiten aus und lieferte immer a (null blieb null).
#   (2) x86: ein Feld, dessen Versatz sich nicht bestimmen laesst, lieferte
#       ausserhalb von Generika still 0, die Zuweisung entfiel (IR meldet es
#       seit #2134).
#   (3) panic(msg) endete auf arm64/riscv mit rc 1, aber OHNE Meldung.
#   (4) Print(f()) mit IMPORTIERTEM f: pchar scheiterte mit "kann den Typ
#       des Arguments nicht bestimmen".
#   (5) Print("ab\0cd") gab nur "ab" aus — das Literal ging mit Laenge -1
#       (zaehlen bis NUL) statt mit seiner bekannten Laenge hinaus; x86
#       ebenso (_lyx_print_str zaehlt).
#
# Gemessen werden WERTE und AUSGABEN (stdout, stderr und rc getrennt) auf
# x86_64, arm64 und riscv; sie muessen auf allen dreien gleich sein. Beim
# Ersatzwert von `??` zaehlt ein Seiteneffekt mit, ob der Ersatz ausgewertet
# wurde (der Weg, nicht nur das Ergebnis); beim Bereichstest die
# Reihenfolge. Gegenseiten: fehlender Schluessel fuegt nichts ein, ein
# pchar-Wert mit NUL bleibt beim Zaehlen, f64 ueber einen Import bleibt auf
# dem IR-Weg laut, das unaufloesbare Feld ist auf ALLEN Zielen laut, die
# aufloesbare Form rechnet.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if [ -z "$QEMU_ARM64" ] || [ -z "$QEMU_RISCV64" ]; then echo "FAIL qemu fuer arm64/riscv fehlt — NICHT gemessen"; exit 1; fi

lauf() {  # ziel, binary
  case "$1" in
    linux) timeout 30 "$2" ;;
    arm64) timeout 30 "$QEMU_ARM64" "$2" ;;
    riscv) timeout 30 "$QEMU_RISCV64" "$2" ;;
  esac
}

baue() {  # ziel, datei, ausgabe [verzeichnis]
  ( cd "${4:-$ROOT}" && timeout 240 "$LYXC" --std-path="$ROOT" --target=$1 "$2" -o "$3" ) >"$3.log" 2>&1
}

# pruefe name datei soll-stdout [soll-stderr] [soll-rc] [verzeichnis]
# NUL wird als @ und das Zeilenende als | sichtbar gemacht.
pruefe() {
  local sollErr="${4:-}" sollRc="${5:-0}" t
  for t in linux arm64 riscv; do
    rm -f "$TMP/p"
    if ! baue $t "$2" "$TMP/p" "${6:-}"; then
      nok "$1 [$t]: uebersetzt nicht ($(grep -m1 -iE 'error|kann den Typ|unbekannt' "$TMP/p.log"))"; continue
    fi
    lauf $t "$TMP/p" >"$TMP/so" 2>"$TMP/se"; local rc=$?
    local aus err
    aus="$(tr '\0\n' '@|' < "$TMP/so")"
    err="$(tr '\0\n' '@|' < "$TMP/se")"
    if [ "$aus" = "$3" ] && [ "$err" = "$sollErr" ] && [ "$rc" = "$sollRc" ]; then ok "$1 [$t]: [$aus] [$err] rc=$rc"
    else nok "$1 [$t]: [$aus] [$err] rc=$rc statt [$3] [$sollErr] rc=$sollRc"; fi
  done
}

# --- (1) Map<int64, V>: Literal, Lesen, Schreiben, len, in ---------------
cat > "$TMP/map.lyx" <<'EOF'
fn main(): int64 {
  var m: Map<int64, int64> := {1: 100, 2: 250};
  PrintInt(m[1]); Print(" "); PrintInt(m[2]); Print("\n");
  m[3] := 7;
  m[1] := 99;
  PrintInt(m[1]); Print(" "); PrintInt(m[3]); Print(" "); PrintInt(len(m)); Print("\n");
  // fehlender Schluessel: 0, und es kommt nichts hinzu
  PrintInt(m[42]); Print(" "); PrintInt(len(m)); Print("\n");
  if (2 in m) { Print("2 drin "); } else { Print("2 fehlt "); }
  if (9 in m) { Print("9 drin\n"); } else { Print("9 fehlt\n"); }
  var k: int64 := 3;
  m[k * 2] := 77;
  PrintInt(m[6]); Print("\n");
  return 0;
}
EOF
pruefe "Map: Literal/Lesen/Schreiben/len/in" "$TMP/map.lyx" "100 250|99 7 3|0 3|2 drin 9 fehlt|77|"

# Ohne Initialisierung, leeres Literal, Sondierung ueber kollidierende
# Schluessel (1, 17, 33 und 2, 18 teilen sich bei Kapazitaet 16 den Platz).
cat > "$TMP/map2.lyx" <<'EOF'
fn main(): int64 {
  var a: Map<int64, int64>;
  a[5] := 55;
  PrintInt(a[5]); Print(" "); PrintInt(len(a)); Print("\n");
  var b: Map<int64, int64> := {};
  b[3] := 33;
  if (3 in b) { Print("ja "); } else { Print("nein "); }
  PrintInt(b[3]); Print("\n");
  var c: Map<int64, int64> := {1: 10, 17: 20, 33: 30, 2: 40, 18: 50};
  PrintInt(c[1] + c[17] + c[33] + c[2] + c[18]); Print(" "); PrintInt(len(c)); Print(" ");
  PrintInt(c[49]); Print("\n");
  return 0;
}
EOF
pruefe "Map: ohne Init, leer, kollidierende Schluessel" "$TMP/map2.lyx" "55 1|ja 33|150 5 0|"

# Zeichenketten-Schluessel (#1291): verglichen wird der INHALT. Der zur
# Laufzeit gebaute Schluessel liegt an einer anderen Adresse als das Literal.
cat > "$TMP/mapstr.lyx" <<'EOF'
fn lies(m: Map<pchar, int64>): int64 { return m["Alpha"c]; }
fn main(): int64 {
  var m: Map<pchar, int64> := {"a"c: 1, "bb"c: 2};
  m["Alpha"c] := 42;
  m["a"c] := 9;
  var k: pchar := StrNew(8);
  StrSetChar(k, 0, 98); StrSetChar(k, 1, 98); StrSetChar(k, 2, 0);
  PrintInt(m["a"c]); Print(" "); PrintInt(m[k]); Print(" "); PrintInt(len(m)); Print(" ");
  PrintInt(lies(m)); Print(" "); PrintInt(m["b"c]); Print("\n");
  if (k in m) { Print("ja "); } else { Print("nein "); }
  if ("Gamma"c in m) { Print("ja\n"); } else { Print("nein\n"); }
  return 0;
}
EOF
pruefe "Map<pchar,V>: Inhaltsvergleich" "$TMP/mapstr.lyx" "9 2 3 42 0|ja nein|"

# Menge: jeder Wert ist 1; `in` auf dem Literal an Ort und Stelle.
cat > "$TMP/set.lyx" <<'EOF'
fn main(): int64 {
  var s: Map<int64, int64> := {3, 5, 7};
  PrintInt(s[5]); Print(" "); PrintInt(s[4]); Print(" "); PrintInt(len(s)); Print("\n");
  var x: int64 := 5;
  if (x in {3, 5, 7}) { Print("ja "); } else { Print("nein "); }
  if (6 in {3, 5, 7}) { Print("ja\n"); } else { Print("nein\n"); }
  return 0;
}
EOF
pruefe "Mengenliteral" "$TMP/set.lyx" "1 0 3|ja nein|"

# Bereichstest: Grenzen einschliesslich, negative Grenzen; die Reihenfolge der
# Auswertung (x, untere, obere Grenze) wird ueber Seiteneffekte gezeigt.
cat > "$TMP/in.lyx" <<'EOF'
fn f(n: int64, tag: pchar): int64 { PrintStr(tag); return n; }
fn main(): int64 {
  var i: int64 := 0;
  while (i <= 6) {
    if (i in 1..5) { Print("1"); } else { Print("0"); }
    i := i + 1;
  }
  Print(" ");
  var g: int64 := 0 - 3;
  if (g in (0 - 5)..(0 - 3)) { Print("1"); } else { Print("0"); }
  if (g in (0 - 2)..9) { Print("1"); } else { Print("0"); }
  Print(" ");
  if (f(3, "x") in f(1, "u")..f(5, "o")) { Print("!\n"); } else { Print("?\n"); }
  return 0;
}
EOF
pruefe "in: Bereich, negative Grenzen, Reihenfolge" "$TMP/in.lyx" "0111110 10 xuo!|"

# --- (1) ?? und as? ------------------------------------------------------
# Der Ersatz darf NUR ausgewertet werden, wenn die linke Seite null ist —
# der Zaehler zeigt es. Vorher: 'da 1 ...' bzw. null statt "ersatz".
cat > "$TMP/coal.lyx" <<'EOF'
var zaehler: int64 := 0;
fn ersatz(): pchar { zaehler := zaehler + 1; return "ersatz"; }
fn nix(): pchar { return null; }
fn main(): int64 {
  var a: pchar := "da" ?? ersatz();
  PrintStr(a); PrintStr(" "); PrintInt(zaehler); PrintStr(" ");
  var b: pchar := nix() ?? ersatz();
  PrintStr(b); PrintStr(" "); PrintInt(zaehler); PrintStr("\n");
  var n: int64 := 0 ?? 7;
  var n2: int64 := 5 ?? 7;
  var c: int64 := 41;
  var d: int64 := c as? int64;
  PrintInt(n); PrintStr(" "); PrintInt(n2); PrintStr(" "); PrintInt(d + 1); PrintStr("\n");
  return 0;
}
EOF
pruefe "??: Ersatz nur bei null, as? reicht durch" "$TMP/coal.lyx" "da 0 ersatz 1|7 5 42|"

# --- (3) panic: Meldung auf stderr, ohne Zeilenende, rc 1 ------------------
cat > "$TMP/panic.lyx" <<'EOF'
fn main(): int64 {
  Print("vorher\n");
  panic("kaputt hier");
  Print("nachher\n");
  return 0;
}
EOF
pruefe "panic(Literal)" "$TMP/panic.lyx" "vorher|" "kaputt hier" 1
cat > "$TMP/panic2.lyx" <<'EOF'
fn grund(n: int64): pchar { if (n > 0) { return "zu gross\n"; } return "ok"; }
fn main(): int64 {
  var m: pchar := grund(3);
  panic(m);
  return 0;
}
EOF
pruefe "panic(Variable)" "$TMP/panic2.lyx" "" "zu gross|" 1

# --- (4) Print(f()) mit importiertem f -------------------------------------
mkdir -p "$TMP/imp"
cat > "$TMP/imp/hilf.lyx" <<'EOF'
unit hilf;
pub fn Name(): pchar { return "hilf"; }
pub fn Zahl(): int64 { return 42; }
pub fn Wert(): f64 { return 1.5; }
EOF
cat > "$TMP/imp/main.lyx" <<'EOF'
import hilf;
fn main(): int64 {
  Print(Name());
  PrintLn(" ", Zahl(), " ", Name());
  return 0;
}
EOF
pruefe "Print(importierte Funktion)" main.lyx "hilf 42 hilf|" "" 0 "$TMP/imp"
# Woertlich aus der Meldung: eine stdlib-Funktion ueber den Import.
cat > "$TMP/imp2.lyx" <<'EOF'
import src.std.fs;
fn main(): int64 {
  Print(BaseName("/a/b/datei.txt"));
  PrintLn("|", BaseName("/x/y"));
  return 0;
}
EOF
pruefe "Print(BaseName(..)) aus src.std.fs" "$TMP/imp2.lyx" "datei.txt|y|"
# Gegenseite: ein importierter f64 bleibt auf dem IR-Weg unbestimmbar —
# laut, nicht als Ganzzahl geraten.
cat > "$TMP/imp/f64.lyx" <<'EOF'
import hilf;
fn main(): int64 { Print(Wert()); return 0; }
EOF
for t in arm64 riscv; do
  if baue $t f64.lyx "$TMP/f" "$TMP/imp"; then nok "Print(importierter f64) [$t]: uebersetzt"
  elif grep -q "kann den Typ des Arguments nicht bestimmen" "$TMP/f.log"; then ok "Print(importierter f64) [$t]: laut abgewiesen"
  else nok "Print(importierter f64) [$t]: $(head -c 200 "$TMP/f.log")"; fi
done

# --- (5) Print mit Literal: bekannte Laenge --------------------------------
cat > "$TMP/lit.lyx" <<'EOF'
fn main(): int64 {
  Print("ab\0cd");
  Print("\n");
  PrintLn("x\0y");
  Print("a", 5, "b\0c\n");
  // Gegenseite: ein pchar-WERT hat keine bekannte Laenge — er endet am NUL.
  var s: pchar := "pq\0rs";
  Print(s); Print("\n");
  return 0;
}
EOF
pruefe "Print(Literal mit \\0)" "$TMP/lit.lyx" "ab@cd|x@y|a5b@c|pq|"

# --- (2) Feld ohne bestimmbaren Typ: laut auf ALLEN Zielen -----------------
# Ausloeser wie in tests/generics_x86_typen_test.sh: `a[0].x` auf einem
# untypisierten `array`. x86 lieferte still 0 (Ausgabe 1), die Zuweisung
# entfiel.
cat > "$TMP/feld.lyx" <<'EOF'
type P = class {
  x: int64;
};
fn mk(): P { var p: P := new P(); p.x := 41; return p; }
fn main(): int64 {
  var a: array := [0, 0];
  var p: P := mk();
  a[0] := p as int64;
  PrintLn(StrFromInt(a[0].x + 1));
  return 0;
}
EOF
cat > "$TMP/feld_w.lyx" <<'EOF'
type P = class {
  x: int64;
};
fn main(): int64 {
  var a: array := [0, 0];
  var p: P := new P();
  a[0] := p as int64;
  a[0].x := 5;
  PrintLn(StrFromInt(p.x));
  return 0;
}
EOF
for f in feld feld_w; do
  for t in linux arm64 riscv; do
    if baue $t "$TMP/$f.lyx" "$TMP/f"; then
      nok "Feld ohne bestimmbaren Typ ($f) [$t]: uebersetzt ($(lauf $t "$TMP/f" 2>/dev/null | tr '\n' '|'))"
    elif grep -q "Feld nicht aufloesbar" "$TMP/f.log"; then ok "Feld ohne bestimmbaren Typ ($f) [$t]: laut abgewiesen"
    else nok "Feld ohne bestimmbaren Typ ($f) [$t]: $(head -c 200 "$TMP/f.log")"; fi
  done
done
cat > "$TMP/feld_ok.lyx" <<'EOF'
type P = class {
  x: int64;
};
fn mk(): P { var p: P := new P(); p.x := 41; return p; }
fn main(): int64 {
  var p: P := mk();
  p.x := p.x + 1;
  PrintLn(StrFromInt(mk().x + 1), " ", StrFromInt(p.x));
  return 0;
}
EOF
pruefe "Feld ueber bestimmbaren Typ (Gegenseite)" "$TMP/feld_ok.lyx" "42 42|"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
