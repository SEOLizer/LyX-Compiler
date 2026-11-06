#!/usr/bin/env bash
# #2403 — fma(a, b, c) mit garantiert EINER Rundung.
#
# Drei Nachweise, jeder an der Wirkung und nicht an einer Invariante:
#
#   1. Sonderfaelle gegen von glibc erhobene Erwartungswerte, BEIDE Wege
#      (Hardware-FMA und exakter ganzzahliger Rueckfall).
#   2. Differenztest: eine Million Zufallsmuster ueber fuenf Exponenten-
#      verteilungen; Hardware und Software muessen bitgleich sein UND die
#      XOR-Pruefsumme muss der von libm fma() gerechneten entsprechen.
#      Ohne die C-Gegenprobe wuerde ein gemeinsamer Fehler beider Wege
#      unentdeckt bleiben.
#   3. Erzeugnis: das Programm enthaelt die VEX-Kodierung von vfmadd213sd.
#      Sonst koennte der "Hardware"-Weg still der Software-Weg sein.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# ── 1. Sonderfaelle ─────────────────────────────────────────────────────────
if "$LYXC" --std-path=. tests/fma_2403/faelle.lyx -o "$TMP/faelle" >"$TMP/b1.log" 2>&1; then
  ok "faelle_uebersetzt"
  if out=$("$TMP/faelle" 2>&1); then
    n=$(echo "$out" | grep -c '^PASS ')
    if [ "$n" -eq 32 ] && echo "$out" | grep -q '^ALL PASS$'; then
      ok "faelle_32_von_32"
    else
      bad "faelle (PASS=$n, erwartet 32)"; echo "$out" | grep '^FAIL' | head -5
    fi
  else
    bad "faelle_laeuft"; echo "$out" | head -10
  fi
else
  bad "faelle_uebersetzt"; tail -5 "$TMP/b1.log"
fi

# ── 2. Differenztest mit C-Gegenprobe ───────────────────────────────────────
cat > "$TMP/ref.c" <<'EOF'
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
static uint64_t s;
static int64_t rnd(void){ uint64_t x=s; x^=x<<13; x^=x>>7; x^=x<<17; s=x; return (int64_t)x; }
static int64_t musterBits(int art){
  int64_t m = rnd() & 4503599627370495LL; int64_t e;
  if(art==0) e = rnd() & 2047;
  else if(art==1) e = 1023 + ((rnd() & 63) - 32);
  else if(art==2) e = rnd() & 31;
  else if(art==3) e = 2047 - (rnd() & 31);
  else e = 1023 + ((rnd() & 1023) - 512);
  int64_t sg = rnd() & 1;
  int64_t b = m | ((e & 2047) << 52);
  if(sg) b |= (int64_t)1<<63;
  return b;
}
static double bits2d(int64_t b){ double d; memcpy(&d,&b,8); return d; }
static int64_t d2bits(double d){ int64_t b; memcpy(&b,&d,8); return b; }
int main(int argc,char**argv){
  long n = argc>1?atol(argv[1]):200000; int art = argc>2?atoi(argv[2]):4;
  s = 88172645463325252ULL;
  int64_t pruef=0;
  for(long i=0;i<n;i++){
    int64_t ab=musterBits(art), bb=musterBits(art), cb=musterBits(art);
    int64_t r = d2bits(fma(bits2d(ab),bits2d(bb),bits2d(cb)));
    if(((r>>52)&2047)==2047 && (r&4503599627370495LL)!=0) r = 9221120237041090560LL;
    pruef ^= r;
  }
  printf("%lld\n", (long long)pruef);
  return 0;
}
EOF
HABE_CC=0
if command -v gcc >/dev/null 2>&1 && gcc -O2 -o "$TMP/ref" "$TMP/ref.c" -lm >"$TMP/cc.log" 2>&1; then
  HABE_CC=1; ok "c_referenz_gebaut"
else
  echo "SKIP c_referenz (kein gcc oder libm) — Differenztest prueft dann nur hw==sw"
fi

if "$LYXC" --std-path=. tests/fma_2403/differenz.lyx -o "$TMP/diff" >"$TMP/b2.log" 2>&1; then
  ok "differenz_uebersetzt"
  for art in 0 1 2 3 4; do
    out=$("$TMP/diff" 200000 "$art" 2>&1) || { bad "differenz_art$art-laeuft"; continue; }
    abw=$(echo "$out" | sed -n 's/^abweichungen=//p')
    phw=$(echo "$out" | sed -n 's/^pruef_hw=//p')
    psw=$(echo "$out" | sed -n 's/^pruef_sw=//p')
    if [ "${abw:-x}" = "0" ] && [ -n "$phw" ] && [ "$phw" = "$psw" ]; then
      ok "differenz_art${art}_hw_gleich_sw"
    else
      bad "differenz_art${art} (abweichungen=${abw:-?})"; echo "$out" | head -8
    fi
    if [ "$HABE_CC" = "1" ]; then
      pc=$("$TMP/ref" 200000 "$art")
      if [ "$phw" = "$pc" ]; then
        ok "differenz_art${art}_gleich_libm"
      else
        bad "differenz_art${art}_gegen_libm (lyx=$phw libm=$pc)"
      fi
    fi
  done
else
  bad "differenz_uebersetzt"; tail -5 "$TMP/b2.log"
fi

# ── 3. Erzeugnis traegt vfmadd213sd ─────────────────────────────────────────
# C4 E2 F1 A9 C2 = vfmadd213sd xmm0, xmm1, xmm2 (VEX 3-Byte, map 0F38, W=1,
# vvvv=xmm1, L=0, pp=66). Lyx-Erzeugnisse haben keine Sektionen, also wird am
# BYTEMUSTER geprueft, nicht ueber objdump -d.
if [ -f "$TMP/faelle" ]; then
  if python3 - "$TMP/faelle" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
n = d.count(bytes.fromhex('c4e2f1a9c2'))
print("vfmadd213sd-Vorkommen:", n)
sys.exit(0 if n >= 1 else 1)
PY
  then ok "erzeugnis_traegt_vfmadd213sd"
  else bad "erzeugnis_traegt_vfmadd213sd"
  fi
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
