#!/usr/bin/env bash
# tests/ir_nachlauf_methoden_test.sh — #2063: der Erreichbarkeitsfilter
# erzeugt auch die freie Funktion, die erst eine METHODE braucht.
#
# Bei einem Import erzeugt der IR-Weg nur Rumpfe, die gerufen werden (#1727).
# Weil eine Markierung zu spaet kommen kann — die gerufene Funktion steht im
# Quelltext VOR dem Rufer —, wiederholt ein Nachlauf den Durchgang, "bis er
# nichts Neues mehr erzeugt". Den Fortschritt meldete aber nur der Zweig fuer
# freie Funktionen. Seit #1783 gilt der Filter auch fuer Methoden; die
# Buchfuehrung kam nicht mit.
#
# Entstand in einer Runde allein eine Methode, endete der Nachlauf, und die
# freie Funktion, die diese Methode ruft, bekam nie einen Rumpf. Der Aufruf
# lief ins Leere — uebersetzt fehlerfrei, Ergebnis 0 oder ein Registerinhalt.
# So kam `TextFromPchar("hello").ByteLength()` auf arm64 und riscv auf 0.
#
# GEMESSEN WIRD DER WERT, den die Funktion liefert. Dass das Programm
# uebersetzt und mit irgendeinem Rueckgabewert endet, war vorher auch so.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
. "$(dirname "$0")/lib/qemu.sh"   # #2048: beide Paketnamen
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
mkdir -p "$TMP/w/bib"

# $1 Beschreibung, $2 Quelle (relativ zu $TMP/w), $3 erwarteter Rueckgabewert
alle_ziele() {
  local was="$1" src="$2" erw="$3" ziel
  for ziel in x86_64 arm64 riscv; do
    local bin="$TMP/b_${ziel}" pre=""
    if ! ( cd "$TMP/w" && timeout 300 "$LYXC" --std-path="$ROOT" --target="$ziel" "$src" -o "$bin" ) >"$TMP/bl.log" 2>&1; then
      nok "$was [$ziel]: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
      continue
    fi
    case "$ziel" in
      arm64) [ -n "$QEMU_ARM64" ]   || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_ARM64" ;;
      riscv) [ -n "$QEMU_RISCV64" ] || { nok "$was [$ziel]: qemu fehlt — NICHT gemessen"; continue; }; pre="$QEMU_RISCV64" ;;
    esac
    local rc
    rc="$( ( timeout 60 $pre "$bin" >/dev/null 2>&1 ) 2>/dev/null; echo $? )"
    if [ "$rc" = "$erw" ]; then ok "$was [$ziel] (rc=$rc)"
    else nok "$was [$ziel]: rc=$rc statt $erw"; fi
  done
}

echo "--- #2063: eine Methode ruft eine freie Funktion ihres Moduls ---"
#
# Der Kernfall, und die Reihenfolge ist wesentlich: die freie Funktion steht
# VOR der Klasse. Im ersten Durchgang ist sie noch nicht gebraucht und wird
# uebergangen; gebraucht wird sie erst, wenn der Rumpf der Methode entsteht.
# Vor dem Fix: arm64 lieferte 2 (das unveraenderte Argument), riscv 0.
cat > "$TMP/w/bib/privat.lyx" <<'EOF'
unit bib.privat;
fn _hilf(x: int64): int64 { return x + 5; }
pub type T = class { n: int64;
  fn Setz(x: int64) { self.n := _hilf(x); }
  fn Hol(): int64 { return self.n; } };
EOF
cat > "$TMP/w/privat.lyx" <<'EOF'
unit main;
import bib.privat;
fn main(): int64 { var t: T := new T(); t.Setz(2); return t.Hol(); }
EOF
alle_ziele "private Funktion, gerufen aus einer Methode" "privat.lyx" 7

# Dass sie privat ist, spielt keine Rolle — derselbe Fall mit `pub`.
cat > "$TMP/w/bib/oeffentlich.lyx" <<'EOF'
unit bib.oeffentlich;
pub fn Hilf(x: int64): int64 { return x + 5; }
pub type T = class { n: int64;
  fn Setz(x: int64) { self.n := Hilf(x); }
  fn Hol(): int64 { return self.n; } };
EOF
cat > "$TMP/w/oeffentlich.lyx" <<'EOF'
unit main;
import bib.oeffentlich;
fn main(): int64 { var t: T := new T(); t.Setz(2); return t.Hol(); }
EOF
alle_ziele "pub-Funktion, gerufen aus einer Methode" "oeffentlich.lyx" 7

echo
echo "--- die Form aus std/text.lyx: Ergebnis als ARGUMENT eines Selbstaufrufs ---"
#
# `self.InitFromUtf8(p, _pcharLen(p))` — an dieser Stelle ist es aufgefallen.
cat > "$TMP/w/bib/arg.lyx" <<'EOF'
unit bib.arg;
fn _hilf(x: int64): int64 { return x + 5; }
pub type T = class { n: int64;
  fn Innen(a: int64, b: int64) { self.n := a + b; }
  fn Setz(x: int64) { self.Innen(x, _hilf(x)); }
  fn Hol(): int64 { return self.n; } };
EOF
cat > "$TMP/w/arg.lyx" <<'EOF'
unit main;
import bib.arg;
fn main(): int64 { var t: T := new T(); t.Setz(2); return t.Hol(); }
EOF
alle_ziele "self.Innen(x, _hilf(x))" "arg.lyx" 9

echo
echo "--- eine KETTE: Methode -> Funktion -> Funktion -> Funktion ---"
#
# Jede Stufe steht vor ihrem Rufer, braucht also eine eigene Runde. Ein
# Nachlauf, der nach der ersten Fortschrittsmeldung nur EINE weitere Runde
# dreht, kaeme bis _b und liesse _a und _c ohne Rumpf.
cat > "$TMP/w/bib/kette.lyx" <<'EOF'
unit bib.kette;
fn _c(x: int64): int64 { return x + 1; }
fn _b(x: int64): int64 { return _c(x) * 2; }
fn _a(x: int64): int64 { return _b(x) + 3; }
pub type T = class { n: int64;
  fn Setz(x: int64) { self.n := _a(x); }
  fn Hol(): int64 { return self.n; } };
EOF
cat > "$TMP/w/kette.lyx" <<'EOF'
unit main;
import bib.kette;
fn main(): int64 { var t: T := new T(); t.Setz(4); return t.Hol(); }
EOF
alle_ziele "drei Stufen hinter einer Methode: ((4+1)*2)+3" "kette.lyx" 13

echo
echo "--- Methode -> Methode -> Funktion ---"
#
# Die zweite Methode wird erst durch die erste gebraucht. Entsteht sie in
# einer spaeteren Runde, muss auch DAS als Fortschritt zaehlen — sonst fehlt
# die Funktion dahinter wieder.
cat > "$TMP/w/bib/zwei.lyx" <<'EOF'
unit bib.zwei;
fn _hilf(x: int64): int64 { return x * 3; }
pub type T = class { n: int64;
  fn Tief(x: int64): int64 { return _hilf(x) + 1; }
  fn Setz(x: int64) { self.n := self.Tief(x); }
  fn Hol(): int64 { return self.n; } };
EOF
cat > "$TMP/w/zwei.lyx" <<'EOF'
unit main;
import bib.zwei;
fn main(): int64 { var t: T := new T(); t.Setz(5); return t.Hol(); }
EOF
alle_ziele "Methode ruft Methode ruft Funktion: 5*3+1" "zwei.lyx" 16

echo
echo "--- GEGENPROBE: der Weg ueber eine freie Funktion ging schon immer ---"
#
# Haelt fest, dass der Fehler an der METHODE hing und nicht am Import — und
# dass der Fix diesen Weg nicht veraendert.
cat > "$TMP/w/bib/frei.lyx" <<'EOF'
unit bib.frei;
fn _hilf(x: int64): int64 { return x + 5; }
pub fn Frei(x: int64): int64 { return _hilf(x); }
EOF
cat > "$TMP/w/frei.lyx" <<'EOF'
unit main;
import bib.frei;
fn main(): int64 { return Frei(2); }
EOF
alle_ziele "private Funktion hinter einer freien pub-Funktion" "frei.lyx" 7

echo
echo "--- der Filter filtert weiter: ein ungerufener RUMPF bleibt draussen ---"
#
# Die andere Seite. Ein "Fix", der einfach alles erzeugt, bestuende jede
# Pruefung oben — und braechte #1783 zurueck (eine nie gerufene Methode mit
# Gleitkomma machte `import std.io` auf freistehenden Zielen unbaubar).
#
# Gemessen am Erzeugnis, und zwar so, dass nur der Rumpf den Unterschied
# machen kann: zweimal derselbe Import mit einer nie gerufenen Funktion und
# einer nie gerufenen Methode, einmal mit kurzem, einmal mit langem Rumpf.
# Kaeme der Rumpf ins Erzeugnis, waere die lange Fassung groesser.
#
# (Fuer jede registrierte, aber nicht erzeugte Funktion bleibt eine leere
# Huelle von wenigen Befehlen stehen. Die ist in beiden Fassungen gleich und
# deshalb hier kein Stoerfaktor — und kein Gegenstand dieses Tests.)
ballast() {  # $1 Name, $2 Zahl der Anweisungen im ungerufenen Rumpf
  {
    echo "unit bib.$1;"
    echo "fn _hilf(x: int64): int64 { return x + 5; }"
    echo "fn _niemand(x: int64): int64 {"
    echo "  var a: int64 := x;"
    local i=0
    while [ "$i" -lt "$2" ]; do echo "  a := a * 3 + $i;"; i=$((i+1)); done
    echo "  return a;"
    echo "}"
    echo "pub type T = class { n: int64;"
    echo "  fn Setz(x: int64) { self.n := _hilf(x); }"
    echo "  fn Ungerufen(x: int64): int64 { return _niemand(x) + _niemand(x + 1); }"
    echo "  fn Hol(): int64 { return self.n; } };"
  } > "$TMP/w/bib/$1.lyx"
  printf 'unit main;\nimport bib.%s;\nfn main(): int64 { var t: T := new T(); t.Setz(2); return t.Hol(); }\n' "$1" > "$TMP/w/$1.lyx"
}
ballast kurz 4
ballast lang 120
# Nur die IR-Ziele: den Erreichbarkeitsfilter gibt es auf dem x86-Schnellweg
# nicht, dort wird jeder importierte Rumpf erzeugt. Das ist ein eigenes Thema
# und kein Befund dieses Tests.
for ziel in arm64 riscv; do
  if ( cd "$TMP/w" && timeout 300 "$LYXC" --std-path="$ROOT" --target="$ziel" kurz.lyx -o "$TMP/k_$ziel" \
       && timeout 300 "$LYXC" --std-path="$ROOT" --target="$ziel" lang.lyx -o "$TMP/l_$ziel" ) >"$TMP/bl.log" 2>&1; then
    gk="$(stat -c %s "$TMP/k_$ziel")"; gl="$(stat -c %s "$TMP/l_$ziel")"
    if [ "$gk" = "$gl" ]; then
      ok "$ziel: ein ungerufener Rumpf kommt nicht ins Erzeugnis (kurz wie lang $gk Byte)"
    else
      nok "$ziel: die Laenge des ungerufenen Rumpfs aendert das Erzeugnis ($gk -> $gl Byte) — er wird erzeugt"
    fi
  else
    nok "$ziel: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
  fi
done

echo
echo "--- #2063: der Nachlauf registriert nicht jede Runde neu ---"
#
# Der Vorpass von lowerModule haengte bei JEDEM Durchgang alle Funktionen des
# Moduls erneut an die Funktionstabelle, ohne Dublettenpruefung; fuer jeden
# Eintrag ohne Rumpf erzeugt das Backend eine leere Huelle. Je mehr Runden der
# Nachlauf drehte, desto mehr Huellen.
#
# Gemessen an der Kette von oben: sie braucht mehrere Runden. Ein zweiter
# Import mit zwanzig nie gerufenen Funktionen darf das Erzeugnis hoechstens
# um zwanzig Huellen wachsen lassen — nicht um zwanzig je Runde. Die Schranke
# (48 Byte je Funktion) liegt ueber dem, was heute bleibt (arm64: zwei
# Eintraege zu 20 Byte — einer aus der Import-Registrierung, einer aus dem
# ersten Durchgang) und unter dem alten Verhalten (60 Byte nach einer
# Nachlaufrunde, 140 nach fuenf).
{
  echo "unit bib.viele;"
  echo "fn _c(x: int64): int64 { return x + 1; }"
  echo "fn _b(x: int64): int64 { return _c(x) * 2; }"
  echo "fn _a(x: int64): int64 { return _b(x) + 3; }"
  i=0; while [ "$i" -lt 20 ]; do echo "fn _nie$i(x: int64): int64 { return x + $i; }"; i=$((i+1)); done
  echo "pub type T = class { n: int64;"
  echo "  fn Setz(x: int64) { self.n := _a(x); }"
  echo "  fn Hol(): int64 { return self.n; } };"
} > "$TMP/w/bib/viele.lyx"
printf 'unit main;\nimport bib.viele;\nfn main(): int64 { var t: T := new T(); t.Setz(4); return t.Hol(); }\n' > "$TMP/w/viele.lyx"
if ( cd "$TMP/w" && timeout 300 "$LYXC" --std-path="$ROOT" --target=arm64 kette.lyx -o "$TMP/ke" \
     && timeout 300 "$LYXC" --std-path="$ROOT" --target=arm64 viele.lyx -o "$TMP/vi" ) >"$TMP/bl.log" 2>&1; then
  gke="$(stat -c %s "$TMP/ke")"; gvi="$(stat -c %s "$TMP/vi")"
  zuw=$(( gvi - gke ))
  if [ "$zuw" -le $(( 20 * 48 )) ]; then
    ok "arm64: zwanzig ungerufene Funktionen kosten $zuw Byte ($(( zuw / 20 )) je Funktion) — keine Huelle je Runde"
  else
    nok "arm64: zwanzig ungerufene Funktionen kosten $zuw Byte ($(( zuw / 20 )) je Funktion) — der Nachlauf registriert wieder jede Runde"
  fi
else
  nok "arm64: uebersetzt nicht ($(grep -m1 -E '^lyxc:|error' "$TMP/bl.log"))"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
