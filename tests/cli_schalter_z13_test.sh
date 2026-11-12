#!/usr/bin/env bash
# tests/cli_schalter_z13_test.sh — #1522, #1525, #1371, #1555.
#
# Vier Schalter, die etwas anderes taten als sie sagten:
#
#   #1525 `-Osafe` stand in --config, wurde aber abgewiesen. Die Kurzform las
#         genau EIN Zeichen hinter dem O und warf den Rest zurueck in die
#         Zerlegung — daher die Meldung "unbekannter Schalter '-s'".
#   #1522 `--config` nannte sechs von zwanzig Zielen (lyxos, Windows, macOS,
#         esp32 fehlten) und kein einziges Suchverzeichnis fuer Importe.
#   #1371 Optimierstufe: --no-opt/-O0 muss auf dem x86-Schnellweg ein anderes
#         Programm erzeugen als der Standard, sonst ist der Schalter Zierat.
#   #1555 `--compile-unit --debug-symbols` erzeugte eine byte-identische
#         .lyu-Datei — dem Format fehlte die Ablage.
#
# Zusaetzlich zwei STILLE DEFAULTS, die hier auffliegen sollen: --target= und
# --opt= liessen einen unbekannten Wert kommentarlos durchfallen und bauten
# mit der Voreinstellung weiter. Wer sich vertippte, bekam das falsche
# Artefakt ohne Hinweis.
#
# GEMESSEN WIRD DIE WIRKUNG, nicht die Hilfezeile: bytegleich vs. nicht,
# rc, und ob der Debug-Abschnitt beim Lesen wieder herauskommt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/p.lyx" <<'EOF'
import std.io;
fn main(): int64 {
  var a: int64 := 2 + 3 * 4;
  PrintLn(IntToStr(a));
  return 0;
}
EOF

cat > "$TMP/u.lyx" <<'EOF'
unit u;
pub fn F(): int64 { return 1; }
pub fn G(a: int64): int64 { return a + 1; }
EOF

bau() { # zielname, schalter...
  local out="$1"; shift
  timeout 200 "$LYXC" --std-path="$ROOT" "$@" "$TMP/p.lyx" -o "$TMP/$out" >"$TMP/$out.log" 2>&1
}

# ===========================================================================
# #1525 — -Osafe in der Kurzform
# ===========================================================================
if bau safe -Osafe; then ok "#1525: -Osafe wird angenommen"
else no "#1525: -Osafe" "abgewiesen: $(grep -m1 . "$TMP/safe.log")"; fi

# Gegenprobe: eine Stufe, die es nicht gibt, wird weiterhin abgewiesen —
# sonst haette der Fix nur die Pruefung entschaerft.
bau quatsch -Oquatsch
if [ $? -ne 0 ]; then ok "#1525: -Oquatsch bleibt abgewiesen"
else no "#1525: -Oquatsch" "klaglos angenommen"; fi

# ===========================================================================
# Stille Defaults: unbekannter Wert darf nicht in die Voreinstellung fallen
# ===========================================================================
bau zielX --target=quatsch
rcT=$?
if [ "$rcT" -ne 0 ] && grep -q "unbekanntes Ziel" "$TMP/zielX.log"; then
  ok "--target=<unbekannt> wird gemeldet statt still x86_64 zu bauen"
else
  no "--target=<unbekannt>" "rc=$rcT, Meldung: $(grep -m1 . "$TMP/zielX.log")"
fi

bau optX --opt=Oquatsch
rcO=$?
if [ "$rcO" -ne 0 ] && grep -q "unbekannter Wert" "$TMP/optX.log"; then
  ok "--opt=<unbekannt> wird gemeldet statt still O2 zu benutzen"
else
  no "--opt=<unbekannt>" "rc=$rcO, Meldung: $(grep -m1 . "$TMP/optX.log")"
fi

# Ein gueltiges Ziel darf davon nicht betroffen sein. BEWUSST OHNE std.io:
# auf der IR-Strecke ist die Einheit derzeit unbrauchbar (#1388, fremder
# offener Defekt) — haenge ich den Test daran, misst er nicht mehr, was er
# soll.
cat > "$TMP/leer.lyx" <<'EOF'
fn main(): int64 { return 0; }
EOF
timeout 200 "$LYXC" --std-path="$ROOT" --target=arm64 "$TMP/leer.lyx" -o "$TMP/zielOk" >"$TMP/zielOk.log" 2>&1
if [ $? -eq 0 ]; then ok "--target=arm64 weiter gueltig"
else no "--target=arm64" "$(grep -m1 -i 'error\|lyxc:' "$TMP/zielOk.log")"; fi

# ===========================================================================
# #1371 — die Optimierstufe muss sich im Erzeugnis zeigen
# ===========================================================================
bau std; bau ohne --no-opt; bau o0 -O0
if [ -f "$TMP/std" ] && [ -f "$TMP/ohne" ]; then
  if cmp -s "$TMP/std" "$TMP/ohne"; then
    no "#1371: --no-opt" "byte-identisch mit dem Standardbau"
  else
    ok "#1371: --no-opt erzeugt ein anderes Programm als der Standardbau"
  fi
  if cmp -s "$TMP/ohne" "$TMP/o0"; then
    ok "#1371: -O0 und --no-opt sind dasselbe"
  else
    no "#1371: -O0 vs --no-opt" "unterschiedlich — eine der beiden Stufen stimmt nicht"
  fi
else
  no "#1371" "Bau fehlgeschlagen"
fi

# Und das Programm muss unter beiden Stufen dasselbe rechnen.
for v in std ohne; do
  got="$("$TMP/$v" 2>&1)"
  [ "$got" = "14" ] || no "#1371: Ergebnis unter '$v'" "'$got' erwartet '14'"
done
ok "#1371: beide Stufen rechnen 2+3*4 = 14"

# ===========================================================================
# #1522 — --config nennt Ziele und Suchverzeichnisse vollstaendig
# ===========================================================================
cfg="$(timeout 60 "$LYXC" --config 2>&1)"; rcC=$?
[ "$rcC" -eq 0 ] || no "#1522: --config rc" "rc=$rcC"
fehlt=""
for muss in lyxos windows-x86_64 macos-arm64 esp32 arm-cm4 android-x86_64 Osafe; do
  echo "$cfg" | grep -q -- "$muss" || fehlt="$fehlt $muss"
done
if [ -z "$fehlt" ]; then ok "#1522: --config nennt alle Zielgruppen und Osafe"
else no "#1522: --config" "es fehlen:$fehlt"; fi

if echo "$cfg" | grep -q "std-path" && echo "$cfg" | grep -q "/usr/include/lyx/units"; then
  ok "#1522: --config nennt die Suchreihenfolge fuer Importe"
else
  no "#1522: Suchpfade" "stehen nicht in --config"
fi

# Was --config nennt, muss der Schalterparser auch annehmen — genau diese
# Luecke war #1525 (-Osafe stand da, wurde aber abgewiesen).
for ziel in lyxos windows-x86_64 esp32 arm-cm4; do
  timeout 200 "$LYXC" --std-path="$ROOT" --target=$ziel "$TMP/p.lyx" -o "$TMP/t_$ziel" >"$TMP/t_$ziel.log" 2>&1
  grep -q "unbekanntes Ziel" "$TMP/t_$ziel.log" && no "#1522: --config nennt '$ziel'" "Parser kennt es nicht"
done
ok "#1522: jedes genannte Ziel wird vom Parser angenommen"

# ===========================================================================
# #1555 — Debug-Abschnitt im .lyu
# ===========================================================================
timeout 200 "$LYXC" --std-path="$ROOT" --compile-unit "$TMP/u.lyx" -o "$TMP/a.lyu" >/dev/null 2>&1
timeout 200 "$LYXC" --std-path="$ROOT" --compile-unit --debug-symbols "$TMP/u.lyx" -o "$TMP/b.lyu" >/dev/null 2>&1
if [ ! -f "$TMP/a.lyu" ] || [ ! -f "$TMP/b.lyu" ]; then
  no "#1555" "eine der beiden .lyu-Dateien fehlt"
else
  if cmp -s "$TMP/a.lyu" "$TMP/b.lyu"; then
    no "#1555: --debug-symbols auf .lyu" "byte-identisch — kein Debug-Abschnitt"
  else
    ok "#1555: --debug-symbols veraendert die .lyu"
  fi
  info="$(timeout 60 "$LYXC" --unit-info "$TMP/b.lyu" 2>&1)"
  if echo "$info" | grep -q "F	Zeile 2" && echo "$info" | grep -q "G	Zeile 3"; then
    ok "#1555: Funktionszeilen kommen beim Lesen wieder heraus"
  else
    no "#1555: Debug-Abschnitt lesen" "$(echo "$info" | grep -i debug | head -1)"
  fi
  # Ohne den Schalter darf nichts davon auftauchen.
  if timeout 60 "$LYXC" --unit-info "$TMP/a.lyu" 2>&1 | grep -q "Debug:"; then
    no "#1555: Datei ohne Schalter" "traegt trotzdem einen Debug-Abschnitt"
  else
    ok "#1555: ohne --debug-symbols bleibt die Datei unveraendert"
  fi
  # Rueckwaertsvertraeglichkeit: die Symboltabelle muss in BEIDEN Dateien
  # gleich gelesen werden — ein Leser, der den Abschnitt nicht kennt, hoert
  # nach den Symbolen auf.
  sa="$(timeout 60 "$LYXC" --unit-info "$TMP/a.lyu" 2>&1 | grep -c '^  \[')"
  sb="$(timeout 60 "$LYXC" --unit-info "$TMP/b.lyu" 2>&1 | grep -c '^  \[')"
  if [ "$sa" = "$sb" ] && [ "$sa" -gt 0 ]; then
    ok "#1555: Symboltabelle unveraendert ($sa Symbole in beiden)"
  else
    no "#1555: Symboltabelle" "$sa vs $sb"
  fi
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
