# Lyx Elasticsearch-Bibliothek (`std/db/elasticsearch`) — Fahrplan

Dieses Dokument beschreibt den vollständigen Entwicklungsplan für
`std/db/elasticsearch`, die offizielle Elasticsearch-Standardbibliothek von Lyx.
Ziel ist ein vollständiger Elasticsearch-Client — aufgebaut auf den bestehenden
Units `std/net/http` und `std/json`, ohne externe Abhängigkeiten.

**Konvention:** WP-ES-NN (Elasticsearch, Nummer). Status-Symbole: ✅ Erledigt,
🔄 In Arbeit, ⬜ Offen.

---

## Vision

```lyx
import std.io;
import std.db.elasticsearch;

pub fn main(): int64 {
  var es: int64 := ESConnect("127.0.0.1", 9200, "elastic", "secret");

  ESIndexCreate(es, "products", "{\"mappings\":{\"properties\":{\"name\":{\"type\":\"text\"},\"price\":{\"type\":\"float\"}}}}");

  ESDocIndex(es, "products", "1", "{\"name\":\"Widget\",\"price\":9.99}");
  ESDocIndex(es, "products", "2", "{\"name\":\"Gadget\",\"price\":24.99}");
  ESDocIndex(es, "products", "3", "{\"name\":\"Widget Pro\",\"price\":49.99}");

  ESIndexRefresh(es, "products");

  var q: pchar := ESQueryMatch("name", "Widget");
  var result: int64 := ESSearch(es, "products", q);

  PrintStr("Treffer: ");
  PrintInt(ESNumHits(result));
  PrintStr("\n");

  var i: int64 := 0;
  while (i < ESNumHits(result)) {
    PrintStr(ESGetHitId(result, i));
    PrintStr(": ");
    PrintStr(ESGetHitSource(result, i));
    PrintStr("\n");
    i := i + 1;
  }

  ESFreeResult(result);
  ESClose(es);
  return 0;
}
```

`std/db/elasticsearch` soll sich so ergonomisch anfühlen wie `std/db/mysql` —
die REST/JSON-Komplexität von Elasticsearch vollständig hinter einer klaren
API kapseln.

---

## Architektur-Überblick

```
┌──────────────────────────────────────────────────────────────┐
│        std/db/elasticsearch.lyu  (public API)                │
│  ESConnect · ESSearch · ESDocIndex · ESBulkFlush · …         │
└──────────────┬───────────────────────────┬───────────────────┘
               │                           │
┌──────────────▼──────────────┐  ┌─────────▼─────────────────┐
│     std/net/http(.lyu)      │  │     std/json(.lyu)         │
│  HTTPRequestBuild · HTTPSend │  │  stringify · parseValue    │
│  HTTP_GET/POST/PUT/DELETE   │  │  JSONEscape · toArray      │
└──────────────┬──────────────┘  └─────────────────────────────┘
               │
┌──────────────▼──────────────┐
│      TCP/IP · Port 9200     │
│   (oder 9243 via HTTPS)     │
└─────────────────────────────┘
```

### Unterschied zu mysql/postgres

| Aspekt | mysql/postgres | elasticsearch |
|--------|---------------|---------------|
| Protokoll | Eigenes TCP-Binärprotokoll | REST/HTTP + JSON |
| Transport | Rohes Lesen/Schreiben | `std/net/http` |
| Datenformat | Binär / Text-Rows | JSON-Dokumente |
| Schema | Starr (DDL) | Dynamisch (Mappings) |
| Query-Sprache | SQL | Query DSL (JSON) |
| Skalierung | Vertikal | Horizontal (Sharding) |
| Basis-Port | 3306 / 5432 | 9200 |

### Datei-Überblick

```
std/db/
  elasticsearch.lyu    ← öffentliche API
  elasticsearch.lyx    ← kompilierte Unit
```

---

## Elasticsearch REST-API — Übersicht

### URL-Konventionen

```
GET  /_cluster/health                      Cluster-Status
GET  /_cat/indices?format=json             Index-Liste
PUT  /<index>                              Index anlegen
DELETE /<index>                            Index löschen
HEAD /<index>                              Index existiert?
POST /<index>/_refresh                     Index aktualisieren

PUT  /<index>/_doc/<id>                    Dokument indizieren (mit ID)
POST /<index>/_doc                         Dokument indizieren (Auto-ID)
GET  /<index>/_doc/<id>                    Dokument lesen
DELETE /<index>/_doc/<id>                  Dokument löschen
POST /<index>/_update/<id>                 Dokument aktualisieren
HEAD /<index>/_doc/<id>                    Dokument existiert?

POST /<index>/_search                      Suchen
POST /<index>/_count                       Zählen
POST /_bulk                                Bulk-Operationen
POST /<index>/_delete_by_query             Löschen per Query
POST /<index>/_update_by_query             Aktualisieren per Query
POST /_search/scroll                       Scroll fortsetzen
DELETE /_search/scroll                     Scroll beenden
```

### Auth-Header

```
Basic Auth:   Authorization: Basic base64(user:password)
API Key:      Authorization: ApiKey base64(id:api_key)
Bearer Token: Authorization: Bearer <token>
```

### Wichtige HTTP-Statuscodes

```
200 OK              Anfrage erfolgreich
201 Created         Dokument erstellt
204 No Content      Erfolgreich ohne Body (z. B. DELETE)
400 Bad Request     Ungültige Query (z. B. JSON-Fehler)
401 Unauthorized    Falsche Auth-Credentials
403 Forbidden       Keine Berechtigung
404 Not Found       Index oder Dokument existiert nicht
409 Conflict        Versionskonfli kt (optimistic locking)
429 Too Many Reqs   Rate-Limit / Überlast
503 Unavailable     Cluster nicht verfügbar
```

### Query DSL — Überblick

```json
{
  "query": {
    "bool": {
      "must":     [{ "match": { "name": "Widget" } }],
      "filter":   [{ "range": { "price": { "gte": 5.0, "lte": 50.0 } } }],
      "must_not": [{ "term":  { "status": "discontinued" } }],
      "should":   [{ "match": { "tags": "sale" } }]
    }
  },
  "sort":  [{ "price": { "order": "asc" } }],
  "from":  0,
  "size":  10,
  "aggs": {
    "price_stats": { "stats": { "field": "price" } }
  }
}
```

---

## Phasen

| Phase | Inhalt | WPs |
|-------|--------|-----|
| 1 | HTTP-Transport, Auth, ESConn, Cluster-Info | ES-01 – ES-02 |
| 2 | Index-Management | ES-03 |
| 3 | Dokument-CRUD | ES-04 |
| 4 | Search API, Result-Typ, Query-Builder | ES-05 – ES-06 |
| 5 | Bulk API & Aggregationen | ES-07 – ES-08 |
| 6 | Scroll API, Demos & Tests | ES-09 – ES-10 |

---

## Work Packages

---

### WP-ES-01: HTTP-Transport & Auth-Layer ⬜

**Ziel:** Einen schlanken internen HTTP-Wrapper um `std/net/http` legen, der
alle ES-spezifischen Anforderungen (Auth-Header, Content-Type, JSON-Body,
Port-Konfiguration) kapselt.

**Zu implementieren:**

- `ESConn`-Struct (per `mmap`):
  ```
  ESConn {
    host=pchar; port=int64
    auth_header=pchar        // vollständiger "Authorization: …"-Header
    auth_type=int64          // ES_AUTH_NONE / BASIC / APIKEY / BEARER
    last_status=int64        // HTTP-Statuscode der letzten Anfrage
    last_error=pchar         // Fehlermeldung (aus ES-Error-JSON)
    use_https=bool
  }
  ```
- Auth-Konstanten: `ES_AUTH_NONE`, `ES_AUTH_BASIC`, `ES_AUTH_APIKEY`, `ES_AUTH_BEARER`
- Interne Hilfsfunktionen (nicht öffentlich):
  - `esGet(conn, path) → pchar` — HTTP GET, gibt Response-Body zurück (oder 0)
  - `esPost(conn, path, body) → pchar` — HTTP POST mit JSON-Body
  - `esPut(conn, path, body) → pchar` — HTTP PUT mit JSON-Body
  - `esDelete(conn, path) → pchar` — HTTP DELETE
  - `esHead(conn, path) → int64` — HTTP HEAD, gibt nur Statuscode zurück
  - `esBuildRequest(conn, method, path, body, bodyLen) → HTTPRequest*`
    — setzt Host, Port, Content-Type: application/json, Auth-Header
  - `esParseError(body) → pchar` — extrahiert `error.reason` aus ES-Error-JSON
- Base64-Encoding für Auth (inline, da `std/base64` vorhanden):
  ```
  Basic: base64(user + ":" + password)
  ApiKey: base64(id + ":" + api_key)
  ```

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- `esGet(conn, "/")` auf laufendem ES gibt JSON-Body zurück (cluster_name etc.)
- Auth-Header wird korrekt gesetzt: `Authorization: Basic dXNlcjpwYXNz`
- `esParseError` extrahiert `"reason"` aus `{"error":{"reason":"index not found"}}`
- HTTP 401 → `last_error` enthält Fehlertext, Rückgabe 0

---

### WP-ES-02: ESConnect / ESClose & Cluster-Info ⬜

**Ziel:** Öffentliche Verbindungsfunktionen und grundlegende Cluster-Abfragen
implementieren.

**Zu implementieren:**

- `ESConnect(host, port, user, password) → int64`
  — legt ESConn an, setzt Basic-Auth, gibt Ptr zurück (oder 0 bei Fehler)
- `ESConnectApiKey(host, port, key_id, api_key) → int64`
  — wie ESConnect, aber mit API-Key-Auth
- `ESConnectBearer(host, port, token) → int64`
  — wie ESConnect, aber mit Bearer-Token
- `ESConnectNoAuth(host, port) → int64`
  — ohne Auth (für lokale Dev-Instanzen)
- `ESClose(conn) → void` — gibt ESConn-Speicher frei
- `ESIsConnected(conn) → bool` — gibt true wenn letzter Request erfolgreich war
- `ESLastStatus(conn) → int64` — HTTP-Statuscode der letzten Operation
- `ESLastError(conn) → pchar` — Fehlermeldung der letzten Operation
- `ESPing(conn) → bool` — `GET /`, prüft ob ES erreichbar und Auth korrekt
- `ESClusterHealth(conn) → pchar` — `GET /_cluster/health`, gibt raw JSON zurück
- `ESClusterStatus(conn) → pchar` — extrahiert `"status"` aus Cluster-Health
  (`"green"` / `"yellow"` / `"red"`)
- `ESServerVersion(conn) → pchar` — extrahiert `version.number` aus `GET /`

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- `ESPing` gibt true für erreichbares ES zurück
- `ESPing` gibt false für falsches Passwort zurück, `ESLastError` hat Text
- `ESClusterStatus` gibt `"green"` oder `"yellow"` zurück (nicht leer)
- `ESServerVersion` gibt z. B. `"8.12.0"` zurück

---

### WP-ES-03: Index-Management ⬜

**Ziel:** Vollständiges Lifecycle-Management für Elasticsearch-Indizes.

**Zu implementieren:**

- `ESIndexCreate(conn, index, settings_json) → bool`
  — `PUT /<index>` mit optionalem JSON-Body (Mappings, Settings);
  `settings_json` darf 0 (leer) sein → minimaler Index
- `ESIndexDelete(conn, index) → bool` — `DELETE /<index>`
- `ESIndexExists(conn, index) → bool` — `HEAD /<index>` → 200 oder 404
- `ESIndexRefresh(conn, index) → bool`
  — `POST /<index>/_refresh` (macht neue Docs sofort suchbar)
- `ESIndexFlush(conn, index) → bool` — `POST /<index>/_flush`
- `ESIndexStats(conn, index) → pchar` — `GET /<index>/_stats`, raw JSON
- `ESIndexDocCount(conn, index) → int64`
  — `GET /<index>/_count`, extrahiert `"count"`
- `ESIndexMapping(conn, index) → pchar`
  — `GET /<index>/_mapping`, raw JSON
- `ESPutMapping(conn, index, mapping_json) → bool`
  — `PUT /<index>/_mapping` (Mapping erweitern)
- `ESListIndices(conn) → pchar`
  — `GET /_cat/indices?format=json&h=index,docs.count,store.size`, raw JSON

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- `ESIndexCreate` + `ESIndexExists` → true
- `ESIndexDelete` + `ESIndexExists` → false
- `ESIndexCreate` mit ungültigem Mapping-JSON → false, Fehlertext vorhanden
- `ESIndexDocCount` nach 3 Inserts + Refresh → 3

---

### WP-ES-04: Dokument-CRUD ⬜

**Ziel:** Vollständige Dokument-Operationen: Indizieren, Lesen, Aktualisieren,
Löschen.

**Zu implementieren:**

- `ESDocIndex(conn, index, id, json) → bool`
  — `PUT /<index>/_doc/<id>` (Dokument anlegen oder ersetzen)
- `ESDocIndexAuto(conn, index, json) → pchar`
  — `POST /<index>/_doc` (Auto-ID), gibt generierte ID zurück (oder 0)
- `ESDocGet(conn, index, id) → pchar`
  — `GET /<index>/_doc/<id>`, gibt `_source`-JSON zurück (oder 0 wenn 404)
- `ESDocGetFull(conn, index, id) → pchar`
  — wie ESDocGet, aber gibt kompletten Response inkl. `_id`, `_version` zurück
- `ESDocDelete(conn, index, id) → bool`
  — `DELETE /<index>/_doc/<id>`
- `ESDocExists(conn, index, id) → bool`
  — `HEAD /<index>/_doc/<id>` → 200 oder 404
- `ESDocUpdate(conn, index, id, fields_json) → bool`
  — `POST /<index>/_update/<id>` mit Body `{"doc": <fields_json>}`
- `ESDocUpsert(conn, index, id, json) → bool`
  — wie ESDocUpdate, aber mit `"doc_as_upsert": true`
- `ESDocVersion(conn, index, id) → int64`
  — `_version`-Feld aus `ESDocGetFull` extrahieren
- Interne Hilfsfunktion: `esExtractSource(response_json) → pchar`
  — extrahiert `_source` aus GET-Response-JSON

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- `ESDocIndex` + `ESDocGet` gibt denselben JSON-String zurück
- `ESDocExists` gibt false für nicht existierende ID zurück
- `ESDocDelete` + `ESDocExists` → false
- `ESDocUpdate` ändert nur angegebene Felder, andere bleiben unverändert
  (per `ESDocGet` verifiziert)
- `ESDocIndexAuto` gibt non-null ID zurück

---

### WP-ES-05: Search API & ESResult-Typ ⬜

**Ziel:** Die primäre Such-API implementieren und den `ESResult`-Typ für
strukturierten Zugriff auf Trefferlisten aufbauen.

**Zu implementieren:**

- `ESSearch(conn, index, query_json) → int64`
  — `POST /<index>/_search` mit Query-JSON-Body; gibt ESResult-Ptr zurück
- `ESSearchAll(conn, index) → int64`
  — Shortcut: `{"query":{"match_all":{}}}` — gibt alle Docs zurück (bis `size` 10)
- `ESSearchSize(conn, index, query_json, from, size) → int64`
  — wie ESSearch, fügt `"from"` und `"size"` in den Body ein
- `ESCount(conn, index, query_json) → int64`
  — `POST /<index>/_count`, gibt `"count"` zurück (oder -1 bei Fehler)
- `ESDeleteByQuery(conn, index, query_json) → int64`
  — `POST /<index>/_delete_by_query`, gibt Anzahl gelöschter Docs zurück
- `ESResult`-Struct (per `mmap`):
  ```
  ESResult {
    total=int64          // "hits.total.value"
    hits_count=int64     // Anzahl geladener Hits (≤ total)
    took_ms=int64        // "took"
    timed_out=bool       // "timed_out"
    hits=int64           // Array ESHit*
    hits_alloc=int64
    scroll_id=pchar      // "_scroll_id" falls vorhanden
    aggs_json=pchar      // "aggregations"-Block als raw JSON (oder 0)
  }
  ```
- `ESHit`-Struct:
  ```
  ESHit {
    id=pchar; index=pchar
    score=f64            // "_score"
    source=pchar         // "_source" als raw JSON-String
    version=int64        // "_version" falls mitgeliefert
  }
  ```
- `ESFreeResult(result) → void`
- Interner Parser: `esParseSearchResponse(body) → ESResult*`
  — parst `hits.hits[]` aus JSON-Response

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- `ESSearchAll` auf 3-Doc-Index gibt `ESNumHits == 3` zurück
- `ESSearch` mit passender Match-Query gibt korrekte Trefferzahl zurück
- `ESCount` stimmt mit `ESNumHits` überein (für dieselbe Query)
- `ESFreeResult` gibt Speicher frei (kein Leak)
- `took_ms` ist > 0

---

### WP-ES-06: Result-Accessoren & Query-Builder ⬜

**Ziel:** Ergonomische Accessoren für ESResult sowie einen schlanken
Query-DSL-Builder, der JSON-Strings erzeugt.

**Zu implementieren:**

**Result-Accessoren:**
- `ESNumHits(result) → int64`
- `ESGetTotal(result) → int64` — Gesamttreffer (kann > ESNumHits sein)
- `ESGetHitId(result, i) → pchar`
- `ESGetHitSource(result, i) → pchar` — `_source` als raw JSON
- `ESGetHitScore(result, i) → f64`
- `ESGetHitIndex(result, i) → pchar`
- `ESGetTook(result) → int64` — Antwortzeit in ms
- `ESTimedOut(result) → bool`
- `ESGetScrollId(result) → pchar`

**Query-Builder** (geben heap-allokierte JSON-Strings zurück):
- `ESQueryMatchAll() → pchar`
  → `{"query":{"match_all":{}}}`
- `ESQueryMatch(field, value) → pchar`
  → `{"query":{"match":{<field>:<value>}}}`
- `ESQueryMatchPhrase(field, value) → pchar`
  → `{"query":{"match_phrase":{<field>:<value>}}}`
- `ESQueryTerm(field, value) → pchar`
  → `{"query":{"term":{<field>:{"value":<value>}}}}`
- `ESQueryTerms(field, values_json) → pchar`
  → `{"query":{"terms":{<field>:[...]}}}`
- `ESQueryRange(field, gte_json, lte_json) → pchar`
  → `{"query":{"range":{<field>:{"gte":…,"lte":…}}}}`
  (`gte_json`/`lte_json` dürfen 0 sein → Feld wird weggelassen)
- `ESQueryBool(must, should, must_not, filter) → pchar`
  — kombiniert bis zu 4 optionale Klauseln; 0-Parameter werden weggelassen
- `ESQueryWithSort(query_json, field, order) → pchar`
  — ergänzt `"sort":[{<field>:{"order":<order>}}]` in bestehende Query
- `ESQueryWithPagination(query_json, from, size) → pchar`
  — ergänzt `"from"` + `"size"` in bestehende Query
- `ESFreeQuery(query_json) → void` — gibt heap-allokierten String frei

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- `ESQueryMatch("name", "Widget")` liefert valides JSON (via `isValidJSON`)
- `ESQueryBool` mit 2 must-Klauseln und 0 für should/must_not/filter
  erzeugt JSON ohne leere Arrays
- `ESQueryWithSort` + `ESQueryWithPagination` können gekettet werden
- Alle Query-Builder-Ergebnisse lassen sich direkt an `ESSearch` übergeben

---

### WP-ES-07: Bulk API ⬜

**Ziel:** Hochperformante Massenoperationen über die Elasticsearch Bulk API.

**Zu implementieren:**

- Interne Struktur `ESBulkCtx`:
  ```
  ESBulkCtx {
    conn=int64
    buf=int64        // mmap-Buffer für NDJSON-Body
    buf_len=int64
    buf_alloc=int64
    op_count=int64
  }
  ```
- `ESBulkBegin(conn) → int64` — legt ESBulkCtx an
- `ESBulkIndex(ctx, index, id, json) → void`
  — fügt dem Buffer hinzu:
  ```
  {"index":{"_index":"<index>","_id":"<id>"}}\n
  <json>\n
  ```
  Bei `id == 0`: ohne `"_id"` (Auto-ID)
- `ESBulkCreate(ctx, index, id, json) → void` — wie ESBulkIndex, aber `"create"`
  (schlägt fehl wenn Dokument bereits existiert)
- `ESBulkDelete(ctx, index, id) → void`
  — fügt hinzu: `{"delete":{"_index":"<index>","_id":"<id>"}}\n`
- `ESBulkUpdate(ctx, index, id, json) → void`
  — fügt hinzu:
  ```
  {"update":{"_index":"<index>","_id":"<id>"}}\n
  {"doc":<json>}\n
  ```
- `ESBulkFlush(ctx) → int64`
  — sendet `POST /_bulk` mit `Content-Type: application/x-ndjson`,
  gibt ESBulkResult-Ptr zurück
- `ESBulkReset(ctx) → void` — leert Buffer ohne ESBulkCtx freizugeben
  (für mehrfaches Flush in einer Schleife)
- `ESBulkFree(ctx) → void` — gibt ESBulkCtx frei
- `ESBulkResult`-Struct:
  ```
  ESBulkResult {
    took_ms=int64
    has_errors=bool
    indexed=int64     // Erfolgreiche Index-Ops
    deleted=int64     // Erfolgreiche Delete-Ops
    errors=int64      // Anzahl Fehler
    error_json=pchar  // Erster Fehler-Detail-String (oder 0)
  }
  ```
- `ESBulkFreeResult(result) → void`

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- 10.000 Docs per Bulk (1.000 pro Flush-Aufruf) sind nachweislich schneller
  als 10.000 Einzel-`ESDocIndex`-Aufrufe
- `ESBulkResult.has_errors == false` für valide Operationen
- `ESBulkCreate` für existierende ID → `has_errors == true`, `errors == 1`
- `ESBulkReset` ermöglicht korrektes zweites Flush desselben ESBulkCtx

---

### WP-ES-08: Aggregationen ⬜

**Ziel:** Aggregations-Builder und Result-Accessoren für die häufigsten
Aggregationstypen implementieren.

**Zu implementieren:**

**Aggregations-Builder** (geben heap-allokierten JSON-Snippet zurück,
der in `ESQueryWithAgg` eingebaut wird):
- `ESAggTerms(name, field, size) → pchar`
  → `"<name>":{"terms":{"field":"<field>","size":<size>}}`
- `ESAggStats(name, field) → pchar`
  → `"<name>":{"stats":{"field":"<field>"}}`
- `ESAggAvg(name, field) → pchar`
- `ESAggSum(name, field) → pchar`
- `ESAggMin(name, field) → pchar`
- `ESAggMax(name, field) → pchar`
- `ESAggDateHistogram(name, field, calendar_interval) → pchar`
  → `"<name>":{"date_histogram":{"field":"<field>","calendar_interval":"<interval>"}}`
  Mögliche Intervalle: `"day"`, `"week"`, `"month"`, `"year"`
- `ESAggValueCount(name, field) → pchar`

**Query-Kombination:**
- `ESQueryWithAgg(query_json, agg_snippet) → pchar`
  — fügt `"aggs":{<agg_snippet>}` in bestehende Query ein
- `ESQueryWithMultiAgg(query_json, agg1, agg2) → pchar`
  — kombiniert zwei Agg-Snippets

**Result-Accessoren:**
- `ESGetAgg(result, name) → pchar` — gibt Raw-JSON des Aggregationsergebnisses zurück
- `ESAggBucketCount(agg_json) → int64` — Anzahl Buckets in `"buckets"`-Array
- `ESAggBucketKey(agg_json, i) → pchar` — Key des i-ten Buckets
- `ESAggBucketDocCount(agg_json, i) → int64` — `doc_count` des i-ten Buckets
- `ESAggValue(agg_json) → f64` — `"value"` für Metriken (avg, sum, min, max)
- `ESAggStatsMin(agg_json) → f64` — `"min"` aus Stats-Ergebnis
- `ESAggStatsMax(agg_json) → f64`
- `ESAggStatsAvg(agg_json) → f64`
- `ESAggStatsSum(agg_json) → f64`
- `ESAggStatsCount(agg_json) → int64`

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- Terms-Aggregation über 3 verschiedene Werte → `ESAggBucketCount == 3`
- Avg-Aggregation über `[1.0, 2.0, 3.0]` → `ESAggValue ≈ 2.0`
- Date-Histogram über 10 Docs in 2 Tagen → 2 Buckets
- `ESQueryWithAgg` + `ESSearch` produziert auswertbares Ergebnis

---

### WP-ES-09: Scroll API (große Ergebnismengen) ⬜

**Ziel:** Den Elasticsearch Scroll-Mechanismus implementieren, um mehr als
`size`-Treffer (Default: 10) seitenweise auszulesen — ohne Datenverlust bei
Indexänderungen.

**Zu implementieren:**

- `ESSearchScroll(conn, index, query_json, size, keep_alive) → int64`
  — `POST /<index>/_search?scroll=<keep_alive>` (z. B. `"1m"`)
  mit `"size": <size>` im Body; gibt ESResult zurück (enthält `scroll_id`)
- `ESScrollNext(conn, scroll_id, keep_alive) → int64`
  — `POST /_search/scroll` mit Body `{"scroll":"<keep_alive>","scroll_id":"<id>"}`
  gibt nächste ESResult-Seite zurück; `ESNumHits == 0` → Ende erreicht
- `ESScrollClear(conn, scroll_id) → bool`
  — `DELETE /_search/scroll` mit Body `{"scroll_id":"<id>"}` — gibt Server-Ressourcen frei
- Convenience-Iterator-Muster:
  ```lyx
  var result: int64 := ESSearchScroll(es, "logs", q, 1000, "1m");
  while (ESNumHits(result) > 0) {
    // Zeilen verarbeiten...
    var sid: pchar := ESGetScrollId(result);
    ESFreeResult(result);
    result := ESScrollNext(es, sid, "1m");
  }
  ESScrollClear(es, ESGetScrollId(result));
  ESFreeResult(result);
  ```
- `ESGetScrollId(result) → pchar` — aus ESResult (bereits in WP-05 im Struct)

**Dateien:**
- `std/db/elasticsearch.lyu`

**Akzeptanzkriterien:**
- 100 Docs mit `size=10`: Scroll-Schleife liefert exakt 10 Iterationen, gesamt 100 Docs
- `ESScrollClear` schlägt keinen Fehler (Scroll-Kontext auf Server entfernt)
- `ESScrollNext` nach letzter Seite gibt `ESNumHits == 0` zurück (kein Absturz)
- Scroll-ID unterscheidet sich zwischen ersten und zweiten `ESScrollNext`-Aufruf

---

### WP-ES-10: Demos & Integrationstests ⬜

**Ziel:** Vollständige Beispielprogramme, die alle Features praxisnah abdecken
und als Regressionsbasis dienen.

**Demo 1 — CRUD-Grundlagen** (`demo_es_crud.lyx`):
```lyx
// Index anlegen, 5 Docs einfügen, Refresh, Search, Update, Delete
// Gibt alle Treffer mit ID und Source aus
```

**Demo 2 — Query-Builder** (`demo_es_query.lyx`):
```lyx
// Match, Term, Range, Bool-Kombinationen
// Sortierung + Paginierung
// Gibt Trefferzahl und erste 3 Hits aus
```

**Demo 3 — Bulk-Import** (`demo_es_bulk.lyx`):
```lyx
// 10.000 Docs als 10× 1.000er-Bulk einfügen
// Timing: Bulk vs. Einzel-Index ausgeben
```

**Demo 4 — Aggregationen** (`demo_es_agg.lyx`):
```lyx
// Produktkatalog: Terms-Agg auf Kategorie, Stats-Agg auf Preis
// Alle Bucket-Keys + doc_count ausgeben
// Avg/Min/Max Preis ausgeben
```

**Demo 5 — Scroll über großen Datensatz** (`demo_es_scroll.lyx`):
```lyx
// 5.000 Docs einfügen, per Scroll mit size=100 auslesen
// Gesamtzahl verifizieren, Scroll korrekt schließen
```

**Demo 6 — Auth-Varianten** (`demo_es_auth.lyx`):
```lyx
// ESConnectNoAuth, ESConnectApiKey, ESConnectBearer
// Jede Variante: Ping + ClusterStatus ausgeben
```

**Dateien:**
- `demo_es_crud.lyx`
- `demo_es_query.lyx`
- `demo_es_bulk.lyx`
- `demo_es_agg.lyx`
- `demo_es_scroll.lyx`
- `demo_es_auth.lyx`

**Akzeptanzkriterien:**
- Alle 6 Demos kompilieren und laufen fehlerfrei gegen lokales ES 8.x
- Demo 3: Bulk ≥ 5× schneller als Einzel-Index
- Demo 5: exakt 5.000 Docs gezählt

---

## Abhängigkeiten

| Abhängigkeit | Quelle | Notiz |
|-------------|--------|-------|
| `std/net/http` | Lyx stdlib | HTTP GET/POST/PUT/DELETE/HEAD |
| `std/json` | Lyx stdlib | JSON serialisieren + parsen |
| `std/base64` | Lyx stdlib | Auth-Header kodieren |
| `std/io` | Lyx stdlib | PrintStr, PrintInt in Demos |
| `std/alloc` | Lyx stdlib | mmap-basierte Struct-Allokation |
| Elasticsearch ≥ 7.x | System | Nur Ziel-Server — kein C-Header |

---

## Offene Fragen

- **HTTPS:** `std/net/https.lyu` ist vorhanden — `ESConnectTLS`-Variante als
  einfacher Wrapper? Relevant für Cloud-ES (Elastic Cloud, AWS OpenSearch).
- **Elasticsearch 8 vs. 7:** In ES 8 ist Security by Default aktiviert (HTTPS + Auth).
  Sollen beide Versionen explizit unterstützt werden oder nur 8.x?
- **OpenSearch-Kompatibilität:** AWS OpenSearch ist ein ES-7-Fork mit weitgehend
  identischer REST-API — sollte ohne Änderungen funktionieren. Explizit testen?
- **Query-Builder-Tiefe:** Der Builder erzeugt einfache Flat-JSON-Strings per
  String-Konkatenation. Für komplexe verschachtelte Queries ist das fragil —
  besser ein DOM-basierter Builder (auf `std/json` aufgebaut)?
- **Index-Templates / ILM:** Für Production-Setups relevant (automatisches
  Rollover, Hot-Warm-Cold) — separates WP oder außerhalb des Scope?
