# std/graphdb — Arbeitspakete

## Architektur-Kurzreferenz

```
[std/hash]  [std/string]  [std/fs]  [std/zlib]
     │            │           │          │
     └────────────┴───────────┴──────────┘
                        │
              [std/graphdb/core]        ← WP-GRP-01
                   │        │
     [graphdb/node]          [graphdb/edge]
       WP-GRP-02               WP-GRP-03
              │                    │
              └────────┬───────────┘
                       │
              [graphdb/mem]            ← WP-GRP-04
                       │
              [graphdb/index]          ← WP-GRP-05
                       │
         ┌─────────────┼─────────────┐
  [graphdb/file]       │       [graphdb/query]
   WP-GRP-06          WP-GRP-07
```

**Kern-Invarianten (gelten für alle WPs):**
- IDs sind `int64`, positiv, `0` = ungültig.
- Timestamps sind `int64` (Unix-Millisekunden).
- Strings werden immer als `pchar` + `int64`-Länge übergeben — nie null-terminated verlassen.
- Alle Klassen-Pointer werden als `int64` übergeben (Lyx-Konvention: `&obj` = Adresse).
- Maximal 6 Parameter pro Funktion (7-Arg-Bug). Bei Bedarf Context-Struct.
- Kein `free` auf Intermediate-Buffern — Lifetime liegt beim Aufrufer.

---

## WP-Übersicht

| WP | Titel | Abhängt von | Datei |
|---|---|---|---|
| WP-GRP-01 | Core (ID, Timestamp, Hilfsfunktionen) | std/hash, std/string | `std/graphdb/core.lyx` |
| WP-GRP-02 | GraphNode + TLV-Properties + Vektor | WP-GRP-01 | `std/graphdb/node.lyx` |
| WP-GRP-03 | GraphEdge + TLV-Properties | WP-GRP-01 | `std/graphdb/edge.lyx` |
| WP-GRP-04 | In-Memory-Store | WP-GRP-02, WP-GRP-03 | `std/graphdb/mem.lyx` |
| WP-GRP-05 | TemporalIndex + TypeIndex + VectorIndex | WP-GRP-04 | `std/graphdb/index.lyx` |
| WP-GRP-06 | Datei-Persistenz (Binärformat) | WP-GRP-04, std/fs, std/zlib | `std/graphdb/file.lyx` |
| WP-GRP-07 | Query-API | WP-GRP-04, WP-GRP-05 | `std/graphdb/query.lyx` |

---

---

# WP-GRP-01: Core

## Ziel

Basis-Konstanten, ID-Erzeugung und Timestamp-Funktionen, die von allen anderen GraphDB-Units benötigt werden. Keine eigenen Datenstrukturen — reine Hilfsfunktionen.

## Abhängigkeiten

- `std/hash` — FNV-1a für `GraphIDFromStr`
- `std/string` — `StrLen`, `StrCharAt`
- Syscall `clock_gettime` (SYS_clock_gettime = 228, CLOCK_REALTIME = 0) für `GraphNow`

## Nicht im Umfang

- UUID-Generierung — v2
- kryptografische IDs — v2

## Wichtige Hinweise

- `GraphNow()` gibt Unix-Millisekunden zurück. Intern: `sec * 1000 + nsec / 1_000_000`. Die nsec-Division mit negativem Zwischenwert vermeiden (Lyx-Division-Bug bei negativen Werten — hier kein Problem da Syscall-Return positiv).
- `GraphIDFromStr` muss für gleiche Eingabe deterministisch sein. FNV-1a Seed = `0xCBF29CE484222325`.
- Rückgabe-ID muss positiv sein: falls FNV-1a-Ergebnis negativ (Bit 63 gesetzt), Bit 63 maskieren: `result & 0x7FFFFFFFFFFFFFFF`.

## Zu implementierende Symbole

```lyx
pub con GRAPH_ID_INVALID: int64 := 0;

pub fn GraphNow(): int64
    // clock_gettime → sec*1000 + nsec/1_000_000

pub fn GraphIDFromStr(s: pchar, slen: int64): int64
    // FNV-1a Hash, Ergebnis & 0x7FFFFFFFFFFFFFFF

pub fn GraphIDNew(): int64
    // GraphNow() XOR pseudo-random (einfacher LCG reicht für v1)
```

## Abnahmekriterien

- [ ] `GraphNow()` gibt einen Wert > 0 zurück und wächst bei zwei aufeinanderfolgenden Aufrufen.
- [ ] `GraphIDFromStr("alice"c, 5)` gibt bei zwei Aufrufen denselben Wert zurück.
- [ ] `GraphIDFromStr("alice"c, 5) != GraphIDFromStr("bob"c, 3)`.
- [ ] `GraphIDNew()` gibt bei zwei Aufrufen (in derselben ms) unterschiedliche Werte zurück.
- [ ] Alle Rückgaben > 0 (kein `GRAPH_ID_INVALID`).
- [ ] Unit kompiliert ohne Fehler mit Stage-2-Build.

---

---

# WP-GRP-02: GraphNode

## Ziel

Datenstruktur für einen Graph-Knoten mit festen Feldern (ID, Labels), dynamischen Properties (TLV-Byte-Buffer) und optionalem Embedding-Vektor (f64-Array als Byte-Buffer).

## Abhängigkeiten

- WP-GRP-01 (core)
- `std/string` — `StrCharAt`, `StrSetChar`, `StrLen`
- `alloc`, `memcpy` (builtins)

## Nicht im Umfang

- Typsicherheit der Properties zur Laufzeit — Aufrufer trägt Verantwortung.
- Labels mit Duplikat-Erkennung — v2.
- Vektor-Normalisierung — liegt beim Aufrufer.

## Wichtige Hinweise

**TLV-Properties-Format** (Byte-Layout im `propsBuf`):
```
[type:1][keyLen:1][key:keyLen][value: je nach type]
  type 0 = int64  → 8 Byte Value
  type 1 = pchar  → 4 Byte Länge (int32 little-endian) + N Byte Daten
  type 2 = f64    → 8 Byte (IEEE-754, als int64 mit `as int64` gespeichert)
  type 3 = bool   → 1 Byte (0 oder 1)
```

**Labels** werden als `\0`-separierter `pchar`-Buffer gespeichert:
```
"Person\0User\0" → labelsCount = 2
```
Kein Pointer-Array nötig; Iteration via linearem Scan bis `labelsLen`.

**Vektor** (`vecBuf`): Raw-f64-Buffer. Zugriff auf Dimension `i`:
```lyx
var bits: int64 := peek64(n.vecBuf + i * 8);
var val: f64 := bits as f64;
```

**7-Arg-Bug**: `GraphNodeSetStr` hätte 6 Parameter (self, key, klen, val, vlen) — genau an der Grenze. Einen Parameter als Context-Struct kapseln falls der Bug auftritt.

## Zu implementierende Symbole

```lyx
class GraphNode {
    id:          int64;
    labelsBuf:   int64;    // pchar-Buffer (als int64)
    labelsLen:   int64;    // belegte Bytes
    labelsCap:   int64;
    labelsCount: int64;
    propsBuf:    int64;    // TLV-Buffer (als int64)
    propsLen:    int64;
    propsCap:    int64;
    vecBuf:      int64;    // f64-Array (als int64), NULL = kein Vektor
    vecDims:     int64;
}

pub fn GraphNodeInit(n: int64)
pub fn GraphNodeFree(n: int64)

pub fn GraphNodeAddLabel(n: int64, label: pchar, llen: int64)
pub fn GraphNodeHasLabel(n: int64, label: pchar, llen: int64): int64   // 1/0

pub fn GraphNodeSetInt(n: int64, key: pchar, klen: int64, val: int64)
pub fn GraphNodeSetStr(n: int64, key: pchar, klen: int64, val: pchar, vlen: int64)
pub fn GraphNodeSetF64(n: int64, key: pchar, klen: int64, val: f64)
pub fn GraphNodeSetBool(n: int64, key: pchar, klen: int64, val: int64)

pub fn GraphNodeGetInt(n: int64, key: pchar, klen: int64): int64   // 0 = nicht gefunden
pub fn GraphNodeGetStr(n: int64, key: pchar, klen: int64, outLen: int64): pchar
pub fn GraphNodeGetF64(n: int64, key: pchar, klen: int64): f64

pub fn GraphNodeSetVec(n: int64, dims: int64, data: int64)  // data = f64-Buffer
pub fn GraphNodeGetVecDim(n: int64, i: int64): f64
```

## Abnahmekriterien

- [ ] `GraphNodeInit` + `GraphNodeFree` ohne Crash (valgrind-äquivalent: kein SIGSEGV).
- [ ] Label hinzufügen + `GraphNodeHasLabel` gibt 1 zurück; unbekanntes Label gibt 0.
- [ ] `GraphNodeSetInt("age"c, 3, 42)` → `GraphNodeGetInt("age"c, 3)` gibt 42 zurück.
- [ ] `GraphNodeSetStr("name"c, 4, "Alice"c, 5)` → `GraphNodeGetStr` gibt "Alice" zurück.
- [ ] `GraphNodeSetF64("score"c, 5, 0.95)` → `GraphNodeGetF64` gibt 0.95 zurück (exakt, da IEEE-754 round-trip).
- [ ] Zwei verschiedene Properties koexistieren im Buffer (kein Überschreiben).
- [ ] `GraphNodeSetVec(3, buf)` → `GraphNodeGetVecDim(1)` gibt korrekten f64-Wert zurück.
- [ ] Buffer wächst korrekt wenn `propsCap` überschritten wird (Realloc-Test: 100 Properties setzen).

---

---

# WP-GRP-03: GraphEdge

## Ziel

Datenstruktur für eine gerichtete Kante mit Pflicht-Feldern (ID, source, target, edgeType, createdAt) und optionalen Properties (TLV-Format wie bei GraphNode).

## Abhängigkeiten

- WP-GRP-01 (core)
- `std/string`
- `alloc`, `memcpy`

## Nicht im Umfang

- Ungerichtete Kanten — v2 (per Konvention zwei Kanten entgegengesetzt).
- Kanten-Gewicht als Sonderfeld — über Properties abbilden (`key="weight"`, type f64).

## Wichtige Hinweise

- `edgeType` wird als `pchar` + `int64`-Länge **kopiert** in einen eigenen Buffer — der Aufrufer darf seinen String-Buffer danach freigeben.
- `createdAt` ist Pflicht. Empfehlung: Aufrufer setzt immer `GraphNow()`. Wert `0` = ungültig, Store lehnt die Kante ab (Validierung in WP-GRP-04).
- TLV-Properties: exakt gleiche Implementierung wie in `node.lyx` — Code kann als separate Hilfsfunktionen in `core.lyx` ausgelagert werden um Dopplung zu vermeiden.

## Zu implementierende Symbole

```lyx
class GraphEdge {
    id:          int64;
    source:      int64;    // Node-ID
    target:      int64;    // Node-ID
    edgeTypeBuf: int64;    // kopierter pchar-Buffer
    edgeTypeLen: int64;
    createdAt:   int64;    // Timestamp (Pflicht, != 0)
    propsBuf:    int64;
    propsLen:    int64;
    propsCap:    int64;
}

pub fn GraphEdgeInit(e: int64)
pub fn GraphEdgeFree(e: int64)
pub fn GraphEdgeSetType(e: int64, etype: pchar, elen: int64)
pub fn GraphEdgeTypeEq(e: int64, etype: pchar, elen: int64): int64   // 1/0

// Properties: gleiche Signaturen wie GraphNode
pub fn GraphEdgeSetInt(e: int64, key: pchar, klen: int64, val: int64)
pub fn GraphEdgeSetStr(e: int64, key: pchar, klen: int64, val: pchar, vlen: int64)
pub fn GraphEdgeGetInt(e: int64, key: pchar, klen: int64): int64
pub fn GraphEdgeGetStr(e: int64, key: pchar, klen: int64, outLen: int64): pchar
```

## Abnahmekriterien

- [ ] `GraphEdgeInit` + `GraphEdgeSetType("KNOWS"c, 5)` → `GraphEdgeTypeEq("KNOWS"c, 5)` = 1.
- [ ] `GraphEdgeTypeEq("PRODUCED"c, 8)` = 0 (anderer Typ).
- [ ] `createdAt` nach `GraphEdgeInit` = 0; Aufrufer setzt es auf `GraphNow()`.
- [ ] Properties-Round-Trip wie bei GraphNode (Int, Str, F64).
- [ ] `GraphEdgeFree` gibt Buffers frei ohne Crash.

---

---

# WP-GRP-04: In-Memory-Store

## Ziel

Zentraler Laufzeit-Speicher für Nodes und Edges mit Adjazenz-Listen für Graph-Traversierung. Kein Persistenz, keine Indizes (die kommen in WP-GRP-05 und WP-GRP-06).

## Abhängigkeiten

- WP-GRP-02 (node)
- WP-GRP-03 (edge)
- `std/hash` — für O(1)-Lookup von Node/Edge per ID
- `alloc`, `memcpy`

## Nicht im Umfang

- Thread-Safety — v2.
- Transaktionen / MVCC — v2.
- Capacity-Limits oder Eviction — v2 (im RAM bis zum OS-Limit).

## Wichtige Hinweise

**ID → Pointer Lookup**: Zwei parallele `int64`-Arrays (`ids[]` + `ptrs[]`). Für v1 reicht linearer Scan (bis ~10k Nodes kein Problem). Für v2: `std/hash`-basierte Hash-Map.

**Adjazenz-Listen**: Flacher `int64`-Buffer mit Einträgen `[nodeId:8][edgeId:8]`. Pro Node alle ausgehenden Kanten. Bei Traversierung linear über alle Einträge scannen und `nodeId` filtern. Alternativ: sortiert nach `nodeId` + Binärsuche.

**Validierung beim Add**:
- `GraphMemStoreAddNode`: `n.id != 0`, Node-ID noch nicht vorhanden.
- `GraphMemStoreAddEdge`: `e.id != 0`, `e.createdAt != 0`, source/target-IDs existieren im Store.

**Rückgabe-Konvention**: Pointer-Funktionen geben `0` zurück wenn nicht gefunden (nie null-deref im Aufrufer prüfen).

## Zu implementierende Symbole

```lyx
class GraphMemStore {
    nodeIds:   int64;    // int64-Array
    nodePtrs:  int64;    // int64-Array (Pointer auf GraphNode)
    nodeCount: int64;
    nodeCap:   int64;

    edgeIds:   int64;
    edgePtrs:  int64;
    edgeCount: int64;
    edgeCap:   int64;

    adjBuf:    int64;    // [nodeId:8][edgeId:8] Paare
    adjCount:  int64;
    adjCap:    int64;
}

pub fn GraphMemStoreInit(s: int64)
pub fn GraphMemStoreFree(s: int64)

pub fn GraphMemStoreAddNode(s: int64, n: int64): int64   // 1=ok, 0=fehler
pub fn GraphMemStoreAddEdge(s: int64, e: int64): int64   // 1=ok, 0=fehler

pub fn GraphMemStoreGetNode(s: int64, id: int64): int64  // Pointer oder 0
pub fn GraphMemStoreGetEdge(s: int64, id: int64): int64  // Pointer oder 0

// Gibt Edge-IDs zurück, die von nodeId ausgehen (outBuf = int64-Array, gibt Anzahl zurück)
pub fn GraphMemStoreOutEdges(s: int64, nodeId: int64, outBuf: int64, maxOut: int64): int64

// Traversierung: Nachbar-Node-IDs über ausgehende Kanten
pub fn GraphMemStoreNeighbors(s: int64, nodeId: int64, outBuf: int64, maxOut: int64): int64
```

## Abnahmekriterien

- [ ] Node hinzufügen → `GraphMemStoreGetNode` gibt denselben Pointer zurück.
- [ ] Doppelte Node-ID → `GraphMemStoreAddNode` gibt 0 zurück.
- [ ] Edge ohne gültiges `createdAt` → `GraphMemStoreAddEdge` gibt 0 zurück.
- [ ] Edge ohne existierende source-ID → `GraphMemStoreAddEdge` gibt 0 zurück.
- [ ] `GraphMemStoreOutEdges(s, nodeId, buf, 10)` gibt korrekte Kanten-IDs zurück.
- [ ] `GraphMemStoreNeighbors` für Dreieck (A→B, B→C, A→C) gibt korrekte Nachbarn.
- [ ] Store mit 1000 Nodes + 5000 Edges: kein SIGSEGV, korrekte Lookups.
- [ ] `GraphMemStoreFree` gibt alle Buffers frei.

---

---

# WP-GRP-05: Indizes

## Ziel

Drei spezialisierte Indizes für performante Abfragen: zeitbasiert (TemporalIndex), nach Kantentyp (TypeIndex), semantisch per Vektor-Ähnlichkeit (VectorIndex).

## Abhängigkeiten

- WP-GRP-04 (mem) — Index baut auf Store-Daten auf
- WP-GRP-02 (node) — VectorIndex liest `vecBuf`
- `std/string`

## Nicht im Umfang

- Automatische Index-Aktualisierung bei Store-Mutationen — v1 baut Index explizit per `GraphXxxIndexBuild`. Aufrufer ruft nach Bulk-Insert erneut auf.
- B-Tree — v1 nutzt sortierte Arrays + Binärsuche.
- HNSW / ANN für VectorIndex — v1 nutzt linearen Scan (exakt, aber O(n)).

## Wichtige Hinweise

**TemporalIndex**: Sortiertes `int64`-Pärchen-Array `[timestamp | edgeId]` (je 16 Byte pro Eintrag). Aufbau: alle Edges aus dem Store iterieren, nach `createdAt` sortieren (Insertion-Sort für v1, reicht bis ~50k Edges). Zeitfenster-Query: Binärsuche auf `timestamp`.

**TypeIndex**: Pro bekanntem `edgeType` eine verkettete Liste von Edge-IDs. In v1: linearer Scan über alle Edges beim Build. Speicherung als Array von `[typeHash:8][edgeId:8]`-Paaren, sortiert nach typeHash.

**VectorIndex**: Flat-Matrix aller Nodes mit Vektor. Layout: `[nodeId:8][dim0:8][dim1:8]...[dimN-1:8]` pro Eintrag. Kosinus-Ähnlichkeit:
```
sim(a,b) = dot(a,b) / (|a| * |b|)
```
f64-Arithmetik, kein SIMD in v1.

**`VectorCosineSim` und f64**: `peek64(buf + i*8) as f64` für Lesen; Schreiben: `poke64(buf + i*8, val as int64)`.

## Zu implementierende Symbole

```lyx
class GraphTemporalIndex {
    entries:  int64;   // [timestamp:8][edgeId:8] Paare
    count:    int64;
    cap:      int64;
}

pub fn GraphTemporalIndexInit(idx: int64)
pub fn GraphTemporalIndexBuild(idx: int64, store: int64)
pub fn GraphTemporalIndexQuery(idx: int64, tsFrom: int64, tsTo: int64,
                                outBuf: int64, maxOut: int64): int64

class GraphTypeIndex {
    entries: int64;    // [typeHash:8][edgeId:8] Paare
    count:   int64;
    cap:     int64;
}

pub fn GraphTypeIndexInit(idx: int64)
pub fn GraphTypeIndexBuild(idx: int64, store: int64)
pub fn GraphTypeIndexQuery(idx: int64, etype: pchar, elen: int64,
                            outBuf: int64, maxOut: int64): int64

class GraphVectorIndex {
    dims:     int64;
    entries:  int64;   // [nodeId:8][f64*dims] pro Eintrag
    count:    int64;
    cap:      int64;
}

pub fn GraphVectorIndexInit(idx: int64, dims: int64)
pub fn GraphVectorIndexBuild(idx: int64, store: int64)
pub fn GraphVectorIndexSearch(idx: int64, queryVec: int64, topK: int64,
                               outNodeIds: int64, outScores: int64): int64
```

## Abnahmekriterien

- [ ] `GraphTemporalIndexBuild` + Query für Zeitfenster [t1, t2] gibt nur Edges mit `createdAt` im Fenster zurück.
- [ ] Query mit `tsFrom > tsTo` gibt 0 Ergebnisse (kein Crash).
- [ ] `GraphTypeIndexQuery("KNOWS"c, 5)` gibt nur Edges vom Typ "KNOWS" zurück.
- [ ] Unbekannter Typ → 0 Ergebnisse.
- [ ] `GraphVectorIndexSearch` mit identischem queryVec wie Node-Vektor → dieser Node ist TopK[0] mit Score ≈ 1.0.
- [ ] Zwei Nodes mit orthogonalen Vektoren → Score = 0.0.
- [ ] `topK = 3` bei 10 Nodes → genau 3 Ergebnisse, absteigend nach Score sortiert.
- [ ] Alle Indizes: kein SIGSEGV bei leerem Store.

---

---

# WP-GRP-06: Datei-Persistenz

## Ziel

Speichern und Laden eines `GraphMemStore` in einem kompakten Binärformat. Optionale zlib-Komprimierung. Ermöglicht Shutdown + Restart ohne Datenverlust.

## Abhängigkeiten

- WP-GRP-04 (mem)
- `std/fs` — `FsWrite`, `FsRead`, `FsOpen`, `FsClose`
- `std/zlib` — `DeflateCompress`, `DeflateDecompress` (optional, per Flag)

## Nicht im Umfang

- WAL / Crash-Recovery — v2.
- Inkrementelles Speichern (nur Deltas) — v2.
- Verschlüsselung — v2.

## Wichtige Hinweise

**Dateiformat** (Magic + Version + Sektionen):
```
[MAGIC: 8 Byte "LYXGDB\x01\x00"]
[nodeCount: 8 Byte]
[edgeCount: 8 Byte]
[flags: 8 Byte]  // Bit 0 = zlib-komprimiert
--- pro Node: ---
[id:8][labelsLen:8][labelsCount:8][propsLen:8][vecDims:8]
[labelsBuf: labelsLen Bytes]
[propsBuf:  propsLen Bytes]
[vecBuf:    vecDims*8 Bytes]
--- pro Edge: ---
[id:8][source:8][target:8][edgeTypeLen:8][createdAt:8][propsLen:8]
[edgeTypeBuf: edgeTypeLen Bytes]
[propsBuf:    propsLen Bytes]
```

- Bei `flags & 1`: Nutzdaten (nach Header) mit `DeflateCompress` komprimiert, beim Lesen zuerst dekomprimieren.
- `DeflateDecompress` existiert noch nicht in `std/zlib` — muss als Teil dieses WP oder separat implementiert werden (Hinweis: RFC 1951, Fixed-Huffman reicht für v1).

## Zu implementierende Symbole

```lyx
pub fn GraphFileSave(store: int64, path: pchar, plen: int64, compress: int64): int64
    // 1=ok, 0=fehler

pub fn GraphFileLoad(store: int64, path: pchar, plen: int64): int64
    // 1=ok, 0=fehler (Store muss vorher mit GraphMemStoreInit initialisiert sein)
```

## Abnahmekriterien

- [ ] Store mit 3 Nodes + 2 Edges speichern → Datei vorhanden, Magic-Bytes korrekt.
- [ ] Datei laden → `GraphMemStoreGetNode` gibt dieselben IDs zurück.
- [ ] Properties (int64, pchar, f64) überleben Round-Trip exakt.
- [ ] Vektor-Daten überleben Round-Trip (f64-Werte bitgenau gleich).
- [ ] `compress=1`: Datei kleiner als unkomprimierte Version bei 100 identischen Nodes.
- [ ] Komprimierte Datei: Load → `GraphVectorIndexBuild` funktioniert auf geladenem Store.
- [ ] Korrupte Datei (falscher Magic) → `GraphFileLoad` gibt 0 zurück, kein SIGSEGV.
- [ ] Leerer Store speichern + laden: nodeCount=0, edgeCount=0.

---

---

# WP-GRP-07: Query-API

## Ziel

High-Level-Abfragen, die Store + Indizes kombinieren. Zielgruppe: KI-Systeme (Graph-RAG), Zeitreihen-Analyse, Pattern-Matching.

## Abhängigkeiten

- WP-GRP-04 (mem)
- WP-GRP-05 (index)

## Nicht im Umfang

- Query-Sprache / Parser (Cypher o.ä.) — v2.
- Aggregationen (COUNT, SUM, AVG) — v2.
- Joins über mehrere Stores — v2.

## Wichtige Hinweise

**`GraphQueryContext`**: Da mehrere Inputs nötig sind (store + multiple indices), werden diese in einen Context-Struct gekapselt — löst auch den 7-Arg-Bug präventiv.

**`GraphGetContextForAI`**: Liefert Node-IDs im "Umfeld" des semantisch nächsten Nodes bis zu `depth` Hops. Algorithmus:
1. `GraphVectorIndexSearch` → TopK Seed-Nodes
2. BFS ab jedem Seed-Node bis Tiefe `depth` über `GraphMemStoreNeighbors`
3. Deduplizierung der gefundenen Node-IDs (Visited-Bitset oder linearer Scan)

**BFS-Implementierung in Lyx**: Kein rekursiver Stack — iterativ mit zwei `int64`-Arrays (aktuelle Ebene + nächste Ebene), max. `depth` Iterationen.

**Ergebnispuffer**: Aufrufer alloziert `outBuf` mit ausreichender Kapazität. Funktion gibt tatsächliche Anzahl zurück. Overflow → auf `maxOut` begrenzt, kein Fehler.

## Zu implementierende Symbole

```lyx
class GraphQueryCtx {
    store:   int64;    // Pointer auf GraphMemStore
    tidx:    int64;    // Pointer auf GraphTemporalIndex (oder 0)
    typeidx: int64;    // Pointer auf GraphTypeIndex (oder 0)
    vidx:    int64;    // Pointer auf GraphVectorIndex (oder 0)
}

pub fn GraphQueryCtxInit(ctx: int64, store: int64)
pub fn GraphQueryCtxSetTemporalIdx(ctx: int64, tidx: int64)
pub fn GraphQueryCtxSetTypeIdx(ctx: int64, typeidx: int64)
pub fn GraphQueryCtxSetVectorIdx(ctx: int64, vidx: int64)

// Alle Edges in Zeitfenster [tsFrom, tsTo]
pub fn GraphQueryEdgesInWindow(ctx: int64, tsFrom: int64, tsTo: int64,
                                outBuf: int64, maxOut: int64): int64

// Alle Edges eines bestimmten Typs
pub fn GraphQueryEdgesByType(ctx: int64, etype: pchar, elen: int64,
                              outBuf: int64, maxOut: int64): int64

// Pattern: Node A → EdgeType → Node B, optional Zeitfenster (0=kein Filter)
pub fn GraphQueryPattern(ctx: int64, srcId: int64, etype: pchar, elen: int64,
                          tsFrom: int64, outBuf: int64, maxOut: int64): int64

// Graph-RAG: semantisch nahe Nodes + deren Umfeld bis depth Hops
pub fn GraphGetContextForAI(ctx: int64, queryVec: int64, topK: int64,
                             depth: int64, outBuf: int64, maxOut: int64): int64
```

## Abnahmekriterien

- [ ] `GraphQueryEdgesInWindow`: gibt nur Edges im Zeitfenster zurück; leer wenn kein Index gesetzt.
- [ ] `GraphQueryEdgesByType("KNOWS"c, 5)`: gibt nur KNOWS-Edges zurück.
- [ ] `GraphQueryPattern(aliceId, "KNOWS"c, 5, 0, ...)`: gibt alle Nodes zurück, die Alice kennt.
- [ ] `GraphQueryPattern` mit `tsFrom = jetzt+1`: gibt 0 Ergebnisse (keine zukünftigen Edges).
- [ ] `GraphGetContextForAI` mit `depth=0`: gibt nur die TopK Seed-Nodes zurück.
- [ ] `GraphGetContextForAI` mit `depth=1`: gibt Seed-Nodes + direkte Nachbarn zurück.
- [ ] `GraphGetContextForAI`: keine Duplikate in `outBuf`.
- [ ] `GraphQueryCtx` mit nicht gesetztem Index (= 0): Funktion gibt 0 zurück, kein SIGSEGV.
- [ ] Alle Funktionen: `maxOut=0` → gibt 0 zurück, kein SIGSEGV.
