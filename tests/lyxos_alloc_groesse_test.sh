#!/bin/bash
# #1861: `alloc(n)` mit negativem n darf den Kernel nicht zerschreiben.
#
# Der Bootloader liest negative Groessen in `.ring3_mmap` als interne Befehle
# (-1 No-Op, -5 Adresse des r3_sc_block, -6 Ausloeser, -7 Bildspeicher). Eine
# negative Groesse fordert also keinen Speicher an, sondern liefert einen
# KERNELZEIGER — und die Nullung aus #1848 schrieb ihn anschliessend mit
# `rep stosb` und rcx = n als vorzeichenloser Zahl voll. Auf dem Geraet endete
# das im zerstoerten IDT-Gate und damit im Triple Fault.
#
# Gemessen wird am ERZEUGNIS, nicht am Lauf: der lokale LBF-Lader kann
# allokierende Programme nicht ausfuehren (er liefert Syscall-Ergebnisse in
# rax, LyxOS in rdx). Geprueft werden die Bytefolgen im .text.
#
# Beide Richtungen gehoeren dazu: die Schranke muss da sein UND die Nullung
# muss erhalten bleiben. Ein Test, der nur die Schranke sucht, waere auch von
# einer Fassung erfuellt, die #1848 wieder ausbaut.

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

cat > "$TMP/a.lyx" <<'EOF'
unit main;

import std.alloc;

fn main(): int64 {
  var n: int64 := 64;
  var p: int64 := alloc(n);
  poke8(p, 7);
  return peek8(p);
}
EOF

if ! $LYXC "$TMP/a.lyx" --target=lyxos -o "$TMP/a.lbf" > "$TMP/a.log" 2>&1; then
    echo "FAIL: uebersetzt nicht"; sed -n '1,5p' "$TMP/a.log"; exit 1
fi

HEX=$(xxd -p "$TMP/a.lbf" | tr -d '\n')

pruefe() {  # Name, Bytefolge, Erwartung(ja|nein), Bedeutung
    local NAME="$1" MUSTER="$2" WILL="$3" WAS="$4"
    if echo "$HEX" | grep -q "$MUSTER"; then DA="ja"; else DA="nein"; fi
    if [ "$DA" = "$WILL" ]; then
        echo "PASS $NAME"; PASS=$((PASS + 1))
    else
        echo "FAIL $NAME: $MUSTER erwartet=$WILL gefunden=$DA — $WAS"
        FAIL=$((FAIL + 1))
    fi
}

# TEST rcx,rcx (48 85 c9) + JG (7f) — die Groessenschranke vor dem Syscall.
pruefe "Groessenschranke vor mmap" "4885c97f" "ja" \
       "ohne sie trifft eine negative Groesse den Sentinel im Bootloader"
# TEST rax,rax (48 85 c0) + JZ (74) — keine Nullung ohne Zeiger.
pruefe "Nullung nur bei Zeiger != 0" "4885c074" "ja" \
       "ohne sie laeuft rep stosb bei abgelehnter Anforderung ab Adresse 0 los"
# Gegenprobe: die Nullung selbst (cld; rep stosb) ist noch da (#1848).
pruefe "Nullung erhalten" "fcf3aa" "ja" \
       "#1848: LyxOS liefert keine genullten Seiten, der Block muss genullt werden"

# Und die Nullung muss NACH der Schranke stehen, nicht davor.
POS_SCHRANKE=$(echo "$HEX" | grep -bo "4885c97f" | head -1 | cut -d: -f1)
POS_STOSB=$(echo "$HEX" | grep -bo "fcf3aa" | head -1 | cut -d: -f1)
if [ -n "$POS_SCHRANKE" ] && [ -n "$POS_STOSB" ] && [ "$POS_SCHRANKE" -lt "$POS_STOSB" ]; then
    echo "PASS Schranke steht vor der Nullung"; PASS=$((PASS + 1))
else
    echo "FAIL Schranke steht nicht vor der Nullung (Schranke=$POS_SCHRANKE stosb=$POS_STOSB)"
    FAIL=$((FAIL + 1))
fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: lyxos alloc-Groessenschranke"
exit 0
