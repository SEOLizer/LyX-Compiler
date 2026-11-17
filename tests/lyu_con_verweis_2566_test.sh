#!/bin/bash
# #2566: `pub con X := <andere con>` in der .lyu beschreiben.
#
# std/error.lyx war nach #2514 die letzte quellpflichtige Unit des Pakets:
# `pub con EWOULDBLOCK: int64 := EAGAIN` ist weder Literal noch Rechnung,
# sondern ein VERWEIS. lyu_writer._konWert kannte den Fall nicht und liess die
# Konstante draussen -- und ein unbeschriebenes Symbol laesst den Codegen
# abbrechen ("Nicht beschrieben: EWOULDBLOCK"). Die Schwesterstelle
# ir_lower._constFaltbar kennt ihn seit #1810; der Kommentar ueber _konWert
# behauptete sogar Gleichstand mit ihr.
#
# GEMESSEN WIRD DER WERT, nicht das Vorhandensein des Symbols. Ein Test auf
# "EWOULDBLOCK ist bekannt" waere auch erfuellt, wenn die Konstante still als
# 0 ankommt -- genau die Fehlerart, vor der die Abbruchmeldung warnt. Darum
# laeuft hier ein Programm und vergleicht Zahlen.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-./lyxc}"
# Der Guard backt den Pfad in seinen Wrapper ein; dieser Test wechselt zum
# Uebersetzen das Verzeichnis, der Pfad muss also vorher absolut sein.
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
[ -x "$LYXC" ] || { echo "SKIP: kein ./lyxc"; echo "RESULT: 0 PASS, 0 FAIL"; exit 0; }
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/baum/x86_64/std" "$T/arb"

if ! "$LYXC" --std-path="$ROOT" --with-objcode --compile-unit std/error.lyx \
     -o "$T/baum/x86_64/std/error.lyu" > "$T/cu.log" 2>&1; then
  nok "std/error.lyx liess sich nicht zu .lyu uebersetzen"
  sed -n '1,4p' "$T/cu.log"; echo "RESULT: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "std/error.lyx zu .lyu uebersetzt"

# Vorbedingung: im Baum liegt KEINE Quelle -- sonst misst der Test den
# Quellweg und meldet trotzdem Erfolg.
if [ -e "$T/baum/x86_64/std/error.lyx" ]; then
  nok "Vorbedingung verletzt: error.lyx liegt im Baum"
else
  ok "Vorbedingung: nur error.lyu im Baum, keine Quelle"
fi

# Die beiden Verweisformen im Bestand. Sind es eines Tages mehr, soll dieser
# Test nicht schweigen -- darum wird die Zahl mitgeprueft.
N_VERWEIS="$(grep -cE '^pub con +[A-Za-z_][A-Za-z0-9_]* *: *[a-z0-9]+ *:= *[A-Za-z_][A-Za-z0-9_]* *(;|//)' std/error.lyx)"
if [ "$N_VERWEIS" -ge 2 ]; then
  ok "std/error.lyx fuehrt $N_VERWEIS Konstanten mit Konstantenverweis"
else
  nok "nur $N_VERWEIS Verweisform(en) in std/error.lyx gefunden, erwartet mindestens 2"
fi

cat > "$T/arb/p.lyx" <<'EOF'
unit main;
import std.error;
fn main(): int64 {
  if (EWOULDBLOCK != EAGAIN)  { return 1; }
  if (EDEADLOCK   != EDEADLK) { return 2; }
  if (EAGAIN      != 11)      { return 3; }
  if (EDEADLK     != 35)      { return 4; }
  return 0;
}
EOF

# OHNE --std-path: mit ihm findet der Compiler std/error.lyx als QUELLE und
# braucht die Beschreibung nie -- der Test waere dann auch mit dem Compiler
# des Vorstands gruen und wuerde den Quellweg messen. Genau so war der erste
# Wurf: 6 PASS alt wie neu.
( cd "$T/arb" && "$LYXC" --units-install-dir="$T/baum" p.lyx -o p > p.log 2>&1 )
rc=$?
if [ "$rc" = "0" ] && [ -s "$T/arb/p" ]; then
  ok "uebersetzt nur aus der .lyu (Erzeugnis entsteht)"
else
  nok "Uebersetzung scheitert (rc=$rc)"
  grep -m3 -iE "error|Nicht beschrieben" "$T/arb/p.log" | sed 's/^/    /'
fi

# Der WERT, am laufenden Programm. Jeder Rueckgabewert nennt genau einen Fall,
# damit ein Fehlschlag sagt, WELCHE Konstante falsch ankam.
if [ -s "$T/arb/p" ]; then
  "$T/arb/p"; prc=$?
  case "$prc" in
    0) ok "die Werte stimmen: EWOULDBLOCK==EAGAIN==11, EDEADLOCK==EDEADLK==35" ;;
    1) nok "EWOULDBLOCK != EAGAIN -- der Verweis kam nicht an" ;;
    2) nok "EDEADLOCK != EDEADLK -- der Verweis kam nicht an" ;;
    3) nok "EAGAIN != 11 -- die Grundkonstante kam falsch an" ;;
    4) nok "EDEADLK != 35 -- die Grundkonstante kam falsch an" ;;
    *) nok "Programm endete mit rc=$prc" ;;
  esac
fi

# Und der Gegenstand des Issues: die Unit gilt nicht mehr als quellpflichtig.
if grep -q "Quelle der importierten Unit nicht lesbar" "$T/arb/p.log" 2>/dev/null; then
  nok "std.error gilt weiter als quellpflichtig"
else
  ok "std.error ist nicht mehr quellpflichtig"
fi

echo "RESULT: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
