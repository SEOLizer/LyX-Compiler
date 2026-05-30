# Lyx PostgreSQL-Bibliothek (`std/db/postgres`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für `std/db/postgres`,
die offizielle PostgreSQL-Standardbibliothek von Lyx. Ziel ist eine vollständige,
reine Lyx-Implementierung des **PostgreSQL Frontend/Backend Protocol v3** — ohne
externe Abhängigkeit auf libpq, analog zu `std/db/mysql`.

**Konvention:** WP-PG-NN (PostgreSQL, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.db.postgres;

pub fn main(): int64 {
  var conn: int64 := PGConnect("127.0.0.1", 5432, "myuser", "secret", "mydb");

  PGQuery(conn, "CREATE TABLE IF NOT EXISTS products (id SERIAL PRIMARY KEY, name TEXT, price FLOAT8)");

  var stmt: int64 := PGStmtPrepare(conn, "insert_product",
    "INSERT INTO products (name, price) VALUES ($1, $2)");
  PGBindStr(stmt, 1, "Widget");
  PGBindFloat(stmt, 2, 9.99);
  PGStmtExecute(conn, stmt);
  PGStmtClose(conn, "insert_product");

  var result: int64 := PGQuery(conn, "SELECT id, name, price FROM products");
  while (PGFetchRow(result)) {
    PrintInt(PGGetInt(result, 0));
    PrintStr(": ");
    PrintStr(PGGetStr(result, 1));
    PrintStr(" @ ");
    PrintFloat(PGGetFloat(result, 2));
    PrintStr("\n");
  }
  PGFreeResult(result);

  PGClose(conn);
  return 0;
}
```

`std/db/postgres` soll sich so selbstverständlich anfühlen wie `std/db/mysql` —
vollständige Eigenimplementierung des Drahtprotokolls, kein externes C.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│           std/db/postgres.lyu  (public API)                  │
│  PGConnect · PGQuery · PGStmtPrepare · PGClose · …           │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│               Protokoll-Schicht (intern)                     │
│  sendMsg · recvMsg · parseMessage · buildStartup …           │
└──────┬────────────────────┬──────────────────────┬───────────┘
       │                    │                      │
┌──────▼──────┐  ┌──────────▼─────────┐  ┌────────▼──────────┐
│   TCP/IP    │  │   Auth-Handler     │  │  Result-Parser    │
│  (sys_socket│  │  MD5 / Cleartext   │  │  RowDesc / DataRow│
│   connect)  │  │  / Trust           │  │  CommandComplete  │
└─────────────┘  └────────────────────┘  └───────────────────┘
```

### Vergleich mysql.lyu vs postgres.lyu

| Aspekt | mysql.lyu | postgres.lyu |
|--------|-----------|--------------|
| Protokoll | MySQL Binary v10 | PG Frontend/Backend v3 |
| Auth | SHA-1 (native password) | MD5 / Cleartext / Trust |
| Frame | 3-Byte-Len + Seq | 1-Byte-Type + 4-Byte-Len |
| Prepared Stmts | COM_STMT_PREPARE | Parse/Bind/Execute/Sync |
| Param-Format | Binary | Text (Phase 1) / Binary (optional) |
| Notifications | — | LISTEN/NOTIFY |
| Bulk-Insert | — | COPY IN |
| SERIAL/Sequences | AUTO_INCREMENT | SERIAL / RETURNING |

### Datei-Überblick

```
std/db/
  postgres.lyu     ← öffentliche API
  postgres.lyx     ← kompilierte Unit
```

---

## PostgreSQL Frontend/Backend Protocol v3 — Überblick

### Nachrichtenformat

```
Frontend → Backend:
  [1 Byte: Type] [4 Byte: Length (big-endian, incl. sich selbst)] [Payload…]
  Ausnahme: StartupMessage hat keinen Type-Byte.

Backend → Frontend:
  [1 Byte: Type] [4 Byte: Length (big-endian, incl. sich selbst)] [Payload…]
```

### Frontend-Nachrichten (Client → Server)

| Type | Name | Beschreibung |
|------|------|--------------|
| — | StartupMessage | Verbindungsaufbau (kein Type-Byte; Protocol=196608) |
| `p` | PasswordMessage | Passwort-Antwort (Cleartext oder MD5) |
| `Q` | Query | Einfache SQL-Anfrage |
| `P` | Parse | Statement kompilieren (Prepared) |
| `B` | Bind | Parameter an Statement binden (Portal erzeugen) |
| `E` | Execute | Portal ausführen |
| `D` | Describe | Statement oder Portal beschreiben |
| `S` | Sync | Sync-Punkt (beendet Extended-Query-Sequenz) |
| `C` | Close | Statement oder Portal schließen |
| `X` | Terminate | Verbindung beenden |
| `d` | CopyData | COPY-Datensatz senden |
| `c` | CopyDone | COPY-Ende signalisieren |
| `f` | CopyFail | COPY mit Fehler abbrechen |

### Backend-Nachrichten (Server → Client)

| Type | Name | Beschreibung |
|------|------|--------------|
| `R` | AuthenticationRequest | Subtyp 0=OK, 3=Cleartext, 5=MD5 (4-Byte-Salt), 10=SASL |
| `S` | ParameterStatus | Server-Parameter (z. B. `server_version`) |
| `K` | BackendKeyData | PID + SecretKey (für CancelRequest) |
| `Z` | ReadyForQuery | Status: `I`=idle, `T`=in Transaktion, `E`=Fehler |
| `T` | RowDescription | Spaltenbeschreibungen |
| `D` | DataRow | Eine Ergebniszeile |
| `C` | CommandComplete | Abschluss-Tag (z. B. `INSERT 0 1`, `SELECT 5`) |
| `E` | ErrorResponse | Fehler mit Typ-Feldern (Severity, Code, Message, …) |
| `N` | NoticeResponse | Hinweis (gleiche Struktur wie Error) |
| `1` | ParseComplete | Statement erfolgreich kompiliert |
| `2` | BindComplete | Portal erfolgreich gebunden |
| `n` | NoData | Statement liefert keine Spalten |
| `I` | EmptyQueryResponse | Leerer SQL-String |
| `A` | NotificationResponse | Asynchrone NOTIFY-Nachricht |
| `G` | CopyInResponse | Server erwartet COPY-Daten |
| `H` | CopyOutResponse | Server sendet COPY-Daten |
| `d` | CopyData | Ein COPY-Datensatz vom Server |
| `c` | CopyDone | COPY-Ende vom Server |

### MD5-Authentifizierung

```
1. Server sendet: R + 0x05 + salt[4]
2. Client berechnet:
     inner = md5hex(password + user)          // 32 Hex-Zeichen
     outer = md5hex(inner + salt_as_str)      // 32 Hex-Zeichen
     response = "md5" + outer                 // 35 Zeichen
3. Client sendet: PasswordMessage mit response
```

### ReadyForQuery Status-Byte

```
'I'  = Idle (keine aktive Transaktion)
'T'  = in Transaction (aktive Transaktion)
'E'  = in failed Transaction (Fehler, ROLLBACK nötig)
```

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | TCP, Nachrichtenrahmen, Handshake, Auth | PG-01 – PG-02 ✅ |
| 2 | Connection-Typ, Simple Query, Result-Set | PG-03 – PG-05 ✅ |
| 3 | Extended Query: Prepared Statements + Binding | PG-06 – PG-07 |
| 4 | Transaktionen, Savepoints, Hilfsfunktionen | PG-08 – PG-09 |
| 5 | LISTEN/NOTIFY & COPY IN | PG-10 – PG-11 |
| 6 | Demos & Integrationstests | PG-12 |

---

## Work Packages

---

### WP-PG-01: TCP-Verbindung & Nachrichtenrahmen ✅

**Ziel:** Rohe TCP-Verbindung zu PostgreSQL aufbauen und den zuverlässigen
Lese-/Schreib-Layer für PG-Nachrichten implementieren.

**Zu implementieren:**

- TCP-Verbindung aufbauen (wie mysql.lyu): `sys_socket`, `sys_connect`, IPv4-Parser
- `pgSendRaw(fd, buf, len)` — schreibt exakt `len` Bytes über den Socket
- `pgRecvRaw(fd, buf, len)` — liest exakt `len` Bytes (retry-loop bei partiellen reads)
- `pgSendMsg(fd, type, payload, payloadLen)` — baut PG-Frame:
  ```
  [1 Byte type][4 Byte big-endian length = payloadLen + 4][payload]
  ```
  Für StartupMessage (kein type-Byte): separater `pgSendStartup()`
- `pgRecvMsg(fd, outType, outBuf, outLen)` — liest 1 Byte type + 4 Byte length,
  dann `length - 4` Payload-Bytes
- Big-Endian Hilfsfunktionen: `writeInt32BE`, `readInt32BE`, `writeInt16BE`, `readInt16BE`

**Interne Datenstrukturen:**
- `PGMsgBuf { buf=int64; cap=int64; len=int64 }` — dynamischer Schreib-Buffer
  (für Nachrichten-Aufbau per `pgBufAppend*` vor dem Senden)

**Dateien:**
- `std/db/postgres.lyu` (Abschnitt: TCP + Frame)

**Akzeptanzkriterien:**
- Rohe TCP-Verbindung zu localhost:5432 öffnet erfolgreich
- `pgSendRaw` / `pgRecvRaw` übertragen Byte-Arrays korrekt
- `readInt32BE(0x00000005)` ergibt 5; `writeInt32BE(buf, 5)` schreibt `00 00 00 05`

---

### WP-PG-02: Handshake & Authentifizierung ✅

**Ziel:** Den vollständigen Verbindungsaufbau mit Authentifizierung implementieren —
von StartupMessage bis ReadyForQuery.

**Zu implementieren:**

- **StartupMessage** aufbauen und senden:
  ```
  [4 Byte length][4 Byte protocol=196608]
  ["user\0" + username + "\0"]
  ["database\0" + dbname + "\0"]
  ["application_name\0lyx\0"]
  ["\0"]
  ```
- Auth-Response parsen:
  - `AuthenticationOk` (R + 0) → fertig
  - `AuthenticationCleartextPassword` (R + 3) → PasswordMessage mit Passwort senden
  - `AuthenticationMD5Password` (R + 5 + 4-Byte-Salt) → MD5-Antwort berechnen + senden
- MD5-Auth-Berechnung:
  ```
  inner = MD5Hex(password + user)      // MD5 aus std/crypto/md5 oder inline
  outer = MD5Hex(inner + salt[4])      // salt als 4 einzelne Bytes (kein hex)
  response = "md5" + outer
  ```
  (Hinweis: PostgreSQL erwartet `MD5Hex(inner + raw_salt_bytes)`)
- Startup-Sequenz nach Auth:
  - `ParameterStatus`-Nachrichten konsumieren (server_version, client_encoding, …)
  - `BackendKeyData` speichern (PID + SecretKey)
  - `ReadyForQuery` abwarten → Verbindung bereit
- Fehlerfall: `ErrorResponse` während Auth → Verbindung schließen, Fehlermeldung extrahieren

**Dateien:**
- `std/db/postgres.lyu` (Abschnitt: Handshake + Auth)

**Akzeptanzkriterien:**
- Verbindung mit `trust`-Auth (kein Passwort nötig) erfolgreich
- Verbindung mit `md5`-Auth und korrektem Passwort erfolgreich
- Verbindung mit falschem Passwort: ErrorResponse korrekt gelesen, kein Absturz
- Nach erfolgreichem Auth: `ReadyForQuery` mit `'I'` erhalten

---

### WP-PG-03: Connection-Typ & PGConnect/PGClose ✅

**Ziel:** Den öffentlichen `PGConn`-Struct einführen und die primären
Verbindungsfunktionen implementieren.

**Zu implementieren:**

- Struct `PGConn` (per `mmap` allokiert):
  ```
  PGConn {
    fd=int64; host=pchar; port=int64
    user=pchar; password=pchar; database=pchar
    pid=int64; secret_key=int64
    status=int64                   // PG_STATUS_DISCONNECTED / CONNECTED / IN_TX / TX_ERROR
    last_error=int64               // Fehlercode (PG_ERR_*)
    errmsg=pchar                   // letzte Fehlermeldung (heap-allokiert)
    tx_status=int64                // ReadyForQuery-Byte: 'I' / 'T' / 'E'
    server_version=pchar           // aus ParameterStatus
    msg_buf=int64                  // Send-Buffer (PGMsgBuf*)
  }
  ```
- Status-Konstanten:
  ```
  PG_STATUS_DISCONNECTED  0
  PG_STATUS_CONNECTED     1
  PG_STATUS_IN_TX         2
  PG_STATUS_TX_ERROR      3
  ```
- `PGConnect(host, port, user, password, database) → int64`
  (PGConn-Ptr oder 0 bei Fehler; ruft intern WP-01 + WP-02 auf)
- `PGClose(conn) → void` — sendet Terminate-Nachricht (`X`), schließt fd, gibt Speicher frei
- `PGError(conn) → pchar` — Fehlermeldung der letzten Operation
- `PGErrno(conn) → int64` — Fehlercode der letzten Operation
- `PGIsConnected(conn) → bool`
- `PGServerVersion(conn) → pchar` — z. B. `"16.2"`

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- `PGConnect` + `PGClose` ohne Fehler
- `PGConnect` mit falschem Port gibt 0 zurück, `PGError` liefert Text
- `PGServerVersion` gibt nicht-leeren String zurück

---

### WP-PG-04: Simple Query Protocol ✅

**Ziel:** Einfache SQL-Anfragen über das Query-Protokoll senden und alle
möglichen Backend-Antworten korrekt parsen.

**Zu implementieren:**

- `PGQuery(conn, sql) → int64` — sendet `Query`-Nachricht (`Q`), parst Antwort:
  - `RowDescription` (T): Spalten-Metadaten extrahieren + PGResult anlegen
  - `DataRow` (D): Zeilen sammeln
  - `CommandComplete` (C): Command-Tag parsen (`INSERT 0 N`, `SELECT N`,
    `UPDATE N`, `DELETE N`, `CREATE TABLE`, …)
  - `EmptyQueryResponse` (I): leeres Ergebnis
  - `ErrorResponse` (E): Fehler in conn.errmsg speichern, 0 zurückgeben
  - `ReadyForQuery` (Z): tx_status aktualisieren, Schleife beenden
- Interner Fehler-Parser für `ErrorResponse`:
  - Felder: `S` Severity, `C` Code (SQLSTATE), `M` Message, `D` Detail, `H` Hint
  - Format: `[1 Byte Feld-Type][Text\0]…[\0]`
- `PGResult`-Struct (per `mmap`):
  ```
  PGResult {
    field_count=int64
    row_count=int64
    affected_rows=int64
    insert_oid=int64              // aus "INSERT oid n"
    fields=int64                  // Array PGField*
    rows=int64                    // Array PGRow*
    row_alloc=int64
    current_row=int64             // Cursor für PGFetchRow
    field_buf=int64               // String-Heap für Feldnamen
  }
  ```
- `PGField`-Struct: `{ name=pchar; table_oid=int64; col_attr=int64; type_oid=int64; type_size=int64; type_mod=int64; format=int64 }`
- `PGRow`-Struct: `{ values=int64; lengths=int64; is_null=int64; count=int64 }`
- `PGFreeResult(result) → void`

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- `PGQuery(conn, "SELECT 1")` gibt PGResult zurück, 1 Zeile, 1 Spalte
- `PGQuery(conn, "CREATE TABLE ...")` gibt PGResult mit `affected_rows=0` zurück
- `PGQuery(conn, "INVALID")` gibt 0 zurück, `PGError` enthält SQLSTATE-Code
- `PGFreeResult` gibt Speicher frei (kein Leak)

---

### WP-PG-05: Result-Set Accessoren ✅

**Ziel:** Ergonomische Funktionen zum Traversieren und Lesen von Abfrageergebnissen.

**Zu implementieren:**

- `PGFetchRow(result) → bool` — Cursor auf nächste Zeile; `false` wenn keine mehr
- `PGGetStr(result, col) → pchar` — Wert als Text (alle PG-Typen kommen als Text)
- `PGGetInt(result, col) → int64` — Text → int64 konvertiert
- `PGGetFloat(result, col) → f64` — Text → f64 konvertiert
- `PGGetBool(result, col) → bool` — `"t"` / `"true"` / `"1"` → true
- `PGIsNull(result, row, col) → bool` — NULL-Check (Länge == -1 in DataRow)
- `PGNumRows(result) → int64`
- `PGNumFields(result) → int64`
- `PGAffectedRows(result) → int64`
- `PGGetFieldName(result, col) → pchar`
- `PGGetFieldTypeOid(result, col) → int64` — PostgreSQL OID (int4=23, text=25, …)
- `PGDataSeek(result, row)` — Cursor an beliebige Zeile setzen

**Häufige OID-Konstanten:**
```
PG_OID_BOOL     16    PG_OID_INT2    21    PG_OID_INT4    23
PG_OID_INT8     20    PG_OID_FLOAT4 700    PG_OID_FLOAT8 701
PG_OID_TEXT     25    PG_OID_VARCHAR 1043  PG_OID_DATE   1082
PG_OID_TIMESTAMP 1114 PG_OID_NUMERIC 1700  PG_OID_BYTEA  17
```

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- SELECT mit 3 Zeilen: while-Schleife mit PGFetchRow liefert exakt 3 Iterationen
- `PGIsNull` gibt true für NULL-Spalten zurück
- `PGGetInt(result, col)` für eine INTEGER-Spalte gibt korrekten Wert zurück
- `PGGetFieldTypeOid` gibt für `id SERIAL` den OID `23` zurück

---

### WP-PG-06: Extended Query Protocol (Prepared Statements) ⬜

**Ziel:** Das Extended Query Protocol implementieren: Parse → Bind → Execute → Sync.

**Zu implementieren:**

- `PGStmtPrepare(conn, name, sql) → int64` — sendet `Parse`-Nachricht:
  ```
  P: [name\0][sql\0][numParams: int16][paramTypeOids: int32*]
  ```
  Empfängt `ParseComplete` (1), Fehler → ErrorResponse
  Gibt PGStmt-Ptr zurück (oder 0 bei Fehler)
- `PGStmt`-Struct:
  ```
  PGStmt {
    name=pchar; sql=pchar; param_count=int64
    params=int64          // Array PGParam*
    params_alloc=int64
    conn=int64
  }
  ```
- `PGStmtExecute(conn, stmt) → int64` — sendet Bind + Execute + Sync-Sequenz:
  ```
  B: [\0 portal][\stmtName\0][0 formatCodes][N params][...][0 resultFormats]
  E: [\0 portal][0 maxRows]
  S: (kein Payload)
  ```
  Empfängt `BindComplete` (2), dann `DataRow`/`CommandComplete`/`ReadyForQuery`
  Gibt PGResult zurück
- `PGStmtClose(conn, name) → void` — sendet `Close`-Nachricht für Statement:
  ```
  C: ['S'][name\0]
  ```
  Empfängt `CloseComplete` (3)
- `PGStmtReset(stmt) → void` — löscht Param-Bindings, setzt Cursor zurück
- Beschreiben: `PGStmtDescribe(conn, name) → int64` (PGResult mit Spalten-Metadaten,
  kein Ausführen) — sendet `Describe`-Nachricht (`D` + `'S'` + name)

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- `PGStmtPrepare` + `PGStmtExecute` ohne Binding → SELECT liefert Ergebnis
- `PGStmtPrepare` mit ungültigem SQL → ErrorResponse, Rückgabe 0, kein Crash
- `PGStmtClose` entfernt Statement serverseitig (zweites Execute → Fehler)
- Mehrfaches Execute desselben Statements (mit Reset) funktioniert korrekt

---

### WP-PG-07: Parameter-Binding (Text-Format) ⬜

**Ziel:** Alle Binde-Typen für Prepared Statements implementieren (Text-Format,
da universell und einfacher als Binärformat).

**Zu implementieren:**

- `PGParam`-Struct: `{ text_val=pchar; len=int64; is_null=bool }`
- `PGBindInt(stmt, i, v)` — formatiert int64 → Dezimalstring
- `PGBindFloat(stmt, i, v)` — formatiert f64 → Dezimalstring (inkl. Exponent)
- `PGBindStr(stmt, i, v)` — übernimmt pchar direkt (keine Escaping nötig
  im Bind-Protokoll, da Länge explizit angegeben wird)
- `PGBindBool(stmt, i, v)` — schreibt `"t"` oder `"f"`
- `PGBindNull(stmt, i)` — setzt is_null=true (Bind-Format: length=-1)
- Internes `pgEncodeParams(stmt, buf)` — baut den Parameter-Abschnitt der Bind-Nachricht:
  ```
  [numParams: int16]
  für jeden Param: [length: int32] [data] oder [-1: int32 für NULL]
  ```

**Hinweis:** Alle Werte werden als Text übertragen (format code = 0).
Binärformat (format code = 1) ist performanter, aber optional — kann in einem
separaten WP ergänzt werden.

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- INSERT mit `$1` (int), `$2` (text), `$3` (float) bindet korrekte Werte ein
- NULL-Binding: Spalte ist in der DB NULL (via SELECT verifiziert)
- `PGBindFloat(stmt, 1, 3.14)` → Spalte enthält `3.14` (keine Rundungsfehler)
- 100 Inserts mit Re-Bind desselben Statements: alle Werte korrekt

---

### WP-PG-08: Transaktionen & Savepoints ⬜

**Ziel:** Vollständige Transaktionsverwaltung inkl. Savepoints für verschachtelte
Transaktionen.

**Zu implementieren:**

- `PGBegin(conn) → bool` — `BEGIN`
- `PGCommit(conn) → bool` — `COMMIT`
- `PGRollback(conn) → bool` — `ROLLBACK`
- `PGBeginReadOnly(conn) → bool` — `BEGIN READ ONLY`
- `PGBeginSerializable(conn) → bool` — `BEGIN ISOLATION LEVEL SERIALIZABLE`
- `PGSavepoint(conn, name) → bool` — `SAVEPOINT name`
- `PGRollbackTo(conn, name) → bool` — `ROLLBACK TO SAVEPOINT name`
- `PGReleaseSavepoint(conn, name) → bool` — `RELEASE SAVEPOINT name`
- `PGInTransaction(conn) → bool` — prüft conn.tx_status == `'T'`
- `PGTxFailed(conn) → bool` — prüft conn.tx_status == `'E'` (muss ROLLBACK folgen)
- `PGSetAutoCommit(conn, on) → bool` — via `SET autocommit = on/off`
  (PostgreSQL hat kein echtes Autocommit-Protokoll; emuliert via SQL)

Alle Transaktionsfunktionen verwenden intern `PGQuery`.
`tx_status` wird nach jedem `ReadyForQuery` aktualisiert.

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- 10.000 Inserts in einer Transaktion nachweislich schneller als Einzel-Commits
- `PGRollback` nach fehlerhaftem INSERT: Daten nicht in der DB
- `PGSavepoint("sp1")` + INSERT + `PGRollbackTo("sp1")`: Row nicht in DB,
  aber Transaktion weiter offen
- `PGTxFailed` gibt true nach Constraint-Verletzung zurück

---

### WP-PG-09: Hilfsfunktionen & Connection-Pool ⬜

**Ziel:** Praktische Utilities für häufige Aufgaben und einen einfachen
Connection-Pool für mehrere gleichzeitige Verbindungen.

**Zu implementieren:**

- `PGLastInsertId(conn) → int64` — via `SELECT lastval()` (PostgreSQL hat keine
  direkte C-API dafür nach einer Query); alternativ per `RETURNING id` in INSERT
- `PGChanges(conn) → int64` — Anzahl betroffener Zeilen aus letztem CommandComplete-Tag
- `PGTableExists(conn, table) → bool` — via `information_schema.tables`-Query
- `PGColumnExists(conn, table, column) → bool` — via `information_schema.columns`
- `PGDropTable(conn, table) → bool` — `DROP TABLE IF EXISTS`
- `PGEscapeStr(dst, src) → int64` — einfaches Escaping für Sonderzeichen in
  nicht-parametrisierten Strings (verdoppelt `'` zu `''`)
- `PGPing(conn) → bool` — `SELECT 1` als Heartbeat
- **Connection-Pool:**
  - `PGPoolCreate(size) → int64` — legt Array von `size` PGConn-Slots an
  - `PGPoolDestroy(pool) → void`
  - `PGPoolAcquire(pool, host, port, user, password, database) → int64`
    — gibt freie Verbindung zurück (öffnet neue wenn nötig)
  - `PGPoolRelease(pool, conn) → void` — Verbindung zurückgeben

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- `PGTableExists` gibt true/false korrekt zurück
- `PGChanges` gibt nach `UPDATE … WHERE id=1` den Wert `1` zurück
- `PGPoolAcquire` + `PGPoolRelease` × 100 ohne Leak

---

### WP-PG-10: LISTEN / NOTIFY ⬜

**Ziel:** Asynchrone Pub/Sub-Benachrichtigungen über PostgreSQL-Channels implementieren.

**Zu implementieren:**

- `PGListen(conn, channel) → bool` — `LISTEN channel`
- `PGUnlisten(conn, channel) → bool` — `UNLISTEN channel`
- `PGNotify(conn, channel, payload) → bool` — `NOTIFY channel, 'payload'`
- `PGGetNotification(conn) → int64` — prüft ob `NotificationResponse` (A) im
  Socket-Buffer liegt (non-blocking via `pgPeekMsg`); gibt PGNotification-Ptr zurück
  oder 0 wenn keine Nachricht ansteht
- `PGNotification`-Struct:
  ```
  PGNotification { pid=int64; channel=pchar; payload=pchar }
  ```
- `PGFreeNotification(notif) → void`
- `PGWaitNotification(conn, timeout_ms) → int64` — blockierendes Warten
  (via `select()`-Syscall mit Timeout)

**Hintergrund:** PostgreSQL sendet `NotificationResponse` (Typ `A`) asynchron
zwischen anderen Antworten. Der Client muss nach jedem `ReadyForQuery` prüfen
ob ein `A`-Frame vorangestellt war.

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- Zwei Verbindungen: conn1 `LISTEN test_ch`, conn2 `NOTIFY test_ch, 'hello'`
  → `PGGetNotification(conn1)` liefert `payload="hello"` und `pid=conn2.pid`
- `PGGetNotification` gibt 0 zurück wenn kein Event ansteht (kein Hängen)
- `PGWaitNotification` mit timeout_ms=100 kehrt rechtzeitig zurück

---

### WP-PG-11: COPY IN — Bulk-Insert ⬜

**Ziel:** Das PostgreSQL COPY-Protokoll für hochperformante Masseneinfügungen
implementieren.

**Zu implementieren:**

- `PGCopyBegin(conn, table, columns) → bool` — sendet:
  `COPY table (columns) FROM STDIN WITH (FORMAT CSV)`
  → Server antwortet mit `CopyInResponse` (G)
- `PGCopyRow(conn, values, count) → bool` — sendet eine CSV-Zeile als `CopyData` (d):
  - Felder kommagetrennt, Strings in Anführungszeichen
  - NULL als `\N` (PostgreSQL COPY-Konvention)
- `PGCopyEnd(conn) → bool` — sendet `CopyDone` (c), wartet auf `CommandComplete`
- `PGCopyAbort(conn, errmsg) → bool` — sendet `CopyFail` (f) mit Fehlermeldung
- Hilfsfunktion `pgCsvEscape(dst, src)` — Zeichen `"`, `,`, `\n`, `\r` korrekt escapen

**Anwendungsfall:** 100.000 Rows in Sekunden statt Minuten laden —
COPY ist typischerweise 10–50× schneller als präparierte INSERTs.

**Dateien:**
- `std/db/postgres.lyu`

**Akzeptanzkriterien:**
- 100.000 Rows via COPY: deutlich schneller als 100.000 Einzel-INSERTs
- Zeilen mit NULL-Feldern korrekt übertragen
- Strings mit Komma oder Anführungszeichen korrekt escaped
- `PGCopyAbort` verhindert das Einfügen (0 Rows in Tabelle)

---

### WP-PG-12: Demos & Integrationstests ⬜

**Ziel:** Vollständige Beispielprogramme, die alle Features praxisnah abdecken
und als Regressionsbasis dienen.

**Demo 1 — CRUD-Grundlagen** (`demo_pg_crud.lyx`):
```lyx
// Tabelle anlegen, 5 Rows einfügen, SELECT, UPDATE, DELETE
// Gibt alle Zeilen mit ID, Name, Preis aus
```

**Demo 2 — Prepared Statements & Re-Use** (`demo_pg_stmt.lyx`):
```lyx
// Einzelnes Prepared Statement 1000× mit verschiedenen Bindings
// Korrekte Ergebnisse + Timing ausgeben
```

**Demo 3 — Transaktion mit Rollback** (`demo_pg_tx.lyx`):
```lyx
// BEGIN → INSERT → Savepoint → fehlerhafter INSERT →
// RollbackTo Savepoint → korrekter INSERT → COMMIT
// Verifiziert: nur 1 Row in der Tabelle
```

**Demo 4 — COPY Bulk-Insert** (`demo_pg_copy.lyx`):
```lyx
// 100.000 Rows per COPY IN einfügen, Timing ausgeben
// Vergleich: dieselbe Zahl per Einzel-INSERT
```

**Demo 5 — LISTEN/NOTIFY** (`demo_pg_notify.lyx`):
```lyx
// conn1 LISTEN, conn2 NOTIFY, conn1 PGGetNotification
// Payload korrekt ausgeben
```

**Demo 6 — NULL & Typen** (`demo_pg_types.lyx`):
```lyx
// Tabelle mit INT8, FLOAT8, TEXT, BOOL, BYTEA, NULL
// PGGetFieldTypeOid + PGIsNull für jede Spalte ausgeben
```

**Dateien:**
- `demo_pg_crud.lyx`
- `demo_pg_stmt.lyx`
- `demo_pg_tx.lyx`
- `demo_pg_copy.lyx`
- `demo_pg_notify.lyx`
- `demo_pg_types.lyx`

**Akzeptanzkriterien:**
- Alle 6 Demos kompilieren und laufen fehlerfrei gegen lokales PostgreSQL 15/16
- Demo 4: COPY ≥ 10× schneller als Einzel-INSERTs
- Demo 3: exakt 1 Row in der Tabelle nach Rollback-To-Savepoint

---

## Abhängigkeiten

| Abhängigkeit | Quelle | Notiz |
|-------------|--------|-------|
| `std/io` | Lyx stdlib | PrintStr, PrintInt in Demos |
| `std/alloc` | Lyx stdlib | mmap-basierte Struct-Allokation |
| `std/crypto/md5` | Lyx stdlib | MD5-Auth (falls vorhanden; sonst inline) |
| PostgreSQL ≥ 13 | System | Nur Ziel-Server — kein C-Header, kein libpq |

---

## Offene Fragen

- **SCRAM-SHA-256:** Modernere Auth-Methode (PG 10+, oft Default bei neueren
  Installationen). Deutlich komplexer als MD5 — separates WP oder initialer
  Scope auf MD5/Cleartext/Trust beschränken?
- **TLS/SSL:** `SSLRequest`-Nachricht vor Startup ermöglicht verschlüsselte
  Verbindung. Aufwand: `std/net/tls` einbinden. Für Phase 1 optional.
- **Binäres Parameterformat:** Format-Code 1 in Bind-Nachricht ist 2–3× effizienter
  als Text — sinnvoll als separates WP nach dem Text-Format?
- **IPv6:** TCP-Verbindung via `sys_connect` aktuell nur IPv4 (wie mysql.lyu) —
  reicht das für den geplanten Einsatz?
- **Connection-Pool Locking:** Bei Multi-Thread-Szenarien nötig —
  vorerst Single-Thread ausreichend?
