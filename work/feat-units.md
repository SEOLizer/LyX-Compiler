# Feature-Erweiterungspotenzial: std/-Units

Stand: 2026-05-31 — aktualisiert nach Implementierung FEAT-02/03/04/05/07/11  
Alle hier aufgeführten Lücken wurden gegen den tatsächlichen Funktionsbestand der `.lyx`-Quelldateien geprüft.  
Bugs/Stubs → siehe `work/fix-units.md`.

## Architekturprinzip: Keine unnötigen externen Bibliotheken

Algorithmen und Datenstrukturen werden **nativ in Lyx** implementiert – keine `extern fn … link "libX"` für Dinge, die wir selbst schreiben können (Mathe, Hashing, String-Ops, Codecs, Protokolle).

Externe Bibliotheken sind **nur dort erlaubt**, wo sie Fremdsysteme repräsentieren, die wir nicht selbst betreiben:

| Erlaubt | Begründung |
|---------|-----------|
| `libssl / libcrypto` (OpenSSL) | TLS ist sicherheitskritisch; eigene Krypto-Implementierung wäre fahrlässig |
| ALSA-Syscalls (`/dev/snd`) | Hardware-Abstraktion des Betriebssystems |
| mpg123 | Akzeptiert bis eine native MP3-Decode-Unit vorhanden ist |
| MySQL/MariaDB Wire-Protokoll | Wird bereits nativ über TCP implementiert – kein `libmysqlclient` |

Nicht erlaubt: `libm` (Mathe), `libpthread` (Threads), `libz` (Kompression), `libpcre` (Regex), `libcurl` (HTTP) – diese werden in Lyx selbst implementiert.

---

## Priorität 1 — Hohe Nachfrage, direkte Auswirkung auf viele Module

---

### FEAT-01 — `std/net/http.lyx`: Fehlende HTTP-Methoden und Header-API

**Ist-Zustand:** `HTTPGet`, `HTTPPost`, `HTTPSend` (manuell), `HTTPResponseFree`.  
Response-Parsing: nur Status-Code und Content-Length.

**Fehlende Features:**

| Feature | Beschreibung |
|---------|-------------|
| `HTTPPut / HTTPDelete / HTTPPatch / HTTPHead` | Verbreitete REST-Methoden fehlen komplett |
| Custom Request Headers | Kein API zum Setzen beliebiger Header (`Authorization`, `Accept`, `X-Custom`) |
| Response Headers lesen | Response-Struct hat nur Body; Header wie `Content-Type`, `Location`, `Set-Cookie` nicht auslesbar |
| 3xx Redirect-Folgen | Redirects müssen manuell behandelt werden |
| Bearer- / Basic-Auth-Helper | `HTTPSetBearerToken(req, token)` / `HTTPSetBasicAuth(req, user, pass)` |
| Chunked Transfer Encoding | Streaming-Responses werden nicht korrekt gelesen |
| Timeout konfigurieren | Kein `SO_RCVTIMEO` pro Request |
| Multipart/form-data Builder | Datei-Upload nicht möglich |

---

### FEAT-02 — `std/fs.lyx`: Glob/Wildcard-Matching fehlt noch

**Erledigtes Ist-Zustand:** `MkDir`, `MkDirAll`, `ReadDir` (via `DirList`), `FileStat`, `FileExists`,
`FileCopy`, `FileMove`, `Chmod`, `Symlink`, `Readlink`, `MkTemp` — alle vorhanden. ✅

**Noch fehlend:**

| Feature | Funktion |
|---------|---------|
| Glob/Wildcard-Matching | `FileGlob("*.lyx")` → Liste passender Pfade |

---

## Priorität 2 — Mittlere Nachfrage / spezifische Anwendungsfälle

---

### FEAT-06 — `std/net/tls.lyx`: Server-seitiges TLS fehlt

**Ist-Zustand:** `TLSInit`, `TLSConnect` (Client), `TLSRead`, `TLSWrite`, `TLSClose`, `TLSFree`. Kein Verify-Modus-Parameter.

**Fehlende Features:**

| Feature | Beschreibung |
|---------|-------------|
| `TLSAccept` | Server-seitig: `SSL_accept()` nach `TCPListenerAccept` |
| `TLSInitServer` | Kontext mit Zertifikat + Private Key laden (`SSL_CTX_use_certificate_file`, `SSL_CTX_use_PrivateKey_file`) |
| ALPN | `SSL_CTX_set_alpn_protos` für HTTP/2, gRPC |
| Cipher-Suite-Selektion | `SSL_CTX_set_cipher_list` |
| Client-Zertifikat-Auth | `SSL_CTX_set_verify(SSL_VERIFY_PEER)` + Client-Cert laden |
| Verify-Modus als Parameter | `TLSConnectEx(ctx, fd, host, verifyMode)` statt hardcoded NONE/PEER |
| TLS-Fehlerdetails | `TLSGetErrorString()` via `ERR_get_error` / `ERR_error_string` |
| Session Resumption | `SSL_CTX_set_session_cache_mode` |

---

### FEAT-07 — `std/hash.lyx`: HMAC-MD5 und xxHash64 fehlen noch

**Erledigtes:** SHA-256 Multi-Block (`SHA256Init/Update/Final`), HMAC-SHA256, HashMap. ✅

**Noch fehlend:**

| Feature | Beschreibung |
|---------|-------------|
| HMAC-MD5 | Für Legacy-Protokolle (IMAP CRAM-MD5 etc.) |
| xxHash64 | Schnellster nicht-kryptografischer Hash |

---

### FEAT-08 — `std/db/mysql.lyx`: Prepared Statements und Transaktionen fehlen

**Ist-Zustand:** `MySQLConnect`, `MySQLQuery` (Text-Protokoll), `MySQLFetchRow`, `MySQLFreeResult`, `MySQLError/Errno`, `MySQLAffectedRows/InsertId`, `MySQLNumFields/NumRows`, `MySQLDataSeek`, `MySQLGetFieldName/Type/Length`.

**Fehlende Features:**

| Feature | Funktion |
|---------|---------|
| Prepared Statements | `MySQLPrepare(conn, sql)` → stmt, `MySQLBindInt/BindStr(stmt, idx, val)`, `MySQLExecute(stmt)` |
| Transaktionen | `MySQLBegin(conn)`, `MySQLCommit(conn)`, `MySQLRollback(conn)` |
| Mehrere Resultsets | `MySQLNextResult(conn)` für Stored Procedures / mehrere Statements |
| Escape-Funktion | `MySQLEscapeString(conn, s)` – Schutz gegen SQL-Injection |
| Ping / Reconnect | `MySQLPing(conn)`, Auto-Reconnect bei lost connection |
| Binary Protocol | Prepared Statements nutzen Binary-Protokoll (effizientere Typen) |

---

### FEAT-09 — `std/db/redis.lyx`: Transaktionen, Pub/Sub, Pipeline fehlen

**Ist-Zustand:** String (GET/SET/DEL/EXISTS/TTL/EXPIRE), List (L/RPUSH, L/RPOP, LRANGE, LLEN), Hash (HSET/HGET/HGETALL/HDEL/HINCRBY), Set (SADD/SREM/SISMEMBER/SINTER/SUNION), ZSet (ZADD).

**Fehlende Features:**

| Feature | Funktion |
|---------|---------|
| Transaktionen | `RedisMulti(conn)`, `RedisExec(conn)`, `RedisDiscard(conn)` |
| Pub/Sub | `RedisSubscribe(conn, channel)`, `RedisPublish(conn, channel, msg)`, `RedisReceiveMessage(conn)` |
| Pipelining | `RedisPipelineBegin/Send/Flush` – mehrere Befehle ohne Round-Trip |
| INCR / DECR | Atomares Inkrementieren (fehlt bei String-Ops) |
| SCAN | `RedisScan(conn, cursor, pattern)` – Schlüssel iterieren ohne KEYS * |
| GETSET / SETNX | Atomares Compare-and-Set |
| AUTH | `RedisAuth(conn, password)` |
| SELECT | `RedisSelect(conn, db)` – Datenbank wechseln |
| PEXPIRE / EXPIREAT | Zeitgesteuerte Schlüssel mit Millisekunden-Präzision |

---

### FEAT-10 — `std/regex.lyx`: Keine Capture-Group-Extraktion, kein Alternation-Operator

**Ist-Zustand:** `Match`, `Search`, `Replace`, compilierte Varianten (`RegexSearchCompiled`, `RegexMatchCompiled`, `RegexReplaceCompiled`), `RegexMatchEx/SearchEx` mit Flags (case-insensitive etc.).

**Fehlende Features:**

| Feature | Beschreibung |
|---------|-------------|
| Capture-Group-Extraktion | `RegexCapture(pattern, text, groupIdx): pchar` – Treffer-Substrings zurückgeben |
| Alle Treffer finden | `RegexFindAll(pattern, text): StringList` |
| Alternation `\|` | `foo\|bar` – Pattern-OR fehlt im Parser |
| Lookahead/Lookbehind | `(?=...)`, `(?!...)`, `(?<=...)` |
| Ergebnis-Positionen | `RegexSearchSpan(pattern, text, startOut, endOut)` – Start/End des Treffers |
| Replace mit Capture | `RegexReplace` mit `\1`, `\2` Backreferenz-Substitution |
| Named Groups | `(?P<name>...)` und Lookup per Name |

---

### FEAT-12 — `std/net/dns.lyx`: CAA/DNSSEC fehlen, kein System-Resolver

**Ist-Zustand:** Sehr vollständig – A, AAAA, CNAME, MX, NS, TXT, SOA, PTR, SRV mit Google/Cloudflare-Shortcuts.

**Fehlende Features (kleine Lücken):**

| Feature | Beschreibung |
|---------|-------------|
| CAA-Record | `DNSResolveCAA` – Certification Authority Authorization |
| DS / DNSKEY | DNSSEC-Validierungsrecords |
| System-Resolver | `DNSResolveSystem(host)` → `/etc/resolv.conf` parsen statt hartkodierter IP |
| DoH (DNS over HTTPS) | `DNSResolveDoH(host)` via `https://dns.google/dns-query` |
| Response-Caching | In-Memory TTL-Cache für häufige Lookups |
| Reverse-Lookup für IPv6 | `DNSResolvePtr6(ipv6)` → `ip6.arpa`-Format |

---

### FEAT-13 — `std/net/mqtt.lyx`: QoS 1/2, Retained Messages, Last Will fehlen

**Ist-Zustand:** Verbindung, SUBSCRIBE, PUBLISH (QoS 0), PINGREQ/PINGRESP, DISCONNECT, grundlegendes CONNACK-Parsing.

**Fehlende Features:**

| Feature | Beschreibung |
|---------|-------------|
| QoS 1 vollständig | PUBACK senden/empfangen, Retry bei Timeout |
| QoS 2 vollständig | PUBREC/PUBREL/PUBCOMP-Handshake |
| Last Will & Testament | Im CONNECT-Paket konfigurierbar |
| Retained Messages | Retain-Flag in PUBLISH setzen |
| Clean Session Flag | Im CONNECT konfigurierbar |
| MQTTS (TLS) | Port 8883 + TLSConnect wrappen |
| Keep-Alive Timer | Automatisches PINGREQ wenn Inaktivität |
| Persistent Session | Pending QoS-1/2-Messages über Reconnect halten |

---

## Priorität 3 — Niedrige Nachfrage / spezifisch

---

### FEAT-14 — `std/vector.lyx`: Nur Vec2, kein Vec3/Vec4/Matrix

**Ist-Zustand:** 40+ Vec2-Operationen (Add/Sub/Mul, Dot/Cross2D, Normalize, Lerp, Rotate, etc.).

**Fehlende Features:**
- `Vec3` mit allen Äquivalenten (Cross3D als echter 3D-Cross-Product, Length3D etc.)
- `Vec4` / einfache Quaternion-Operationen
- `Matrix2x2 / Matrix3x3 / Matrix4x4` mit Mul, Invert, Transpose, Determinant
- Matrix-Vektor-Multiplikation `MatMulVec3`

---

### FEAT-16 — `std/lyxvision/`: Fehlende UI-Widgets und Layout-Manager

**Ist-Zustand:** Window, Button, Dialog, InputLine, ListView, StaticText, StaticLine, Frame, Group, Menu, TextDevice (Zeichenfläche), Terminal.

**Fehlende Features:**

| Widget / Feature | Priorität |
|----------------|----------|
| Layout-Manager (VBox, HBox, Grid) | Hoch – heute nur absolute Positionierung |
| ComboBox / Dropdown | Hoch |
| CheckBox | Hoch |
| RadioButton-Gruppe | Mittel |
| Slider / SpinBox | Mittel |
| ProgressBar | Mittel |
| TabWidget | Mittel |
| TreeView | Niedrig |
| Toolbar | Niedrig |
| Drag & Drop | Niedrig |

---

### FEAT-17 — `std/audio/`: Nur Wiedergabe, keine Aufnahme

**Ist-Zustand:** MP3/WAV-Parsing, ALSA-Playback, mpg123-Decoder-Integration.

**Fehlende Features:**
- Audio-Aufnahme via ALSA (`snd_pcm_open(SND_PCM_STREAM_CAPTURE)`)
- PCM-zu-MP3-Encoding (nativ: MDCT + Huffman-Codierung in Lyx, oder als separates `std/audio/mp3enc.lyx`)
- Sample-Rate-Konvertierung
- Lautstärkeregelung (Software-Mixer)
- Stereo-Panning
- WAV-Schreiben (aktuell nur Lesen)

---

### FEAT-18 — `std/url.lyx`: Parse unvollständig, kein Percent-Encoding

**Ist-Zustand:** URL-Struct mit allen Feldern (scheme, user, password, host, port, path, query, fragment). Hilfsfunktionen für Substring-Suche. `ParseString` beginnt, extrahiert aber nicht alle Felder zuverlässig.

**Fehlende Features:**
- Vollständige `URLParse(s)` – Schema, Auth, Host, Port, Pfad, Query, Fragment trennen
- `URLPercentEncode(s): pchar` / `URLPercentDecode(s): pchar`
- `URLQueryGet(url, key): pchar` – Query-Parameter lesen
- `URLQuerySet(url, key, value)` – Query-Parameter setzen
- `URLBuild(url): pchar` – Struct → String
- Relative URL auflösen: `URLResolve(base, relative)`

---

## Zusammenfassung nach Aufwand/Nutzen

| # | Unit | Status | Aufwand | Nutzen |
|---|------|--------|---------|--------|
| FEAT-01 | `std/net/http.lyx` | ⬜ Offen | Mittel | Sehr hoch |
| FEAT-02 | `std/fs.lyx` | 🟡 Fast fertig (nur FileGlob) | Klein | Sehr hoch |
| FEAT-06 | `std/net/tls.lyx` | ⬜ Offen | Mittel | Hoch |
| FEAT-07 | `std/hash.lyx` | 🟡 Fast fertig (HMAC-MD5, xxHash64) | Klein | Mittel |
| FEAT-08 | `std/db/mysql.lyx` | ⬜ Offen | Groß | Mittel |
| FEAT-09 | `std/db/redis.lyx` | ⬜ Offen | Mittel | Mittel |
| FEAT-10 | `std/regex.lyx` | ⬜ Offen | Mittel | Mittel |
| FEAT-12 | `std/net/dns.lyx` | ⬜ Offen | Klein | Niedrig |
| FEAT-13 | `std/net/mqtt.lyx` | ⬜ Offen | Mittel | Mittel |
| FEAT-14 | `std/vector.lyx` | ⬜ Offen | Mittel | Mittel |
| FEAT-16 | `std/lyxvision/` | ⬜ Offen | Groß | Mittel |
| FEAT-17 | `std/audio/` | ⬜ Offen | Groß | Niedrig |
| FEAT-18 | `std/url.lyx` | ⬜ Offen | Mittel | Mittel |

### Erledigte Features (entfernt aus Hauptliste)

| # | Unit | Abgeschlossen |
|---|------|--------------|
| FEAT-03 | `std/math.lyx` | GCD/LCM/IsPrime/NextPrime/IsPowerOfTwo/PopCount + SinF64/CosF64/TanF64/ExpF64/LogF64/SqrtF64/FloorF64/CeilF64/RoundF64/AbsF64/MinF64/MaxF64/PowF64 |
| FEAT-04 | `std/string.lyx` | StrJoin/StrStartsWith/StrEndsWith/StrPadLeft/StrPadRight/StrRepeat/StrToInt64/Int64ToStr |
| FEAT-05 | `std/list.lyx` | ListInt64 vollständig + Sort/Clone/Contains/Remove; Vec2List; RingBufferVec2; StaticList8/16; StackInt64; QueueInt64 |
| FEAT-07 | `std/hash.lyx` | SHA-256 Multi-Block (RFC-konform) + HMAC-SHA256 + HashMap |
| FEAT-11 | `std/log.lyx` | log_set_file/color/timestamp + log_infof/debugf/warnf/errorf |
| FEAT-02 | `std/fs.lyx` | MkDirAll + Readlink + MkTemp (nur FileGlob noch offen) |
