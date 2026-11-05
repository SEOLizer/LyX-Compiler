#!/usr/bin/env bash
# tests/vektor_zeigerbasis_2363_test.sh — eine Basis aus einem ZEIGER oder
# einer UMDEUTUNG wird als schleifeninvariant erkannt (#2363, Rest).
#
# Nach Schritt 2 blieben 117 Ablehnungen LOAD_LEFT_BASE_NOT_INVARIANT: die
# Schreibseite und der Wert waren in Ordnung, nur die Leseadresse fiel durch.
# Zwei Formen steckten dahinter, und beide kommen im Bestand haeufig vor:
#
#   peek8(src + start + i)          — `src` ist pchar, nicht ganzzahlig
#   peek8((clsP as int64) + i)      — eine Umdeutung als Basis
#
# `cg_exprRein` liess als Local nur ganzzahlige Typen zu und kannte CGN_CAST
# nicht. Beides ist jetzt zugelassen, eng gefasst: `pchar` als Typ, und als
# Ziel einer Umdeutung nur `int64` und `pchar` — beide 64 Bit, die Umdeutung
# ist dort wertgleich.
#
# WAS DIESER TEST ZUSAETZLICH SICHERT: die Umdeutung musste in ZWEI
# Aufzaehlungen nachgezogen werden, in `cg_exprRein` und in
# `cg_vmOhneZaehler`. Nach der ersten allein bewegte sich GEMESSEN nichts
# (1 Stelle von 117). Der Fall `cast_am_zaehler` unten haelt beide Stellen
# zusammen: er ist nur dann richtig abgelehnt, wenn cg_vmOhneZaehler die
# Umdeutung betritt, statt sie pauschal abzulehnen.
#
# Geprueft wird der WERT gegen die skalare Rechnung derselben Quelle (-O0),
# nicht gegen eine handgerechnete Zahl. Das Profil wird nach der eigenen
# Funktion gefiltert: `decision_summary` zaehlt die ganze Uebersetzung
# einschliesslich der importierten Einheiten, in der std.io eine
# Kopierschleife enthaelt (#2375).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# mach NAME RUMPF — die gepruefte Schleife steht in `probe`.
mach() {
  cat > "$TMP/$1.lyx" <<LYX
import std.io;
fn probe(q: pchar, start: int64, n: int64, ziel: int64) {
  var i: int64 := 0;
$2
}
fn main(): int64 {
  var n: int64 := 37;
  var ziel: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 4096) { poke8(ziel + i, 0); i := i + 1; }
  probe("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"c, 3, n, ziel);
  var s: int64 := 0;
  var k: int64 := 0;
  while (k < 4096) { s := s + peek8(ziel + k) * (k + 1); k := k + 1; }
  PrintStr("PRUEFSUMME="c); PrintInt(s); PrintStrLn(""c);
  return 0;
}
LYX
}

lauf() {
  ( ulimit -c 0; cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $2 "$TMP/$1.lyx" -o "$TMP/$1.x" >"$TMP/$1.blog" 2>&1 ) || { echo "BAUFEHLER"; return; }
  ( ulimit -c 0; cd "$TMP" && timeout 60 "$TMP/$1.x" 2>/dev/null | tr '\n' ' ' )
}

gruende() {
  ( cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" --compile-profile --compile-profile-level=detailed "$1.lyx" -o "$1.p" ) >"$TMP/$1.plog" 2>&1 || { echo "BAUFEHLER"; return; }
  python3 - "$TMP/$1.p.lyxc-profile.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get('decisions',[]):
    if x.get('pass_id')=='vectorize' and x.get('function')=='probe':
        print('%s %s' % (x.get('outcome'), x.get('reason_code')))
PY
}

wert() {
  mach "$1" "$2"
  local V S
  V="$(lauf "$1" "")"; S="$(lauf "$1" "-O0")"
  if [ "$V" = "BAUFEHLER" ] || [ "$S" = "BAUFEHLER" ]; then
    no "$1" "uebersetzt nicht: $(grep -m1 -iE 'error|lyxc:' "$TMP/$1.blog")"; return 1
  fi
  if [ -n "$V" ] && [ "$V" = "$S" ]; then ok "$1 Wert stimmt ($V)"; return 0
  else no "$1 Wert" "vektorisiert '$V', skalar '$S'"; return 1; fi
}

ja() { # NAME RUMPF — muss angenommen werden
  wert "$1" "$2" || return
  local G="$(gruende "$1")"
  if echo "$G" | grep -q "^applied "; then ok "$1 vektorisiert"
  else no "$1 vektorisiert" "kein applied: $(echo "$G" | tr '\n' '; ')"; fi
}
nein() { # NAME RUMPF — muss abgelehnt werden
  wert "$1" "$2" || return
  local G="$(gruende "$1")"
  if echo "$G" | grep -q "^applied "; then no "$1 abgewiesen" "wurde vektorisiert"
  else ok "$1 abgewiesen ($(echo "$G" | head -1))"; fi
}

# ── angenommen ──────────────────────────────────────────────────────────────
# pchar-Local als Basis, mit invariantem Versatz (die Form aus StrSubstr).
ja zeiger_mit_versatz '  while (i < n) { poke8(ziel + i, peek8(q + start + i)); i := i + 1; }'
# Umdeutung als Basis (die Form aus _methodMangle und lowerCall).
ja umdeutung        '  while (i < n) { poke8(ziel + i, peek8((q as int64) + i)); i := i + 1; }'
# Umdeutung UND Versatz.
ja umdeutung_versatz '  while (i < n) { poke8(ziel + i, peek8((q as int64) + start + i)); i := i + 1; }'

# ── abgewiesen ──────────────────────────────────────────────────────────────
# Der Zaehler steckt in der Umdeutung: die Basis ist nicht invariant und darf
# nicht vor die Schleife gezogen werden. Dieser Fall ist nur dann richtig
# abgelehnt, wenn cg_vmOhneZaehler die Umdeutung BETRITT — lehnte sie sie
# pauschal ab, waere auch `umdeutung` oben rot.
nein cast_am_zaehler '  while (i < n) { poke8(ziel + i, peek8(((q as int64) + i) + i)); i := i + 1; }'
# Umdeutung auf eine SCHMALERE Art schneidet ab und bleibt abgelehnt.
nein cast_schmal     '  while (i < n) { poke8(ziel + i, peek8(((q as int64) as int32) + i)); i := i + 1; }'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
