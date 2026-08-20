#!/usr/bin/env bash
# tests/ref_parameter_test.sh — #1528 (Rest von #1351).
#
# Struct-Parameter wurden nach REFERENZ übergeben: `fn bump(p: Pt)` änderte das
# Original des Aufrufers. Die Zuweisung kopierte seit #1351, die Übergabe nicht
# — dieselbe Sprache, zwei Bedeutungen für dasselbe Struct.
#
# Eine Kopie beim Eintritt allein hätte den Bestand still gebrochen: 51
# Funktionen in 19 stdlib-Einheiten ändern ihren Struct-Parameter mit ABSICHT
# und geben ihr Ergebnis so zurück. Deshalb erst das Sprachmittel, dann die
# Semantik: `ref` sagt „nach Referenz", alles andere ist ein Wert.
#
# GEPRÜFT WIRD BEIDES ZUSAMMEN. Ein Test nur auf Wertsemantik wäre grün, wenn
# `ref` versehentlich auch kopierte — und dann wäre die halbe stdlib
# wirkungslos, ohne dass es jemand merkt. Deshalb steht neben jedem Wertfall
# der ref-Fall, und am Ende die stdlib selbst.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht"; return
  fi
  got="$(timeout 20 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ rc=$rc"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

meldet() { # name, quelltext, textstueck
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$(timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then no "$1" "uebersetzt klaglos"; return; fi
  if echo "$msg" | grep -qF "$3"; then ok "$1"; else no "$1" "andere Meldung: $(echo "$msg"|grep -i error|head -1)"; fi
}

# ===========================================================================
# Der Fall aus der Meldung
# ===========================================================================

out "#1528: Repro aus der Meldung" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn bump(p: Pt): int64 { p.x := 999; return 0; }
fn main(): int64 {
  var a: Pt; a.x := 1;
  bump(a);
  PrintLn(IntToStr(a.x));
  return 0;
}' "1"

# Die Kopie muss den INHALT tragen, nicht nur eine leere Flaeche: die Funktion
# liest den uebergebenen Wert, aendert ihn, und der Aufrufer sieht das Original.
out "#1528: der Wert kommt an, die Aenderung bleibt drinnen" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn summe(p: Pt): int64 {
  var s: int64 := p.x + p.y;
  p.x := 0; p.y := 0;
  return s;
}
fn main(): int64 {
  var a: Pt; a.x := 3; a.y := 4;
  var s: int64 := summe(a);
  PrintStr(IntToStr(s)); PrintStr(" ");
  PrintStr(IntToStr(a.x)); PrintStr(" "); PrintLn(IntToStr(a.y));
  return 0;
}' "7 3 4"

# ref: dieselbe Funktion, ein Wort mehr, umgekehrtes Verhalten.
out "#1528: ref aendert das Original" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn bump(ref p: Pt): int64 { p.x := 999; return 0; }
fn main(): int64 {
  var a: Pt; a.x := 1;
  bump(a);
  PrintLn(IntToStr(a.x));
  return 0;
}' "999"

# Mehrere Parameter: die Kopie darf die anderen Argumente nicht zerstoeren.
# Genau daran scheiterte der erste Versuch (#1351) — `rep movsq` zwischen den
# Spills ueberschrieb rdi/rsi/rcx, und das zweite Argument war weg.
out "#1528: Kopie zerstoert die anderen Argumente nicht" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn misch(a: Pt, n: int64, b: Pt, m: int64, c: Pt, k: int64): int64 {
  a.x := 0; b.x := 0; c.x := 0;
  return n + m + k;
}
fn main(): int64 {
  var p: Pt; p.x := 1; p.y := 1;
  var q: Pt; q.x := 2; q.y := 2;
  var r: Pt; r.x := 3; r.y := 3;
  PrintStr(IntToStr(misch(p, 10, q, 20, r, 30))); PrintStr(" ");
  PrintStr(IntToStr(p.x)); PrintStr(IntToStr(q.x)); PrintLn(IntToStr(r.x));
  return 0;
}' "60 123"

# Gemischt: ein Wert- und ein ref-Parameter in derselben Signatur.
out "#1528: Wert und ref nebeneinander" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn beides(w: Pt, ref r: Pt): int64 {
  w.x := 99;
  r.x := 99;
  return 0;
}
fn main(): int64 {
  var a: Pt; a.x := 1;
  var b: Pt; b.x := 1;
  beides(a, b);
  PrintStr(IntToStr(a.x)); PrintStr(" "); PrintLn(IntToStr(b.x));
  return 0;
}' "1 99"

# Der siebte Parameter liegt auf dem Stack, nicht im Register — die Kopie muss
# auch dort greifen.
out "#1528: Wertsemantik auch beim Stack-Parameter" 'import std.io;
type Pt = struct { x: int64; y: int64; };
fn viele(a: int64, b: int64, c: int64, d: int64, e: int64, f: int64, p: Pt): int64 {
  p.x := 999;
  return a + f;
}
fn main(): int64 {
  var s: Pt; s.x := 7;
  var r: int64 := viele(1, 2, 3, 4, 5, 6, s);
  PrintStr(IntToStr(r)); PrintStr(" "); PrintLn(IntToStr(s.x));
  return 0;
}' "7 7"

# ===========================================================================
# Was NICHT kopiert werden darf
# ===========================================================================

# Klassen bleiben Referenzen — `new` gibt sie aus, geteilt wird mit Absicht.
out "#1528: Klasse bleibt Referenz" 'import std.io;
type K = class {
  v: int64;
  fn Hol(): int64 { return self.v; }
};
fn setz(k: K): int64 { k.v := 42; return 0; }
fn main(): int64 {
  var k: K := new K();
  k.v := 1;
  setz(k);
  PrintLn(IntToStr(k.v));
  return 0;
}' "42"

# Ein int64 ist ohnehin ein Wert; hier darf sich nichts geaendert haben.
out "#1528: skalare Parameter unveraendert" 'import std.io;
fn zaehl(n: int64): int64 { n := n + 1; return n; }
fn main(): int64 {
  var a: int64 := 5;
  PrintStr(IntToStr(zaehl(a))); PrintStr(" "); PrintLn(IntToStr(a));
  return 0;
}' "6 5"

# ref an etwas, das gar nicht kopiert wird, ist eine Zusage ohne Wirkung.
meldet "#1528: ref an int64 wird gemeldet" 'import std.io;
fn f(ref n: int64): int64 { return n; }
fn main(): int64 { var a: int64 := 1; PrintLn(IntToStr(f(a))); return 0; }' \
  "ref ist nur bei Struct-Parametern wirksam"

# `ref` ist ein WEICHES Schluesselwort: als gewoehnlicher Name muss es
# weiterhin gehen, sonst braeche jeder Bestand, der so eine Variable fuehrt.
out "#1528: ref bleibt als Bezeichner nutzbar" 'import std.io;
fn f(ref2: int64): int64 { return ref2; }
fn main(): int64 {
  var ref: int64 := 5;
  ref := ref + 1;
  PrintStr(IntToStr(ref)); PrintStr(" "); PrintLn(IntToStr(f(ref)));
  return 0;
}' "6 6"

# ===========================================================================
# Die stdlib — der eigentliche Grund für ref
# ===========================================================================

# TTerminal ist einer der 51 Faelle: TerminalPutChar aendert den Zustand des
# uebergebenen Terminals. Ohne ref waere der Aufruf wirkungslos gewesen — und
# zwar still.
#
# TerminalPutChar schreibt dabei Steuerzeichen auf stdout; gemessen wird
# deshalb nur der markierte Teil, nicht die ganze Ausgabe.
cat > "$TMP/t.lyx" <<'LYXEOF'
import std.io;
import std.lyxvision.terminal;
fn main(): int64 {
  var t: TTerminal := TerminalCreate(0, 0, 80, 25);
  var vorher: int64 := t.cursorX;
  TerminalPutChar(t, 65);
  PrintStr("ERG:"); PrintStr(IntToStr(vorher)); PrintStr(" "); PrintLn(IntToStr(t.cursorX));
  return 0;
}
LYXEOF
if timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >/dev/null 2>&1; then
  erg="$(timeout 20 "$TMP/t" 2>/dev/null | tr -d '\033' | grep -o 'ERG:.*')"
  [ "$erg" = "ERG:0 1" ] \
    && ok "#1528: std.lyxvision.terminal behaelt seine Wirkung" \
    || no "#1528: std.lyxvision.terminal behaelt seine Wirkung" "'$erg' erwartet 'ERG:0 1'"
else
  no "#1528: std.lyxvision.terminal behaelt seine Wirkung" "uebersetzt nicht"
fi

# Und die Gegenprobe an derselben Unit: ein Struct, das NICHT als ref
# uebergeben wird, bleibt beim Aufrufer unveraendert.
out "#1528: eigenes Struct in derselben Datei bleibt Wert" 'import std.io;
import std.lyxvision.terminal;
type Zaehler = struct { n: int64; };
fn hoch(z: Zaehler): int64 { z.n := z.n + 1; return z.n; }
fn main(): int64 {
  var z: Zaehler; z.n := 0;
  var r: int64 := hoch(z);
  PrintStr(IntToStr(r)); PrintStr(" "); PrintLn(IntToStr(z.n));
  return 0;
}' "1 0"

# ===========================================================================
# Der Bestand: keine weitere Stelle darf still wirkungslos geworden sein
# ===========================================================================

# Die 51 Stellen wurden GEMESSEN, nicht geraten: jede stdlib-Funktion, die
# einen Struct-Parameter schreibt, muss ihn als ref fuehren. Diese Pruefung
# sucht dieselbe Form erneut — findet sie eine Stelle ohne ref, ist dort eine
# Funktion still wirkungslos geworden.
FEHLT="$(python3 - "$ROOT" <<'PYEOF'
import re,glob,os,sys
root=sys.argv[1]
structs=set()
for f in glob.glob(os.path.join(root,'std/**/*.lyx'),recursive=True):
    src=open(f,encoding='utf-8',errors='replace').read()
    structs.update(m.group(1) for m in re.finditer(r'type\s+(\w+)\s*=\s*(?:packed\s+|flat\s+)?struct\b', src))
    structs.update(m.group(1) for m in re.finditer(r'^\s*struct\s+(\w+)\s*\{', src, re.M))
fehlt=[]
for f in sorted(glob.glob(os.path.join(root,'std/**/*.lyx'),recursive=True)):
    lines=open(f,encoding='utf-8',errors='replace').read().split('\n')
    for i,l in enumerate(lines):
        m=re.match(r'\s*(?:pub |public )?fn\s+(\w+)\s*\(([^)]*)\)', l)
        if not m: continue
        wert=[]
        for prm in m.group(2).split(','):
            pm=re.match(r'\s*(?:con\s+)?(ref\s+)?(\w+)\s*:\s*(\w+)', prm)
            if pm and pm.group(3) in structs and not pm.group(1):
                wert.append(pm.group(2))
        if not wert: continue
        j=i+1; body=[]
        while j<len(lines) and not re.match(r'\s*(?:pub |public )?fn\s+\w+\s*\(', lines[j]):
            body.append(lines[j]); j+=1
        b='\n'.join(body)
        for p in wert:
            if re.search(r'\b'+re.escape(p)+r'\.\w+\s*:=', b):
                fehlt.append(f"{os.path.relpath(f,root)}:{i+1} {m.group(1)}({p})")
print('\n'.join(fehlt))
PYEOF
)"
if [ -z "$FEHLT" ]; then
  ok "#1528: keine stdlib-Funktion schreibt einen Wert-Parameter"
else
  no "#1528: keine stdlib-Funktion schreibt einen Wert-Parameter" "$(echo "$FEHLT" | head -5 | tr '\n' ' ')"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
