# Fahrplan: Google Cast SDK (`std/net/cast/`)

## Vision

Ein natives Lyx-SDK für das Google Cast-Protokoll (CastV2) – ohne externe Abhängigkeiten außer OpenSSL (bereits über `std/net/tls.lyu` verfügbar). Gerätefindung via mDNS, Protokollkommunikation via TLS/Protobuf, Mediensteuerung via JSON-Namespaces.

```lyx
import std.net.cast;

fn main() {
    var devices: CastDeviceList := CastDiscover(5);
    if (devices.count == 0) {
        println("Keine Geräte gefunden.");
        return;
    }

    var client: CastClient := CastConnect(devices.items[0]);
    CastLaunchMedia(client);
    CastPlayMedia(
        client,
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
        "video/mp4"
    );

    while (CastIsConnected(client)) {
        CastTick(client);   // Events verarbeiten (Heartbeat läuft im Hintergrundprozess)
        SleepMs(500);
    }
    CastDisconnect(client);
}
```

---

## Architektur

```
┌──────────────────────────────────────────────────────────┐
│                   Lyx-Anwendungscode                     │
│         CastDiscover / CastConnect / CastPlayMedia       │
└────────────────────────┬─────────────────────────────────┘
                         │
             ┌───────────▼───────────┐
             │   std.net.cast API    │  (cast.lyx – WP-CAST-09)
             │  High-Level Façade    │
             └───┬───────┬───────────┘
                 │       │
    ┌────────────▼──┐  ┌─▼──────────────────────────────┐
    │ std.net.mdns  │  │      Channel-Schicht            │
    │  Discovery    │  │  Heartbeat / Connection /       │
    │  (WP-CAST-01) │  │  Receiver / Media               │
    └───────────────┘  │  (WP-CAST-05 – WP-CAST-08)     │
                       └─────────────┬──────────────────┘
                                     │
                       ┌─────────────▼──────────────────┐
                       │   Frame-Transport               │
                       │   4-Byte-Länge + Protobuf       │
                       │   (WP-CAST-03 + WP-CAST-04)    │
                       └─────────────┬──────────────────┘
                                     │
                       ┌─────────────▼──────────────────┐
                       │   TLS/TCP Port 8009             │
                       │   std.net.tls (SSL_VERIFY_NONE) │
                       └────────────────────────────────┘
```

---

## Abhängigkeiten (bereits in Lyx vorhanden)

| Modul              | Verwendung                                   |
|--------------------|----------------------------------------------|
| `std.net.socket`   | UDP-Multicast für mDNS, TCP-Basis            |
| `std.net.tls`      | TLS-Verbindung zu Port 8009 (selbstsign. Z.) |
| `std.net.dns`      | Referenz-Implementierung für DNS-Parsing     |
| `std.json`         | JSON-Payloads der Cast-Namespaces            |
| `std.process`      | `fork()` für Heartbeat-Hintergrundprozess    |

> **Hinweis `std.thread`:** Die Unit existiert, ist aber ein unfertiger Skeleton – `ThreadCreate` ruft `_exit(0)` statt den Funktionszeiger auf, `MutexLock` ist ein No-Op. Für den Heartbeat wird daher `std.process` (`fork`) verwendet.

---

## Work Packages

---

### WP-CAST-01 — mDNS Discovery (`std/net/mdns.lyx`)

**Ziel:** Lyx-Modul, das via UDP-Multicast nach Geräten sucht, die `_googlecast._tcp.local` ankündigen.

**Datei:** `std/net/mdns.lyx`

**Warum eigenes Modul statt std.net.dns:**  
Das bestehende `dns.lyx` kommuniziert mit unicast DNS-Resolvern. mDNS nutzt IP-Multicast (224.0.0.251, Port 5353) und braucht IP_ADD_MEMBERSHIP auf dem Socket – eine andere Code-Pfad.

**Protokolldetails:**
- UDP-Multicast-Gruppe: `224.0.0.251`, Port `5353`
- Query: PTR-Record für `_googlecast._tcp.local` (DNS-Class IN | QU-Bit = 0x8001)
- Antwort enthält: PTR → Name, SRV → Host + Port, TXT → Metadaten (id, md, fn, ca, st, ve), A → IPv4

**Datenstrukturen:**
```lyx
pub type MDNSDevice = struct {
    ip:       int64;    // IPv4 als 32-Bit in int64
    port:     int64;    // Meist 8009
    namePtr:  int64;    // Pointer auf Gerätename (z.B. "Wohnzimmer TV")
    nameLen:  int64;
    modelPtr: int64;    // "md"-TXT-Feld (z.B. "Chromecast Ultra")
    modelLen: int64;
    uuidPtr:  int64;    // "id"-TXT-Feld
    uuidLen:  int64;
};

pub type MDNSDeviceList = struct {
    items:    int64;    // Pointer auf MDNSDevice-Array
    count:    int64;
    capacity: int64;
};
```

**Funktionen:**
```lyx
pub fn MDNSScan(timeoutSec: int64): MDNSDeviceList;
// Öffnet UDP-Socket, joined Multicastgruppe, sendet PTR-Query,
// sammelt Antworten für timeoutSec Sekunden, gibt Liste zurück.

fn mdns_send_query(sock: UDPSocket): int64;
fn mdns_parse_response(buf: int64, len: int64, list: int64): int64;
fn mdns_parse_name(buf: int64, pos: int64, base: int64, out: int64): int64;
fn mdns_parse_txt(data: int64, len: int64, dev: int64): void;
```

**Implementierungsschritte:**
1. `UDPSocketNew()` + `setsockopt(IP_ADD_MEMBERSHIP)` via Syscall (analog zu `socket.lyx`)
2. DNS-Wire-Format-Query bauen (Header: ID=0, QR=0, OPCODE=0, QD=1; Question: `_googlecast._tcp.local`, TYPE=PTR, CLASS=0x8001)
3. Query an 224.0.0.251:5353 senden
4. `UDPSocketRecvFrom` in Schleife mit SO_RCVTIMEO
5. Antwortpakete parsen: Header → Answer-Section → PTR/SRV/TXT/A-Records auflösen
6. Pointer-Compression (0xC0-Byte) korrekt folgen
7. Deduplizierung nach UUID

**Testbarkeit:**
- Separates Test-Binary `test_mdns.lyx` das alle gefundenen Geräte auf stdout ausgibt
- Wireshark-Capture als Referenz: Filter `mdns && dns.qry.name contains "googlecast"`

**Akzeptanzkriterium:** `MDNSScan(5)` gibt mindestens ein Gerät mit korrekter IP und Port 8009 zurück, wenn ein Chromecast im Netzwerk ist.

---

### WP-CAST-02 — Protobuf-Codec für CastMessage (`std/net/cast_proto.lyx`)

**Ziel:** Minimaler, auf CastMessage zugeschnittener Protobuf-Encoder und -Decoder. Kein generischer Protobuf-Parser nötig – nur die sieben Felder der CastMessage.

**Datei:** `std/net/cast_proto.lyx`

**Das Protobuf-Schema (cast_channel.proto):**
```
message CastMessage {
  required ProtocolVersion protocol_version = 1;  // varint, immer 0
  required string source_id       = 2;
  required string destination_id  = 3;
  required string namespace       = 4;
  required PayloadType payload_type = 5;           // varint, 0=STRING 1=BINARY
  optional string payload_utf8    = 6;
  optional bytes  payload_binary  = 7;
}
```

**Wire-Format (Protobuf Binary):**
- Tag-Byte = `(field_number << 3) | wire_type`
- Wire-Typ 0: varint (LEB128), Wire-Typ 2: length-delimited
- Feldbytes: `0x08` (F1 varint), `0x12` (F2 str), `0x1A` (F3 str), `0x22` (F4 str), `0x28` (F5 varint), `0x32` (F6 str)

**Datenstrukturen:**
```lyx
pub type CastMessage = struct {
    srcPtr:    int64;   // source_id
    srcLen:    int64;
    dstPtr:    int64;   // destination_id
    dstLen:    int64;
    nsPtr:     int64;   // namespace
    nsLen:     int64;
    payPtr:    int64;   // payload_utf8
    payLen:    int64;
    payType:   int64;   // 0=STRING, 1=BINARY
};
```

**Funktionen:**
```lyx
// Encodes CastMessage into buf, returns written byte count
pub fn CastMsgEncode(msg: int64, buf: int64, maxLen: int64): int64;

// Decodes from buf (len bytes) into msg struct. Returns 0 on error.
pub fn CastMsgDecode(buf: int64, len: int64, msg: int64): int64;

// Internal: varint encode/decode (LEB128)
fn proto_write_varint(buf: int64, pos: int64, val: int64): int64;
fn proto_read_varint(buf: int64, pos: int64, outVal: int64): int64;
fn proto_write_string(buf: int64, pos: int64, tag: int64, str: int64, slen: int64): int64;
fn proto_read_field(buf: int64, pos: int64, endPos: int64, msg: int64): int64;
```

**Implementierungsschritte:**
1. `proto_write_varint`: LEB128-Encoding – jeweils 7 Bits, MSB = continuation bit
2. `CastMsgEncode`: Protocol-Version-Feld (0x08, 0x00), dann alle String-Felder, dann Payload-Type
3. `CastMsgDecode`: Loop über Bytes, switch auf Tag-Byte, für jedes bekannte Feld lesen
4. Pointer-Compression nicht nötig (Protobuf hat keine)

**Testbarkeit:** Bekannte Bytes (aus pychromecast/node-castv2 oder Wireshark-Dump) als Hex-String hartcodieren, dekodieren, Felder prüfen. Dann re-encoden und Byte-für-Byte vergleichen.

**Akzeptanzkriterium:** `CastMsgDecode(known_ping_bytes, len, &msg)` liefert `namespace = "urn:x-cast:com.google.cast.tp.heartbeat"` und `payload_utf8 = '{"type":"PING"}'`.

---

### WP-CAST-03 — Frame-Transport (`std/net/cast_transport.lyx`)

**Ziel:** TLS-Verbindung zu Port 8009 mit 4-Byte-Big-Endian-Längenrahmen für Protobuf-Payloads.

**Datei:** `std/net/cast_transport.lyx`

**Wire-Format:**
```
+--------+--------+--------+--------+-------- ... --------+
|  Len3  |  Len2  |  Len1  |  Len0  |  Protobuf-Payload   |
+--------+--------+--------+--------+-------- ... --------+
  Big-Endian uint32                    (Len Bytes)
```

**Datenstruktur:**
```lyx
pub type CastTransport = struct {
    tls:       TLSConn;     // aus std.net.tls
    ctx:       TLSContext;
    connected: int64;
    rxBuf:     int64;       // Empfangspuffer (64KB mmap)
    txBuf:     int64;       // Sendepuffer (64KB mmap)
};
```

**Funktionen:**
```lyx
pub fn CastTransportOpen(ip: int64, port: int64, out: int64): int64;
// Baut TCP-Verbindung auf, startet TLS-Handshake mit SSL_VERIFY_NONE.
// Gibt CAST_OK oder Fehlercode zurück.

pub fn CastTransportSend(t: int64, protoBytes: int64, protoLen: int64): int64;
// Schreibt 4-Byte Big-Endian Länge, dann protoLen Bytes über TLS.

pub fn CastTransportRecv(t: int64, outBuf: int64, outLen: int64): int64;
// Liest 4-Byte Länge, dann payload in outBuf. Gibt Länge zurück, 0=Timeout, <0=Fehler.

pub fn CastTransportClose(t: int64): void;
```

**Implementierungshinweise:**
- `TLSConnect` aus `std.net.tls` verwenden, `SSL_VERIFY_NONE` setzen
- Big-Endian-Schreiben: `poke8(buf+0, len>>24)`, `poke8(buf+1, (len>>16)&0xFF)` etc.
- `TLSRead` ist blocking – für Timeout `SO_RCVTIMEO` auf dem TCP-Socket setzen **vor** TLS-Wrap
- Puffer: 2 × 65536 Bytes via `mmap` (analog zu anderen std-Modulen)

**Fehlerbehandlung:**
```lyx
pub con CAST_OK:             int64 := 0;
pub con CAST_ERR_CONNECT:    int64 := -1;
pub con CAST_ERR_TLS:        int64 := -2;
pub con CAST_ERR_SEND:       int64 := -3;
pub con CAST_ERR_RECV:       int64 := -4;
pub con CAST_ERR_TOOBIG:     int64 := -5;   // Payload > 64KB
pub con CAST_ERR_CLOSED:     int64 := -6;
```

**Akzeptanzkriterium:** `CastTransportOpen` stellt Verbindung zu einem echten Chromecast auf Port 8009 her (TLS-Handshake erfolgreich, kein Zertifikatsfehler da VERIFY_NONE).

---

### WP-CAST-04 — JSON-Builder für Cast-Payloads (`std/net/cast_json.lyx`)

**Ziel:** Leichtgewichtiger JSON-Builder für die spezifischen Cast-Payload-Templates. Nutzt `std.json` für Parsing, baut Strings für Senden zusammen.

**Datei:** `std/net/cast_json.lyx`

**Hintergrund:** Die `std.json`-Unit ist als `.lyu` bereits kompiliert vorhanden. Für das Senden reichen template-basierte String-Builder, da alle Cast-JSON-Payloads bekannte Strukturen haben.

**Benötigte Payload-Templates:**

| Namespace     | Typ       | JSON-Payload                                                          |
|---------------|-----------|-----------------------------------------------------------------------|
| heartbeat     | PING      | `{"type":"PING"}`                                                     |
| heartbeat     | PONG      | `{"type":"PONG"}`                                                     |
| connection    | CONNECT   | `{"type":"CONNECT","userAgent":"LyxCast/1.0"}`                        |
| connection    | CLOSE     | `{"type":"CLOSE"}`                                                    |
| receiver      | LAUNCH    | `{"type":"LAUNCH","appId":"CC1AD845","requestId":N}`                   |
| receiver      | STOP      | `{"type":"STOP","sessionId":"...","requestId":N}`                     |
| receiver      | GET_STATUS| `{"type":"GET_STATUS","requestId":N}`                                 |
| media         | LOAD      | `{"type":"LOAD","media":{...},"autoplay":true,"requestId":N}`         |
| media         | PLAY      | `{"type":"PLAY","mediaSessionId":N,"requestId":N}`                    |
| media         | PAUSE     | `{"type":"PAUSE","mediaSessionId":N,"requestId":N}`                   |
| media         | STOP      | `{"type":"STOP","mediaSessionId":N,"requestId":N}`                    |
| media         | SEEK      | `{"type":"SEEK","currentTime":F,"mediaSessionId":N,"requestId":N}`    |
| media         | GET_STATUS| `{"type":"GET_STATUS","requestId":N}`                                 |

**Funktionen:**
```lyx
// Füllt buf mit JSON-String, gibt Länge zurück
pub fn CastJsonPing(buf: int64): int64;
pub fn CastJsonPong(buf: int64): int64;
pub fn CastJsonConnect(buf: int64): int64;
pub fn CastJsonClose(buf: int64): int64;
pub fn CastJsonLaunch(buf: int64, appId: int64, reqId: int64): int64;
pub fn CastJsonStop(buf: int64, sessionId: int64, reqId: int64): int64;
pub fn CastJsonGetStatus(buf: int64, reqId: int64): int64;
pub fn CastJsonLoad(buf: int64, url: int64, mime: int64, reqId: int64): int64;
pub fn CastJsonMediaPlay(buf: int64, sessionId: int64, reqId: int64): int64;
pub fn CastJsonMediaPause(buf: int64, sessionId: int64, reqId: int64): int64;
pub fn CastJsonMediaStop(buf: int64, sessionId: int64, reqId: int64): int64;

// Parst empfangenes JSON, extrahiert "type"-Feld
pub fn CastJsonGetType(json: int64, jsonLen: int64, outBuf: int64): int64;

// Parst ReceiverStatus → sessionId extrahieren
pub fn CastJsonParseSession(json: int64, jsonLen: int64, outBuf: int64): int64;

// Parst MediaStatus → mediaSessionId extrahieren
pub fn CastJsonParseMediaSession(json: int64, jsonLen: int64): int64;
```

**Implementierung:** Alle Builder verwenden `StrCopy`/`StrAppend`-Pattern mit Integer-zu-String-Konvertierung für requestId. Kein dynamisches JSON-Parsing für Sender-Seite nötig.

**Akzeptanzkriterium:** `CastJsonLoad(buf, "http://example.com/v.mp4", "video/mp4", 1)` erzeugt valides JSON das `isValidJSON()` aus `std.json` akzeptiert.

---

### WP-CAST-05 — Heartbeat-Channel (`std/net/cast_heartbeat.lyx`)

**Ziel:** Sicherstellen der Verbindung durch zyklisches PING/PONG in einem echten Hintergrundprozess. Ohne Heartbeat trennt der Chromecast nach ~5 Sekunden.

**Datei:** `std/net/cast_heartbeat.lyx`

**Namespace:** `urn:x-cast:com.google.cast.tp.heartbeat`

**Protokoll:**
- Sender schickt alle 5 Sekunden: `{"type":"PING"}` an `destination_id = "receiver-0"`
- Empfänger antwortet: `{"type":"PONG"}`
- Bleibt PONG 3× aus → Verbindung als tot markieren

**Implementierungsstrategie: `fork()` + Shared Memory (MAP_SHARED)**

`std.thread` ist ein unfertiger Skeleton (`ThreadCreate` führt die übergebene Funktion nie aus, Mutexe sind No-Ops). Stattdessen wird `std.process` genutzt:

```
CastConnect()
     │
     ├─ mmap(MAP_SHARED | MAP_ANONYMOUS, 16 Bytes)
     │    → CastHeartbeatShm { alive: int64; pongReceived: int64 }
     │
     └─ fork()
           │
           ├─ Parent: besitzt alle Reads (CastTransportRecv)
           │          schreibt pongReceived=1 wenn PONG eintrifft
           │          liest alive-Flag um Child zu stoppen
           │
           └─ Child:  kein Read, nur Writes
                      loop: sleep(5s) → send PING
                      prüft alive-Flag → exit(0) wenn 0
```

**Warum keine Konflikte auf dem TLS-Socket:**  
Nach `fork()` erben beide Prozesse denselben Datei-Deskriptor. Der Child **schreibt nur** (PINGs), der Parent **liest nur** (Responses) – keine gleichzeitigen Writes, daher kein Race auf den internen OpenSSL-Strukturen.

**Shared-Memory-Layout (16 Bytes, `mmap MAP_SHARED`):**
```
Offset 0:  alive        (int64) – 1=läuft, 0=Child soll beenden
Offset 8:  pongReceived (int64) – Parent setzt auf 1 bei PONG, Child liest & resettet
```

**Datenstruktur (Parent-seitig):**
```lyx
pub type CastHeartbeat = struct {
    childPid:   int64;    // PID des Fork-Kindes
    shmPtr:     int64;    // Pointer auf MAP_SHARED-Segment (16 Bytes)
    missedPongs: int64;   // Zähler im Parent: wie viele PINGs ohne PONG
};
```

**Funktionen:**
```lyx
// Startet fork()-Child. Aufzurufen direkt nach CastTransportOpen.
// sslFd = roher TCP-fd der TLS-Verbindung (für PING-Writes im Child)
pub fn CastHeartbeatStart(hb: int64, sslPtr: int64): int64;

// Im Parent aufrufen wenn PONG-Nachricht empfangen wurde
pub fn CastHeartbeatHandlePong(hb: int64): void;

// Im Parent-Tick prüfen ob Child noch lebt und Pongs ankommen
// Gibt CAST_ALIVE oder CAST_DEAD zurück
pub fn CastHeartbeatCheck(hb: int64): int64;

// Stoppt Child sauber: setzt alive=0 im SHM, wartet mit waitpid()
pub fn CastHeartbeatStop(hb: int64): void;
```

**Child-Prozess-Logik (intern, nach fork):**
```lyx
// Läuft im Child nach fork()
fn heartbeat_child_loop(shmPtr: int64, sslPtr: int64): void {
    while (peek64(shmPtr + 0) == 1) {    // alive-Flag
        cast_send_ping(sslPtr);
        SleepMs(5000);
    }
    _exit(0);
}
```

**Implementierungsschritte:**
1. `mmap(0, 16, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0)` vor dem Fork
2. `alive`-Flag auf 1 setzen, `pongReceived` auf 0
3. `fork()` via `std.process`
4. Child: schreibt PINGs, prüft `alive`-Flag alle 5s, `_exit(0)` wenn Flag = 0
5. Parent: bei eingehender PONG-Nachricht `pongReceived=1` ins SHM schreiben
6. `CastHeartbeatCheck`: liest `pongReceived`, resettet auf 0, inkrementiert `missedPongs` wenn kein PONG seit letztem PING; bei `missedPongs >= 3` → `CAST_DEAD`
7. `CastHeartbeatStop`: `alive=0` ins SHM, `waitpid(childPid)` um Zombie zu vermeiden

**Akzeptanzkriterium:** Heartbeat-Child läuft stabil im Hintergrund. Elternprozess empfängt PONGs und `missedPongs` bleibt 0. Nach `CastHeartbeatStop` kein Zombie-Prozess in `ps aux`.

---

### WP-CAST-06 — Connection-Channel (`std/net/cast_connection.lyx`)

**Ziel:** Virtuelle Verbindungen zu Receiver und App aufbauen/trennen.

**Datei:** `std/net/cast_connection.lyx`

**Namespace:** `urn:x-cast:com.google.cast.tp.connection`

**Hintergrund:** Das Cast-Protokoll hat zwei Ebenen virtueller Verbindungen:
1. **Device-Level**: `source_id="sender-0"` → `destination_id="receiver-0"` (immer zuerst)
2. **App-Level**: `source_id="sender-0"` → `destination_id=<transportId der gestarteten App>` (nach LAUNCH)

Jede Ebene braucht ein separates CONNECT-Paket.

**Funktionen:**
```lyx
pub fn CastConnectDevice(t: int64): int64;
// Sendet CONNECT an receiver-0. Muss direkt nach TLS-Handshake aufgerufen werden.

pub fn CastConnectApp(t: int64, transportId: int64): int64;
// Sendet CONNECT an <transportId> (aus ReceiverStatus.applications[0].transportId)

pub fn CastDisconnectApp(t: int64, transportId: int64): int64;
// Sendet CLOSE an <transportId>
```

**Implementierungsdetail:** `source_id` = `"sender-0"` (statisch), `destination_id` = `"receiver-0"` oder transportId. Payload: `{"type":"CONNECT","userAgent":"LyxCast/1.0"}`.

**Akzeptanzkriterium:** Nach `CastConnectDevice` antwortet der Chromecast im Receiver-Namespace (kein sofortiges Trennen).

---

### WP-CAST-07 — Receiver-Channel (`std/net/cast_receiver.lyx`)

**Ziel:** Apps auf dem Chromecast starten/stoppen und den Gerätestatus abfragen.

**Datei:** `std/net/cast_receiver.lyx`

**Namespace:** `urn:x-cast:com.google.cast.receiver`

**Wichtige App-IDs:**
```lyx
pub con CAST_APP_DEFAULT_MEDIA: int64 := "CC1AD845";  // Standard-Medienempfänger
pub con CAST_APP_YOUTUBE:       int64 := "233637DE";
pub con CAST_APP_NETFLIX:       int64 := "CA5E8412";
```

**Ablauf LAUNCH:**
1. `CastReceiverLaunch(t, "CC1AD845", reqId)` senden
2. Warten auf `RECEIVER_STATUS`-Antwort (Typ `"RECEIVER_STATUS"`)
3. Aus der Antwort `applications[0].transportId` und `applications[0].sessionId` extrahieren
4. Danach `CastConnectApp(t, transportId)` aufrufen (WP-CAST-06)

**Datenstrukturen:**
```lyx
pub type CastReceiverStatus = struct {
    sessionIdPtr:   int64;
    sessionIdLen:   int64;
    transportIdPtr: int64;
    transportIdLen: int64;
    appIdPtr:       int64;
    appIdLen:       int64;
    volume:         int64;   // 0-100
    muted:          int64;   // bool
};
```

**Funktionen:**
```lyx
pub fn CastReceiverLaunch(t: int64, appId: int64, reqId: int64): int64;
pub fn CastReceiverStop(t: int64, sessionId: int64, reqId: int64): int64;
pub fn CastReceiverGetStatus(t: int64, reqId: int64): int64;

// Parst empfangene RECEIVER_STATUS-Nachricht
pub fn CastReceiverParseStatus(json: int64, jsonLen: int64, out: int64): int64;
// out = Pointer auf CastReceiverStatus-Struct (caller-allocated)
```

**JSON-Parsing-Strategie:** Einfaches Substring-Suchen für `"transportId"`, `"sessionId"`, `"appId"` da keine komplexe verschachtelte JSON-Navigation nötig. Alternativ: `std.json`-Parser für saubere Lösung.

**Akzeptanzkriterium:** Nach `CastReceiverLaunch` mit `CC1AD845` erscheint auf dem Chromecast-Gerät der Standard-Medienempfänger (schwarzer Hintergrund mit Cast-Logo). `transportId` wird korrekt extrahiert.

---

### WP-CAST-08 — Media-Channel (`std/net/cast_media.lyx`)

**Ziel:** Medien laden, abspielen, pausieren, stoppen und Status abfragen.

**Datei:** `std/net/cast_media.lyx`

**Namespace:** `urn:x-cast:com.google.cast.media`

**Wichtig:** Media-Nachrichten gehen an `destination_id = transportId` (nicht an `"receiver-0"`). Diese ID stammt aus WP-CAST-07.

**Stream-Typen:**
```lyx
pub con CAST_STREAM_NONE:      int64 := "NONE";
pub con CAST_STREAM_BUFFERED:  int64 := "BUFFERED";   // VOD (Video on Demand)
pub con CAST_STREAM_LIVE:      int64 := "LIVE";        // Live-Stream
```

**LOAD-Payload (vollständig):**
```json
{
  "type": "LOAD",
  "requestId": 1,
  "autoplay": true,
  "currentTime": 0,
  "media": {
    "contentId": "<URL>",
    "contentType": "<MIME>",
    "streamType": "BUFFERED",
    "metadata": {
      "type": 0,
      "title": "LyxCast",
      "images": []
    }
  }
}
```

**Datenstruktur:**
```lyx
pub type CastMediaStatus = struct {
    mediaSessionId:  int64;
    currentTime:     int64;   // Sekunden (Integer-Teil)
    playerState:     int64;   // 0=IDLE 1=PLAYING 2=BUFFERING 3=PAUSED
    idleReason:      int64;   // 0=none 1=FINISHED 2=CANCELLED 3=INTERRUPTED 4=ERROR
};
```

**Funktionen:**
```lyx
pub fn CastMediaLoad(t: int64, transportId: int64, url: int64, mime: int64,
                     streamType: int64, reqId: int64): int64;

pub fn CastMediaPlay(t: int64, transportId: int64, sessionId: int64, reqId: int64): int64;
pub fn CastMediaPause(t: int64, transportId: int64, sessionId: int64, reqId: int64): int64;
pub fn CastMediaStop(t: int64, transportId: int64, sessionId: int64, reqId: int64): int64;
pub fn CastMediaSeek(t: int64, transportId: int64, sessionId: int64,
                     timeSec: int64, reqId: int64): int64;
pub fn CastMediaGetStatus(t: int64, transportId: int64, reqId: int64): int64;

pub fn CastMediaParseStatus(json: int64, jsonLen: int64, out: int64): int64;
```

**Akzeptanzkriterium:** Nach `CastMediaLoad` mit Big-Buck-Bunny-URL beginnt das Video auf dem Gerät zu spielen. `CastMediaPause` friert das Bild ein, `CastMediaPlay` setzt fort.

---

### WP-CAST-09 — High-Level SDK API (`std/net/cast.lyx`)

**Ziel:** Alles hinter einer einzigen sauberen API verbergen. Die Fassade, die Anwendungscode benutzt.

**Datei:** `std/net/cast.lyx` (importiert alle cast_*.lyx-Module)

**Toplevel-Datenstruktur:**
```lyx
pub type CastDevice = struct {
    ip:       int64;
    port:     int64;
    namePtr:  int64;
    nameLen:  int64;
    modelPtr: int64;
    modelLen: int64;
};

pub type CastDeviceList = struct {
    items:    int64;   // Pointer auf CastDevice-Array (16 Slots max)
    count:    int64;
};

pub type CastClient = struct {
    transport:    CastTransport;
    heartbeat:    CastHeartbeat;
    reqIdCounter: int64;
    sessionIdPtr: int64;    // Aus ReceiverStatus
    sessionIdLen: int64;
    transportIdPtr: int64;  // App-transportId
    transportIdLen: int64;
    mediaSessionId: int64;
    connected:    int64;
};
```

**Öffentliche API:**
```lyx
// Schritt 1: Geräte suchen
pub fn CastDiscover(timeoutSec: int64): CastDeviceList;

// Schritt 2: Verbinden (TLS + CONNECT device-level)
pub fn CastConnect(device: int64): CastClient;

// Schritt 3: Medien-App starten (LAUNCH + CONNECT app-level)
pub fn CastLaunchMedia(client: int64): int64;   // 0=ok, <0=Fehler

// Schritt 4: URL abspielen (LOAD)
pub fn CastPlayMedia(client: int64, url: int64, mime: int64): int64;

// Steuerung
pub fn CastPlay(client: int64): int64;
pub fn CastPause(client: int64): int64;
pub fn CastStop(client: int64): int64;
pub fn CastSeek(client: int64, timeSec: int64): int64;

// Event-Pump: empfangene Nachrichten verarbeiten + Heartbeat-Status prüfen
// Kein striktes Timing mehr nötig – Heartbeat läuft im Child-Prozess
pub fn CastTick(client: int64): int64;   // Gibt CAST_OK oder CAST_DEAD zurück

// Status
pub fn CastIsConnected(client: int64): int64;

// Trennen
pub fn CastDisconnect(client: int64): void;
```

**`CastTick`-Logik:**
1. `CastTransportRecv` mit Timeout 100ms → falls Daten: `CastMsgDecode`
2. Auf Namespace prüfen und an richtigen Handler routen:
   - `tp.heartbeat` + `PONG` → `CastHeartbeatHandlePong` (schreibt ins SHM)
   - `tp.heartbeat` + `PING` → PONG direkt senden (Chromecast pingt gelegentlich zurück)
   - `cast.receiver` + `RECEIVER_STATUS` → `sessionId`/`transportId` aktualisieren
   - `cast.media` + `MEDIA_STATUS` → `mediaSessionId`/`playerState` aktualisieren
3. `CastHeartbeatCheck` → liest SHM, prüft `missedPongs`
4. Gibt `CAST_DEAD` zurück wenn `missedPongs >= 3` oder Child-Prozess unerwartet beendet

> Kein Timing-Druck mehr: Der PING wird vom Child-Prozess gesendet, unabhängig davon wie oft `CastTick` aufgerufen wird.

**Akzeptanzkriterium:** Das in der Vision gezeigte Beispielprogramm kompiliert und läuft ohne Abstürze durch.

---

### WP-CAST-10 — Demo-Applikation (`test_cast.lyx`)

**Ziel:** Vollständige Demonstration und manueller Integrationstest des SDKs.

**Datei:** `test_cast.lyx` (im Projektstamm, analog zu `test_mqtt.lyx`)

**Funktionsumfang:**

```
Aufruf:  lyxc test_cast.lyx && ./test_cast [<IP>] [<URL>]

Ohne Argumente:
  - mDNS-Scan für 5 Sekunden
  - Alle gefundenen Geräte auflisten
  - Mit dem ersten gefundenen Gerät verbinden
  - Big-Buck-Bunny-URL laden und 30 Sekunden abspielen
  - Danach pausieren (5s), dann stoppen

Mit <IP>:
  - mDNS-Scan überspringen, direkt zu IP:8009 verbinden

Mit <URL>:
  - Diese URL statt Big-Buck-Bunny verwenden
```

**Ausgabe-Beispiel:**
```
[CastDiscover] Suche via mDNS (5s)...
[CastDiscover] 2 Gerät(e) gefunden:
  [0] "Wohnzimmer TV"    192.168.1.42:8009  (Chromecast Ultra)
  [1] "Schlafzimmer Hub" 192.168.1.55:8009  (Google Nest Hub)
[CastConnect] Verbinde mit 192.168.1.42:8009...
[CastConnect] TLS-Handshake OK
[CastConnect] CONNECT device-level OK
[CastLaunchMedia] Starte CC1AD845...
[CastLaunchMedia] transportId=web-5  sessionId=...  OK
[CastPlayMedia] Lade https://...BigBuckBunny.mp4
[CastPlayMedia] mediaSessionId=1  PLAYING
[   5s] Status: PLAYING  position=5s
[  10s] Status: PLAYING  position=10s
...
[  30s] CastPause → PAUSED
[  35s] CastStop  → IDLE
[CastDisconnect] Verbindung getrennt.
```

**Akzeptanzkriterium:** Demo läuft ohne Abstürze auf einem echten Chromecast durch. Video ist tatsächlich auf dem Gerät sichtbar.

---

### WP-CAST-11 — Makefile-Integration & Kompilierung

**Ziel:** SDK-Module korrekt im Build-System verankern.

**Änderungen:**

1. **`std/net/cast_proto.lyx`** → kompilieren zu `std/net/cast_proto.lyu`
2. **`std/net/cast_transport.lyx`** → `std/net/cast_transport.lyu`
3. **`std/net/cast_json.lyx`** → `std/net/cast_json.lyu`
4. **`std/net/cast_heartbeat.lyx`** → `std/net/cast_heartbeat.lyu`
5. **`std/net/cast_connection.lyx`** → `std/net/cast_connection.lyu`
6. **`std/net/cast_receiver.lyx`** → `std/net/cast_receiver.lyu`
7. **`std/net/cast_media.lyx`** → `std/net/cast_media.lyu`
8. **`std/net/cast.lyx`** → `std/net/cast.lyu`
9. **`std/net/mdns.lyx`** → `std/net/mdns.lyu`

**Makefile-Einträge** (analog zu mqtt/http/dns):
```makefile
std/net/mdns.lyu: std/net/mdns.lyx std/net/socket.lyu std/net/types.lyu
	$(LYXC) std/net/mdns.lyx

std/net/cast_proto.lyu: std/net/cast_proto.lyx
	$(LYXC) std/net/cast_proto.lyx

# ... (alle cast_*.lyu targets)

std/net/cast.lyu: std/net/cast.lyx std/net/cast_proto.lyu std/net/cast_transport.lyu \
    std/net/cast_json.lyu std/net/cast_heartbeat.lyu std/net/cast_connection.lyu \
    std/net/cast_receiver.lyu std/net/cast_media.lyu std/net/mdns.lyu
	$(LYXC) std/net/cast.lyx

test_cast: test_cast.lyx std/net/cast.lyu
	$(LYXC) test_cast.lyx -o test_cast
```

**Linker-Flags:** Kein neuer Linker-Bedarf – OpenSSL bereits via `std.net.tls` eingebunden.

**Akzeptanzkriterium:** `make test_cast` läuft ohne Fehler durch. `./test_cast --help` gibt Verwendungshinweis aus.

---

## Implementierungsreihenfolge (Empfohlen)

```
WP-CAST-02  (Protobuf-Codec)          ← keine Abhängigkeiten, gut isoliert testbar
    ↓
WP-CAST-04  (JSON-Builder)            ← nutzt nur String-Ops
    ↓
WP-CAST-03  (Frame-Transport)         ← baut auf std.net.tls auf
    ↓
WP-CAST-01  (mDNS Discovery)          ← unabhängig, parallel möglich
    ↓
WP-CAST-05  (Heartbeat)
WP-CAST-06  (Connection)              ← beide bauen auf Transport + JSON auf
    ↓
WP-CAST-07  (Receiver)
    ↓
WP-CAST-08  (Media)
    ↓
WP-CAST-09  (High-Level API)          ← fasst alle Schichten zusammen
    ↓
WP-CAST-10  (Demo)
    ↓
WP-CAST-11  (Makefile)
```

---

## Referenzen & Protokoll-Ressourcen

| Ressource                    | Zweck                                              |
|------------------------------|----------------------------------------------------|
| `pychromecast` (Python)      | JSON-Payloads aller Namespaces nachschlagen         |
| `node-castv2` (JS)           | Wire-Format-Referenz (Protobuf-Framing)            |
| `cast_channel.proto`         | Offizielle Protobuf-Schema-Definition              |
| Wireshark Filter             | `tcp.port == 8009` + TLS-Decrypt via Keylog-File   |
| RFC 6762                     | mDNS-Spezifikation (Multicast DNS)                 |
| RFC 6763                     | DNS-SD (Service Discovery über mDNS)               |

**Wireshark-Tipp:** Chrome mit `SSLKEYLOGFILE=/tmp/keys.log` starten, dann in Wireshark unter *Edit → Preferences → Protocols → TLS* den Key-Log-File eintragen. Danach ist der Cast-Traffic auf Port 8009 im Klartext lesbar.

---

## Risiken & Offene Fragen

| # | Risiko | Mitigation |
|---|--------|------------|
| R1 | `std.thread` ist nicht funktional (Skeleton) | `fork()` via `std.process` für Heartbeat-Child – funktioniert, solange nur Child schreibt und Parent liest |
| R2 | mDNS benötigt `IP_ADD_MEMBERSHIP` Syscall nicht in socket.lyx | Prüfen ob `setsockopt`-Wrapper vorhanden; ggf. rohen Syscall nutzen |
| R3 | Google könnte Protokoll-Details in neuen Firmware-Versionen ändern | Gegen mehrere Geräteversionen testen; pychromecast als Referenz |
| R4 | `clock_gettime` für Heartbeat-Timing | Bereits in anderen Modulen vorhanden – direkt verwenden |
| R5 | Maximale Payload-Größe (64KB) könnte für lange URLs zu knapp sein | Puffer auf 256KB auslegen, Konstante `CAST_MAX_FRAME` einführen |
