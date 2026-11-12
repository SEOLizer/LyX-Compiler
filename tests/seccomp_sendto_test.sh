#!/usr/bin/env bash
# tests/seccomp_sendto_test.sh — #2120: sendto/recvfrom mit jeder Netz-Capability.
#
# Bis 1.2.14C gab es sendto nur mit network.tcp.connect/udp.connect, recvfrom
# nicht mit network.unix. Ein Server (Unix-Socket, TCP-Listener) starb beim
# Antworten mit MSG_NOSIGNAL an SIGSYS (rc 159) — obwohl sendmsg, das
# dasselbe kann, mit jeder Netz-Capability frei war.
#
# Gemessen wird die WIRKUNG: der Syscall kommt durch (Programm laeuft zu Ende)
# bzw. das Programm stirbt an SIGSYS. Beide Seiten: ohne Netz-Capability
# bleibt sendto gesperrt.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

lauf() {  # name, quelle, soll-ausgabe, soll-rc
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! ( cd "$ROOT" && timeout 240 "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" ) >"$TMP/bl.log" 2>&1; then
    nok "$1: uebersetzt nicht ($(grep -m1 -iE 'error' "$TMP/bl.log"))"; return
  fi
  local aus rc
  aus="$( (cd "$TMP" && timeout 30 ./p 2>/dev/null) | tr '\n' '|')"; rc=${PIPESTATUS[0]}
  if [ "$aus" = "$3" ] && [ "$rc" = "$4" ]; then ok "$1: [$aus] rc=$rc"
  else nok "$1: [$aus] rc=$rc statt [$3] rc=$4"; fi
}

# Der Fall aus dem Issue, woertlich bis auf den Socketpfad.
lauf "Issue: sendto auf Unix-Socket mit network.unix" '// Repro: sendto auf einem Unix-Socket (und auf angenommenen TCP-Verbindungen eines Servers)
@capabilities([network.unix, io.wait, memory.mmap, fs.delete])
import std.io;
import std.net.socket;

fn main(): int64 {
  unlink("sendto.sock"c);
  var s: UnixConn := UnixSocketNew();
  if (UnixSocketBind(s, "sendto.sock"c as int64) != 0) { Print("bind fehlgeschlagen\n"); return 1; }
  if (UnixSocketListen(s, 1) != 0) { Print("listen fehlgeschlagen\n"); return 1; }
  var cli: UnixConn := UnixSocketConnect("sendto.sock"c as int64);
  if (cli.fd < 0) { Print("connect fehlgeschlagen\n"); return 1; }
  var r: int64 := sys_sendto(cli.fd, "x"c as int64, 1, 16384, 0, 0);   // MSG_NOSIGNAL
  if (r != 1) { Print("sendto fehlgeschlagen\n"); return 1; }
  Print("sendto ok\n");
  unlink("sendto.sock"c);
  return 0;
}' "sendto ok|" 0

# recvfrom mit network.unix: der Server liest, was der Client schickt.
lauf "recvfrom auf Unix-Socket mit network.unix" '@capabilities([network.unix, io.wait, memory.mmap, fs.delete])
import std.io;
import std.net.socket;
fn main(): int64 {
  unlink("rf.sock"c);
  var s: UnixConn := UnixSocketNew();
  if (UnixSocketBind(s, "rf.sock"c as int64) != 0) { return 1; }
  if (UnixSocketListen(s, 1) != 0) { return 1; }
  var cli: UnixConn := UnixSocketConnect("rf.sock"c as int64);
  var srv: int64 := sys_accept(s.fd, 0, 0);
  if (srv < 0) { Print("accept\n"); return 1; }
  sys_sendto(cli.fd, "AB"c as int64, 2, 16384, 0, 0);
  var b: int64 := alloc(8);
  var r: int64 := sys_recvfrom(srv, b, 8, 0, 0, 0);
  Print(IntToStr(r)); Print(" "); Print(IntToStr(peek8(b))); Print("\n");
  unlink("rf.sock"c);
  return 0;
}' "2 65|" 0

# network.tcp.bind: sendto auf einem (unverbundenen) TCP-Socket darf den
# Kernel erreichen — Antwort ein Fehlercode, kein SIGSYS.
lauf "sendto mit network.tcp.bind erreicht den Kernel" '@capabilities([network.tcp.bind, memory.mmap])
import std.io;
fn main(): int64 {
  var fd: int64 := sys_socket(2, 1, 0);
  if (fd < 0) { Print("socket\n"); return 1; }
  var r: int64 := sys_sendto(fd, "x"c as int64, 1, 16384, 0, 0);
  if (r < 0) { Print("fehlercode\n"); } else { Print("gesendet\n"); }
  return 0;
}' "fehlercode|" 0

# Gegenseite: ohne Netz-Capability bleibt sendto gesperrt (SIGSYS, rc 159).
lauf "sendto ohne Netz-Capability: SIGSYS" '@capabilities([memory.mmap])
import std.io;
fn main(): int64 {
  Print("vor\n");
  var r: int64 := sys_sendto(1, "x"c as int64, 1, 0, 0, 0);
  Print("nach\n");
  return 0;
}' "vor|" 159

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
