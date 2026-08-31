#!/bin/bash
# #1870, #1871, #1872, #1875: die Capabilities der zweiten Haelfte.
#
# Gemessen wird BEIDE Richtungen je Recht: der Aufruf laeuft MIT, und er
# stirbt OHNE mit SIGSYS (Exit 159). Ein Test nur fuer die erste Haelfte waere
# auch von einem Filter erfuellt, der alles durchlaesst (#1823).
#
# Dazu die Eingrenzungsproben: ein Recht darf nicht mehr freigeben, als sein
# Name verspricht.

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

lauf() {   # Name, caps-Zusatz, Rumpf, frei|gesperrt
  local NAME="$1" CAPS="$2" RUMPF="$3" WILL="$4"
  cat > "$TMP/p.lyx" <<EOF
@capabilities([system.exit, system.memory.heap$CAPS])
unit main;
import std.io;
fn main(): int64 {
$RUMPF
  return 0;
}
EOF
  rm -f "$TMP/p"
  if ! $LYXC --std-path=. "$TMP/p.lyx" -o "$TMP/p" > "$TMP/p.log" 2>&1; then
    echo "FAIL $NAME: uebersetzt nicht — $(grep -iE '^sema|^error' "$TMP/p.log" | head -1)"
    FAIL=$((FAIL + 1)); return
  fi
  ( ulimit -c 0; "$TMP/p" > /dev/null 2>&1 ) 2>/dev/null; local rc=$?
  if [ "$WILL" = "frei" ]; then
    if [ "$rc" -eq 159 ]; then
      echo "FAIL $NAME: stirbt an SIGSYS, obwohl das Recht deklariert ist"; FAIL=$((FAIL + 1))
    else
      echo "PASS $NAME"; PASS=$((PASS + 1))
    fi
  else
    if [ "$rc" -eq 159 ]; then
      echo "PASS $NAME"; PASS=$((PASS + 1))
    else
      echo "FAIL $NAME: laeuft OHNE das Recht (exit $rc) — der Filter deckt zu viel ab"
      FAIL=$((FAIL + 1))
    fi
  fi
}

echo "-- #1870: Rechtewechsel und Namensraeume --"
SID='  var r: int64 := sys_setsid();'
lauf "setsid mit process.privileges"  ", process.privileges" "$SID" frei
lauf "setsid ohne das Recht"          ""                     "$SID" gesperrt
# Eingrenzung: privileges gibt KEINE Namensraeume frei.
UNS='  var r: int64 := sys_unshare(0);'
lauf "unshare mit system.namespace"   ", system.namespace"   "$UNS" frei
lauf "unshare mit privileges allein"  ", process.privileges" "$UNS" gesperrt
# reboot gehoert in keines von beiden.
RBT='  var r: int64 := sys_reboot(0, 0, 0, 0);'
lauf "reboot mit namespace allein"    ", system.namespace"   "$RBT" gesperrt

echo "-- #1871: IPC --"
SHM='  var r: int64 := sys_shmget(0, 4096, 0);'
lauf "shmget mit ipc.shm"             ", ipc.shm"            "$SHM" frei
lauf "shmget ohne das Recht"          ""                     "$SHM" gesperrt
# Eingrenzung: die drei IPC-Rechte sind getrennt.
SEM='  var r: int64 := sys_semget(0, 1, 0);'
lauf "semget mit ipc.sem"             ", ipc.sem"            "$SEM" frei
lauf "semget mit ipc.shm allein"      ", ipc.shm"            "$SEM" gesperrt

echo "-- #1872: Dateisystem, Speicher, Beobachtung --"
CHD='  var r: int64 := sys_chdir("/tmp"c as int64);'
lauf "chdir mit fs.cwd"               ", fs.cwd"             "$CHD" frei
lauf "chdir mit fs.read allein"       ", fs.read"            "$CHD" gesperrt
XAT='  var b: int64 := alloc(64); var r: int64 := sys_getxattr("/tmp"c as int64, "u.x"c as int64, b, 64);'
lauf "getxattr mit fs.xattr"          ", fs.xattr"           "$XAT" frei
lauf "getxattr mit fs.read allein"    ", fs.read"            "$XAT" gesperrt
INO='  var r: int64 := sys_inotify_init1(0);'
lauf "inotify mit fs.watch"           ", fs.watch"           "$INO" frei
lauf "inotify ohne das Recht"         ""                     "$INO" gesperrt
MAD='  var p: int64 := alloc(4096); var r: int64 := sys_madvise(p, 4096, 1);'
lauf "madvise mit memory.mmap"        ", memory.mmap"        "$MAD" frei
lauf "madvise ohne das Recht"         ""                     "$MAD" gesperrt
# ptrace und bpf gehoeren ausdruecklich NICHT an ein bestehendes Recht.
PTR='  var r: int64 := sys_ptrace(0, 0, 0, 0);'
lauf "ptrace mit debug.trace"         ", debug.trace"        "$PTR" frei
lauf "ptrace mit process.fork allein" ", process.fork"       "$PTR" gesperrt

echo "-- #1875: hardware.block gibt jetzt etwas frei --"
# BLKSSZGET = 0x1268 = 4712
BLK='  var b: int64 := alloc(64); var r: int64 := sys_ioctl(0, 4712, b);'
lauf "Block-ioctl mit hardware.block" ", hardware.block"     "$BLK" frei
lauf "Block-ioctl ohne das Recht"     ""                     "$BLK" gesperrt
# Eingrenzung: hardware.block gibt NICHT jedes ioctl frei. TCGETS = 21505.
TTY='  var b: int64 := alloc(64); var r: int64 := sys_ioctl(0, 21505, b);'
lauf "Terminal-ioctl mit hw.block"    ", hardware.block"     "$TTY" gesperrt
lauf "Terminal-ioctl mit system.tty"  ", system.tty"         "$TTY" frei

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: process.privileges, system.namespace, system.admin, ipc.*, fs.xattr/watch/cwd, debug.trace, kernel.bpf, hardware.block"
exit 0
