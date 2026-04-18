# MariaDB/MySQL Implementation Plan für Lyx

## Übersicht

Es soll eine neue Unit `std/db/mysql.lyx` erstellt werden, die das MySQL/MariaDB Wire Protocol (MySQL 5.7+ / MariaDB 10.x) implementiert.

Der Plan enthält folgende Arbeitspakete (WPs):

---

## WP 1: Grundstruktur & Typ-Definitionen

**Beschreibung:**
- Erstellung der Unit-Datei mit Importen
- Definition der MySQL-spezifischen Konstanten (Capability Flags, Status Flags, Commands)
- Definition der core-Typen: `MySQLConn`, `MySQLResult`, `MySQLRow`, `MySQLField`, `MySQLStmt`
- Connection-Pool-Typ: `MySQLPool`

**Konstanten:**

```
Capability Flags:
- CLIENT_LONG_PASSWORD (1)
- CLIENT_FOUND_ROWS (2) 
- CLIENT_LONG_FLAG (4)
- CLIENT_CONNECT_WITH_DB (8)
- CLIENT_PROTOCOL_41 (512)
- CLIENT_TRANSACTIONS (8192)
- CLIENT_SECURE_CONNECTION (32768)
- CLIENT_MULTI_STATEMENTS (65536)
- CLIENT_MULTI_RESULTS (131072)
- CLIENT_PLUGIN_AUTH (524288)

Server Status:
- SERVER_STATUS_IN_TRANSACTION (1)
- SERVER_STATUS_AUTOCOMMIT (2)
```

**Typen:**

```lyx
pub type MySQLConn = struct {
    fd:         int64;
    host:       pchar;
    port:       int64;
    user:       pchar;
    password:   pchar;
    database:   pchar;
    packet_num: int64;
    server_ver: int64;    // mmap'd buffer für version string
    cap_flags:  int64;
    charset:    int64;
    status:     int64;    // SERVER_STATUS_*
};

pub type MySQLResult = struct {
    field_count:  int64;
    affected_rows: int64;
    insert_id:    int64;
    server_status: int64;
    warning_count: int64;
    fields:       int64;  // mmap'd array of MySQLField
    field_count_alloc: int64;
    rows:         int64;  // mmap'd array of MySQLRow
    row_count:    int64;
};

pub type MySQLField = struct {
    catalog: pchar;
    db:      pchar;
    table:   pchar;
    org_table: pchar;
    name:    pchar;
    org_name: pchar;
    charset: int64;
    length:  int64;
    type:    int64;
    flags:   int64;
    decimals: int64;
    default_val: pchar;
};

pub type MySQLRow = struct {
    values: int64;     // mmap'd array of pchar
    lengths: int64;    // mmap'd array of int64
    count:   int64;
};

pub type MySQLPool = struct {
    connections: int64;  // array of MySQLConn
    size:        int64;
    max_size:    int64;
    timeout_ms:  int64;
    host:       pchar;
    port:       int64;
    user:       pchar;
    password:   pchar;
    database:   pchar;
};
```

**Abhängigkeiten:** Nur `std.net.types`, `std.net.syscalls`, `std.string`

---

## WP 2: Packet-Handling (Lesen/Schreiben)

**Beschreibung:**
- Implementierung der Low-Level Packet-Funktionen
- MySQL-Packet-Format: `[payload_len:3][seq:1][payload:N]`

**Funktionen:**

```lyx
// Sende MySQL-Packet mit Payload
pub fn mysqlSendPacket(conn: MySQLConn, data: int64, len: int64): bool

// Empfange ein MySQL-Packet (gibt Payload-Ptr, Länge, seq_id)
// Payload wird in mmap'd buffer geschrieben
pub fn mysqlReadPacket(conn: MySQLConn, outLen: int64, outSeq: int64): int64

// Empfange alle Daten eines Multi-Packet-Responses
pub fn mysqlReadPacketAll(conn: MySQLConn, totalLen: int64): int64
```

**Spezifikation:**
- Payload max. 16MB (2^24-1) pro Packet
- Bei größeren Daten: Multi-Packet (packet number continuation)
- Little-Endian für Length (3 bytes), Sequence-ID inkrementiert

---

## WP 3: Connection & Handshake

**Beschreibung:**
- TCP-Verbindung zum MySQL-Server
- Verarbeitung des HandshakeV10-Pakets
- Senden der HandshakeResponse41

**Funktionen:**

```lyx
pub fn MySQLConnect(host: pchar, port: int64, user: pchar, password: pchar, db: pchar): MySQLConn
pub fn MySQLClose(conn: MySQLConn): void
```

**Ablauf:**
1. TCP-Socket erstellen (AF_INET, SOCK_STREAM)
2. `connect()` zum Server
3. HandshakeV10 empfangen und parsen:
   - Protocol version (muss 10 sein)
   - Server version string
   - Thread ID
   - Auth plugin data (scramble buffer)
   - Capability flags
   - Character set
   - Server status
   - Auth plugin name
4. HandshakeResponse41 senden:
   - Client capabilities (mit MYSQL_NATIVE_PASSWORD für Kompatibilität)
   - Max packet size (16MB)
   - Character set (utf8mb4)
   - Username
   - Auth response (SHA1 scramble)
   - Database (optional)
5. OK/Error-Paket empfangen und Status prüfen

---

## WP 4: Authentifizierung (mysql_native_password)

**Beschreibung:**
- Implementierung des Classic MySQL Authentication (SHA1 scramble)
- Dies ist das einfachste Auth-Schema und kompatibel mit fast allen Servern

**Scramble-Algorithmus:**

```
1. server_scramble = first 20 bytes from handshake
2. password_hash = SHA1(password)
3. double_hash = SHA1(password_hash)
4. scramble = SHA1(server_scramble + double_hash) XOR password_hash
```

**Funktionen:**

```lyx
// Berechne SHA1 von Daten (benötigt crypto/sha1 oder eigene Implementierung)
fn sha1(data: int64, len: int64): int64

// Erstelle Auth-Response für mysql_native_password
fn buildNativeAuthResponse(password: pchar, scramble: int64): int64
```

---

## WP 5: Query-Ausführung

**Beschreibung:**
- Senden von COM_QUERY Command
- Empfangen und Parsen der Result-Sets

**Funktionen:**

```lyx
pub fn MySQLQuery(conn: MySQLConn, sql: pchar): MySQLResult
pub fn MySQLQueryStr(conn: MySQLConn, sql: pchar): int64  // für string return
pub fn MySQLAffectedRows(conn: MySQLConn): int64
pub fn MySQLInsertId(conn: MySQLConn): int64
pub fn MySQLError(conn: MySQLConn): pchar
pub fn MySQLErrno(conn: MySQLConn): int64
```

**Response-Typen:**

- **OK Packet**: `affected_rows, insert_id, server_status, warning_count, message`
- **Error Packet**: `error_code, sql_state, error_message`
- **Result Set**: `field_count, fields[], rows[], eof_status`

**Result-Set-Parsing:**
1. Column Count Packet (length-encoded integer)
2. Für jede Spalte: Field Definition Packet
3. Für jede Zeile: Row Data Packet(s)
4. EOF/OK Packet

---

## WP 6: Result-Set-Verarbeitung

**Beschreibung:**
- Hilfsfunktionen für den Zugriff auf Query-Ergebnisse
- Konvertierung zwischen MySQL-Typen und Lyx-Typen

**Funktionen:**

```lyx
pub fn MySQLFetchRow(result: MySQLResult): MySQLRow
pub fn MySQLFreeResult(result: MySQLResult): void
pub fn MySQLNumFields(result: MySQLResult): int64
pub fn MySQLNumRows(result: MySQLResult): int64
pub fn MySQLGetField(result: MySQLResult, idx: int64): MySQLField
pub fn MySQLGetRowField(row: MySQLRow, idx: int64): pchar
pub fn MySQLGetRowFieldLen(row: MySQLRow, idx: int64): int64
pub fn MySQLIsNull(row: MySQLRow, idx: int64): bool
```

**MySQL-Typen (Field Type Codes):**

```
MYSQL_TYPE_DECIMAL = 0
MYSQL_TYPE_TINY = 1
MYSQL_TYPE_SHORT = 2
MYSQL_TYPE_LONG = 3
MYSQL_TYPE_FLOAT = 4
MYSQL_TYPE_DOUBLE = 5
MYSQL_TYPE_NULL = 6
MYSQL_TYPE_TIMESTAMP = 7
MYSQL_TYPE_LONGLONG = 8
MYSQL_TYPE_INT24 = 9
MYSQL_TYPE_DATE = 10
MYSQL_TYPE_TIME = 11
MYSQL_TYPE_DATETIME = 12
MYSQL_TYPE_YEAR = 13
MYSQL_TYPE_VARCHAR = 15
MYSQL_TYPE_BIT = 16
MYSQL_TYPE_NEWDECIMAL = 246
MYSQL_TYPE_ENUM = 247
MYSQL_TYPE_SET = 248
MYSQL_TYPE_TINY_BLOB = 249
MYSQL_TYPE_MEDIUM_BLOB = 250
MYSQL_TYPE_LONG_BLOB = 251
MYSQL_TYPE_BLOB = 252
MYSQL_TYPE_VARSTRING = 253
MYSQL_TYPE_STRING = 254
MYSQL_TYPE_GEOMETRY = 255
```

---

## WP 7: Prepared Statements

**Beschreibung:**
- Implementierung des Binary Protocol für Prepared Statements
- Parameter-Binding und Result-Set-Handling

**Funktionen:**

```lyx
pub fn MySQLStmtPrepare(conn: MySQLConn, sql: pchar): MySQLStmt
pub fn MySQLStmtExecute(conn: MySQLConn, stmt: MySQLStmt): MySQLResult
pub fn MySQLStmtBindParam(stmt: MySQLStmt, paramIdx: int64, type: int64, value: int64): bool
pub fn MySQLStmtBindResult(stmt: MySQLStmt, idx: int64, type: int64, buffer: int64): bool
pub fn MySQLStmtFetch(stmt: MySQLStmt): int64  // returns row count
pub fn MySQLStmtClose(stmt: MySQLStmt): void
pub fn MySQLStmtReset(conn: MySQLConn, stmt: MySQLStmt): void
```

**Binary Protocol Packet Layout:**
- COM_STMT_PREPARE_OK: `statement_id, column_count, param_count, warning_count`
- Parameter-Bound mit Type-Byte pro Parameter

---

## WP 8: Transaktionen

**Beschreibung:**
- Transaktions-Control mit START TRANSACTION, COMMIT, ROLLBACK
- Auto-commit Mode Handling

**Funktionen:**

```lyx
pub fn MySQLBegin(conn: MySQLConn): bool
pub fn MySQLCommit(conn: MySQLConn): bool
pub fn MySQLRollback(conn: MySQLConn): bool
pub fn MySQLSetAutoCommit(conn: MySQLConn, enable: bool): bool
pub fn MySQLGetAutoCommit(conn: MySQLConn): bool
```

**Intern:**
- Nutzt COM_QUERY für SQL-Befehle
- Prüft server_status auf SERVER_STATUS_IN_TRANSACTION

---

## WP 9: Connection Pool

**Beschreibung:**
- Pool-Verwaltung für mehrere gleichzeitige Verbindungen
- Timeout-Handling, Connection-Recycling

**Funktionen:**

```lyx
pub fn MySQLPoolCreate(host: pchar, port: int64, user: pchar, password: pchar, db: pchar, maxConnections: int64, timeoutMs: int64): MySQLPool
pub fn MySQLPoolGetConnection(pool: MySQLPool): MySQLConn
pub fn MySQLPoolReleaseConnection(pool: MySQLPool, conn: MySQLConn): void
pub fn MySQLPoolDestroy(pool: MySQLPool): void
pub fn MySQLPoolQuery(pool: MySQLPool, sql: pchar): MySQLResult
```

**Implementation:**
- Array von `MySQLConn` Structs
- Mutex-free (simplified): Nur ein Thread pro Connection
- Bei Erschöpfung: Warte auf Timeout oder Fehler

---

## WP 10: Tests & Beispiele

**Beschreibung:**
- Beispielprogramme für die Nutzung
- Einfache Test-Cases

**Dateien:**

```lyx
// tests/lyx/stdlib/use_mysql_basic.lyx
// tests/lyx/stdlib/use_mysql_pool.lyx
// tests/lyx/stdlib/use_mysql_prepared.lyx
```

---

## Zusammenfassung

| WP | Inhalt | Komplexität | Geschätzte Zeilen |
|----|--------|-------------|-------------------|
| 1 | Grundstruktur & Typen | Niedrig | ~150 |
| 2 | Packet-Handling | Mittel | ~100 |
| 3 | Connection & Handshake | Hoch | ~200 |
| 4 | Authentifizierung | Mittel | ~80 |
| 5 | Query-Ausführung | Hoch | ~200 |
| 6 | Result-Set | Mittel | ~120 |
| 7 | Prepared Statements | Hoch | ~180 |
| 8 | Transaktionen | Niedrig | ~60 |
| 9 | Connection Pool | Mittel | ~150 |
| 10 | Tests | Niedrig | ~100 |

**Gesamt:** ~1.340 Zeilen Lyx-Code

---

## Offene Punkte / Annahmen

1. **Auth-Methode**: Wir starten mit `mysql_native_password` (SHA1). Das ist einfach zu implementieren und funktioniert mit fast allen MySQL/MariaDB-Installationen. `caching_sha2_password` kann später ergänzt werden.

2. **SHA1-Implementierung**: Lyx hat bereits `std.crypto.sha1` - das sollte nutzbar sein.

3. **Fehlerbehandlung**: Bei Netzwerkfehlern wird die Connection geschlossen und ein Fehler-Code gesetzt.

4. **Thread-Safety**: Der Connection Pool gibt keine echten Mutex-Free Garantien - die Nutzung erfordert einen Connection-Pool pro Thread oder externe Synchronisation.

---

## Referenzen

- MySQL Wire Protocol: https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_v10.html
- Protocol Overview: https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html
- HandshakeV10: https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake_v10.html