#!/usr/bin/env bash
# tests/bit_builtins_test.sh — popcount/clz/ctz/bswap64/rotl/rotr (#2190) und
# das ISA-Gating, das daran haengt (#2191).
#
# Keines dieser Rechenwerke war in Lyx erreichbar: kein Builtin, keine
# asm-Mnemonik, keine Mustererkennung. Jede Stelle im Bestand, die eins
# brauchte, baute es in einer Schleife nach.
#
# Zwei Dinge werden gemessen, und das zweite ist das eigentlich neue:
#
#   1. Die WERTE — auf x86-64 und auf arm64 unter qemu, mit denselben
#      Erwartungen. Besonders die Randfaelle: clz(0) und ctz(0) sind 64, wie
#      LZCNT/TZCNT es festlegen. Haette der Software-Zweig hier etwas anderes
#      geliefert, haenge das Ergebnis eines Programms an der CPU, auf der es
#      uebersetzt wurde.
#
#   2. Dass die CPU-Stufe den erzeugten CODE veraendert. Ein reiner Wertetest
#      ist dafuer blind: beide Stufen liefern ja absichtlich dasselbe. Geprueft
#      wird deshalb am Erzeugnis, und in BEIDEN Richtungen — mit `baseline`
#      darf kein POPCNT/LZCNT/TZCNT im Erzeugnis liegen, mit `avx2` muss. Nur
#      die eine Haelfte zu pruefen waere auch von einem Compiler erfuellt, der
#      die Stufe ignoriert und immer emittiert (#1823).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

. "$(dirname "$0")/lib/qemu.sh"   # #2048
QEMU="$QEMU_ARM64"
if [ -z "$QEMU" ]; then
  echo "HINWEIS: qemu-aarch64 fehlt — arm64 wird nur uebersetzt."
fi

# Die Werte werden Variablen zugewiesen, nicht direkt in PrintLn gegeben:
# --target=arm64 kann den Typ eines Builtin-Aufrufs als Print-Argument nicht
# bestimmen (vorbestehende Grenze, nicht Teil von #2190).
cat > "$TMP/w.lyx" <<'EOF'
import src.std.io;
fn main(): int64 {
  var a: int64 := popcount(255);
  var b: int64 := popcount(0);
  var c: int64 := popcount(0 - 1);
  var d: int64 := clz(1);
  var e: int64 := clz(0);
  var f: int64 := ctz(8);
  var g: int64 := ctz(0);
  var h: int64 := bswap64(1);
  var i: int64 := rotl(1, 1);
  var j: int64 := rotr(2, 1);
  var k: int64 := rotl(1, 0);
  var l: int64 := rotl(1, 64);
  PrintLn(a); PrintLn(b); PrintLn(c); PrintLn(d); PrintLn(e); PrintLn(f);
  PrintLn(g); PrintLn(h); PrintLn(i); PrintLn(j); PrintLn(k); PrintLn(l);
  return 0;
}
EOF

# popcount(-1) = 64 (alle Bits), clz(1) = 63, bswap64(1) = 1<<56,
# rotl(1,0) == rotl(1,64) == 1: die Hardware beschneidet die Weite auf 6 Bit.
ERWARTET="8 0 64 63 64 3 64 72057594037927936 2 1 1 1"

werte() { # stufe-flag, name
  local flag="$1" name="$2"
  if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $flag "$TMP/w.lyx" -o "$TMP/w.$name" >"$TMP/w.log" 2>&1); then
    echo "FAIL $name uebersetzte nicht"; sed -n '1,4p' "$TMP/w.log"; FAIL=$((FAIL+1)); return
  fi
  local got
  got=$( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/w.$name" 2>/dev/null | tr '\n' ' ' )
  got="${got% }"
  if [ "$got" = "$ERWARTET" ]; then
    echo "PASS Werte $name"; PASS=$((PASS+1))
  else
    echo "FAIL Werte $name: '$got' erwartet '$ERWARTET'"; FAIL=$((FAIL+1))
  fi
}

werte ""                   baseline
werte "--target-cpu=sse4"  sse4
werte "--target-cpu=avx2"  avx2
werte "--target-cpu=avx512" avx512

# arm64: dieselben Werte. Dort gibt es CLZ, RBIT, REV und ROR im Grundbestand
# und popcount ueber CNT+ADDV — CNT allein waere die halbe Antwort, es zaehlt
# die Bits JE BYTE.
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" --target=arm64 -o "$TMP/w.a64" >"$TMP/a.log" 2>&1); then
  if [ -n "$QEMU" ]; then
    got=$( ulimit -c 0; cd "$TMP" && timeout 60 "$QEMU" "$TMP/w.a64" 2>/dev/null | tr '\n' ' ' )
    got="${got% }"
    if [ "$got" = "$ERWARTET" ]; then
      echo "PASS Werte arm64"; PASS=$((PASS+1))
    else
      echo "FAIL Werte arm64: '$got' erwartet '$ERWARTET'"; FAIL=$((FAIL+1))
    fi
  else
    echo "PASS arm64 uebersetzt (qemu fehlt)"; PASS=$((PASS+1))
  fi
else
  echo "FAIL arm64 uebersetzte nicht"; sed -n '1,4p' "$TMP/a.log"; FAIL=$((FAIL+1))
fi

# riscv: RV64I kennt keinen dieser Befehle (sie stehen in der Erweiterung Zbb,
# die nicht zugesichert ist) — sie werden dort aus Grundbefehlen gerechnet.
# Gemessen wird trotzdem derselbe Wert; eine eigene Rechnung je Backend ist
# genau die Stelle, an der Ergebnisse auseinanderlaufen.
if [ -n "$QEMU_RISCV64" ]; then
  if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" --target=riscv -o "$TMP/w.rv" >"$TMP/r.log" 2>&1); then
    got=$( ulimit -c 0; cd "$TMP" && timeout 60 "$QEMU_RISCV64" "$TMP/w.rv" 2>/dev/null | tr '\n' ' ' )
    got="${got% }"
    if [ "$got" = "$ERWARTET" ]; then
      echo "PASS Werte riscv"; PASS=$((PASS+1))
    else
      echo "FAIL Werte riscv: '$got' erwartet '$ERWARTET'"; FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL riscv uebersetzte nicht"; sed -n '1,4p' "$TMP/r.log"; FAIL=$((FAIL+1))
  fi
else
  echo "HINWEIS: qemu-riscv64 fehlt — riscv nicht gemessen."
fi

# --- Das Gating am Erzeugnis ------------------------------------------------
# Gezaehlt wird mit Python, weil das Erzeugnis keine Sections hat und
# `objdump -d` daran nichts anzeigt. Wichtig: `48 0F BD C7` (BSR) ist eine
# TEILFOLGE von `F3 48 0F BD C7` (LZCNT) — wer nur sucht, zaehlt den
# Hardware-Befehl als Software-Zweig mit. Deshalb wird das F3 davor
# ausdruecklich ausgeschlossen.
zaehl() { # datei
python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
def n(pat, ohne_f3=False):
    k = 0; i = 0
    while True:
        i = d.find(pat, i)
        if i < 0: return k
        if not ohne_f3 or i == 0 or d[i-1] != 0xF3: k += 1
        i += 1
print(n(b'\xf3\x48\x0f\xb8\xc7'), n(b'\xf3\x48\x0f\xbd\xc7'), n(b'\xf3\x48\x0f\xbc\xc7'),
      n(b'\x48\x0f\xbd\xc7', True), n(b'\x48\x0f\xbc\xc7', True))
PY
}

read -r p_base l_base t_base bsr_base bsf_base <<< "$(zaehl "$TMP/w.baseline")"
read -r p_avx  l_avx  t_avx  bsr_avx  bsf_avx  <<< "$(zaehl "$TMP/w.avx2")"
read -r p_sse  l_sse  t_sse  bsr_sse  bsf_sse  <<< "$(zaehl "$TMP/w.sse4")"

if [ "$p_base" -eq 0 ] && [ "$l_base" -eq 0 ] && [ "$t_base" -eq 0 ]; then
  echo "PASS baseline emittiert kein POPCNT/LZCNT/TZCNT"; PASS=$((PASS+1))
else
  echo "FAIL baseline emittiert gated Befehle: popcnt=$p_base lzcnt=$l_base tzcnt=$t_base"; FAIL=$((FAIL+1))
fi
if [ "$bsr_base" -gt 0 ] && [ "$bsf_base" -gt 0 ]; then
  echo "PASS baseline nimmt den Software-Zweig (BSR/BSF)"; PASS=$((PASS+1))
else
  echo "FAIL baseline ohne Software-Zweig: bsr=$bsr_base bsf=$bsf_base"; FAIL=$((FAIL+1))
fi
if [ "$p_avx" -gt 0 ] && [ "$l_avx" -gt 0 ] && [ "$t_avx" -gt 0 ]; then
  echo "PASS avx2 emittiert POPCNT, LZCNT und TZCNT"; PASS=$((PASS+1))
else
  echo "FAIL avx2 emittiert sie nicht: popcnt=$p_avx lzcnt=$l_avx tzcnt=$t_avx"; FAIL=$((FAIL+1))
fi
# Die Stufen sind gestaffelt: POPCNT kam mit SSE4.2, LZCNT/TZCNT erst mit
# BMI1. `sse4` darf deshalb POPCNT emittieren, LZCNT/TZCNT aber nicht.
if [ "$p_sse" -gt 0 ] && [ "$l_sse" -eq 0 ] && [ "$t_sse" -eq 0 ]; then
  echo "PASS sse4 emittiert POPCNT, aber kein LZCNT/TZCNT"; PASS=$((PASS+1))
else
  echo "FAIL sse4 staffelt nicht: popcnt=$p_sse lzcnt=$l_sse tzcnt=$t_sse"; FAIL=$((FAIL+1))
fi

# --- @cpu an der Funktion schlaegt die CLI ----------------------------------
# Ohne diesen Fall waere nur belegt, dass das Flag wirkt, nicht das Attribut.
cat > "$TMP/at.lyx" <<'EOF'
@cpu(avx2)
fn zaehle(x: int64): int64 { return popcount(x); }
fn main(): int64 { return zaehle(255); }
EOF
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/at.lyx" -o "$TMP/at" >"$TMP/at.log" 2>&1); then
  read -r p_at _ _ _ _ <<< "$(zaehl "$TMP/at")"
  ( ulimit -c 0; "$TMP/at" ); rc=$?
  if [ "$p_at" -gt 0 ] && [ "$rc" -eq 8 ]; then
    echo "PASS @cpu(avx2) setzt POPCNT durch, obwohl die CLI baseline sagt (rc=$rc)"; PASS=$((PASS+1))
  else
    echo "FAIL @cpu(avx2): popcnt=$p_at rc=$rc (erwartet popcnt>0, rc=8)"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL @cpu(avx2) uebersetzte nicht"; sed -n '1,4p' "$TMP/at.log"; FAIL=$((FAIL+1))
fi

# --- Falsche Namen muessen ABGEWIESEN werden --------------------------------
# Ein Tippfehler darf nicht still als baseline gedeutet werden: der Code waere
# dann langsamer als zugesagt, und niemand haette es gemerkt.
out=$(cd "$ROOT" && "$LYXC" --target-cpu=avx9 "$TMP/w.lyx" -o "$TMP/x" 2>&1)
if echo "$out" | grep -q 'target-cpu kennt nur'; then
  echo "PASS --target-cpu=avx9 wird abgewiesen"; PASS=$((PASS+1))
else
  echo "FAIL --target-cpu=avx9 nicht abgewiesen: $out"; FAIL=$((FAIL+1))
fi
printf '@cpu(avx9)\nfn f(): int64 { return 1; }\nfn main(): int64 { return f(); }\n' > "$TMP/bad.lyx"
out=$(cd "$ROOT" && "$LYXC" "$TMP/bad.lyx" -o "$TMP/bad" 2>&1)
if echo "$out" | grep -q '@cpu kennt nur'; then
  echo "PASS @cpu(avx9) wird abgewiesen"; PASS=$((PASS+1))
else
  echo "FAIL @cpu(avx9) nicht abgewiesen: $out"; FAIL=$((FAIL+1))
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
