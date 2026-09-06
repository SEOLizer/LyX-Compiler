#!/usr/bin/env bash
# #1974: Der IR-Abschnitt der .lyu.
#
# Bis 1.2.3B trug eine `.lyu` NAMEN und TYPEN, aber keinen Code: das Feld
# `IRCodeOffset` stand im Kopf und wurde immer als 0 geschrieben. Eine allein
# ausgelieferte Unit lieferte deshalb keine einzige Funktion.
#
# GEMESSEN WIRD DER INHALT des Abschnitts, nicht sein Vorhandensein: die
# Satzgroessen muessen aufgehen (Instruktionen 80 Byte, Funktionen 80 Byte),
# und die Byte-Laengen muessen zu den Anzahlen im Kopf des Abschnitts passen.
# Ein Test auf "LYIR kommt vor" waere auch von einem Abschnitt erfuellt, in
# dem Muell steht — und genau so sah der erste Wurf aus: `instr 7 Byte`,
# `func 1 Byte`, weil die Laengenfelder des IR-Moduls NICHT einheitlich
# zaehlen (instr/func/global/capture zaehlen SAETZE, str/label zaehlen BYTES).
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
laengen = {}
for name in ("instr", "str", "label", "func", "global", "capture"):
    ln, = struct.unpack_from("<I", d, p); p += 4
    laengen[name] = ln
    p += ln
# Der Abschnitt muss GENAU bis ans Dateiende reichen: bleibt etwas uebrig oder
# laeuft er darueber hinaus, stimmen die Laengen nicht.
print(f"ver={ver} nInstr={nInstr} nFunc={nFunc} nGlob={nGlob} "
      f"instr={laengen['instr']} func={laengen['func']} str={laengen['str']} "
      f"ende={p} datei={len(d)}")
PY
)"

if [ "$befund" = "FEHLT" ]; then
    nok "kein IR-Abschnitt in der .lyu"
    echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "die .lyu traegt einen IR-Abschnitt"

eval "$(printf '%s\n' "$befund" | tr ' ' '\n' | sed 's/^/lyu_/')"

# Die Satzgroessen muessen aufgehen — sonst steht dort Muell.
if [ $(( lyu_instr % 80 )) -eq 0 ] && [ "$lyu_instr" -eq $(( lyu_nInstr * 80 )) ]; then
    ok "Instruktionen: $lyu_nInstr Saetze = $lyu_instr Byte"
else
    nok "Instruktionen passen nicht: $lyu_nInstr Saetze, $lyu_instr Byte"
fi

# Zwei pub-Funktionen — die Unit deklariert genau zwei.
if [ "$lyu_func" -eq $(( lyu_nFunc * 80 )) ] && [ "$lyu_nFunc" -ge 2 ]; then
    ok "Funktionen: $lyu_nFunc Saetze = $lyu_func Byte"
else
    nok "Funktionen passen nicht: $lyu_nFunc Saetze, $lyu_func Byte"
fi

# Der Abschnitt endet GENAU am Dateiende.
if [ "$lyu_ende" -eq "$lyu_datei" ]; then
    ok "der Abschnitt endet genau am Dateiende"
else
    nok "Abschnitt endet bei $lyu_ende, Datei ist $lyu_datei Byte"
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
