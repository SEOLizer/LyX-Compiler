# Fehlende Standard-Library Units

## Aktueller Bestand

### std/ (51 Units)
alloc, base64, buffer, circle, color, conv, country, crt, crt_raw, crypto (aes), datetime, env, error, fs, geo, hash, io, json, list, log, math, math_batch, os, pack, process, qbool, qt5_app, qt5_core, qt5_egl, qt5_gl, qt5_glx, rect, regex, result, sort, stats, stats_batch, string, system, time, url, uuid, vector, vector_batch, x11, xml, yaml, zlib

### std/net/ (20 Units)
asn1, bgp, dns, http, https, imap, ldap, mqtt, ntp, quic, sip, smtp, snmp, socket, ssh, syscalls, telnet, tls, types, whois

### std/validate/ (5 Units)
ean, iban, isbn, luhn, vat

### std/math/ (1 Unit)
constants

---

## Potenziell fehlende Units

### Text/Serialisierung
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `fmt` | Formatierte Ausgabe (like Go's fmt) | FEHLT |
| `bytes` | Byte-Slice Operationen | FEHLT (buffer.lyx existiert, aber nicht vollständig) |
| `text` | Text-Verarbeitung (Lines, Words) | FEHLT |
| `csv` | CSV Lesen/Schreiben | FEHLT |
| `xml` | XML Parsen/Generieren | ✅ VORHANDEN |
| `yaml` | YAML Parsen/Generieren | ✅ VORHANDEN |
| `toml` | TOML Parsen/Generieren | FEHLT |
| `ini` | INI-Dateien lesen/schreiben | FEHLT |
| `html` | HTML Parsen/Escaping | ✅ VORHANDEN |
| `markdown` | Markdown parsing | FEHLT |

### Datenbank/Storage
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `sqlite` | SQLite Datenbank | FEHLT |
| `redis` | Redis Client | FEHLT |
| `mongo` | MongoDB Client | FEHLT |
| `cache` | Caching Interface | FEHLT |

### Security/Crypto
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `crypto/aes` | AES encryption | ✅ VORHANDEN (soeben implementiert) |
| `crypto/sha` | SHA hashes | FEHLT |
| `crypto/hmac` | HMAC | FEHLT |
| `crypto/rand` | Zufallszahlen | FEHLT |
| `crypto/ecb` | Elliptic Curve | FEHLT |
| `jwt` | JSON Web Tokens | FEHLT |
| `oauth` | OAuth utilities | FEHLT |

### Netzwerk (zusätzlich zu std/net/)
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `net/websocket` | WebSocket Client/Server | FEHLT |
| `net/grpc` | gRPC Client/Server | FEHLT |
| `net/ftp` | FTP Client | FEHLT |
| `net/sftp` | SFTP Client | FEHLT |
| `net/smb` | SMB Client | FEHLT |
| `net/ntp` | (existiert bereits) | ✅ VORHANDEN |
| `net/radius` | RADIUS Client | FEHLT |

### Utilities
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `uuid` | UUID Generierung/Parsing | ✅ VORHANDEN |
| `base32` | Base32 encoding | FEHLT |
| `hex` | Hex encoding/decoding | TEILWEISE (in buffer.lyx) |
| `mime` | MIME types | FEHLT |
| `url` | (existiert bereits) | ✅ VORHANDEN |
| `uri` | URI parsing | TEILWEISE (in url.lyx) |

### Zeit/Datum
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `datetime` | (existiert bereits) | ✅ VORHANDEN |
| `cron` | Cron expression parsing | FEHLT |
| `tz` | Timezone database | FEHLT |

### Bildverarbeitung
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `image` | Bildverarbeitung (resize, crop) | FEHLT |
| `bmp` | BMP Format | FEHLT |
| `png` | PNG Format | FEHLT |
| `jpeg` | JPEG Format | FEHLT |

### Audio/Video
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `audio` | Audio utilities | FEHLT |
| `wav` | WAV Format | FEHLT |
| `mp3` | MP3 Format | FEHLT |

### System/OS
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `signal` | Signal handling | FEHLT |
| `exec` | Kommandoausführung | TEILWEISE (process.lyx) |
| `tty` | Terminal utilities | FEHLT |
| `pty` | PTY handling | FEHLT |
| `user` | User/Group info | FEHLT |

### Testing
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `testing` | Test framework | FEHLT |
| `mock` | Mocking utilities | FEHLT |
| `assert` | Assertions | FEHLT |

### Diverses
| Unit | Beschreibung | Status |
|------|--------------|--------|
| `sync` | Synchronisation (Mutex, WaitGroup) | FEHLT |
| `context` | Context handling | FEHLT |
| `errors` | Error wrapping/handling | TEILWEISE (error.lyx) |
| `iter` | Iterator patterns | FEHLT |
| `fnv` | FNV hash | FEHLT |
| `xxhash` | XXHash | TEILWEISE (hash.lyx) |

---

## Zusammenfassung

| Kategorie | Vorhanden | Fehlend |
|-----------|-----------|---------|
| Text/Serialisierung | 7 (json, regex, string, base64, xml, yaml, html) | ~4 |
| Database/Storage | 0 | ~4 |
| Crypto | 1 (aes) | ~5 |
| Netzwerk (erweitert) | 20 | ~7 |
| Utilities | 5+ | ~5 |
| Zeit/Datum | 2 (time, datetime) | ~2 |
| Bild/Audio | 0 | ~6 |
| System | 5+ | ~4 |
| Testing | 0 | ~3 |
| Diverses | 3+ | ~4 |

**Gesamt: ca. 35-45 fehlende Units**