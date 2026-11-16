#!/usr/bin/env bash
# #1974: Der IR-Abschnitt der .lyu.
#
# Bis 1.2.3B trug eine `.lyu` NAMEN und TYPEN, aber keinen Code: das Feld
# `IRCodeOffset` stand im Kopf und wurde immer als 0 geschrieben. Eine allein
# ausgelieferte Unit lieferte deshalb keine einzige Funktion.
#
# GEMESSEN WIRD DER INHALT des Abschnitts, nicht sein Vorhandensein: ein Test
# auf "LYIR kommt vor" waere auch von einem Abschnitt erfuellt, in dem Muell
# steht — und genau so sah der erste Wurf aus: `instr 7 Byte`, `func 1 Byte`,
# weil die Laengenfelder des IR-Moduls NICHT einheitlich zaehlen
# (instr/func/global/capture zaehlen SAETZE, str/label zaehlen BYTES).
#
# #2538 hat das MITTEL geaendert, nicht den Zweck. Bis Fassung 1 war der
# Abschnitt eine Bytekopie des RAM-Layouts, und die Pruefung lautete
# `instr == nInstr * 80`. Seit Fassung 2 sind die Satzpuffer feldweise
# kodiert (Maske + Varint), also sagt die Bytelaenge nichts mehr ueber die
# Satzzahl. Geprueft wird deshalb SCHAERFER als vorher: der Puffer wird
# DEKODIERT, seine Satzzahl gegen die im Kopf gehalten, und er muss genau an
# seinem angekuendigten Ende aufhoeren. Eine Rechnung konnte nur aufgehen
# oder nicht; ein Umlauf faellt auch dann auf, wenn Felder verloren gehen.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/demo"
cat > "$TMP/demo/mathe.lyx" <<'EOF'
unit demo.mathe;
pub fn Verdoppeln(x: int64): int64 { return x * 2; }
pub fn Dreifach(x: int64): int64 { return x * 3; }
pub con ZWEI: int64 := 2;
EOF

# #1982: Das IR entsteht nur fuer ein Ziel, das den IR-Weg auch geht. Ohne
# --target liefert --compile-unit eine .lyu wie vor #1974 (Namen und Typen,
# kein Code) — siehe die Gegenprobe unten.
if ! ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --target=arm64 --std-path="$ROOT" \
        "$TMP/demo/mathe.lyx" -o "$TMP/demo/mathe.lyu" ) >"$TMP/cu.log" 2>&1; then
    nok "--compile-unit schlaegt fehl"; sed -n '1,4p' "$TMP/cu.log"
    echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "--compile-unit erzeugt die .lyu"

# Der Abschnitt wird AUSGEWERTET, nicht nur gesucht.
befund="$(python3 - "$TMP/demo/mathe.lyu" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"LYIR")
if i < 0:
    print("FEHLT"); raise SystemExit
p = i + 4
ver, = struct.unpack_from("<I", d, p); p += 4
nInstr, nFunc, nGlob = struct.unpack_from("<III", d, p); p += 12
# #2538: Zickzack-Varint lesen — Spiegelbild von lyu_writer._eVarint,
# einschliesslich der Fluchtform (nach acht Fortsetzungsbytes wird das neunte
# ROH genommen).
def _varint(d, q):
    z = 0; sh = 0
    for _ in range(8):
        b = d[q]; q += 1
        z |= (b & 127) << sh
        if not (b & 128):
            return ((z >> 1) ^ -(z & 1)), q
        sh += 7
    z |= d[q] << 56; q += 1
    return ((z >> 1) ^ -(z & 1)), q

# Einen feldweise kodierten Satzpuffer dekodieren. Gibt die Satzzahl und die
# Zahl BELEGTER Felder zurueck -- letztere faellt auf, wenn die Maske und die
# Varints auseinanderlaufen.
def _dekod(d, q, laenge, felder):
    if laenge <= 0: return 0, 0, q
    ende = q + laenge
    saetze, = struct.unpack_from("<I", d, q); q += 4
    mb = (felder + 7) // 8
    belegt = 0
    for _ in range(saetze):
        maske = int.from_bytes(d[q:q+mb], "little"); q += mb
        for f in range(felder):
            if maske & (1 << f):
                _, q = _varint(d, q); belegt += 1
    if q != ende:
        raise AssertionError(f"Puffer endet bei {q}, angekuendigt {ende}")
    return saetze, belegt, ende

laengen = {}
dek = {}
satzfelder = {"instr": (80, 10), "func": (80, 10), "global": (8, 1), "capture": (8, 1)}
for name in ("instr", "str", "label", "func", "global", "capture"):
    ln, = struct.unpack_from("<I", d, p); p += 4
    laengen[name] = ln
    if ver >= 2 and name in satzfelder:
        _satz, felder = satzfelder[name]
        try:
            saetze, belegt, p = _dekod(d, p, ln, felder)
        except (AssertionError, IndexError, struct.error) as e:
            print(f"KAPUTT {name}: {e}"); raise SystemExit
        dek[name] = (saetze, belegt)
    else:
        p += ln

# Der Abschnitt muss GENAU dort enden, wo der naechste anfaengt — bleibt etwas
# uebrig oder laeuft er darueber hinaus, stimmen die Laengen nicht.
#
# Bis 1.2.5H stand hier "genau am Dateiende". Das war nur richtig, solange der
# IR-Abschnitt der LETZTE war; mit dem Konstantenabschnitt (#2014) liegen 19
# Byte dahinter, und mit Ressourcen (#1971) waere der Test genauso gefallen.
# Die Reihenfolge der Abschnitte ist nicht zugesichert, ihre LAGE steht im
# Kopf — also von dort lesen.
#
# Kopf: magic(4) ver(2) arch(1) flags(1) ulen(2)+name, dann bei v2 drei
# Leerstrings, dann symCount(4) und VIER Offsets.
q = 4
kver, = struct.unpack_from("<H", d, q); q += 2
q += 2                                   # arch + flags
ul, = struct.unpack_from("<H", d, q); q += 2 + ul
if kver >= 2:
    for _ in range(3):
        ln, = struct.unpack_from("<H", d, q); q += 2 + ln
q += 4                                   # symCount
offs = struct.unpack_from("<IIII", d, q) # konstanten, ir, debug, ressourcen
# Der naechste Abschnitt hinter dem IR — oder das Dateiende, wenn keiner folgt.
spaeter = [o for o in offs if 0 < o and o > i]
grenze = min(spaeter) if spaeter else len(d)

dI = dek.get("instr", (0, 0)); dF = dek.get("func", (0, 0)); dG = dek.get("global", (0, 0))
print(f"ver={ver} nInstr={nInstr} nFunc={nFunc} nGlob={nGlob} "
      f"instr={laengen['instr']} func={laengen['func']} str={laengen['str']} "
      f"dInstr={dI[0]} dFunc={dF[0]} dGlob={dG[0]} fInstr={dI[1]} "
      f"ende={p} grenze={grenze} datei={len(d)}")
PY
)"

if [ "$befund" = "FEHLT" ]; then
    nok "kein IR-Abschnitt in der .lyu"
    echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "die .lyu traegt einen IR-Abschnitt"

eval "$(printf '%s\n' "$befund" | tr ' ' '\n' | sed 's/^/lyu_/')"

# #2538: Der dekodierte Puffer muss so viele Saetze hergeben, wie der Kopf
# nennt. Das ist die Nachfolgepruefung von `instr == nInstr * 80`: sie faellt
# bei gemischter Zaehlweise genauso auf, und zusaetzlich dann, wenn Maske und
# Varints auseinanderlaufen (der Umlauf endet dann nicht am Pufferende).
if [ "$lyu_dInstr" -eq "$lyu_nInstr" ] && [ "$lyu_nInstr" -gt 0 ]; then
    ok "Instruktionen: $lyu_nInstr Saetze dekodiert, $lyu_fInstr belegte Felder, $lyu_instr Byte kodiert"
else
    nok "Instruktionen passen nicht: Kopf $lyu_nInstr, dekodiert $lyu_dInstr"
fi

# Die Kodierung muss auch GREIFEN: ein Encoder, der jedes Feld schreibt, waere
# von der Satzzahl allein erfuellt. Das RAM-Layout waere nInstr * 80 Byte.
if [ "$lyu_instr" -lt $(( lyu_nInstr * 80 )) ]; then
    ok "kodiert kleiner als das RAM-Layout: $lyu_instr < $(( lyu_nInstr * 80 )) Byte"
else
    nok "kodierter Puffer nicht kleiner als $(( lyu_nInstr * 80 )) Byte — Bytekopie zurueck?"
fi

# Zwei pub-Funktionen — die Unit deklariert genau zwei.
if [ "$lyu_dFunc" -eq "$lyu_nFunc" ] && [ "$lyu_nFunc" -ge 2 ]; then
    ok "Funktionen: $lyu_nFunc Saetze dekodiert, $lyu_func Byte kodiert"
else
    nok "Funktionen passen nicht: Kopf $lyu_nFunc, dekodiert $lyu_dFunc"
fi

# Der Abschnitt endet GENAU dort, wo der naechste anfaengt (oder am Dateiende,
# wenn keiner folgt).
if [ "$lyu_ende" -eq "$lyu_grenze" ]; then
    ok "der IR-Abschnitt endet genau an der naechsten Abschnittsgrenze ($lyu_grenze)"
else
    nok "IR-Abschnitt endet bei $lyu_ende, Grenze ist $lyu_grenze (Datei $lyu_datei Byte)"
fi

# GEGENPROBE: ein aelterer Leser darf die Datei unveraendert lesen. Der
# Abschnitt haengt hinten, Offset im Kopf — --unit-info muss die Symbole
# weiterhin zeigen, samt der Rueckgabetypen aus #1966.
info="$( cd "$ROOT" && timeout 60 "$LYXC" --unit-info "$TMP/demo/mathe.lyu" 2>&1 )"
if printf '%s' "$info" | grep -qE "fn[[:space:]]+Verdoppeln[[:space:]]+int64" \
   && printf '%s' "$info" | grep -qE "con[[:space:]]+ZWEI"; then
    ok "--unit-info liest die Datei unveraendert"
else
    nok "--unit-info stolpert ueber den IR-Abschnitt"
fi

# Und die Unit bleibt als Import brauchbar (mit .lyx daneben).
cat > "$TMP/prog.lyx" <<'EOF'
unit main;
import std.io;
import demo.mathe;
fn main(): int64 { PrintLn(IntToStr(Verdoppeln(21))); return 0; }
EOF
if ( cd / && timeout 120 "$LYXC" --std-path="$ROOT" --include-path="$TMP" \
      "$TMP/prog.lyx" -o "$TMP/prog" ) >"$TMP/b.log" 2>&1 \
   && [ "$( ulimit -v 4000000; "$TMP/prog" )" = "42" ]; then
    ok "die Unit bleibt als Import brauchbar"
else
    nok "Import gestoert"; sed -n '1,4p' "$TMP/b.log"
fi

# --- #1982: ohne Zielangabe KEIN IR-Abschnitt -------------------------------
#
# Die erste Fassung von #1974 baute das IR immer, auch fuer das voreingestellte
# x86_64. Zwei Gruende, warum das falsch war:
#
#   * x86 nimmt den Schnellweg direkt vom AST, ein IR wird dort nie gebraucht —
#     wohl aber gebaut, und dabei stolperte ir_lower ueber Builtins, die nur
#     der x86-Codegen kennt (118 Namen laut Drift-Waechter). `make
#     precompile-units` brach an std/bpf.lyx ab.
#   * Das Lowering ist ZIELABHAENGIG; ein fuer x86 gebautes IR waere fuer arm64
#     gar nicht das richtige gewesen.
#
# Geprueft wird deshalb BEIDES: mit Ziel ist der Abschnitt da (oben), ohne Ziel
# nicht. Ein Test nur auf "Abschnitt vorhanden" haette die Regression nicht
# bemerkt.
if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --std-path="$ROOT" \
      "$TMP/demo/mathe.lyx" -o "$TMP/ohneziel.lyu" ) >"$TMP/oz.log" 2>&1; then
    if python3 -c "import sys; sys.exit(0 if open('$TMP/ohneziel.lyu','rb').read().find(b'LYIR') < 0 else 1)"; then
        ok "ohne --target entsteht kein IR-Abschnitt"
    else
        nok "ohne --target entsteht doch ein IR-Abschnitt (#1982)"
    fi
else
    nok "--compile-unit ohne Ziel schlaegt fehl"; grep -v Copyright "$TMP/oz.log" | sed -n '1,3p'
fi

# Und eine Unit, die einen NUR-x86-Builtin benutzt, muss sich weiterhin
# vorkompilieren lassen — das ist der Fall, an dem precompile-units brach.
if [ -f "$ROOT/std/bpf.lyx" ]; then
    if ( cd "$ROOT" && timeout 120 "$LYXC" --compile-unit --std-path="$ROOT" \
          "$ROOT/std/bpf.lyx" -o "$TMP/bpf.lyu" ) >"$TMP/bpf.log" 2>&1; then
        ok "std/bpf.lyx (nutzt sys_bpf, nur x86) laesst sich vorkompilieren"
    else
        nok "std/bpf.lyx bricht ab: $(grep -viE 'copyright' "$TMP/bpf.log" | grep -iE 'lyxc:|error' | head -1)"
    fi
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
