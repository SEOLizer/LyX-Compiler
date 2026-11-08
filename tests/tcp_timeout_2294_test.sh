#!/usr/bin/env bash
# tests/tcp_timeout_2294_test.sh — TCP-Zeitlimits in std.net.socket (#2294).
#
# Bis 1.2.31J gab es Empfangs- und Sende-Zeitlimits nur fuer UDP (#1641). Eine
# TCP-Gegenstelle, die die Verbindung offen haelt und nichts sendet, haengte
# den Aufrufer in TCPConnRead auf, ohne dass ein Verbindungsabbruch ihn weckt.
#
# Gemessen wird die WIRKUNG, nicht das Vorhandensein: dass eine Leseoperation
# nach der gesetzten Zeit mit EAGAIN (-11) zurueckkommt UND dass dieselbe
# Verbindung mit grosszuegigem Zeitlimit die Daten noch bekommt. Nur die erste
# Haelfte zu pruefen waere auch von einer Fassung erfuellt, die immer sofort
# EAGAIN meldet; nur die zweite auch von einer, die das Zeitlimit ignoriert
# (#1823, beide Seiten messen).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1${2:+ — $2}"; FAIL=$((FAIL+1)); }

cat > "$TMP/t.lyx" <<'EOF'
import std.io;
import std.string;
import std.net.socket;
import std.net.types;
import std.time;
import std.alloc;

// Lauscher auf 127.0.0.1 mit vom Kernel gewaehltem Port, dann zu sich selbst
// verbinden. Ein Prozess genuegt: der Lauscher nimmt an und sendet NICHTS,
// genau der Fall, der ohne Zeitlimit haengt.
fn main(): int64 {
  var l: TCPListener := TCPListenerNew();
  if (l.fd < 0) { PrintStrLn("LAUSCHER_FEHLT"c); return 1; }
  TCPListenerSetReuseAddr(l);
  var port: int64 := 24294;
  var versuch: int64 := 0;
  var geb: int64 := 0 - 1;
  while (versuch < 20 && geb < 0) {
    geb := TCPListenerBindTo(l, IPPack(127, 0, 0, 1), port + versuch);
    if (geb < 0) { versuch := versuch + 1; }
  }
  if (geb < 0) { PrintStrLn("BIND_FEHLT"c); return 1; }
  var p: int64 := port + versuch;
  if (TCPListenerListen(l, 4) < 0) { PrintStrLn("LISTEN_FEHLT"c); return 1; }

  var c: TCPConn := TCPConnect(IPPack(127, 0, 0, 1), p);
  if (c.fd < 0) { PrintStrLn("CONNECT_FEHLT"c); return 1; }
  var s: TCPConn := TCPListenerAccept(l);
  if (s.fd < 0) { PrintStrLn("ACCEPT_FEHLT"c); return 1; }

  var puf: pchar := alloc(64) as pchar;

  // 1. Zeitlimit 0,25 s, Gegenstelle sendet nichts -> EAGAIN nach ~250 ms.
  var rcset: int64 := TCPConnSetRecvTimeout(c, 0, 250000);
  PrintStr("set_rc="c); PrintLn(rcset);
  var t0: int64 := NowMs();
  var r1: int64 := TCPConnRead(c, puf, 64);
  var d1: int64 := NowMs() - t0;
  PrintStr("read1_rc="c); PrintLn(r1);
  PrintStr("read1_ms="c); PrintLn(d1);

  // 2. Dieselbe Verbindung, grosszuegiges Zeitlimit: die Daten muessen
  //    ankommen. Der Lauscher sendet jetzt.
  TCPConnSetRecvTimeout(c, 5, 0);
  TCPConnWrite(s, "hallo"c, 5);
  var r2: int64 := TCPConnRead(c, puf, 64);
  PrintStr("read2_rc="c); PrintLn(r2);
  if (r2 == 5) {
    StrSetChar(puf, 5, 0);
    PrintStr("read2_text="c); PrintStrLn(puf);
  }

  // 3. Sende-Zeitlimit laesst sich setzen und stoert den Normalfall nicht.
  PrintStr("snd_rc="c); PrintLn(TCPConnSetSendTimeout(c, 1, 0));
  PrintStr("write_rc="c); PrintLn(TCPConnWrite(c, "ok"c, 2));

  // 4. Accept-Zeitlimit am Lauscher: kein weiterer Verbinder -> EAGAIN.
  PrintStr("acc_set_rc="c); PrintLn(TCPListenerSetAcceptTimeout(l, 0, 250000));
  var t2: int64 := NowMs();
  var a2: TCPConn := TCPListenerAccept(l);
  var d2: int64 := NowMs() - t2;
  PrintStr("accept_fd="c); PrintLn(a2.fd);
  PrintStr("accept_ms="c); PrintLn(d2);

  TCPConnClose(c); TCPConnClose(s); TCPListenerClose(l);
  return 0;
}
EOF

if ! ( cd "$ROOT" && timeout 200 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" ) >"$TMP/b.log" 2>&1; then
  no "uebersetzt" "$(grep -m1 -iE 'error|sema' "$TMP/b.log")"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "uebersetzt"

AUS="$( ulimit -c 0; cd "$TMP" && timeout 60 ./t 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then
  no "laeuft" "rc=$rc, Ausgabe: $(echo "$AUS" | tr '\n' ' ' | cut -c1-200)"
  echo "=== PASS=$PASS FAIL=$FAIL"; exit 1
fi
hol() { echo "$AUS" | sed -n "s/^$1=//p" | head -1; }

[ "$(hol set_rc)" = "0" ] && ok "TCPConnSetRecvTimeout meldet Erfolg" \
  || no "set_rc" "'$(hol set_rc)' statt 0"

# Die WIRKUNG: Rueckkehr mit EAGAIN, nicht blockieren. -11 = EAGAIN.
[ "$(hol read1_rc)" = "-11" ] && ok "Lesen laeuft ins Zeitlimit (EAGAIN)" \
  || no "read1_rc" "'$(hol read1_rc)' statt -11"

# Und zwar NACH der gesetzten Zeit, nicht sofort — sonst wuerde auch eine
# Fassung bestehen, die jeden Lesezugriff abweist.
MS="$(hol read1_ms)"
if [ -n "$MS" ] && [ "$MS" -ge 200 ] && [ "$MS" -le 3000 ]; then
  ok "Wartezeit ${MS} ms liegt beim gesetzten Viertelsekundenwert"
else
  no "read1_ms" "'$MS' ms liegt nicht zwischen 200 und 3000"
fi

# Gegenrichtung: mit grosszuegigem Limit kommen die Daten an.
[ "$(hol read2_rc)" = "5" ] && ok "mit 5-s-Limit kommen die 5 Byte an" \
  || no "read2_rc" "'$(hol read2_rc)' statt 5"
[ "$(hol read2_text)" = "hallo" ] && ok "Inhalt 'hallo' unveraendert" \
  || no "read2_text" "'$(hol read2_text)'"

[ "$(hol snd_rc)" = "0" ] && ok "TCPConnSetSendTimeout meldet Erfolg" \
  || no "snd_rc" "'$(hol snd_rc)' statt 0"
[ "$(hol write_rc)" = "2" ] && ok "Senden mit gesetztem Limit schreibt 2 Byte" \
  || no "write_rc" "'$(hol write_rc)' statt 2"

[ "$(hol acc_set_rc)" = "0" ] && ok "TCPListenerSetAcceptTimeout meldet Erfolg" \
  || no "acc_set_rc" "'$(hol acc_set_rc)' statt 0"
[ "$(hol accept_fd)" = "-11" ] && ok "Accept laeuft ins Zeitlimit (EAGAIN)" \
  || no "accept_fd" "'$(hol accept_fd)' statt -11"
AMS="$(hol accept_ms)"
if [ -n "$AMS" ] && [ "$AMS" -ge 200 ] && [ "$AMS" -le 3000 ]; then
  ok "Accept-Wartezeit ${AMS} ms liegt beim gesetzten Wert"
else
  no "accept_ms" "'$AMS' ms liegt nicht zwischen 200 und 3000"
fi

# Die Zeitlimit-Rechnung steht nur noch an EINER Stelle (sockSetzeTimeval);
# eine zweite Kopie waere die Stelle, die beim naechsten Mal nicht nachgezogen
# wird.
KOPIEN="$(grep -c "SO_RCVTIMEO, tv, 16\|SO_SNDTIMEO, tv, 16" "$ROOT/std/net/socket.lyx" || true)"
[ "$KOPIEN" = "0" ] && ok "keine zweite timeval-Rechnung im Modul" \
  || no "timeval-Kopien" "$KOPIEN handgeschriebene setsockopt-Aufrufe fuer Zeitlimits"

echo "=== PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
