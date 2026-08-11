#!/usr/bin/env bash
# tests/lyxos_caps_tlv_test.sh — @capabilities → LBF CAPS-TLV-Mapping (--target=lyxos).
# Bug: writer.lyx schrieb CAPS-TLV hart als 0 → @capabilities([fs.read,fs.write]) blieb 0
# → Kernel-Pledge-Gate erlaubte nur STDIO, File-Zugriff denied. Fix: lyxc scannt
# NK_CAPABILITY_DECL-Nodes, mappt Pfad→LBF_CAP_*-Bit (fs.read=1/fs.write=2/network=4/…),
# OR-Union → writer.setCapabilities → CAPS-TLV. Verifikation: TLV-Bits aus dem LBF lesen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

capbits() { # source → druckt CAPS-TLV-Bits (oder "none")
  printf "%s" "$1" > "$TMP/c.lyx"
  LYX_STD_PATH="$ROOT/std" "$LYXC" --target=lyxos "$TMP/c.lyx" -o "$TMP/c.lyxnative" >/dev/null 2>&1
  python3 - "$TMP/c.lyxnative" <<'PY'
import sys
try: d=open(sys.argv[1],'rb').read()
except: print("ERR"); sys.exit()
i=64+128; end=64+4032
while i<end-3:
    tag=d[i]; ln=d[i+1]|(d[i+2]<<8)
    if tag==0: break
    if tag==5: print(int.from_bytes(d[i+3:i+11],'little')); break
    i+=3+ln
else: print("none")
PY
}

check() { # name, source, expected-bits
  local got; got=$(capbits "$2")
  if [ "$got" = "$3" ]; then echo "PASS $1 (=$got)"; PASS=$((PASS+1));
  else echo "FAIL $1: bits=$got erwartet $3"; FAIL=$((FAIL+1)); fi
}

check "no_caps"        'fn main(): int64 { return 0; }' 0
check "fs_read"        '@capabilities([fs.read])
fn main(): int64 { return 0; }' 1
check "fs_write"       '@capabilities([fs.write])
fn main(): int64 { return 0; }' 2
check "fs_read_write"  '@capabilities([fs.read, fs.write])
fn main(): int64 { return 0; }' 3
check "network"        '@capabilities([network.tcp.connect])
fn main(): int64 { return 0; }' 4
check "fs_read_net"    '@capabilities([fs.read, network.tcp.connect])
fn main(): int64 { return 0; }' 5

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
