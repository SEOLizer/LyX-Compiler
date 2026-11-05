#!/usr/bin/env bash
# tests/vektor_kopierschleife_2375_test.sh — die reine KOPIERSCHLEIFE wird
# vektorisiert (#2375).
#
#   while (i < n) { pokeW(b + i * W, peekW(a + i * W)); i := i + 1; }
#
# Der Erkenner verlangte als abgelegten Wert einen Binop ueber zwei
# Leseadressen (`c[i] = a[i] op b[i]`). Eine Kopie hat keinen Operator und
# fiel mit VALUE_NOT_BINOP durch — im Selbstbau von src/lyxc.lyx 374 Mal,
# darunter StrConcat, StrCopy und AppendStr im Compilerbaum.
#
# GEPRUEFT WIRD DER WERT, nicht die Uebersetzbarkeit, und zwar gegen die
# skalare Rechnung DERSELBEN Quelle (`-O0`). Eine handgerechnete Erwartung
# waere hier die schwaechere Probe: sie faellt mit, wenn ich mich verrechne.
#
# Die Pruefsumme wiegt jedes Byte des GANZEN Zielpuffers mit seiner Stelle.
# Eine Summe nur ueber die n kopierten Elemente waere blind fuer eine Ablage
# daneben — genau der Defekt aus #2199.
#
# Vier Gegenproben, ohne die der Test wertlos waere:
#   * UEBERLAPPUNG: Ziel = Quelle + 3. Der Vektorweg darf dort nicht laufen
#     (die Vergleichspaare in cg_vmEmit schicken ihn skalar); das Ergebnis
#     muss der skalaren Rechnung gleichen. Haette der Kern blockweise
#     kopiert, stuende hier ein anderer Wert.
#   * VERSCHIEDENE INDEXFORMEN: `poke8(d + i, peek8(s + i * 2))` ist keine
#     Kopie derselben Stelle und muss abgelehnt bleiben.
#   * BREITENMISCHUNG: `poke16(d + i * 2, peek8(s + i))` ebenso.
#   * n ist kein Vielfaches der Vektorbreite (37), damit der Rest-Durchgang
#     mitlaeuft.
#
# Und der Positivfall am Profil: ohne ihn waere der Test auch von einem
# Erkenner erfuellt, der nichts mehr annimmt.
#
# Die gepruefte Schleife steht in einer EIGENEN Funktion `probe`, und das
# Profil wird nach dieser Funktion gefiltert. Ohne den Filter zaehlte die
# Pruefsummenschleife mit: die ist eine Reduktion (#2335) und wird ebenfalls
# vektorisiert, womit jede Gegenprobe "angenommen" gemeldet haette. Genau
# dieser Fehler stand in der ersten Fassung dieses Tests.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# mach NAME RUMPF — ein Programm je Fall; zwei Formen in einer Datei liessen
# nicht erkennen, welche Schleife welchen Grund erzeugt hat.
mach() {
  cat > "$TMP/$1.lyx" <<LYX
import std.io;
fn probe(a: int64, b: int64, n: int64) {
  var i: int64 := 0;
$2
}
fn main(): int64 {
  var n: int64 := 37;
  var a: int64 := alloc(4096);
  var b: int64 := alloc(4096);
  var i: int64 := 0;
  while (i < 4096) { poke8(a + i, 0); poke8(b + i, 0); i := i + 1; }
  i := 0;
  while (i < 200) { poke8(a + i, i + 1); i := i + 1; }
  probe(a, b, n);
  var s: int64 := 0;
  var k: int64 := 0;
  while (k < 4096) { s := s + peek8(a + k) * (k + 1) + peek8(b + k) * (k + 7); k := k + 1; }
  PrintStr("PRUEFSUMME="c); PrintInt(s); PrintStrLn(""c);
  return 0;
}
LYX
}

lauf() { # $1 = Name, $2 = Schalter
  ( ulimit -c 0; cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" $2 "$TMP/$1.lyx" -o "$TMP/$1.x" >"$TMP/$1.blog" 2>&1 ) || { echo "BAUFEHLER"; return; }
  ( ulimit -c 0; cd "$TMP" && timeout 60 "$TMP/$1.x" 2>/dev/null | tr '\n' ' ' )
}

gruende() { # $1 = Name
  ( cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" --compile-profile --compile-profile-level=detailed "$1.lyx" -o "$1.p" ) >"$TMP/$1.plog" 2>&1 || { echo "BAUFEHLER"; return; }
  python3 - "$TMP/$1.p.lyxc-profile.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get('decisions',[]):
    if x.get('pass_id')=='vectorize' and x.get('function')=='probe':
        print('%s %s' % (x.get('outcome'), x.get('reason_code')))
PY
}

# wert NAME RUMPF — Wert gegen die skalare Rechnung
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

# ── angenommen: Kopie, je Breite ────────────────────────────────────────────
for paar in "8 1" "16 2" "32 4"; do
  set -- $paar
  w="$1"; bw="$2"
  if [ "$bw" = "1" ]; then idx="i"; else idx="i * $bw"; fi
  R="  i := 0;
  while (i < n) { poke${w}(b + ${idx}, peek${w}(a + ${idx})); i := i + 1; }"
  wert "kopie$w" "$R"
  G="$(gruende "kopie$w")"
  if echo "$G" | grep -q "^applied "; then
    ok "kopie${w}_vektorisiert ($(echo "$G" | grep '^applied ' | head -1))"
  else
    no "kopie${w}_vektorisiert" "kein applied: $(echo "$G" | tr '\n' '; ')"
  fi
done

# ── Ueberlappung: muss skalar bleiben und denselben Wert liefern ────────────
wert ueberlappend "  var q: int64 := a;
  var z: int64 := a + 3;
  i := 0;
  while (i < n) { poke8(z + i, peek8(q + i)); i := i + 1; }"
G="$(gruende ueberlappend)"
if echo "$G" | grep -q "^applied "; then
  ok "ueberlappend_zur_Laufzeit_geprueft ($(echo "$G" | head -1))"
else
  no "ueberlappend_zur_Laufzeit_geprueft" "erwartet applied, Profil: $(echo "$G" | tr '\n' '; ')"
fi

# ── abgewiesen: keine Kopie derselben Stelle ────────────────────────────────
gegen() { # $1 = Name, $2 = Rumpf
  wert "$1" "$2" || return
  local G="$(gruende "$1")"
  if echo "$G" | grep -q "^applied "; then
    no "$1 abgewiesen" "wurde vektorisiert, obwohl Lese- und Schreibform nicht zusammenpassen"
  else
    ok "$1 abgewiesen"
  fi
}
gegen index_verschieden "  i := 0;
  while (i < n) { poke8(b + i, peek8(a + i * 2)); i := i + 1; }"
gegen breiten_mischung "  i := 0;
  while (i < n) { poke16(b + i * 2, peek8(a + i)); i := i + 1; }"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
