#!/usr/bin/env bash
# tests/wcet_test.sh — #1139: `@wcet(N)` wird nachgewiesen.
#
# Bis 1.0.14K war das Attribut ein blosser Vermerk: geparst, in seiner
# Argumentform geprueft, am Knoten notiert -- und seit #1099 meldete jedes
# Vorkommen, dass die Zusicherung NICHT nachgewiesen wird.
#
# EINHEIT: N zaehlt ITERATIONEN, nicht Zyklen. Eine Zyklenzahl braeuchte ein
# Mikroarchitekturmodell; jede Zahl in einer Kostentabelle waere erfunden und
# damit ein Beweisanschein. Iterationen sind das, was am Baum abzaehlbar ist.
#
# Gezaehlt wird kumulativ: eine Schleife mit Schranke B, in deren Rumpf I
# Iterationen stecken, traegt B * (1 + I) bei. Zwei geschachtelte Zehnerschleifen
# ergeben also 10 + 100 = 110 -- die Zahl der Durchlaeufe, die wirklich
# stattfinden. Der Test haelt beide Seiten fest: 110 geht durch, 109 nicht.
#
# NICHT nachweisbar ist ein FEHLER, kein stiller Durchlass: berechnete
# Schleifengrenzen, `repeat/until`, das C-artige `for`, Rekursion (auch
# indirekt) und der Aufruf einer Funktion ohne eigene Schranke.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fails() { # name, quelltext, erwarteter meldungsteil
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  msg="$("$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)"
  if [ -f "$TMP/c" ]; then echo "FAIL $1: uebersetzt, statt zu melden"; FAIL=$((FAIL+1)); return; fi
  case "$msg" in
    *"$3"*) echo "PASS $1"; PASS=$((PASS+1)) ;;
    *) echo "FAIL $1: Meldung ohne '$3'"; FAIL=$((FAIL+1)) ;;
  esac
}

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

K='import src.std.io;'

# --- Der Repro aus dem Issue ---------------------------------------------
fails "Repro: Schranke 10, Rumpf laeuft eine Million Mal" "$K
@wcet(10)
fn Endlos(): int64 { var i: int64 := 0; while (i < 1000000) { i := i + 1; } return i; }
fn main(): int64 { PrintLn(Endlos()); return 0; }" "@wcet(10) verletzt — der Rumpf laeuft bis zu 1000000 Iterationen"

# Die Meldung nennt beide Zahlen. Ohne die tatsaechliche Iterationszahl weiss
# man nicht, auf welchen Wert man die Schranke setzen muesste.
fails "Meldung nennt Schranke und Iterationen" "$K
@wcet(5)
fn F(): int64 { var s: int64 := 0; for i := 1 to 20 { s := s + 1; } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" "@wcet(5) verletzt — der Rumpf laeuft bis zu 20 Iterationen"

# --- Die abzaehlbaren Schleifenformen ------------------------------------
out "for ... to unter der Schranke" "$K
@wcet(1000)
fn Ok(): int64 { var s: int64 := 0; for i := 0 to 999 { s := s + i; } return s; }
fn main(): int64 { PrintLn(Ok()); return 0; }" '499500'

out "for i in a..b (Grenzen einschliesslich)" "$K
@wcet(10)
fn F(): int64 { var s: int64 := 0; for i in 1..10 { s := s + i; } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" '55'

out "for i in range(a, b) (Ende ausschliessend)" "$K
@wcet(5)
fn F(): int64 { var s: int64 := 0; for i in range(0, 5) { s := s + i; } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" '10'

out "downto zaehlt genauso" "$K
@wcet(5)
fn F(): int64 { var s: int64 := 0; for i := 5 downto 1 { s := s + i; } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" '15'

# `while (i < C)` mit literalem Start und fester Schrittweite ist abzaehlbar.
out "while mit Zaehler und konstanter Grenze" "$K
@wcet(10)
fn F(): int64 { var i: int64 := 0; while (i < 10) { i := i + 1; } return i; }
fn main(): int64 { PrintLn(F()); return 0; }" '10'

# Schrittweite 2 halbiert die Durchlaeufe -- die Rechnung muss sie kennen.
out "Schrittweite geht in die Rechnung ein" "$K
@wcet(5)
fn F(): int64 { var i: int64 := 0; while (i < 10) { i := i + 2; } return i; }
fn main(): int64 { PrintLn(F()); return 0; }" '10'

# `while (c) limit(N)` (#1103) gibt die Schranke ausdruecklich an -- damit ist
# auch eine berechnete Bedingung abzaehlbar.
out "while mit limit(N)" "$K
@wcet(50)
fn L(n: int64): int64 { var i: int64 := 0; while (i < n) limit(50) { i := i + 1; } return i; }
fn main(): int64 { PrintLn(L(3)); return 0; }" '3'

# --- Geschachtelt: 10 + 10*10 = 110 --------------------------------------
out "geschachtelte Schleifen, Schranke genau erreicht" "$K
@wcet(110)
fn F(): int64 { var s: int64 := 0; for i := 1 to 10 { for j := 1 to 10 { s := s + 1; } } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" '100'

fails "geschachtelte Schleifen, eine Iteration zu viel" "$K
@wcet(109)
fn F(): int64 { var s: int64 := 0; for i := 1 to 10 { for j := 1 to 10 { s := s + 1; } } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" "bis zu 110 Iterationen"

# --- Was NICHT nachweisbar ist, wird abgewiesen --------------------------
fails "berechnete Schleifengrenze" "$K
@wcet(100)
fn G(n: int64): int64 { var i: int64 := 0; while (i < n) { i := i + 1; } return i; }
fn main(): int64 { PrintLn(G(3)); return 0; }" "die while-Schleife hat keine abzaehlbare Durchlaufzahl"

fails "repeat/until" "$K
@wcet(100)
fn P(): int64 { var i: int64 := 0; repeat { i := i + 1; } until (i > 5); return i; }
fn main(): int64 { PrintLn(P()); return 0; }" "\`repeat/until\` hat keine abzaehlbare Durchlaufzahl"

fails "Rekursion" "$K
@wcet(100)
fn R(n: int64): int64 { if (n <= 0) { return 0; } return R(n - 1); }
fn main(): int64 { PrintLn(R(3)); return 0; }" "die Funktion ist rekursiv"

# Auch ein INDIREKTER Zyklus -- dafuer gibt es den Aufrufgraphen (#1138).
fails "indirekte Rekursion" "$K
@wcet(100)
fn A(n: int64): int64 { if (n <= 0) { return 0; } return B(n - 1); }
@wcet(100)
fn B(n: int64): int64 { return A(n - 1); }
fn main(): int64 { PrintLn(A(4)); return 0; }" "die Funktion ist rekursiv"

# Zwei Fortschaltungen koennen einander aufheben; dann ist nichts abzuzaehlen.
fails "zwei Zuweisungen an den Zaehler" "$K
@wcet(100)
fn F(): int64 { var i: int64 := 0; while (i < 10) { i := i + 2; i := i - 1; } return i; }
fn main(): int64 { PrintLn(F()); return 0; }" "keine abzaehlbare Durchlaufzahl"

# --- Aufrufe -------------------------------------------------------------
fails "Aufruf einer Funktion ohne eigene Schranke" "$K
@wcet(10)
fn A(): int64 { return B(); }
fn B(): int64 { return 1; }
fn main(): int64 { PrintLn(A()); return 0; }" "\`B\` hat selbst kein @wcet"

# Importiertes ist hier gar nicht sichtbar -- auch das ist kein Nachweis.
fails "Aufruf einer importierten Funktion" "$K
@wcet(10)
fn A(): int64 { PrintStrLn(\"x\"); return 1; }
fn main(): int64 { PrintLn(A()); return 0; }" "liegt nicht in dieser Einheit"

# Traegt der Gerufene eine Schranke, geht sie in die Summe ein:
# 5 Durchlaeufe x (1 + 3 aus B) = 20.
out "Aufruf einer Funktion mit eigener Schranke" "$K
@wcet(20)
fn A(): int64 { var s: int64 := 0; for i := 1 to 5 { s := s + B(); } return s; }
@wcet(3)
fn B(): int64 { var s: int64 := 0; for i := 1 to 3 { s := s + 1; } return s; }
fn main(): int64 { PrintLn(A()); return 0; }" '15'

fails "Aufruf mit Schranke, Summe zu gross" "$K
@wcet(19)
fn A(): int64 { var s: int64 := 0; for i := 1 to 5 { s := s + B(); } return s; }
@wcet(3)
fn B(): int64 { var s: int64 := 0; for i := 1 to 3 { s := s + 1; } return s; }
fn main(): int64 { PrintLn(A()); return 0; }" "bis zu 20 Iterationen"

# Die Speicher-Builtins erzeugen geradlinigen Code -- sie kosten nichts. Die
# Liste steht in src/frontend/wcet.lyx und in §20.1, damit sie nachpruefbar
# bleibt statt als stiller Default zu wirken.
out "peek/poke kosten nichts" "$K
@wcet(4)
fn F(p: int64): int64 {
    poke64(p, 0);
    for i := 1 to 4 { poke64(p, peek64(p) + i); }
    return peek64(p);
}
fn main(): int64 { var p: int64 := alloc(16); PrintLn(F(p)); return 0; }" '10'

# --- Methoden ------------------------------------------------------------
# Am Methodenknoten belegen die Modifier-Bits die iVal; ohne eigenen Zweig
# waere der Wert dort verloren und das Attribut still wirkungslos.
fails "Methode verletzt ihre Schranke" "$K
type C = class { v: int64;
  @wcet(2)
  fn G(): int64 { var s: int64 := 0; for i := 1 to 100 { s := s + 1; } return s; }
};
fn main(): int64 { var c: C := new C(); PrintLn(c.G()); return 0; }" "@wcet(2) verletzt"

out "Methode haelt ihre Schranke" "$K
type C = class { v: int64;
  @wcet(100)
  fn G(): int64 { var s: int64 := 0; for i := 1 to 100 { s := s + 1; } return s; }
};
fn main(): int64 { var c: C := new C(); PrintLn(c.G()); return 0; }" '100'

# --- Die Argumentform bleibt geprueft (#1099) ----------------------------
fails "Schranke 0 wird abgewiesen" "$K
@wcet(0)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }" "wcet"

# --- Gegenproben: ohne das Attribut aendert sich nichts ------------------
out "dieselbe Schleife ohne @wcet" "$K
fn F(): int64 { var i: int64 := 0; while (i < 1000000) { i := i + 1; } return i; }
fn main(): int64 { PrintLn(F()); return 0; }" '1000000'

out "Rekursion ohne @wcet bleibt erlaubt" "$K
fn Fak(n: int64): int64 { if (n <= 1) { return 1; } return n * Fak(n - 1); }
fn main(): int64 { PrintLn(Fak(5)); return 0; }" '120'

# Das Attribut wirkt nur auf die annotierte Funktion.
out "unannotierte Nachbarfunktion bleibt unberuehrt" "$K
@wcet(5)
fn Sicher(): int64 { var s: int64 := 0; for i := 1 to 5 { s := s + 1; } return s; }
fn Frei(n: int64): int64 { var i: int64 := 0; while (i < n) { i := i + 1; } return i; }
fn main(): int64 { PrintLn(Sicher()); PrintLn(Frei(3)); return 0; }" '5
3'

# --- Der Vermerk aus #1099 ist weg ---------------------------------------
printf '%s\n' "$K
@wcet(5)
fn F(): int64 { var s: int64 := 0; for i := 1 to 5 { s := s + 1; } return s; }
fn main(): int64 { PrintLn(F()); return 0; }" > "$TMP/w.lyx"
wmsg="$("$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" 2>&1)"
case "$wmsg" in
  *"@wcet: die Zusicherung wird vom Compiler NICHT nachgewiesen"*)
    echo "FAIL Vermerk 'nicht nachgewiesen' ist weg: steht noch da"; FAIL=$((FAIL+1)) ;;
  *) echo "PASS Vermerk 'nicht nachgewiesen' ist weg"; PASS=$((PASS+1)) ;;
esac

# Die uebrigen unbewiesenen Attribute melden weiterhin.
printf '%s\n' "$K
@integrity(crc32)
fn F(): int64 { return 1; }
fn main(): int64 { return F(); }" > "$TMP/v.lyx"
vmsg="$("$LYXC" --std-path="$ROOT" "$TMP/v.lyx" -o "$TMP/v" 2>&1)"
case "$vmsg" in
  *"NICHT nachgewiesen"*) echo "PASS @integrity meldet weiterhin"; PASS=$((PASS+1)) ;;
  *) echo "FAIL @integrity meldet weiterhin: Meldung fehlt"; FAIL=$((FAIL+1)) ;;
esac

# --- Bekannte Luecke, eigenes Issue --------------------------------------
# Ein Attribut an einer GESCHACHTELTEN Funktion (WP-13) kommt gar nicht erst
# durch den Parser: `@stack_limit(64)` ergibt dort "undefined function
# 'stack_limit'", `@packed` ein "undefined symbol". Das gilt fuer alle
# Attribute ausser @energy und ist aelter als #1139 -- eigenes Issue #1261.
# Hier steht nur der Beleg, dass es an dieser Stelle nicht still danebengeht.
printf '%s\n' "$K
fn Aussen(): int64 {
  @wcet(3)
  fn Innen(): int64 { var s: int64 := 0; for i := 1 to 10 { s := s + 1; } return s; }
  return Innen();
}
fn main(): int64 { PrintLn(Aussen()); return 0; }" > "$TMP/n.lyx"
rm -f "$TMP/n"
"$LYXC" --std-path="$ROOT" "$TMP/n.lyx" -o "$TMP/n" >/dev/null 2>&1
if [ -f "$TMP/n" ]; then
  echo "FAIL Attribut an geschachtelter fn: uebersetzt still durch"; FAIL=$((FAIL+1))
else
  echo "PASS Attribut an geschachtelter fn wird abgewiesen (bekannte Luecke)"; PASS=$((PASS+1))
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
