# Lyx Neo4j-Bibliothek (`std/db/neo4j`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für
`std/db/neo4j`, die offizielle Neo4j-Standardbibliothek von Lyx.
Ziel ist eine vollständige, reine Lyx-Implementierung des **Bolt-Protokolls v4/v5**
mit **PackStream-Encoding** — ohne externe Abhängigkeiten, analog zu den
anderen `std/db`-Units.

**Konvention:** WP-NJ-NN (Neo4j, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.db.neo4j;

pub fn main(): int64 {
  var conn: int64 := NJConnect("127.0.0.1", 7687, "neo4j", "secret");

  NJRun(conn, "CREATE (p:Person {name: $name, age: $age}) RETURN p",
        NJParams2Str("name", "Alice", "age", "30"), 0);

  var params: int64 := NJParamNew();
  NJParamSetStr(params, "name", "Alice");
  var result: int64 := NJRun(conn,
    "MATCH (p:Person {name: $name})-[:KNOWS]->(f:Person) RETURN f.name, f.age",
    params, 0);
  NJParamFree(params);

  while (NJFetchRow(result)) {
    PrintStr(NJGetStr(result, 0));
    PrintStr(" (Alter: ");
    PrintInt(NJGetInt(result, 1));
    PrintStr(")\n");
  }
  NJFreeResult(result);

  var node_result: int64 := NJRun(conn,
    "MATCH (p:Person) RETURN p LIMIT 5", 0, 0);
  while (NJFetchRow(node_result)) {
    var node: int64 := NJGetNode(node_result, 0);
    PrintStr(NJNodeGetStr(node, "name"));
    PrintStr("\n");
  }
  NJFreeResult(node_result);

  NJClose(conn);
  return 0;
}
```

`std/db/neo4j` soll das gesamte Bolt-Protokoll und PackStream-Encoding
vollständig kapseln — der Nutzer arbeitet mit Cypher und Graph-Typen, nicht
mit Bytes.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│             std/db/neo4j.lyu  (public API)                   │
│  NJConnect · NJRun · NJGetNode · NJGetRel · NJBegin · …      │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│               Bolt-Schicht (intern)                          │
│  njSendMsg · njRecvMsg · njParseSuccess · njParseRecord      │
└──────┬────────────────────┬──────────────────────┬───────────┘
       │                    │                      │
┌──────▼──────┐  ┌──────────▼─────────┐  ┌────────▼──────────┐
│   TCP/IP    │  │  PackStream En-/   │  │  Graph-Typen      │
│  Port 7687  │  │  Decoder           │  │  Node / Rel /     │
│  Chunk-     │  │  (Neo4j-eigenes    │  │  Path / Point     │
│  Framing    │  │  Binärformat)      │  │  / Duration       │
└─────────────┘  └────────────────────┘  └───────────────────┘
```

### Vergleich aller DB-Units

| Aspekt | mysql | postgres | cassandra | elasticsearch | neo4j |
|--------|-------|----------|-----------|---------------|-------|
| Protokoll | Binary v10 | FE/BE v3 | CQL Bin v4 | REST/HTTP | Bolt v4/v5 |
| Encoding | Binär/Text | Binär/Text | Big-Endian Bin | JSON | PackStream |
| Auth | SHA-1 | MD5/Clear | SASL PLAIN | Basic/ApiKey | Basic (in HELLO) |
| Query-Sprache | SQL | SQL | CQL | Query DSL | Cypher |
| Datenmodell | Relational | Relational | Wide Column | Dokument | Graph |
| Spezialtypen | — | OID-Typen | UUID/Counter | — | Node/Rel/Path |
| Basis-Port | 3306 | 5432 | 9042 | 9200 | 7687 |

### Datei-Überblick

```
std/db/
  neo4j.lyu     ← öffentliche API
  neo4j.lyx     ← kompilierte Unit
```

---

## Bolt-Protokoll — Überblick

### Verbindungsaufbau

```
1. TCP-Verbindung zu Port 7687

2. Client sendet Magic Preamble (4 Bytes):
   60 60 B0 17

3. Client schlägt 4 Protokollversionen vor (je 4 Bytes, big-endian):
   [minor: uint8][major: uint8][range: uint8][00]
   z. B.:  00 04 05 00   (Bolt 5.4)
           00 04 04 00   (Bolt 4.4)
           00 03 04 00   (Bolt 4.3)
           00 00 00 00   (kein Vorschlag)

4. Server antwortet mit gewählter Version (4 Bytes):
   z. B.: 00 04 05 00 → Bolt 5.4 gewählt
          00 00 00 00 → kein gemeinsames Protokoll
```

### Chunk-Framing

```
Jede Bolt-Nachricht wird in Chunks übertragen:

  [uint16 BE chunk_size][payload_bytes…]   ← ein oder mehrere Chunks
  [00 00]                                  ← End-of-Message-Marker

Beispiel: Nachricht mit 300 Bytes (> 1 Chunk):
  [01 00][256 Bytes]   ← erster Chunk: 256 Bytes
  [00 2C][44 Bytes]    ← zweiter Chunk: 44 Bytes
  [00 00]              ← Nachrichtenende
```

### Nachrichtenstruktur

Jede Bolt-Nachricht ist eine **PackStream-Struktur**:
```
[Struktur-Header: B0–BF für 0–15 Felder]
[Signature-Byte: 1 Byte, identifiziert den Nachrichtentyp]
[Felder: PackStream-Werte…]
```

### Bolt-Nachrichten

| Hex | Name | Richtung | Bolt-Version | Beschreibung |
|-----|------|----------|--------------|--------------|
| 0x01 | HELLO | → Server | 4.x + 5.x | Verbindungsinitialisierung + Auth (4.x) |
| 0x02 | GOODBYE | → Server | alle | Verbindung beenden |
| 0x0F | RESET | → Server | alle | Fehler-Zustand zurücksetzen |
| 0x10 | RUN | → Server | alle | Cypher-Statement ausführen |
| 0x2F | DISCARD | → Server | alle | Ergebnisse verwerfen |
| 0x3F | PULL | → Server | alle | Ergebnisse abrufen |
| 0x11 | BEGIN | → Server | alle | Transaktion beginnen |
| 0x12 | COMMIT | → Server | alle | Transaktion bestätigen |
| 0x13 | ROLLBACK | → Server | alle | Transaktion verwerfen |
| 0x66 | ROUTE | → Server | 4.3+ | Routing-Informationen anfragen |
| 0x6A | LOGON | → Server | 5.1+ | Authentifizierung (getrennt von HELLO) |
| 0x6B | LOGOFF | → Server | 5.1+ | Abmelden |
| 0x70 | SUCCESS | ← Server | alle | Operation erfolgreich |
| 0x71 | RECORD | ← Server | alle | Ergebnis-Zeile |
| 0x7E | IGNORED | ← Server | alle | Operation ignoriert (nach Fehler) |
| 0x7F | FAILURE | ← Server | alle | Operation fehlgeschlagen |

### HELLO-Nachricht (Bolt 4.x)

```
HELLO {
  "scheme":      "basic",
  "principal":   "neo4j",
  "credentials": "password",
  "bolt_agent":  { "product": "lyx/1.0" },
  "routing":     null
}
```

### RUN-Nachricht

```
RUN <cypher_string> <params_dict> <extra_dict>

extra_dict: {
  "mode":      "w" | "r"         (write oder read, optional)
  "db":        "neo4j"            (Datenbank, optional)
  "bookmarks": []                 (für kausale Konsistenz, optional)
  "timeout":   0                  (ms, optional)
}
```

### PULL-Nachricht

```
PULL { "n": -1 }     ← alle Ergebnisse
PULL { "n": 100 }    ← max. 100 Ergebnisse (für Paging)
PULL { "n": 100, "qid": <id> }  ← explicit query ID (Bolt 4.0+)
```

### Zustandsmaschine nach RUN

```
Client:  RUN → PULL
Server:  SUCCESS (mit fields-Metadaten) → RECORD* → SUCCESS (mit summary)
         oder FAILURE (bei Syntax-/Laufzeit-Fehler)
```

### SUCCESS-Metadaten nach PULL

```
{
  "bookmark":     "...",
  "type":         "r" | "rw" | "w",
  "stats":        { "nodes-created": N, "relationships-created": N, ... },
  "profile":      { ... },
  "notifications": [ ... ]
}
```

---

## PackStream-Encoding

PackStream ist Neo4js eigenes kompaktes Binärformat (ähnlich MessagePack).
**Jeder Wert** — Parameter, Ergebnisse, Nachrichten — wird in PackStream kodiert.

### Einfache Typen

| Marker | Typ | Bedeutung |
|--------|-----|-----------|
| `0xC0` | Null | |
| `0xC3` | Boolean True | |
| `0xC2` | Boolean False | |
| `0xC1` + 8 Bytes | Float64 | IEEE 754 Big-Endian |
| `0xC8` + 1 Byte | Int8 | |
| `0xC9` + 2 Bytes BE | Int16 | |
| `0xCA` + 4 Bytes BE | Int32 | |
| `0xCB` + 8 Bytes BE | Int64 | |
| `0x00`–`0x7F` | Tiny Int | 0 bis 127 direkt |
| `0xF0`–`0xFF` | Tiny Int | -16 bis -1 direkt |

### String

| Marker | Typ |
|--------|-----|
| `0x80`–`0x8F` | Tiny String, 0–15 Bytes (Nibble = Länge) |
| `0xD0` + uint8 | String8 (bis 255 Bytes) |
| `0xD1` + uint16 BE | String16 |
| `0xD2` + uint32 BE | String32 |
gefolgt von: UTF-8-Bytes

### Bytes (Byte-Array)

| Marker | Typ |
|--------|-----|
| `0xCC` + uint8 | Bytes8 |
| `0xCD` + uint16 BE | Bytes16 |
| `0xCE` + uint32 BE | Bytes32 |

### List

| Marker | Typ |
|--------|-----|
| `0x90`–`0x9F` | Tiny List, 0–15 Elemente |
| `0xD4` + uint8 | List8 |
| `0xD5` + uint16 BE | List16 |
| `0xD6` + uint32 BE | List32 |
gefolgt von: N PackStream-Werte

### Dictionary

| Marker | Typ |
|--------|-----|
| `0xA0`–`0xAF` | Tiny Dict, 0–15 Einträge |
| `0xD8` + uint8 | Dict8 |
| `0xD9` + uint16 BE | Dict16 |
| `0xDA` + uint32 BE | Dict32 |
gefolgt von: N × (String-Schlüssel + PackStream-Wert)

### Struktur (Struct)

| Marker | Typ |
|--------|-----|
| `0xB0`–`0xBF` | Tiny Struct, 0–15 Felder (Nibble = Anzahl Felder) |
| `0xDC` + uint8 | Struct8 |
| `0xDD` + uint16 BE | Struct16 |
gefolgt von: 1 Byte Signature + N PackStream-Felder

### Graph-Typen (PackStream-Strukturen)

| Signature | Typ | Felder |
|-----------|-----|--------|
| `0x4E` (`N`) | **Node** | id (int), labels (list\<str\>), properties (dict), element_id (str) |
| `0x52` (`R`) | **Relationship** | id, start_node_id, end_node_id, type (str), properties (dict), element_id, start_element_id, end_element_id |
| `0x72` (`r`) | **UnboundRelationship** | id, type (str), properties (dict), element_id |
| `0x50` (`P`) | **Path** | nodes (list\<Node\>), rels (list\<UnboundRel\>), sequence (list\<int\>) |
| `0x44` (`D`) | **Date** | days (int, seit 1970-01-01) |
| `0x54` (`T`) | **Time** | nanoseconds (int), tz_offset_seconds (int) |
| `0x74` (`t`) | **LocalTime** | nanoseconds (int) |
| `0x49` (`I`) | **DateTime** | seconds (int), nanoseconds (int), tz_offset_seconds (int) |
| `0x64` (`d`) | **LocalDateTime** | seconds (int), nanoseconds (int) |
| `0x45` (`E`) | **Duration** | months, days, seconds, nanoseconds |
| `0x58` (`X`) | **Point2D** | srid (int), x (float), y (float) |
| `0x59` (`Y`) | **Point3D** | srid (int), x (float), y (float), z (float) |

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | TCP, Chunk-Framing, Version-Negotiation, PackStream | NJ-01 – NJ-02 |
| 2 | Bolt-Handshake, Auth, NJConn | NJ-03 – NJ-04 |
| 3 | RUN + PULL, Result-Set, Accessoren | NJ-05 – NJ-06 |
| 4 | Graph-Typen (Node, Relationship, Path) | NJ-07 |
| 5 | Transaktionen, Parameter-Builder, Utilities | NJ-08 – NJ-09 |
| 6 | Demos & Tests | NJ-10 |

---

## Work Packages

---

### WP-NJ-01: TCP, Chunk-Framing & Bolt-Handshake ⬜

**Ziel:** Rohe TCP-Verbindung aufbauen, das Bolt-Chunk-Framing implementieren
und die Versionsnegotiation durchführen.

**Zu implementieren:**

- TCP-Verbindung (wie mysql.lyu): `sys_socket`, `sys_connect`, IPv4-Parser
- **Magic Preamble** senden (4 Bytes): `60 60 B0 17`
- **Versionsnegotiation**: 16 Bytes senden (4 Versionsvorschläge):
  ```
  [00 04 05 00]  Bolt 5.4
  [00 04 04 00]  Bolt 4.4
  [00 03 04 00]  Bolt 4.3
  [00 00 00 00]  kein weiterer Vorschlag
  ```
  Server antwortet mit 4 Bytes (gewählte Version); `00 00 00 00` = kein Protokoll gemeinsam
- **Chunk-Framing** — Senden:
  ```
  njChunkSend(fd, msg, msgLen)
    → zerlegt in Chunks ≤ 65535 Bytes
    → schreibt je: [uint16 BE chunkSize][payload]
    → schreibt am Ende: [00 00]
  ```
- **Chunk-Framing** — Empfangen:
  ```
  njChunkRecv(fd, outBuf) → int64 (gesamte Nachrichtenlänge)
    → liest Chunks bis [00 00] aufeinander
    → reassembliert in outBuf
  ```
- Interne Buffer-Verwaltung: `NJMsgBuf { buf=int64; cap=int64; len=int64 }`
  mit dynamischem Wachstum (mmap + munmap)
- Hilfsfunktionen: `writeUint16BE`, `readUint16BE` (für Chunk-Größen)

**Dateien:**
- `std/db/neo4j.lyu` (Abschnitt: TCP + Framing)

**Akzeptanzkriterien:**
- TCP-Verbindung zu localhost:7687 öffnet erfolgreich
- Server bestätigt Versionsnegotiation mit `00 04 05 00` oder `00 04 04 00`
- `njChunkSend` + `njChunkRecv` transferieren beliebig große Nachrichten korrekt
- Nachricht > 65535 Bytes: korrekt in mehrere Chunks zerlegt und reassembliert

---

### WP-NJ-02: PackStream Encoder & Decoder ⬜

**Ziel:** Den vollständigen PackStream-En-/Decoder implementieren — das Herz
der Bibliothek, auf dem alle Nachrichten und Ergebnisse aufbauen.

**Zu implementieren:**

**Encoder** (`psEncode*`-Familie, schreibt in NJMsgBuf):
- `psEncodeNull(buf)`
- `psEncodeBool(buf, v)`
- `psEncodeInt(buf, v)` — wählt automatisch TinyInt / Int8 / Int16 / Int32 / Int64
- `psEncodeFloat(buf, v)` — 0xC1 + 8 Bytes IEEE 754 BE
- `psEncodeStr(buf, s)` — wählt TinyString / String8 / String16 / String32
- `psEncodeBytes(buf, ptr, len)` — Bytes8 / Bytes16 / Bytes32
- `psEncodeListBegin(buf, n)` — wählt TinyList / List8 / List16
- `psEncodeDictBegin(buf, n)` — wählt TinyDict / Dict8 / Dict16
- `psEncodeStructBegin(buf, n_fields, signature)` — TinyStruct (0xBn + sig)
- Kein explizites ListEnd/DictEnd nötig (Länge ist fest vorgegeben)

**Decoder** (`psDecode*`-Familie, liest aus Byte-Array mit Offset-Pointer):
- `psDecodeType(buf, off) → int64` — liest Marker-Byte, gibt PS_TYPE_* zurück:
  ```
  PS_TYPE_NULL    PS_TYPE_BOOL    PS_TYPE_INT     PS_TYPE_FLOAT
  PS_TYPE_BYTES   PS_TYPE_STRING  PS_TYPE_LIST    PS_TYPE_DICT
  PS_TYPE_STRUCT
  ```
- `psDecodeNull(buf, off)` — konsumiert 1 Byte
- `psDecodeBool(buf, off) → bool`
- `psDecodeInt(buf, off) → int64` — alle Int-Varianten
- `psDecodeFloat(buf, off) → f64`
- `psDecodeStr(buf, off) → pchar` — gibt heap-kopierten String zurück
- `psDecodeStrLen(buf, off) → int64` — String-Länge ohne Kopie
- `psDecodeStrPtr(buf, off) → int64` — zeigt direkt in den Buffer (kein Alloc)
- `psDecodeListSize(buf, off) → int64` — Anzahl Elemente
- `psDecodeDictSize(buf, off) → int64` — Anzahl Einträge
- `psDecodeStructFields(buf, off) → int64` — Anzahl Felder
- `psDecodeStructSig(buf, off) → int64` — Signature-Byte
- `psSkipValue(buf, off)` — überspringt einen kompletten Wert (inklusive rekursiv)

**Interne Offset-Verwaltung:**
Alle Decode-Funktionen bekommen einen `off`-Pointer (int64*) und rücken ihn
nach jedem gelesenen Wert weiter.

**Dateien:**
- `std/db/neo4j.lyu` (Abschnitt: PackStream)

**Akzeptanzkriterien:**
- Encode + Decode Roundtrip für alle Typen: null, bool, int(-16..127, -128..127, int32, int64), float, string (leer, 1 Byte, 15 Byte, 16 Byte, 256 Byte), list, dict
- `psEncodeInt(0)` → `0x00`; `psEncodeInt(127)` → `0x7F`; `psEncodeInt(-1)` → `0xFF`;
  `psEncodeInt(128)` → `0xC9 0x00 0x80`
- `psEncodeStr("hello")` → `0x85` + `68 65 6C 6C 6F`
- Leere Dict → `0xA0`; Dict mit 1 Eintrag `{"a": 1}` → `0xA1 0x81 0x61 0x01`
- `psSkipValue` überspringt nested Dicts/Lists korrekt

---

### WP-NJ-03: Bolt-Nachrichten & HELLO/Auth ⬜

**Ziel:** Die Bolt-Nachrichtenschicht aufbauen: Senden und Empfangen aller
Nachrichten, HELLO-Handshake und Authentifizierung.

**Zu implementieren:**

- Internes Nachricht-Senden `njSendMsg(fd, signature, …)`:
  - baut PackStream-Struct in NJMsgBuf
  - übergibt an `njChunkSend`
- Internes Nachricht-Empfangen `njRecvMsg(fd, outBuf) → int64 (signature)`:
  - ruft `njChunkRecv` auf
  - liest Struct-Header (TinyStruct + Signature)
  - gibt Signature zurück; Body verbleibt in outBuf ab Offset 2
- **HELLO** (0x01) aufbauen und senden:
  ```lyx
  // Bolt 4.x: Auth direkt in HELLO
  HELLO {
    "scheme":      "basic",
    "principal":   <user>,
    "credentials": <password>,
    "bolt_agent":  { "product": "lyx/1.0" }
  }
  ```
- Response-Dispatch:
  - `SUCCESS` (0x70) → Metadaten parsen (server_version, hints, connection_id)
  - `FAILURE` (0x7F) → Fehlercode + Nachricht aus dict `{"code":…,"message":…}` lesen
  - `IGNORED` (0x7E) → unerwartete Antwort, Connection-Reset
- Nach Fehler: **RESET** (0x0F) senden → `SUCCESS` abwarten (Zustandsreset)
- **GOODBYE** (0x02) senden beim Schließen
- Bolt 5.1+: Separates **LOGON** (0x6A) für Auth nach HELLO

**Dateien:**
- `std/db/neo4j.lyu` (Abschnitt: Bolt-Nachrichten)

**Akzeptanzkriterien:**
- HELLO mit korrekten Credentials → SUCCESS
- HELLO mit falschem Passwort → FAILURE, Fehlertext `Neo.ClientError.Security.Unauthorized`
- Nach FAILURE: RESET → SUCCESS (Verbindung wieder nutzbar)
- `server_version` aus SUCCESS-Metadaten korrekt gelesen (z. B. `"Neo4j/5.15.0"`)

---

### WP-NJ-04: NJConn-Typ & NJConnect/Close ⬜

**Ziel:** Den öffentlichen `NJConn`-Struct und die primären
Verbindungsfunktionen implementieren.

**Zu implementieren:**

- Struct `NJConn` (per `mmap`):
  ```
  NJConn {
    fd=int64; host=pchar; port=int64
    user=pchar; password=pchar
    bolt_version_major=int64; bolt_version_minor=int64
    server_version=pchar          // z. B. "Neo4j/5.15.0"
    connection_id=pchar           // aus HELLO-SUCCESS
    status=int64                  // NJ_STATUS_DISCONNECTED / CONNECTED / TX
    last_errcode=pchar            // Neo4j BOLT-Error-Code (String, z. B. "Neo.ClientError.…")
    errmsg=pchar
    in_tx=bool
    send_buf=int64                // NJMsgBuf* für ausgehende Frames
    recv_buf=int64                // NJMsgBuf* für empfangene Frames
    last_bookmark=pchar           // für kausale Konsistenz
  }
  ```
- Statuskonstanten: `NJ_STATUS_DISCONNECTED`, `NJ_STATUS_CONNECTED`, `NJ_STATUS_TX`
- `NJConnect(host, port, user, password) → int64`
  — TCP + Handshake + HELLO; gibt NJConn-Ptr zurück (0 = Fehler)
- `NJConnectDB(host, port, user, password, database) → int64`
  — wie NJConnect, speichert database-Name für alle RUN-Nachrichten
- `NJClose(conn) → void` — sendet GOODBYE, schließt fd, gibt Speicher frei
- `NJError(conn) → pchar` — Fehlermeldung der letzten Operation
- `NJErrorCode(conn) → pchar` — Neo4j-Fehlercode, z. B. `"Neo.ClientError.Schema.ConstraintValidationFailed"`
- `NJIsConnected(conn) → bool`
- `NJReset(conn) → bool` — sendet RESET (für Fehler-Recovery)
- `NJServerVersion(conn) → pchar`

**Dateien:**
- `std/db/neo4j.lyu`

**Akzeptanzkriterien:**
- `NJConnect` + `NJClose` ohne Fehler
- `NJConnect` auf falschem Port → 0, `NJError` hat Text
- `NJServerVersion` gibt nicht-leeren String zurück
- `NJReset` nach Fehler-Zustand: Connection wieder nutzbar

---

### WP-NJ-05: RUN + PULL — Simple Query ⬜

**Ziel:** Cypher-Statements ausführen und alle Antworttypen korrekt parsen.

**Zu implementieren:**

- `NJRun(conn, cypher, params, extra) → int64`
  — sendet RUN + PULL:
  ```
  1. RUN: struct{0x10}(cypher_str, params_dict, extra_dict)
     extra_dict: {"db":"neo4j"} oder {} wenn kein DB-Name gesetzt
  2. Empfang: SUCCESS mit fields-Metadaten → Feldnamen extrahieren
  3. PULL: struct{0x3F}({"n":-1})
  4. Empfang: RECORD* → Zeilen sammeln; abschließend SUCCESS mit summary
  5. Bei FAILURE nach RUN: RESET senden; 0 zurückgeben
  ```
  Gibt NJResult-Ptr zurück (0 = Fehler)
- `NJRunSize(conn, cypher, params, page_size) → int64`
  — wie NJRun, aber `PULL {"n": page_size}` statt `-1`
- `NJResult`-Struct (per `mmap`):
  ```
  NJResult {
    field_count=int64
    field_names=int64       // Array pchar* (aus RUN-SUCCESS-Metadaten)
    row_count=int64
    rows=int64              // Array NJRow*
    rows_alloc=int64
    current_row=int64       // Cursor für NJFetchRow
    has_more=bool           // PULL mit n < -1, Server signalisiert weitere Rows
    summary=int64           // NJSummary* (type, stats, bookmark)
    field_buf=int64         // String-Heap für Feldnamen
    value_buf=int64         // String-Heap für String-Werte
  }
  ```
- `NJRow`-Struct:
  ```
  NJRow { values=int64; types=int64; count=int64 }
  ```
  `values`: Array NJValue*; `types`: Array int64 (PS_TYPE_*)
- `NJValue`-Union:
  ```
  NJValue {
    int_val=int64; float_val=f64; str_val=pchar
    bool_val=bool; is_null=bool
    blob_ptr=int64; blob_len=int64
    node_ptr=int64          // NJNode* wenn PS_TYPE_STRUCT + sig 0x4E
    rel_ptr=int64           // NJRelationship* wenn sig 0x52
    path_ptr=int64          // NJPath* wenn sig 0x50
  }
  ```
- `NJSummary`-Struct:
  ```
  NJSummary {
    query_type=pchar         // "r", "w", "rw", "s"
    bookmark=pchar
    nodes_created=int64; nodes_deleted=int64
    rels_created=int64;  rels_deleted=int64
    properties_set=int64
    time_ms=int64            // "time" aus profile/summary
  }
  ```
- `NJFreeResult(result) → void`

**Dateien:**
- `std/db/neo4j.lyu`

**Akzeptanzkriterien:**
- `NJRun(conn, "RETURN 1 AS n", 0, 0)` → 1 Zeile, 1 Feld `"n"` mit Wert 1
- `NJRun(conn, "MATCH (n) RETURN n LIMIT 0", 0, 0)` → 0 Zeilen, kein Absturz
- Syntax-Fehler in Cypher → 0 zurück, `NJErrorCode` enthält `"Neo.ClientError.Statement.SyntaxError"`
- `NJFreeResult` gibt Speicher frei
- `NJSummary.nodes_created` nach `CREATE (n:Test)` = 1

---

### WP-NJ-06: Result-Set Accessoren ⬜

**Ziel:** Ergonomische Funktionen zum Traversieren und Lesen von Ergebniszeilen.

**Zu implementieren:**

- `NJFetchRow(result) → bool` — Cursor auf nächste Zeile
- `NJNumRows(result) → int64`
- `NJNumCols(result) → int64`
- `NJGetColName(result, col) → pchar`
- **Einfache Typ-Accessoren** (0-basierter Spaltenindex):
  - `NJGetInt(result, col) → int64` — für Integer
  - `NJGetFloat(result, col) → f64` — für Float
  - `NJGetStr(result, col) → pchar` — für String (und alle anderen Typen als String)
  - `NJGetBool(result, col) → bool` — für Boolean
  - `NJGetBlob(result, col, outLen) → int64` — für Bytes
  - `NJIsNull(result, col) → bool`
  - `NJGetType(result, col) → int64` — PS_TYPE_* des Werts
- **Graph-Typ-Checker** (für Dispatch vor NJGetNode/NJGetRel/NJGetPath):
  - `NJIsNode(result, col) → bool` — Struct-Sig 0x4E
  - `NJIsRel(result, col) → bool` — Struct-Sig 0x52
  - `NJIsPath(result, col) → bool` — Struct-Sig 0x50
  - `NJIsDate(result, col) → bool` — Struct-Sig 0x44
- `NJDataSeek(result, row)` — Cursor an beliebige Zeile

**Dateien:**
- `std/db/neo4j.lyu`

**Akzeptanzkriterien:**
- `RETURN 42, 3.14, "hello", true, null` → korrekte Werte je Accessor
- `NJIsNull` gibt true für die null-Spalte zurück
- `NJGetStr` für Integer-Spalte konvertiert korrekt zu String
- `NJGetType` gibt PS_TYPE_INT für Integer-Wert zurück

---

### WP-NJ-07: Graph-Typen (Node, Relationship, Path) ⬜

**Ziel:** Die Neo4j-spezifischen PackStream-Strukturen zu ergonomischen Lyx-Typen
deserialisieren und mit Accessoren ausstatten.

**Zu implementieren:**

**NJNode:**
- Struct `NJNode`:
  ```
  NJNode {
    id=int64; element_id=pchar
    labels=int64; label_count=int64   // Array pchar*
    props=int64; prop_count=int64     // Array NJProp*
  }
  ```
- `NJGetNode(result, col) → int64` — gibt NJNode-Ptr zurück (oder 0 wenn kein Node)
- `NJNodeId(node) → int64`
- `NJNodeLabelCount(node) → int64`
- `NJNodeGetLabel(node, i) → pchar`
- `NJNodeHasLabel(node, label) → bool`
- `NJNodeGetStr(node, key) → pchar`
- `NJNodeGetInt(node, key) → int64`
- `NJNodeGetFloat(node, key) → f64`
- `NJNodeGetBool(node, key) → bool`
- `NJNodeIsNull(node, key) → bool`
- `NJNodeHasProp(node, key) → bool`
- `NJNodePropCount(node) → int64`
- `NJNodeGetPropName(node, i) → pchar`

**NJRelationship:**
- Struct `NJRelationship`:
  ```
  NJRel {
    id=int64; element_id=pchar
    start_id=int64; end_id=int64
    start_element_id=pchar; end_element_id=pchar
    rel_type=pchar
    props=int64; prop_count=int64
  }
  ```
- `NJGetRel(result, col) → int64`
- `NJRelId(rel) → int64`
- `NJRelType(rel) → pchar`
- `NJRelStartId(rel) → int64`
- `NJRelEndId(rel) → int64`
- `NJRelGetStr(rel, key) → pchar`
- `NJRelGetInt(rel, key) → int64`
- `NJRelGetFloat(rel, key) → f64`
- `NJRelHasProp(rel, key) → bool`

**NJPath:**
- Struct `NJPath`:
  ```
  NJPath {
    node_count=int64; nodes=int64       // Array NJNode*
    rel_count=int64;  rels=int64        // Array NJRel* (unbound)
    sequence=int64; sequence_len=int64  // Array int64: alternierend rel-idx/node-idx
  }
  ```
- `NJGetPath(result, col) → int64`
- `NJPathLength(path) → int64` — Anzahl Relationships
- `NJPathNode(path, i) → int64` — i-ter Node (0 = Startknoten)
- `NJPathRel(path, i) → int64` — i-te Relationship

**Temporale Typen (Deserialisierung):**
- `NJGetDate(result, col) → int64` — Tage seit 1970-01-01 als int64
- `NJGetTimestamp(result, col) → int64` — Sekunden seit Epoch (aus DateTime)
- `NJGetDurationMs(result, col) → int64` — Näherung: months×30×24×3600×1000 + …

**Dateien:**
- `std/db/neo4j.lyu`

**Akzeptanzkriterien:**
- `CREATE (p:Person {name:"Alice",age:30}) RETURN p` → `NJGetNode` → `NJNodeGetStr(node,"name") == "Alice"`, `NJNodeHasLabel(node,"Person") == true`
- `MATCH (a)-[r:KNOWS]->(b) RETURN r` → `NJGetRel` → `NJRelType(rel) == "KNOWS"`
- `MATCH p=()-[:KNOWS]->() RETURN p` → `NJGetPath` → `NJPathLength ≥ 1`
- `NJNodePropCount` stimmt mit Anzahl gesetzter Properties überein

---

### WP-NJ-08: Transaktionen ⬜

**Ziel:** Explizite Transaktionsverwaltung mit BEGIN/COMMIT/ROLLBACK und
kausaler Konsistenz via Bookmarks.

**Zu implementieren:**

- `NJBegin(conn) → bool`
  — sendet BEGIN `{}` → erwartet SUCCESS
- `NJBeginDB(conn, database) → bool`
  — BEGIN `{"db": <database>}`
- `NJBeginReadOnly(conn) → bool`
  — BEGIN `{"mode": "r"}`
- `NJCommit(conn) → bool`
  — sendet COMMIT → erwartet SUCCESS; extrahiert Bookmark aus Metadaten
  → speichert in `conn.last_bookmark`
- `NJRollback(conn) → bool`
  — sendet ROLLBACK → erwartet SUCCESS
- `NJInTransaction(conn) → bool`
  — gibt `conn.in_tx` zurück
- Innerhalb einer Transaktion: RUN/PULL funktionieren identisch (Bolt verwaltet
  den TX-Zustand serverseitig; keine Änderung am RUN-Protokoll nötig)
- `NJRunTx(conn, cypher, params) → int64`
  — Kurzform: BEGIN + RUN + PULL + COMMIT (für einfache atomare Operationen)
- **Bookmarks** (kausale Konsistenz):
  - `NJGetLastBookmark(conn) → pchar`
  - `NJBeginWithBookmarks(conn, bookmarks_json) → bool`
    — BEGIN `{"bookmarks": [...]}`

**Dateien:**
- `std/db/neo4j.lyu`

**Akzeptanzkriterien:**
- BEGIN + 3× RUN (CREATE) + COMMIT: alle 3 Nodes in der DB
- BEGIN + CREATE + ROLLBACK: 0 neue Nodes in der DB
- `NJInTransaction` gibt true nach BEGIN, false nach COMMIT zurück
- Bookmark nach COMMIT ist non-null und nicht leer
- `NJBeginWithBookmarks` mit letztem Bookmark: Reads sehen vorherige Writes

---

### WP-NJ-09: Parameter-Builder & Cypher-Utilities ⬜

**Ziel:** Einen ergonomischen Parameter-Builder für Cypher-Queries implementieren
und häufige Graph-Operationen als Convenience-Funktionen anbieten.

**Zu implementieren:**

**Parameter-Builder:**
- `NJParamNew() → int64` — legt NJParams-Struct an (per `mmap`)
- `NJParamFree(params) → void`
- `NJParamSetStr(params, key, value) → void`
- `NJParamSetInt(params, key, value) → void`
- `NJParamSetFloat(params, key, value) → void`
- `NJParamSetBool(params, key, value) → void`
- `NJParamSetNull(params, key) → void`
- `NJParamSetList(params, key, json_array) → void`
  — nimmt JSON-Array-String, konvertiert zu PackStream-List
- Interne Funktion `njParamsToPackStream(params, buf)` — serialisiert alle
  Key-Value-Paare als PackStream-Dict

**Shortcut-Konstruktoren:**
- `NJParams1Str(k1, v1) → int64`
- `NJParams2Str(k1, v1, k2, v2) → int64`
- `NJParams1Int(k1, v1) → int64`
- `NJParams2Int(k1, v1, k2, v2) → int64`

**Graph-Utilities:**
- `NJCreateNode(conn, label, params) → int64`
  — `CREATE (n:<label> $props) RETURN n` → gibt NJNode zurück
- `NJMergeNode(conn, label, match_params, set_params) → int64`
  — `MERGE (n:<label> $match) ON CREATE SET n += $set RETURN n`
- `NJDeleteNode(conn, element_id) → bool`
  — `MATCH (n) WHERE elementId(n) = $id DETACH DELETE n`
- `NJCreateRel(conn, from_id, to_id, rel_type, params) → int64`
  — `MATCH (a),(b) WHERE elementId(a)=$a AND elementId(b)=$b CREATE (a)-[r:<type> $props]->(b) RETURN r`
- `NJNodeCount(conn, label) → int64`
  — `MATCH (n:<label>) RETURN count(n)`
- `NJDropAllNodes(conn) → bool`
  — `MATCH (n) DETACH DELETE n` (für Tests)

**Dateien:**
- `std/db/neo4j.lyu`

**Akzeptanzkriterien:**
- `NJParamNew` + `NJParamSetStr` + `NJParamSetInt` + `NJRun` fügt korrekte Properties ein
- `NJParams2Str("name","Alice","city","Berlin")` → beide Properties korrekt
- `NJCreateNode` gibt validen NJNode-Ptr zurück
- `NJNodeCount` stimmt mit `CREATE` + `COUNT(n)` überein
- `NJDropAllNodes` + `NJNodeCount` → 0

---

### WP-NJ-10: Demos & Integrationstests ⬜

**Ziel:** Vollständige Beispielprogramme für alle Features als Regressionsbasis
und Showcase der Graph-Mächtigkeit.

**Demo 1 — CRUD-Grundlagen** (`demo_nj_crud.lyx`):
```lyx
// Node anlegen, lesen, Properties aktualisieren, löschen
// MATCH (n:Person {name:$name}) RETURN n
// Alle Properties ausgeben
```

**Demo 2 — Beziehungen & Traversal** (`demo_nj_graph.lyx`):
```lyx
// Personen-Graph: Alice KNOWS Bob KNOWS Carol
// MATCH (a:Person)-[:KNOWS*1..3]->(b) WHERE a.name="Alice" RETURN b.name
// Alle erreichbaren Personen + Hop-Distanz ausgeben
```

**Demo 3 — Transaktionen** (`demo_nj_tx.lyx`):
```lyx
// BEGIN → 5x CREATE → COMMIT
// BEGIN → CREATE → ROLLBACK → Verifizieren: kein Rollback-Node
// Bookmark-Weitergabe demonstrieren
```

**Demo 4 — Kürzester Pfad** (`demo_nj_path.lyx`):
```lyx
// Graph mit 10 Nodes + Edges aufbauen
// MATCH p = shortestPath((a)-[*]-(b)) WHERE a.name=$start AND b.name=$end RETURN p
// Alle Nodes und Beziehungen des Pfads ausgeben
```

**Demo 5 — Parameter-Builder & Batch-Create** (`demo_nj_batch.lyx`):
```lyx
// 1000 Nodes per Transaktion (100 pro RUN via UNWIND) anlegen
// Timing: einzelne RUNs vs. UNWIND-Batch
// UNWIND $rows AS row CREATE (n:Item) SET n = row
```

**Demo 6 — Aggregation & Projektion** (`demo_nj_agg.lyx`):
```lyx
// MATCH (p:Person) RETURN p.city AS city, count(*) AS cnt ORDER BY cnt DESC
// Top-5-Städte mit Personenanzahl ausgeben
// NJGetStr + NJGetInt pro Zeile
```

**Dateien:**
- `demo_nj_crud.lyx`
- `demo_nj_graph.lyx`
- `demo_nj_tx.lyx`
- `demo_nj_path.lyx`
- `demo_nj_batch.lyx`
- `demo_nj_agg.lyx`

**Akzeptanzkriterien:**
- Alle 6 Demos kompilieren und laufen fehlerfrei gegen Neo4j 5.x
- Demo 2: korrekte Traversal-Ergebnisse für bekannten Testgraph
- Demo 3: exakt 0 Rollback-Nodes nach Rollback
- Demo 5: UNWIND-Batch ≥ 5× schneller als 1000 Einzel-CREATEs

---

## Abhängigkeiten

| Abhängigkeit | Quelle | Notiz |
|-------------|--------|-------|
| `std/io` | Lyx stdlib | PrintStr, PrintInt in Demos |
| `std/alloc` | Lyx stdlib | mmap-basierte Struct-Allokation |
| Neo4j ≥ 5.0 | System | Nur Ziel-Server; Bolt 4.4 für 4.x-Kompatibilität |

---

## Offene Fragen

- **Bolt 5.1 LOGON:** Neuere Neo4j-Versionen trennen Auth vom HELLO-Handshake.
  Initialer Scope: Bolt 4.4 mit Auth in HELLO; LOGON als optionale Erweiterung?
- **TLS:** Neo4j unterstützt TLS auf Port 7687 (und dediziert auf 7688).
  `std/net/tls` wäre die Basis — optionales WP?
- **Routing (Cluster):** Bolt-ROUTE-Nachricht (0x66) ermöglicht Auto-Discovery
  der Cluster-Mitglieder. Für Single-Node-Setups nicht nötig — separates WP?
- **Reaktives Streaming (Bolt 4.0):** `PULL {"n": 100, "qid": X}` mit expliziter
  Query-ID erlaubt parallele Ergebnisströme. Für einfachen Client: qid=−1
  (aktuellste Query) ausreichend?
- **Neo4j Aura (Cloud):** Verbindet sich über `neo4j+s://` (immer TLS +
  Bolt-Routing). Abhängig von TLS-WP.
- **UNWIND-Batch-Größe:** Cassandra hat BATCH, Neo4j nutzt `UNWIND $list AS row`
  für Massen-Inserts. Soll ein `NJUnwindCreate`-Utility in NJ-09 aufgenommen werden?
