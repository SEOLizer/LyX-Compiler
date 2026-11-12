#!/bin/bash
# #2111: SIGHUP ueber signalfd in den epoll-Loop holen — mit io.wait allein.
#
# Bis 1.2.14B starb dieselbe Probe unter [io.wait, system.time] an SIGSYS:
# rt_sigprocmask (eigene Maske) hing an process.signal, das auch kill auf
# FREMDE Prozesse freigibt, und das read auf den signalfd an fs.read. Seitdem
# stehen rt_sigprocmask und read unter io.wait (Begruendung am Code,
# src/security/seccomp_gen.lyx).
#
# Gemessen wird die WIRKUNG: die Probe bekommt das Signal tatsaechlich und
# liest die Signalnummer aus dem signalfd_siginfo (rc 0 nur bei ssi_signo ==
# SIGHUP). Und BEIDE Seiten (#1823): was mit io.wait NICHT dazukommen darf —
# kill/tgkill auf einen fremden Prozess und open — stirbt weiterhin an SIGSYS,
# und mit dem jeweils richtigen Recht laeuft es (sonst waere "stirbt" auch von
# einem Filter erfuellt, der den Aufruf aus anderem Grund verwirft).
#
# Das Signal schickt das SKRIPT von aussen (kill -HUP), nicht das Programm —
# sonst braeuchte die Probe genau das process.signal, um das es geht.
#
# SIGSYS ist Exit 159 (128 + 31).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
LYXC="${LYXC:-$ROOT/lyxc}"
. "$ROOT/tests/lib/lyxc_guard.sh"   # #1294
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

BASIS="system.exit, system.memory.heap"

uebersetze() { # caps, rumpf -> $TMP/p
  cat > "$TMP/p.lyx" <<EOF
@capabilities([$1])
unit main;
import std.io;
import std.signals;
fn main(): int64 {
$2
  return 0;
}
EOF
  rm -f "$TMP/p"
  "$LYXC" "$TMP/p.lyx" -o "$TMP/p" > "$TMP/p.log" 2>&1
}

# lauf <Name> <caps> <rumpf> <erwartet: frei|gesperrt>
lauf() {
  local NAME="$1" CAPS="$2" RUMPF="$3" WILL="$4"
  if ! uebersetze "$CAPS" "$RUMPF"; then
    no "$NAME: uebersetzt nicht — $(sed -n '2p' "$TMP/p.log")"; return
  fi
  ( ulimit -c 0; timeout 10 "$TMP/p" < /dev/null > /dev/null 2>&1 ) 2>/dev/null; local rc=$?
  if [ "$WILL" = "frei" ]; then
    if [ "$rc" -eq 0 ]; then ok "$NAME: laeuft (rc 0)"
    else no "$NAME: rc $rc — erwartet 0 (159 = SIGSYS)"; fi
  else
    if [ "$rc" -eq 159 ]; then ok "$NAME: stirbt an SIGSYS"
    else no "$NAME: rc $rc statt SIGSYS — der Filter laesst zu viel durch"; fi
  fi
}

# ── Die Probe aus dem Issue ────────────────────────────────────────────────
PROBE='  if SignalMaskBlock(SIGHUP) != 0 { return 2; }
  var sfd: int64 := SignalFd(SIGHUP);
  if sfd < 0 { return 3; }
  var ep: int64 := sys_epoll_create1(0);
  if ep < 0 { return 4; }
  var ev: int64 := alloc(16); poke64(ev, 1); poke64(ev + 4, sfd);
  if sys_epoll_ctl(ep, 1, sfd, ev) != 0 { return 5; }
  PrintLn("READY");
  var evs: int64 := alloc(64);
  var nr: int64 := sys_epoll_wait(ep, evs, 4, 5000);
  if nr != 1 { return 6; }
  var buf: int64 := alloc(128);
  if SignalFdRead(sfd, buf) != 128 { return 7; }
  if SignalFdSigno(buf) != SIGHUP { return 8; }
  PrintLn("GOT SIGHUP");'

# sighup <Name> <caps> <erwartet: frei|gesperrt>
sighup() {
  local NAME="$1" CAPS="$2" WILL="$3"
  if ! uebersetze "$CAPS" "$PROBE"; then
    no "$NAME: uebersetzt nicht — $(sed -n '2p' "$TMP/p.log")"; return
  fi
  : > "$TMP/out"
  ( ulimit -c 0; exec "$TMP/p" < /dev/null > "$TMP/out" 2>&1 ) 2>/dev/null & local P=$!
  local i
  for i in $(seq 100); do
    grep -q READY "$TMP/out" 2>/dev/null && break
    kill -0 "$P" 2>/dev/null || break
    sleep 0.1
  done
  kill -HUP "$P" 2>/dev/null
  wait "$P" 2>/dev/null; local rc=$?
  if [ "$WILL" = "frei" ]; then
    if [ "$rc" -eq 0 ] && grep -q "GOT SIGHUP" "$TMP/out"; then
      ok "$NAME: SIGHUP ueber signalfd gelesen (ssi_signo == 1)"
    else
      no "$NAME: rc $rc, Ausgabe '$(tr '\n' ' ' < "$TMP/out")' — erwartet rc 0 + GOT SIGHUP"
    fi
  else
    if [ "$rc" -eq 159 ]; then ok "$NAME: stirbt an SIGSYS"
    else no "$NAME: rc $rc statt SIGSYS"; fi
  fi
}

echo "-- #2111: signalfd-Muster --"
sighup "Probe mit [io.wait, system.time]"  "$BASIS, io.wait, system.time" frei
# Gegenseite: ohne io.wait bleibt schon die eigene Maske gesperrt.
sighup "Probe ohne io.wait"               "$BASIS, system.time"          gesperrt
# Der fruehere Weg bleibt offen (keine Verschaerfung fuer Bestandscode).
sighup "Probe mit process.signal + fs.read" "$BASIS, io.wait, system.time, process.signal, fs.read" frei

echo "-- #2111: was io.wait NICHT freigibt --"
# kill(getppid(), 0): Signal 0 prueft nur — ein fremder Prozess (die Shell),
# ohne Wirkung, falls der Filter es doch durchliesse.
KILL='  var r: int64 := sys_kill(sys_getppid(), 0);
  if r != 0 { return 9; }'
lauf "kill auf fremden Prozess mit io.wait"        "$BASIS, io.wait, system.time" "$KILL" gesperrt
lauf "kill auf fremden Prozess mit process.signal" "$BASIS, io.wait, system.time, process.signal" "$KILL" frei
TGKILL='  var p: int64 := sys_getppid();
  var r: int64 := sys_tgkill(p, p, 0);'
lauf "tgkill mit io.wait"        "$BASIS, io.wait, system.time" "$TGKILL" gesperrt
lauf "tgkill mit process.signal" "$BASIS, io.wait, system.time, process.signal" "$TGKILL" frei
# Oeffnen bleibt bei fs.read — darauf stuetzt sich die Freigabe von read.
OPEN='  var fd: int64 := sys_open("/etc/hostname"c, 0, 0);'
lauf "open mit io.wait"  "$BASIS, io.wait, system.time" "$OPEN" gesperrt
lauf "open mit fs.read"  "$BASIS, io.wait, system.time, fs.read" "$OPEN" frei
# pread64 bleibt ebenfalls bei fs.read: positioniertes Lesen ist Dateiarbeit.
PREAD='  var b: int64 := alloc(16); var r: int64 := sys_pread64(0, b, 1, 0);'
lauf "pread64 mit io.wait" "$BASIS, io.wait, system.time" "$PREAD" gesperrt

echo "-- #2111: die bewusste Folge — read auf bereits offene Deskriptoren --"
# read ist fd-blind: unter io.wait gilt es auch fuer stdin. Festgehalten, damit
# die Weite sichtbar bleibt und nicht still waechst oder schrumpft.
READ='  var b: int64 := alloc(16); var r: int64 := sys_read(0, b, 1);
  if r != 0 { return 10; }'
lauf "read(stdin) mit io.wait"  "$BASIS, io.wait" "$READ" frei
lauf "read(stdin) ohne io.wait" "$BASIS"          "$READ" gesperrt

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: signalfd-Muster unter io.wait, kill/tgkill/open bleiben gesperrt"
exit 0
