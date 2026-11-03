#!/usr/bin/env bash
# tests/voidwert_leser_2326_test.sh — #2326 Posten 2: das Nullen von rax nach
# einem void-Builtin HAT einen Leser.
#
# Im elementweisen Kern aus `bench/arr_int.lyx` steht nach jedem `poke8` ein
# `xor %rax,%rax` — ein Befehl von zehn, dessen Ergebnis dort niemand liest.
# #2326 will ihn sparen und verlangt vorher die Frage: gibt es eine Stelle,
# die den Wert eines Ausdruck-Statements liest?
#
# Es gibt sie. `cg_genMatchBody` (src/codegen_x86.lyx) nimmt die letzte
# Anweisung eines match-Arms als dessen Wert:
#
#     if (nxt == -1 && self.cg_nkind(stmt) == CGN_EXPR_STMT) {
#       // letzte Anweisung ist ein Ausdruck -> sein Wert ist der Wert des Blocks
#
# Ist diese letzte Anweisung ein void-Builtin, dann ist das genullte rax der
# Armwert. Wer das Nullen pauschal entfernt, liefert dort einen Restwert aus
# dem Rumpf des Builtins — stillschweigend und abhaengig vom Zugriffspfad.
#
# Dieser Test ist deshalb die Wache, die #2326 fordert: er prueft den WERT
# (Armwert 0 und die Wirkung des Schreibzugriffs), nicht die
# Uebersetzbarkeit. Wird das Nullen im Statement-Kontext gespart, muss es im
# Blockwert-Kontext bleiben — dann bleibt dieser Test gruen. Wird es
# pauschal entfernt, wird er rot.
#
# Bewusst KEIN Test auf die Abwesenheit des Befehls im Erzeugnis: er soll ja
# gespart werden. Ein Test, der das Fortbestehen einer Luecke voraussetzt,
# wird rot, sobald die Luecke zugeht.
#
# GEGENPROBE, gemessen auf 1.2.29A — ohne sie waere dieser Test nur eine
# Behauptung:
#
#   * `cg_zeroRax` im poke8-Zweig der Builtin-Kette entfernt (`mov [rdi],
#     sil`): arm1 = 42, arm2 = 13 statt 0. Der GESCHRIEBENE Wert bleibt in
#     rax stehen und wird zum Armwert — der Test wird rot, und zwar am Wert.
#   * `cg_zeroRax` im schnellen Zugriffspfad entfernt: arm1 und arm2 bleiben
#     gruen, denn ihre Adresse ist kein Basis-plus-Index-Muster und nimmt den
#     schnellen Pfad nicht. Dafuer gibt es arm3 mit `poke8(p + i, ...)` —
#     dieselbe Form wie im Kern aus bench/arr_int.lyx.
#
# Es gibt rund 90 Aufrufstellen von `cg_zeroRax`. Eine Wache deckt immer nur
# die Stelle ab, die der Testfall wirklich durchlaeuft; deshalb beide Formen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
export LYXC
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

cat > "$TMP/leser.lyx" <<'EOF'
import std.io;

fn main(): int64 {
  var p: int64 := alloc(8);
  var w: int64 := 7;
  // Letzte Anweisung des Arms ist ein void-Builtin. Ihr Wert ist der
  // Armwert; er muss 0 sein, und der Schreibzugriff muss stattfinden.
  var r: int64 := match (w) {
    case 7 => { poke8(p, 42); }
    case _ => { 99 }
  };
  var s: int64 := match (w) {
    case 1 => { 11 }
    case _ => { poke8(p + 1, 13); }
  };
  // Dritter Arm mit Basis + INDEX: diese Form nimmt den schnellen
  // Zugriffspfad, und genau sie steht im elementweisen Kern aus
  // bench/arr_int.lyx (`poke8(c + i, ...)`). Ohne sie bewacht der Test nur
  // die Builtin-Kette und nicht die Stelle, an der #2326 sparen will.
  var i: int64 := 2;
  var t: int64 := match (w) {
    case 7 => { poke8(p + i, 55); }
    case _ => { 77 }
  };
  PrintStr("arm1="c);
  PrintLn(r);
  PrintStr("arm2="c);
  PrintLn(s);
  PrintStr("arm3="c);
  PrintLn(t);
  PrintStr("byte0="c);
  PrintLn(peek8(p));
  PrintStr("byte1="c);
  PrintLn(peek8(p + 1));
  PrintStr("byte2="c);
  PrintLn(peek8(p + i));
  return 0;
}
EOF

if ! ( cd "$TMP" && "$LYXC" --std-path="$ROOT" leser.lyx -o leser ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -v Copyright "$TMP/b.log" | grep -m1 -iE 'error|lyxc:')"
  echo "=== PASS=$PASS FAIL=$FAIL"
  exit 1
fi

AUS="$( cd "$TMP" && timeout 60 ./leser 2>&1 )"
rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc, Ausgabe: $(echo "$AUS" | tr '\n' ' ')"
else
  ok "uebersetzt und laeuft"
fi

hol() { echo "$AUS" | sed -n "s/^$1=//p"; }

# 1. Der Armwert. Das ist die eigentliche Aussage: ein void-Builtin als
#    letzte Anweisung liefert 0, nicht einen Restwert.
for paar in "arm1" "arm2" "arm3"; do
  v="$(hol "$paar")"
  if [ "$v" = "0" ]; then
    ok "$paar ist 0 — der Wert des void-Builtins wird gelesen"
  else
    no "$paar" "'$v' statt 0 — das Nullen von rax nach einem void-Builtin fehlt oder wurde pauschal entfernt"
  fi
done

# 2. Beide Seiten: der Schreibzugriff muss trotzdem stattgefunden haben. Ein
#    Armwert 0 allein waere auch von einem weggelassenen poke8 erfuellt.
b0="$(hol byte0)"; b1="$(hol byte1)"; b2="$(hol byte2)"
if [ "$b0" = "42" ] && [ "$b1" = "13" ] && [ "$b2" = "55" ]; then
  ok "die Schreibzugriffe wirken (42, 13, 55)"
else
  no "Wirkung des Schreibzugriffs" "byte0='$b0' (42), byte1='$b1' (13), byte2='$b2' (55)"
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
