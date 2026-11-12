#!/usr/bin/env bash
# tests/sprung_ausrichtung_2244_test.sh — kein Sprung ueber eine 32-Byte-Grenze (#2244).
#
# JCC-Erratum (Skylake..Coffee Lake): ein Sprung — als makrofusioniertes Paar
# mit seinem cmp/test, oder allein —, der eine 32-Byte-Grenze kreuzt oder an
# ihr endet, wird nicht aus dem uop-Cache geliefert. #2234 richtete nur die
# Paare aus cg_genSprungWennFalsch aus (if/while-Bedingungen). Offen waren:
# &&/|| (test+jz/jnz und der jmp dazwischen), die Rueckspruenge der Schleifen,
# der jmp ueber den else-Zweig, die Spruenge des Bump-Blocks und die
# Canary-Pruefung im Epilog (`xor r11, r10; jne` — xor verschmilzt nicht, jetzt
# `cmp r11, r10`).
#
# Gemessen am Selbstbau bis 1.2.20D: 10,1 % der bedingten Spruenge und 15,7 %
# der jmp lagen ungeschickt; jetzt 0,1 % bzw. 0,4 % (Rest: kalte Pfade).
#
# Geprueft wird der WEG an einer Funktion, deren 32 Varianten durch eine
# wachsende Zahl vorangestellter Zuweisungen auf alle Lagen mod 32 fallen:
# keiner ihrer Spruenge kreuzt eine Grenze oder endet an ihr. Und die WIRKUNG:
# das Ergebnis stimmt (gegengerechnet in Python).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ulimit -c 0
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

{
  echo 'import std.io;'
  echo '@export'
  echo 'fn f(n: int64): int64 {'
  echo '  var s: int64 := 0;'
  for k in $(seq 0 31); do
    j=0; while [ $j -lt $k ]; do echo "  s := s + $j;"; j=$((j+1)); done
    echo "  var lauf$k: int64 := 0;"
    echo "  while (lauf$k < n) {"
    echo "    if ((lauf$k > 0 && s > 0) || lauf$k == 2) { s := s + $k; } else { s := s + 1; }"
    echo "    var t$k: pchar := IntToStr(lauf$k);"
    echo "    s := s + StrLen(t$k);"
    echo "    lauf$k += 1;"
    echo "  }"
    echo "  var r$k: int64 := 0;"
    echo "  repeat { r$k := r$k + 1; } until (r$k >= 2);"
    echo "  s := s + r$k;"
  done
  echo '  return s;'
  echo '}'
  echo 'fn main(): int64 { PrintLn(f(3)); return 0; }'
} > "$TMP/j.lyx"

# Erwartung: je Variante k: Anfangszuweisungen sum(range(k)); Schleife n=3:
# lauf=0 -> else (+1), lauf=1 -> s>0? (s ist dann >0, da +1) -> +k, lauf=2 -> +k;
# je Durchlauf StrLen("0".."2") = 1; repeat liefert 2.
ERW=$(python3 -c "
s=0
for k in range(32):
    s+=sum(range(k))
    for lauf in range(3):
        if (lauf>0 and s>0) or lauf==2: s+=k
        else: s+=1
        s+=1
    s+=2
print(s)")

if ! (cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/j.lyx" -o "$TMP/j" --map-file >"$TMP/b.log" 2>&1); then
  no "uebersetzt" "$(grep -m1 -i error "$TMP/b.log")"
else
  got=$( timeout 20 "$TMP/j" ); if [ "$got" = "$ERW" ]; then ok "Wirkung: f(3) = $got"; else no "Wirkung" "'$got' erwartet '$ERW'"; fi
  a=$(awk '$4=="f"{print $1}' "$TMP/j.map"); b=$(awk -v a="$a" 'f{print $1; exit} $4=="f"{f=1}' "$TMP/j.map")
  if [ -z "$a" ] || [ -z "$b" ]; then no "Weg" "f nicht in der Abbildkarte"
  else
    # Je Sprung: Anfang = vorangehendes cmp/test (makrofusioniert), sonst der
    # Sprung selbst; Ende = hinter dem Sprung. objdump mit -z (#1370).
    erg=$(objdump -D -z -b binary -m i386:x86-64 --start-address=$((a - 0x400000)) --stop-address=$((b - 0x400000)) "$TMP/j" \
      | awk -F'\t' '/^ +[0-9a-f]+:/ { split($1,x,":"); gsub(/ /,"",x[1]); adr=strtonum("0x" x[1]); n=split($2,by," "); ins=$3;
          if (ins == "") next;
          if (ins ~ /^j/) {
            s=adr; if (ins !~ /^jmp/ && pc != "") s=padr;
            s+=0x400000; e=adr+n+0x400000;
            if (ins ~ /^jmp/) gj++; else gc++;
            if (int(s/32) != int((e-1)/32) || e%32==0) { if (ins ~ /^jmp/) kj++; else kc++ }
          }
          if (ins ~ /^(cmp|test)/) { pc=ins; padr=adr } else { pc="" } }
        END { print gc+0, kc+0, gj+0, kj+0 }')
    read -r gc kc gj kj <<<"$erg"
    if [ "$gc" -lt 128 ] || [ "$gj" -lt 64 ]; then no "Weg" "zu wenige Spruenge gefunden ($gc bedingt, $gj jmp)"
    else
      if [ "$kc" -eq 0 ]; then ok "Weg: $gc bedingte Spruenge/Paare, keiner ueber oder an einer 32-Byte-Grenze"
      else no "Weg bedingt" "$kc von $gc ueber oder an einer 32-Byte-Grenze"; fi
      if [ "$kj" -eq 0 ]; then ok "Weg: $gj jmp, keiner ueber oder an einer 32-Byte-Grenze"
      else no "Weg jmp" "$kj von $gj ueber oder an einer 32-Byte-Grenze"; fi
    fi
  fi
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
