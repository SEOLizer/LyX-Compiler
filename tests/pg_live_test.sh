#!/usr/bin/env bash
# tests/pg_live_test.sh — std.db.postgres gegen einen ECHTEN Server: #2087
# (PGBind* stuerzte ab), #2090 (Binaerparameter, BYTEA) und #2089
# (SCRAM-SHA-256).
#
# Die Tests pg_01..pg_11 sprechen fest localhost:5432 als `postgres` ohne
# Passwort an und melden sonst SKIP. Auf einem Rechner mit SCRAM (dem
# PostgreSQL-Standard seit 14) liefen ihre Live-Teile deshalb NIE — genau so
# blieb #2087 unbemerkt: jedes PGBind* auf einem frischen Statement stuerzte
# ab, weil eine lokale Variable `alloc` die Funktion alloc() verdeckte.
#
# Dieser Test legt sich deshalb seinen eigenen Wegwerf-Cluster an (initdb,
# nur 127.0.0.1, freier Port, Zufallspasswoerter) und raeumt ihn wieder ab.
# Fehlt PostgreSQL ganz, ist das ROT ("NICHT gemessen"), nicht gruen — wie bei
# qemu.
#
# Die Faelle, die einen Server brauchen, der sich FALSCH verhaelt
# (manipulierte Serversignatur, AuthenticationOk ohne Signatur), spielt ein
# kleiner Python-Server nach.
set -uo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"
TMP="$(mktemp -d /tmp/lyxpg.XXXXXX)"   # kurzer Pfad: Unix-Socket-Pfade sind auf 107 Byte begrenzt
PASS=0; FAIL=0
ok()  { echo "PASS $1"; PASS=$((PASS+1)); }
nok() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

PGBIN=""
for d in /usr/lib/postgresql/*/bin; do [ -x "$d/initdb" ] && PGBIN="$d"; done
[ -z "$PGBIN" ] && command -v initdb >/dev/null 2>&1 && PGBIN="$(dirname "$(command -v initdb)")"

aufraeumen() {
  [ -n "$PGBIN" ] && [ -d "$TMP/data" ] && "$PGBIN/pg_ctl" -D "$TMP/data" -m immediate stop >/dev/null 2>&1
  [ -n "${KEEP_PGLOG:-}" ] && cp "$TMP/pg.log" "$KEEP_PGLOG" 2>/dev/null
  [ -n "${FAKEPID:-}" ] && kill "$FAKEPID" 2>/dev/null
  rm -rf "$TMP"
}
trap aufraeumen EXIT

bauen() {  # $1 Quelle, $2 Ausgabe
  ( cd "$ROOT" && timeout 300 "$LYXC" --std-path="$ROOT" "$1" -o "$2" ) >"$TMP/bau.log" 2>&1
}

echo "--- #2089: SCRAM-Rechnung am Testvektor aus RFC 7677, Abschnitt 3 (offline) ---"
cat > "$TMP/rfc.lyx" <<'EOF'
import std.db.postgres;
fn main(): int64 {
  var sig: int64 := alloc(8);
  var cf: pchar := PGScramClientFinal("pencil"c, "n=user,r=rOprNGfwEbeRWgbNEkqO"c,
    "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"c, sig);
  PrintStr(cf); PrintStr("\n"); PrintStr(peek64(sig) as pchar); PrintStr("\n");
  // fremde Nonce: muss abgewiesen werden
  var fremd: pchar := PGScramClientFinal("pencil"c, "n=user,r=rOprNGfwEbeRWgbNEkqO"c,
    "r=ANDERE_NONCE_xyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"c, sig);
  if (fremd == 0 as pchar) { PrintStr("fremd=abgewiesen\n"); } else { PrintStr("fremd=angenommen\n"); }
  // Nicht-ASCII-Passwort: SASLprep fehlt — abweisen statt falsch rechnen
  var nonascii: pchar := PGScramClientFinal("p\xc3\xa4ss"c, "n=user,r=rOprNGfwEbeRWgbNEkqO"c,
    "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"c, sig);
  if (nonascii == 0 as pchar) { PrintStr("nonascii=abgewiesen\n"); } else { PrintStr("nonascii=angenommen\n"); }
  return 0;
}
EOF
if bauen "$TMP/rfc.lyx" "$TMP/rfc"; then
  aus="$(timeout 60 "$TMP/rfc" | tr '\n' '|')"
  soll='c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=|6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=|fremd=abgewiesen|nonascii=abgewiesen|'
  if [ "$aus" = "$soll" ]; then ok "ClientProof und ServerSignature wie RFC 7677; fremde Nonce und Nicht-ASCII abgewiesen"
  else nok "RFC 7677: [$aus] statt [$soll]"; fi
else nok "RFC-Test uebersetzt nicht: $(grep -m1 -i error "$TMP/bau.log")"; fi

echo
echo "--- Wegwerf-Cluster ---"
if [ -z "$PGBIN" ]; then
  nok "PostgreSQL (initdb) fehlt — die Live-Faelle wurden NICHT gemessen"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
PORT=$(( 20000 + RANDOM % 20000 ))
PW_SCRAM="s$RANDOM$RANDOM"; PW_MD5="m$RANDOM$RANDOM"; PW_HOCH="h$RANDOM$RANDOM"
echo "$PW_SCRAM" > "$TMP/pw"
if ! "$PGBIN/initdb" -D "$TMP/data" -U lyxtest --auth=scram-sha-256 --pwfile="$TMP/pw" -E UTF8 >"$TMP/initdb.log" 2>&1; then
  nok "initdb scheitert: $(tail -1 "$TMP/initdb.log")"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
# md5-Rolle VOR den scram-Zeilen erlauben
sed -i '0,/^local   all/s//host    all             lyxmd5          127.0.0.1\/32            md5\nlocal   all/' "$TMP/data/pg_hba.conf"
if ! "$PGBIN/pg_ctl" -D "$TMP/data" -o "-p $PORT -c unix_socket_directories='' -c listen_addresses=127.0.0.1" -l "$TMP/pg.log" -w start >/dev/null 2>&1; then
  nok "Cluster startet nicht: $(tail -1 "$TMP/pg.log")"
  echo; echo "Ergebnis: $PASS PASS, $FAIL FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
PSQL="$PGBIN/psql"; [ -x "$PSQL" ] || PSQL=psql
# Jede Anweisung ein eigenes -c: mehrere in EINEM -c laufen als eine
# Transaktion, und CREATE DATABASE darf nicht darin stehen.
PGPASSWORD="$PW_SCRAM" "$PSQL" -h 127.0.0.1 -p "$PORT" -U lyxtest -d postgres -q -v ON_ERROR_STOP=1 \
  -c "create database nexus" \
  -c "set password_encryption = 'md5'; create role lyxmd5 login password '$PW_MD5'" \
  -c "reset password_encryption; set scram_iterations = 15000; create role lyxhoch login password '$PW_HOCH'" \
  -c "alter database nexus owner to lyxmd5" \
  -c "grant connect on database nexus to lyxhoch" >"$TMP/psql.log" 2>&1 \
  || nok "Rollen anlegen: $(head -1 "$TMP/psql.log")"
ok "eigener Cluster auf 127.0.0.1:$PORT ($("$PGBIN/postgres" --version | awk '{print $3}'))"

echo
echo "--- #2087/#2090: Binden ueber md5 — jeder Typ, BYTEA mit Nullbytes, neun Parameter ---"
cat > "$TMP/bind.lyx" <<EOF
import std.db.postgres;
fn zeige(v: pchar) { if (v == 0 as pchar) { PrintStr("NULL"); } else { PrintStr(v); } PrintStr("|"); }
fn main(): int64 {
  var conn: int64 := PGConnect("127.0.0.1"c, $PORT, "lyxmd5"c, "$PW_MD5"c, "nexus"c);
  if (PGIsConnected(conn) == 0) { PrintStr("connect:"); PrintStr(PGErrorMessage(conn)); return 1; }
  var st: int64 := PGStmtPrepare(conn, "q1"c, "SELECT \$1::int + 1, \$2::text || '!', \$3::float8 * 2, \$4::bool, \$5::text IS NULL"c);
  PGStmtReset(st);
  PGBindInt(st, 0, 41); PGBindStr(st, 1, "hallo"c); PGBindFloat(st, 2, 1.25); PGBindBool(st, 3, 1); PGBindNull(st, 4);
  var r: int64 := PGStmtExecute(conn, st);
  if (r == 0) { PrintStr("execute:"); PrintStr(PGErrorMessage(conn)); return 2; }
  PGFetchRow(r); zeige(PGGetStr(r, 0)); zeige(PGGetStr(r, 1)); zeige(PGGetStr(r, 2)); zeige(PGGetStr(r, 3)); zeige(PGGetStr(r, 4));
  PGFreeResult(r);
  var raw: int64 := alloc(5);
  poke8(raw, 0); poke8(raw + 1, 65); poke8(raw + 2, 255); poke8(raw + 3, 0); poke8(raw + 4, 7);
  var st2: int64 := PGStmtPrepare(conn, "q2"c, "SELECT \$1::bytea, length(\$1::bytea), \$2::text"c);
  PGStmtReset(st2);
  PGBindBytes(st2, 0, raw, 5);
  PGBindStr(st2, 1, "neben"c);          // Text- und Binaerparameter in EINER Nachricht
  var r2: int64 := PGStmtExecute(conn, st2);
  if (r2 == 0) { PrintStr("bytea:"); PrintStr(PGErrorMessage(conn)); return 3; }
  PGFetchRow(r2); zeige(PGGetStr(r2, 0)); zeige(PGGetStr(r2, 1)); zeige(PGGetStr(r2, 2));
  var nl: int64 := alloc(8);
  var back: int64 := PGGetBytes(r2, 0, nl);
  var i: int64 := 0;
  while (i < peek64(nl)) { PrintInt(peek8(back + i) & 255); PrintStr(","); i := i + 1; }
  PrintStr("|");
  PGFreeResult(r2);
  var st3: int64 := PGStmtPrepare(conn, "q3"c, "SELECT \$1::int+\$2::int+\$3::int+\$4::int+\$5::int+\$6::int+\$7::int+\$8::int+\$9::int"c);
  PGStmtReset(st3);
  var k: int64 := 0;
  while (k < 9) { PGBindInt(st3, k, k + 1); k := k + 1; }
  var r3: int64 := PGStmtExecute(conn, st3);
  PGFetchRow(r3); zeige(PGGetStr(r3, 0)); PGFreeResult(r3);
  // dasselbe Statement erneut, Slot 0 jetzt mit einem anderen Wert (Re-Bind)
  PGStmtReset(st3);
  k := 0;
  while (k < 9) { PGBindInt(st3, k, 10); k := k + 1; }
  var r4: int64 := PGStmtExecute(conn, st3);
  PGFetchRow(r4); zeige(PGGetStr(r4, 0)); PGFreeResult(r4);
  PGStmtFree(st); PGStmtFree(st2); PGStmtFree(st3);
  PGClose(conn);
  return 0;
}
EOF
if bauen "$TMP/bind.lyx" "$TMP/bind"; then
  aus="$(timeout 60 "$TMP/bind" 2>&1 | tr '\n' ' ')"; rc=$?
  soll='42|hallo!|2.5|t|t|\x0041ff0007|5|neben|0,65,255,0,7,|45|90|'
  if [ "$aus" = "$soll" ]; then ok "Int/Text/Float/Bool/NULL, BYTEA binaer hin und zurueck, 9 Parameter, Re-Bind"
  else nok "Binden: [$aus] statt [$soll]"; fi
else nok "Bind-Test uebersetzt nicht: $(grep -m1 -i error "$TMP/bau.log")"; fi

echo
echo "--- #2089: SCRAM-SHA-256 gegen den Server ---"
cat > "$TMP/scram.lyx" <<EOF
import std.db.postgres;
fn probe(user: pchar, pw: pchar) {
  var c: int64 := PGConnect("127.0.0.1"c, $PORT, user, pw, "nexus"c);
  PrintInt(PGIsConnected(c)); PrintStr(":");
  if (PGIsConnected(c) != 0) {
    var r: int64 := PGQuery(c, "SELECT current_user"c);
    PGFetchRow(r); PrintStr(PGGetStr(r, 0)); PGFreeResult(r); PGClose(c);
  } else {
    PrintInt(PGErrno(c)); PrintStr(":"); PrintStr(PGError(c)); PrintStr(":"); PrintStr(PGErrorMessage(c));
  }
  PrintStr("|");
}
fn main(): int64 {
  probe("lyxtest"c, "$PW_SCRAM"c);    // 4096 Runden (Standard)
  probe("lyxhoch"c, "$PW_HOCH"c);     // 15000 Runden
  probe("lyxtest"c, "falsch"c);       // falsches Passwort
  return 0;
}
EOF
if bauen "$TMP/scram.lyx" "$TMP/scram"; then
  aus="$(timeout 120 "$TMP/scram" 2>&1)"
  case "$aus" in
    "1:lyxtest|1:lyxhoch|0:3006:28P01:password authentication failed for user \"lyxtest\"|")
      ok "SCRAM: 4096 und 15000 Runden verbinden; falsches Passwort → 28P01 samt Klartext" ;;
    *) nok "SCRAM: [$aus]" ;;
  esac
else nok "SCRAM-Test uebersetzt nicht: $(grep -m1 -i error "$TMP/bau.log")"; fi

echo
echo "--- #2089: ein Server, der FALSCH antwortet, wird abgewiesen ---"
# Spielt AuthenticationSASL/SASLContinue nach und antwortet dann je nach Modus:
#   falsch — SASLFinal mit einer falschen Signatur
#   ohne   — AuthenticationOk, ohne SASLFinal (Signatur nie gezeigt)
if command -v python3 >/dev/null 2>&1; then
cat > "$TMP/fake.py" <<'PY'
import socket, struct, sys
modus, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1)
print("bereit", flush=True)
c, _ = s.accept()
def recv_exact(n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d: raise SystemExit
        b += d
    return b
l = struct.unpack("!I", recv_exact(4))[0]; recv_exact(l - 4)                 # StartupMessage
def send(t, data): c.sendall(t + struct.pack("!I", len(data) + 4) + data)
send(b"R", struct.pack("!I", 10) + b"SCRAM-SHA-256\0\0")
t = recv_exact(1); l = struct.unpack("!I", recv_exact(4))[0]; d = recv_exact(l - 4)
mech_end = d.index(b"\0"); ilen = struct.unpack("!I", d[mech_end+1:mech_end+5])[0]
cfirst = d[mech_end+5:mech_end+5+ilen].decode()
cnonce = cfirst.split("r=", 1)[1]
send(b"R", struct.pack("!I", 11) + ("r=%sSRV,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096" % cnonce).encode())
t = recv_exact(1); l = struct.unpack("!I", recv_exact(4))[0]; recv_exact(l - 4)  # client-final
if modus == "falsch":
    send(b"R", struct.pack("!I", 12) + b"v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
send(b"R", struct.pack("!I", 0))
send(b"Z", b"I")
try: c.recv(16)
except Exception: pass
PY
  for modus in falsch ohne; do
    FPORT=$(( 40000 + RANDOM % 20000 ))
    python3 "$TMP/fake.py" "$modus" "$FPORT" > "$TMP/fake.out" 2>&1 & FAKEPID=$!
    for _ in $(seq 1 50); do grep -q bereit "$TMP/fake.out" 2>/dev/null && break; sleep 0.2; done
    cat > "$TMP/fake.lyx" <<EOF
import std.db.postgres;
fn main(): int64 {
  var c: int64 := PGConnect("127.0.0.1"c, $FPORT, "u"c, "pencil"c, "d"c);
  PrintInt(PGIsConnected(c)); PrintStr(":"); PrintInt(PGErrno(c)); PrintStr(":"); PrintStr(PGError(c));
  return 0;
}
EOF
    if bauen "$TMP/fake.lyx" "$TMP/fake"; then
      aus="$(timeout 60 "$TMP/fake" 2>&1)"
      case "$modus:$aus" in
        "falsch:0:3007:SCRAM: Serversignatur stimmt nicht"*) ok "manipulierte Serversignatur → abgebrochen (3007)" ;;
        "ohne:0:3007:SCRAM: AuthenticationOk ohne Serversignatur"*) ok "AuthenticationOk ohne Signatur → abgebrochen (3007)" ;;
        *) nok "Fake-Server ($modus): [$aus]" ;;
      esac
    else nok "Fake-Test uebersetzt nicht: $(grep -m1 -i error "$TMP/bau.log")"; fi
    kill "$FAKEPID" 2>/dev/null; wait "$FAKEPID" 2>/dev/null; FAKEPID=""
  done
else
  nok "python3 fehlt — die Faelle mit falsch antwortendem Server wurden NICHT gemessen"
fi

echo
echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
