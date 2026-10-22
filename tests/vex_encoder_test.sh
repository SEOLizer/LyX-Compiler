#!/usr/bin/env bash
# tests/vex_encoder_test.sh — #2192, Schnitt 1: der VEX-Encoder fuer sich.
#
# AVX2 wird seit #2187 erkannt und war nirgends emittiert — im ganzen Compiler
# gab es kein einziges VEX-kodiertes Wort. Der Encoder ist die Voraussetzung
# dafuer und wird hier ALLEIN geprueft, bevor er im Vektorpfad Wirkung hat.
#
# Warum getrennt: ein falsch gesetztes Bit im Praefix erzeugt keinen Fehler,
# sondern einen ANDEREN gueltigen Befehl. Bei der NEON-Tabelle aus #2185 waren
# vier von vier Woertern falsch, drei davon sahen wie gueltige Befehle aus und
# eines war gar keiner — aufgefallen ist das erst, als die Bytes
# zurueckgelesen wurden. VEX hat sechs Felder (R, X, B, vvvv, L, pp, mm, W),
# und R, X, B und vvvv stehen INVERTIERT im Praefix.
#
# Deshalb vergleicht dieser Test die Bytes NICHT mit einer Liste, die jemand
# getippt hat. Er laesst `lyxc --vex-selftest` die Kodierungen ausgeben und
# gibt sie an llvm-mc zum DISASSEMBLIEREN; verglichen wird, was dabei
# herauskommt, mit dem gemeinten Befehl. Eine ungueltige Kodierung meldet
# llvm-mc ausdruecklich als "invalid instruction encoding".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

MC=""
for k in llvm-mc-21 llvm-mc-20 llvm-mc-19 llvm-mc; do
  if command -v "$k" >/dev/null 2>&1; then MC="$k"; break; fi
done

if ! "$LYXC" --vex-selftest > "$TMP/vex.txt" 2>"$TMP/vex.err"; then
  echo "FAIL --vex-selftest lief nicht"; sed -n '1,4p' "$TMP/vex.err"
  echo "Ergebnis: 0 PASS, 1 FAIL"; exit 1
fi

zeilen=$(grep -c . "$TMP/vex.txt")
if [ "$zeilen" -lt 15 ]; then
  echo "FAIL --vex-selftest gibt nur $zeilen Zeilen aus (erwartet mindestens 15)"
  FAIL=$((FAIL+1))
else
  echo "PASS --vex-selftest gibt $zeilen Kodierungen aus"; PASS=$((PASS+1))
fi

# Jede Zeile: "<gemeinter Befehl>\t<bytes in hex>".
# Verglichen wird der MNEMONIC und die Operandenliste, soweit sie im gemeinten
# Namen steht — Schreibweisen wie "ymm0, ymm1, ymm2" muessen uebereinstimmen.
# Eine Zeile, deren gemeinter Name eine Klammer traegt, wird nur am Mnemonic
# geprueft (dort steht eine Anmerkung statt der Operanden).
if [ -z "$MC" ]; then
  echo "HINWEIS: llvm-mc fehlt — die Kodierungen werden NICHT zurueckgelesen."
  echo "  Damit prueft dieser Lauf nur, DASS Bytes entstehen, nicht WELCHE."
  echo "  Auf einer Maschine mit llvm-mc gegenmessen (Paket llvm)."
else
  while IFS=$'\t' read -r gemeint bytes; do
    [ -z "$gemeint" ] && continue
    [ -z "$bytes" ] && { echo "FAIL $gemeint: keine Bytes"; FAIL=$((FAIL+1)); continue; }

    # Hex-Folge ("c5 f4 58 c2") in die Form bringen, die llvm-mc liest.
    komma=$(printf '%s' "$bytes" | sed 's/ /,0x/g; s/^/0x/')
    # --output-asm-variant=1 = Intel-Syntax. Ohne das liest llvm-mc in AT&T aus:
    # umgekehrte Operandenreihenfolge und %-Praefix. Beim ersten Lauf hat genau
    # das 15 richtige Kodierungen als falsch gemeldet.
    gelesen=$(printf '%s\n' "$komma" | "$MC" --disassemble --triple=x86_64 --output-asm-variant=1 2>&1)

    if printf '%s' "$gelesen" | grep -qi 'invalid\|error'; then
      echo "FAIL $gemeint: llvm-mc haelt '$bytes' fuer ungueltig"
      FAIL=$((FAIL+1)); continue
    fi

    # Mnemonic und Operanden aus der llvm-mc-Ausgabe normalisieren.
    # Die Zeile kann eine Anmerkung tragen (bei FMA haengt llvm-mc
    # " # ymm0 = (ymm1*ymm0)+ymm2" an) — alles ab '#' gehoert nicht zum Befehl.
    ist=$(printf '%s' "$gelesen" | sed -n '1p' | sed 's/#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g')
    mnem_ist=$(printf '%s' "$ist" | cut -d' ' -f1)
    mnem_soll=$(printf '%s' "$gemeint" | cut -d' ' -f1)

    if [ "$mnem_ist" != "$mnem_soll" ]; then
      echo "FAIL $gemeint: gelesen '$ist' (Bytes $bytes)"
      FAIL=$((FAIL+1)); continue
    fi

    # Operanden nur vergleichen, wenn der gemeinte Name keine Anmerkung traegt.
    case "$gemeint" in
      *\(*) echo "PASS $mnem_soll (nur Mnemonic geprueft: $ist)"; PASS=$((PASS+1)); continue ;;
    esac

    op_soll=$(printf '%s' "$gemeint"  | cut -d' ' -f2- | tr -d ' ')
    op_ist=$( printf '%s' "$ist"      | cut -d' ' -f2- | tr -d ' ')
    if [ "$op_soll" = "$op_ist" ]; then
      echo "PASS $gemeint  [$bytes]"; PASS=$((PASS+1))
    else
      echo "FAIL $gemeint: Operanden gelesen als '$op_ist' (Bytes $bytes)"
      FAIL=$((FAIL+1))
    fi
  done < "$TMP/vex.txt"
fi

# Die kurze Form muss genommen werden, wo sie geht, und die lange, wo sie
# noetig ist. Ohne diese Pruefung waere ein Encoder erfuellt, der immer die
# dreibyteige Form schreibt — er waere korrekt, aber jedes Wort ein Byte zu
# lang, und das faellt an keiner Disassembly auf.
kurz=$(grep -c $'\tc5 ' "$TMP/vex.txt" || true)
lang=$(grep -c $'\tc4 ' "$TMP/vex.txt" || true)
if [ "$kurz" -gt 0 ] && [ "$lang" -gt 0 ]; then
  echo "PASS beide Praefixformen kommen vor ($kurz zweibyteig, $lang dreibyteig)"
  PASS=$((PASS+1))
else
  echo "FAIL Praefixformen: $kurz zweibyteig, $lang dreibyteig — beide muessen vorkommen"
  FAIL=$((FAIL+1))
fi

# VZEROUPPER gehoert dazu: wer 256-Bit-Code emittiert und den oberen Teil vor
# der Rueckkehr in SSE-Code nicht loescht, zahlt den Zustandswechsel bei JEDEM
# folgenden SSE-Befehl.
if grep -qi '^vzeroupper' "$TMP/vex.txt"; then
  echo "PASS vzeroupper ist dabei"; PASS=$((PASS+1))
else
  echo "FAIL vzeroupper fehlt im Selbsttest"; FAIL=$((FAIL+1))
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
