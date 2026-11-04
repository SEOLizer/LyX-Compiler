#!/usr/bin/env bash
# tests/vektor_schranke_feld_2350_test.sh — #2350 Schritt 3b: ein FELD als
# Schranke (`while (i < k.anzahl)`) darf vektorisiert werden, aber nur mit
# Laufzeitwache.
#
# Vorher verlangte `cg_vmErkennen` die Schranke als Local. Im Selbstbau waren
# das 547 Ablehnungen CONDITION_BOUND_FIELD — der groesste Einzelposten der
# Bedingungsformen.
#
# WARUM EINE WACHE NOETIG IST. Die skalare Fassung liest die Schranke bei
# JEDEM Durchlauf neu, die Vektorfassung genau einmal. Beides faellt
# auseinander, wenn der Rumpf das Feld ueberschreibt — und das kann er: die
# Ablage schreibt rohen Speicher, und ob der das Objekt trifft, steht zur
# Uebersetzungszeit nicht fest. Fuer die Local-Schranke gibt es dafuer
# POINTER_IS_BOUND; fuer ein Feld greift das nicht. Der Vektorweg prueft
# deshalb zur Laufzeit, ob die Feldadresse im beschriebenen Bereich liegt, und
# geht sonst skalar weiter.
#
# GEGENPROBE, gemessen auf 1.2.29E — ohne sie waere die Wache nur eine
# Behauptung. Derselbe Fall (`wache.lyx`, Ablage zeigt auf das Objekt selbst),
# einmal mit und einmal ohne Wache uebersetzt:
#
#   mit Wache  (= skalare Semantik):  i_danach = 9,  anzahl = 0
#   ohne Wache:                       i_danach = 0,  anzahl = 0
#
# Die 9 ist vollstaendig erklaerbar: der Vtable-Zeiger liegt auf Versatz 0,
# `anzahl` auf 8. Beim Durchlauf i = 8 wird das niederwertigste Byte genullt,
# aus 64 wird 0, und die Pruefung `9 < 0` bricht ab. Die 0 ohne Wache zeigt
# zusaetzlich einen zweiten Schaden: der Vektorweg zieht `i` hinter der
# Schleife auf die Schranke nach und LIEST SIE DAFUER ERNEUT — zu diesem
# Zeitpunkt ist das Feld schon genullt. Falsch ist also nicht nur die
# Durchlaufzahl, sondern auch der Zustand nach der Schleife.
#
# ZUR LESART VON `applied`: der Bericht meldet den Vektorweg auch dann als
# `applied`, wenn die Laufzeitweiche ihn verwirft — `applied` heisst
# "ausgegeben", nicht "ausgefuehrt". Deshalb prueft dieser Test die Wache am
# WERT und nicht am Bericht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# --------------------------------------------------- 1. der gewollte Fall
cat > "$TMP/fs.lyx" <<'EOF'
import std.io;

pub type Kasten = class {
  anzahl: int64;
  fn Init(n: int64) { self.anzahl := n; }
};

fn main(): int64 {
  var k: Kasten := new Kasten();
  k.Init(1000);                      // kein Vielfaches der Vektorbreite
  var a: int64 := alloc(1000);
  var b: int64 := alloc(1000);
  var c: int64 := alloc(1000);
  var i: int64 := 0;
  while (i < k.anzahl) { poke8(a + i, (i & 127)); i := i + 1; }
  i := 0;
  while (i < k.anzahl) { poke8(b + i, ((i * 3) & 127)); i := i + 1; }
  // Die Schleife, um die es geht: Schranke aus einem FELD.
  i := 0;
  while (i < k.anzahl) { poke8(c + i, peek8(a + i) + peek8(b + i)); i := i + 1; }
  var s: int64 := 0;
  i := 0;
  while (i < 1000) { s := s + peek8(c + i); i := i + 1; }
  PrintStr("summe="c);     PrintLn(s);
  PrintStr("erste="c);     PrintLn(peek8(c));
  PrintStr("letzte="c);    PrintLn(peek8(c + 999));
  PrintStr("i_danach="c);  PrintLn(i);
  return 0;
}
EOF

if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" fs.lyx -o fs ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
AUS="$( cd "$TMP" && timeout 60 ./fs 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc, Ausgabe: $(echo "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt und laeuft"

hol() { echo "$AUS" | sed -n "s/^$1=//p"; }
# Gegengerechnet: c[i] = (i & 127) + ((i*3) & 127), beide Summanden < 128.
ERW="$(awk 'BEGIN{s=0; for(i=0;i<1000;i++){s += (i%128) + ((i*3)%128)} print s}')"
ERW_L="$(awk 'BEGIN{print (999%128) + ((999*3)%128)}')"
for paar in "summe:$ERW" "erste:0" "letzte:$ERW_L" "i_danach:1000"; do
  k="${paar%%:*}"; e="${paar##*:}"; v="$(hol "$k")"
  if [ "$v" = "$e" ]; then ok "$k = $e"; else no "$k" "'$v' statt $e"; fi
done

PROF="$TMP/prof.json"
( cd "$TMP" && "$LYXC" --std-path="$ROOT" --compile-profile="$PROF" \
    --compile-profile-level=detailed fs.lyx -o fs_p ) >/dev/null 2>&1
if [ ! -s "$PROF" ]; then
  no "Profil" "kein Compilatprofil erzeugt"
else
  if grep -q '"outcome": *"applied"' "$PROF"; then
    ok "Vektorweg ausgegeben (outcome=applied)"
  else
    no "vektorisiert" "keine Entscheidung mit outcome=applied — die Feldschranke wurde nicht angenommen"
  fi
  if grep -q '"CONDITION_BOUND_FIELD"' "$PROF"; then
    no "Grund verschwunden" "CONDITION_BOUND_FIELD steht noch im Bericht"
  else
    ok "kein CONDITION_BOUND_FIELD mehr in diesem Programm"
  fi
fi

# ------------------------------------- 2. die Wache, am WERT nachgewiesen
cat > "$TMP/wache.lyx" <<'EOF'
import std.io;

pub type Kasten = class {
  anzahl: int64;
  fn Init(n: int64) { self.anzahl := n; }
};

fn main(): int64 {
  var k: Kasten := new Kasten();
  k.Init(64);
  var a: int64 := alloc(64);
  var b: int64 := alloc(64);
  var i: int64 := 0;
  while (i < 64) { poke8(a + i, 0); i := i + 1; }
  i := 0;
  while (i < 64) { poke8(b + i, 0); i := i + 1; }
  // Die Ablage zeigt auf das OBJEKT: sie ueberschreibt das Feld, das die
  // Bedingung liest. Richtig ist die skalare Semantik — Schranke je
  // Durchlauf neu lesen.
  var c: int64 := k as int64;
  i := 0;
  while (i < k.anzahl) { poke8(c + i, peek8(a + i) + peek8(b + i)); i := i + 1; }
  PrintStr("i_danach="c); PrintLn(i);
  PrintStr("anzahl="c);   PrintLn(k.anzahl);
  return 0;
}
EOF
if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" wache.lyx -o wache ) >"$TMP/bw.log" 2>&1; then
  no "Wachefall uebersetzt" "$(grep -v Copyright "$TMP/bw.log" | grep -m1 -iE 'error|lyxc:')"
else
  AUSW="$( cd "$TMP" && timeout 60 ./wache 2>&1 )"
  iw="$(echo "$AUSW" | sed -n 's/^i_danach=//p')"
  # 9, weil der Vtable-Zeiger auf Versatz 0 und `anzahl` auf 8 liegt: beim
  # Durchlauf i = 8 wird das niederwertigste Byte genullt, aus 64 wird 0,
  # und `9 < 0` bricht ab. Ohne Wache steht hier 0 (gemessen, siehe Kopf).
  if [ "$iw" = "9" ]; then
    ok "Wache greift: i_danach = 9, also skalare Semantik"
  else
    no "Wache" "i_danach = '$iw' statt 9 — bei 0 lief der Vektorweg trotz Ueberlappung mit dem Feld"
  fi
fi

# ----------------- 3. die engen Grenzen halten: schmales Feld bleibt abgelehnt
cat > "$TMP/schmal.lyx" <<'EOF'
import std.io;

pub type Schmal = class {
  anzahl: int32;
  fn Init(n: int64) { self.anzahl := n as int32; }
};

fn main(): int64 {
  var k: Schmal := new Schmal();
  k.Init(1000);
  var a: int64 := alloc(1000);
  var b: int64 := alloc(1000);
  var c: int64 := alloc(1000);
  var i: int64 := 0;
  // int32-Feld: laedt anders als ein 8-Byte-Feld (cg_emitNarrowLoadRax).
  // Der Vektorweg darf das nicht annehmen.
  while (i < k.anzahl) { poke8(c + i, peek8(a + i) + peek8(b + i)); i := i + 1; }
  PrintStr("i="c); PrintLn(i);
  return 0;
}
EOF
PROF3="$TMP/prof3.json"
if ( cd "$TMP" && "$LYXC" --std-path="$ROOT" --compile-profile="$PROF3" \
      --compile-profile-level=detailed schmal.lyx -o schmal ) >"$TMP/bs.log" 2>&1; then
  if grep -q 'BOUND_FIELD_NARROW_WIDTH' "$PROF3"; then
    ok "schmales Feld wird mit eigenem Grund abgelehnt (BOUND_FIELD_NARROW_WIDTH)"
  else
    no "Gegenprobe schmal" "ein int32-Feld als Schranke wurde nicht als BOUND_FIELD_NARROW_WIDTH abgelehnt — die Freigabe ist zu weit"
  fi
  AUSS="$( cd "$TMP" && timeout 60 ./schmal 2>&1 )"
  if [ "$(echo "$AUSS" | sed -n 's/^i=//p')" = "1000" ]; then
    ok "schmales Feld: Schleife laeuft skalar korrekt durch (i = 1000)"
  else
    no "schmales Feld" "i = '$(echo "$AUSS" | sed -n 's/^i=//p')' statt 1000"
  fi
else
  no "schmaler Fall uebersetzt" "$(grep -v Copyright "$TMP/bs.log" | grep -m1 -iE 'error|lyxc:')"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
