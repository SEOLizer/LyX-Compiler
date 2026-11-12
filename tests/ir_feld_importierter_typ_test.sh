#!/usr/bin/env bash
# tests/ir_feld_importierter_typ_test.sh — #2459: geschachtelter Feldzugriff
# auf einen IMPORTIERTEN Typ auf dem IR-Weg.
#
# BEFUND: `r.min.x` mit `r: Rect` aus einer anderen Unit brach ab —
#
#   error: #2134: Feld nicht aufloesbar (Typ der Basis unbekannt): x
#
# — waehrend derselbe Wert ueber eine lokale Zwischenkopie (`v := r.min;
# v.x`) ging. Identisches Objekt, identische Importe, zwei Ergebnisse: das
# Muster "eine Herkunft fehlt in einer Aufzaehlung" (#1787, #1806, #1812).
# _exprTypeNode loeste den Feldtyp nur ueber Deklarationen der EIGENEN Unit
# auf; fuer einen importierten Typ kam -1 zurueck.
#
# Die Meldung in #2459 nannte win64. Gemessen mit 1.2.35C traf es win64,
# arm64, riscv und lyxos gleichlautend — jedes Ziel, das ueber das IR geht.
#
# Gemessen wird in beiden Richtungen und am WERT:
#   * der zweistufige Zugriff muss uebersetzen UND die richtige Zahl liefern
#     (ein Offset von 0 waere auch "uebersetzt"),
#   * die einstufige Form daneben muss weiter gehen (sonst waere der Test auch
#     von einer Fassung erfuellt, die den einfachen Fall kaputt macht).
#
# WAS HIER NICHT GEMESSEN WIRD: die zweite Form, `df.columns[c].field.name`
# (Feld eines INDEXZUGRIFFS auf ein Feld, data/csv.lyx:115 und drei weitere).
# Sie ist unten auf Uebersetzbarkeit der vier echten Units gesichert, aber
# nicht am Wert — kein kleines Programm baut einen DataFrame von data.frame
# auf (DataFrameAddColumn liefert dort einzeln aufgerufen -1), und ein
# nachgebautes Paar Units stolpert vorher ueber eine ANDERE, aeltere Luecke:
# ein geschachteltes inline-Struct-Feld (`x.k.a` mit `k: Inner`) faultet auf
# jedem IR-Ziel, in der eigenen Unit genauso — das ist ein eigener Befund und
# ein eigenes Issue, nicht Teil von #2459.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$ROOT/tests/lib/lyxc_guard.sh"; [ -f "$_g" ] && . "$_g"
. "$ROOT/tests/lib/qemu.sh"   # #2048: QEMU_ARM64 / QEMU_RISCV64 — nicht selbst suchen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+: $2}"; FAIL=$((FAIL+1)); }

ERWARTET="11 22 33 44 11 22"

# std.rect fuehrt `Rect` mit zwei Feldern des importierten Typs `Vec2` —
# genau die Lage aus dem Bericht, und zwar im Bestand, nicht nachgebaut.
cat > "$TMP/nf.lyx" <<'LYX'
import src.std.io;
import std.rect;
import std.vector;

fn main(): int64 {
  var a: Vec2; a.x := 11; a.y := 22;
  var b: Vec2; b.x := 33; b.y := 44;
  var r: Rect := RectNew(a, b);
  // Zweistufig — das ist die Form, die abbrach.
  PrintInt(r.min.x); PrintStr(" "c);
  PrintInt(r.min.y); PrintStr(" "c);
  PrintInt(r.max.x); PrintStr(" "c);
  PrintInt(r.max.y); PrintStr(" "c);
  // Einstufig ueber eine Zwischenkopie — ging schon vorher und muss weiter gehen.
  var v: Vec2 := r.min;
  PrintInt(v.x); PrintStr(" "c);
  PrintInt(v.y); PrintStr("\n"c);
  return 0;
}
LYX

# Die Unit aus dem Bericht: sie wird nur UEBERSETZT, nicht ausgefuehrt.
cat > "$TMP/p.lyx" <<'LYX'
unit p;
import std.rect;
import std.vector;
pub fn F(r: Rect): int64 { return r.min.x; }
pub fn G(r: Rect): int64 { var v: Vec2; v := r.min; return v.x; }
LYX

# ------------------------------------------------- Referenz: der Schnellweg

if "$LYXC" --std-path="$ROOT" "$TMP/nf.lyx" -o "$TMP/nf_x86" > "$TMP/log" 2>&1; then
  aus=$("$TMP/nf_x86" 2>/dev/null | tr -d '\n')
  if [ "$aus" = "$ERWARTET" ]; then
    ok "x86-Schnellweg liest beide Formen richtig (Referenz)"
  else
    no "x86-Schnellweg" "erhalten [$aus], erwartet [$ERWARTET]"
  fi
else
  no "x86-Schnellweg uebersetzt" "$(grep -m1 -i error "$TMP/log")"
fi

# ------------------------------------------------- IR-Ziele: Wert ausfuehren

probe() { # probe <ziel> <emulator aus lib/qemu.sh, leer wenn keiner da>
  local z="$1" q="$2"
  if ! "$LYXC" --std-path="$ROOT" --target="$z" "$TMP/nf.lyx" -o "$TMP/nf_$z" > "$TMP/log" 2>&1; then
    no "$z uebersetzt den zweistufigen Zugriff" "$(grep -m1 -iE '2134|error' "$TMP/log")"
    return
  fi
  ok "$z uebersetzt den zweistufigen Zugriff"
  if [ -z "$q" ] || ! command -v "$q" > /dev/null 2>&1; then
    echo "SKIP kein Emulator vorhanden — der Wert bleibt auf $z ungemessen"
    return
  fi
  local aus
  aus=$(cd "$TMP" && timeout 120 "$q" "./nf_$z" 2>/dev/null | tr -d '\n')
  if [ "$aus" = "$ERWARTET" ]; then
    ok "$z liest dieselben Werte wie x86 (kein Offset 0)"
  else
    no "$z Werte" "erhalten [$aus], erwartet [$ERWARTET]"
  fi
}

probe arm64 "$QEMU_ARM64"
probe riscv "$QEMU_RISCV64"

# ------------------------------------------------- die Unit aus dem Bericht

for z in win64 arm64 riscv lyxos; do
  if "$LYXC" --std-path="$ROOT" --target="$z" --compile-unit "$TMP/p.lyx" \
       -o "$TMP/p_$z.lyu" > "$TMP/log" 2>&1; then
    ok "die Unit aus #2459 laesst sich fuer $z vorkompilieren"
  else
    no "Unit aus #2459 fuer $z" "$(grep -m1 -iE '2134|error' "$TMP/log")"
  fi
done

# ------------------------------------------------- die sieben gemeldeten Units

# Aus #2459: sieben Units des Bestands scheiterten an derselben Stelle. Sie
# stehen hier namentlich, damit nicht nur der nachgebaute Fall bewacht ist.
for u in data/binary.lyx data/csv.lyx data/json.lyx data/ops.lyx data/print.lyx \
         std/circle.lyx std/net/socket.lyx; do
  if "$LYXC" --std-path="$ROOT" --target=win64 --compile-unit "$ROOT/$u" \
       -o "$TMP/u.lyu" > "$TMP/log" 2>&1; then
    ok "$u fuer win64 vorkompilierbar"
  elif grep -q "#2134" "$TMP/log"; then
    no "$u fuer win64" "$(grep -m1 '#2134' "$TMP/log")"
  else
    echo "SKIP $u scheitert an einer ANDEREN Ursache: $(grep -m1 -iE 'error|unbekannter' "$TMP/log")"
  fi
done

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
