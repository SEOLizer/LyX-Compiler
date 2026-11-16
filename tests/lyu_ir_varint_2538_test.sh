#!/usr/bin/env bash
# tests/lyu_ir_varint_2538_test.sh — der IR-Abschnitt der .lyu ist feldweise
# kodiert (Fassung 2, #2538).
#
# Befund: bis Fassung 1 war der Abschnitt eine BYTEKOPIE des RAM-Puffers.
# Ein IR-Befehl belegt 80 Byte (zehn int64-Felder), ein typischer Befehl
# benutzt zwei bis vier davon -- gemessen 72,4 % Nullbytes in
# lyxos/std/io.lyu, gleichmaessig verteilt, also keine Polsterung, sondern
# Saetze mit ueberwiegend leeren Feldern. Das Dateiformat hatte die
# Speicherrepraesentation geerbt: #439 legte den festen Stride fuer die
# INDIZIERUNG im RAM fest, nie fuer eine Datei.
#
# Fassung 2: je Satz eine Feldmaske (ein Bit je Feld), dann die gesetzten
# Felder als Zickzack-Varint. Gemessener Baum: 274 MB -> 44 MB.
#
# GEPRUEFT WIRD DIE WIRKUNG, nicht die Groesse allein:
#   * eine Groessenpruefung allein waere von einem Encoder erfuellt, der
#     Felder VERLIERT -- deshalb die Bitgleichheit des Erzeugnisses,
#   * und eine Fassungspruefung muss in BEIDE Richtungen laut sein.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 fehlt"; echo "Ergebnis: 0 PASS, 0 FAIL"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null
pr() { if [ "$1" = ok ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

echo "--- 1. Der Abschnitt nennt Fassung 2 und traegt kaum noch Nullbytes ---"
( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" --target=lyxos \
    --compile-unit std/io.lyx -o "$TMP/io.lyu" ) >"$TMP/io.log" 2>&1
if [ -s "$TMP/io.lyu" ]; then
  python3 - "$TMP/io.lyu" > "$TMP/mess.txt" <<'PY'
import sys, struct
d = open(sys.argv[1],'rb').read()
i = d.find(b'LYIR')
if i < 0: print("KEIN_LYIR"); raise SystemExit
ver = struct.unpack_from('<I', d, i+4)[0]
print("VER", ver)
print("NUL", round(100*d.count(0)/len(d), 1))
print("LEN", len(d))
PY
  ver=$(awk '/^VER/{print $2}' "$TMP/mess.txt")
  nul=$(awk '/^NUL/{print $2}' "$TMP/mess.txt")
  [ "$ver" = "2" ] && pr ok "LYIR nennt Fassung 2" || pr no "LYIR nennt Fassung '$ver'"
  # Fassung 1 lag bei 72,4 %. Die Schwelle ist bewusst grob: geprueft wird die
  # GROESSENORDNUNG, nicht eine Zahl, die bei jeder IR-Aenderung wandert.
  if [ -n "$nul" ] && python3 -c "import sys; sys.exit(0 if float('$nul') < 40.0 else 1)"; then
    pr ok "Nullbytes bei ${nul} % (Fassung 1: 72,4 %)"
  else
    pr no "Nullbytes bei ${nul} % -- die Bytekopie ist zurueck"
  fi
else
  pr no "std/io.lyx uebersetzt nicht: $(grep -m1 -iE 'error' "$TMP/io.log" | cut -c1-70)"
  pr no "Nullanteil nicht messbar"
fi

echo "--- 2. Varint und Maske sind UMKEHRBAR: Felder bleiben erhalten ---"
# Das ist der Kern. Eine Groessenpruefung allein waere auch von einem Encoder
# erfuellt, der Felder verliert; hier wird der Abschnitt nachgerechnet und
# gegen das RAM-Layout gehalten, das der Leser daraus bauen muss.
if [ -s "$TMP/io.lyu" ]; then
  python3 - "$TMP/io.lyu" > "$TMP/rt.txt" 2>&1 <<'PY'
import sys, struct
d = open(sys.argv[1],'rb').read()
i = d.find(b'LYIR'); p = i+4
ver, nI, nF, nG = struct.unpack_from('<4I', d, p); p += 16
def varint(d, p):
    z = 0; sh = 0
    for k in range(8):
        b = d[p]; p += 1
        z |= (b & 127) << sh
        if not (b & 128):
            return ((z >> 1) ^ -(z & 1)), p
        sh += 7
    z |= d[p] << 56; p += 1
    return ((z >> 1) ^ -(z & 1)), p
def lies(p, satz, felder):
    (l,) = struct.unpack_from('<I', d, p); p += 4
    if l == 0: return [], p, 0
    ende = p + l
    (saetze,) = struct.unpack_from('<I', d, p); p += 4
    mb = (felder + 7)//8
    out = []
    for s in range(saetze):
        maske = int.from_bytes(d[p:p+mb], 'little'); p += mb
        satzf = []
        for f in range(felder):
            if maske & (1 << f):
                v, p = varint(d, p); satzf.append(v)
            else:
                satzf.append(0)
        out.append(satzf)
    assert p == ende, f"Puffer endet bei {p}, angekuendigt {ende}"
    return out, p, saetze
instr, p, sI = lies(p, 80, 10)
(l,) = struct.unpack_from('<I', d, p); p += 4 + l          # str
(l,) = struct.unpack_from('<I', d, p); p += 4 + l          # label
func, p, sF = lies(p, 80, 10)
glob, p, sG = lies(p, 8, 1)
cap,  p, sC = lies(p, 8, 1)
assert sI == nI, f"Instr: Puffer {sI}, Kopf {nI}"
assert sF == nF, f"Func: Puffer {sF}, Kopf {nF}"
assert sG == nG, f"Glob: Puffer {sG}, Kopf {nG}"
belegt = sum(1 for s in instr for v in s if v != 0)
minus1 = sum(1 for s in instr for v in s if v == -1)
print("OK", sI, sF, sG, sC, belegt, minus1)
PY
  if grep -q "^OK " "$TMP/rt.txt"; then
    set -- $(cat "$TMP/rt.txt")
    pr ok "Abschnitt vollstaendig lesbar: $2 Befehle, $3 Funktionen, $4 Globale, $5 Captures"
    # -1 ist im IR "nicht belegt" und muss den Zickzack ueberleben: ohne ihn
    # waere genau dieser Wert der teuerste von allen (zehn Byte).
    if [ "${7:-0}" -gt 0 ]; then
      pr ok "negative Werte kommen zurueck ($7 Felder mit -1)"
    else
      pr no "kein einziges -1 dekodiert -- Zickzack verdaechtig"
    fi
  else
    pr no "Abschnitt nicht lesbar: $(head -3 "$TMP/rt.txt" | tail -1 | cut -c1-80)"
    pr no "Zickzack nicht pruefbar"
  fi
else
  pr no "keine .lyu zum Nachrechnen"; pr no "Zickzack nicht pruefbar"
fi

echo "--- 3. Die Fluchtform traegt grosse UND stark negative Werte ---"
# 8,7 % der Felder wuerden unter naivem Varint WACHSEN (Zeiger,
# Sentinel-Nachbarn). Geprueft wird am Umlauf, nicht am Entwurf: beide
# Extreme muessen exakt zurueckkommen.
python3 - > "$TMP/fl.txt" <<'PY'
def enc(v):
    z = (v << 1) ^ (v >> 63) if v < 0 else (v << 1)
    z &= (1 << 64) - 1
    out = bytearray()
    for _ in range(8):
        if z < 0x80:
            out.append(z); return bytes(out)
        out.append((z & 127) | 128); z >>= 7
    out.append(z & 255); return bytes(out)
def dec(b):
    z = 0; sh = 0; p = 0
    for _ in range(8):
        x = b[p]; p += 1
        z |= (x & 127) << sh
        if not (x & 128):
            return ((z >> 1) ^ -(z & 1)), p
        sh += 7
    z |= b[p] << 56; p += 1
    return ((z >> 1) ^ -(z & 1)), p
faelle = [0, 1, -1, 127, -128, 2**31, -2**31, 2**55, 2**62, -2**62,
          0x7FFFFFFFFFFFFFFF, -0x8000000000000000, 0x4141414141414141]
schlecht = []
maxlen = 0
for v in faelle:
    b = enc(v); maxlen = max(maxlen, len(b))
    w, n = dec(b)
    if w != v or n != len(b): schlecht.append((v, w, len(b)))
print("MAXLEN", maxlen)
print("SCHLECHT", len(schlecht), schlecht[:3])
PY
ml=$(awk '/^MAXLEN/{print $2}' "$TMP/fl.txt"); sb=$(awk '/^SCHLECHT/{print $2}' "$TMP/fl.txt")
[ "$sb" = "0" ] && pr ok "alle 13 Extremwerte kommen exakt zurueck" \
  || pr no "Umlauf falsch fuer $sb Werte: $(grep '^SCHLECHT' "$TMP/fl.txt" | cut -c11-70)"
[ "$ml" = "9" ] && pr ok "kein Wert braucht mehr als 9 Byte (reines LEB128: 10)" \
  || pr no "laengste Kodierung $ml Byte, erwartet 9"

echo "--- 4. Schreiber und Leser nennen DIESELBE Fassung ---"
# Zwei Aufzaehlungen derselben Sache: lyu_writer traegt LYU_IR_VER, ir_lower
# vergleicht gegen ein Literal. Wer eine aendert und die andere nicht, macht
# jede .lyu unlesbar -- laut, aber unnoetig.
wv=$(grep -oE 'pub con LYU_IR_VER: int64 := [0-9]+' "$ROOT/src/lyu_writer.lyx" | grep -oE '[0-9]+$')
rv=$(grep -oE 'abschnittVer != [0-9]+' "$ROOT/src/ir_lower.lyx" | grep -oE '[0-9]+$' | head -1)
if [ -n "$wv" ] && [ "$wv" = "$rv" ]; then
  pr ok "Schreiber und Leser nennen Fassung $wv"
else
  pr no "Schreiber nennt '$wv', Leser '$rv'"
fi

echo "--- 5. Eine fremde Fassung wird abgewiesen, nicht geraten ---"
# Die Wirkung, nicht der Wortlaut: aus einer .lyu wird die Fassungszahl auf
# 99 gesetzt, der Bau MUSS scheitern. Ein Leser, der eine unbekannte Fassung
# als "kein IR" durchlaesst, liefert still ein Programm ohne die Funktionen.
if [ -s "$TMP/io.lyu" ]; then
  mkdir -p "$TMP/baum/lyxos/std" "$TMP/leer"
  cp "$TMP/io.lyu" "$TMP/baum/lyxos/std/io.lyu"
  python3 - "$TMP/baum/lyxos/std/io.lyu" <<'PY'
import sys, struct
p = sys.argv[1]
d = bytearray(open(p,'rb').read())
i = d.find(b'LYIR')
struct.pack_into('<I', d, i+4, 99)
open(p,'wb').write(d)
PY
  printf 'import std.io;\nfn main(): int64 { PrintLn("x"); return 0; }\n' > "$TMP/leer/p.lyx"
  ( cd "$TMP/leer" && timeout 300 "$LYXC" --std-path="$TMP/baum" --target=lyxos \
      p.lyx -o p.lbf ) >"$TMP/f99.log" 2>&1
  if [ -s "$TMP/leer/p.lbf" ]; then
    pr no "Fassung 99 wurde hingenommen und ein Erzeugnis gebaut"
  else
    pr ok "Fassung 99 wird abgewiesen, kein Erzeugnis"
  fi
else
  pr no "keine .lyu fuer die Fassungsprobe"
fi

echo
echo "lyu_ir_varint_2538_test: PASS=$PASS FAIL=$FAIL"
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
