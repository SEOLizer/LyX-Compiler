# gRPC-Erweiterung für Lyx — Konzept & Arbeitspakete

## Bewertung des ursprünglichen Konzepts

**Stärken:**
- Korrekte Beschreibung der drei Architekturschichten
- Vollständige Abdeckung der vier RPC-Typen
- Nennung relevanter technischer Herausforderungen

**Schwächen:**
- Keine konkreten Arbeitspakete mit Abnahmekriterien
- Keine Sequenzierung / Abhängigkeiten zwischen Modulen
- Fehlende Lyx-spezifische Überlegungen (kein GC, manuelle Speicherverwaltung, FFI-Grenzen)
- Kein Hinweis auf Interoperabilitätstests mit Referenz-Implementierungen (Go/Java)
- Protobuf und HTTP/2 werden als gegeben angenommen, obwohl beides in Lyx gebaut oder eingebunden werden muss

---

## Architektur-Überblick

```
┌─────────────────────────────────────────────────┐
│              Anwendungsschicht                  │
│  (Generierte Stubs / Server-Interfaces in Lyx)  │
├─────────────────────────────────────────────────┤
│              gRPC Runtime                       │
│  Channel · Metadata · Status · Interceptors     │
├─────────────────────────────────────────────────┤
│           gRPC Wire-Format                      │
│  Length-Prefixed Framing · Compression-Flag     │
├─────────────────────────────────────────────────┤
│           HTTP/2 Transport                      │
│  Streams · HPACK · Flow-Control · TLS/ALPN      │
└─────────────────────────────────────────────────┘
```

---

## Arbeitspakete

### WP-G1 — HTTP/2 Transport-Schicht (Client)

**Grund:**
gRPC ist fest an HTTP/2 gebunden. Ohne einen funktionierenden HTTP/2-Client kann kein einziger RPC ausgeführt werden. Dieses Paket legt das Fundament für alle weiteren WPs.

**Inhalt:**
- TCP-Verbindungsaufbau zu einem gRPC-Server
- HTTP/2-Handshake: `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` + SETTINGS-Frame
- Senden und Empfangen von HEADERS-Frames (HPACK-Kodierung)
- Senden und Empfangen von DATA-Frames
- Verarbeitung von WINDOW_UPDATE, PING, GOAWAY
- Multiplexing: mehrere Streams über eine einzige TCP-Verbindung
- Flow-Control auf Stream- und Connection-Ebene

**Technische Details:**
- HPACK-Komprimierung (RFC 7541): statische Tabelle (61 Einträge) + dynamische Tabelle
- Pflicht-Header für gRPC: `:method POST`, `:scheme http/https`, `:path /Package.Service/Method`, `:authority <host>`, `content-type: application/grpc`
- Stream-IDs: Client verwendet ungerade IDs (1, 3, 5 …), Server gerade
- Initial SETTINGS: `HEADER_TABLE_SIZE`, `INITIAL_WINDOW_SIZE` (65535 Default)

**Abhängigkeiten:** keine (Basis-WP)

**Abnahmekriterien:**
- [ ] Ein `POST`-Request mit korrekten gRPC-Headern erreicht einen Go-gRPC-Testserver (`helloworld`-Beispiel)
- [ ] Der Server antwortet mit HTTP/2 200 und `content-type: application/grpc`
- [ ] Mindestens 10 parallele Streams über eine einzige Verbindung ohne Fehler
- [ ] Flow-Control: Client blockiert korrekt bei `WINDOW_SIZE = 0` und setzt fort nach WINDOW_UPDATE
- [ ] Wireshark-Capture zeigt valide HTTP/2-Frames (kein Protokollfehler vom Server)

---

### WP-G2 — gRPC Wire-Format (Length-Prefixed Framing)

**Grund:**
Das gRPC-Protokoll definiert ein exaktes Binärformat für alle Nachrichten — unabhängig vom Inhalt (Protobuf, JSON, etc.). Dieses Framing liegt zwischen HTTP/2 und der Serialisierung und muss korrekt implementiert sein.

**Inhalt:**
- Serialisierung des 5-Byte-Nachrichtenpräfix
- Deserialisierung eingehender LENGTH-PREFIXED Messages
- Unterstützung für Compressed-Flag (Byte 0: `0x00` = unkomprimiert, `0x01` = komprimiert)
- Optionale gzip-Komprimierung (`grpc-encoding: gzip`)
- Parsing mehrerer aufeinanderfolgender Messages in einem HTTP/2 DATA-Stream (für Streaming-RPCs)

**Technische Details:**
```
┌────────────────────────────────────────────────┐
│ Byte 0   │ Compressed-Flag (0 = nein, 1 = ja)  │
│ Byte 1-4 │ Message-Length (Big-Endian uint32)  │
│ Byte 5-N │ Serialisierter Payload (Protobuf)   │
└────────────────────────────────────────────────┘
```
- Ein HTTP/2 DATA-Frame kann mehrere Length-Prefixed Messages enthalten
- Partial Reads: eine Message kann auf mehrere DATA-Frames verteilt sein → Zustandsautomat nötig

**Abhängigkeiten:** WP-G1

**Abnahmekriterien:**
- [ ] Manuelle Binärnachricht (hartcodierter Protobuf-Payload) wird korrekt gerahmt und an Go-Server gesendet
- [ ] Server-Antwort wird korrekt derahmt (5-Byte-Header entfernt, Payload extrahiert)
- [ ] Korrekte Behandlung von Messages, die über zwei DATA-Frames verteilt sind
- [ ] gzip-komprimierte Antwort wird korrekt dekomprimiert (Compressed-Flag = 1)
- [ ] Unit-Test: 1000 zufällige Payloads frame/deframe round-trip ohne Datenverlust

---

### WP-G3 — Protobuf-Serialisierung & Runtime-Library

**Grund:**
gRPC-Nachrichten werden standardmäßig als Protobuf-Binärformat übertragen. Ohne Serialisierung/Deserialisierung können keine strukturierten Daten ausgetauscht werden.

**Inhalt:**
- Implementierung des Protobuf Wire-Formats (Binary Encoding, RFC/Google Spec)
  - Varint-Encoding (field_number << 3 | wire_type)
  - Wire Types: 0 (Varint), 1 (64-bit), 2 (Length-delimited), 5 (32-bit)
- Lyx-Typen → Protobuf-Mapping:
  - `i32/i64` → int32/int64/sint32/sint64
  - `u32/u64` → uint32/uint64
  - `f32/f64` → float/double
  - `bool`    → bool
  - `string`  → string (UTF-8)
  - `[]u8`    → bytes
- Nested Messages, Repeated Fields, Optional Fields
- Runtime-Library: `std/proto` — Encode/Decode-Funktionen für alle Typen

**Technische Details:**
- Varint: 7 Bits pro Byte, MSB = Continuation-Bit
- ZigZag-Encoding für sint32/sint64: `(n << 1) ^ (n >> 31)`
- Unbekannte Felder müssen beim Lesen übersprungen (nicht verworfen) werden (Forward-Compatibility)
- Lyx hat keinen GC → Puffer müssen explizit alloziiert und freigegeben werden

**Abhängigkeiten:** keine (kann parallel zu WP-G1 entwickelt werden)

**Abnahmekriterien:**
- [ ] `std/proto`-Encode/Decode für alle Scalar-Typen: round-trip korrekt
- [ ] Interoperabilitätstest: Lyx-kodierte Nachricht wird von Go-`proto.Unmarshal` korrekt dekodiert
- [ ] Interoperabilitätstest: Go-kodierte Nachricht wird von Lyx-`proto.Decode` korrekt gelesen
- [ ] Repeated Fields: Liste mit 0, 1 und 1000 Elementen
- [ ] Nested Messages: drei Ebenen tief
- [ ] Unbekannte Felder werden toleriert (kein Crash, kein Datenverlust bekannter Felder)

---

### WP-G4 — Client Runtime — Unary RPC

**Grund:**
Unary RPC (ein Request, eine Response) ist der einfachste und häufigste gRPC-Aufruftyp. Er bildet die Basis für alle komplexeren Streaming-Varianten und ist der erste vollständig nutzbare RPC-Typ.

**Inhalt:**
- `Channel`-Typ: hält HTTP/2-Verbindung, verwaltet Stream-IDs
- `UnaryCall(method: string, request: []u8) -> Result<[]u8, GrpcStatus>`
- Aufbau: HEADERS-Frame senden → DATA-Frame (Length-Prefixed Payload) → END_STREAM
- Empfang: HEADERS + DATA-Frames lesen → Trailer (`grpc-status`, `grpc-message`) auswerten
- gRPC-Statuscode-Mapping (0 = OK, 1 = CANCELLED, 2 = UNKNOWN, …, 16 = UNAUTHENTICATED)
- Deadline/Timeout: `grpc-timeout`-Header setzen (`100m` = 100 Millisekunden)
- Metadaten: beliebige Key-Value-Header mitsenden

**Technische Details:**
- gRPC-Trailer kommen als `HEADERS`-Frame mit `END_STREAM`-Flag nach dem DATA-Frame
- `grpc-status` ist ein Trailer, kein Request-Header (wichtig für Server-Push-Handling)
- `grpc-message` ist URL-encoded (Percent-Encoding für non-ASCII)
- Timeouts Format: `HnMnSnmn` → Stunden/Minuten/Sekunden/Millisekunden

**Abhängigkeiten:** WP-G1, WP-G2, WP-G3

**Abnahmekriterien:**
- [ ] Unary-Call gegen Go-`helloworld`-Server: korrekte Response empfangen
- [ ] Fehlerfall: Server gibt `grpc-status: 5` (NOT_FOUND) zurück → `GrpcStatus`-Error in Lyx
- [ ] Timeout-Test: Server antwortet absichtlich nach 500ms, Client-Timeout auf 100ms gesetzt → `DEADLINE_EXCEEDED`
- [ ] Metadaten: benutzerdefinierter Header `x-request-id` wird vom Server empfangen und zurückgespiegelt
- [ ] 100 sequenzielle Unary-Calls ohne Connection-Leak oder Stream-ID-Erschöpfung

---

### WP-G5 — Server Runtime — Unary RPC

**Grund:**
Ohne Server-Implementierung kann Lyx nur als gRPC-Client agieren. Für Microservices in Lyx ist ein vollständiger Server unverzichtbar.

**Inhalt:**
- HTTP/2-Server: lauscht auf TCP-Port, führt Handshake durch
- Request-Routing: `:path`-Header parsen → `Package.Service/Method` → Handler-Funktion aufrufen
- Handler-Interface: `fn(ctx: *Context, req: []u8) -> Result<[]u8, GrpcStatus>`
- Response senden: HEADERS (200 + content-type) → DATA (Length-Prefixed) → HEADERS (Trailer grpc-status)
- Concurrent Requests: mehrere Streams parallel verarbeiten (Lyx-Threads oder async I/O)
- Graceful Shutdown: GOAWAY-Frame senden, laufende Streams abschließen

**Technische Details:**
- Server-seitige SETTINGS nach Handshake: `MAX_CONCURRENT_STREAMS` konfigurierbar
- Pflicht-Trailer: `grpc-status: 0` bei Erfolg (fehlt → Client-Fehler)
- Optionaler Trailer: `grpc-message` bei Fehler (URL-encoded)
- Routing-Tabelle: `map<string, HandlerFn>` — zur Startzeit befüllt

**Abhängigkeiten:** WP-G1, WP-G2, WP-G3

**Abnahmekriterien:**
- [ ] Go-gRPC-Client kann Unary-Call an Lyx-Server senden und korrekte Response empfangen
- [ ] `grpccurl`-Tool kann den Server erfolgreich aufrufen
- [ ] Unbekannter Methodenname → `grpc-status: 12` (UNIMPLEMENTED)
- [ ] Fehler im Handler → korrekter Fehler-Trailer mit `grpc-message`
- [ ] 50 parallele Clients, je 20 Requests → kein Datenverlust, kein Deadlock

---

### WP-G6 — protoc-Plugin (Code-Generierung)

**Grund:**
Manuelles Schreiben von Serialisierungs- und Stub-Code ist fehleranfällig und nicht skalierbar. Das protoc-Plugin automatisiert die Code-Generierung aus `.proto`-Dateien und ist die primäre Entwickler-Schnittstelle.

**Inhalt:**
- Binärprogramm `protoc-gen-lyx` das protoc als Plugin-Prozess startet
- Eingabe: `CodeGeneratorRequest` (Protobuf-kodiert auf stdin)
- Ausgabe: `CodeGeneratorResponse` mit generierten `.lyx`-Dateien auf stdout
- Generierte Artefakte:
  - Message-Typen als Lyx-`struct` mit `Encode()` und `Decode()`-Methoden
  - Client-Stubs: eine Funktion pro RPC-Methode
  - Server-Interface: abstrakte Handler-Signaturen
- Namespacing: Protobuf-`package` → Lyx-`import`-Pfad

**Technische Details:**
- protoc-Plugin-Protokoll: `google.protobuf.compiler.CodeGeneratorRequest` auf stdin lesen
- Ausgabe als `CodeGeneratorResponse` auf stdout schreiben
- Aufruf: `protoc --lyx_out=./gen --plugin=protoc-gen-lyx=./bin/protoc-gen-lyx service.proto`
- Fehlermeldungen: im `error`-Feld von `CodeGeneratorResponse` (nicht stderr)

**Abhängigkeiten:** WP-G3, WP-G4, WP-G5

**Abnahmekriterien:**
- [ ] `protoc --lyx_out=. helloworld.proto` generiert valide `.lyx`-Datei ohne Compilerfehler
- [ ] Generierter Client-Stub kann ohne manuelle Änderungen einen Unary-Call ausführen
- [ ] Generierter Server-Stub: Implementierung des Interfaces reicht für einen lauffähigen Server
- [ ] Round-Trip-Test: Lyx-Client (generiert) ↔ Lyx-Server (generiert) für alle Scalar-Typen
- [ ] Fehlerfall in `.proto` (z. B. fehlende `package`-Deklaration) → verständliche Fehlermeldung

---

### WP-G7 — Streaming RPCs

**Grund:**
Streaming ist ein Kernmerkmal von gRPC und unterscheidet es fundamental von REST. Server- und Client-Streaming sind für viele reale Use-Cases (Logs, Telemetrie, Bulk-Uploads) notwendig.

**Inhalt:**
- **Server Streaming:** Client sendet einen Request, Server sendet N Responses
- **Client Streaming:** Client sendet N Requests, Server antwortet einmal
- **Bidirektionales Streaming:** beide Seiten senden asynchron N Nachrichten
- Stream-Typen in Lyx: `ServerStream<T>`, `ClientStream<T>`, `BidiStream<T>`
- `Send()` und `Recv()` Primitive auf Stream-Objekten
- Korrekte `END_STREAM`-Semantik: wann darf/muss der Stream geschlossen werden
- Half-Close: Client kann senden beenden, aber noch empfangen

**Technische Details:**
- HTTP/2: Server Streaming = mehrere DATA-Frames ohne END_STREAM bis zum letzten
- `END_STREAM` im letzten DATA-Frame des Servers signalisiert Ende der Stream-Response
- Bidirektional: beide Seiten können jederzeit `END_STREAM` setzen → unabhängige Halbstreams
- Backpressure: `WINDOW_UPDATE` muss korrekt ausgestellt werden, sonst hängt der Stream

**Abhängigkeiten:** WP-G4, WP-G5

**Abnahmekriterien:**
- [ ] Server Streaming: Lyx-Client empfängt 1000 Nachrichten von Go-Server ohne Timeout
- [ ] Client Streaming: Lyx-Client sendet 1000 Nachrichten, Go-Server bestätigt aggregierten Wert
- [ ] Bidirektional: Lyx ↔ Go Ping-Pong mit 500 Nachrichten in beide Richtungen
- [ ] Half-Close: Client sendet END_STREAM, Server antwortet noch 10 Nachrichten → korrekt empfangen
- [ ] Stream-Abbruch: Server bricht Stream mit RST_STREAM ab → Client erhält `CANCELLED`-Status

---

### WP-G8 — TLS / mTLS Support

**Grund:**
gRPC im Produktionseinsatz läuft ausschließlich über TLS. Ohne TLS ist die Erweiterung nicht produktionstauglich. mTLS ist für Service-zu-Service-Authentifizierung in Zero-Trust-Architekturen Standard.

**Inhalt:**
- TLS 1.2/1.3 via Systembibliotek (OpenSSL oder mbedTLS FFI)
- ALPN-Aushandlung: `h2`-Protokoll-Identifier
- TLS-Server: Zertifikat + Privat-Key laden
- TLS-Client: CA-Zertifikat für Server-Verifikation
- mTLS: Client-Zertifikat + Key für gegenseitige Authentifizierung
- Insecure-Modus (`grpc.WithInsecure()` Äquivalent) für Entwicklung/Tests

**Technische Details:**
- ALPN (RFC 7301): TLS-Extension, die HTTP/2 (`h2`) aushandelt — Pflicht für Browser-kompatibes gRPC
- TLS 1.3 bevorzugen: 0-RTT-Handshake reduziert Latenz
- SNI: Server Name Indication muss gesetzt werden für Virtual Hosting
- Zertifikat-Rotation: Verbindungen sollten neuem Zertifikat nach Reload folgen

**Abhängigkeiten:** WP-G1

**Abnahmekriterien:**
- [ ] TLS-Client: Lyx verbindet sich zu TLS-gesichertem Go-Server (echtes Zertifikat oder self-signed CA)
- [ ] TLS-Server: Go-Client verbindet sich zu Lyx-Server über TLS
- [ ] mTLS: gegenseitige Zertifikat-Authentifizierung schlägt mit falschem Client-Zertifikat fehl
- [ ] ALPN: Wireshark zeigt `h2`-Aushandlung im TLS-Handshake
- [ ] Ablaufendes Zertifikat: Verbindungsaufbau schlägt mit verständlichem Fehler fehl (nicht Crash)

---

### WP-G9 — Interoperabilität & Conformance Tests

**Grund:**
gRPC-Implementierungen müssen mit allen anderen konformen Implementierungen kompatibel sein. Nur Interop-Tests gegen Referenz-Implementierungen (Go, Java, C++) garantieren Spec-Konformität.

**Inhalt:**
- Ausführen der offiziellen gRPC-Interop-Testszenarien (grpc/grpc-interop-tests)
- Szenarien: `empty_unary`, `large_unary`, `client_streaming`, `server_streaming`, `ping_pong`, `cancel_after_begin`, `timeout_on_sleeping_server`, u. a.
- Lyx als Client gegen Go-Referenz-Server
- Lyx als Server gegen Go-Referenz-Client
- Performance-Baseline: Latenz und Throughput im Vergleich zu Go-Client (±30% Toleranz)

**Technische Details:**
- Interop-Testserver/Client: verfügbar als Docker-Images (`grpc/java_interop_client`, etc.)
- Test-Protokoll: spezifische `.proto`-Datei (`grpc/testing/test.proto`)
- Conformance-Fehler: werden als Protokollverletzungen gewertet, nicht als Feature-Lücken

**Abhängigkeiten:** WP-G6, WP-G7, WP-G8

**Abnahmekriterien:**
- [ ] Alle Pflicht-Interop-Szenarien aus der gRPC-Spezifikation bestanden (Lyx als Client)
- [ ] Alle Pflicht-Interop-Szenarien bestanden (Lyx als Server)
- [ ] `cancel_after_begin`-Szenario: korrekte Freigabe von Ressourcen (kein Memory-Leak)
- [ ] `timeout_on_sleeping_server`-Szenario: Client bricht nach Timeout ab, kein Goroutine-/Thread-Leak
- [ ] Performance: Unary-Latenz p99 ≤ 2× Go-Referenzimplementierung unter gleicher Last

---

## Abhängigkeitsgraph

```
WP-G3 (Protobuf) ──┐
                    ├──▶ WP-G4 (Client Unary) ──┐
WP-G1 (HTTP/2) ────┤                            ├──▶ WP-G6 (Streaming)
WP-G2 (Framing) ───┘                            │
                    ├──▶ WP-G5 (Server Unary) ──┘
                                                 ├──▶ WP-G6
                                                 └──▶ WP-G7 (TLS) ──▶ WP-G9 (Interop)
                    WP-G4 + WP-G5 ──────────────▶ WP-G8 (protoc Plugin)
```

## Phasenplan

| Phase | WPs           | Ziel                                           |
|-------|---------------|------------------------------------------------|
| 1     | G1, G2, G3    | Fundament: HTTP/2, Framing, Protobuf           |
| 2     | G4, G5        | Erster vollständiger Unary-RPC Lyx ↔ Go        |
| 3     | G6, G7        | Streaming + TLS: produktionsbereit             |
| 4     | G8, G9        | Developer-Experience + Conformance             |
