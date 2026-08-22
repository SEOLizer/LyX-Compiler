#!/usr/bin/env bash
# tests/cli_truth_test.sh — #1368, #1098, #1360.
#
# Drei Ausprägungen desselben Musters: der Compiler nimmt etwas an und tut
# etwas anderes, ohne es zu sagen.
#
# #1368: Der Aufloeser kannte keinen Installationspfad. Nach `dpkg -i`
# scheiterte `import std.io` — fuer `make test` unsichtbar, weil der immer
# `--std-path` mitgibt. Genau deshalb misst dieser Test OHNE Schalter und
# OHNE Umgebungsvariablen, aus einem fremden Arbeitsverzeichnis.
#
# #1098: Schalter, die etwas versprechen und schweigen. Drei Klassen:
#   (a) `--no-opt` wurde AKTIV rueckgaengig gemacht — OPT_NONE ist 0, und die
#       Normalisierung hob jede 0 auf O2. Zudem erreichte die CLI-Stufe den
#       x86-Schnellweg nie, der nur die Angabe aus dem Quelltext las.
#   (b) `--call-graph`, `--static-analysis`, `--trace-imports` rechneten oder
#       waren verdrahtet, gaben aber nichts aus.
#   (c) sechs Schalter ohne jede Umsetzung (#1370) — sie werden abgewiesen.
# Der Nachweis vergleicht deshalb gegen einen ERFUNDENEN Schalter: was sich
# wie `--zzz-gibt-es-nicht` verhaelt, ist wirkungslos.
#
# #1360: `--target=riscv` fiel in einen Emitter ohne IR-Durchlauf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/hallo.lyx" <<'EOF'
import std.io;
fn main(): int64 { PrintLn("hi"); return 0; }
EOF
cat > "$TMP/rek.lyx" <<'EOF'
fn fak(n: int64): int64 { if n <= 1 { return 1; } return n * fak(n - 1); }
fn tot(): int64 { return 7; }
fn main(): int64 { var a: [4]int64; a[0] := fak(5); return a[0]; }
EOF

# ===========================================================================
# #1368 — die Standardbibliothek ohne jede Angabe finden
# ===========================================================================

# Ein installiertes lyxc hat weder -I noch --std-path noch LYX_*; der Test
# stellt genau das her. Er greift auf den Paketbaum des Repos zu, indem er ihn
# als /usr/include/lyx/units erwartet — liegt dort nichts, ist die Pruefung
# nicht aussagekraeftig und wird uebersprungen statt falsch gruen gemeldet.
if [ -d /usr/include/lyx/units/std ]; then
  ( cd "$TMP" && env -u LYX_PATH -u LYX_STD_PATH "$LYXC" hallo.lyx -o hallo >/dev/null 2>&1 )
  if [ -x "$TMP/hallo" ] && [ "$("$TMP/hallo" 2>/dev/null)" = "hi" ]; then
    ok "import std.io ohne --std-path und ohne LYX_STD_PATH"
  else
    no "import std.io ohne --std-path und ohne LYX_STD_PATH" "uebersetzt nicht oder laeuft nicht"
  fi
else
  echo "SKIP /usr/include/lyx/units nicht installiert — #1368 nicht messbar"
fi

# Die Reihenfolge ist der eigentliche Vertrag: der eingebaute Pfad kommt
# ZULETZT. Sonst uebersteuerte eine installierte Bibliothek die des Checkouts,
# und niemand kaeme mehr an seine eigene Aenderung heran.
#
# Geprueft wird mit einer Funktion, die es NUR im eigenen Baum gibt. Ein
# Nachbau von PrintLn taugt dafuer nicht: PrintLn ist ein Builtin und wird
# nie aus der Unit geholt — der erste Anlauf dieses Tests mass deshalb nichts.
mkdir -p "$TMP/eigen/std"
cat > "$TMP/eigen/std/io.lyx" <<'EOF'
unit std.io;
pub fn NurImEigenenBaum(): int64 { return 42; }
EOF
cat > "$TMP/vorrang.lyx" <<'EOF'
import std.io;
fn main(): int64 { return NurImEigenenBaum(); }
EOF
( cd "$TMP" && env -u LYX_PATH -u LYX_STD_PATH "$LYXC" --std-path="$TMP/eigen" vorrang.lyx -o vorrang >/dev/null 2>&1 )
if [ -x "$TMP/vorrang" ]; then
  "$TMP/vorrang"; rc=$?
  if [ "$rc" -eq 42 ]; then ok "--std-path schlaegt den eingebauten Installationspfad"
  else no "--std-path schlaegt den eingebauten Installationspfad" "rc=$rc statt 42"; fi
else
  no "--std-path schlaegt den eingebauten Installationspfad" "uebersetzt nicht"
fi

# ===========================================================================
# #1098 — Schalter, die etwas versprechen
# ===========================================================================

# Referenz: so sieht Wirkungslosigkeit aus.
erfunden="$("$LYXC" "$TMP/rek.lyx" --zzz-gibt-es-nicht -o "$TMP/z" 2>&1)"
case "$erfunden" in
  *"unbekannter Schalter"*) ok "unbekannter Schalter wird gemeldet" ;;
  *) no "unbekannter Schalter wird gemeldet" "$erfunden" ;;
esac

hat_ausgabe() { # name, schalter, erwartetes textstueck
  out="$("$LYXC" "$TMP/rek.lyx" "$2" -o "$TMP/r" 2>&1)"
  case "$out" in
    *"$3"*) ok "$1" ;;
    *) no "$1" "Ausgabe enthaelt '$3' nicht" ;;
  esac
}

hat_ausgabe "--call-graph nennt Umfang des Graphen"   --call-graph      "Aufrufgraph"
hat_ausgabe "--call-graph nennt die Rekursion"        --call-graph      "fak"
hat_ausgabe "--static-analysis nennt den Stapelbedarf" --static-analysis "Stapelbedarf"

# --trace-imports muss den GEWONNENEN Pfad nennen, nicht bloss "starte
# Aufloesung" — die Frage lautet ja, welcher der vier Suchwege gegriffen hat.
timp="$("$LYXC" --std-path="$ROOT" "$TMP/hallo.lyx" --trace-imports -o "$TMP/h" 2>&1)"
# Wird die Unit relativ zum Arbeitsverzeichnis gefunden, steht dort ein
# relativer Pfad — genau das ist die Auskunft, um die es geht.
case "$timp" in
  *"[import] std.io -> "*"io.lyx"*) ok "--trace-imports nennt den aufgeloesten Pfad" ;;
  *) no "--trace-imports nennt den aufgeloesten Pfad" "$(echo "$timp" | grep -c '\[import\]') Zeilen" ;;
esac

# --no-opt: geprueft wird der WEG, nicht die Ausgabe. Ohne Optimierung muss
# ein anderes Binary entstehen — sonst ist der Schalter wirkungslos, egal was
# er meldet. Genau daran scheiterte er: OPT_NONE == 0, und die Normalisierung
# machte aus jeder 0 wieder O2.
cat > "$TMP/opt.lyx" <<'EOF'
fn main(): int64 {
  var a: int64 := 2 * 3 + 4;
  var b: int64 := a * 1;
  var c: int64 := b + 0;
  return c - 10;
}
EOF
# Gemessen wird gegen ein IR-Ziel: der x86-64-Schnellweg hat gar keinen
# Optimierer (#1371), dort KANN der Schalter nichts aendern. Auf der
# IR-Strecke muss er es — vor dem Fix war das Binary identisch, weil
# OPT_NONE (== 0) von der Normalisierung wieder auf O2 gehoben wurde.
"$LYXC" "$TMP/opt.lyx" --target=arm64 -o "$TMP/o_mit"  >/dev/null 2>&1
"$LYXC" "$TMP/opt.lyx" --target=arm64 --no-opt -o "$TMP/o_ohne" >/dev/null 2>&1
if [ ! -f "$TMP/o_mit" ] || [ ! -f "$TMP/o_ohne" ]; then
  no "--no-opt wirkt auf der IR-Strecke" "eine der beiden Uebersetzungen scheiterte"
elif cmp -s "$TMP/o_mit" "$TMP/o_ohne"; then
  no "--no-opt wirkt auf der IR-Strecke" "Binary identisch — Schalter ohne Wirkung"
else
  ok "--no-opt erzeugt auf der IR-Strecke ein anderes Binary"
fi

# Auf dem Schnellweg WIRKT der Schalter jetzt (#1371): die Vereinfachungen, die
# der Codegen beim Emittieren macht, haengen an der Stufe. Die frueher noetige
# Warnung ("bleibt wirkungslos") darf deshalb nicht mehr kommen — sie waere die
# Unwahrheit in der anderen Richtung.
wmsg="$("$LYXC" "$TMP/opt.lyx" --no-opt -o "$TMP/o_x86" 2>&1)"
case "$wmsg" in
  *"wirkungslos"*) no "x86-Schnellweg meldet --no-opt nicht mehr als wirkungslos" "$wmsg" ;;
  *) ok "x86-Schnellweg meldet --no-opt nicht mehr als wirkungslos" ;;
esac
# Und der Schalter aendert wirklich etwas — sonst waere die entfernte Warnung
# eine Beschoenigung. Gemessen wird gegen denselben Quelltext ohne Schalter.
"$LYXC" "$TMP/opt.lyx" -o "$TMP/o_x86_mit" >/dev/null 2>&1
if [ -x "$TMP/o_x86_mit" ] && [ -x "$TMP/o_x86" ]; then
  if cmp -s "$TMP/o_x86_mit" "$TMP/o_x86"; then
    no "--no-opt aendert das Binary auf dem Schnellweg" "byteweise identisch"
  else
    ok "--no-opt aendert das Binary auf dem Schnellweg"
  fi
else
  no "--no-opt aendert das Binary auf dem Schnellweg" "uebersetzt nicht"
fi
if [ -x "$TMP/o_x86" ]; then
  "$TMP/o_x86"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "mit --no-opt rechnet das Programm richtig"
  else no "mit --no-opt rechnet das Programm richtig" "rc=$rc statt 0"; fi
fi

# #1370: die noch offenen DREI sagen es, statt zu schweigen. --dump-relocs,
# --map-file und seit 1.1.6E auch --profile sind umgesetzt und muessen
# angenommen werden; geprueft wird ihr INHALT in
# tests/diagnose_schalter_test.sh bzw. tests/profile_schalter_test.sh.
for f in --emit-asm --dump-asm --asm-listing; do
  out="$("$LYXC" "$TMP/rek.lyx" "$f" -o "$TMP/r" 2>&1)"
  case "$out" in
    *"nicht umgesetzt"*"#1370"*) ok "$f wird als nicht umgesetzt gemeldet" ;;
    *) no "$f wird als nicht umgesetzt gemeldet" "$(echo "$out" | head -1)" ;;
  esac
done
for f in --dump-relocs --map-file --profile; do
  if "$LYXC" "$TMP/rek.lyx" "$f" -o "$TMP/r" >/dev/null 2>&1; then
    ok "$f wird angenommen (umgesetzt)"
  else
    no "$f wird angenommen (umgesetzt)" "$("$LYXC" "$TMP/rek.lyx" "$f" -o "$TMP/r" 2>&1 | head -1)"
  fi
done

# ===========================================================================
# #1360 — RISC-V
# ===========================================================================

# Geprueft wird mit einem Programm OHNE Array-Indizierung. Grund: seit #1339
# weist das riscv-Backend Opcodes, die es nicht behandelt, laut ab — und
# IRO_STORE_IDX (87) gehoert dazu. Vorher uebersetzte `a[0] := …` fuer dieses
# Ziel und der Speicherbefehl verschwand spurlos; dieser Test war also gruen,
# obwohl das erzeugte Binary unvollstaendig war. Hier geht es um #1360 (kommt
# ueberhaupt ein RISC-V-ELF heraus), nicht um den Umfang des Backends.
printf 'fn fak(n: int64): int64 { if n <= 1 { return 1; } return n * fak(n - 1); }\nfn main(): int64 { return fak(5); }\n' > "$TMP/rv.lyx"
for t in riscv riscv64 linux-riscv64; do
  rm -f "$TMP/rv"
  "$LYXC" "$TMP/rv.lyx" --target=$t -o "$TMP/rv" >/dev/null 2>&1
  if [ ! -f "$TMP/rv" ]; then
    no "--target=$t erzeugt ein Binary" "keine Ausgabedatei: $("$LYXC" "$TMP/rv.lyx" --target=$t -o "$TMP/rv" 2>&1 | head -1)"
  elif head -c 20 "$TMP/rv" | od -An -tu1 -j18 -N1 | grep -q ' 243'; then
    ok "--target=$t erzeugt ein RISC-V-ELF"
  else
    no "--target=$t erzeugt ein RISC-V-ELF" "e_machine ist nicht 243 (RISC-V)"
  fi
done

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
