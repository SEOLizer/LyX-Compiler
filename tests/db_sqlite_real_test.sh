#!/usr/bin/env bash
# tests/db_sqlite_real_test.sh — #1329.
#
# REAL-Werte gingen in beide Richtungen verloren: SQLiteBindFloat speicherte
# 0.0, SQLiteColumnFloat lieferte 0 — obwohl der Wert nachweislich in der
# Datenbank stand (SQL rechnete richtig damit). INTEGER und TEXT arbeiteten.
#
# URSACHE war nicht die Unit, sondern der Codegen: FFI-Aufrufe legten ALLE
# Argumente in die Ganzzahlregister, die SysV-ABI fuehrt Gleitkomma aber in
# xmm0..xmm7 (#1486). sqlite3 bekam das double nie zu sehen und gab seines
# nie zurueck.
#
# DER TEST BLEIBT, obwohl der Fix woanders sitzt: er misst die Strecke
# Lyx -> libsqlite3 -> Datei -> zurueck, die kein Compilertest abdeckt.
# Gegengelesen wird mit dem sqlite3-Client, wo vorhanden — nur der sagt, was
# wirklich auf der Platte steht.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="$ROOT/lyxc"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

if [ ! -e /lib/x86_64-linux-gnu/libsqlite3.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ]; then
  echo "SKIP libsqlite3.so.0 nicht gefunden"
  echo "--- 0 PASS, 0 FAIL"; exit 0
fi

# ===========================================================================
# Lesen: der Wert aus der Datenbank kommt als f64 an
# ===========================================================================

cat > "$TMP/r.lyx" <<'EOF'
import std.io;
import std.db.sqlite;
fn main(): int64 {
  var db: int64 := SQLiteOpen(":memory:"c);
  SQLiteExec(db, "CREATE TABLE t (f REAL)"c);
  SQLiteExec(db, "INSERT INTO t VALUES (1250.5)"c);
  var q: int64 := SQLiteStmtPrepare(db, "SELECT f, CAST(f*10 AS INTEGER) FROM t"c);
  if (SQLiteStmtStep(q) == SQLITE_ROW) {
    var fv: f64 := SQLiteColumnFloat(q, 0);
    PrintStr(IntToStr((fv * 10.0) as int64)); PrintStr(" ");
    PrintLn(IntToStr(SQLiteColumnInt(q, 1)));
  }
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/r.lyx" -o "$TMP/r" >/dev/null 2>&1; then
  got="$(timeout 30 "$TMP/r" 2>&1)"
  # Beide Zahlen muessen gleich sein: links ueber Lyx gerechnet, rechts vom
  # Server. Nur der Vergleich sagt, dass der Wert wirklich ankam.
  if [ "$got" = "12505 12505" ]; then ok "#1329: SQLiteColumnFloat liefert den gespeicherten REAL-Wert"
  else no "#1329: SQLiteColumnFloat liefert den gespeicherten REAL-Wert" "'$got' erwartet '12505 12505'"; fi
else
  no "#1329: SQLiteColumnFloat liefert den gespeicherten REAL-Wert" "uebersetzt nicht"
fi

# ===========================================================================
# Schreiben: gegen die Datei gegengelesen
# ===========================================================================

DBF="$TMP/t.db"
cat > "$TMP/w.lyx" <<EOF
import std.io;
import std.db.sqlite;
fn main(): int64 {
  var db: int64 := SQLiteOpen("$DBF"c);
  SQLiteExec(db, "CREATE TABLE kunden (name TEXT, umsatz REAL)"c);
  var st: int64 := SQLiteStmtPrepare(db, "INSERT INTO kunden VALUES (?, ?)"c);
  SQLiteBindStr(st, 1, "Meier GmbH"c);
  PrintBoolLn(SQLiteBindFloat(st, 2, 1250.5));
  SQLiteStmtStep(st);
  SQLiteStmtFinalize(st);
  SQLiteClose(db);
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/w.lyx" -o "$TMP/w" >/dev/null 2>&1 && timeout 30 "$TMP/w" >/dev/null 2>&1; then
  if command -v sqlite3 >/dev/null 2>&1; then
    ist="$(sqlite3 "$DBF" "SELECT name || '=' || umsatz FROM kunden" 2>&1)"
    if [ "$ist" = "Meier GmbH=1250.5" ]; then ok "#1329: SQLiteBindFloat schreibt den Wert in die Datei"
    else no "#1329: SQLiteBindFloat schreibt den Wert in die Datei" "'$ist'"; fi
  elif command -v python3 >/dev/null 2>&1; then
    ist="$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select name,umsatz from kunden').fetchall())" "$DBF" 2>&1)"
    if [ "$ist" = "[('Meier GmbH', 1250.5)]" ]; then ok "#1329: SQLiteBindFloat schreibt den Wert in die Datei"
    else no "#1329: SQLiteBindFloat schreibt den Wert in die Datei" "'$ist'"; fi
  else
    echo "SKIP weder sqlite3 noch python3 zum Gegenlesen"
  fi
else
  no "#1329: SQLiteBindFloat schreibt den Wert in die Datei" "laeuft nicht"
fi

# Gegenprobe: INTEGER und TEXT waren nie betroffen und bleiben es.
cat > "$TMP/g.lyx" <<'EOF'
import std.io;
import std.db.sqlite;
fn main(): int64 {
  var db: int64 := SQLiteOpen(":memory:"c);
  SQLiteExec(db, "CREATE TABLE t (i INTEGER, s TEXT)"c);
  var st: int64 := SQLiteStmtPrepare(db, "INSERT INTO t VALUES (?, ?)"c);
  SQLiteBindInt(st, 1, 4711);
  SQLiteBindStr(st, 2, "hallo"c);
  SQLiteStmtStep(st);
  SQLiteStmtFinalize(st);
  var q: int64 := SQLiteStmtPrepare(db, "SELECT i, s FROM t"c);
  if (SQLiteStmtStep(q) == SQLITE_ROW) {
    PrintStr(IntToStr(SQLiteColumnInt(q, 0))); PrintStr(" ");
    PrintLn(SQLiteColumnText(q, 1));
  }
  return 0;
}
EOF
if "$LYXC" --std-path="$ROOT" "$TMP/g.lyx" -o "$TMP/g" >/dev/null 2>&1; then
  got="$(timeout 30 "$TMP/g" 2>&1)"
  if [ "$got" = "4711 hallo" ]; then ok "#1329: INTEGER und TEXT unveraendert"
  else no "#1329: INTEGER und TEXT unveraendert" "'$got'"; fi
else
  no "#1329: INTEGER und TEXT unveraendert" "uebersetzt nicht"
fi

echo "--- $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
