#!/usr/bin/env bash
# tests/seccomp_filter_test.sh — #1185: der seccomp-Filter deckt die Syscalls
# ab, die der Codegen tatsaechlich emittiert.
#
# `mkdir` (83), `unlink` (87) und `rename` (82) starben mit SIGSYS, obwohl die
# passende Capability gewaehrt war: der Filter kannte nur die *at-Varianten
# (`unlinkat`, `openat`), der Codegen emittiert aber die DIREKTen. Dieselbe
# Luecke traf `getpid` (39) — OpenSSL ruft es beim Init, womit HTTPS mit
# aktivem LCBS gar nicht nutzbar war.
#
# Geprueft wird beides: dass der erlaubte Fall LAEUFT und dass der nicht
# gewaehrte weiterhin STIRBT. Ein Test, der nur das erste prueft, koennte durch
# einen Filter erfuellt werden, der alles durchlaesst — und genau das waere das
# Gegenteil von dem, was hier abgesichert wird.
#
# Massstab ist capabilities.md:
#   fs.create — "Neue Dateien und Verzeichnisse anlegen"
#   fs.delete — "Dateien und Verzeichnisse loeschen"
#   fs.meta   — "Metadaten LESEN (stat, Verzeichnislisting)"
#   fs.perm   — "Zugriffsrechte und Eigentuemer aendern" (#1188)
# chmod/chown haengen an fs.perm, NICHT an fs.meta: wer nur auflisten will,
# soll nicht stillschweigend Rechte umschreiben duerfen.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; rm -rf /tmp/lyx_sc_probe_* 2>/dev/null' EXIT
PASS=0; FAIL=0

# Laeuft bis zum Ende durch (Exit 0, kein SIGSYS).
runs() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  timeout 10 "$TMP/c" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 159 ]; then echo "FAIL $1: SIGSYS trotz gewaehrter Capability"; FAIL=$((FAIL+1)); return; fi
  if [ "$rc" -ne 0 ]; then echo "FAIL $1: rc=$rc"; FAIL=$((FAIL+1)); return; fi
  echo "PASS $1"; PASS=$((PASS+1))
}

# Wird vom Filter getoetet (SIGSYS, rc=159).
blocked() { # name, quelltext
  printf '%s\n' "$2" > "$TMP/c.lyx"; rm -f "$TMP/c"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" >/dev/null 2>&1; then
    echo "FAIL $1: uebersetzt nicht"; FAIL=$((FAIL+1)); return
  fi
  # Die Shell meldet SIGSYS auf ihrem eigenen stderr; hier ist der Tod der
  # ERWARTETE Ausgang, also unterdrueckt.
  ( timeout 10 "$TMP/c" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq 159 ]; then echo "PASS $1 (SIGSYS)"; PASS=$((PASS+1))
  else echo "FAIL $1: nicht geblockt (rc=$rc)"; FAIL=$((FAIL+1)); fi
}

IO='import src.std.io;'

# --- fs.create: Verzeichnisse anlegen ------------------------------------
runs "mkdir mit fs.create" "@capabilities([fs.read, fs.write, fs.create, fs.delete, fs.meta])
$IO
fn main(): int64 {
  var r: int64 := mkdir(\"/tmp/lyx_sc_probe_a\"c, 493);
  rmdir(\"/tmp/lyx_sc_probe_a\"c);
  return 0;
}"

blocked "mkdir OHNE fs.create" "@capabilities([fs.read])
$IO
fn main(): int64 {
  var r: int64 := mkdir(\"/tmp/lyx_sc_probe_b\"c, 493);
  return 0;
}"

# --- fs.delete: loeschen --------------------------------------------------
runs "unlink mit fs.delete" "@capabilities([fs.read, fs.write, fs.create, fs.delete])
$IO
fn main(): int64 {
  var r: int64 := unlink(\"/tmp/lyx_sc_probe_gibtesnicht\"c);
  return 0;
}"

blocked "unlink OHNE fs.delete" "@capabilities([fs.read, fs.write])
$IO
fn main(): int64 {
  var r: int64 := unlink(\"/tmp/lyx_sc_probe_gibtesnicht\"c);
  return 0;
}"

runs "rmdir mit fs.delete" "@capabilities([fs.read, fs.delete])
$IO
fn main(): int64 {
  var r: int64 := rmdir(\"/tmp/lyx_sc_probe_gibtesnicht\"c);
  return 0;
}"

# --- rename verlangt BEIDE Capabilities ----------------------------------
# Umbenennen legt am Ziel an und entfernt an der Quelle. Mit nur einer der
# beiden waere `rename` ein Weg, ohne fs.delete zu loeschen.
runs "rename mit fs.create UND fs.delete" "@capabilities([fs.read, fs.write, fs.create, fs.delete])
$IO
fn main(): int64 {
  var r: int64 := rename(\"/tmp/lyx_sc_probe_x\"c, \"/tmp/lyx_sc_probe_y\"c);
  return 0;
}"

blocked "rename mit NUR fs.create" "@capabilities([fs.read, fs.write, fs.create])
$IO
fn main(): int64 {
  var r: int64 := rename(\"/tmp/lyx_sc_probe_x\"c, \"/tmp/lyx_sc_probe_y\"c);
  return 0;
}"

# --- Basissatz: harmlose Introspektion ------------------------------------
# OpenSSL ruft getpid beim Init; ohne diesen Satz stirbt jedes Programm mit
# extern gelinkter Bibliothek, bevor es etwas tut.
runs "getpid ohne eigene Capability" "@capabilities([fs.read])
$IO
fn main(): int64 {
  var p: int64 := getpid();
  if (p > 0) { return 0; }
  return 1;
}"

# --- Metadaten LESEN, nicht schreiben ------------------------------------
runs "stat mit fs.meta" "@capabilities([fs.read, fs.meta])
$IO
fn main(): int64 {
  var buf: int64 := alloc(256);
  var r: int64 := stat(\"/tmp\"c, buf);
  return 0;
}"

# #1188: chmod SCHREIBT Metadaten und haengt deshalb an fs.perm — nicht an
# fs.meta, das laut Doku das LESEN abdeckt. Beide Richtungen geprueft.
runs "chmod mit fs.perm" "@capabilities([fs.read, fs.perm])
$IO
fn main(): int64 {
  var r: int64 := chmod(\"/tmp/lyx_sc_probe_gibtesnicht\"c, 420);
  return 0;
}"

blocked "chmod mit fs.meta allein bleibt geblockt" "@capabilities([fs.read, fs.write, fs.create, fs.delete, fs.meta])
$IO
fn main(): int64 {
  var r: int64 := chmod(\"/tmp/lyx_sc_probe_gibtesnicht\"c, 420);
  return 0;
}"

runs "chown mit fs.perm" "@capabilities([fs.read, fs.perm])
$IO
fn main(): int64 {
  var r: int64 := chown(\"/tmp/lyx_sc_probe_gibtesnicht\"c, 0 - 1, 0 - 1);
  return 0;
}"

blocked "chown ohne fs.perm" "@capabilities([fs.read, fs.meta])
$IO
fn main(): int64 {
  var r: int64 := chown(\"/tmp/lyx_sc_probe_gibtesnicht\"c, 0 - 1, 0 - 1);
  return 0;
}"

# fs.perm gibt NUR Rechte frei — kein Lesen, kein Schreiben von Inhalten.
blocked "fs.perm oeffnet keine Dateien" "@capabilities([fs.perm])
$IO
fn main(): int64 {
  var fd: int64 := sys_open(\"/etc/hostname\"c, 0, 0);
  return 0;
}"

# --- #1193: Optionen und Adressen der eigenen Verbindung ------------------
# Ohne setsockopt stirbt jeder TLS-Handshake: OpenSSL setzt TCP_ULP. Und
# std.net.socket bietet TCPConnSetNodelay/SetKeepAlive/SetRecvBuf/GetError an,
# die alle darauf laufen.
runs "setsockopt mit network.tcp.connect" "@capabilities([fs.read, fs.write, network.tcp.connect])
$IO
fn main(): int64 {
  var fd: int64 := sys_socket(2, 1, 0);
  var val: int64 := alloc(8);
  poke64(val, 1);
  var r: int64 := sys_setsockopt(fd, 1, 9, val, 4);
  if (r != 0) { return 1; }
  return 0;
}"

runs "getsockopt mit network.tcp.connect" "@capabilities([fs.read, fs.write, network.tcp.connect])
$IO
fn main(): int64 {
  var fd: int64 := sys_socket(2, 1, 0);
  var val: int64 := alloc(8);
  var lenp: int64 := alloc(8);
  poke64(lenp, 4);
  var r: int64 := sys_getsockopt(fd, 1, 4, val, lenp);
  return 0;
}"

# Ohne Netzwerk-Capability bleibt es geblockt — die Freigabe haengt an der
# Verbindung, nicht an der Sandbox allgemein.
blocked "setsockopt ohne Netzwerk-Capability" "@capabilities([fs.read, fs.write])
$IO
fn main(): int64 {
  var val: int64 := alloc(8);
  poke64(val, 1);
  var r: int64 := sys_setsockopt(3, 1, 9, val, 4);
  return 0;
}"

# --- Gegenproben: der Filter bleibt scharf --------------------------------
# Ohne jede fs-Capability darf auch das Oeffnen nicht gehen.
blocked "open ohne fs-Capability" "@capabilities([system.exit])
$IO
fn main(): int64 {
  var fd: int64 := sys_open(\"/etc/hostname\"c, 0, 0);
  return 0;
}"

# Ein Programm ohne @capabilities laeuft ungefiltert — die Sandbox greift nur,
# wenn sie angefordert wird.
runs "ohne @capabilities laeuft alles" "$IO
fn main(): int64 {
  var r: int64 := mkdir(\"/tmp/lyx_sc_probe_c\"c, 493);
  rmdir(\"/tmp/lyx_sc_probe_c\"c);
  return 0;
}"

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
test "$FAIL" -eq 0
