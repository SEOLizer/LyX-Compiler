# Lyx Apache Cassandra-Bibliothek (`std/db/cassandra`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für
`std/db/cassandra`, die offizielle Apache Cassandra-Standardbibliothek von Lyx.
Ziel ist eine vollständige, reine Lyx-Implementierung des **CQL Binary Protocol
v4** — ohne externe Abhängigkeiten, analog zu `std/db/mysql` und `std/db/postgres`.

**Konvention:** WP-CA-NN (Cassandra, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.db.cassandra;

pub fn main(): int64 {
  var conn: int64 := CassConnect("127.0.0.1", 9042, "cassandra", "cassandra");

  CassQuery(conn, "CREATE KEYSPACE IF NOT EXISTS shop WITH replication = {'class':'SimpleStrategy','replication_factor':1}", CASS_CONSISTENCY_LOCAL_ONE);
  CassQuery(conn, "USE shop", CASS_CONSISTENCY_LOCAL_ONE);
  CassQuery(conn, "CREATE TABLE IF NOT EXISTS products (id uuid PRIMARY KEY, name text, price double)", CASS_CONSISTENCY_LOCAL_ONE);

  var stmt: int64 := CassPrepare(conn, "INSERT INTO products (id, name, price) VALUES (?, ?, ?)");
  CassBindUUID(stmt, 0, CassUUIDGen());
  CassBindStr(stmt, 1, "Widget");
  CassBindDouble(stmt, 2, 9.99);
  CassStmtExecute(conn, stmt, CASS_CONSISTENCY_QUORUM);
  CassStmtFree(stmt);

  var result: int64 := CassQuery(conn, "SELECT id, name, price FROM products", CASS_CONSISTENCY_ONE);
  while (CassFetchRow(result)) {
    PrintStr(CassGetStr(result, 0));
    PrintStr(": ");
    PrintStr(CassGetStr(result, 1));
    PrintStr(" @ ");
    PrintFloat(CassGetDouble(result, 2));
    PrintStr("\n");
  }
  CassFreeResult(result);

  CassClose(conn);
  return 0;
}
```

`std/db/cassandra` soll sich so selbstverständlich anfühlen wie `std/db/mysql` —
die gesamte CQL-Protokoll-Komplexität inklusive SASL-Auth, Paging und Batch-Writes
vollständig hinter einer klaren API kapseln.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│           std/db/cassandra.lyu  (public API)                 │
│  CassConnect · CassQuery · CassPrepare · CassBatch · …       │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│               Protokoll-Schicht (intern)                     │
│  cassSendFrame · cassRecvFrame · cassParseResult · …         │
└──────┬────────────────────┬──────────────────────┬───────────┘
       │                    │                      │
┌──────▼──────┐  ┌──────────▼─────────┐  ┌────────▼──────────┐
│   TCP/IP    │  │   SASL PLAIN Auth  │  │  Result-Parser    │
│  Port 9042  │  │  \0user\0password  │  │  Rows / Void /    │
│ sys_socket  │  │  AUTH_RESPONSE     │  │  Prepared /       │
│ sys_connect │  │                    │  │  Schema_change    │
└─────────────┘  └────────────────────┘  └───────────────────┘
```

### Vergleich der DB-Units

| Aspekt | mysql | postgres | cassandra |
|--------|-------|----------|-----------|
| Protokoll | Binary v10 | PG FE/BE v3 | CQL Binary v4 |
| Auth | SHA-1 HMAC | MD5 / Cleartext | SASL PLAIN |
| Frame | 3-Byte-Len + Seq | Type + 4-Byte-Len | Version + Flags + Stream + Opcode + 4-Byte-Len |
| Query-Sprache | SQL | SQL | CQL (SQL-ähnlich, kein JOIN) |
| Prepared Stmts | COM_STMT_PREPARE | Parse/Bind/Execute | PREPARE / EXECUTE |
| Batch | — | (via Transaktion) | BATCH (LOGGED/UNLOGGED/COUNTER) |
| Konsistenz | — | ACID | Konfigurierbares Konsistenzlevel |
| Basis-Port | 3306 | 5432 | 9042 |

### Datei-Überblick

```
std/db/
  cassandra.lyu     ← öffentliche API
  cassandra.lyx     ← kompilierte Unit
```

---

## CQL Binary Protocol v4 — Überblick

### Frame-Format

```
[version:  1 Byte]   0x04 = Request, 0x84 = Response
[flags:    1 Byte]   0x00=keine, 0x01=Komprimierung, 0x04=Tracing, 0x08=Custom-Payload
[stream:   2 Bytes]  Signed int16, big-endian (Multiplexing; 0 für einfachen Client)
[opcode:   1 Byte]   Nachrichtentyp (s. u.)
[length:   4 Bytes]  Body-Länge, int32 big-endian
[body:     N Bytes]
```

### Opcodes

| Hex | Name | Richtung | Beschreibung |
|-----|------|----------|--------------|
| 0x01 | STARTUP | → Server | Verbindungsinitialisierung |
| 0x02 | READY | ← Server | Verbindung bereit (kein Auth nötig) |
| 0x03 | AUTHENTICATE | ← Server | Auth erforderlich |
| 0x05 | OPTIONS | → Server | Unterstützte Optionen anfragen |
| 0x06 | SUPPORTED | ← Server | Antwort auf OPTIONS |
| 0x07 | QUERY | → Server | CQL-Statement ausführen |
| 0x08 | RESULT | ← Server | Antwort auf QUERY/EXECUTE/PREPARE/BATCH |
| 0x09 | PREPARE | → Server | Statement vorkompilieren |
| 0x0A | EXECUTE | → Server | Prepared Statement ausführen |
| 0x0B | REGISTER | → Server | Für Events registrieren |
| 0x0C | EVENT | ← Server | Asynchrones Ereignis |
| 0x0D | BATCH | → Server | Mehrere Statements gebündelt |
| 0x0E | AUTH_CHALLENGE | ← Server | SASL-Challenge |
| 0x0F | AUTH_RESPONSE | → Server | SASL-Antwort |
| 0x10 | AUTH_SUCCESS | ← Server | Auth erfolgreich |
| 0x00 | ERROR | ← Server | Fehlerantwort |

### STARTUP-Body

```
[string map]:
  "CQL_VERSION" → "3.0.0"          (pflicht)
  "DRIVER_NAME" → "lyx"            (optional)
  "DRIVER_VERSION" → "1.0"         (optional)
```

### SASL PLAIN Authentication

```
1. Server → AUTHENTICATE: Body = Authenticator-Klassenname
   "org.apache.cassandra.auth.PasswordAuthenticator"

2. Client → AUTH_RESPONSE:
   Body = [bytes]: \x00 + username + \x00 + password

3. Server → AUTH_SUCCESS (oder AUTH_CHALLENGE für SCRAM-basierte Auth)
```

### QUERY-Parameter-Format

```
[consistency: int16]
[flags: int32]
  0x0001 VALUES          – Bind-Werte folgen
  0x0004 PAGE_SIZE       – Seitengröße folgt
  0x0008 WITH_PAGING_STATE
  0x0010 WITH_SERIAL_CONSISTENCY
  0x0040 WITH_NAMES_FOR_VALUES
[n_values: int16]        – falls VALUES-Flag gesetzt
[value: bytes]*          – je value: int32 len (-1 = null) + bytes
[page_size: int32]       – falls PAGE_SIZE-Flag gesetzt
[paging_state: bytes]    – falls PAGING_STATE-Flag gesetzt
```

### RESULT-Typen

```
0x0001  Void            → kein Ergebnis (z. B. INSERT, CREATE TABLE)
0x0002  Rows            → Ergebnismenge mit Metadaten und Zeilen
0x0003  Set_keyspace    → USE <keyspace> erfolgreich
0x0004  Prepared        → PREPARE: prepared_id + col-Metadaten
0x0005  Schema_change   → DDL-Operation (change_type + target + options)
```

### RESULT Rows — Metadaten-Flags

```
0x0001  GLOBAL_TABLES_SPEC  – ks_name + table_name einmalig für alle Spalten
0x0002  HAS_MORE_PAGES      – Paging-State folgt für nächste Seite
0x0004  NO_METADATA         – Metadaten weggelassen (bei EXECUTE)
```

### CQL-Typen (RESULT-Metadaten Type-IDs)

| ID | CQL-Typ | Lyx-Typ |
|----|---------|---------|
| 0x0001 | ascii | pchar |
| 0x0002 | bigint | int64 |
| 0x0003 | blob | ptr+len |
| 0x0004 | boolean | bool |
| 0x0005 | counter | int64 |
| 0x0007 | double | f64 |
| 0x0008 | float | f64 (→ f32 intern) |
| 0x0009 | int | int64 (→ int32 intern) |
| 0x000A | timestamp | int64 (ms seit Epoch) |
| 0x000B | uuid | pchar (hex-string) |
| 0x000C | varchar / text | pchar |
| 0x000E | timeuuid | pchar (hex-string) |
| 0x000F | inet | pchar |
| 0x0010 | date | int64 |
| 0x0012 | smallint | int64 (→ int16) |
| 0x0013 | tinyint | int64 (→ int8) |
| 0x0020 | list\<T\> | raw JSON-ähnliche pchar |
| 0x0021 | map\<K,V\> | raw pchar |
| 0x0022 | set\<T\> | raw pchar |

### Serialisierung von Bind-Werten (binäres Big-Endian)

```
bigint / counter / timestamp  → 8 Bytes, big-endian int64
int                           → 4 Bytes, big-endian int32
smallint                      → 2 Bytes, big-endian int16
tinyint                       → 1 Byte
double                        → 8 Bytes IEEE 754
float                         → 4 Bytes IEEE 754
boolean                       → 1 Byte (0x00 / 0x01)
text / varchar / ascii        → UTF-8-Bytes (keine Länge, nur Payload)
uuid / timeuuid               → 16 Bytes
blob                          → raw bytes
inet                          → 4 Bytes (IPv4) oder 16 Bytes (IPv6)
NULL                          → Länge = -1 (kein Body)
```

### Konsistenzlevel-Konstanten

```
CASS_CONSISTENCY_ANY            0x0000
CASS_CONSISTENCY_ONE            0x0001
CASS_CONSISTENCY_TWO            0x0002
CASS_CONSISTENCY_THREE          0x0003
CASS_CONSISTENCY_QUORUM         0x0004
CASS_CONSISTENCY_ALL            0x0005
CASS_CONSISTENCY_LOCAL_QUORUM   0x0006
CASS_CONSISTENCY_EACH_QUORUM    0x0007
CASS_CONSISTENCY_SERIAL         0x0008
CASS_CONSISTENCY_LOCAL_SERIAL   0x0009
CASS_CONSISTENCY_LOCAL_ONE      0x000A
```

### ERROR-Codes (Auswahl)

```
0x0000  Server error          0x0100  Authentication error
0x000A  Protocol error        0x1000  Unavailable exception
0x1100  Write_timeout         0x1200  Read_timeout
0x2000  Syntax_error          0x2100  Unauthorized
0x2200  Invalid               0x2400  Already_exists
0x2500  Unprepared
```

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | TCP, Frame-Layer, Handshake, SASL-Auth | CA-01 – CA-02 |
| 2 | Connection-Typ, CassConnect/Close, Simple Query | CA-03 – CA-04 |
| 3 | Result-Set Accessoren | CA-05 |
| 4 | Prepared Statements & Parameter-Binding | CA-06 – CA-07 |
| 5 | Batch-Operationen & Paging | CA-08 – CA-09 |
| 6 | UUID/Typen, Demos & Tests | CA-10 – CA-11 |

---

## Work Packages

---

### WP-CA-01: TCP-Verbindung & Frame-Layer ⬜

**Ziel:** Rohe TCP-Verbindung aufbauen und den vollständigen CQL-v4-Frame-Layer
implementieren — das Fundament aller weiteren Operationen.

**Zu implementieren:**

- TCP-Verbindung (wie mysql.lyu): `sys_socket`, `sys_connect`, IPv4-Parser
- Sende- und Empfangs-Buffer (per `mmap`): `CassMsgBuf { buf=int64; cap=int64; len=int64 }`
- Internes Frame-Senden:
  ```
  cassSendFrame(fd, opcode, stream, body, bodyLen)
    → schreibt [0x04][flags=0x00][stream: 2 Byte BE][opcode][bodyLen: 4 Byte BE][body]
  ```
- Internes Frame-Empfangen:
  ```
  cassRecvFrame(fd, outOpcode, outStream, outBuf) → int64 (bodyLen)
    → liest 9-Byte-Header, dann bodyLen Bytes in outBuf
  ```
- Big-Endian-Hilfsfunktionen (werden auch in WP-PG-01 benötigt, hier parallel):
  - `writeInt32BE(buf, off, v)` / `readInt32BE(buf, off) → int64`
  - `writeInt16BE(buf, off, v)` / `readInt16BE(buf, off) → int64`
- CQL-Typ-Serialisierungs-Primitiven:
  - `cassWriteString(buf, off, s)` — int16 len + UTF-8 bytes
  - `cassReadString(buf, off) → pchar` — liest int16 len + kopiert
  - `cassWriteLongString(buf, off, s)` — int32 len + bytes (für Queries)
  - `cassWriteStringMap(buf, off, keys, vals, n)` — int16 count + [key+val]*
  - `cassWriteBytes(buf, off, ptr, len)` — int32 len + bytes
  - `cassReadBytes(buf, off, outLen) → int64` — ptr auf Payload
- Frame-Konstanten: alle Opcodes, Flags, Protocol-Version-Bytes

**Dateien:**
- `std/db/cassandra.lyu` (Abschnitt: TCP + Frame)

**Akzeptanzkriterien:**
- Rohe TCP-Verbindung zu localhost:9042 erfolgreich
- `cassSendFrame` + `cassRecvFrame` transferieren Frame korrekt (Loopback-Test)
- `writeInt32BE(buf, 0, 0x0001FFFF)` schreibt Bytes `00 01 FF FF`
- `cassWriteString` + `cassReadString` sind invers zueinander

---

### WP-CA-02: Handshake & SASL-Authentifizierung ⬜

**Ziel:** Den vollständigen Verbindungsaufbau bis zum betriebsbereiten
Zustand implementieren — von STARTUP bis READY oder AUTH_SUCCESS.

**Zu implementieren:**

- **STARTUP** aufbauen und senden:
  ```
  opcode = 0x01
  body   = string_map { "CQL_VERSION" → "3.0.0" }
  ```
- Response-Dispatch:
  - `READY` (0x02) → Verbindung ist fertig (Trust/keine Auth)
  - `AUTHENTICATE` (0x03) → Auth nötig; Body = Authenticator-Name (z. B.
    `"org.apache.cassandra.auth.PasswordAuthenticator"`)
  - `ERROR` (0x00) → Verbindung fehlgeschlagen; Fehlercode + Meldung lesen
- **SASL PLAIN** AUTH_RESPONSE aufbauen:
  ```
  token = [0x00][username-bytes][0x00][password-bytes]
  AUTH_RESPONSE body = [bytes] token
  ```
- Response auf AUTH_RESPONSE:
  - `AUTH_SUCCESS` (0x10) → Verbindung hergestellt
  - `AUTH_CHALLENGE` (0x0E) → für komplexere SASL-Mechanismen (außerhalb Scope)
  - `ERROR` 0x0100 → falsche Credentials
- Error-Parser `cassParseError(body, outCode, outMsg)`:
  - `[int32] error_code` + `[string] message`
  - Für bestimmte Codes: zusätzliche Felder (z. B. Unavailable: Consistency + required + alive)

**Dateien:**
- `std/db/cassandra.lyu` (Abschnitt: Handshake + Auth)

**Akzeptanzkriterien:**
- Verbindung ohne Auth (Cassandra `authenticator: AllowAllAuthenticator`) → READY empfangen
- Verbindung mit korrekten Credentials → AUTH_SUCCESS
- Verbindung mit falschem Passwort → ERROR 0x0100, `last_error` enthält Meldung
- `cassParseError` extrahiert Fehlercode und Nachricht korrekt

---

### WP-CA-03: CassConn-Typ & CassConnect/Close ⬜

**Ziel:** Den öffentlichen `CassConn`-Struct und die primären
Verbindungsfunktionen implementieren.

**Zu implementieren:**

- Struct `CassConn` (per `mmap`):
  ```
  CassConn {
    fd=int64; host=pchar; port=int64
    user=pchar; password=pchar; keyspace=pchar
    status=int64              // CASS_STATUS_DISCONNECTED / CONNECTED
    last_errcode=int64        // CQL-Fehlercode der letzten Op
    errmsg=pchar              // Fehlermeldung (heap-allokiert)
    next_stream=int64         // nächste Stream-ID (inkrementell; Simplex-Mode)
    send_buf=int64            // CassMsgBuf* für Frame-Aufbau
    recv_buf=int64            // CassMsgBuf* für empfangene Frames
    protocol_version=int64    // 4
  }
  ```
- Status-Konstanten:
  ```
  CASS_STATUS_DISCONNECTED  0
  CASS_STATUS_CONNECTED     1
  ```
- `CassConnect(host, port, user, password) → int64`
  — öffnet TCP, führt Handshake + Auth durch; gibt CassConn-Ptr zurück (0 = Fehler)
- `CassConnectKeyspace(host, port, user, password, keyspace) → int64`
  — wie CassConnect, sendet danach `USE <keyspace>` als QUERY
- `CassClose(conn) → void` — schließt fd, gibt Speicher frei
- `CassError(conn) → pchar` — letzte Fehlermeldung
- `CassErrno(conn) → int64` — letzter Fehlercode
- `CassIsConnected(conn) → bool`
- `CassUseKeyspace(conn, keyspace) → bool` — `USE <keyspace>` als QUERY

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- `CassConnect` + `CassClose` ohne Fehler
- `CassConnectKeyspace` mit gültigem Keyspace: kein Fehler
- `CassConnectKeyspace` mit ungültigem Keyspace: gibt 0 zurück, `CassError` hat Text
- `CassIsConnected` gibt false nach `CassClose` zurück

---

### WP-CA-04: Simple Query Protocol (QUERY) ⬜

**Ziel:** CQL-Statements ohne Parameter senden und alle RESULT-Typen korrekt
parsen.

**Zu implementieren:**

- `CassQuery(conn, cql, consistency) → int64`
  — baut QUERY-Frame (opcode 0x07):
  ```
  [long_string cql][consistency: int16][flags: int32 = 0x0000]
  ```
  Gibt CassResult-Ptr zurück (0 bei Fehler)
- `CassResult`-Struct (per `mmap`):
  ```
  CassResult {
    result_type=int64       // 1=Void, 2=Rows, 3=Set_ks, 4=Prepared, 5=Schema
    field_count=int64
    row_count=int64
    rows=int64              // Array CassRow*
    row_alloc=int64
    fields=int64            // Array CassField*
    paging_state=int64      // bytes für nächste Seite (oder 0)
    paging_state_len=int64
    has_more_pages=bool
    current_row=int64       // Cursor für CassFetchRow
    field_buf=int64         // String-Heap
    keyspace=pchar          // für Set_keyspace-Result
  }
  ```
- `CassField`-Struct:
  ```
  CassField { name=pchar; keyspace=pchar; table=pchar; type_id=int64 }
  ```
- `CassRow`-Struct:
  ```
  CassRow { values=int64; lengths=int64; is_null=int64; count=int64 }
  ```
- Interner RESULT-Parser `cassParseResult(body, bodyLen) → CassResult*`:
  - RESULT-Typ lesen (int32)
  - Void → leeres CassResult
  - Rows → Metadaten-Flags, columns_count, paging_state, column-specs, rows_count, Zeilen
  - Set_keyspace → keyspace-Feld setzen
  - Schema_change → Typ + Target + Options lesen (gespeichert in keyspace-Feld als JSON-String)
- `CassFreeResult(result) → void`
- Fehlerbehandlung: ERROR-Frame → `conn.last_errcode`, `conn.errmsg`; Rückgabe 0

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- `CassQuery(conn, "SELECT release_version FROM system.local", CASS_CONSISTENCY_ONE)`
  → CassResult mit 1 Zeile, 1 Spalte
- `CassQuery` für `CREATE TABLE IF NOT EXISTS …` → Void-Result (kein Absturz)
- `CassQuery` mit Syntax-Fehler → 0 zurück, `CassError` enthält SYNTAX_ERROR-Text
- `CassFreeResult` gibt Speicher frei (kein Leak)

---

### WP-CA-05: Result-Set Accessoren ⬜

**Ziel:** Ergonomische Funktionen zum Traversieren und Lesen von
CassResult-Ergebnismengen.

**Zu implementieren:**

- `CassFetchRow(result) → bool` — Cursor auf nächste Zeile; false wenn keine mehr
- `CassNumRows(result) → int64`
- `CassNumCols(result) → int64`
- `CassHasMorePages(result) → bool` — true wenn Cassandra weitere Seiten hat
- `CassGetPagingState(result, outLen) → int64` — Ptr auf Paging-State-Bytes
- Column-Accessoren (0-basierter Index):
  - `CassGetStr(result, col) → pchar` — text / varchar / ascii / uuid als String
  - `CassGetInt(result, col) → int64` — bigint / int / smallint / tinyint / counter
  - `CassGetDouble(result, col) → f64` — double / float
  - `CassGetBool(result, col) → bool` — boolean
  - `CassGetBlob(result, col, outLen) → int64` — blob / bytes (Raw-Ptr + Länge)
  - `CassGetTimestamp(result, col) → int64` — timestamp als ms seit Epoch
  - `CassIsNull(result, col) → bool`
  - `CassGetColName(result, col) → pchar`
  - `CassGetColType(result, col) → int64` — CQL-Typ-ID (s. Tabelle oben)
- `CassDataSeek(result, row)` — Cursor auf beliebige Zeile setzen

**Typ-Konvertierungen intern:**
- bigint (8 Byte BE int64) → direkt
- int (4 Byte BE int32) → sign-extend auf int64
- smallint (2 Byte BE int16) → sign-extend auf int64
- tinyint (1 Byte int8) → sign-extend auf int64
- double (8 Byte IEEE 754) → f64 direkt
- float (4 Byte IEEE 754) → f64 via cast
- boolean (1 Byte 0x00/0x01) → bool

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- SELECT mit 3 Zeilen: CassFetchRow-Schleife liefert exakt 3 Iterationen
- `CassIsNull` gibt true für NULL-Spalte zurück
- `CassGetInt` für bigint-Spalte gibt korrekten Wert zurück
- `CassGetColType` gibt 0x000C (varchar) für TEXT-Spalte zurück
- `CassGetStr` für uuid-Spalte gibt String der Form `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` zurück

---

### WP-CA-06: Prepared Statements & EXECUTE ⬜

**Ziel:** CQL-Statements vorkompilieren (PREPARE) und parametrisiert ausführen
(EXECUTE) — der performanteste Weg für wiederholte Queries.

**Zu implementieren:**

- `CassPrepare(conn, cql) → int64`
  — sendet PREPARE-Frame (opcode 0x09):
  ```
  [long_string cql][flags: int32 = 0]
  ```
  Parst RESULT Prepared: speichert `prepared_id` (short bytes, 16–32 Bytes)
  und Column-Metadaten für Bind-Platzhalter
  Gibt CassStmt-Ptr zurück (oder 0 bei Fehler)
- `CassStmt`-Struct:
  ```
  CassStmt {
    prepared_id=int64; prepared_id_len=int64
    sql=pchar
    param_count=int64
    params=int64          // Array CassParam*
    params_alloc=int64
    conn=int64
    col_meta=int64        // Spalten-Metadaten (CassField*)
    col_count=int64
  }
  ```
- `CassParam`-Struct: `{ data=int64; data_len=int64; type_id=int64; is_null=bool }`
- `CassStmtExecute(conn, stmt, consistency) → int64`
  — baut EXECUTE-Frame (opcode 0x0A):
  ```
  [short_bytes prepared_id][consistency: int16][flags: 0x0001 VALUES][n_values: int16]
  [für jeden Param: int32 len + bytes (oder int32 -1 für NULL)]
  ```
  Gibt CassResult-Ptr zurück
- `CassStmtFree(stmt) → void`
- `CassStmtReset(stmt) → void` — löscht alle Bindings, behält prepared_id

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- `CassPrepare` + `CassStmtExecute` für INSERT + SELECT korrekt
- `CassStmtReset` + neu binden + Execute: zweite Ausführung korrekt
- `CassPrepare` mit Syntax-Fehler → 0, Fehlertext vorhanden
- prepared_id wird korrekt gespeichert und im EXECUTE-Frame übermittelt

---

### WP-CA-07: Parameter-Binding ⬜

**Ziel:** Alle Bind-Typen für Prepared Statements implementieren (binäres
Big-Endian-Format, wie Cassandra es erwartet).

**Zu implementieren:**

- `CassBindInt(stmt, i, v) → void` — int64 → 4 Byte BE int32 (für CQL `int`)
- `CassBindBigint(stmt, i, v) → void` — int64 → 8 Byte BE (bigint / counter / timestamp)
- `CassBindDouble(stmt, i, v) → void` — f64 → 8 Byte IEEE 754 (double)
- `CassBindFloat(stmt, i, v) → void` — f64 → 4 Byte IEEE 754 (float, via narrowing cast)
- `CassBindStr(stmt, i, v) → void` — pchar → raw UTF-8 bytes (text / varchar / ascii)
- `CassBindBool(stmt, i, v) → void` — bool → 1 Byte 0x00/0x01
- `CassBindUUID(stmt, i, uuid_str) → void`
  — hex-UUID-String `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` → 16 raw bytes
- `CassBindBlob(stmt, i, ptr, len) → void` — raw bytes
- `CassBindTimestamp(stmt, i, ms) → void` — int64 ms → 8 Byte BE (wie bigint)
- `CassBindNull(stmt, i) → void` — setzt is_null = true (EXECUTE sendet len = -1)
- `CassBindSmallint(stmt, i, v) → void` — int64 → 2 Byte BE int16
- `CassBindTinyint(stmt, i, v) → void` — int64 → 1 Byte int8

Interne Hilfsfunktion:
- `cassCopyBE(dst, src, n)` — kopiert n Bytes in Big-Endian-Reihenfolge

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- INSERT mit bigint, text, double, bool, uuid → alle Werte korrekt (per SELECT verifiziert)
- NULL-Binding: Spalte ist in Cassandra NULL
- `CassBindTimestamp` mit bekanntem Wert: SELECT timestamp = Ausgangswert
- UUID round-trip: `CassBindUUID(stmt, 0, CassUUIDToStr(uuid))` → `CassGetStr(result, 0)` liefert dieselbe UUID

---

### WP-CA-08: Batch-Operationen ⬜

**Ziel:** Das Cassandra BATCH-Protokoll implementieren für atomare
(LOGGED) oder hochperformante (UNLOGGED) Mehrzeilen-Schreiboperationen.

**Zu implementieren:**

- Batch-Typ-Konstanten:
  ```
  CASS_BATCH_LOGGED    0   // Atomare Ausführung (2-Phase Paxos intern)
  CASS_BATCH_UNLOGGED  1   // Kein Logging, max. Performance
  CASS_BATCH_COUNTER   2   // Nur für Counter-Columns
  ```
- `CassBatch`-Struct:
  ```
  CassBatch {
    conn=int64; batch_type=int64
    buf=int64; buf_len=int64; buf_alloc=int64
    n_queries=int64
  }
  ```
- `CassBatchBegin(conn, batch_type) → int64` — legt CassBatch an
- `CassBatchAddQuery(batch, cql, params_json) → void`
  — fügt Simple-Query-Eintrag in den BATCH-Body ein:
  ```
  [byte 0x00 = query][long_string cql][n_values: int16 = 0]
  ```
- `CassBatchAddStmt(batch, stmt) → void`
  — fügt Prepared-Statement-Eintrag ein:
  ```
  [byte 0x01 = prepared][short_bytes prepared_id][n_values: int16][values…]
  ```
  (übernimmt Bindings aus CassStmt)
- `CassBatchExecute(batch, consistency) → bool`
  — sendet BATCH-Frame (opcode 0x0D):
  ```
  [byte batch_type][int16 n][…queries…][int16 consistency][int32 flags = 0]
  ```
  Parst RESULT (erwartet Void)
- `CassBatchFree(batch) → void`

**Hinweis:** LOGGED BATCH ist in Cassandra teuer (Paxos). Für Pure-Performance-
Szenarien UNLOGGED verwenden (mit Inkonsistenz-Risiko bei Fehler).

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- `CassBatchBegin(LOGGED)` + 5× `CassBatchAddStmt` + `CassBatchExecute`:
  alle 5 Rows in der Tabelle (per SELECT verifiziert)
- `CassBatchBegin(UNLOGGED)` + 1000× AddStmt + Execute: deutlich schneller
  als 1000 Einzel-`CassStmtExecute`
- `CassBatchBegin(COUNTER)` + Counter-Increment: Counter korrekt aktualisiert
- Fehler im Batch (Constraint-Verletzung) → `CassBatchExecute` false + Fehlertext

---

### WP-CA-09: Paging (Ergebnismengen > 1 Seite) ⬜

**Ziel:** Das Cassandra-Paging-Protokoll implementieren, um große Ergebnismengen
seitenweise abzurufen — ohne Memory-Explosion oder Timeout.

**Hintergrund:** Cassandra limitiert intern die zurückgegebenen Rows pro Query.
Mit `page_size` und `paging_state` kann der Client Seite für Seite lesen.

**Zu implementieren:**

- `CassQueryPaged(conn, cql, consistency, page_size) → int64`
  — wie `CassQuery`, aber mit `PAGE_SIZE`-Flag gesetzt:
  ```
  flags = 0x0004  (PAGE_SIZE)
  page_size: int32
  ```
  Gibt CassResult zurück; `has_more_pages` zeigt ob weitere Seiten folgen
- `CassQueryNextPage(conn, cql, consistency, page_size, result) → int64`
  — wie `CassQueryPaged`, aber mit `WITH_PAGING_STATE`-Flag:
  ```
  flags = 0x0004 | 0x0008  (PAGE_SIZE + WITH_PAGING_STATE)
  paging_state = CassGetPagingState(prev_result, &len)
  ```
  Gibt neue CassResult zurück für die nächste Seite
- Convenience-Iterator-Muster:
  ```lyx
  var result: int64 := CassQueryPaged(conn, "SELECT * FROM bigTable",
                                       CASS_CONSISTENCY_ONE, 1000);
  var total: int64 := 0;
  while (result != 0) {
    total := total + CassNumRows(result);
    if (CassHasMorePages(result)) {
      var next: int64 := CassQueryNextPage(conn, "SELECT * FROM bigTable",
                                            CASS_CONSISTENCY_ONE, 1000, result);
      CassFreeResult(result);
      result := next;
    } else {
      CassFreeResult(result);
      result := 0;
    }
  }
  ```
- Paging gilt auch für EXECUTE (Prepared Statements):
  - `CassStmtExecutePaged(conn, stmt, consistency, page_size) → int64`
  - `CassStmtExecuteNextPage(conn, stmt, consistency, page_size, prev_result) → int64`

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- 5.000 Rows in Cassandra, `page_size=1000`: 5 Iterationen, gesamt 5.000 Rows gezählt
- `CassHasMorePages` gibt false auf letzter Seite zurück
- `CassQueryNextPage` mit Paging-State der letzten Seite → `CassNumRows == 0`
  (keine Endlosschleife)

---

### WP-CA-10: UUID-Generierung & Hilfsfunktionen ⬜

**Ziel:** UUID-Erzeugung (v4 und TimeUUID v1), Typ-Utilities und
praktische Shortcuts.

**Zu implementieren:**

**UUID v4 (zufällig):**
- `CassUUIDGen() → pchar` — erzeugt UUID v4:
  - 16 zufällige Bytes via `/dev/urandom` (sys_read)
  - Byte 6 maskieren: `(b6 & 0x0F) | 0x40` (Version 4)
  - Byte 8 maskieren: `(b8 & 0x3F) | 0x80` (Variant 10)
  - Formatieren als `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
- `CassUUIDToStr(uuid_bytes) → pchar` — 16 raw Bytes → Hex-String
- `CassStrToUUID(str, out_bytes)` — Hex-String → 16 raw Bytes

**TimeUUID v1 (zeitbasiert):**
- `CassTimeUUIDNow() → pchar` — erzeugt TimeUUID v1:
  - Timestamp = 100-ns-Intervalle seit 1582-10-15 (Gregorian calendar)
  - Clock sequence: zufällig bei Start
  - Node: zufällig (MAC nicht ausgelesen)

**Weitere Hilfsfunktionen:**
- `CassLastError(conn) → pchar` — Alias für `CassError`
- `CassLastErrno(conn) → int64` — Alias für `CassErrno`
- `CassTableExists(conn, keyspace, table) → bool`
  — via `SELECT table_name FROM system_schema.tables WHERE keyspace_name=? AND table_name=?`
- `CassKeyspaceExists(conn, keyspace) → bool`
  — via `SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name=?`
- `CassTruncateTable(conn, table) → bool` — `TRUNCATE TABLE <table>`
- `CassDropTableIfExists(conn, table) → bool` — `DROP TABLE IF EXISTS <table>`
- `CassCountRows(conn, table, consistency) → int64` — `SELECT COUNT(*) FROM <table>`

**Dateien:**
- `std/db/cassandra.lyu`

**Akzeptanzkriterien:**
- `CassUUIDGen()` gibt String der Form `xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx` zurück
- Zwei aufeinanderfolgende `CassUUIDGen()`-Aufrufe liefern verschiedene Strings
- `CassStrToUUID` + `CassUUIDToStr` ist round-trip-identisch
- `CassTableExists` gibt true für existierende, false für fehlende Tabelle zurück

---

### WP-CA-11: Demos & Integrationstests ⬜

**Ziel:** Vollständige Beispielprogramme für alle Features als Regressionsbasis.

**Demo 1 — CRUD-Grundlagen** (`demo_cass_crud.lyx`):
```lyx
// Keyspace + Tabelle anlegen, 5 Rows einfügen (via Prepared Stmt),
// SELECT mit FetchRow, UPDATE, DELETE
// Alle Zeilen ausgeben
```

**Demo 2 — Konsistenzlevel** (`demo_cass_consistency.lyx`):
```lyx
// Dieselbe Query mit ONE, QUORUM, ALL
// Bei Single-Node-Dev: ALL = QUORUM = ONE; ausgeben was zurückkommt
// Bei Fehler: Fehlercode + Meldung ausgeben
```

**Demo 3 — Batch-Insert Performance** (`demo_cass_batch.lyx`):
```lyx
// 10.000 Rows via UNLOGGED BATCH (1000er-Blöcke) vs. Einzel-Inserts
// Timing für beide Varianten ausgeben
```

**Demo 4 — Paging über großen Datensatz** (`demo_cass_paging.lyx`):
```lyx
// 5.000 Rows einfügen, page_size=500, alle Seiten iterieren
// Gesamtzahl ausgeben, verifizieren = 5000
```

**Demo 5 — UUID & Typen** (`demo_cass_types.lyx`):
```lyx
// Tabelle mit uuid, bigint, double, boolean, text, timestamp, blob
// Pro Spalte: CassGetColType + CassIsNull ausgeben
// UUID-Roundtrip verifizieren
```

**Demo 6 — Systemkatalog abfragen** (`demo_cass_system.lyx`):
```lyx
// SELECT release_version FROM system.local
// SELECT keyspace_name FROM system_schema.keyspaces
// Alle Keyspaces ausgeben
```

**Dateien:**
- `demo_cass_crud.lyx`
- `demo_cass_consistency.lyx`
- `demo_cass_batch.lyx`
- `demo_cass_paging.lyx`
- `demo_cass_types.lyx`
- `demo_cass_system.lyx`

**Akzeptanzkriterien:**
- Alle 6 Demos kompilieren und laufen fehlerfrei gegen lokales Cassandra 4.x / 5.x
- Demo 3: UNLOGGED BATCH ≥ 5× schneller als Einzel-Inserts
- Demo 4: exakt 5.000 Rows gezählt
- Demo 5: UUID-Roundtrip identisch

---

## Abhängigkeiten

| Abhängigkeit | Quelle | Notiz |
|-------------|--------|-------|
| `std/io` | Lyx stdlib | PrintStr, PrintInt in Demos |
| `std/alloc` | Lyx stdlib | mmap-basierte Struct-Allokation |
| `/dev/urandom` | Linux syscall | Zufallsbytes für UUID-Generierung |
| Apache Cassandra ≥ 4.0 | System | Nur Ziel-Server — kein C-Header |

---

## Offene Fragen

- **LWT (Lightweight Transactions):** `IF NOT EXISTS` / `IF condition` nutzt
  intern Paxos. Die RESULT-Antwort auf ein LWT ist kein Void, sondern ein
  Rows-Result mit einer `[applied]`-Boolean-Spalte — separates WP sinnvoll?
- **Komprimierung:** CQL v4 unterstützt LZ4- und Snappy-Komprimierung des
  Frame-Bodys (`STARTUP`: `"COMPRESSION" → "lz4"`). Relevant für
  schreibintensive Workloads mit großen Payloads — außerhalb des initialen Scope?
- **TLS:** Cassandra unterstützt mutual TLS (Client-Zertifikat). Würde
  `std/net/tls` erfordern — optional als Erweiterung?
- **Mehrere Nodes / Load-Balancing:** Produktive Cassandra-Cluster haben 3+
  Nodes. Der Client verbindet sich aktuell nur mit einem. Ein minimaler
  Round-Robin-Pool (wie `PGPoolCreate`) wäre nützlich — separates WP?
- **TOKEN-Awareness:** Optimale Performance erfordert, dass Anfragen direkt
  an den zuständigen Node gehen (basierend auf Partition-Token). Zu komplex
  für initiale Implementierung?
- **Protocol v5:** Cassandra 4.0+ unterstützt CQL v5 (bessere Fehlerberichte,
  kontinuierliche Paging-Events). Initialer Scope: v4; Migration zu v5 optional.
