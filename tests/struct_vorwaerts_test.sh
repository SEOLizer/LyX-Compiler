#!/usr/bin/env bash
# tests/struct_vorwaerts_test.sh — #1451.
#
# Ein Struct-Typ, der BENUTZT wird, bevor seine Deklaration in der Datei
# steht, bekam kein Layout. Eine lokale Variable dieses Typs war damit
# groesse-null: der erste Feldzugriff traf ins Leere, das Programm starb mit
# Speicherzugriffsfehler. Fuer GLOBALE Variablen gab es das Vorziehen schon
# (#1256) — nur eben punktuell.
#
# Gefunden ueber std/net/socket.lyx: dort steht `TCPConn` hinter
# `TCPListenerAccept`, das den Typ zurueckgibt. Jeder TCP-Server stuerzte beim
# ersten Zugriff auf das Ergebnis ab.
#
# GEPRUEFT WIRD DER ABSTURZ UND DER WERT. Ein Test, der nur "uebersetzt" prueft,
# waere vor dem Fix gruen gewesen — der Compiler meldete nichts.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

out() { # name, quelltext, erwartete ausgabe
  printf '%s\n' "$2" > "$TMP/p.lyx"; rm -f "$TMP/p"
  if ! "$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" >/dev/null 2>&1; then
    no "$1" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/p.lyx" -o "$TMP/p" 2>&1 | grep -i error | head -1)"
    return
  fi
  got="$(timeout 30 "$TMP/p" 2>&1)"; rc=$?
  if [ "$rc" -ge 128 ]; then no "$1" "ABSTURZ (rc=$rc)"; return; fi
  if [ "$got" = "$3" ]; then ok "$1"; else no "$1" "'$got' erwartet '$3'"; fi
}

# ===========================================================================
# Die Reproduktion in Kleinform
# ===========================================================================

out "#1451: Rueckgabetyp steht hinter der Funktion" 'import std.io;
fn Macher(): Spaet {
  var s: Spaet;
  s.wert := 42;
  return s;
}
type Spaet = struct { wert: int64; };
fn main(): int64 {
  var s: Spaet := Macher();
  PrintLn(IntToStr(s.wert));
  return 0;
}' "42"

# Mehrere Felder: bei fehlendem Layout stimmten auch die Offsets nicht, nicht
# nur die Groesse.
out "#1451: mehrere Felder, alle Offsets stimmen" 'import std.io;
fn Bau(): Spaet {
  var s: Spaet;
  s.a := 1; s.b := 2; s.c := 3;
  return s;
}
type Spaet = struct { a: int64; b: int64; c: int64; };
fn main(): int64 {
  var s: Spaet := Bau();
  PrintLn(IntToStr(s.a * 100 + s.b * 10 + s.c));
  return 0;
}' "123"

# Lokale Variable eines spaeter deklarierten Typs, ohne Umweg ueber eine
# Rueckgabe.
out "#1451: lokale Variable eines spaeteren Typs" 'import std.io;
fn Nutz(): int64 {
  var s: Spaet;
  s.wert := 7;
  return s.wert * 6;
}
type Spaet = struct { wert: int64; };
fn main(): int64 { PrintLn(IntToStr(Nutz())); return 0; }' "42"

# Parameter eines spaeter deklarierten Typs.
out "#1451: Parameter eines spaeteren Typs" 'import std.io;
fn Lies(s: Spaet): int64 { return s.wert + 1; }
type Spaet = struct { wert: int64; };
fn main(): int64 {
  var s: Spaet;
  s.wert := 41;
  PrintLn(IntToStr(Lies(s)));
  return 0;
}' "42"

# NICHT geprueft wird hier ein Struct MIT EINEM STRUCT ALS FELD. Das stuerzt
# auch bei richtiger Deklarationsreihenfolge ab und ist ein eigener offener
# Defekt (#1513) — ein Test, der daran haengt, misst nicht das, was drauf
# steht. Das Vorziehen selbst kommt damit zurecht: es baut in Runden und
# vermisst ein Struct erst, wenn jedes seiner Struct-Felder vermessen ist.

# ===========================================================================
# Der gemeldete Fall selbst
# ===========================================================================

# TCPListenerAccept liefert TCPConn, das in der Unit weiter unten steht.
# Gemessen wird gegen einen Listener auf dem eigenen Rechner — ohne Netz nach
# draussen. Der Port haengt an der PID: zwei Laeufe kurz hintereinander
# stolperten sonst ueber den noch belegten Port des vorigen.
PORT=$(( 18300 + ($$ % 900) ))
out "#1451: TCP-Server nimmt eine Verbindung an" 'import std.io;
import std.net.socket;
fn main(): int64 {
  var srv: TCPListener := TCPListenerNew();
  var addr: int64 := BufferAlloc(SOCKADDR_IN_SIZE);
  var ip: int64 := IPPack(127, 0, 0, 1);
  SockAddrInCreate(addr, ip, '"$PORT"');
  TCPListenerBind(srv, addr);
  TCPListenerListen(srv, 16);
  var cli: TCPConn := TCPConnect(ip, '"$PORT"');
  var conn: TCPConn := TCPListenerAccept(srv);
  if (conn.fd > 0) { PrintLn("verbunden"); } else { PrintLn("kein fd"); }
  TCPConnClose(conn); TCPConnClose(cli); TCPListenerClose(srv);
  return 0;
}' "verbunden"

# ===========================================================================
# Gegenprobe: die uebliche Reihenfolge bleibt, wie sie war
# ===========================================================================

out "#1451: Typ vor der Nutzung unveraendert" 'import std.io;
type Frueh = struct { a: int64; b: int64; };
fn main(): int64 {
  var f: Frueh;
  f.a := 6; f.b := 7;
  PrintLn(IntToStr(f.a * f.b));
  return 0;
}' "42"

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
