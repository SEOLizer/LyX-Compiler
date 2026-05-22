# Lyx SQLite-Bibliothek (`std/db/sqlite`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für `std/db/sqlite`,
die offizielle SQLite-Standardbibliothek von Lyx. Ziel ist eine vollständige,
ergonomische Lyx-Anbindung an libsqlite3 — inklusive Prepared Statements,
Parameter-Binding, Transaktionen und Blob-Support.

**Konvention:** WP-SQ-NN (SQLite, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.db.sqlite;

pub fn main(): int64 {
  var db: int64 := SQLiteOpen("app.db");

  SQLiteExec(db, "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

  var stmt: int64 := SQLiteStmtPrepare(db, "INSERT INTO users (name, age) VALUES (?, ?)");
  SQLiteBindStr(stmt, 1, "Alice");
  SQLiteBindInt(stmt, 2, 30);
  SQLiteStmtStep(stmt);
  SQLiteStmtFinalize(stmt);

  var sel: int64 := SQLiteStmtPrepare(db, "SELECT id, name, age FROM users");
  while (SQLiteStmtStep(sel) == SQLITE_ROW) {
    var id:   int64 := SQLiteColumnInt(sel, 0);
    var name: pchar := SQLiteColumnText(sel, 1);
    var age:  int64 := SQLiteColumnInt(sel, 2);
    PrintInt(id);
    PrintStr(": ");
    PrintStr(name);
    PrintStr(" (");
    PrintInt(age);
    PrintStr(")\n");
  }
  SQLiteStmtFinalize(sel);

  SQLiteClose(db);
  return 0;
}
```

`std/db/sqlite` soll sich so selbstverständlich anfühlen wie `std/db/mysql` —
minimale API, keine manuelle Verwaltung von C-Handles, klare Fehlerbehandlung.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│              std/db/sqlite.lyu  (public API)                 │
│  SQLiteOpen · SQLiteExec · SQLiteStmtPrepare · SQLiteClose   │
└──────────────────────────┬───────────────────────────────────┘
                           │  FFI via --include
┌──────────────────────────▼───────────────────────────────────┐
│               libsqlite3  (C-Bibliothek)                     │
│  sqlite3_open · sqlite3_prepare_v2 · sqlite3_step · …        │
└──────────────────────────────────────────────────────────────┘
```

### Vergleich mit bestehenden DB-Units

| Aspekt | mysql.lyu | redis.lyu | sqlite.lyu |
|--------|-----------|-----------|------------|
| Transport | TCP Socket (eigen) | TCP Socket (eigen) | Shared Library FFI |
| Auth | HMAC/SHA-1 | optional | keine |
| Datentypen | Binärprotokoll | RESP Text | typlos / affine |
| Transaktionen | ✅ | ❌ | ✅ |
| Prepared Stmts | ✅ | ❌ | ✅ |

### Datei-Überblick

```
std/db/
  sqlite.lyu     ← öffentliche API
  sqlite.lyx     ← kompilierte Unit
```

---

## SQLite C API — Relevante Funktionen

| C-Funktion | Lyx-Wrapper | Beschreibung |
|------------|-------------|--------------|
| `sqlite3_open(path, &db)` | `SQLiteOpen` | Datenbank öffnen |
| `sqlite3_close(db)` | `SQLiteClose` | Verbindung schließen |
| `sqlite3_exec(db, sql, 0, 0, &err)` | `SQLiteExec` | Statement ohne Ergebnis |
| `sqlite3_prepare_v2(db, sql, -1, &stmt, 0)` | `SQLiteStmtPrepare` | Statement kompilieren |
| `sqlite3_step(stmt)` | `SQLiteStmtStep` | Nächste Zeile |
| `sqlite3_reset(stmt)` | `SQLiteStmtReset` | Statement zurücksetzen |
| `sqlite3_finalize(stmt)` | `SQLiteStmtFinalize` | Statement freigeben |
| `sqlite3_bind_int64(stmt, i, v)` | `SQLiteBindInt` | Int64 binden |
| `sqlite3_bind_double(stmt, i, v)` | `SQLiteBindFloat` | f64 binden |
| `sqlite3_bind_text(stmt, i, v, -1, STATIC)` | `SQLiteBindStr` | Text binden |
| `sqlite3_bind_null(stmt, i)` | `SQLiteBindNull` | NULL binden |
| `sqlite3_bind_blob(stmt, i, v, n, STATIC)` | `SQLiteBindBlob` | Blob binden |
| `sqlite3_column_int64(stmt, i)` | `SQLiteColumnInt` | Int64 lesen |
| `sqlite3_column_double(stmt, i)` | `SQLiteColumnFloat` | f64 lesen |
| `sqlite3_column_text(stmt, i)` | `SQLiteColumnText` | Text lesen |
| `sqlite3_column_blob(stmt, i)` | `SQLiteColumnBlob` | Blob-Pointer lesen |
| `sqlite3_column_bytes(stmt, i)` | `SQLiteColumnBytes` | Blob-Länge lesen |
| `sqlite3_column_type(stmt, i)` | `SQLiteColumnType` | Typ-Code lesen |
| `sqlite3_column_count(stmt)` | `SQLiteColumnCount` | Spaltenanzahl |
| `sqlite3_column_name(stmt, i)` | `SQLiteColumnName` | Spaltenname |
| `sqlite3_last_insert_rowid(db)` | `SQLiteLastInsertId` | Letzte Insert-ID |
| `sqlite3_changes(db)` | `SQLiteChanges` | Betroffene Zeilen |
| `sqlite3_errmsg(db)` | `SQLiteErrmsg` | Fehlermeldung |
| `sqlite3_errcode(db)` | `SQLiteErrno` | Fehlercode |

### Rückgabecodes (Konstanten)

```
SQLITE_OK          0   SQLITE_ERROR     1   SQLITE_BUSY      5
SQLITE_ROW        100  SQLITE_DONE     101  SQLITE_MISUSE   21
SQLITE_CONSTRAINT  19  SQLITE_NOTFOUND  12  SQLITE_NOMEM     7
```

### Spalten-Typkodes

```
SQLITE_INTEGER  1   SQLITE_FLOAT  2   SQLITE_TEXT   3
SQLITE_BLOB     4   SQLITE_NULL   5
```

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | FFI-Binding, Typen, Open/Close, Exec | SQ-01 – SQ-02 |
| 2 | Prepared Statements & Parameter-Binding | SQ-03 – SQ-04 |
| 3 | Transaktionen & Hilfsfunktionen | SQ-05 – SQ-06 |
| 4 | Blob-Support & erweiterte Typen | SQ-07 |
| 5 | Demos & Integrationstests | SQ-08 |

---

## Work Packages

---

### WP-SQ-01: FFI-Deklarationen & Konstanten ⬜

**Ziel:** Alle benötigten C-Symbole aus `sqlite3.h` als Lyx-extern-Funktionen
deklarieren und die wichtigsten Konstanten definieren.

**Zu implementieren:**

- Extern-Deklarationen für alle C-Funktionen aus der Tabelle oben:
  ```lyx
  extern fn sqlite3_open(filename: pchar, ppDb: int64): int64;
  extern fn sqlite3_close(db: int64): int64;
  extern fn sqlite3_exec(db: int64, sql: pchar, cb: int64, arg: int64, errmsg: int64): int64;
  extern fn sqlite3_prepare_v2(db: int64, sql: pchar, nByte: int64, ppStmt: int64, pzTail: int64): int64;
  extern fn sqlite3_step(stmt: int64): int64;
  extern fn sqlite3_reset(stmt: int64): int64;
  extern fn sqlite3_finalize(stmt: int64): int64;
  extern fn sqlite3_bind_int64(stmt: int64, i: int64, v: int64): int64;
  extern fn sqlite3_bind_double(stmt: int64, i: int64, v: f64): int64;
  extern fn sqlite3_bind_text(stmt: int64, i: int64, v: pchar, n: int64, destructor: int64): int64;
  extern fn sqlite3_bind_null(stmt: int64, i: int64): int64;
  extern fn sqlite3_bind_blob(stmt: int64, i: int64, v: int64, n: int64, destructor: int64): int64;
  extern fn sqlite3_column_int64(stmt: int64, i: int64): int64;
  extern fn sqlite3_column_double(stmt: int64, i: int64): f64;
  extern fn sqlite3_column_text(stmt: int64, i: int64): pchar;
  extern fn sqlite3_column_blob(stmt: int64, i: int64): int64;
  extern fn sqlite3_column_bytes(stmt: int64, i: int64): int64;
  extern fn sqlite3_column_type(stmt: int64, i: int64): int64;
  extern fn sqlite3_column_count(stmt: int64): int64;
  extern fn sqlite3_column_name(stmt: int64, i: int64): pchar;
  extern fn sqlite3_last_insert_rowid(db: int64): int64;
  extern fn sqlite3_changes(db: int64): int64;
  extern fn sqlite3_errmsg(db: int64): pchar;
  extern fn sqlite3_errcode(db: int64): int64;
  ```
- Konstanten (int64):
  `SQLITE_OK`, `SQLITE_ERROR`, `SQLITE_BUSY`, `SQLITE_ROW`, `SQLITE_DONE`,
  `SQLITE_MISUSE`, `SQLITE_CONSTRAINT`, `SQLITE_NOTFOUND`, `SQLITE_NOMEM`
- Spaltentyp-Konstanten: `SQLITE_INTEGER`, `SQLITE_FLOAT`, `SQLITE_TEXT`,
  `SQLITE_BLOB`, `SQLITE_NULL`
- Destruktor-Sentinels: `SQLITE_STATIC` (0), `SQLITE_TRANSIENT` (-1)
- Makefile / Compiler-Flag: `-lsqlite3` in der Link-Phase

**Dateien:**
- `std/db/sqlite.lyu` (Abschnitt: FFI + Konstanten)

**Akzeptanzkriterien:**
- Kompilierung mit `-lsqlite3` schlägt nicht fehl (Linker findet alle Symbole)
- `SQLITE_ROW == 100` und `SQLITE_DONE == 101` sind korrekt

---

### WP-SQ-02: Connection-Typ & Open/Close/Exec ⬜

**Ziel:** Den `SQLiteDB`-Struct einführen und die grundlegenden Verbindungs-
und Ausführungsfunktionen implementieren.

**Zu implementieren:**

- Struct `SQLiteDB`:
  ```
  SQLiteDB { handle=int64; path=pchar; last_errcode=int64 }
  ```
  Allokiert per `mmap`, Handle zeigt auf das `sqlite3*`-Objekt.
- `SQLiteOpen(path: pchar) → int64` — öffnet/erstellt die DB, gibt SQLiteDB-Ptr zurück;
  gibt `0` zurück bei Fehler
- `SQLiteClose(db: int64) → void` — schließt Verbindung, gibt Speicher frei
- `SQLiteExec(db: int64, sql: pchar) → bool` — führt SQL ohne Ergebnismenge aus
  (CREATE TABLE, INSERT ohne Bind, PRAGMA, …); gibt `true` bei Erfolg
- `SQLiteErrmsg(db: int64) → pchar` — Fehlermeldung der letzten Operation
- `SQLiteErrno(db: int64) → int64` — Fehlercode der letzten Operation

**Dateien:**
- `std/db/sqlite.lyu`

**Akzeptanzkriterien:**
- Öffnen einer neuen DB → Datei erscheint auf dem Dateisystem
- `SQLiteExec(db, "CREATE TABLE t (id INTEGER)")` gibt `true` zurück
- `SQLiteExec(db, "INVALID SQL")` gibt `false` zurück, `SQLiteErrmsg` liefert Text
- `SQLiteClose` gibt Speicher frei (kein Leak via valgrind)

---

### WP-SQ-03: Prepared Statements & Parameter-Binding ⬜

**Ziel:** Prepared Statements kompilieren und alle Binde-Typen implementieren.

**Zu implementieren:**

- Struct `SQLiteStmt`:
  ```
  SQLiteStmt { handle=int64; db=int64; column_count=int64 }
  ```
- `SQLiteStmtPrepare(db: int64, sql: pchar) → int64` — kompiliert SQL, gibt Stmt-Ptr zurück
- `SQLiteStmtFinalize(stmt: int64) → void` — gibt Statement frei
- `SQLiteStmtReset(stmt: int64) → void` — setzt Statement auf Anfangszustand zurück
  (Bindings bleiben erhalten; für Re-Execution)
- `SQLiteClearBindings(stmt: int64) → void` — setzt alle Bindings auf NULL zurück
- Bind-Funktionen (1-basierter Index, wie sqlite3 C API):
  - `SQLiteBindInt(stmt: int64, i: int64, v: int64) → bool`
  - `SQLiteBindFloat(stmt: int64, i: int64, v: f64) → bool`
  - `SQLiteBindStr(stmt: int64, i: int64, v: pchar) → bool`
  - `SQLiteBindNull(stmt: int64, i: int64) → bool`

**Dateien:**
- `std/db/sqlite.lyu`

**Akzeptanzkriterien:**
- Prepare eines INSERT mit `?`-Platzhaltern + BindInt/BindStr + Step
  fügt korrekte Daten ein (per SELECT verifiziert)
- `SQLiteStmtReset` + neues Bind + Step führt zweites Insert korrekt aus
- Falscher Index (0 oder > param_count) gibt `false` zurück ohne Absturz

---

### WP-SQ-04: Result-Set — Step & Column-Accessors ⬜

**Ziel:** Zeilenweises Lesen von SELECT-Ergebnissen implementieren.

**Zu implementieren:**

- `SQLiteStmtStep(stmt: int64) → int64` — gibt `SQLITE_ROW` oder `SQLITE_DONE`
  zurück; bei Fehler wird `SQLITE_ERROR` geliefert
- Column-Accessoren (0-basierter Index):
  - `SQLiteColumnInt(stmt: int64, i: int64) → int64`
  - `SQLiteColumnFloat(stmt: int64, i: int64) → f64`
  - `SQLiteColumnText(stmt: int64, i: int64) → pchar`
  - `SQLiteColumnIsNull(stmt: int64, i: int64) → bool`
  - `SQLiteColumnType(stmt: int64, i: int64) → int64` — liefert `SQLITE_INTEGER` etc.
- Spaltenmetadaten:
  - `SQLiteColumnCount(stmt: int64) → int64`
  - `SQLiteColumnName(stmt: int64, i: int64) → pchar`

**Dateien:**
- `std/db/sqlite.lyu`

**Akzeptanzkriterien:**
- SELECT über 3 Zeilen: while-Schleife mit `SQLiteStmtStep == SQLITE_ROW` liefert
  exakt 3 Iterationen, danach `SQLITE_DONE`
- `SQLiteColumnName(stmt, 0)` gibt korrekten Spaltennamen zurück
- `SQLiteColumnIsNull` gibt `true` für eine NULL-Spalte zurück
- `SQLiteColumnType` liefert für INTEGER `1`, für TEXT `3`

---

### WP-SQ-05: Transaktionen ⬜

**Ziel:** Explizite Transaktionsverwaltung für Batch-Inserts und atomare Updates.

**Zu implementieren:**

- `SQLiteBegin(db: int64) → bool` — `BEGIN TRANSACTION`
- `SQLiteCommit(db: int64) → bool` — `COMMIT`
- `SQLiteRollback(db: int64) → bool` — `ROLLBACK`
- `SQLiteBeginImmediate(db: int64) → bool` — `BEGIN IMMEDIATE` (schreibt Lock sofort)
- `SQLiteBeginExclusive(db: int64) → bool` — `BEGIN EXCLUSIVE`
- `SQLiteInTransaction(db: int64) → bool` — prüft via `sqlite3_get_autocommit`

Alle Funktionen verwenden intern `SQLiteExec` auf den entsprechenden SQL-String.

**Dateien:**
- `std/db/sqlite.lyu`

**Akzeptanzkriterien:**
- 1000 Inserts in einer Transaktion sind erheblich schneller als 1000 einzelne
  (manueller Benchmark mit `PrintInt(time_ms)`)
- `SQLiteRollback` nach fehlgeschlagenem Insert: Daten nicht in der DB
- `SQLiteInTransaction` gibt nach `BEGIN` `true` zurück, nach `COMMIT` `false`

---

### WP-SQ-06: Hilfsfunktionen & Metadaten ⬜

**Ziel:** Praktische Utilities, die typische Aufgaben abkürzen.

**Zu implementieren:**

- `SQLiteLastInsertId(db: int64) → int64` — Rowid des letzten INSERT
- `SQLiteChanges(db: int64) → int64` — Anzahl betroffener Zeilen (INSERT/UPDATE/DELETE)
- `SQLiteTableExists(db: int64, table: pchar) → bool` — prüft via
  `sqlite_master` ob Tabelle existiert
- `SQLiteDropTable(db: int64, table: pchar) → bool` — `DROP TABLE IF EXISTS`
- `SQLiteVacuum(db: int64) → bool` — `VACUUM` (Datei schrumpfen)
- `SQLiteSetJournalMode(db: int64, mode: pchar) → bool` — z. B. `"WAL"` oder `"DELETE"`
- `SQLiteSetCacheSize(db: int64, pages: int64) → bool` — PRAGMA cache_size

**Dateien:**
- `std/db/sqlite.lyu`

**Akzeptanzkriterien:**
- `SQLiteLastInsertId` gibt nach INSERT die korrekte ID zurück
- `SQLiteTableExists` gibt `true` für bestehende und `false` für fehlende Tabellen zurück
- `SQLiteSetJournalMode(db, "WAL")` schaltet WAL-Modus ein (via `PRAGMA journal_mode`)

---

### WP-SQ-07: Blob-Support ⬜

**Ziel:** Binärdaten (Byte-Arrays) an Statements binden und aus Ergebnissen lesen.

**Zu implementieren:**

- `SQLiteBindBlob(stmt: int64, i: int64, ptr: int64, len: int64) → bool`
  — bindet Blob-Daten (Raw-Pointer + Länge) an Parameter `i`
- `SQLiteColumnBlob(stmt: int64, i: int64) → int64`
  — gibt Raw-Pointer auf Blob-Daten zurück (gültig bis nächstes Step/Reset)
- `SQLiteColumnBytes(stmt: int64, i: int64) → int64`
  — gibt Blob-Länge in Bytes zurück

Anwendungsfall: Kleine Binärdaten (Icons, Thumbnails, serialisierte Structs)
direkt in SQLite speichern und lesen.

**Dateien:**
- `std/db/sqlite.lyu`

**Akzeptanzkriterien:**
- Blob mit 256 zufälligen Bytes schreiben → lesen → byteweiser Vergleich ergibt 100 % Übereinstimmung
- `SQLiteColumnBytes` gibt korrekte Länge zurück
- `SQLiteColumnBlob` gibt `0` für NULL-Spalte zurück (kein Absturz)

---

### WP-SQ-08: Demos & Integrationstests ⬜

**Ziel:** Vollständige Beispielprogramme schreiben, die alle Features abdecken,
und als Regressionsbasis dienen.

**Zu implementieren:**

**Demo 1 — CRUD-Grundlagen** (`demo_sqlite_crud.lyx`):
```lyx
// Tabelle anlegen, 5 Zeilen einfügen, SELECT, UPDATE, DELETE
// Gibt alle Zeilen mit ID, Name, Alter aus
```

**Demo 2 — Transaktion Batch-Insert** (`demo_sqlite_batch.lyx`):
```lyx
// 10.000 Rows ohne Transaktion vs. in einer Transaktion
// Gibt Zeitdifferenz aus
```

**Demo 3 — Prepared Statement Re-Use** (`demo_sqlite_stmt.lyx`):
```lyx
// Einzelnes Prepared Statement 100× mit verschiedenen Bindings wiederverwenden
// Korrekte Ergebnisse prüfen
```

**Demo 4 — NULL & Typprüfung** (`demo_sqlite_types.lyx`):
```lyx
// Tabelle mit INTEGER, REAL, TEXT, BLOB, NULL-Spalten
// SQLiteColumnType / SQLiteColumnIsNull für jede Spalte prüfen
```

**Demo 5 — Blob-Roundtrip** (`demo_sqlite_blob.lyx`):
```lyx
// 1 KB Buffer mit Zufallsdaten per mmap anlegen, INSERT, SELECT, Vergleich
```

**Dateien:**
- `demo_sqlite_crud.lyx`
- `demo_sqlite_batch.lyx`
- `demo_sqlite_stmt.lyx`
- `demo_sqlite_types.lyx`
- `demo_sqlite_blob.lyx`

**Akzeptanzkriterien:**
- Alle 5 Demos kompilieren und laufen fehlerfrei durch
- Demo 2 zeigt Transaktion ≥ 10× schneller als Einzel-Commits
- Demo 5 meldet keinen Byte-Unterschied beim Blob-Vergleich

---

## Abhängigkeiten

| Abhängigkeit | Quelle | Notiz |
|-------------|--------|-------|
| `libsqlite3` | System (`apt install libsqlite3-dev`) | Linker-Flag: `-lsqlite3` |
| `std/io` | Lyx stdlib | Für PrintStr, PrintInt in Demos |
| `std/alloc` | Lyx stdlib | Für mmap-basierte Struct-Allokation |

---

## Offene Fragen

- **In-Memory-DB:** `SQLiteOpen(":memory:")` sollte ohne Änderung funktionieren —
  explizite Konstante `SQLITE_MEMORY` als Alias?
- **Mehrere Verbindungen:** Werden mehrere gleichzeitige SQLiteDB-Instanzen benötigt,
  oder reicht eine pro Prozess?
- **WAL-Modus als Default:** Für schreibintensive Anwendungen sinnvoll —
  in `SQLiteOpen` automatisch aktivieren?
- **Thread-Safety:** sqlite3 unterstützt Serialized/Multi-Thread-Mode —
  für Lyx vorerst Single-Thread ausreichend?
