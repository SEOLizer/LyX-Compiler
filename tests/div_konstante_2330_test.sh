#!/usr/bin/env bash
# tests/div_konstante_2330_test.sh — #2330: Division und Rest durch eine
# konstante Zweierpotenz ohne idiv.
#
# `idiv r64` kostet auf Skylake 36 bis 95 Takte. Fuer einen Divisor, der eine
# Zweierpotenz ist, geht es mit Shift und Maske — aber NICHT naiv:
#
#   VORZEICHENBEHAFTET ist `x / 2^k` nicht `sar x, k`. Der Shift rundet gegen
#   minus unendlich, Lyx (wie C) rundet gegen null: -7 / 2 ist -3, `sar`
#   liefert -4. Deshalb wird (2^k - 1) addiert, bevor geschoben wird, und zwar
#   nur bei negativem Wert.
#
# Geprueft wird deshalb in drei Richtungen:
#
#   1. DIFFERENTIELL gegen die unveraenderte Fassung: derselbe Divisor einmal
#      als Konstante (neuer Weg) und einmal durch eine Variable verdeckt
#      (idiv). Beide muessen bitgleiche Ergebnisse liefern — ueber alle
#      Vorzeichenkombinationen und die Grenzwerte INT64_MIN/MAX.
#   2. AM ERZEUGNIS, beide Seiten: ein Programm mit konstanter Zweierpotenz
#      darf KEINE Division enthalten, eines mit variablem Divisor muss eine
#      enthalten. Ohne die zweite Haelfte wuerde der Test auch bestehen, wenn
#      gar nicht umgeformt wird.
#   3. GEGENSEITE DER ERKENNUNG: ein Divisor, den die Bedingung NICHT trifft,
#      muss weiter ueber die Division laufen und richtig rechnen. Sonst waere
#      nicht belegt, dass die Bedingung eng genug ist.
#
#      Dieser Nachweis stand bis 1.2.26K auf dem Divisor 1000 — und wurde
#      damit rot, sobald #2330 Schritt 2 auch den allgemeinen konstanten
#      Divisor per Multiplikation erledigte. Genau der Fall, vor dem
#      CLAUDE.md warnt: ein Test darf nicht voraussetzen, dass eine Luecke
#      offen bleibt. Die Gegenseite steht deshalb jetzt auf einem Divisor,
#      den BEIDE Schritte ablehnen: 6148914691236517206 liegt ueber 2^62
#      (Schritt 2 braucht die Kopffreiheit fuer seine Schleifenschranke) und
#      ist keine Zweierpotenz. Dass 1000 richtig rechnet, wird weiter
#      geprueft — nur nicht mehr daran, dass es LANGSAM rechnet.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

baue() { printf '%s' "$2" > "$TMP/$1.lyx"
         (cd "$TMP" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/$1.lyx" -o "$TMP/$1" >"$TMP/$1.log" 2>&1); }

divzahl() {   # Datei -> Anzahl div/idiv (48 F7 /6 oder /7)
  python3 -I - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
print(sum(1 for i in range(len(d)-2)
          if d[i] == 0x48 and d[i+1] == 0xF7 and (d[i+2] >> 3 & 7) in (6, 7)))
PY
}

# ---------------------------------------------------------------- 1
Q_DIFF='unit main;
import std.io;
fn dk(x: int64, w: int64): int64 {
  if (w == 1) { return x / 2; }
  if (w == 2) { return x % 2; }
  if (w == 3) { return x / 8; }
  if (w == 4) { return x % 8; }
  if (w == 5) { return x / 1024; }
  if (w == 6) { return x % 1024; }
  if (w == 7) { return x / 1000; }
  if (w == 8) { return x % 1000; }
  return 0;
}
fn dv(x: int64, w: int64, d: int64): int64 {
  if (w == 1 || w == 3 || w == 5 || w == 7) { return x / d; }
  return x % d;
}
fn main(): int64 {
  var v: int64 := alloc(256);
  var n: int64 := 0;
  poke64(v + n * 8, 0); n += 1;
  poke64(v + n * 8, 1); n += 1;
  poke64(v + n * 8, 2); n += 1;
  poke64(v + n * 8, 7); n += 1;
  poke64(v + n * 8, 8); n += 1;
  poke64(v + n * 8, 9); n += 1;
  poke64(v + n * 8, 999); n += 1;
  poke64(v + n * 8, 1000); n += 1;
  poke64(v + n * 8, 1023); n += 1;
  poke64(v + n * 8, 1024); n += 1;
  poke64(v + n * 8, 1025); n += 1;
  poke64(v + n * 8, 0 - 1); n += 1;
  poke64(v + n * 8, 0 - 2); n += 1;
  poke64(v + n * 8, 0 - 7); n += 1;
  poke64(v + n * 8, 0 - 8); n += 1;
  poke64(v + n * 8, 0 - 9); n += 1;
  poke64(v + n * 8, 0 - 999); n += 1;
  poke64(v + n * 8, 0 - 1000); n += 1;
  poke64(v + n * 8, 0 - 1023); n += 1;
  poke64(v + n * 8, 0 - 1024); n += 1;
  poke64(v + n * 8, 9223372036854775807); n += 1;
  poke64(v + n * 8, 0 - 9223372036854775807 - 1); n += 1;
  var dd: int64 := alloc(128);
  poke64(dd, 2); poke64(dd + 8, 2); poke64(dd + 16, 8); poke64(dd + 24, 8);
  poke64(dd + 32, 1024); poke64(dd + 40, 1024); poke64(dd + 48, 1000); poke64(dd + 56, 1000);
  var fehler: int64 := 0;
  var i: int64 := 0;
  while (i < n) {
    var x: int64 := peek64(v + i * 8);
    var w: int64 := 1;
    while (w <= 8) {
      var a: int64 := dk(x, w);
      var b: int64 := dv(x, w, peek64(dd + (w - 1) * 8));
      if (a != b) {
        PrintStr("ABWEICHUNG x="); PrintInt(x); PrintStr(" w="); PrintInt(w);
        PrintStr(" konst="); PrintInt(a); PrintStr(" var="); PrintInt(b); PrintStr("\n");
        fehler += 1;
      }
      w += 1;
    }
    i += 1;
  }
  PrintStr("geprueft="); PrintInt(n * 8);
  PrintStr(" abweichungen="); PrintInt(fehler); PrintStr("\n");
  return 0;
}'
if ! baue diff "$Q_DIFF"; then
  no "differentiell uebersetzen" "$(grep -v Copyright "$TMP/diff.log" | grep -m1 -iE 'error|lyxc:')"
else
  aus=$( cd "$TMP" && timeout 60 ./diff 2>&1 | tail -1 )
  if [ "$aus" = "geprueft=176 abweichungen=0" ]; then
    ok "differentiell: 176 Faelle, keine Abweichung (inkl. negativ, INT64_MIN/MAX)"
  else
    no "differentiell" "$aus"
  fi
fi

# ---------------------------------------------------------------- 2
Q_KONST='unit main;
import std.io;
fn f(x: int64): int64 { return (x / 8) + (x % 1024) + (x / 2); }
fn main(): int64 { PrintInt(f(12345)); PrintStr("\n"); return 0; }'
Q_VAR='unit main;
import std.io;
fn f(x: int64, d: int64): int64 { return (x / d) + (x % d); }
fn main(): int64 { PrintInt(f(12345, 8)); PrintStr("\n"); return 0; }'
if baue konst "$Q_KONST" && baue vari "$Q_VAR"; then
  nk=$(divzahl "$TMP/konst"); nv=$(divzahl "$TMP/vari")
  # Der Rumpf ist in beiden gleich gross; die stdlib bringt in beiden
  # denselben Grundbestand an Divisionen mit (IntToStr rechnet / 10 und % 10).
  # Verglichen wird deshalb die DIFFERENZ, nicht die absolute Zahl.
  if [ "$nv" -gt "$nk" ]; then
    ok "erzeugnis: konstante Zweierpotenz kommt ohne Division aus ($nk gegen $nv beim variablen Divisor)"
  else
    no "erzeugnis" "konstant $nk, variabel $nv — die Umformung greift nicht"
  fi
  a=$( cd "$TMP" && timeout 30 ./konst 2>&1 ); b=$( cd "$TMP" && timeout 30 ./vari 2>&1 )
  # Gegengerechnet: 12345/8 = 1543, 12345 % 1024 = 12345 - 12*1024 = 57,
  # 12345/2 = 6172 (gegen null gerundet). Summe 7772.
  if [ "$a" = "7772" ]; then ok "konstante Fassung rechnet richtig (7772)"; else no "konstante Fassung" "'$a' erwartet 7772"; fi
  if [ "$b" = "1544" ]; then ok "variable Fassung rechnet richtig (1544)"; else no "variable Fassung" "'$b' erwartet 1544"; fi
fi

# ---------------------------------------------------------------- 3
# 1000 ist keine Zweierpotenz und muss richtig rechnen. SEIT #2330 Schritt 2
# laeuft es allerdings ebenfalls ohne idiv (Multiplikation mit Faktor), taugt
# also nicht mehr als Nachweis dafuer, dass die Zweierpotenz-Bedingung eng
# ist. Der Wert wird weiter geprueft, der Weg nicht mehr.
Q_NICHTPOT='unit main;
import std.io;
fn f(x: int64): int64 { return (x / 1000) + (x % 1000); }
fn main(): int64 { PrintInt(f(12345)); PrintStr("\n"); return 0; }'
if baue nichtpot "$Q_NICHTPOT"; then
  aus=$( cd "$TMP" && timeout 30 ./nichtpot 2>&1 )
  if [ "$aus" = "357" ]; then ok "kein Zweierpotenz-Divisor rechnet richtig (357)"; else no "nicht-Zweierpotenz" "'$aus' erwartet 357"; fi
fi

# Die eigentliche Gegenseite: ein Divisor, den BEIDE Schritte ablehnen.
# 6148914691236517206 liegt ueber 2^62 und ist keine Zweierpotenz, muss also
# die Division behalten. 12345 / 6148914691236517206 ist 0, der Rest 12345.
Q_ABGELEHNT='unit main;
import std.io;
fn f(x: int64): int64 { return (x / 6148914691236517206) + (x % 6148914691236517206); }
fn main(): int64 { PrintInt(f(12345)); PrintStr("\n"); return 0; }'
if baue abgelehnt "$Q_ABGELEHNT"; then
  aus=$( cd "$TMP" && timeout 30 ./abgelehnt 2>&1 )
  if [ "$aus" = "12345" ]; then ok "abgelehnter Divisor rechnet richtig (12345)"; else no "abgelehnter Divisor" "'$aus' erwartet 12345"; fi
  nn=$(divzahl "$TMP/abgelehnt"); nk2=$(divzahl "$TMP/konst")
  if [ "$nn" -gt "$nk2" ]; then
    ok "erzeugnis: abgelehnter Divisor laeuft weiter ueber die Division ($nn gegen $nk2)"
  else
    no "gegenseite" "umgeformt trotz Ablehnung ($nn gegen $nk2) — die Bedingung ist zu weit"
  fi
fi

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
