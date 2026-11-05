#!/usr/bin/env bash
# tests/vektor_basis_ausdruck_2363_test.sh — #2363 Schritt 2: eine Basis, die
# ein schleifeninvarianter AUSDRUCK ist, wird vektorisiert.
#
# Vorher nahm der Erkenner als Basis nur einen Bezeichner mit Rahmenversatz an.
# `poke8(c + lenA + j, ...)` ist `((c + lenA) + j)` — der linke Summand ist
# kein Bezeichner, also fiel die Schleife mit STORE_BASE_NOT_LOCAL durch. Im
# Selbstbau von src/lyxc.lyx sind das 166 Ablehnungen; 120 davon kommen mit
# dieser Aenderung durch die Basispruefung.
#
# WAS DIESER TEST BEWEISEN MUSS, ist nicht „es uebersetzt", sondern dreierlei:
#
#   1. Der WERT stimmt. Verglichen wird gegen die skalare Rechnung derselben
#      Quelle (`--opt-level=0` schaltet die Vektorisierung ab), nicht gegen
#      eine von Hand ausgerechnete Zahl: so traegt der Vergleich auch die
#      Faelle, in denen ich mich beim Erwartungswert verrechnen koennte.
#   2. Die Schleife wird WIRKLICH vektorisiert — am Profil geprueft
#      (`--compile-profile-level=detailed`, sonst fehlt `applied`).
#   3. Eine Basis, die vom Zaehler, von der Schranke oder von einem Aufruf
#      abhaengt, wird ABGEWIESEN. Das ist die Pflichtgegenprobe: ein Erkenner,
#      der die Basis einfach vor die Schleife zieht, waere von Punkt 1 und 2
#      erfuellt und bei `c + j + j` still falsch.
#
# Nachbarelemente werden mitgeprueft (#2199: eine zu breite Ablage traf
# daneben), und n = 37 ist kein Vielfaches der Vektorbreite — der Restweg
# laeuft also mit.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# mach NAME BREITE ELEMENTBYTES BASISAUSDRUCK
# Der Basisausdruck steht an allen drei Zeigern (zwei Lesen, ein Schreiben) —
# eine Erweiterung, die nur die Schreibseite kennt, waere die halbe Umsetzung.
mach() {
  local name="$1" w="$2" bw="$3" basis="$4" idx
  if [ "$bw" = "1" ]; then idx="j"; else idx="j * $bw"; fi
  cat > "$TMP/$name.lyx" <<LYX
import std.io;
fn hilf(x: int64): int64 { return x + 1; }
fn main(): int64 {
  var n: int64 := 37;
  var lenA: int64 := 5;
  var a: int64 := alloc(4096);
  var b: int64 := alloc(4096);
  var c: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 4096) { poke8(a + i, 0); poke8(b + i, 0); poke8(c + i, 0); i := i + 1; }
  i := 0;
  while (i < n) { poke${w}(a + lenA + i * ${bw}, i + 1); poke${w}(b + lenA + i * ${bw}, 10); i := i + 1; }
  var j: int64 := 0;
  while (j < n) { poke${w}(${basis} + ${idx}, peek${w}(a + lenA + ${idx}) + peek${w}(b + lenA + ${idx})); j := j + 1; }
  var s: int64 := 0;
  j := 0;
  while (j < 4096) { s := s + peek8(c + j) * (j + 1); j := j + 1; }
  PrintStr("PRUEFSUMME="c); PrintInt(s); PrintStrLn(""c);
  return 0;
}
LYX
}

# Die Pruefsumme wiegt jedes Byte des GANZEN Zielpuffers mit seiner Stelle.
# Damit faellt auch eine Ablage daneben auf — eine blosse Summe ueber die n
# Zielelemente waere dafuer blind (#2199).
lauf() { # $1 = Name, $2 = zusaetzliche Schalter
  ( ulimit -c 0; cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $2 "$TMP/$1.lyx" -o "$TMP/$1.x" >"$TMP/$1.blog" 2>&1 ) || { echo "BAUFEHLER"; return; }
  ( ulimit -c 0; cd "$TMP" && timeout 60 "$TMP/$1.x" 2>/dev/null | tr '\n' ' ' )
}

gruende() { # $1 = Name — Zeilen "outcome reason count" des Vektorisierers
  ( cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" --compile-profile --compile-profile-level=detailed "$1.lyx" -o "$1.p" ) >"$TMP/$1.plog" 2>&1 || { echo "BAUFEHLER"; return; }
  python3 - "$TMP/$1.p.lyxc-profile.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get('decision_summary',[]):
    if x.get('pass_id')=='vectorize':
        print('%s %s %d' % (x.get('outcome'), x.get('reason_code'), x.get('count')))
PY
}

# ── angenommen: invariante Ausdrucksbasis, je Breite ────────────────────────
for paar in "8 1" "16 2" "32 4"; do
  set -- $paar
  w="$1"; bw="$2"
  mach "ja$w" "$w" "$bw" 'c + lenA'
  VEK="$(lauf "ja$w" "")"
  SKA="$(lauf "ja$w" "-O0")"
  if [ "$VEK" = "BAUFEHLER" ] || [ "$SKA" = "BAUFEHLER" ]; then
    no "int${w}_wert" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/ja$w.blog")"
  elif [ -n "$VEK" ] && [ "$VEK" = "$SKA" ]; then
    ok "int${w}_wert stimmt mit der skalaren Rechnung ($VEK)"
  else
    no "int${w}_wert" "vektorisiert '$VEK', skalar '$SKA'"
  fi
  G="$(gruende "ja$w")"
  if echo "$G" | grep -q "^applied "; then
    ok "int${w}_vektorisiert ($(echo "$G" | grep '^applied ' | head -1))"
  else
    no "int${w}_vektorisiert" "kein applied im Profil: $(echo "$G" | tr '\n' '; ')"
  fi
done

# ── abgewiesen: Basis haengt an etwas, das die Schleife fortschaltet ────────
# Je Fall zusaetzlich der WERT gegen die skalare Rechnung: eine falsche
# Annahme waere hier nicht nur langsam, sondern falsch.
gegen() { # $1 = Name, $2 = Basisausdruck
  mach "$1" 8 1 "$2"
  local VEK SKA G
  VEK="$(lauf "$1" "")"; SKA="$(lauf "$1" "-O0")"
  if [ "$VEK" = "BAUFEHLER" ] || [ "$SKA" = "BAUFEHLER" ]; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$1.blog")"; return
  fi
  if [ -n "$VEK" ] && [ "$VEK" = "$SKA" ]; then ok "$1 Wert stimmt ($VEK)"
  else no "$1 Wert" "'$VEK' gegen skalar '$SKA'"; fi
  G="$(gruende "$1")"
  if echo "$G" | grep -q "^applied "; then
    no "$1 abgewiesen" "wurde vektorisiert, obwohl die Basis nicht invariant ist"
  else
    ok "$1 abgewiesen ($(echo "$G" | grep -oE 'STORE_BASE_[A-Z_]+' | head -1))"
  fi
}
gegen zaehler_in_basis  'c + j'          # haengt am Zaehler
gegen schranke_in_basis 'c + n'          # haengt an der Schranke
gegen aufruf_in_basis   'c + hilf(lenA)' # Aufruf: nicht rein, Aliasing unbekannt

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
