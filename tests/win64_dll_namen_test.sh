#!/bin/bash
# win64/PE — Linux-SO-Namen werden auf Windows-DLLs abgebildet (#2480)
#
# Vorher trug das Backend den `link`-String unveraendert in die
# Import-Tabelle: eine .exe, die "libc.so.6" importiert, und ein Windows, das
# den Start mit "libc.so.6 nicht gefunden" abbricht. Geprueft wird deshalb
# beides — die Tabelle mit objdump (dort steht der Name, den der Lader sucht)
# und, wo wine da ist, der Lauf ueber ws2_32.
set -u
cd "$(dirname "$0")/.."
LYXC=${LYXC:-./lyxc}
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pruefe() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (erwartet '$3', erhalten '$2')"; fi; }

# ------------------------------------------------------------------ Abbildung
cat > "$TMP/map.lyx" <<'EOF'
unit Main;
import std.io;
@cap(system.unsafe.ffi)
extern fn strlen(s: pchar): int64 link "libc.so.6";
@cap(network.tcp.connect)
extern fn socket(d: int64, t: int64, p: int64): int64 link "libc.so.6";
@cap(system.unsafe.ffi)
extern fn SHA256(d: int64, n: int64, md: int64): int64 link "libcrypto.so.3";
@cap(system.unsafe.ffi)
extern fn sqlite3_libversion(): int64 link "libsqlite3.so.0";
@cap(ui.display)
extern fn lstrlenA(s: pchar): int64 link "kernel32.dll";
fn main(): int64 {
  var n: int64 := strlen("abc");
  var s: int64 := socket(2, 1, 0);
  var h: int64 := SHA256(0, 0, 0);
  var v: int64 := sqlite3_libversion();
  PrintLn("len=" + IntToStr(lstrlenA("abcde")));
  return n + s + h + v;
}
EOF
if ! "$LYXC" --std-path=. "$TMP/map.lyx" --target=win64 --format=pe -o "$TMP/map.exe" > "$TMP/map.log" 2>&1; then
  bad "#2480 uebersetzt"; grep -E "error" "$TMP/map.log" | head -3
else
  ok "#2480 uebersetzt"
  if command -v objdump > /dev/null 2>&1; then
    namen=$(objdump -p "$TMP/map.exe" 2>/dev/null | grep "DLL Name:" | awk '{print $3}')
    hat() { echo "$namen" | grep -qx "$1"; }
    # Kein einziger .so-Name darf uebrig bleiben — das ist der ganze Fehler.
    uebrig=$(echo "$namen" | grep -c "\.so")
    pruefe "#2480 kein .so-Name in der Import-Tabelle" "$uebrig" "0"
    if hat "msvcrt.dll";          then ok "#2480 libc -> msvcrt.dll";               else bad "#2480 libc -> msvcrt.dll (hat: $namen)"; fi
    # Winsock entscheidet sich am FUNKTIONSnamen, nicht am Bibliotheksnamen:
    # socket steht nicht in msvcrt, obwohl es dieselbe `link`-Angabe hat.
    if hat "ws2_32.dll";          then ok "#2480 socket aus libc -> ws2_32.dll";    else bad "#2480 socket aus libc -> ws2_32.dll (hat: $namen)"; fi
    if hat "libcrypto-3-x64.dll"; then ok "#2480 libcrypto.so.3 -> OpenSSL-DLL";    else bad "#2480 libcrypto.so.3 -> OpenSSL-DLL (hat: $namen)"; fi
    if hat "libsqlite3.dll";      then ok "#2480 unbekanntes .so -> gleicher Name mit .dll"; else bad "#2480 unbekanntes .so -> .dll (hat: $namen)"; fi
    # Gegenprobe: wer schon eine DLL nennt, bekommt sie unveraendert.
    if hat "kernel32.dll";        then ok "#2480 DLL-Name bleibt unveraendert";     else bad "#2480 DLL-Name bleibt unveraendert (hat: $namen)"; fi
  fi
fi

# ------------------------------------------------------------------ Winsock
if ! command -v wine > /dev/null 2>&1; then
  echo "HINWEIS: wine fehlt — Laufzeitpruefung zu std.net.tcp uebersprungen"
  echo "----"
  echo "$PASS PASS, $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
fi
export WINEDEBUG=-all

if ! command -v python3 > /dev/null 2>&1; then
  echo "HINWEIS: python3 fehlt — Gegenstelle fuer den Winsock-Lauf nicht baubar"
  echo "----"
  echo "$PASS PASS, $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

PORT=18099
cat > "$TMP/srv.py" <<'EOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
s.settimeout(60)
c, _ = s.accept()
d = c.recv(100)
open(sys.argv[2], "wb").write(d)
c.sendall(b"hallo-von-der-gegenstelle")
c.close()
EOF

cat > "$TMP/tcp.lyx" <<'EOF'
unit Main;
import std.io;
import std.alloc;
import std.net.tcp;
fn main(): int64 {
  PrintLn("init=" + IntToStr(TcpInit()));
  var s: int64 := TcpConnectV4(127, 0, 0, 1, 18099);
  if (s == TCP_UNGUELTIG) { PrintLn("verbunden=0"); TcpEnde(); return 1; }
  PrintLn("verbunden=1");
  TcpSetRecvTimeoutMs(s, 10000);
  PrintLn("geschrieben=" + IntToStr(TcpWriteAll(s, "frage"c as int64, 5)));
  var puffer: int64 := alloc(256);
  var n: int64 := TcpRead(s, puffer, 255);
  PrintLn("gelesen=" + IntToStr(n));
  TcpClose(s);
  TcpEnde();
  return 0;
}
EOF

if ! "$LYXC" --std-path=. -I "$PWD/platform/win64" "$TMP/tcp.lyx" --target=win64 --format=pe -o "$TMP/tcp.exe" > "$TMP/tcp.log" 2>&1; then
  bad "#2480 std.net.tcp (win64) uebersetzt"; grep -E "error" "$TMP/tcp.log" | head -3
else
  ok "#2480 std.net.tcp (win64) uebersetzt"
  if command -v objdump > /dev/null 2>&1; then
    # Winsock und sonst nichts: keine msvcrt-Sockets, kein .so.
    if objdump -p "$TMP/tcp.exe" 2>/dev/null | grep -q "WSAStartup"; then
      ok "#2480 WSAStartup steht in der Import-Tabelle"
    else
      bad "#2480 WSAStartup steht in der Import-Tabelle"
    fi
  fi
  python3 -I "$TMP/srv.py" "$PORT" "$TMP/srv_sah" &
  SRV=$!
  sleep 1
  ( cd "$TMP" && timeout 90 wine ./tcp.exe ) > "$TMP/tcp.out" 2>"$TMP/tcp.err"
  wait $SRV 2>/dev/null
  t() { grep "^$1=" "$TMP/tcp.out" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r'; }
  pruefe "#2480 WSAStartup meldet Erfolg"       "$(t init)"        "0"
  pruefe "#2480 connect ueber ws2_32"           "$(t verbunden)"   "1"
  pruefe "#2480 send ueber ws2_32"              "$(t geschrieben)" "5"
  pruefe "#2480 recv ueber ws2_32"              "$(t gelesen)"     "25"
  # Gegenprobe auf der anderen Seite: die Bytes muessen wirklich angekommen
  # sein, nicht nur gezaehlt worden.
  pruefe "#2480 Gegenstelle sah die Bytes"      "$(cat "$TMP/srv_sah" 2>/dev/null)" "frage"
fi

# ------------------------------------------------- dieselbe Unit unter Linux
# Die Fassade taugt nur, wenn BEIDE Seiten sie erfuellen: gleiche Namen,
# gleiches Verhalten. Ohne diese Gegenprobe faellt erst beim naechsten
# Windows-Bau auf, dass eine Signatur auseinandergelaufen ist.
if ! "$LYXC" --std-path=. -I "$PWD/platform/linux" "$TMP/tcp.lyx" -o "$TMP/tcp_linux" > "$TMP/tcp_linux.log" 2>&1; then
  bad "#2480 std.net.tcp (linux) uebersetzt"; grep -E "error" "$TMP/tcp_linux.log" | head -3
else
  ok "#2480 std.net.tcp (linux) uebersetzt"
  python3 -I "$TMP/srv.py" "$PORT" "$TMP/srv_sah_linux" &
  SRVL=$!
  sleep 1
  timeout 90 "$TMP/tcp_linux" > "$TMP/tcp_linux.out" 2>"$TMP/tcp_linux.err"
  wait $SRVL 2>/dev/null
  tl() { grep "^$1=" "$TMP/tcp_linux.out" 2>/dev/null | head -1 | cut -d= -f2; }
  pruefe "#2480 linux: verbunden"   "$(tl verbunden)"   "1"
  pruefe "#2480 linux: geschrieben" "$(tl geschrieben)" "5"
  pruefe "#2480 linux: gelesen"     "$(tl gelesen)"     "25"
fi

echo "----"
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
