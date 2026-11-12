#!/bin/bash
# #1864: @little_endian am Struct- und Klassenfeld.
#
# Der Name stand in der Attributliste des Parsers und im Hilfetext, wurde am
# Feld aber nie angenommen — `@little_endian a: int32;` gab einen Parse error.
# Ein Feld ausdruecklich auf Little-Endian zu setzen war damit nicht
# schreibbar, auch nicht als Gegenangabe neben @big_endian-Feldern im selben
# Protokollkopf.
#
# Geprueft werden beide Fundstellen (Struct UND Klasse) — es sind zwei
# getrennte Aufzaehlungen derselben Sache, und genau daran ist die Luecke
# entstanden. Dazu die Gegenprobe, dass sich die beiden Angaben am selben Feld
# ausschliessen.

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# --- Struct: beide Angaben nebeneinander ----------------------------------
cat > "$TMP/s.lyx" <<'EOF'
unit main;
import std.io;
type Kopf = struct {
  @little_endian laenge: int32;
  @big_endian    kennung: int32;
  rest: int32;
}
fn main(): int64 { PrintInt(sizeof(Kopf)); PrintLn(""c); return 0; }
EOF
if $LYXC "$TMP/s.lyx" -o "$TMP/s" > "$TMP/s.log" 2>&1; then
  GR=$("$TMP/s")
  if [ "$GR" = "12" ]; then
    ok "Struct: @little_endian neben @big_endian, sizeof = 12"
  else
    no "Struct: sizeof = $GR statt 12 — das Attribut aendert das Feldlayout"
  fi
else
  no "Struct: uebersetzt nicht ($(sed -n '2p' "$TMP/s.log"))"
fi

# --- Klasse: die zweite Fundstelle ----------------------------------------
cat > "$TMP/c.lyx" <<'EOF'
unit main;
import std.io;
type C = class {
  @little_endian x: int32;
  @big_endian    y: int32;
  fn Summe(): int64 { return 3; }
};
fn main(): int64 { var o: C := new C(); PrintInt(o.Summe()); PrintLn(""c); return 0; }
EOF
if $LYXC "$TMP/c.lyx" -o "$TMP/c" > "$TMP/c.log" 2>&1 && [ "$("$TMP/c")" = "3" ]; then
  ok "Klasse: @little_endian am Feld wird angenommen"
else
  no "Klasse: @little_endian am Feld ($(sed -n '2p' "$TMP/c.log"))"
fi

# --- Gegenprobe: @big_endian bleibt, wie es war ---------------------------
cat > "$TMP/b.lyx" <<'EOF'
unit main;
import std.io;
type B = struct { @big_endian a: int32; b: int32; }
fn main(): int64 { PrintInt(sizeof(B)); PrintLn(""c); return 0; }
EOF
if $LYXC "$TMP/b.lyx" -o "$TMP/b" > "$TMP/b.log" 2>&1 && [ "$("$TMP/b")" = "8" ]; then
  ok "@big_endian allein arbeitet weiter"
else
  no "@big_endian allein arbeitet weiter"
fi

# --- Beides am selben Feld muss LAUT scheitern ----------------------------
# Sonst waere unklar, welche Angabe gilt; ein stiller Vorrang der letzten
# waere genau die Sorte Default, die dieses Projekt sich abgewoehnt hat.
cat > "$TMP/w.lyx" <<'EOF'
unit main;
type W = struct { @big_endian @little_endian a: int32; }
fn main(): int64 { return 0; }
EOF
if $LYXC "$TMP/w.lyx" -o "$TMP/w" > "$TMP/w.log" 2>&1; then
  no "@big_endian @little_endian am selben Feld baut durch"
elif grep -q "am selben Feld" "$TMP/w.log"; then
  ok "@big_endian @little_endian am selben Feld wird abgewiesen"
else
  no "am selben Feld: scheitert, aber ohne die Begruendung ($(sed -n '2p' "$TMP/w.log"))"
fi

# --- Und ein erfundener Nachbarname bleibt ein Fehler ---------------------
cat > "$TMP/x.lyx" <<'EOF'
unit main;
type X = struct { @middle_endian a: int32; }
fn main(): int64 { return 0; }
EOF
if $LYXC "$TMP/x.lyx" -o "$TMP/x" > "$TMP/x.log" 2>&1; then
  no "@middle_endian wird angenommen — die Pruefung schlaegt zu weit aus"
else
  ok "erfundener Attributname bleibt ein Fehler"
fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: @little_endian am Feld"
exit 0
