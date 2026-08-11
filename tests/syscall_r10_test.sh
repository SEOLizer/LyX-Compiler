#!/usr/bin/env bash
# tests/syscall_r10_test.sh — #1192: das VIERTE Argument eines Syscalls.
#
# Die Argumente eines Intrinsics kommen nach C-Konvention an — rdi, rsi, rdx,
# RCX, r8, r9. Der Linux-Syscall nimmt das vierte aber in **r10**. Wer das
# vergisst, laesst dort stehen, was zufaellig drin war.
#
# Bei `sendto`/`recvfrom` war das die FLAGS-Maske: je nach zufaellig gesetztem
# Bit blockierte der Aufruf (kein MSG_DONTWAIT) oder scheiterte mit EOPNOTSUPP
# (MSG_OOB). Der Wert wechselte von Lauf zu Lauf — deshalb mal Timeout, mal
# sofortiger Fehler. Jede Namensaufloesung ueber std.net.dns lief darueber,
# damit GetHostByName, HTTPGet und HTTPSGet.
#
# Der Test kommt OHNE externes Netz aus: zwei UDP-Sockets auf 127.0.0.1. Ein
# Test gegen einen echten Resolver waere netzabhaengig und gehoerte nach
# suite-external (#1176).
#
# Geprueft wird das ERGEBNIS des Aufrufs, nicht die Uebersetzbarkeit — mit
# Muell-Flags uebersetzt der Code ja, er tut nur das Falsche.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  # Der Fehler zeigte sich auch als HAENGEN — der Timeout ist Teil der Pruefung.
  got="$(timeout 10 "$TMP/c" 2>&1)"; rc=$?
  if [ "$rc" -eq 124 ]; then echo "FAIL $1: haengt (Zeitueberschreitung)"; FAIL=$((FAIL+1)); return; fi
  if [ "$rc" -ge 128 ]; then echo "FAIL $1: ABSTURZ (rc=$rc)"; FAIL=$((FAIL+1)); return; fi
  if [ "$got" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1))
  else echo "FAIL $1: '$got' erwartet '$3'"; FAIL=$((FAIL+1)); fi
}

K='import src.std.io;
fn mkaddr(port: int64): int64 {
  var a: int64 := alloc(16);
  poke8(a, 2); poke8(a + 1, 0);
  poke8(a + 2, port / 256); poke8(a + 3, port % 256);
  poke8(a + 4, 127); poke8(a + 5, 0); poke8(a + 6, 0); poke8(a + 7, 1);
  return a;
}'

# --- Der Repro aus dem Issue: 6-Argument-Syscall aus einer Wrapper-Funktion --
# In `main` direkt lief er schon vorher; erst der Aufruf aus einer eigenen
# Funktion heraus zeigte den Fehler.
out "sendto/recvfrom aus Wrapper-Funktionen" "$K
fn sendIt(fd: int64, buf: int64, n: int64, addr: int64): int64 {
  return sys_sendto(fd, buf, n, 0, addr, 16);
}
fn recvIt(fd: int64, buf: int64, n: int64): int64 {
  return sys_recvfrom(fd, buf, n, 0, 0, 0);
}
fn main(): int64 {
  var rx: int64 := sys_socket(2, 2, 0);
  var ra: int64 := mkaddr(38217);
  if (sys_bind(rx, ra, 16) != 0) { PrintLn(0 - 1); return 1; }
  var tx: int64 := sys_socket(2, 2, 0);
  var buf: int64 := alloc(16);
  poke8(buf, 65); poke8(buf + 1, 66);
  PrintLn(sendIt(tx, buf, 2, ra));
  var rb: int64 := alloc(16);
  PrintLn(recvIt(rx, rb, 16));
  PrintLn(peek8(rb));
  PrintLn(peek8(rb + 1));
  return 0;
}" '2
2
65
66'

# Dieselbe Folge direkt in `main` — sie lief schon vorher und muss es weiter.
out "sendto/recvfrom direkt in main" "$K
fn main(): int64 {
  var rx: int64 := sys_socket(2, 2, 0);
  var ra: int64 := mkaddr(38219);
  if (sys_bind(rx, ra, 16) != 0) { PrintLn(0 - 1); return 1; }
  var tx: int64 := sys_socket(2, 2, 0);
  var buf: int64 := alloc(16);
  poke8(buf, 88);
  PrintLn(sys_sendto(tx, buf, 1, 0, ra, 16));
  var rb: int64 := alloc(16);
  PrintLn(sys_recvfrom(rx, rb, 16, 0, 0, 0));
  PrintLn(peek8(rb));
  return 0;
}" '1
1
88'

# Das vierte Argument muss auch WIRKEN, nicht nur 0 sein: MSG_DONTWAIT (0x40)
# auf einem leeren Socket kehrt sofort mit EAGAIN (-11) zurueck, statt zu
# blockieren. Mit Muell im Register waere das Ergebnis beliebig.
out "flags wirken: MSG_DONTWAIT liefert EAGAIN" "$K
fn recvNb(fd: int64, buf: int64, n: int64): int64 {
  return sys_recvfrom(fd, buf, n, 64, 0, 0);
}
fn main(): int64 {
  var rx: int64 := sys_socket(2, 2, 0);
  var ra: int64 := mkaddr(38221);
  if (sys_bind(rx, ra, 16) != 0) { PrintLn(0 - 1); return 1; }
  var rb: int64 := alloc(16);
  PrintLn(recvNb(rx, rb, 16));
  return 0;
}" '-11'

# --- Gegenprobe: Syscalls mit weniger Argumenten bleiben unberuehrt --------
out "3-Argument-Syscall aus einer Wrapper-Funktion" "$K
fn bindIt(fd: int64, a: int64): int64 { return sys_bind(fd, a, 16); }
fn main(): int64 {
  var fd: int64 := sys_socket(2, 2, 0);
  PrintLn(bindIt(fd, mkaddr(38223)));
  return 0;
}" '0'

# `sys_send` teilt den Zweig mit `sys_sendto`, hat aber nur vier Argumente —
# dort IST das vierte die Flags-Maske, die Behandlung ist also dieselbe.
out "sys_send mit verbundenem Socket" "$K
fn sendC(fd: int64, buf: int64, n: int64): int64 { return sys_send(fd, buf, n, 0); }
fn main(): int64 {
  var rx: int64 := sys_socket(2, 2, 0);
  var ra: int64 := mkaddr(38225);
  if (sys_bind(rx, ra, 16) != 0) { PrintLn(0 - 1); return 1; }
  var tx: int64 := sys_socket(2, 2, 0);
  if (sys_connect(tx, ra, 16) != 0) { PrintLn(0 - 2); return 1; }
  var buf: int64 := alloc(16);
  poke8(buf, 90);
  PrintLn(sendC(tx, buf, 1));
  var rb: int64 := alloc(16);
  PrintLn(sys_recvfrom(rx, rb, 16, 0, 0, 0));
  PrintLn(peek8(rb));
  return 0;
}" '1
1
90'

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
