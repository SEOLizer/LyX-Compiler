#!/usr/bin/env bash
# tests/kurzsprung_test.sh — #1915: ein Kurzsprung darf nicht still ueberlaufen.
#
# `push` auf ein Array erzeugt einen Wachstumspfad von rund 127 Byte, den ein
# Sprung ueberspringt. War es ein KURZSPRUNG (rel8), reichte er genau bis zur
# fuenfzehnten vorangehenden lokalen Variablen: ab der sechzehnten liegt das
# Array jenseits von rbp-128, `cg_storeRax` braucht drei Byte mehr, und die
# Distanz kippte auf 130. `poke8` schnitt sie auf ein Byte, die CPU las -126 —
# der Sprung ging RUECKWAERTS in den Pfad, den er ueberspringen sollte.
#
# Am Erzeugnis nachgemessen: 14 Locals davor -> rel8 = 127 (die Grenze exakt
# ausgereizt), 16 Locals -> 130. Der Fehler war von aussen unsichtbar: dasselbe
# Programm mit einer Variablen weniger uebersetzte tadellos.
#
# Der Test misst die WIRKUNG ueber den Kipppunkt hinweg und zaehlt dabei die
# Locals hoch. Eine einzelne Groesse waere zu wenig — genau die Nachbarschaft
# der Grenze ist der Fall.
#
# ALLE Laeufe stehen unter `ulimit -v`: ein Sprung ins Leere kann in eine
# unbegrenzte Speicherbelegung laufen, und ohne Deckel sucht sich der
# OOM-Killer den groessten Verbraucher im System — nicht den Schuldigen.
#
# Der Deckel stand zuerst auf 256 MB und war damit FLACKERND: auf dem
# CI-Runner scheiterten dieselben Faelle mal mit rc=139, mal gar nicht — ein
# Wiederholungslauf desselben Commits war gruen (11 PASS, 0 FAIL), lokal war
# der Test nie rot. Ein Deckel, der knapp ueber dem legitimen Bedarf liegt,
# misst die Maschine mit, nicht den Compiler. 1 GB liegt weit ueber allem, was
# ein korrektes Programm hier braucht, und weit unter dem, was einen fremden
# Prozess gefaehrdet — der Zweck des Deckels bleibt erhalten.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

bau() { # anzahl-locals
  { echo "unit main;"; echo "import std.io;"; echo "fn main(): int64 {"
    i=0; while [ "$i" -lt "$1" ]; do echo "  var vv$i: int64 := $i;"; i=$((i+1)); done
    echo "  var a: Array<int64>;"
    echo "  var i: int64 := 0;"
    echo "  while (i < 1030) { push(a, i); i := i + 1; }"
    echo "  PrintLn(IntToStr(len(a)));"
    echo "  return 0;"
    echo "}"; } > "$TMP/k.lyx"
  "$LYXC" --std-path="$ROOT" "$TMP/k.lyx" -o "$TMP/k" >/dev/null 2>&1
}

# Ueber den Kipppunkt hinweg. 15/16 ist die Grenze, 40 liegt weit dahinter.
for n in 0 8 14 15 16 17 24 40; do
  if ! bau "$n"; then no "$n Locals: uebersetzt" "Uebersetzung schlug fehl"; continue; fi
  got="$( ulimit -v 1048576; timeout 20 "$TMP/k" 2>/dev/null )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    no "$n Locals davor: push waechst korrekt" "rc=$rc (139 = Speicherzugriffsfehler)"
  elif [ "$got" != "1030" ]; then
    no "$n Locals davor: push waechst korrekt" "Laenge $got statt 1030"
  else
    ok "$n Locals davor: push waechst korrekt"
  fi
done

# Der Sprung im Erzeugnis MUSS lang sein. Ohne diese Pruefung waere der Test
# auch von einem Kurzsprung erfuellt, der gerade noch passt — und der naechste
# hinzugefuegte Befehl im Wachstumspfad braechte den Fehler zurueck.
bau 4
if command -v objdump >/dev/null 2>&1; then
  # 48 39 C2 = cmp rdx,rax (len gegen cap), danach der Sprung.
  kurz=$(objdump -d -z "$TMP/k" 2>/dev/null | grep -c "48 39 c2.*7c" || true)
  if python3 - "$TMP/k" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
kurz = d.count(bytes([0x48,0x39,0xC2,0x7C]))
lang = d.count(bytes([0x48,0x39,0xC2,0x0F,0x8C]))
print(f"  Kurzspruenge nach cmp rdx,rax: {kurz}, Langspruenge: {lang}")
sys.exit(0 if kurz == 0 and lang > 0 else 1)
PY
  then ok "der Wachstumssprung ist ein LANGER Sprung (rel32)"
  else no "der Wachstumssprung ist ein LANGER Sprung" "es steht noch ein Kurzsprung da"; fi
else
  echo "UEBERSPRUNGEN Sprungart: objdump fehlt"
fi

# Und der Waechter selbst: er steht im Codegen und faengt kuenftige
# Ueberlaeufe an JEDER der Stellen ab, nicht nur an dieser einen.
if grep -q "fn cg_patchRel8" "$ROOT/src/codegen_x86.lyx"; then
  n=$(grep -c "cg_patchRel8" "$ROOT/src/codegen_x86.lyx")
  ok "Waechter cg_patchRel8 ist eingezogen ($n Stellen)"
else
  no "Waechter cg_patchRel8 ist eingezogen" "fehlt"
fi
# Kein roher Sprungpatch mehr — sonst waere der Waechter luecken haft.
roh=$(grep "poke8(self.code + " "$ROOT/src/codegen_x86.lyx" | grep -vc "cg_patchRel8" || true)
if [ "$roh" -le 1 ]; then
  ok "kein roher Sprungpatch mehr (nur der Byte-Emitter)"
else
  no "kein roher Sprungpatch mehr" "$roh Stellen umgehen den Waechter"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
