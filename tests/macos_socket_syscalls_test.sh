#!/usr/bin/env bash
# tests/macos_socket_syscalls_test.sh — macOS-Backend emittiert die BSD-Socket-
# Syscallnummern (Issue #1017, vormals wp06_macos_socket).
#
# tests/wp06_macos_socket.lyx dokumentiert im Kopf genau diese Zuordnung, hat
# sie aber durch AUSFÜHREN geprüft — und lief in der Linux-Suite mit. Dort
# scheiterte er zwangsläufig: die macOS-Konstanten (MACOS_SOL_SOCKET usw.)
# bedeuten unter Linux etwas anderes, `sys_setsockopt` gab einen Fehler zurück.
#
# Prüfbar ist die Zuordnung auf Linux trotzdem — nur eben am erzeugten Binary
# statt an seinem Verhalten: mit `--target=macosx64` entsteht ein Mach-O, und
# die Nummern stehen als Konstanten im Code.
#
# Die Quelle steht hier im Test und ruft ALLE ZEHN Syscalls auf. Der alte
# Test rief nur sechs davon auf, dokumentierte im Kopf aber zehn — die vier
# übrigen (connect, accept, sendto, recvfrom) waren nie geprüft.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

cat > "$TMP/socks.lyx" <<'EOF'
import std.io;
import std.net.types;

// Beruehrt jeden der zehn Socket-Builtins genau einmal, damit das Backend
// fuer jeden die BSD-Nummer emittieren muss. Ausgefuehrt wird nichts — der
// Test prueft das erzeugte Mach-O.
fn main(): int64 {
  var fd: int64 := sys_socket(MACOS_AF_INET, MACOS_SOCK_STREAM, MACOS_IPPROTO_TCP);
  var buf: int64 := mmap(0, 64, 3, 34, -1, 0);
  sys_setsockopt(fd, MACOS_SOL_SOCKET, MACOS_SO_REUSEADDR, buf, 4);
  sys_getsockopt(fd, MACOS_SOL_SOCKET, MACOS_SO_TYPE, buf, buf);
  sys_bind(fd, buf, 16);
  sys_listen(fd, 1);
  sys_accept(fd, buf, buf);
  sys_connect(fd, buf, 16);
  sys_sendto(fd, buf, 4, 0, 0, 0);
  sys_recvfrom(fd, buf, 4, 0, 0, 0);
  sys_shutdown(fd, 2);
  sys_close(fd);
  munmap(buf, 64);
  return 0;
}
EOF

if ! "$LYXC" --target=macosx64 --std-path="$ROOT" "$TMP/socks.lyx" -o "$TMP/mac.bin" >/dev/null 2>&1; then
  echo "FAIL uebersetzt nicht fuer --target=macosx64"
  echo "Ergebnis: 0 PASS, 1 FAIL"
  exit 1
fi
echo "PASS uebersetzt fuer macosx64"; PASS=$((PASS+1))

# Mach-O 64-bit little endian: cf fa ed fe
magic=$(head -c 4 "$TMP/mac.bin" | od -An -tx1 | tr -d ' \n')
if [ "$magic" = "cffaedfe" ]; then
  echo "PASS Mach-O-Magic"; PASS=$((PASS+1))
else
  echo "FAIL Mach-O-Magic: $magic erwartet cffaedfe"; FAIL=$((FAIL+1))
fi

# Die im Testkopf dokumentierte Zuordnung Linux-Nummer -> BSD-Nummer.
check_num() { # name, hexnummer
  if python3 - "$TMP/mac.bin" "$2" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
num  = int(sys.argv[2], 16)
sys.exit(0 if struct.pack("<I", num) in data else 1)
PY
  then echo "PASS $1 ($2)"; PASS=$((PASS+1))
  else echo "FAIL $1 ($2) nicht im Code"; FAIL=$((FAIL+1)); fi
}

check_num sys_socket     0x2000061
check_num sys_connect    0x2000062
check_num sys_accept     0x200001E
check_num sys_sendto     0x2000085
check_num sys_recvfrom   0x200001D
check_num sys_shutdown   0x2000086
check_num sys_bind       0x2000068
check_num sys_listen     0x200006A
check_num sys_setsockopt 0x2000069
check_num sys_getsockopt 0x2000076

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
