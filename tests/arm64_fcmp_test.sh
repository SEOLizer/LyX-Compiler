#!/usr/bin/env bash
# tests/arm64_fcmp_test.sh — #1339, Scheibe FCMP.
#
# Die FCMP-Familie (IRO_FCMP_EQ..GE, 40..45) behandelte KEIN IR-Backend.
# Auf arm64 erzeugte `if (a < b)` mit f64 deshalb gar keinen Vergleich: das
# Ergebnisregister behielt, was zufaellig darin stand. Ohne sie gibt es auf
# diesen Zielen keine Gleitkomma-Verzweigung — und der Dispatcher meldet es
# seit der Haertung von #1339 laut, statt still nichts zu tun.
#
# GEPRUEFT WERDEN DIE BYTES. Ein Test auf "uebersetzt ohne Fehler" waere
# aussagelos: seit dem Default-Zweig bricht der Lauf bei einem unbehandelten
# Opcode ab, und vor der Haertung waere er ebenfalls "erfolgreich"
# durchgelaufen — mit fehlendem Code. Das Issue verlangt deshalb ausdruecklich
# den Byte-Nachweis.
#
# Kodierung (ARM ARM):
#   FCMP Dn, Dm     0x1E602000 | (Dm << 16) | (Dn << 5)
#   CSET Xd, cond   = CSINC Xd, XZR, XZR, ~cond
#                   0x9A9F07E0 | ((~cond & 0xF) << 12) | Rd
# Fuer Gleitkomma sind die Bedingungen MI/LS/GT/GE (nicht LT/LE), damit ein
# Vergleich mit NaN falsch ergibt — bei ungeordneten Operanden setzt FCMP C
# und V, die vorzeichenlosen Bedingungen treffen dann nicht zu.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP kein python3 — die Bytes lassen sich nicht nachrechnen"
  echo "--- 0 PASS, 0 FAIL"; exit 0
fi

# Je Vergleich ein Programm, damit sich die erwartete Bedingung eindeutig
# zuordnen laesst.
einzeln() { # name, operator, inverse Bedingung
  cat > "$TMP/f.lyx" <<EOF
fn main(): int64 {
  var a: f64 := 2.5;
  var b: f64 := 4.0;
  if (a $2 b) { return 1; }
  return 0;
}
EOF
  rm -f "$TMP/f.bin"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" --target=arm64 -o "$TMP/f.bin" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/f.lyx" --target=arm64 -o "$TMP/f.bin" 2>&1 | grep -i -m1 'error\|unbehandelt')"
    return
  fi
  n_fcmp="$(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read()
print(d.count(struct.pack('<I', 0x1E602000 | (1<<16))))" "$TMP/f.bin")"
  n_cset="$(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read()
print(d.count(struct.pack('<I', 0x9A9F07E0 | ((int(sys.argv[2])&15)<<12))))" "$TMP/f.bin" "$3")"
  if [ "$n_fcmp" -ge 1 ] && [ "$n_cset" -ge 1 ]; then
    ok "$1"
  else
    no "$1" "FCMP=$n_fcmp CSET(inv=$3)=$n_cset"
  fi
}

einzeln "#1339: a < b  -> FCMP + CSET mi"  "<"  5
einzeln "#1339: a <= b -> FCMP + CSET ls"  "<=" 8
einzeln "#1339: a > b  -> FCMP + CSET gt"  ">"  13
einzeln "#1339: a >= b -> FCMP + CSET ge"  ">=" 11
einzeln "#1339: a == b -> FCMP + CSET eq"  "==" 1
einzeln "#1339: a != b -> FCMP + CSET ne"  "!=" 0

# Gegenprobe: der GANZZAHLvergleich benutzt weiterhin SUBS und die
# vorzeichenbehafteten Bedingungen — die neue Familie darf ihn nicht verdraengen.
cat > "$TMP/i.lyx" <<'EOF'
fn main(): int64 {
  var a: int64 := 2;
  var b: int64 := 4;
  if (a < b) { return 1; }
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/i.lyx" --target=arm64 -o "$TMP/i.bin" >/dev/null 2>&1; then
  erg="$(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read()
subs = d.count(struct.pack('<I', 0xEB01001F | (1<<16)))
csetlt = d.count(struct.pack('<I', 0x9A9F07E0 | (10<<12)))   # LT -> inv GE=10
fcmp = d.count(struct.pack('<I', 0x1E602000 | (1<<16)))
print('%d %d %d' % (subs, csetlt, fcmp))" "$TMP/i.bin")"
  s_subs="$(echo "$erg" | cut -d' ' -f1)"
  s_cset="$(echo "$erg" | cut -d' ' -f2)"
  s_fcmp="$(echo "$erg" | cut -d' ' -f3)"
  if [ "$s_subs" -ge 1 ] && [ "$s_cset" -ge 1 ] && [ "$s_fcmp" -eq 0 ]; then
    ok "#1339: Ganzzahlvergleich unveraendert (SUBS + CSET lt, kein FCMP)"
  else
    no "#1339: Ganzzahlvergleich unveraendert (SUBS + CSET lt, kein FCMP)" "SUBS=$s_subs CSET=$s_cset FCMP=$s_fcmp"
  fi
else
  no "#1339: Ganzzahlvergleich unveraendert (SUBS + CSET lt, kein FCMP)" "uebersetzt nicht"
fi

# Und die Gleitkomma-ARITHMETIK, die es vorher schon gab, bleibt heil.
cat > "$TMP/ar.lyx" <<'EOF'
fn main(): int64 {
  var a: f64 := 2.5;
  var b: f64 := 4.0;
  var c: f64 := a + b;
  if (c > b) { return 1; }
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/ar.lyx" --target=arm64 -o "$TMP/ar.bin" >/dev/null 2>&1; then
  n="$(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read()
fadd = d.count(struct.pack('<I', 0x1E602800 | (1<<16)))
fcmp = d.count(struct.pack('<I', 0x1E602000 | (1<<16)))
print('%d %d' % (fadd, fcmp))" "$TMP/ar.bin")"
  if [ "$(echo "$n" | cut -d' ' -f1)" -ge 1 ] && [ "$(echo "$n" | cut -d' ' -f2)" -ge 1 ]; then
    ok "#1339: FADD und FCMP im selben Programm"
  else
    no "#1339: FADD und FCMP im selben Programm" "$n"
  fi
else
  no "#1339: FADD und FCMP im selben Programm" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
