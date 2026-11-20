#!/bin/bash
# #2551: Erreichbarkeitsanalyse auf Funktionsebene (--gc-functions).
#
# BEFUND: eine importierte Unit landet vollstaendig im Erzeugnis, egal wie
# viel von ihr gebraucht wird. Gemessen vor der Aenderung (1.2.42A):
#   leeres Programm                              4 313 Byte
#   dasselbe plus unbenutztes `import std.hash`  190 176 Byte
#
# WAS DIESER TEST MISST, und warum nicht weniger:
#
# BEIDE SEITEN. Dass der unbenutzte Import schrumpft, waere auch erfuellt,
# wenn die Analyse zu viel verwirft. Darum wird zusaetzlich am LAUFENDEN
# Programm geprueft, dass benutzte Funktionen weiter da sind und RICHTIG
# rechnen -- und zwar ueber drei Wege, auf denen ein Name verschwinden kann
# ohne dass eine Groessenzahl es zeigt:
#   * gewoehnlicher Aufruf
#   * Funktionszeiger (der Name steht als WERT, nicht als Aufrufziel)
#   * Aufruf aus einer anderen Funktion derselben importierten Unit
#     (transitiv -- die zweite Funktion nennt niemand von aussen)
#
# OHNE SCHALTER BITGLEICH. Die Vorgabe darf sich nicht veraendern; geprueft
# wird mit sha256 gegen einen Lauf ohne Schalter.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LYXC="${LYXC:-./lyxc}"
case "$LYXC" in /*) ;; *) LYXC="$PWD/${LYXC#./}";; esac
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
[ -x "$LYXC" ] || { echo "SKIP: kein ./lyxc"; echo "RESULT: 0 PASS, 0 FAIL"; exit 0; }
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Eine eigene Unit, damit der Test nicht an der Groesse einer fremden haengt.
mkdir -p "$T/u"
cat > "$T/u/viel.lyx" <<'EOF'
// Zwei benutzte Funktionen (eine davon nur transitiv), eine ueber
// Funktionszeiger, und reichlich unbenutzte Masse.
pub fn Benutzt(a: int64): int64 { return Tief(a) + 1; }
pub fn Tief(a: int64): int64 { return a * 3; }
pub fn PerZeiger(a: int64): int64 { return a + 7; }
pub fn Unbenutzt01(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt02(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt03(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt04(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt05(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt06(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt07(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn Unbenutzt08(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
EOF

cat > "$T/u/p.lyx" <<'EOF'
import viel;
fn main(): int64 {
  // gewoehnlicher Aufruf; Benutzt ruft intern Tief (transitiv)
  if (Benutzt(5) != 16) { return 1; }
  // Funktionszeiger: der Name steht als WERT
  var f: fn(int64): int64 := PerZeiger;
  if (f(3) != 10) { return 2; }
  return 0;
}
EOF

lauf() {  # lauf <marke> <zusatzargumente...>
  local m="$1"; shift
  ( cd "$T/u" && "$LYXC" -I . "$@" p.lyx -o "$T/$m" > "$T/$m.log" 2>&1 )
  echo $?
}

rc_ohne="$(lauf ohne)"
if [ "$rc_ohne" != "0" ] || [ ! -s "$T/ohne" ]; then
  nok "Vergleichslauf ohne Schalter scheitert (rc=$rc_ohne)"
  grep -m3 -iE "error" "$T/ohne.log" | sed 's/^/    /'
  echo "RESULT: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "ohne Schalter uebersetzt ($(stat -c%s "$T/ohne") Byte)"

rc_mit="$(lauf mit --gc-functions)"
if [ "$rc_mit" != "0" ] || [ ! -s "$T/mit" ]; then
  nok "--gc-functions scheitert (rc=$rc_mit)"
  grep -m3 -iE "error|unbekannt|unknown" "$T/mit.log" | sed 's/^/    /'
  echo "RESULT: $PASS PASS, $FAIL FAIL"; exit 1
fi
ok "--gc-functions uebersetzt ($(stat -c%s "$T/mit") Byte)"

# Seite 1: es muss WIRKLICH kleiner werden.
s_ohne="$(stat -c%s "$T/ohne")"
s_mit="$(stat -c%s "$T/mit")"
if [ "$s_mit" -lt "$s_ohne" ]; then
  ok "Erzeugnis schrumpft: $s_ohne -> $s_mit Byte ($(( s_ohne - s_mit )) gespart)"
else
  nok "Erzeugnis schrumpft nicht: $s_ohne -> $s_mit Byte"
fi

# Seite 2: es muss weiter RICHTIG rechnen. Jeder Rueckgabewert nennt genau
# einen Fall, damit ein Fehlschlag sagt, welcher Weg gebrochen ist.
"$T/mit"; prc=$?
case "$prc" in
  0) ok "laeuft mit --gc-functions richtig (Aufruf, transitiv und Funktionszeiger)" ;;
  1) nok "Benutzt(5) != 16 -- gewoehnlicher Aufruf oder die transitiv gerufene Tief fehlt" ;;
  2) nok "Funktionszeiger PerZeiger gebrochen" ;;
  *) nok "Programm endete mit rc=$prc (Absturz? fehlender Rumpf?)" ;;
esac

"$T/ohne"; orc=$?
if [ "$orc" = "0" ]; then
  ok "derselbe Quelltext laeuft auch ohne Schalter richtig"
else
  nok "schon ohne Schalter falsch (rc=$orc) -- der Test misst nicht die Analyse"
fi

# Seite 3: die Vorgabe bleibt unveraendert.
rc_ohne2="$(lauf ohne2)"
if [ "$rc_ohne2" = "0" ] && [ -s "$T/ohne2" ]; then
  a="$(sha256sum "$T/ohne"  | cut -d' ' -f1)"
  b="$(sha256sum "$T/ohne2" | cut -d' ' -f1)"
  if [ "$a" = "$b" ]; then
    ok "ohne Schalter zweimal bitgleich (die Vorgabe ist unberuehrt)"
  else
    nok "ohne Schalter nicht reproduzierbar: $a != $b"
  fi
else
  nok "zweiter Lauf ohne Schalter scheitert"
fi

# ── Klassen und Interface-Dispatch ────────────────────────────────────────
#
# Der gefaehrlichste Fall: bei virtuellem Dispatch steht der Methodenname
# NICHT als Aufrufziel im Baum, die Auswahl faellt erst zur Laufzeit in der
# VMT. Methoden sind darum ueberhaupt keine Kandidaten -- das soll dieser
# Fall belegen, und zwar am LAUFENDEN Programm.
#
# Gemessen wird ueber den BERICHT, nicht ueber die Dateigroesse: die ist
# seitengranular (ein Erzeugnis sprang um genau 4096 Byte), zwei kleine
# weggelassene Funktionen sind daran nicht zu erkennen. Genau daran hatte
# ich den Fall erst falsch als "greift nicht" gelesen.
mkdir -p "$T/o"
cat > "$T/o/formen.lyx" <<'EOF'
pub type IFlaeche = interface {
  fn Flaeche(): int64;
};
pub type Rechteck = class implements IFlaeche {
  b: int64;
  h: int64;
  pub fn Flaeche(): int64 { return self.b * self.h; }
};
pub type Quadrat = class implements IFlaeche {
  s: int64;
  pub fn Flaeche(): int64 { return self.s * self.s; }
};
pub fn NieGerufen01(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
pub fn NieGerufen02(a: int64): int64 { var s: int64 := 0; var i: int64 := 0; while (i < 64) { s := s + a * i; i := i + 1; } return s; }
EOF
cat > "$T/o/q.lyx" <<'EOF'
import formen;
fn main(): int64 {
  var r: Rechteck := new Rechteck();
  r.b := 3; r.h := 4;
  var q: Quadrat := new Quadrat();
  q.s := 5;
  var f1: IFlaeche := r;
  var f2: IFlaeche := q;
  if (f1.Flaeche() != 12) { return 1; }
  if (f2.Flaeche() != 25) { return 2; }
  return 0;
}
EOF
( cd "$T/o" && "$LYXC" -I . --gc-functions-bericht q.lyx -o "$T/oop" > "$T/oop.log" 2>&1 )
orc2=$?
if [ "$orc2" = "0" ] && [ -s "$T/oop" ]; then
  ok "OOP-Programm uebersetzt mit --gc-functions"
  # Die beiden nie gerufenen freien Funktionen muessen weg sein ...
  weg=0
  grep -q "weggelassen NieGerufen01" "$T/oop.log" && weg=$((weg+1))
  grep -q "weggelassen NieGerufen02" "$T/oop.log" && weg=$((weg+1))
  if [ "$weg" = "2" ]; then
    ok "beide nie gerufenen freien Funktionen weggelassen"
  else
    nok "nur $weg von 2 nie gerufenen Funktionen weggelassen"
    grep -iE "^gc|weggelassen" "$T/oop.log" | sed 's/^/    /'
  fi
  # ... und KEINE Methode darf verschwinden.
  if grep -q "weggelassen Flaeche" "$T/oop.log"; then
    nok "eine Methode wurde weggelassen -- der VMT-Eintrag zeigt ins Leere"
  else
    ok "keine Methode weggelassen (VMT bleibt vollstaendig)"
  fi
  "$T/oop"; oprc=$?
  case "$oprc" in
    0) ok "Interface-Dispatch rechnet weiter richtig (3*4=12 und 5*5=25)" ;;
    1) nok "Rechteck.Flaeche() != 12 -- Dispatch oder Methode gebrochen" ;;
    2) nok "Quadrat.Flaeche() != 25 -- Dispatch oder Methode gebrochen" ;;
    *) nok "OOP-Programm endete mit rc=$oprc" ;;
  esac
else
  nok "OOP-Programm uebersetzt nicht mit --gc-functions (rc=$orc2)"
  grep -m3 -iE "error" "$T/oop.log" | sed 's/^/    /'
fi

# ── #2588: Aufrufe AUS METHODENRUEMPFEN sind lebende Kanten ────────────────
#
# Der Vorpass lief nur die oberste Ebene ab und sammelte allein NK_FUNC_DECL.
# Methoden haengen INNERHALB der Typdeklaration (nc1 des NK_TYPE_DECL), wurden
# also nie abgelaufen -- eine freie Funktion, die AUSSCHLIESSLICH aus einem
# Methodenrumpf gerufen wird, hatte keine eingehende Kante und galt als
# unerreichbar. `lyxc` ist methodenlastig: 413 von 495 Funktionen fielen weg,
# und der Selbstbau brach ab mit
#   error: undefined function 'lyxc_zlCpuNs' -- no codegen implementation found
#
# WARUM DER RUMPF EINEN ECHTEN AUFRUF BRAUCHT: zwei erste Minimalfassungen mit
# `fn freiHelfer(): int64 { return 42; }` liefen GRUEN durch und gaben 42 aus,
# obwohl der Bericht die Funktion als weggelassen meldete -- die Konstante wird
# gefaltet, der Aufruf verschwindet, der Fehler ist unsichtbar. Darum steht im
# Rumpf ein `PrintLn` mit einer Marke, die im Erzeugnis nachweisbar ist.
cat > "$T/m.lyx" <<'LYXM'
unit main;

// NUR aus einem Methodenrumpf gerufen. Mit dem Defekt aus #2588 fiel sie weg.
fn nurAusMethode(): int64 {
  PrintLn("MARKE-2588-AUS-METHODE"c);
  return 11;
}

// Transitiv: nurAusMethode ruft diese nicht, aber die Methode ruft beide --
// die zweite Kante darf nicht an einer Stufe haengen bleiben.
fn tiefAusMethode(): int64 {
  PrintLn("MARKE-2588-TIEF"c);
  return 22;
}

// Nie gerufen, von nirgends. Muss WEGFALLEN -- sonst waere der Test auch von
// einer Analyse erfuellt, die einfach alles behaelt.
fn niemandRuftMich(): int64 {
  PrintLn("MARKE-2588-TOT"c);
  return 99;
}

type Rechner = class {
  wert: int64;
  pub fn Summe(): int64 {
    return nurAusMethode() + tiefAusMethode();
  }
};

fn main(): int64 {
  var r: Rechner := new Rechner();
  if (r.Summe() != 33) { return 1; }
  return 0;
}
LYXM

if "$LYXC" --std-path="$ROOT" --gc-functions "$T/m.lyx" -o "$T/m.bin" >"$T/m.log" 2>&1; then
  ok "eine nur aus einem Methodenrumpf gerufene Funktion bleibt erhalten (#2588)"
  # Die WIRKUNG, nicht das Uebersetzen: beide Marken muessen im Erzeugnis
  # stehen und das Programm muss 0 liefern.
  if grep -q "MARKE-2588-AUS-METHODE" "$T/m.bin" && grep -q "MARKE-2588-TIEF" "$T/m.bin"; then
    ok "beide aus der Methode gerufenen Ruempfe stehen im Erzeugnis"
  else
    nok "ein aus der Methode gerufener Rumpf fehlt im Erzeugnis"
  fi
  "$T/m.bin" >"$T/m.out" 2>&1
  mrc=$?
  if [ "$mrc" = "0" ]; then
    ok "das Programm rechnet 11+22=33 (die Ruempfe sind da und richtig)"
  else
    nok "Programm endete mit rc=$mrc -- fehlender Rumpf oder falsches Ergebnis"
  fi
  # Gegenprobe: die von nirgends gerufene Funktion MUSS weg sein.
  if grep -q "MARKE-2588-TOT" "$T/m.bin"; then
    nok "niemandRuftMich steht noch im Erzeugnis -- die Analyse verwirft nichts mehr"
  else
    ok "die von nirgends gerufene Funktion faellt weiter weg (die Analyse wirkt noch)"
  fi
else
  nok "uebersetzt nicht mit --gc-functions (#2588)"
  grep -m3 -iE "error" "$T/m.log" | sed 's/^/    /'
fi

echo "RESULT: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
