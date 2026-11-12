#!/usr/bin/env bash
# tests/vektor_gruende_2363_test.sh — #2363 Schritt 1: die vier Sammelkategorien
# des Vektorisierers aufgeschluesselt.
#
# In diesem Themenkreis sind die Ablehnungsgruende die MESSGROESSE (#2350):
# ohne sie ist nicht entscheidbar, welcher Eingriff wie viel bringt. Vier
# Gruende waren Sammelkategorien und trugen im Selbstbau von src/lyxc.lyx
# zusammen 1187 Ablehnungen, ohne zu sagen, welche Form dastand:
#
#   STORE_WIDTH_UNKNOWN        314   HELPER_INIT_NOT_BINOP   323
#   HELPER_INIT_NOT_MUL        383   STORE_INDEX_FORM_MISMATCH 167
#
# Dieser Test prueft, dass jeder neue Grund GENAU DANN erscheint, wenn die
# zugehoerige Form dasteht. Geprueft wird am Profil (`--compile-profile`), das
# ist das Erzeugnis dieser Aenderung.
#
# BEIDE SEITEN (Lehre aus #1823): es genuegt nicht, dass der erwartete Code
# auftaucht. Zusaetzlich wird geprueft, dass die alten Sammelnamen NICHT mehr
# vorkommen — sonst waere offen, ob daneben noch ein Sammelzweig steht.
#
# Und ein POSITIVFALL ist dabei: eine Schleife, die weiter vektorisiert wird.
# Ein Test, der nur Ablehnungen prueft, waere auch von einem Erkenner erfuellt,
# der gar nichts mehr annimmt.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# Je Fall ein eigenes Programm: zwei Formen in einer Datei lassen nicht
# erkennen, welche Schleife welchen Grund erzeugt hat.
mach() { # $1 = Name, $2 = Rumpf der Schleife (mit i als Zaehler)
  cat > "$TMP/$1.lyx" <<EOF
import std.io;

fn hilf(x: int64): int64 { return x + 1; }

fn main(): int64 {
  var n: int64 := 37;
  var c: int64 := alloc(512);
  var k: int64 := 8;
  var i: int64 := 0;
$2
  PrintStrLn("FERTIG"c);
  return 0;
}
EOF
}

# Liefert die Gruende des Vektorisierers aus dem Profil, einer je Zeile.
gruende() { # $1 = Name
  ( cd "$TMP" && "$LYXC" --std-path="$ROOT" --compile-profile --compile-profile-level=detailed "$1.lyx" -o "$1" ) >"$TMP/$1.blog" 2>&1 || { echo "BAUFEHLER"; return; }
  python3 - "$TMP/$1.lyxc-profile.json" "$1.lyx" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
# NUR Entscheidungen aus der eigenen Quelldatei. decision_summary zaehlt die
# GANZE Uebersetzung, also auch die importierten Einheiten -- seit #2375 wird
# eine Kopierschleife in std/io.lyx (ReadLine) vektorisiert, womit jedes
# Programm ein `applied` enthaelt und jede Gegenprobe stumm gruen waere.
eigen = sys.argv[2]
for x in d.get('decisions',[]):
    if x.get('pass_id')!='vectorize': continue
    f = (x.get('location') or {}).get('file') or ''
    if f.endswith(eigen):
        print('%s %s' % (x.get('outcome'), x.get('reason_code')))
PY
}

pruefe() { # $1 = Name, $2 = erwarteter Grund, $3 = Rumpf
  mach "$1" "$3"
  G="$(gruende "$1")"
  if echo "$G" | grep -q BAUFEHLER; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$1.blog")"
    return
  fi
  if echo "$G" | grep -qx "rejected $2"; then
    ok "$1 -> $2"
  else
    no "$1" "erwartet '$2', Profil nennt: $(echo "$G" | tr '\n' '; ')"
  fi
  # Gegenprobe: kein alter Sammelname mehr.
  for alt in STORE_WIDTH_UNKNOWN HELPER_INIT_NOT_MUL HELPER_INIT_NOT_BINOP STORE_INDEX_FORM_MISMATCH; do
    if echo "$G" | grep -qx "rejected $alt"; then no "$1/Sammelname" "$alt steht noch im Profil"; fi
  done
}

# ── STORE_WIDTH_* ────────────────────────────────────────────────────────
pruefe poke64 STORE_WIDTH_POKE64 '  while (i < n) { poke64(c + i * 8, i); i := i + 1; }'
pruefe kein_poke STORE_WIDTH_NOT_POKE '  while (i < n) { hilf(i); i := i + 1; }'

# ── STORE_INDEX_* / STORE_BASE_* ─────────────────────────────────────────
# `c + i + i` ist `((c + i) + i)`: der linke Summand ist kein Bezeichner mehr
# UND haengt am Zaehler.
#
# Hier stand bis Schritt 2 von #2363 `c + k + i`, also eine Basis, die nur
# kein Bezeichner war. Schritt 2 nimmt diese Form an (`cg_vmBasisKnoten`), der
# Fall waere also rot geworden — ein Test darf nicht voraussetzen, dass eine
# Luecke offen bleibt. Der Zaehler in der Basis bleibt abgelehnt, und zwar
# begruendet: eine Basis, die sich je Durchlauf aendert, darf nicht vor die
# Schleife gezogen werden.
pruefe basis_summe STORE_BASE_NOT_LOCAL '  while (i < n) { poke8(c + i + i, i); i := i + 1; }'
# poke16 mit nacktem Zaehler: Schrittweite 1 Byte bei 2 Byte Ablage.
pruefe index_nackt STORE_INDEX_PLAIN_LOOP_VAR '  while (i < n) { poke16(c + i, i); i := i + 1; }'

# ── HELPER_INIT_* (Knotenart) ────────────────────────────────────────────
pruefe helfer_aufruf HELPER_INIT_CALL '  while (i < n) { var o: int64 := hilf(i); poke8(c + o, i); i := i + 1; }'
pruefe helfer_literal HELPER_INIT_LITERAL '  while (i < n) { var o: int64 := 5; poke8(c + o, i); i := i + 1; }'
pruefe helfer_ident HELPER_INIT_IDENT '  while (i < n) { var o: int64 := k; poke8(c + o, i); i := i + 1; }'

# ── HELPER_INIT_OP_* (Operator) ──────────────────────────────────────────
pruefe helfer_plus HELPER_INIT_OP_PLUS '  while (i < n) { var o: int64 := i + 1; poke8(c + o, i); i := i + 1; }'
pruefe helfer_minus HELPER_INIT_OP_MINUS '  while (i < n) { var o: int64 := i - 1; poke8(c + o, i); i := i + 1; }'
pruefe helfer_shl HELPER_INIT_OP_SHL '  while (i < n) { var o: int64 := i << 1; poke8(c + o, i); i := i + 1; }'

# ── POSITIVFALL: wird weiter angenommen ──────────────────────────────────
mach positiv '  var a: int64 := alloc(512);
  var b: int64 := alloc(512);
  while (i < n) { poke8(c + i, peek8(a + i) + peek8(b + i)); i := i + 1; }'
G="$(gruende positiv)"
if echo "$G" | grep -q "^applied "; then
  ok "Positivfall wird weiter vektorisiert ($(echo "$G" | grep '^applied ' | head -1))"
else
  no "Positivfall" "kein 'applied' im Profil; die Aufschluesselung hat den Erkenner veraendert. Profil: $(echo "$G" | tr '\n' '; ')"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
