#!/usr/bin/env bash
# tests/vektor_ausrichtung_2372_test.sh — der Vektorkern darf keine
# 16-Byte-Ausrichtung der Basis voraussetzen (#2372).
#
# Warum es diesen Test gibt:
#
# Der Kern in cg_emitSSE2BinOp/cg_emitVexGanzSchritt las und schrieb mit
# `movdqa`/`movaps`. Diese Befehle verlangen eine 16-Byte-Ausrichtung und
# loesen sonst #GP aus. Der Erkenner (cg_vmBasisVon) nimmt jeden Bezeichner
# mit Rahmenversatz als Basis — er kann nicht wissen, ob der Zeiger darin
# ausgerichtet ist, und prueft es auch nicht. Die Annahme hielt nur, solange
# die Basis in der Praxis ein ganzer Puffer aus `alloc()` war; ein daraus
# ABGELEITETER Zeiger (`var d: int64 := c + 1;`) liegt beliebig.
#
# Am Mergestand 9d7786a7 (ohne jede Aenderung) ergab der Fall unten fuer
# int8/int16/int32 jeweils rc 139 (SIGSEGV) und KEINE Ausgabe, mit Versatz 16
# dagegen rc 0 und das richtige Ergebnis. Dieser Test waere davor also rot
# gewesen — und zwar am WERT, nicht an der Uebersetzbarkeit.
#
# Gemessen wird deshalb dreierlei:
#   1. die Summe der Zielelemente (der Wert, nicht das Durchlaufen),
#   2. die NACHBARELEMENTE direkt vor und hinter dem Ziel: eine zu breite
#      Ablage traf in #2199 daneben und waere an der Summe unsichtbar,
#   3. n = 37, also KEIN Vielfaches der Vektorbreite — der Restweg laeuft mit.
#
# Die ausgerichtete Gegenprobe (Versatz 16) steht daneben, weil ein Test, der
# nur den unausgerichteten Fall prueft, auch von einem Kern erfuellt waere,
# der die Vektorisierung ganz abgeschaltet hat.
#
# Dazu die Gegenprobe am ERZEUGNIS: die vier Kerne duerfen die ausgerichteten
# Speicherformen nicht mehr enthalten. Der f32-Kern und der Negationskern sind
# ueber `parallel Array` nur mit Basen aus der Anlage erreichbar (die richtet
# auf 16 aus), ein Wertefall kann sie also nicht rot machen — die Bytepruefung
# belegt sie trotzdem.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# mach BREITE ELEMENTBYTES VERSATZ -> Programm auf stdout
mach() {
  local w="$1" bw="$2" off="$3" idx
  if [ "$bw" = "1" ]; then idx="i"; else idx="i * $bw"; fi
  cat <<LYX
import std.io;
fn main(): int64 {
  var n: int64 := 37;
  var a: int64 := alloc(4096);
  var b: int64 := alloc(4096);
  var c: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 4096) { poke8(a + i, 0); poke8(b + i, 0); poke8(c + i, 0); i := i + 1; }
  i := 0;
  while (i < n) { poke${w}(a + ${off} + ${idx}, i + 1); poke${w}(b + ${off} + ${idx}, 10); i := i + 1; }
  var da: int64 := a + ${off};
  var db: int64 := b + ${off};
  var dc: int64 := c + ${off};
  i := 0;
  while (i < n) { poke${w}(dc + ${idx}, peek${w}(da + ${idx}) + peek${w}(db + ${idx})); i := i + 1; }
  var summe: int64 := 0;
  i := 0;
  while (i < n) { summe := summe + peek${w}(dc + ${idx}); i := i + 1; }
  PrintStr("SUMME="c); PrintInt(summe); PrintStrLn(""c);
  PrintStr("VOR="c); PrintInt(peek8(c + ${off} - 1)); PrintStrLn(""c);
  PrintStr("NACH="c); PrintInt(peek8(c + ${off} + n * ${bw})); PrintStrLn(""c);
  return 0;
}
LYX
}

# Summe von (i+1)+10 fuer i = 0..36  =  703 + 370 = 1073
ERWARTET="SUMME=1073 VOR=0 NACH=0"

pruefe() {
  local name="$1" quelle="$2"
  printf "%s" "$quelle" > "$TMP/c.lyx"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c.x" >"$TMP/c.log" 2>&1); then
    echo "FAIL $name: uebersetzte nicht"; sed -n '1,3p' "$TMP/c.log"; FAIL=$((FAIL+1)); return
  fi
  local got rc
  got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/c.x" 2>/dev/null | tr '\n' ' ' ); rc=$?
  got="${got% }"
  if [ "$got" = "$ERWARTET" ]; then
    echo "PASS $name ($got)"; PASS=$((PASS+1))
  else
    echo "FAIL $name: '$got' (rc $rc) erwartet '$ERWARTET'"; FAIL=$((FAIL+1))
  fi
}

for paar in "8 1" "16 2" "32 4"; do
  set -- $paar
  w="$1"; bw="$2"
  # Der Fall, der vorher mit rc 139 starb.
  pruefe "int${w}_versatz1"  "$(mach "$w" "$bw" 1)"
  # Dieselbe Rechnung ausgerichtet — belegt, dass der Vektorweg noch greift.
  pruefe "int${w}_versatz16" "$(mach "$w" "$bw" 16)"
done

# --- Gegenprobe am Erzeugnis: keine ausgerichteten Speicherformen mehr ------
# Gelesen wird die QUELLE des Kerns, nicht ein Erzeugnis: die vier Kerne
# stehen als Bytefolgen im Codegen, und genau diese Folgen sind der Defekt.
# Ein Bytescan am uebersetzten Compiler waere nicht eindeutig, weil dieselben
# Bytes auch als Daten vorkommen (#2340).
CG="$ROOT/src/codegen_x86.lyx"
verbot() {
  local name="$1" muster="$2"
  if grep -qE "$muster" "$CG"; then
    echo "FAIL erzeugnis_$name: ausgerichtete Speicherform steht noch im Kern"
    grep -nE "$muster" "$CG" | sed -n '1,3p'
    FAIL=$((FAIL+1))
  else
    echo "PASS erzeugnis_$name"; PASS=$((PASS+1))
  fi
}
# 66 0F 6F/7F mit Speicher-ModRM (0x04/0x0C + SIB) — movdqa [reg+reg]
verbot "movdqa_speicher" 'cg_e8\(0x66\); self\.cg_e8\(0x0F\); self\.cg_e8\(0x[67]F\); self\.cg_e8\(0x(04|0C)\); self\.cg_e8\(0x0'
# 0F 28/29 mit Speicher-ModRM — movaps [reg+reg]
verbot "movaps_speicher" 'cg_e8\(0x0F\); self\.cg_e8\(0x2[89]\); self\.cg_e8\(0x(04|0C)\); self\.cg_e8\(0x0'
# VEX-Ganzzahlschritt: pp muss 2 (F3) sein, nicht 1 (0x66)
if grep -qE 'cg_vexOpRM\(0x[67]F, [0-9]+, 0, [0-9]+, 0, l, 1, 1, 0\)' "$CG"; then
  echo "FAIL erzeugnis_vmovdqa: VEX-Ladebefehl steht noch auf pp = 1 (0x66)"; FAIL=$((FAIL+1))
else
  echo "PASS erzeugnis_vmovdqa"; PASS=$((PASS+1))
fi
if [ "$(grep -cE 'cg_vexOpRM\(0x[67]F, [0-9]+, 0, [0-9]+, 0, l, 2, 1, 0\)' "$CG")" = "3" ]; then
  echo "PASS erzeugnis_vmovdqu_drei"; PASS=$((PASS+1))
else
  echo "FAIL erzeugnis_vmovdqu_drei: erwartet drei vmovdqu-Stellen im VEX-Ganzzahlschritt"; FAIL=$((FAIL+1))
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
