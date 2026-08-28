#!/usr/bin/env bash
# tests/import_graph_test.sh — Kosten des Importgraphen auf dem IR-Weg (#1845).
#
# `lowerModule` ist an jedem NK_IMPORT rekursiv und las den Import dabei JEDES
# MAL neu ein und lowerte ihn erneut. Bei einem Diamanten im Graphen geschah
# das einmal pro PFAD, nicht einmal pro Modul — der Aufwand wuchs exponentiell:
#
#   Tiefe  8: 0,08 s /  11 MB      Tiefe 12: 0,51 s /  58 MB
#   Tiefe 14: 1,35 s / 148 MB      Tiefe 16: 3,52 s / 382 MB
#
# Faktor 2,6 je zwei Ebenen — genau phi^2, die Form der Fibonacci-Kette. In
# `vega@0.1.9` kostete `vega.forms` (2023 Zeilen) dadurch 80 s und 3,6 GB,
# waehrend `vega.control` (2182 Zeilen, flacherer Graph) 2 s brauchte.
#
# Gemessen wird NICHT die Zeit — die haengt an der Maschine und macht den Test
# launisch. Gemessen wird das ERZEUGNIS: der alte Lauf emittierte jeden Rumpf
# mehrfach, das Abbild wuchs also mit. Waechst es zwischen zwei Tiefen mehr als
# linear, ist die Mehrfachverarbeitung zurueck.
#
# Dazu die Gegenprobe an der WIRKUNG: der berechnete Wert muss stimmen. Ein
# Dedup, das zu viel wegwirft, laesst Rumpfe fehlen — das faellt sonst erst
# beim Laden auf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ulimit -c 0 2>/dev/null

# Fibonacci-Diamant: n_i importiert n_{i-1} UND n_{i-2}. Jedes Modul ist winzig;
# teuer ist allein die Zahl der PFADE durch den Graphen.
printf 'unit n00;\npub fn f00(a: int64): int64 { return a + 1; }\n' > "$TMP/n00.lyx"
printf 'unit n01;\nimport n00;\npub fn f01(a: int64): int64 { return f00(a); }\n' > "$TMP/n01.lyx"
i=2
while [ $i -le 16 ]; do
  printf 'unit n%02d;\nimport n%02d;\nimport n%02d;\npub fn f%02d(a: int64): int64 { return f%02d(a) + f%02d(a); }\n' \
    $i $((i-1)) $((i-2)) $i $((i-1)) $((i-2)) > "$TMP/n$(printf %02d $i).lyx"
  i=$((i+1))
done

groesse() {  # tiefe -> Bytes des lyxos-Abbilds
  printf 'import n%02d;\nfn main(): int64 { return f%02d(1); }\n' "$1" "$1" > "$TMP/m.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/m.lyx" --target=lyxos -I "$TMP" -o "$TMP/m.lbf" >"$TMP/m.log" 2>&1; then
    echo "0"; return
  fi
  stat -c%s "$TMP/m.lbf" 2>/dev/null || echo 0
}

g8="$(groesse 8)"; g16="$(groesse 16)"
if [ "$g8" = "0" ] || [ "$g16" = "0" ]; then
  echo "FAIL abbild_entsteht: Tiefe 8=$g8 Tiefe 16=$g16 — $(grep -im1 'error\|unbekannt' "$TMP/m.log")"; FAIL=$((FAIL+1))
else
  echo "PASS abbild_entsteht (Tiefe 8: $g8 B, Tiefe 16: $g16 B)"; PASS=$((PASS+1))
  # Acht Ebenen mehr sind acht kleine Module mehr. Gemessen mit dem Stand VOR
  # dem Fix: Tiefe 8 = 16384 B, Tiefe 16 = 352256 B — Faktor 21. Danach bleibt
  # beides bei 8192 B. Die Schranke (Faktor 2) trennt die beiden Faelle
  # deutlich, ohne an einer genauen Zahl zu haengen.
  if [ "$g16" -le $(( g8 * 2 )) ]; then
    echo "PASS wachstum_bleibt_linear ($g16 <= 2 * $g8)"; PASS=$((PASS+1))
  else
    echo "FAIL wachstum_bleibt_linear: $g16 > 2 * $g8 — Module werden je Pfad verarbeitet"; FAIL=$((FAIL+1))
  fi
fi

# Wirkung: der Wert muss stimmen (f16 = 3194, als Prozessstatus 122).
printf 'import n16;\nfn main(): int64 { return f16(1); }\n' > "$TMP/w.lyx"
for ziel in linux arm64 riscv; do
  q=""
  if [ "$ziel" = "arm64" ]; then
    command -v qemu-aarch64-static >/dev/null 2>&1 && q=qemu-aarch64-static
    [ -z "$q" ] && command -v qemu-aarch64 >/dev/null 2>&1 && q=qemu-aarch64
    if [ -z "$q" ]; then echo "SKIP arm64/wert: qemu fehlt"; continue; fi
  elif [ "$ziel" = "riscv" ]; then
    command -v qemu-riscv64-static >/dev/null 2>&1 && q=qemu-riscv64-static
    [ -z "$q" ] && command -v qemu-riscv64 >/dev/null 2>&1 && q=qemu-riscv64
    if [ -z "$q" ]; then echo "SKIP riscv/wert: qemu fehlt"; continue; fi
  fi
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" --target="$ziel" -I "$TMP" -o "$TMP/w.out" >"$TMP/w.log" 2>&1; then
    echo "FAIL $ziel/wert: uebersetzt nicht: $(grep -im1 'error\|unbekannt' "$TMP/w.log")"; FAIL=$((FAIL+1)); continue
  fi
  timeout 60 $q "$TMP/w.out" >/dev/null 2>&1; rc=$?
  # f16 der Kette ist 3194; der Rueckgabewert kommt als Prozessstatus zurueck
  # und damit modulo 256 an: 3194 mod 256 = 122. Der Wert selbst ist
  # nebensaechlich — dass ALLE drei Ziele DENSELBEN liefern und keiner in einer
  # fehlenden Funktion landet, ist der Nachweis.
  if [ "$rc" -eq 122 ]; then echo "PASS $ziel/wert (=$rc)"; PASS=$((PASS+1));
  else echo "FAIL $ziel/wert: exit=$rc erwartet 122"; FAIL=$((FAIL+1)); fi
done

echo "== import_graph_test: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
