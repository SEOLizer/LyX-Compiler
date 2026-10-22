#!/usr/bin/env bash
# tests/cpu_features_test.sh — std.cpu.features gegen die ECHTE CPU (#2187).
#
# Bis 1.2.18D parste die Unit /proc/cpuinfo nach Zeichenketten, trug dafuer
# @capabilities([fs.read]) und lieferte ohne /proc still 0 — ununterscheidbar
# von "diese CPU kann nichts davon". Jetzt fragt sie die CPU ueber CPUID.
#
# Gemessen wird gegen eine UNABHAENGIGE Quelle (lscpu, sonst /proc/cpuinfo),
# und zwar in BEIDEN Richtungen: jede Faehigkeit, die die Referenz nennt, muss
# die Unit melden — und jede, die sie NICHT nennt, darf die Unit nicht melden.
# Nur die erste Haelfte zu pruefen waere auch von einer Unit erfuellt, die
# stumpf alles bejaht (#1823).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

. "$(dirname "$0")/lib/qemu.sh"   # #2048
QEMU="$QEMU_ARM64"

# Referenzliste der Flags dieser Maschine. lscpu zuerst, weil es die Flags
# aufbereitet; /proc/cpuinfo als Rueckfall.
REF="$(lscpu 2>/dev/null | sed -n 's/^Flags:\s*//p')"
if [ -z "$REF" ]; then
  REF="$(sed -n 's/^flags\s*:\s*//p' /proc/cpuinfo 2>/dev/null | head -1)"
fi
if [ -z "$REF" ]; then
  echo "HINWEIS: weder lscpu noch /proc/cpuinfo lesbar — der Abgleich mit der echten CPU entfaellt."
fi

hat_ref() { # flagname → 0 = ja
  printf ' %s ' "$REF" | grep -q " $1 "
}

cat > "$TMP/f.lyx" <<'EOF'
import src.std.io;
import std.cpu.features;
fn main(): int64 {
  PrintStr("cpuid "c);   PrintLn(CpuHasCpuid());
  PrintStr("sse2 "c);    PrintLn(CpuHasSSE2());
  PrintStr("sse4_1 "c);  PrintLn(CpuHasSSE41());
  PrintStr("sse4_2 "c);  PrintLn(CpuHasSSE42());
  PrintStr("popcnt "c);  PrintLn(CpuHasPOPCNT());
  PrintStr("abm "c);     PrintLn(CpuHasLZCNT());
  PrintStr("aes "c);     PrintLn(CpuHasAESNI());
  PrintStr("avx "c);     PrintLn(CpuHasAVX());
  PrintStr("avx2 "c);    PrintLn(CpuHasAVX2());
  PrintStr("fma "c);     PrintLn(CpuHasFMA());
  PrintStr("bmi1 "c);    PrintLn(CpuHasBMI1());
  PrintStr("bmi2 "c);    PrintLn(CpuHasBMI2());
  PrintStr("sha_ni "c);  PrintLn(CpuHasSHANI());
  PrintStr("avx512f "c); PrintLn(CpuHasAVX512F());
  return 0;
}
EOF

if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" -o "$TMP/f" >"$TMP/f.log" 2>&1); then
  echo "FAIL x86-64 uebersetzte nicht"; sed -n '1,5p' "$TMP/f.log"; echo "Ergebnis: $PASS PASS, $((FAIL+1)) FAIL"; exit 1
fi
( ulimit -c 0; cd "$TMP" && timeout 20 "$TMP/f" > "$TMP/f.out" 2>/dev/null )

# cpuid muss auf x86-64 da sein — sonst sagt der ganze Rest nichts aus.
if grep -q '^cpuid 1$' "$TMP/f.out"; then
  echo "PASS cpuid vorhanden"; PASS=$((PASS+1))
else
  echo "FAIL cpuid: die Unit meldet auf x86-64 kein CPUID"; FAIL=$((FAIL+1))
fi

# Abgleich beider Richtungen.
if [ -n "$REF" ]; then
  gemeldet=0; verschwiegen=0
  while read -r flag wert; do
    [ "$flag" = "cpuid" ] && continue
    [ -z "$flag" ] && continue
    if hat_ref "$flag"; then
      if [ "$wert" = "1" ]; then
        gemeldet=$((gemeldet+1))
      else
        echo "FAIL $flag: Referenz nennt es, die Unit meldet $wert"; FAIL=$((FAIL+1))
      fi
    else
      if [ "$wert" = "0" ]; then
        verschwiegen=$((verschwiegen+1))
      else
        echo "FAIL $flag: Referenz nennt es NICHT, die Unit meldet $wert"; FAIL=$((FAIL+1))
      fi
    fi
  done < "$TMP/f.out"
  echo "PASS Abgleich mit der echten CPU: $gemeldet vorhanden und gemeldet, $verschwiegen fehlend und verschwiegen"
  PASS=$((PASS+1))
  # Beide Seiten muessen ueberhaupt belegt sein, sonst ist der Abgleich
  # einseitig und damit kein Nachweis.
  if [ "$gemeldet" -gt 0 ] && [ "$verschwiegen" -gt 0 ]; then
    echo "PASS beide Richtungen belegt"; PASS=$((PASS+1))
  else
    echo "HINWEIS: diese Maschine belegt nur eine Richtung ($gemeldet vorhanden, $verschwiegen fehlend) — auf einer anderen CPU gegenmessen."
  fi
fi

# Die Unit darf keine Dateirechte mehr verlangen: eine CPU-Abfrage braucht
# kein @capabilities([fs.read]), und genau das war der Grund fuer #2187.
if grep -E '^@capabilities' "$ROOT/std/cpu/features.lyx" | grep -q 'fs\.read'; then
  echo "FAIL std/cpu/features.lyx verlangt weiter fs.read"; FAIL=$((FAIL+1))
else
  echo "PASS kein fs.read mehr"; PASS=$((PASS+1))
fi
# Nur ein echtes Zeichenketten-Literal zaehlt; die Begruendung im Kopf der
# Unit NENNT /proc/cpuinfo und soll das auch duerfen.
if grep -q '"/proc/cpuinfo"' "$ROOT/std/cpu/features.lyx"; then
  echo "FAIL std/cpu/features.lyx liest weiter /proc/cpuinfo"; FAIL=$((FAIL+1))
else
  echo "PASS kein /proc/cpuinfo mehr"; PASS=$((PASS+1))
fi

# Auf einer Architektur ohne CPUID muss die Unit uebersetzen UND durchweg 0
# melden. Vorher war das der stille Fehlerfall; jetzt ist es die richtige
# Antwort, und CpuHasCpuid() macht sie von "nicht ermittelbar" unterscheidbar.
if (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/f.lyx" --target=arm64 -o "$TMP/f.a64" >"$TMP/a.log" 2>&1); then
  echo "PASS arm64 uebersetzt (CPUID-Abfrage blockiert die Portierung nicht)"; PASS=$((PASS+1))
  if [ -n "$QEMU" ]; then
    ( ulimit -c 0; cd "$TMP" && timeout 60 "$QEMU" "$TMP/f.a64" > "$TMP/a.out" 2>/dev/null )
    if [ -s "$TMP/a.out" ] && ! grep -qv ' 0$' "$TMP/a.out"; then
      echo "PASS arm64 meldet durchweg 0"; PASS=$((PASS+1))
    else
      echo "FAIL arm64 meldet nicht durchweg 0:"; sed -n '1,14p' "$TMP/a.out"; FAIL=$((FAIL+1))
    fi
  else
    echo "HINWEIS: qemu-aarch64 fehlt — arm64 nur uebersetzt."
  fi
else
  echo "FAIL arm64 uebersetzte nicht"; sed -n '1,5p' "$TMP/a.log"; FAIL=$((FAIL+1))
fi

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
