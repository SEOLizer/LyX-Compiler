#!/usr/bin/env bash
# tests/vektor_feldbasis_2378_test.sh — ein FELD als Vektorbasis (#2378).
#
#   while (i < n) { poke8(ziel + i, peek8(self.buf + i)); i := i + 1; }
#
# Nach #2363 waren das die letzten 76 Ablehnungen LOAD_LEFT_BASE_NOT_INVARIANT
# im Selbstbau, und sie hatten eine einzige Ursache: ein Feld ist nicht
# invariant im Sinne von cg_exprRein. Es ist aber invariant GENUG, wenn man
# die eine Art, auf die es sich im Rumpf aendern kann, zur Laufzeit
# ausschliesst — die Ablage trifft den Objektspeicher. Dieselbe Pruefung
# benutzt #2350 Schritt 3b schon fuer die SCHRANKE; sie steht jetzt in
# cg_vmFeldAusserhalb und bedient beide Stellen.
#
# DREI ROLLEN, die der Test auseinanderhaelt:
#
#   feld8/16/32   Der Positivfall. Diese Faelle sind am Vorgaengerstand ROT:
#                 dort wird die Schleife mit LOAD_LEFT_BASE_NOT_INVARIANT
#                 abgewiesen, es gibt also kein `applied`.
#
#   nah_am_feld   Das Ziel liegt IM Objekt, aber hinter dem Feld. Die
#                 Waechterpruefung muss durchlassen — sonst waere der Gewinn
#                 an jeder Stelle verschenkt, an der ein Objekt in der Naehe
#                 des Ziels liegt.
#
#   waechter      Das Ziel UEBERDECKT das Feld. Dieser Fall ist am
#                 Vorgaengerstand gruen (dort wird gar nicht vektorisiert) und
#                 muss gruen BLEIBEN: er faellt genau dann um, wenn die
#                 Feldbasis ohne die Laufzeitpruefung angenommen wird.
#                 Erwartet wird die SKALARE Bedeutung.
#
# Der letzte Fall ist aufwendig gebaut, und das hat einen Grund: ein
# Zeigerfeld, das eine Schleife byteweise ueberschreibt, nimmt zwischendurch
# ungueltige Werte an, und dann stuerzen BEIDE Fassungen ab (gemessen: rc 139
# gegen rc 139, also keine Aussage). Damit der Zeiger durchgehend gueltig
# bleibt, liegt das zweite Ziel im selben Block (a + 256), und beide Puffer
# tragen in ihren ersten acht Bytes genau diese Adresse. Erst dadurch
# unterscheiden sich die beiden Fassungen in einem WERT statt in einem
# Absturz: skalar 52800 (die 200er aus b), vektorisiert ohne Pruefung 1848
# (die 7er aus a).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

lauf() { # $1 = Name, $2 = Schalter -> Ausgabe oder BAUFEHLER/ABSTURZ:rc
  ( ulimit -c 0; cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $2 "$TMP/$1.lyx" -o "$TMP/$1.x" >"$TMP/$1.blog" 2>&1 ) || { echo "BAUFEHLER"; return; }
  local out rc
  out=$( ulimit -c 0; cd "$TMP" && timeout 60 "$TMP/$1.x" 2>/dev/null | tr '\n' ' ' ); rc=$?
  if [ "$rc" -ne 0 ]; then echo "ABSTURZ:$rc"; return; fi
  echo "$out"
}

gruende() { # $1 = Name, $2 = Funktion
  ( cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" --compile-profile --compile-profile-level=detailed "$1.lyx" -o "$1.p" ) >"$TMP/$1.plog" 2>&1 || { echo "BAUFEHLER"; return; }
  python3 - "$TMP/$1.p.lyxc-profile.json" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get('decisions',[]):
    if x.get('pass_id')=='vectorize' and x.get('function')==sys.argv[2]:
        print('%s %s' % (x.get('outcome'), x.get('reason_code')))
PY
}

gleich() { # $1 = Name — vektorisiert == skalar
  local V S
  V="$(lauf "$1" "")"; S="$(lauf "$1" "-O0")"
  case "$V" in BAUFEHLER*) no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$1.blog")"; return 1;; esac
  if [ -n "$V" ] && [ "$V" = "$S" ]; then ok "$1 Wert stimmt ($V)"; return 0
  else no "$1 Wert" "vektorisiert '$V', skalar '$S'"; return 1; fi
}

# ── Positivfall je Breite ───────────────────────────────────────────────────
for paar in "8 1" "16 2" "32 4"; do
  set -- $paar
  w="$1"; bw="$2"
  if [ "$bw" = "1" ]; then idx="i"; else idx="i * $bw"; fi
  cat > "$TMP/feld$w.lyx" <<LYX
import std.io;
pub type Puffer = class {
  buf: int64;
  cap: int64;
  fn kopiereNach(ziel: int64, n: int64) {
    var i: int64 := 0;
    while (i < n) { poke${w}(ziel + ${idx}, peek${w}(self.buf + ${idx})); i := i + 1; }
  }
}
fn main(): int64 {
  var p: Puffer := new Puffer();
  p.buf := alloc(4096); p.cap := 4096;
  var ziel: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 4096) { poke8(p.buf + i, 0); poke8(ziel + i, 0); i := i + 1; }
  i := 0;
  while (i < 37) { poke${w}(p.buf + ${idx}, i + 1); i := i + 1; }
  p.kopiereNach(ziel, 37);
  var s: int64 := 0;
  var k: int64 := 0;
  while (k < 4096) { s := s + peek8(ziel + k) * (k + 1); k := k + 1; }
  PrintStr("PRUEFSUMME="c); PrintInt(s); PrintStrLn(""c);
  return 0;
}
LYX
  gleich "feld$w" || continue
  G="$(gruende "feld$w" kopiereNach)"
  if echo "$G" | grep -q "^applied "; then ok "feld${w}_vektorisiert"
  else no "feld${w}_vektorisiert" "kein applied: $(echo "$G" | tr '\n' '; ')"; fi
done

# ── Ziel im Objekt, aber hinter dem Feld: muss durchgelassen werden ─────────
cat > "$TMP/nah_am_feld.lyx" <<'LYX'
import std.io;
pub type Puffer = class {
  buf: int64;
  cap: int64;
  fuell: int64;
  fn kopiereNach(ziel: int64, n: int64) {
    var i: int64 := 0;
    while (i < n) { poke8(ziel + i, peek8(self.buf + i)); i := i + 1; }
  }
}
fn main(): int64 {
  var p: Puffer := new Puffer();
  p.buf := alloc(4096); p.cap := 4096; p.fuell := 0;
  var i: int64 := 0;
  while (i < 4096) { poke8(p.buf + i, (i & 63) + 1); i := i + 1; }
  var ziel: int64 := p as int64 + 24;
  p.kopiereNach(ziel, 37);
  var s: int64 := 0;
  var k: int64 := 0;
  while (k < 37) { s := s + peek8(ziel + k) * (k + 1); k := k + 1; }
  PrintStr("NAH="c); PrintInt(s); PrintStrLn(""c);
  return 0;
}
LYX
gleich nah_am_feld
G="$(gruende nah_am_feld kopiereNach)"
if echo "$G" | grep -q "^applied "; then ok "nah_am_feld_vektorisiert"
else no "nah_am_feld_vektorisiert" "kein applied: $(echo "$G" | tr '\n' '; ')"; fi

# ── Ziel ueberdeckt das Feld: die Laufzeitpruefung muss skalar schicken ─────
cat > "$TMP/waechter.lyx" <<'LYX'
import std.io;
pub type Puffer = class {
  buf: int64;
  cap: int64;
  fuell: int64;
  fn kopiereNach(ziel: int64, n: int64) {
    var i: int64 := 0;
    while (i < n) { poke8(ziel + i, peek8(self.buf + i)); i := i + 1; }
  }
}
fn main(): int64 {
  var a: int64 := alloc(8192);
  var i: int64 := 0;
  while (i < 8192) { poke8(a + i, 7); i := i + 1; }
  var b: int64 := a + 256;
  i := 256;
  while (i < 1024) { poke8(a + i, 200); i := i + 1; }
  poke64(a, b);
  poke64(b, b);
  var p: Puffer := new Puffer();
  p.buf := a; p.cap := 8192; p.fuell := 0;
  var r: int64 := p as int64;
  p.kopiereNach(r + 8, 24);
  var s: int64 := 0;
  var k: int64 := 8;
  while (k < 24) { s := s + peek8(r + 8 + k) * (k + 1); k := k + 1; }
  PrintStr("WAECHTER="c); PrintInt(s); PrintStrLn(""c);
  return 0;
}
LYX
W="$(lauf waechter "")"
S="$(lauf waechter "-O0")"
if [ "$W" = "$S" ] && [ "$W" = "WAECHTER=52800 " ]; then
  ok "waechter schickt skalar ($W)"
elif [ "$W" = "WAECHTER=1848 " ]; then
  no "waechter" "vektorisiert OHNE Laufzeitpruefung: '$W' statt der skalaren Bedeutung '$S'"
else
  no "waechter" "vektorisiert '$W', skalar '$S' (erwartet WAECHTER=52800)"
fi

# ── abgewiesen: ein schmales Feld laedt anders ──────────────────────────────
cat > "$TMP/schmal.lyx" <<'LYX'
import std.io;
pub type Puffer = class {
  buf: int32;
  cap: int64;
  fn kopiereNach(ziel: int64, n: int64) {
    var i: int64 := 0;
    while (i < n) { poke8(ziel + i, peek8(self.buf + i)); i := i + 1; }
  }
}
fn main(): int64 {
  var p: Puffer := new Puffer();
  var q: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 4096) { poke8(q + i, 3); i := i + 1; }
  p.buf := q as int32; p.cap := 4096;
  var ziel: int64 := alloc(4096);
  i := 0;
  while (i < 4096) { poke8(ziel + i, 0); i := i + 1; }
  PrintStrLn("FERTIG"c);
  return 0;
}
LYX
G="$(gruende schmal kopiereNach)"
case "$G" in
  BAUFEHLER*) ok "schmal (uebersetzt nicht — schmales Feld als Zeiger ist kein gueltiges Programm)";;
  *) if echo "$G" | grep -q "^applied "; then
       no "schmal abgewiesen" "ein schmales Feld wurde als Basis angenommen"
     else
       ok "schmal abgewiesen ($(echo "$G" | head -1))"
     fi;;
esac

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
