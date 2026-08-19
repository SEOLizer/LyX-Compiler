#!/bin/bash
# #1693, #1697, #1698 — das lyxos-Ziel war unbenutzbar, ohne dass es auffiel:
# `make test-lyxos` haengt an keinem Sammelziel und laeuft in keiner CI (#1696).
#
# Geprueft wird jeweils die Wirkung, nicht nur "uebersetzt durch":
#   - #1693 auch UNIT-UEBERGREIFEND und mit -I, denn genau daran lag es;
#     relativ zum Arbeitsverzeichnis ging es naemlich schon vorher.
#   - #1697 an beiden Positionen des Paares und mehrfach in einer Funktion.
#   - #1698 samt der Frage, ob der Builtin verdeckt wird.
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok()  { echo "PASS: $1"; P=$((P+1)); }
bad() { echo "FAIL: $1"; F=$((F+1)); }

# ---------------------------------------------------------------------------
# #1693 — Funktionen aus importierten Units
# ---------------------------------------------------------------------------
mkdir -p "$TMP/u/Probe" "$TMP/u/Tief"
cat > "$TMP/u/Probe/Klein.lyx" <<'EOF'
unit Probe.Klein;
pub fn Verdopple(x: int64): int64 { return x * 2; }
EOF
cat > "$TMP/u/Tief/Basis.lyx" <<'EOF'
unit Tief.Basis;
pub fn Drei(): int64 { return 3; }
EOF
cat > "$TMP/u/Probe/Mittel.lyx" <<'EOF'
unit Probe.Mittel;
import Tief.Basis;
pub fn Sieben(): int64 { return Drei() + 4; }
EOF
cat > "$TMP/e1.lyx" <<'EOF'
unit Main;
import Probe.Klein;
fn main(): int64 { return Verdopple(21); }
EOF
cat > "$TMP/e2.lyx" <<'EOF'
unit Main;
import Probe.Mittel;
fn main(): int64 { return Sieben(); }
EOF

# Der Kern: mit -I, aus einem Verzeichnis, in dem der relative Pfad NICHT passt.
if "$LYXC" "$TMP/e1.lyx" -I "$TMP/u" --target=lyxos -o "$TMP/e1.lbf" > "$TMP/a.log" 2>&1; then
  if [ -s "$TMP/e1.lbf" ]; then
    ok "lyxos: Funktion aus importierter Unit, ueber -I gefunden"
  else
    bad "lyxos: uebersetzt, aber keine LBF entstanden"
  fi
else
  bad "lyxos: importierte Funktion ($(grep -oE 'unbekannter Builtin.*|error.*' "$TMP/a.log" | head -1))"
fi

if "$LYXC" "$TMP/e2.lyx" -I "$TMP/u" --target=lyxos -o "$TMP/e2.lbf" > "$TMP/b.log" 2>&1 && [ -s "$TMP/e2.lbf" ]; then
  ok "lyxos: transitiver Import (Main -> Mittel -> Basis)"
else
  bad "lyxos: transitiver Import ($(grep -oE 'unbekannter Builtin.*|error.*' "$TMP/b.log" | head -1))"
fi

# Gegenprobe Linux: derselbe Quelltext muss auch rechnen, nicht nur uebersetzen.
if "$LYXC" "$TMP/e2.lyx" -I "$TMP/u" -o "$TMP/e2.elf" > /dev/null 2>&1; then
  chmod +x "$TMP/e2.elf"; "$TMP/e2.elf"; rc=$?
  if [ "$rc" -eq 7 ]; then ok "Linux-Gegenprobe rechnet richtig (7)"; else bad "Linux-Gegenprobe liefert $rc statt 7"; fi
else
  bad "Linux-Gegenprobe uebersetzt nicht"
fi

# ---------------------------------------------------------------------------
# #1697 — `_` als Verwurf
# ---------------------------------------------------------------------------
cat > "$TMP/v.lyx" <<'EOF'
import std.io;
fn zwei(): (int64, int64) { return (7, 9); }
fn main(): int64 {
  var a, b := zwei();
  var c, _ := zwei();
  var _, d := zwei();
  var e, _ := zwei();
  PrintLn(IntToStr(a) + IntToStr(b) + IntToStr(c) + IntToStr(d) + IntToStr(e));
  return 0;
}
EOF
if "$LYXC" --std-path=. "$TMP/v.lyx" -o "$TMP/v" > "$TMP/v.log" 2>&1; then
  chmod +x "$TMP/v"; vaus="$("$TMP/v" 2>&1 | head -1)"
  # a=7 b=9 c=7 d=9 e=7
  if [ "$vaus" = "79797" ]; then
    ok "Verwurf an beiden Positionen, mehrfach in einer Funktion"
  else
    bad "Verwurf liefert '$vaus' statt '79797'"
  fi
else
  bad "Verwurf uebersetzt nicht ($(grep -oE 'error.*' "$TMP/v.log" | head -1))"
fi

# `var _` allein hat keine Bedeutung und muss abgewiesen bleiben — sonst waere
# aus dem Verwurf versehentlich ein gewoehnlicher Name geworden.
printf 'import std.io;\nfn main(): int64 { var _: int64 := 5; return 0; }\n' > "$TMP/w.lyx"
if "$LYXC" --std-path=. "$TMP/w.lyx" -o "$TMP/w" > "$TMP/w.log" 2>&1; then
  bad "'var _: int64' uebersetzt, sollte abgewiesen werden"
else
  ok "'var _: int64' allein bleibt abgewiesen"
fi

# Die vier Bestandsdateien, die die Schreibweise benutzen.
vier=0
for f in tests/lyxos/lx12_pledge.lyx tests/lyxos/lx14_ai_infer.lyx tests/lyxos/lx21_two_ret.lyx; do
  "$LYXC" --std-path=. "$f" --target=lyxos --emit=lbf -o "$TMP/x.lbf" > /dev/null 2>&1 || vier=$((vier+1))
done
"$LYXC" --std-path=. --target=lyxos tests/lx21_tworet_test.lyx -o "$TMP/x2" > /dev/null 2>&1 || vier=$((vier+1))
if [ "$vier" -eq 0 ]; then
  ok "die vier Bestandsdateien mit dem Verwurf uebersetzen"
else
  bad "$vier der vier Bestandsdateien mit '_' uebersetzen weiterhin nicht"
fi

# ---------------------------------------------------------------------------
# #1698 — lyxrt
# ---------------------------------------------------------------------------
if "$LYXC" --std-path=. --target=lyxos tests/lx19_lyxrt_test.lyx -o "$TMP/lx19" > "$TMP/r.log" 2>&1; then
  ok "lyxrt ist benutzbar (lx19 uebersetzt)"
else
  bad "lx19 uebersetzt nicht ($(grep -oE 'sema error.*|error.*' "$TMP/r.log" | head -1))"
fi

# Die Runtime darf die Builtins NICHT verdecken: haetten die Funktionen weiter
# `alloc`/`free` geheissen und waeren pub, entschiede der Import still, welcher
# Allocator getroffen wird — Arena auf sys_mmap oder Builtin.
if grep -qE "^pub fn (alloc|free)\(" src/std/lyxos/lyxrt.lyx; then
  bad "lyxrt exportiert 'alloc'/'free' und verdeckt damit die Builtins"
else
  ok "lyxrt verdeckt die Builtins nicht (rt_alloc/rt_free)"
fi

echo "----"
echo "$P PASS, $F FAIL"
[ "$F" -eq 0 ]
