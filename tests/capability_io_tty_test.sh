#!/bin/bash
# #1866–#1869, #1873: die neuen Capabilities.
#
# Gemessen wird an der WIRKUNG — ob der Aufruf unter dem Filter durchkommt,
# nicht ob der Name uebersetzt. Und es werden BEIDE Richtungen gemessen: dass
# das Recht den Aufruf freigibt UND dass er ohne das Recht stirbt. Ein Test,
# der nur die erste Haelfte prueft, waere auch von einem Filter erfuellt, der
# alles durchlaesst (#1823).
#
# SIGSYS ist Exit 159 (128 + 31).

cd "$(dirname "$0")/.." || exit 1
LYXC="${LYXC:-./lyxc}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

BASIS="system.exit, system.memory.heap"

# lauf <Name> <caps> <rumpf> <erwartet: frei|gesperrt>
lauf() {
  local NAME="$1" CAPS="$2" RUMPF="$3" WILL="$4"
  cat > "$TMP/p.lyx" <<EOF
@capabilities([$CAPS])
unit main;
import std.io;
fn main(): int64 {
$RUMPF
  return 0;
}
EOF
  if ! $LYXC "$TMP/p.lyx" -o "$TMP/p" > "$TMP/p.log" 2>&1; then
    no "$NAME: uebersetzt nicht — $(sed -n '2p' "$TMP/p.log")"
    return
  fi
  # SIGSYS meldet die Shell selbst ("Ungueltiger Betriebssystemaufruf") —
  # das ist hier der ERWARTETE Ausgang und darf die Ausgabe nicht fluten.
  ( ulimit -c 0; "$TMP/p" > /dev/null 2>&1 ) 2>/dev/null; local rc=$?
  if [ "$WILL" = "frei" ]; then
    if [ "$rc" -eq 159 ]; then
      no "$NAME: stirbt an SIGSYS, obwohl das Recht deklariert ist"
    else
      ok "$NAME: laeuft mit dem Recht (exit $rc)"
    fi
  else
    if [ "$rc" -eq 159 ]; then
      ok "$NAME: stirbt ohne das Recht an SIGSYS"
    else
      no "$NAME: laeuft OHNE das Recht (exit $rc) — der Filter deckt zu viel ab"
    fi
  fi
}

echo "-- #1866: nanosleep an system.time --"
SCHLAF='  var ts: int64 := alloc(16); poke64(ts, 0); poke64(ts + 8, 1000000);
  var r: int64 := sys_nanosleep(ts, 0);'
lauf "nanosleep mit system.time"  "$BASIS, system.time" "$SCHLAF" frei
lauf "nanosleep ohne system.time" "$BASIS"              "$SCHLAF" gesperrt

echo "-- #1868: io.wait --"
WARTE='  var pfd: int64 := alloc(8); poke64(pfd, 0); poke64(pfd + 4, 1);
  var r: int64 := sys_poll(pfd, 1, 0);'
lauf "poll mit io.wait"  "$BASIS, io.wait" "$WARTE" frei
lauf "poll ohne io.wait" "$BASIS"          "$WARTE" gesperrt
EPOLL='  var e: int64 := sys_epoll_create1(0);'
lauf "epoll_create1 mit io.wait"  "$BASIS, io.wait" "$EPOLL" frei
lauf "epoll_create1 ohne io.wait" "$BASIS"          "$EPOLL" gesperrt

echo "-- #1869: io.fd --"
ROEHRE='  var fds: int64 := alloc(8); var r: int64 := sys_pipe2(fds, 0);'
lauf "pipe2 mit io.fd"  "$BASIS, io.fd" "$ROEHRE" frei
lauf "pipe2 ohne io.fd" "$BASIS"        "$ROEHRE" gesperrt
DUP='  var r: int64 := sys_dup(0);'
lauf "dup mit io.fd"  "$BASIS, io.fd" "$DUP" frei
lauf "dup ohne io.fd" "$BASIS"        "$DUP" gesperrt

echo "-- #1867: system.tty --"
# TCGETS auf stdin. Ob es ENOTTY liefert, ist gleichgueltig — gemessen wird,
# ob der Filter den Aufruf ueberhaupt zulaesst.
TTY='  var t: int64 := alloc(64); var r: int64 := sys_ioctl(0, 21505, t);'
lauf "TCGETS mit system.tty"  "$BASIS, system.tty" "$TTY" frei
lauf "TCGETS ohne system.tty" "$BASIS"             "$TTY" gesperrt
# Die Eingrenzung ist die eigentliche Aussage: system.tty gibt NICHT jedes
# ioctl frei. 0x8933 (SIOCGIFINDEX) ist ein Netz-ioctl.
NETZ='  var t: int64 := alloc(64); var r: int64 := sys_ioctl(0, 35123, t);'
lauf "Netz-ioctl trotz system.tty" "$BASIS, system.tty" "$NETZ" gesperrt

echo "-- #1873: audio.play --"
# Auf Linux ohne Syscall-Wirkung; geprueft wird, dass der Name existiert und
# NICHT dasselbe Bit setzt wie audio.mic.
for NAME in audio.play audio.mic; do
  cat > "$TMP/a.lyx" <<EOF
@capabilities([system.exit, system.memory.heap, $NAME])
unit main;
fn main(): int64 { return 0; }
EOF
  if $LYXC "$TMP/a.lyx" --target=lyxos -o "$TMP/a_$NAME.lbf" > "$TMP/a.log" 2>&1; then
    ok "$NAME ist deklarierbar (lyxos)"
  else
    no "$NAME ist deklarierbar (lyxos) — $(sed -n '2p' "$TMP/a.log")"
  fi
done
if [ -f "$TMP/a_audio.play.lbf" ] && [ -f "$TMP/a_audio.mic.lbf" ]; then
  if cmp -s "$TMP/a_audio.play.lbf" "$TMP/a_audio.mic.lbf"; then
    no "audio.play und audio.mic erzeugen dasselbe Abbild — gleiches CAPS-Bit"
  else
    ok "audio.play setzt ein anderes CAPS-Bit als audio.mic"
  fi
fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" = "0" ] || exit 1
echo "OK: io.wait, io.fd, system.tty, audio.play, nanosleep an system.time"
exit 0
