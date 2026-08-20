#!/usr/bin/env bash
# tests/db_mysql_prepared_test.sh — #1332 (gegen MariaDB 10.11 gemessen).
#
# Drei Befunde, alle in std/db/mysql.lyx:
#
#   1. COM_STMT_PREPARE und COM_STMT_EXECUTE wurden ab Puffer+1 gesendet — das
#      KOMMANDOBYTE fiel vorn heraus. Der Server las ein Laengenbyte als
#      Kommando ("#08S01 Unknown command") bzw. die halbe stmt_id
#      ("#42000 Incorrect database name ''"). Gegen MySQL/MariaDB gab es damit
#      keinen Weg, Werte gebunden zu uebergeben — und damit keinen Schutz vor
#      SQL-Injection ausser eigenem Pruefen.
#      Dazu stand new_params_bound_flag auf 0 ("die Typen von vorhin gelten"),
#      obwohl es nie ein Vorhin gab; die Typtabelle fehlte ganz.
#   2. MySQLGetFieldName/Type/Length gaben fest "" bzw. 0 zurueck — die
#      gelesenen Spaltendefinitionen wurden sofort weggeworfen.
#   3. conn.error_num blieb ueber Aufrufe hinweg stehen; Begin/Commit/Rollback
#      urteilen danach und meldeten false, obwohl die Transaktion lief.
#
# GEPRUEFT WIRD GEGEN EINEN ECHTEN SERVER und, wo moeglich, mit dem
# mysql-Client gegengelesen: nur der sagt, ob wirklich etwas in der Tabelle
# steht. Ohne Server wird uebersprungen — ein Test gegen eine Attrappe haette
# genau den Protokollfehler nicht gesehen, um den es hier geht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

HOST="${LYX_MYSQL_HOST:-127.0.0.1}"
PORT="${LYX_MYSQL_PORT:-3306}"
USER="${LYX_MYSQL_USER:-lyx}"
PASSWORT="${LYX_MYSQL_PASS:-test12345}"
DB="${LYX_MYSQL_DB:-lyx}"
TAB="lyx_t1332"

if ! command -v mysql >/dev/null 2>&1; then
  echo "SKIP kein mysql-Client — ohne Gegenlesen sagt der Test zu wenig"
  echo "--- 0 PASS, 0 FAIL"; exit 0
fi
if ! mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASSWORT" "$DB" -e "SELECT 1" >/dev/null 2>&1; then
  echo "SKIP kein MySQL/MariaDB auf $HOST:$PORT als $USER erreichbar"
  echo "--- 0 PASS, 0 FAIL"; exit 0
fi

sql() { mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$PASSWORT" "$DB" -N -B -e "$1" 2>/dev/null; }
sql "DROP TABLE IF EXISTS $TAB;
     CREATE TABLE $TAB (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(64), umsatz_cent BIGINT)"

cat > "$TMP/m.lyx" <<EOF
import std.io;
import std.db.mysql;
fn main(): int64 {
  var conn: MySQLConn := MySQLConnect("$HOST"c, $PORT, "$USER"c, "$PASSWORT"c, "$DB"c);
  if (conn.fd < 0) { PrintLn("keine Verbindung"); return 1; }

  var st: MySQLStmt := MySQLStmtPrepare(conn, "INSERT INTO $TAB (name, umsatz_cent) VALUES (?, ?)"c);
  PrintStr("params="); PrintLn(IntToStr(st.param_count));
  PrintStr("id>0="); PrintBoolLn(st.stmt_id > 0);

  MySQLStmtBindStr(st, 0, "Eins GmbH"c);
  MySQLStmtBindInt(st, 1, 555);
  MySQLStmtExecute(conn, st);
  MySQLStmtBindStr(st, 0, "Zwei AG"c);
  MySQLStmtBindNull(st, 1, true);
  MySQLStmtExecute(conn, st);
  PrintStr("fehler=["); PrintStr(MySQLError(conn)); PrintLn("]");

  var q: MySQLResult := MySQLQuery(conn, "SELECT id, name, umsatz_cent FROM $TAB ORDER BY id"c);
  PrintStr("felder=");
  var i: int64 := 0;
  while (i < MySQLNumFields(q)) {
    PrintStr(MySQLGetFieldName(q, i));
    PrintStr(":"); PrintStr(IntToStr(MySQLGetFieldType(q, i)));
    PrintStr(" ");
    i := i + 1;
  }
  PrintLn("");

  PrintStr("begin="); PrintBoolLn(MySQLBegin(conn));
  PrintStr("rollback="); PrintBoolLn(MySQLRollback(conn));
  MySQLClose(conn);
  return 0;
}
EOF

if ! "$LYXC" --std-path="$ROOT" "$TMP/m.lyx" -o "$TMP/m" >/dev/null 2>&1; then
  no "#1332: Prepared Statements gegen MariaDB" "uebersetzt nicht: $("$LYXC" --std-path="$ROOT" "$TMP/m.lyx" -o "$TMP/m" 2>&1 | grep -i error | head -1)"
  echo "--- $PASS PASS, $FAIL FAIL"; exit 1
fi

got="$(timeout 60 "$TMP/m" 2>&1)"; rc=$?
if [ "$rc" -ge 128 ]; then
  no "#1332: Prepared Statements gegen MariaDB" "ABSTURZ (rc=$rc)"
else
  # 1) Prepare meldet die Parameter des Servers
  if printf '%s' "$got" | grep -q "^params=2$" && printf '%s' "$got" | grep -q "^id>0=true$"; then
    ok "#1332: COM_STMT_PREPARE kommt an (stmt_id und param_count vom Server)"
  else
    no "#1332: COM_STMT_PREPARE kommt an (stmt_id und param_count vom Server)" "$(printf '%s' "$got" | head -3 | tr '\n' ' ')"
  fi

  # 2) Kein Fehlertext
  if printf '%s' "$got" | grep -q "^fehler=\[\]$"; then
    ok "#1332: COM_STMT_EXECUTE ohne Serverfehler"
  else
    no "#1332: COM_STMT_EXECUTE ohne Serverfehler" "$(printf '%s' "$got" | grep '^fehler=')"
  fi

  # 3) Der Server hat die Werte wirklich — von aussen gegengelesen
  ist="$(sql "SELECT name, IFNULL(umsatz_cent,'NULL') FROM $TAB ORDER BY id" | tr '\t\n' ' :')"
  if [ "$ist" = "Eins GmbH 555:Zwei AG NULL:" ]; then
    ok "#1332: die gebundenen Werte stehen in der Tabelle (inkl. NULL)"
  else
    no "#1332: die gebundenen Werte stehen in der Tabelle (inkl. NULL)" "'$ist'"
  fi

  # 4) Feld-Metadaten. 3 = LONG, 253 = VAR_STRING, 8 = LONGLONG.
  if printf '%s' "$got" | grep -q "^felder=id:3 name:253 umsatz_cent:8 $"; then
    ok "#1332: Spaltennamen und -typen statt leerer Huellen"
  else
    no "#1332: Spaltennamen und -typen statt leerer Huellen" "$(printf '%s' "$got" | grep '^felder=')"
  fi

  # 5) Transaktionen melden, was sie tun
  if printf '%s' "$got" | grep -q "^begin=true$" && printf '%s' "$got" | grep -q "^rollback=true$"; then
    ok "#1332: Begin und Rollback melden Erfolg"
  else
    no "#1332: Begin und Rollback melden Erfolg" "$(printf '%s' "$got" | grep -E '^(begin|rollback)=')"
  fi
fi

# Gegenprobe: ein Wert mit Anfuehrungszeichen geht gebunden durch, ohne dass
# jemand ihn maskiert — das ist der Sinn der Sache.
cat > "$TMP/i.lyx" <<EOF
import std.io;
import std.db.mysql;
fn main(): int64 {
  var conn: MySQLConn := MySQLConnect("$HOST"c, $PORT, "$USER"c, "$PASSWORT"c, "$DB"c);
  if (conn.fd < 0) { return 1; }
  var st: MySQLStmt := MySQLStmtPrepare(conn, "INSERT INTO $TAB (name, umsatz_cent) VALUES (?, ?)"c);
  MySQLStmtBindStr(st, 0, "O'Brien\"; DROP TABLE x; --"c);
  MySQLStmtBindInt(st, 1, 1);
  MySQLStmtExecute(conn, st);
  MySQLClose(conn);
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/i.lyx" -o "$TMP/i" >/dev/null 2>&1 && timeout 60 "$TMP/i" >/dev/null 2>&1; then
  ist="$(sql "SELECT name FROM $TAB WHERE umsatz_cent = 1")"
  if [ "$ist" = "O'Brien\"; DROP TABLE x; --" ]; then
    ok "#1332: Sonderzeichen kommen gebunden unveraendert an"
  else
    no "#1332: Sonderzeichen kommen gebunden unveraendert an" "'$ist'"
  fi
else
  no "#1332: Sonderzeichen kommen gebunden unveraendert an" "laeuft nicht"
fi

sql "DROP TABLE IF EXISTS $TAB"
echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
