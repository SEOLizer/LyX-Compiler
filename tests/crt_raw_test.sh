#!/bin/bash
# #1874: std.crt_raw — SetRawMode und KeyPressed waren Platzhalter (-1/false).
#
# Gemessen wird die WIRKUNG, nicht der Rueckgabewert: ob eine Taste OHNE
# Eingabetaste ankommt. Ein Test, der nur `SetRawMode(true) == 0` prueft, waere
# auch von einer Fassung erfuellt, die nichts umschaltet und 0 zurueckgibt.
#
# Der Rohmodus braucht ein Terminal. Ohne eines (Pipe) muss die Funktion das
# SAGEN — der ehrliche Fehlerwert ist der zweite Teil der Aussage.

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS + 1)); }
no()  { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

cat > "$TMP/r.lyx" <<'EOF'
unit main;
import std.io;
import std.crt_raw;
fn main(): int64 {
  PrintStr("raw="c); PrintInt(SetRawMode(true)); PrintLn(""c);
  PrintStr("taste="c); if (KeyPressed()) { PrintStr("ja"c); } else { PrintStr("nein"c); } PrintLn(""c);
  PrintStr("zurueck="c); PrintInt(SetRawMode(false)); PrintLn(""c);
  return 0;
}
EOF

cat > "$TMP/k.lyx" <<'EOF'
unit main;
import std.io;
import std.crt_raw;
fn main(): int64 {
  if (SetRawMode(true) != 0) { PrintStrLn("kein Terminal"c); return 2; }
  var k: int64 := ReadKeyRaw();
  SetRawMode(false);
  PrintStr("Taste="c); PrintInt(k); PrintLn(""c);
  return 0;
}
EOF

for f in r k; do
  if ! $LYXC "$TMP/$f.lyx" -o "$TMP/$f" > "$TMP/$f.log" 2>&1; then
    echo "FAIL: $f.lyx uebersetzt nicht"; sed -n '2,4p' "$TMP/$f.log"; exit 1
  fi
done
ok "std.crt_raw uebersetzt"

# --- ohne Terminal: der Fehler muss gemeldet werden -----------------------
AUS=$("$TMP/r" < /dev/null 2>&1)
if echo "$AUS" | grep -q "raw=-1"; then
  ok "ohne Terminal meldet SetRawMode -1"
else
  no "ohne Terminal meldet SetRawMode -1 (erhalten: $(echo "$AUS" | head -1))"
fi
if echo "$AUS" | grep -q "zurueck=0"; then
  ok "Zuruecknehmen ohne vorheriges Einschalten ist kein Fehler"
else
  no "Zuruecknehmen ohne vorheriges Einschalten meldet einen Fehler"
fi

# --- im Pseudoterminal: die eigentliche Aussage ---------------------------
if ! command -v script > /dev/null 2>&1; then
  echo "UEBERSPRUNGEN: 'script' fehlt — der Rohmodus braucht ein Terminal."
  echo "  Die Pruefungen ohne Terminal liefen."
else
  AUS=$(script -qec "$TMP/r" /dev/null < /dev/null 2>&1)
  if echo "$AUS" | grep -q "raw=0"; then
    ok "im Terminal schaltet SetRawMode um"
  else
    no "im Terminal schaltet SetRawMode um (erhalten: $(echo "$AUS" | tr -d '\r' | head -1))"
  fi
  if echo "$AUS" | grep -q "taste=nein"; then
    ok "KeyPressed meldet ohne Eingabe nichts"
  else
    no "KeyPressed meldet ohne Eingabe eine Taste"
  fi

  # Die Wirkung: ein Zeichen OHNE Eingabetaste kommt an. Zeilengepuffert
  # (der Zustand vor #1874) blockiert ReadKeyRaw hier bis zum Dateiende.
  AUS=$(printf 'A' | timeout 20 script -qec "$TMP/k" /dev/null 2>&1 | tr -d '\r')
  if echo "$AUS" | grep -q "Taste=65"; then
    ok "Taste kommt ohne Eingabetaste an (A = 65)"
  else
    no "Taste kommt ohne Eingabetaste an — erhalten: $(echo "$AUS" | tail -1)"
  fi
fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: std.crt_raw Rohmodus"
exit 0
