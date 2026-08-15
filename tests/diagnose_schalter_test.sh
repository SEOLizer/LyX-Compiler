#!/usr/bin/env bash
# tests/diagnose_schalter_test.sh — #1370 (zwei von sechs Schaltern).
#
# `--dump-relocs` und `--map-file` setzten ein Feld, das anschliessend niemand
# las. Seit #1098 wurden sie laut abgewiesen statt still angenommen; jetzt
# tun sie, was ihr Name sagt.
#
# Die Daten lagen die ganze Zeit bereit: der x86-Codegen fuehrt seine
# Patch-Tabelle (jede Stelle, deren Zieladresse erst nach dem Erzeugen
# feststeht) und seine Markentabelle (Name, Codeoffset, Quellzeile). Gefehlt
# hat nur die Ausgabe. Der alte Platzhalter behauptete sogar das Gegenteil:
# "No relocations to dump (static binary)".
#
# GEPRUEFT WIRD DER INHALT, nicht die blosse Anwesenheit einer Ausgabe:
# bekannte Symbole muessen mit plausibler Adresse auftauchen, und die
# Relokation eines Aufrufs muss den gerufenen Namen nennen. Eine Pruefung auf
# "schreibt irgendetwas" waere auch mit einer Kopfzeile allein gruen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'EOF'
import std.io;
fn zweimal(a: int64): int64 { return a * 2; }
fn dreimal(a: int64): int64 { return a * 3; }
fn main(): int64 {
  PrintLn(IntToStr(zweimal(21)));
  PrintLn(IntToStr(dreimal(14)));
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
  no "Testprogramm uebersetzt" "uebersetzt nicht"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi

# ===========================================================================
# --dump-relocs
# ===========================================================================

"$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" --dump-relocs > "$TMP/rel.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  no "#1370: --dump-relocs wird angenommen" "rc=$rc: $(grep -i 'nicht umgesetzt' "$TMP/rel.txt" | head -1)"
else
  ok "#1370: --dump-relocs wird angenommen"
fi

if grep -q "RELOCATION TABLE" "$TMP/rel.txt"; then
  ok "#1370: --dump-relocs gibt die Tabelle aus"
else
  no "#1370: --dump-relocs gibt die Tabelle aus" "kein Kopf gefunden"
fi

# Der alte Platzhalter behauptete, es gebe nichts zu zeigen.
if grep -q "No relocations to dump" "$TMP/rel.txt"; then
  no "#1370: kein Platzhaltertext mehr" "der alte Text steht noch da"
else
  ok "#1370: kein Platzhaltertext mehr"
fi

# Inhalt: der Aufruf von main ist eine CALL-Relokation und muss namentlich
# dastehen. Die Zahl der Eintraege muss ausserdem groesser als null sein.
if grep -qE "CALL +main" "$TMP/rel.txt"; then
  ok "#1370: die CALL-Relokation nennt das Ziel beim Namen"
else
  no "#1370: die CALL-Relokation nennt das Ziel beim Namen" "$(grep -c CALL "$TMP/rel.txt") CALL-Zeilen"
fi

anz="$(grep -cE '^  0x' "$TMP/rel.txt")"
if [ "$anz" -ge 3 ]; then
  ok "#1370: mehrere Eintraege mit Offset ($anz)"
else
  no "#1370: mehrere Eintraege mit Offset" "nur $anz"
fi

# ===========================================================================
# --map-file
# ===========================================================================

rm -f "$TMP/p.map"
"$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" --map-file > "$TMP/mapout.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  no "#1370: --map-file wird angenommen" "rc=$rc: $(grep -i 'nicht umgesetzt' "$TMP/mapout.txt" | head -1)"
else
  ok "#1370: --map-file wird angenommen"
fi

if [ -s "$TMP/p.map" ]; then
  ok "#1370: die Karte liegt neben dem Ziel"
else
  no "#1370: die Karte liegt neben dem Ziel" "keine oder leere Datei"
fi

if [ -s "$TMP/p.map" ]; then
  # Sektionen mit Laengen
  if grep -qE '^  \.text   0x[0-9a-f]{16}  [0-9]+' "$TMP/p.map" && \
     grep -qE '^  \.data   0x[0-9a-f]{16}  [0-9]+' "$TMP/p.map"; then
    ok "#1370: Sektionen mit Adresse und Laenge"
  else
    no "#1370: Sektionen mit Adresse und Laenge" "$(grep -A3 Sektionen "$TMP/p.map" | tr '\n' '|')"
  fi

  # Die beiden eigenen Funktionen samt Quellzeile (2 und 3).
  if grep -qE '^  0x[0-9a-f]{16}  0x[0-9a-f]{16}  2  zweimal$' "$TMP/p.map" && \
     grep -qE '^  0x[0-9a-f]{16}  0x[0-9a-f]{16}  3  dreimal$' "$TMP/p.map"; then
    ok "#1370: eigene Funktionen mit Adresse und Quellzeile"
  else
    no "#1370: eigene Funktionen mit Adresse und Quellzeile" "$(grep -E 'zweimal|dreimal' "$TMP/p.map" | tr '\n' '|')"
  fi

  if grep -qE '^  0x[0-9a-f]{16}  0x[0-9a-f]{16}  [0-9]+  main$' "$TMP/p.map"; then
    ok "#1370: main steht in der Karte"
  else
    no "#1370: main steht in der Karte" "nicht gefunden"
  fi

  # Nach Adresse sortiert: die Offsetspalte muss monoton steigen.
  unsortiert="$(awk '/^  0x/ { print strtonum($2) }' "$TMP/p.map" | awk 'NR>1 && $1 < vor { print "abfall bei " NR } { vor = $1 }' | head -1)"
  if [ -z "$unsortiert" ]; then
    ok "#1370: Symbole nach Adresse sortiert"
  else
    no "#1370: Symbole nach Adresse sortiert" "$unsortiert"
  fi
fi

# ===========================================================================
# Gegenprobe: die vier noch offenen Schalter weisen weiterhin laut ab
# ===========================================================================
# Ein still angenommener Schalter ist schlimmer als ein abgewiesener (#1098).
# Solange sie nichts tun, muessen sie das sagen.

offen_ok=1
for sch in --emit-asm --dump-asm --asm-listing --profile; do
  if "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p2" "$sch" >/dev/null 2>&1; then
    offen_ok=0
    echo "  ($sch wird angenommen, obwohl nicht umgesetzt)"
  fi
done
if [ "$offen_ok" -eq 1 ]; then
  ok "#1370: die vier offenen Schalter weisen weiterhin ab"
else
  no "#1370: die vier offenen Schalter weisen weiterhin ab" "siehe oben"
fi

# Und ohne Schalter darf nichts davon erscheinen.
"$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p3" > "$TMP/ohne.txt" 2>&1
if grep -q "RELOCATION TABLE" "$TMP/ohne.txt" || [ -e "$TMP/p3.map" ]; then
  no "#1370: ohne Schalter keine Zusatzausgabe" "es kam etwas"
else
  ok "#1370: ohne Schalter keine Zusatzausgabe"
fi

# ===========================================================================
# #1371 — die Optimierstufe wirkt auf dem x86-Schnellweg
# ===========================================================================
#
# Der Schnellweg erzeugt Maschinencode unmittelbar aus dem AST, die IR-Strecke
# mit IROptimize wird uebersprungen. `cg.optLevel` wurde gesetzt und nirgends
# gelesen — `--no-opt` erzeugte byteweise dasselbe Binary. Jetzt haengen die
# Vereinfachungen, die der Codegen ohnehin beim Emittieren macht
# (Konstantenfaltung, tote Zweige), an dieser Stufe.
#
# GEPRUEFT WIRD BEIDES: dass der Schalter etwas aendert UND dass das Programm
# in beiden Faellen dasselbe rechnet. Ein Test auf "die Binaries sind
# verschieden" allein wuerde auch eine kaputte Optimierung durchwinken.

cat > "$TMP/o.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var a: int64 := 6 * 7 + 100 - 50;
  if (1 == 1) { PrintLn(IntToStr(a)); } else { PrintLn("nie"); }
  return 0;
}
EOF

if "$LYXC" --std-path="$ROOT" "$TMP/o.lyx" -o "$TMP/o_mit" >/dev/null 2>&1 &&    "$LYXC" --std-path="$ROOT" "$TMP/o.lyx" -o "$TMP/o_ohne" --no-opt >/dev/null 2>&1; then
  if cmp -s "$TMP/o_mit" "$TMP/o_ohne"; then
    no "#1371: --no-opt aendert das Ergebnis des x86-Wegs" "byteweise identisch"
  else
    ok "#1371: --no-opt aendert das Ergebnis des x86-Wegs"
  fi
  a="$(timeout 30 "$TMP/o_mit" 2>&1)"
  b="$(timeout 30 "$TMP/o_ohne" 2>&1)"
  if [ "$a" = "92" ] && [ "$b" = "92" ]; then
    ok "#1371: beide Fassungen rechnen dasselbe"
  else
    no "#1371: beide Fassungen rechnen dasselbe" "mit='$a' ohne='$b' erwartet 92"
  fi
  # Ohne Faltung muss der Code laenger sein, nicht kuerzer — sonst haette der
  # Schalter die Bedeutung verkehrt herum.
  gm="$(stat -c %s "$TMP/o_mit")"; go="$(stat -c %s "$TMP/o_ohne")"
  if [ "$go" -gt "$gm" ]; then
    ok "#1371: ohne Optimierung wird der Code laenger ($gm -> $go)"
  else
    no "#1371: ohne Optimierung wird der Code laenger" "mit=$gm ohne=$go"
  fi
else
  no "#1371: --no-opt aendert das Ergebnis des x86-Wegs" "uebersetzt nicht"
  no "#1371: beide Fassungen rechnen dasselbe" "uebersetzt nicht"
  no "#1371: ohne Optimierung wird der Code laenger" "uebersetzt nicht"
fi

# Die Warnung von frueher ("bleiben wirkungslos") darf nicht mehr kommen.
"$LYXC" --std-path="$ROOT" "$TMP/o.lyx" -o "$TMP/o2" --no-opt > "$TMP/warn.txt" 2>&1
if grep -q "wirkungslos" "$TMP/warn.txt"; then
  no "#1371: keine Wirkungslos-Warnung mehr" "$(grep wirkungslos "$TMP/warn.txt" | head -1)"
else
  ok "#1371: keine Wirkungslos-Warnung mehr"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
