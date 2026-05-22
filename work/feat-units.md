# Feature-Erweiterungspotenzial: std/-Units

Stand: 2026-05-21  
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

### FEAT-02 — `std/fs.lyx`: Fehlende Verzeichnis- und Metadaten-Operationen

**Ist-Zustand:** `ReadFile`, `WriteFile`, `AppendFile`, `DeleteFile`, `FileSize`, `PathNormalize/Dir/Ext/Base/Resolve`.

**Fehlende Features:**

| Feature | Funktion |
|---------|---------|
| Verzeichnis erstellen | `MkDir(path)`, `MkDirAll(path)` (rekursiv) |
| Verzeichnis lesen | `ReadDir(path)` → Dateiliste via `opendir`/`readdir` |
| Datei-Metadaten | `FileStat(path)` → mtime, mode, uid/gid, inode |
| Datei existiert? | `FileExists(path): bool` (heute nur `FileSize` nutzbar) |
| Datei kopieren | `FileCopy(src, dst)` |
| Datei verschieben/umbenennen | `FileMove(src, dst)` via `rename()` |
| Dateiberechtigungen | `FileChmod(path, mode)` |
| Glob/Wildcard-Matching | `FileGlob("*.lyx")` → Liste passender Pfade |
| Temporäre Datei | `TmpFile()` → sicherer Temp-Pfad via `mkstemp` |
| Symlink | `Symlink(target, link)`, `Readlink(path)` |

---

### FEAT-03 — `std/math.lyx`: Fehlende f64-Mathematik und Zahlentheorie

**Ist-Zustand:** Vollständige Integer-Mathematik (Abs64, Min/Max, Sqrt64, Pow64, Clamp64, Sign64, Lerp64, Map64, Hypot64, Log2). Sin64/Cos64 als Fixed-Point (Microdegrees). RandomRange/RandomBetween. Atan2Microdegrees.

**Implementierungsprinzip:** Alle f64-Funktionen werden **nativ in Lyx** implementiert – kein `extern link "libm.so.6"`. Die Algorithmen sind bekannt und kompakt:

| Funktion | Nativer Algorithmus |
|---------|-------------------|
| `SinF64 / CosF64` | Taylor-Reihe um 0, Argument-Reduktion auf `[-π/2, π/2]` per Modulo |
| `TanF64` | `SinF64(x) / CosF64(x)`, gesonderte Behandlung nahe `π/2` |
| `AsinF64 / AcosF64` | Identität `asin(x) = atan(x / sqrt(1 - x²))` |
| `Atan2F64` | CORDIC-Iteration oder Minimax-Polynom (bereits ähnlich in `Atan2Microdegrees`) |
| `ExpF64` | Taylor-Reihe, Argument-Reduktion via `e^x = e^n · e^r` (n ganzzahlig) |
| `LogF64` | Identität `ln(x) = 2·arctanh((x-1)/(x+1))`, Range-Reduktion auf `[0.5,1]` |
| `Log10F64` | `LogF64(x) / LogF64(10.0)` – Konstante `ln(10)` hartcodieren |
| `SqrtF64` | Newton-Raphson: `x_n+1 = 0.5·(x_n + a/x_n)` (analog zu vorhandenem `Sqrt64`) |
| `PowF64` | `exp(y · ln(x))` für nicht-ganzzahlige Exponenten |
| `FloorF64 / CeilF64 / TruncF64 / RoundF64` | f64-zu-int64-Cast + Korrektur bei negativen Werten |
| `AbsF64 / MinF64 / MaxF64` | Direkte f64-Vergleiche |
| `NextPowerOfTwo / IsPowerOfTwo` | Bereits auskommentiert vorhanden – nur freischalten |
| `GCD / LCM` | Euklidischer Algorithmus (reine Integer-Logik) |
| `IsPrime / NextPrime` | Trial-Division bis `sqrt(n)` für kleine n; Sieb für Bereiche |

---

### FEAT-04 — `std/string.lyx`: Fehlende String-Hilfsfunktionen

**Ist-Zustand:** StrFind, StrSafeCharAt, case conversion, StrReverse, StrIndexOfChar/LastIndexOfChar, StrTrimWhitespace/StrTrim, StrSubstring, StrContains, StrIndexOf, StrReplace, StrCount, StrSplit.

**Fehlende Features:**

| Feature | Funktion |
|---------|---------|
| String zusammenfügen | `StrJoin(parts: int64, count: int64, delim: pchar): pchar` |
| Präfix/Suffix-Prüfung | `StrStartsWith(s, prefix): bool` / `StrEndsWith(s, suffix): bool` |
| String-Padding | `StrPadLeft(s, width, char)` / `StrPadRight(...)` |
| String-Wiederholung | `StrRepeat(s, n): pchar` |
| String → Integer | `StrToInt64(s): int64` mit Fehlerindikator (aktuell kein safe-Parse) |
| String → f64 | `StrToF64(s): f64` |
| Integer/f64 → String | `Int64ToStr(n, buf): pchar` / `F64ToStr(f, buf, decimals)` |
| Printf-ähnlich | `StrFormat(fmt, ...)` oder zumindest `StrAppendInt/StrAppendF64` |

---

### FEAT-05 — `std/list.lyx`: ListInt64 unvollständig, Vec2List/RingBuffer Stubs

**Ist-Zustand:** `ListInt64` (New/WithCapacity/Add/Get/Set/Len/Clear/IsEmpty), `StaticList8/16`, `StackInt64` (32-Slots), `QueueInt64` (32-Slots circular). `Vec2List` und `RingBufferVec2` sind Stubs (alle `return 0`).

**Fehlende Features:**

| Feature | Funktion |
|---------|---------|
| Element entfernen | `ListInt64RemoveAt(list, index)`, `ListInt64Remove(list, value)` |
| Einfügen an Position | `ListInt64InsertAt(list, index, value)` |
| Suchen | `ListInt64Contains(list, value): bool`, `ListInt64IndexOf(list, value): int64` |
| Sortieren | `ListInt64Sort(list)`, `ListInt64SortDesc(list)` |
| Kopieren | `ListInt64Clone(list): int64` |
| Vec2List implementieren | Alle 4 Vec2List-Funktionen sind `return 0`/leer |
| RingBufferVec2 implementieren | Alle 4 RingBuffer-Funktionen sind `return 0`/leer |
| StaticList32/64 | Größere Varianten der statischen Listen |

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

### FEAT-07 — `std/hash.lyx`: SHA-256 nur Single-Block, kein HashMap, kein HMAC

**Ist-Zustand:** FNV1a32/64, DJB2, Murmur2, CRC32, SHA256 (nur ≤55 Bytes!), MD5, HashPassword (FNV-basiert), HashTableIndex, HashInt64/Int32.

**Fehlende Features:**

| Feature | Beschreibung |
|---------|-------------|
| SHA-256 Multi-Block | Aktuell nur ein 512-Bit-Block → crash/falsch für Eingaben > 55 Bytes |
| HMAC-SHA256 | `HMAC(key, data): pchar` – für API-Signaturen, JWT etc. |
| Streaming-API | `SHA256Init / SHA256Update / SHA256Final` – für große Daten |
| HMAC-MD5 | Für Legacy-Protokolle (IMAP CRAM-MD5 etc.) |
| HashMap-Datenstruktur | `HashMapNew / HashMapSet / HashMapGet / HashMapDel` – im Quellcode auskommentiert |
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

### FEAT-11 — `std/log.lyx`: Kein Datei-Output, kein Timestamp, kein strukturiertes Logging

**Ist-Zustand:** `log_debug/info/warn/error/fatal`, Level-Filter, conditional logging, `log_section_enter/exit`, `log_app_start/end`, Callback-Registrierung. Alle Ausgaben gehen auf `stdout`.

**Fehlende Features:**

| Feature | Beschreibung |
|---------|-------------|
| Datei-Output | `log_set_file(path)` – in Datei statt stdout schreiben |
| Timestamps | Jeder Log-Eintrag mit `[YYYY-MM-DD HH:MM:SS]` |
| Strukturiertes Logging | `log_info_kv("event", "user_id", "42")` → JSON-Zeile |
| Log-Rotation | `log_set_max_size(bytes)` / `log_set_max_files(n)` |
| Farb-Output (ANSI) | Levels farblich differenzieren in Terminals |
| Format-String | `log_infof("user %d connected", uid)` |

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

### FEAT-15 — `std/hash.lyx` → HashMap-Datenstruktur

Der Quellcode enthält bereits auskommentierte Vorbereitung. Wird von vielen anderen Modulen (JSON, INI, DNS-Cache) benötigt.

**Fehlende Features:**
- `HashMapNew(capacity): int64`
- `HashMapSet(map, key: pchar, value: int64): void`
- `HashMapGet(map, key: pchar): int64`
- `HashMapHas(map, key: pchar): bool`
- `HashMapDel(map, key: pchar): void`
- `HashMapKeys(map, out): int64` – alle Schlüssel
- Load-Factor und automatisches Rehashing

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

| # | Unit | Aufwand | Nutzen |
|---|------|---------|--------|
| FEAT-01 | `std/net/http.lyx` | Mittel | Sehr hoch – betrifft alle HTTP-Client-Nutzung |
| FEAT-02 | `std/fs.lyx` | Mittel | Sehr hoch – mkdir/readdir fehlen überall |
| FEAT-03 | `std/math.lyx` | Mittel | Hoch – f64-Trig/Log/Exp nativ via Taylor/Newton |
| FEAT-04 | `std/string.lyx` | Klein | Hoch – StrJoin, StrStartsWith, Pad täglich genutzt |
| FEAT-05 | `std/list.lyx` | Klein-Mittel | Hoch – Remove/Sort/IndexOf fehlen |
| FEAT-06 | `std/net/tls.lyx` | Mittel | Hoch – Server-TLS Voraussetzung für HTTPS-Server |
| FEAT-07 | `std/hash.lyx` | Mittel | Hoch – SHA-256 multi-block + HashMap |
| FEAT-08 | `std/db/mysql.lyx` | Groß | Mittel – Prepared Statements für sichere Queries |
| FEAT-09 | `std/db/redis.lyx` | Mittel | Mittel – Transactions + Pub/Sub |
| FEAT-10 | `std/regex.lyx` | Mittel | Mittel – Capture Groups sehr häufig genutzt |
| FEAT-11 | `std/log.lyx` | Klein | Mittel – Datei-Output + Timestamps |
| FEAT-12 | `std/net/dns.lyx` | Klein | Niedrig – System-Resolver + CAA |
| FEAT-13 | `std/net/mqtt.lyx` | Mittel | Mittel – QoS 1/2 für produktiven Einsatz nötig |
| FEAT-14 | `std/vector.lyx` | Mittel | Mittel – Vec3/Matrix für 3D/ML |
| FEAT-15 | `std/hash.lyx` (HashMap) | Mittel | Hoch – fehlende Basisstruktur |
| FEAT-16 | `std/lyxvision/` | Groß | Mittel – Layout-Manager dringend |
| FEAT-17 | `std/audio/` | Groß | Niedrig – spezifisch |
| FEAT-18 | `std/url.lyx` | Mittel | Mittel – für HTTP/REST-Clients nötig |
