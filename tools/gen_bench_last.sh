#!/usr/bin/env bash
# tools/gen_bench_last.sh — erzeugt EINE Rechenlast in drei Sprachen (#2332).
#
#   tools/gen_bench_last.sh -n FUNKTIONEN -o VERZEICHNIS
#
# Geschrieben werden last.lyx, last.c und last.rs mit je FUNKTIONEN gleich
# gebauten Funktionen und einem main, das sie der Reihe nach aufruft. Die
# Fassungen rechnen Zeile fuer Zeile dasselbe; jede gibt
# `checksum=<zahl>` aus. tools/bench_vergleich.sh misst damit die
# UEBERSETZUNGSzeit mehrerer Compiler auf derselben Last und prueft vorher,
# dass alle Erzeugnisse dieselbe Pruefsumme liefern.
#
# Warum generiert und nicht von Hand: die Uebersetzungszeit eines kleinen
# Programms besteht fast nur aus Prozessstart. Erst ein paar tausend
# Funktionen trennen die Compiler voneinander. Und nur generierter Code ist
# in drei Sprachen WIRKLICH zeilenweise gleich.
#
# Zur Arithmetik: jeder Rumpf haelt die Werte klein genug, dass NICHTS
# ueberlaeuft (Maske auf 16 Bit vor der Multiplikation mit 65537) und alle
# Werte positiv bleiben. Das ist kein Zierrat:
#   * signierter Ueberlauf ist in C unbestimmtes Verhalten,
#   * in Rust bricht er im Debug-Bau ab,
#   * `>>` ist in allen drei Sprachen arithmetisch, auf positiven Werten
#     also dasselbe wie logisch (Lyx: siehe CLAUDE.md).
# Ohne diese Schranke waere ein Pruefsummenunterschied zwischen den
# Fassungen kein Compilerbefund, sondern ein Fehler dieser Datei.
set -uo pipefail
N=2000; OUT=""
while getopts "n:o:h" o; do
  case $o in
    n) N=$OPTARG ;;
    o) OUT=$OPTARG ;;
    h) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "tools/gen_bench_last.sh: -o VERZEICHNIS fehlt" >&2; exit 2; }
[ "$N" -ge 1 ] 2>/dev/null || { echo "tools/gen_bench_last.sh: -n braucht eine Zahl >= 1" >&2; exit 2; }
mkdir -p "$OUT" || exit 1

# Je Funktion vier Konstanten aus dem Index — damit kein Compiler zwei
# Rumpfe als denselben erkennt und nur einen uebersetzt.
konst() { echo $(( ( $1 * 2654435761 + $2 * 40503 ) % 60013 + 3 )); }

# ---------------------------------------------------------------- Lyx
{
  echo "// bench/last.lyx — generiert von tools/gen_bench_last.sh -n $N (#2332). NICHT von Hand aendern."
  echo "@description(\"Benchmark-Last, $N Funktionen (#2332)\")"
  echo "@author(\"Andreas Röne\")"
  echo "@copyright(\"2026 Andreas Röne\")"
  echo
  echo "import std.io;"
  echo "import std.string;"
  echo
  for ((i = 0; i < N; i++)); do
    a=$(konst "$i" 1); b=$(konst "$i" 2); c=$(konst "$i" 3); d=$(konst "$i" 4)
    cat <<EOF
fn k$i(x: int64): int64 {
  var a: int64 := x & 65535;
  a := a * 65537 + $a;
  a := a ^ (a >> 7);
  a := (a + $b) & 65535;
  a := a * 65537 + $c;
  a := a ^ (a >> 11);
  return (a + $d) & 4294967295;
}
EOF
  done
  echo "fn main(): int64 {"
  echo "  var argc: int64 := GetArgC();"
  echo "  var argv: pchar := GetArgV();"
  echo "  var wdh: int64 := 1;"
  echo "  if (argc > 1) {"
  echo "    var s: pchar := ArgvGet(argv, 1);"
  echo "    var v: int64 := StrToInt(s);"
  echo "    if (v > 0) { wdh := v; }"
  echo "  }"
  echo "  var acc: int64 := 1;"
  echo "  var w: int64 := 0;"
  echo "  while (w < wdh) {"
  for ((i = 0; i < N; i++)); do echo "    acc := k$i(acc);"; done
  echo "    w += 1;"
  echo "  }"
  echo "  PrintStr(\"checksum=\"c);"
  echo "  PrintLn(acc & 4294967295);"
  echo "  return 0;"
  echo "}"
} > "$OUT/last.lyx"

# ---------------------------------------------------------------- C
{
  echo "/* bench/last.c — generiert von tools/gen_bench_last.sh -n $N (#2332). NICHT von Hand aendern. */"
  echo "#include <stdio.h>"
  echo "#include <stdlib.h>"
  echo
  for ((i = 0; i < N; i++)); do
    a=$(konst "$i" 1); b=$(konst "$i" 2); c=$(konst "$i" 3); d=$(konst "$i" 4)
    cat <<EOF
static long long k$i(long long x) {
    long long a = x & 65535;
    a = a * 65537 + $a;
    a = a ^ (a >> 7);
    a = (a + $b) & 65535;
    a = a * 65537 + $c;
    a = a ^ (a >> 11);
    return (a + $d) & 4294967295LL;
}
EOF
  done
  echo "int main(int argc, char **argv) {"
  echo "    long long wdh = 1;"
  echo "    if (argc > 1) { long long v = atoll(argv[1]); if (v > 0) wdh = v; }"
  echo "    long long acc = 1;"
  echo "    for (long long w = 0; w < wdh; w++) {"
  for ((i = 0; i < N; i++)); do echo "        acc = k$i(acc);"; done
  echo "    }"
  echo "    printf(\"checksum=%lld\\n\", acc & 4294967295LL);"
  echo "    return 0;"
  echo "}"
} > "$OUT/last.c"

# ---------------------------------------------------------------- Rust
# `inline(never)` haelt die Last beim Vergleich zwischen Cranelift und LLVM
# vergleichbar: ohne das Attribut zieht LLVM auf -Copt-level=2 die Kette aus
# $N Aufrufen zu einem Ausdruck zusammen und messt etwas anderes als die
# anderen Fassungen.
{
  echo "// bench/last.rs — generiert von tools/gen_bench_last.sh -n $N (#2332). NICHT von Hand aendern."
  echo
  for ((i = 0; i < N; i++)); do
    a=$(konst "$i" 1); b=$(konst "$i" 2); c=$(konst "$i" 3); d=$(konst "$i" 4)
    cat <<EOF
#[inline(never)]
fn k$i(x: i64) -> i64 {
    let mut a: i64 = x & 65535;
    a = a * 65537 + $a;
    a = a ^ (a >> 7);
    a = (a + $b) & 65535;
    a = a * 65537 + $c;
    a = a ^ (a >> 11);
    (a + $d) & 4294967295
}
EOF
  done
  echo "fn main() {"
  echo "    let mut wdh: i64 = 1;"
  echo "    if let Some(s) = std::env::args().nth(1) {"
  echo "        if let Ok(v) = s.parse::<i64>() { if v > 0 { wdh = v; } }"
  echo "    }"
  echo "    let mut acc: i64 = 1;"
  echo "    for _ in 0..wdh {"
  for ((i = 0; i < N; i++)); do echo "        acc = k$i(acc);"; done
  echo "    }"
  echo "    println!(\"checksum={}\", acc & 4294967295);"
  echo "}"
} > "$OUT/last.rs"

echo "geschrieben: $OUT/last.lyx $OUT/last.c $OUT/last.rs ($N Funktionen)"
