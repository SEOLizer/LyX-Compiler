#!/usr/bin/env bash
# tests/bibliotheken_runde3_test.sh — #1604, #1609, #1610, #1611.
#
# Vier Bibliotheken, die still das Falsche taten. Zwei davon mit
# Angriffsflaeche nach aussen (SMTP-Ueberlauf, NTP-Zeitfaelschung).
#
# GEPRUEFT WIRD DER WEG, nicht das Ergebnis:
#   #1611 an der ZAHL, die der Kernel zurueckgibt (-14 EFAULT gegen 0) — ein
#         Test auf "stuerzt nicht ab" waere vorher gruen gewesen.
#   #1610 daran, dass die zu lange Nachricht ABGELEHNT wird statt still
#         weiterzuschreiben; ein Test auf den Rueckgabewert allein haette den
#         Ueberlauf nicht gesehen, denn das Programm stuerzte dabei nicht ab.
#   #1609 an synthetischen Antwortpaketen: gespiegelter Origin-Stempel,
#         Betriebsart, Kiss-o'-Death. Kein Netz noetig, und der Angriffsfall
#         laesst sich sonst gar nicht nachstellen.
#   #1604 an Werten aus dem hinteren Teil der Tabelle (Eintrag 200+), den es
#         vorher nicht gab.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

lauf() {
  local name="$1" erwartet="$2" quelle="$3"
  printf '%s\n' "$quelle" > "$TMP/t.lyx"
  if ! timeout 300 "$LYXC" --std-path="$ROOT" "$TMP/t.lyx" -o "$TMP/t" >"$TMP/c.log" 2>&1; then
    no "$name" "uebersetzt nicht: $(grep -m1 -iE 'sema error|codegen error' "$TMP/c.log")"
    return
  fi
  # Leerzeilen bleiben stehen — bei #1610 ist die Leerzeile zwischen Kopf und
  # Rumpf Teil dessen, was geprueft wird. Weg muss nur das LCBS-Banner.
  local got; got="$(timeout 60 "$TMP/t" 2>&1 | tr -d '\r' \
    | grep -vE 'Capabilit|^===|^Programm:|^  o |^  [A-Za-z-]+ ' | sed '/./,$!d')"
  if [ "$got" = "$erwartet" ]; then ok "$name"; else
    no "$name" "erwartet [$(echo "$erwartet"|tr '\n' '|')], bekam [$(echo "$got"|tr '\n' '|')]"
  fi
}

# ===========================================================================
# #1611 — Socket-Optionen: Adresse statt Wert
# ===========================================================================
# Der Kernel selbst ist der Zeuge: mit dem Wert antwortet er EFAULT (-14).
lauf "#1611: alle Setter melden Erfolg statt EFAULT" \
'0
0
0
0
0
0' 'import std.io;
import std.net.socket;
import std.net.types;
fn main(): int64 {
  var l: TCPListener := TCPListenerNew();
  PrintLn(IntToStr(TCPListenerSetReuseAddr(l)));
  PrintLn(IntToStr(TCPListenerSetReusePort(l)));
  var u: UDPSocket := UDPSocketNew();
  PrintLn(IntToStr(UDPSocketSetReuseAddr(u)));
  PrintLn(IntToStr(UDPSocketSetRecvBuf(u, 65536)));
  PrintLn(IntToStr(UDPSocketSetSendBuf(u, 65536)));
  PrintLn(IntToStr(UDPSocketSetBroadcast(u, true)));
  return 0;
}'

# Die Option muss auch WIRKEN, nicht nur 0 melden: SO_RCVBUF meldet der Kernel
# beim Lesen zurueck (verdoppelt, das ist Linux-Konvention).
lauf "#1611: gesetzte Puffergroesse ist danach wirklich gesetzt" 'gesetzt' 'import std.io;
import std.net.socket;
import std.net.types;
fn main(): int64 {
  var u: UDPSocket := UDPSocketNew();
  UDPSocketSetRecvBuf(u, 65536);
  var puf: int64 := BufferAlloc(16);
  poke64(puf, 0); poke64(puf + 8, 0); poke32(puf + 8, 4);
  sys_getsockopt(u.fd, SOL_SOCKET, SO_RCVBUF, puf, puf + 8);
  var wert: int64 := peek32(puf);
  if (wert >= 65536) { PrintLn("gesetzt"); } else { PrintLn(IntToStr(wert)); }
  return 0;
}'

# ===========================================================================
# #1610 — SMTP: Ueberlauf und Header-Injection
# ===========================================================================
# Der Repro aus dem Bericht: 6000 Zeichen, jede Zeile beginnt mit einem Punkt.
# Durch Dot-Stuffing werden daraus 9000 — der Puffer fasst 8192.
lauf "#1610: zu lange Nachricht wird abgelehnt statt ueberzulaufen" \
'0' 'import std.io;
import std.net.smtp;
fn main(): int64 {
  var n: int64 := 6000;
  var body: int64 := alloc(n + 1);
  var i: int64 := 0;
  while (i < n) {
    if (i % 2 == 0) { poke8(body + i, 46); } else { poke8(body + i, 10); }
    i := i + 1;
  }
  poke8(body + n, 0);
  var mail: SMTPEmail;
  mail.from := "a@b.c"c as int64;
  mail.toAddr := "d@e.f"c as int64;
  mail.subject := "x"c as int64;
  mail.body := body;
  PrintLn(IntToStr(SMTPBuildMessage(mail)));
  return 0;
}'

lauf "#1610: CR/LF in Betreff und Absender wird abgewiesen" \
'0
0' 'import std.io;
import std.net.smtp;
fn main(): int64 {
  var m: SMTPEmail;
  m.from := "a@b.c"c as int64;
  m.toAddr := "d@e.f"c as int64;
  m.subject := "hallo\r\nBcc: opfer@example.com"c as int64;
  m.body := "text"c as int64;
  PrintLn(IntToStr(SMTPBuildMessage(m)));
  var m2: SMTPEmail;
  m2.from := "a@b.c\nBcc: opfer@example.com"c as int64;
  m2.toAddr := "d@e.f"c as int64;
  m2.subject := "ok"c as int64;
  m2.body := "text"c as int64;
  PrintLn(IntToStr(SMTPBuildMessage(m2)));
  return 0;
}'

# Gegenprobe: die gesunde Nachricht wird weiterhin gebaut, mit korrektem
# Dot-Stuffing (aus ".punkt" wird "..punkt").
lauf "#1610: gesunde Nachricht entsteht weiterhin, mit Dot-Stuffing" \
'From: a@b.c
To: d@e.f
Subject: Test

..punktzeile
normal

.' 'import std.io;
import std.net.smtp;
fn main(): int64 {
  var m: SMTPEmail;
  m.from := "a@b.c"c as int64;
  m.toAddr := "d@e.f"c as int64;
  m.subject := "Test"c as int64;
  m.body := ".punktzeile\nnormal\n"c as int64;
  var msg: int64 := SMTPBuildMessage(m);
  if (msg == 0) { PrintLn("ABGELEHNT"); return 1; }
  PrintLn(msg as pchar);
  return 0;
}'

# ===========================================================================
# #1609 — NTP: Zuordnung der Antwort und die Rechnung
# ===========================================================================
# Synthetische Pakete: nur so laesst sich der Angriffsfall (gefaelschte
# Antwort mit falschem Origin-Stempel) ueberhaupt nachstellen.
lauf "#1609: Antwort mit fremdem Origin-Stempel wird abgewiesen" \
'-3' 'import std.io;
import std.net.ntp;
fn main(): int64 {
  var p: int64 := alloc(48);
  var i: int64 := 0;
  while (i < 48) { poke8(p + i, 0); i := i + 1; }
  poke8(p, 36);            // LI=0, VN=4, Mode=4 (Server)
  poke8(p + 1, 2);         // Stratum 2
  NTPWriteTS64(p, 24, 111111);   // Origin: NICHT unser Stempel
  NTPWriteTS64(p, 32, 222222);
  NTPWriteTS64(p, 40, 333333);
  var t: NTPTime := NTPParseResponse(p, 999999, 444444);
  PrintLn(IntToStr(t.status));
  return 0;
}'

lauf "#1609: Betriebsart und Kiss-o-Death werden abgewiesen" \
'-2
-4
-5' 'import std.io;
import std.net.ntp;
fn bau(erstesByte: int64, stratum: int64): int64 {
  var p: int64 := alloc(48);
  var i: int64 := 0;
  while (i < 48) { poke8(p + i, 0); i := i + 1; }
  poke8(p, erstesByte);
  poke8(p + 1, stratum);
  NTPWriteTS64(p, 24, 1000);
  NTPWriteTS64(p, 32, 2000);
  NTPWriteTS64(p, 40, 3000);
  return p;
}
fn main(): int64 {
  PrintLn(IntToStr(NTPParseResponse(bau(35, 2), 1000, 4000).status));   // Mode 3
  PrintLn(IntToStr(NTPParseResponse(bau(36, 0), 1000, 4000).status));   // Stratum 0
  PrintLn(IntToStr(NTPParseResponse(bau(228, 2), 1000, 4000).status));  // LI=3
  return 0;
}'

# Die Rechnung selbst, an Zahlen, die sich von Hand nachvollziehen lassen:
# T1=0s, T2=+2s, T3=+3s, T4=+4s  ->  delay = 4-0 - (3-2) = 3s = 3000ms
#                                    offset = ((2-0) + (3-4))/2 = 0.5s = 500ms
lauf "#1609: delay und offset werden wirklich gerechnet" \
'3000
500' 'import std.io;
import std.net.ntp;
fn main(): int64 {
  var p: int64 := alloc(48);
  var i: int64 := 0;
  while (i < 48) { poke8(p + i, 0); i := i + 1; }
  poke8(p, 36); poke8(p + 1, 2);
  var eins: int64 := 4294967296;          // 1 Sekunde als 32.32-Festkomma
  NTPWriteTS64(p, 24, 0);                 // Origin = T1
  NTPWriteTS64(p, 32, 2 * eins);          // T2
  NTPWriteTS64(p, 40, 3 * eins);          // T3
  var t: NTPTime := NTPParseResponse(p, 0, 4 * eins);
  PrintLn(IntToStr(t.delay));
  PrintLn(IntToStr(t.offset));
  return 0;
}'

# Und der Sendestempel steht wirklich im Paket — ohne ihn kann der Server
# nichts spiegeln und die Zuordnung oben liefe ins Leere.
lauf "#1609: die Anfrage traegt den eigenen Sendestempel" 'gesetzt' 'import std.io;
import std.net.ntp;
fn main(): int64 {
  var req: int64 := NTPBuildRequest();
  var ts: int64 := NTPReadTS64(req, 40);
  if (ts != 0) { PrintLn("gesetzt"); } else { PrintLn("NULL"); }
  return 0;
}'

# ===========================================================================
# #1604 — std.country: Tabelle vollstaendig und lesbar
# ===========================================================================
lauf "#1604: Abfragen stuerzen nicht mehr ab und liefern die richtigen Werte" \
'249
Germany
JPY
840
1
0' 'import std.io;
import std.country;
fn main(): int64 {
  PrintLn(IntToStr(CountryGetCount()));
  PrintLn(CountryGetName("DE"c));
  PrintLn(CountryGetCurrency("JP"c));
  PrintLn(IntToStr(CountryGetNumeric("US"c)));
  PrintLn(IntToStr(CountryIsValid("FJ"c)));
  PrintLn(IntToStr(CountryIsValid("XX"c)));
  return 0;
}'

# Eintraege aus dem hinteren Teil der Tabelle — die gab es vorher gar nicht.
lauf "#1604: auch die spaeten Eintraege sind da" \
'Tuvalu
716
Vanuatu
VUV' 'import std.io;
import std.country;
fn main(): int64 {
  PrintLn(CountryGetName("TV"c));
  PrintLn(IntToStr(CountryGetNumeric("ZW"c)));
  PrintLn(CountryGetName("VU"c));
  PrintLn(CountryGetCurrency("VU"c));
  return 0;
}'

lauf "#1604: Rueckwaertssuche ueber den Namen" 'JP' 'import std.io;
import std.country;
fn main(): int64 { PrintLn(CountryGetCode("Japan"c)); return 0; }'

echo
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
