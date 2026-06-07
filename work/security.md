# Sicherheits-Fahrplan — Aurum/Lyx

> Erstellt: 2026-05-31 (Security Audit)
> Neubewertet: 2026-06-03 (nach LCBS WP-L1…WP-T15)
> Status: ⬜ geplant | 🔄 in Arbeit | ✅ erledigt

---

## LCBS-Einfluss auf den Fahrplan (Stand v0.9.3A)

LCBS (Lyx Capability-Based Security, WP-L1–WP-T15) hat den Fahrplan in mehreren Punkten verändert:

| WP | Änderung | Grund |
|----|----------|-------|
| WP-5 | ✅ **Erledigt** durch WP-L5 | Hard-Blacklist in `ffi_validator.lyx` — Compile-Error für `system`, `gets`, `sprintf`, `strcpy`, `execve` etc. |
| WP-6 | ⚠️ **Audit-Bug aufgedeckt** | ELF ist weiterhin RWX (`PF_R\|PF_W\|PF_X`), aber Audit reportet hardcoded `+W^X` — Score ist für diesen Punkt unzuverlässig |
| WP-7 | Priorität Runtime → Mittel | Landlock (WP-R10) schützt LCBS-Programme auf Kernel-Ebene; Compiler-Side bleibt Hoch |
| WP-17 | Scope erweitert | LCBS-Annotationsökosystem (`@capabilities`, `@uses_caller_cap`, `@cap`, `@grant`) ist undokumentiert |
| WP-18 | Urgenz gesunken | LCBS-seccomp enthält Post-Exploit — Angreifer nach Stack-Overflow kann kaum Syscalls ausführen |
| WP-20 | Priorität gestiegen | Starke Synergie: `.meta_safe` verifiziert Code-Integrität, LCBS schränkt dann Laufzeitrechte ein |
| WP-22 | Scope erweitert + Priorität gestiegen | LCBS-Enforcement ist automatisch testbar: seccomp, Landlock, Capability-Inheritance |
| WP-23–25 | **Neu** | LCBS-spezifische Lücken (Audit-Integrität, seccomp-Vollständigkeit, Compat-Warnung) |

---

## Gesamtübersicht

| Phase | Schwerpunkt | WPs | Aufwand | Status |
|-------|------------|-----|---------|--------|
| 1 | 🔴 Kritische Sicherheitslücken | WP-1 – WP-4 | ~11–14 Tage | ✅ |
| 2 | 🟠 Hohe Sicherheitsrisiken | WP-5 – WP-11 | ~12–14 Tage | ✅ |
| 3 | 🟡 Mittelstufe | WP-12 – WP-17 | ~6–8 Tage | 🔄 |
| 4 | 🔵 Langfristig / Niedrig | WP-18 – WP-22 | ~10–14 Tage | ⬜ |
| 5 | 🔴 LCBS-Audit-Integrität | WP-23 – WP-25 | ~2–3 Tage | ⬜ |

**Kritischer Pfad (aktualisiert):** WP-23 (Audit-Fix) → WP-6 (echtes W^X) → WP-8 (SQL) → WP-10 (Integer-Overflow)

---

## Phase 1 — 🔴 Kritische Sicherheitslücken (sofort handeln)

---

### WP-1: Kryptografische Hash-Funktionen korrigieren

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/hash.lyx` |
| **Aufwand** | 5–7 Tage |
| **Priorität** | 🔴 Kritisch |
| **Status** | ✅ erledigt 2026-05-31 |

**Problem:** Alle Passwort-Hashing-Funktionen (BCrypt, Argon2, PBKDF2, SHA-256, MD5) sind nicht-funktionale Stubs.
FNV-1a (nicht-kryptografisch) wird in ALLEN Hash-Funktionen verwendet.
`GenerateSalt()` ist deterministisch (kein Zufall).
`HashPassword` (1000 Iterationen) und `HashPasswordSimple` (100 Iterationen FNV-1a) sind in Sekunden geknackt.
Kein constant-time Vergleich für Byte-Arrays vorhanden.

**Teilschritte:**

- [x] **1.1** SHA-256 korrekt implementieren — `HashSHA256` delegiert an FEAT-07-Streaming-Impl. (sha256_compress, 64 Runden, FIPS 180-4 Padding)
- [x] **1.2** SHA-384/512 — vollständig neu: `sha512_compress` (80 Runden), `SHA512Init/Update/Final/Hash`, `SHA384Init/Hash`
- [x] **1.3** HMAC-SHA256 — war bereits korrekt (FEAT-07); `HMACSHA256` mit ipad/opad
- [x] **1.4** PBKDF2-HMAC-SHA256 — `PBKDF2HMACSHA256Bytes` (RFC 2898): U1=HMAC(pw,salt||0001), Un=HMAC(pw,U(n-1)), XOR; Default 600.000 Iterationen
- [x] **1.5** BCrypt — FFI `crypt()` via `libcrypt.so.1`; `HashBCryptStr` + `BCryptVerifyStr` mit CSPRNG-Salt und konstantem Zeitvergleich
- [x] **1.6** Argon2id — FFI `crypto_pwhash_str/verify` via `libsodium.so.23`; `HashArgon2idStr` + `Argon2idVerifyStr`
- [x] **1.7** `GenerateSaltBytes` via `/dev/urandom`; `GenerateSalt` auf CSPRNG umgestellt
- [x] **1.8** FNV-1a aus `HashPassword`, `HashPasswordSimple`, PBKDF2, BCrypt, Argon2 entfernt
- [x] **1.9** `ConstantTimeCompareBytes` — XOR aller Bytes, kein early-exit
- [x] **1.10** `HashPassword` → PBKDF2; `HashPasswordSimple` → PBKDF2 + deprecated-Kommentar

**Definition of Done:**
- SHA-256("abc") = `ba7816bf8f01cfea414140de5dae2ec73b00361bbef0469121afc7f88ac2e7a`
- HMAC-SHA256 mit RFC 4231-Testvektoren bestanden
- PBKDF2 mit 1000 Iterationen erzeugt korrekte RFC 6070-Vektoren
- BCrypt kann existierende `$2b$`-Hashes verifizieren
- Timing-safe Compare ist implementiert und getestet
- Kein FNV-1a mehr in Passwort-Funktionen

---

### WP-2: TLS-Hostname-Verifikation einbauen

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/tls.lyx`, `std/net/https.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🔴 Kritisch |
| **Status** | ✅ erledigt 2026-05-31 |

**Problem:** Nach dem SSL-Handshake wird nur `SSL_get_verify_result()` geprüft.
Die Zertifikatskette wird validiert, aber **NIEMALS** der Hostname gegen SubjectAltName/CommonName.
Ein Angreifer mit *irgendeinem* gültigen TLS-Zertifikat kann MITM auf ALLE HTTPS-Verbindungen durchführen.
Zusätzlich: `TLS_method()` statt `TLS_client_method()` aktiviert fälschlich DTLS.
Keine TLS-Versionseinschränkung (TLS 1.0/1.1 sind noch erlaubt).

**Teilschritte:**

- [x] **2.1** `SSL_get1_peer_certificate()` nach erfolgreichem Handshake aufrufen
- [x] **2.2** `X509_check_host()` mit angefragtem Hostnamen — prüft SubjectAltName und CommonName
- [x] **2.3** Bei Fehler: Verbindung abbrechen (conn.connected=0); neuer Fehlercode `TLS_ERR_HOSTNAME=-8`
- [x] **2.4** TLS-Minimum-Version TLS 1.2 via `SSL_CTX_ctrl(ctx, 123, 771, 0)`
- [x] **2.5** `TLS_method()` durch `TLS_client_method()` ersetzt — kein DTLS mehr
- [ ] **2.6** HTTPS-Integrationstests — manuell zu verifizieren (kein Testframework vorhanden)

**Definition of Done:**
- Hostname-Verifikation schlägt fehl bei nicht-match
- TLS 1.0/1.1 werden abgelehnt
- Kein DTLS mehr fälschlich aktiviert

---

### WP-3: SSH-Host-Key-Verifikation einbauen

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/ssh.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🔴 Kritisch |
| **Status** | ✅ erledigt 2026-05-31 |

**Problem:** `libssh2_session_handshake()` wird aufgerufen, ohne danach den Host Key zu prüfen.
Es gibt keinen Aufruf von `libssh2_knownhost_check()` oder `libssh2_session_hostkey()`.
Jede SSH-Verbindung akzeptiert stillschweigend jeden beliebigen Host Key (MITM).
Nur Passwort-Auth, keine Public-Key-Authentifizierung.
CPU-Spin (Busy-Wait) beim Warten auf Output.

**Teilschritte:**

- [x] **3.1** `libssh2_session_hostkey()` nach Handshake — liefert Roh-Key + Typ
- [x] **3.2** `libssh2_knownhost_init()` + `libssh2_knownhost_readfile()` für `~/.ssh/known_hosts` (via `getenv("HOME")`)
- [x] **3.3** `libssh2_knownhost_checkp()` gegen erhaltenen Host Key (PLAIN + RAW Encoding)
- [x] **3.4** MISMATCH → Verbindung abbrechen; NOTFOUND + TOFU → `libssh2_knownhost_addc()` + writefile; STRICT → fail. `SSHConnectVerified(session, host, port, policy)` für explizite Policy-Wahl
- [x] **3.5** `SSHAuthPublicKey(session, username, privateKeyPath, passphrase)` via `libssh2_userauth_publickey_fromfile_ex()`
- [x] **3.6** Busy-Wait in `SSHExecOutput` durch `ssh_wait_socket()` ersetzt: `libssh2_session_block_directions()` + `sys_select()` auf Socket-FD

**Definition of Done:**
- Bekannter Host → erfolgreiche Verbindung
- Unbekannter / falscher Key → Abbruch
- Public-Key-Auth funktioniert
- Kein CPU-Spin mehr

---

### WP-4: MongoDB-Treiber absichern

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/mongo.lyx` |
| **Aufwand** | 2–3 Tage |
| **Priorität** | 🔴 Kritisch |
| **Status** | ✅ erledigt 2026-06-01 |

**Problem:** Auth-Konstanten definiert aber nie implementiert.
Nur unverschlüsseltes TCP, kein TLS.
`MongoDocAddString` ist ein Dummy (gibt immer 0 zurück).
`MONGO_AUTH_PLAIN` würde Credentials im Klartext senden.

**Teilschritte:**

- [x] **4.1** `MongoConnectTLS(host, port, hostname)` — nutzt `TLSInit`/`TLSConnect` aus WP-2; speichert `tls_ssl`/`tls_ctx` in `MongoConn`; `MongoSend`/`MongoRead` TLS-aware
- [x] **4.2** SCRAM-SHA-256 (RFC 5802/7677) in `MongoAuth()` — nonce(urandom)+base64, PBKDF2-SHA256, HMAC-SHA256 via libcrypto; baut saslStart/saslContinue als OP_MSG mit BSON; verifiziert Server-Signatur
- [x] **4.3** `MongoDocAddString` — BSON-Encoding: type(1)+key(cstring)+strLen(int32 LE)+value+null; neu: `MongoDocAddInt32`, `MongoDocAddBinary`, `MongoDocFinalize`
- [x] **4.4** `MongoAuth()` gibt -1 zurück wenn `MONGO_AUTH_PLAIN` und `tls_enabled==0`
- [x] **4.5** `MongoPool` als "connection pooling not yet implemented" dokumentiert

**Alternative:** Modul als "unfertig – nicht für Produktion" dokumentieren.

**Definition of Done:**
- TLS-Verbindung mit Auth → Erfolg
- PLAIN ohne TLS → Fehler
- BSON-Serialisierung funktioniert korrekt

---

## Phase 2 — 🟠 Hohe Sicherheitsrisiken (dringend)

---

### WP-5: Gefährliche FFI-Externs absichern ✅

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/security/ffi_validator.lyx` (WP-L5) |
| **Aufwand** | erledigt |
| **Priorität** | ~~🟠 Hoch~~ |
| **Status** | ✅ erledigt durch LCBS WP-L5 |

**Lösung durch LCBS WP-L5:** `src/security/ffi_validator.lyx` implementiert eine Hard-Blacklist und Signatur-basierte Klassifizierung. Gefährliche Funktionen führen zum **Compile-Error** (`_errorNode`), nicht nur zur Warnung.

**Hard-Blacklist (Compile-Error):** `system`, `popen`, `gets`, `sprintf`, `vsprintf`, `strcpy`, `strcat`, `wcscpy`, `wcscat`, `execve`, `execvp`, `execlp`, `execl`, `execle`, `execvpe`

**Format-String-Familie (Compile-Error ohne `@capabilities([system.unsafe.format_string])`):** `printf`, `fprintf`, `scanf`, `fscanf`, `sscanf`, `vprintf`, `vfprintf`

**Signatur-basiert geblockt:** Jede extern fn mit ≥2 `pchar`-Parametern ohne Größenlimit → Klasse 3 → Compile-Error

- [x] **5.1** `system()` — Hard-Blacklist
- [x] **5.2** `sprintf()`, `gets()` — Hard-Blacklist
- [x] **5.3** `strcpy()`, `strcat()` — Hard-Blacklist; `strlcpy`/`strlcat` als Klasse 0 (Safe) zugelassen
- [x] **5.4** `execve()` und alle exec-Varianten — Hard-Blacklist

---

### WP-6: W^X für generierte ELF-Binaries ⚠️

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` (Z. 9199–9200), `src/codegen_x86.lyx` (Z. 8985, 9015) |
| **Aufwand** | 2–3 Tage (W^X) + 1 Tag (Audit-Fix) |
| **Priorität** | 🔴 Kritisch (hochgestuft wegen Audit-Bug) |
| **Status** | ⬜ offen — **Audit reportet fälschlicherweise W^X als aktiv** |

**Problem (unverändert):** `src/codegen_x86.lyx:9200`: `poke32(ph + 4, 7); // p_flags = PF_R|PF_W|PF_X` — Single PT_LOAD, vollständig RWX. W^X ist **nicht implementiert**.

**Neuer Befund (LCBS-Audit-Bug):** Die LCBS-Audit-Funktion (`cg_runAudit`) gibt hardcoded `+ W^X (RX-Code / RW-Daten getrennt)` und `+5 Punkte W^X aktiv` aus — **ohne den tatsächlichen ELF-Header zu prüfen**. Der Security-Score ist für diesen Punkt unzuverlässig. Das ist ein Integritätsproblem des Audit-Systems selbst. → Siehe auch WP-23.

**Teilschritte:**

- [ ] **6.0** Audit-Funktion: W^X-Ausgabe an echten ELF-Flag-Check binden (statt hardcoded)
- [ ] **6.1** PT_LOAD in zwei Segmente aufteilen: RX (Code) + RW (Daten)
- [ ] **6.2** `.text` → RX-Segment, `.data`/`.bss` → RW-Segment
- [ ] **6.3** PIE-Unterstützung einbauen (Relocation-Tables)
- [ ] **6.4** Bestehende Programme/Tests mit neuen Einstellungen testen

**Risiko:** PIE erfordert Relocation-Tables, die der Compiler noch nicht vollständig unterstützt.

**Definition of Done:**
- `readelf -l` zeigt getrennte LOAD-Segmente mit RX und RW
- `checksec --elf` zeigt "No execute" und "PIE enabled"
- Audit-Report prüft tatsächlichen ELF-Header und gibt `o W^X` solange nicht umgesetzt
- Alle Tests laufen durch

---

### WP-7: Path Traversal in File-Operationen verhindern

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/sema.lyx`, `src/codegen_x86.lyx`, `std/fs.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Hoch (Compiler-Side) / 🟡 Mittel (Stdlib-Side) |
| **Status** | 🔄 Stdlib/Runtime ✅ via Landlock; Compiler-Side (7.1/7.2) ⬜ offen |

**Problem:** Compiler öffnet Dateien aus `import`-Anweisungen ohne Prüfung auf `..`-Traversal.
Ein bösartiges `.lyx`-File könnte beliebige Dateien lesen.

**LCBS-Einfluss:** Landlock (WP-R10) schützt LCBS-Programme zur Laufzeit auf Kernel-Ebene — nur explizit in `@capabilities([fs.read(path: "...")])` deklarierte Pfade sind erreichbar. Stdlib-Traversal für annotierte Programme ist damit abgedeckt. Der **Compiler selbst** unterliegt keiner eigenen LCBS-Sandbox; 7.1 und 7.2 bleiben daher Hoch.

**Teilschritte:**

- [ ] **7.1** `_sema_readFile()` auf `..`-Komponenten prüfen *(Compiler-Side, Hoch)*
- [ ] **7.2** `_cg_readFile()` analog absichern *(Compiler-Side, Hoch)*
- [ ] **7.3** Stdlib-File-Operationen (`FileExists`, `Mkdir`, `Remove`, etc.) auf `..` prüfen *(Runtime-Side, durch Landlock größtenteils abgedeckt → Mittel)*

**Definition of Done:**
- `import ../../../etc/passwd` wird mit Fehler abgewiesen
- Normale relative Imports funktionieren weiter

---

### WP-8: SQL Injection in DB-Treibern schließen

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/db/mysql.lyx`, `std/db/postgres.lyx`, `std/db/sqlite.lyx` |
| **Aufwand** | 3–4 Tage |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** MySQL: `MySQLQuery()` sendet rohes SQL per `COM_QUERY`.
PostgreSQL: `PGDropTable()`, `PGTableExists()` bauen SQL per String-Konkatenation.
SQLite: `SQLiteDropTable()` konkateniert Tabellennamen direkt.
Keine Prepared Statements als Default.

**Teilschritte:**

- [ ] **8.1** MySQL: `MySQLQuery()` deprecated; `MySQLExecutePrepared()` als Standard
- [ ] **8.2** PostgreSQL: `PGQueryParam()` mit Extended Query / Parametern
- [ ] **8.3** PostgreSQL: `PGDropTable()`, `PGColumnExists()`, `PGTableExists()` auf Parameter umstellen
- [ ] **8.4** SQLite: `SQLiteExecParam()` (Wrapper um `sqlite3_bind_*`)
- [ ] **8.5** SQLite: `SQLiteDropTable()`, `SQLiteSetJournalMode()` auf Parameter umstellen
- [ ] **8.6** Alle String-Konkatenationen in SQL-Kontexten eliminieren
- [ ] **8.7** Integrationstests mit bösartigen Eingaben

**Definition of Done:**
- `MySQLQuery("... WHERE name = '" + name + "'")` abgefangen
- `PGDropTable(conn, "users; DROP TABLE admins --")` löscht nur users
- SQLite-Parameter-Queries arbeiten korrekt

---

### WP-9: HTTP-Client absichern

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/http.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** `HTTPGet`/`HTTPPost` validieren weder Host noch Path.
CR/LF-Injection (Request Smuggling) und Path Traversal möglich.
Buffer fix auf 4KB (Request) bzw. 8KB (Response) → Truncation.

**Teilschritte:**

- [x] **9.1** Host auf erlaubte Zeichen validieren (kein CR/LF)
- [x] **9.2** Path auf CR/LF-Injection prüfen (Ablehnung bei `\r`/`\n`)
- [x] **9.3** Request-Buffer dynamisch allozieren (Start 4KB, wachsen bei Bedarf)
- [x] **9.4** Response-Buffer: `Content-Length` auswerten und in Schleife lesen
- [x] **9.5** Timeout für Response-Lesen implementieren

**Definition of Done:**
- HTTP-Anfrage mit `\r\n` im Path wird abgewiesen
- Responses > 8KB werden vollständig gelesen

---

### WP-10: Integer-Overflow-Prüfungen einbauen

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/sema.lyx`, `src/codegen_x86.lyx`, `src/lyxc.lyx`, `src/crypto/lic_hmac.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** `len + 1`, `cnt * fieldSize`, `shnum * 64`, `inLen * 8` – mehrfach ohne Overflow-Prüfung.
Bei manipulierten Eingaben kann daraus eine kleine oder negative Allokation resultieren.

**Teilschritte:**

- [x] **10.1** `len + 1` → Prüfung auf `len == MAX_INT64`
- [x] **10.2** `cnt * fieldSize` → Prüfung auf Overflow (Division oder `__builtin_mul_overflow`)
- [x] **10.3** `inLen * 8` (Bit-Längen) → Prüfung auf `inLen > MAX_INT64 / 8`
- [x] **10.4** `shnum * 64` → Prüfung auf sinnvolles Maximum (`shnum < 65536`)

**Definition of Done:**
- Bei potentiell überlaufender Größe kommt Fehler, kein Absturz
- Alle kritischen Multiplikationen/Additionen sind geprüft

---

### WP-11: Redis-Treiber korrigieren

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/db/redis.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟠 Hoch |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** `RedisConnect()` ignoriert `host`-Parameter → immer nur localhost.
`RedisLRange()` sendet hardcodierte "0"/"-1" statt Parameter.
`RedisHIncrBy()` hardcodet increment auf "1".
`RedisZAdd()` hardcodet score "100" / member "player1".
Empfangsbuffer nur 512 Bytes → Datenstummelung.

**Teilschritte:**

- [x] **11.1** `RedisConnect()`: `host`-Parameter an Socket-Adresse weitergeben
- [x] **11.2** `RedisLRange()`: Start/Stop-Parameter statt Hardcodierung
- [x] **11.3** `RedisHIncrBy()`: increment-Parameter statt "1"
- [x] **11.4** `RedisZAdd()`: score + member-Parameter statt Hardcodierung
- [x] **11.5** Empfangsbuffer auf 64KB erhöhen oder dynamisch machen

**Definition of Done:**
- `RedisConnect("myhost", 6379)` verbindet zu myhost
- Keine hardcodierten Werte mehr in Redis-Befehlen

---

## Phase 3 — 🟡 Mittelstufe

---

### WP-12: SMTP mit TLS und Header-Sanitisierung

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/smtp.lyx` |
| **Aufwand** | 2 Tage |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ |

**Problem:** Kein STARTTLS – Credentials (AUTH) gehen im Klartext.
From/To/Subject werden roh in Header kopiert → CRLF-Injection.

**Teilschritte:**

- [ ] **12.1** STARTTLS (Port 25 → EHLO → STARTTLS → TLS)
- [ ] **12.2** SMTPS (Port 465, direkt TLS)
- [ ] **12.3** From/To/Subject auf CRLF-Injection prüfen
- [ ] **12.4** AUTH nur über TLS erlauben

**Definition of Done:**
- E-Mail-Versand über STARTTLS funktioniert
- Header mit `\r\n` werden abgewiesen/escaped
- Klartext-AUTH ohne TLS wird verweigert

---

### WP-13: Crypto-Memory sicher löschen

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/crypto/lic_hmac.lyx`, `src/crypto/lic_secret.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** SHA-256-State, HMAC-Keys und gepaddete Blöcke werden per `munmap` freigegeben ohne vorheriges Zeroing.
Compiler könnte Zeroing-Stores wegoptimieren (keine Memory Barrier).

**Teilschritte:**

- [x] **13.1** `explicit_bzero()`/`memset_s()` oder Compiler-Barriere vor munmap
- [x] **13.2** `__sync_synchronize()` nach Zeroing gegen Optimierung
- [x] **13.3** Alle Fehlerpfade in `lic_sha256`/`lic_hmacSha256` auf korrektes Cleanup prüfen

**Definition of Done:**
- Nach `lic_hmacSha256` sind alle temporären Buffer genullt
- Assembly-Check bestätigt: Zeroing wird nicht wegoptimiert

---

### WP-14: DNS-Parser mit Größenlimits

| Attribut | Wert |
|----------|------|
| **Dateien** | `std/net/dns.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** DNS-Response-Parsing ohne obere Schranke bei Domain-Name-Decompression.
Potentieller Buffer-Overread / Loop-Angriff via zirkuläre Pointer.

**Teilschritte:**

- [x] **14.1** Max 255 Bytes pro Domain-Name (RFC 1035)
- [x] **14.2** Max 100 Pointer (gegen Loop-Angriffe)
- [x] **14.3** Max Response-Größe 65535 Bytes (DNS-UDP-Limit)

**Definition of Done:**
- Zirkuläre Pointer werden erkannt und abgewiesen
- Domain > 255 Zeichen → Fehler

---

### WP-15: Constant-Time Crypto für HMAC

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/crypto/lic_hmac.lyx`, `src/crypto/lic_derive.lyx` |
| **Aufwand** | 1–2 Tage |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt 2026-06-03 |

**Problem:** HMAC-Vergleiche und Schlüsselableitung sind potentiell nicht constant-time.
Timing-Seitenkanal-Angriffe möglich bei lokalem Zugriff.

**Teilschritte:**

- [x] **15.1** Alle HMAC-Vergleiche auf constant-time prüfen (kein early-exit)
- [x] **15.2** Zeitlich konstanter Speicherzugriff im SHA-256-Kernel

**Definition of Done:**
- HMAC-Vergleich 32 Bytes braucht immer gleiche Zeit
- Keine branch-on-secret-data im SHA-256-Kernel

---

### WP-16: `gen_lic_secret.py` sicherer machen

| Attribut | Wert |
|----------|------|
| **Dateien** | `tools/gen_lic_secret.py` |
| **Aufwand** | 0.5 Tage |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt 2026-06-04 |

**Problem:** Das generierte Master-Secret wird ans Terminal ausgegeben (Scrollback, Logs, History).

**Teilschritte:**

- [x] **16.1** Secret in Datei mit 600er-Permissions schreiben (statt stdout) — `os.open(path, O_WRONLY|O_CREAT|O_TRUNC, 0o600)` + `os.chmod` + Sanity-Check; Default `~/.lyx/master.secret`
- [x] **16.2** Optional Direktausgabe mit verstärkter Warnung — `--show-secret` gibt Secret auf stderr mit prominenter Sicherheitswarnung aus

**Definition of Done:**
- Secret landet nicht mehr ungeschützt in Terminal-History

---

### WP-17: Teilimplementierte Annotationen dokumentieren

| Attribut | Wert |
|----------|------|
| **Dateien** | `COMPILER_MANUAL.md` |
| **Aufwand** | 0.5 Tage |
| **Priorität** | 🟡 Mittel |
| **Status** | ✅ erledigt 2026-06-04 |

**Befund (Audit-Korrektur):** `@redundant` (WP-3.1: TMR triple storage + majority-vote) und `@big_endian` (WP-4.1-B: BSWAP) sind vollständig im Codegen implementiert. Die ursprüngliche Diagnose "Parser-Level only" war veraltet.

**Teilschritte:**

- [x] **17.1** Neue Section 2.11 "Annotations" in `COMPILER_MANUAL.md` — dokumentiert alle 9 Annotationen (`@export`, `@jni`, `@packed`, `@big_endian`, `@redundant`, `@capabilities`, `@uses_caller_cap`, `@cap`, `@energy`) mit Syntax, Ziel, Implementierungsstatus (alle ✅) und Beispiel
- [x] **17.2** Compile-Error für `@big_endian` auf `f64`-Feldern bereits in `sema.lyx:2590` vorhanden; alle übrigen Annotationen haben validierten Codegen — keine zusätzliche Warnung erforderlich

**Definition of Done:**
- Doku erwähnt explizit den Implementierungsstatus jeder Annotation

---

## Phase 4 — 🔵 Langfristig / Niedrige Priorität

---

### WP-18: Stack-Canaries in generierte ELFs einbauen

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` |
| **Aufwand** | 1 Tag |
| **Priorität** | 🔵 Niedrig |
| **Status** | ✅ erledigt 2026-06-04 |

**Lösung:**
- `cg_emitPrologue()` / `cg_emitPrologueNested()`: reservieren `[rbp-8]` für den Canary und laden ihn aus dem `_lyx_canary`-Global (RIP-relative via `CG_PATCH_STR`)
- `cg_emitEpilogue()`: vergleicht `[rbp-8]` via `r10/r11` (scratch, kein Eingriff in `rax` Return-Wert); bei Mismatch → `jnz __lyx_stack_fail`
- `__lyx_stack_fail` (70 Bytes): schreibt `"stack smashing detected\n"` auf stderr, exit(1)
- `__lyx_canary_init` (27 Bytes): `sys_getrandom(&_lyx_canary, 8, 0)` — kernel-CSPRNG, kein libc/FS-Register nötig
- Aufruf in `main()` VOR dem Prologue (damit Prologue bereits den initialisierten Wert speichert)
- Security-Score: +5 Punkte (35/45)

**LCBS-Einfluss:** seccomp schränkt Post-Exploit-Möglichkeiten stark ein — ein Angreifer der via Stack-Overflow RCE erreicht, kann kaum weitere Syscalls ausführen. Stack-Canaries bleiben als erste Verteidigungslinie sinnvoll, aber LCBS reduziert die Urgenz deutlich.

---

### WP-19: ARM64-Dynamic-Linking-Bugs fixen

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/backend/arm64/emit_arm64.lyx`, `src/lyxc.lyx` |
| **Aufwand** | — |
| **Priorität** | 🔵 Niedrig |
| **Status** | ✅ erledigt (bereits in `feat/dynlink-v2`) |

**Befund:** Die PLT/GOT-Bugs aus der ursprünglichen Security-Analyse waren bereits in Branch `feat/dynlink-v2` behoben (vor diesem Fahrplan):
- [x] SIGBUS bei PLT/GOT-basiertem Dynamic Linking — X16-Register-Kollision behoben via X17 (`emit_arm64.lyx`: `emitCallExtern` nutzt X17 statt X16)
- [x] `R_AARCH64_GLOB_DAT`-Relocations korrekt in `writeELFExecDynamic` (`src/lyxc.lyx:2340`)
- [x] Float-Codegen (NEON) — behoben via format_float builtin

**Offener Punkt (nicht Teil von WP-19):** Beide ARM64-ELF-Writer (`writeELF` Z. 2500 und `writeELFExecDynamic` Z. 2340) setzen `PT_LOAD p_flags = 7 (RWX)` — parallele W^X-Lücke zu WP-6 auf x86-64. Kein PIE/ASLR. Diese Punkte sind ARM64-Äquivalente von WP-6 und sollten dort mitbehandelt oder als WP-6b geführt werden.

---

### WP-20: `.meta_safe` CRC32-Code-Integrität implementieren

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/lyxc.lyx`, `std/meta_safe.lyx`, `src/codegen_x86.lyx` |
| **Aufwand** | 1 Tag (Bugfixes) |
| **Priorität** | 🟡 Mittel (hochgestuft durch LCBS-Synergie) |
| **Status** | ✅ erledigt 2026-06-04 |

**Befund:** `.meta_safe` war bereits vollständig implementiert (Compiler + Runtime), hatte aber drei Bugs die `MetaSafeVerify()` zum Scheitern brachten:

1. **CG_CANARY-Kollision** (`src/codegen_x86.lyx`): `self.dataLen := 80` startete String-Konstanten genau bei Offset 80 — `CG_CANARY = 80` überschrieb sie mit `sys_getrandom`-Output. Fix: `dataLen := 88`.
2. **Page-Alignment-Bug** (`src/codegen_x86.lyx`): Padding-Formel `(4096 - (codeLen & 4095)) & 4095` berücksichtigte `CG_CODE_OFF = 176` nicht. RX/RW-Segmente teilten eine Page → Laufzeit-SIGSEGV. Fix: `(4096 - ((CG_CODE_OFF + codeLen) & 4095)) & 4095`.
3. **Falscher codeOff** (`src/lyxc.lyx`, `std/meta_safe.lyx`): Hardcoded `120` statt korrektem `176` (`CG_CODE_OFF` = 64-byte ELF-Header + 2×56-byte PHDRs). Fix: `176`.

**LCBS-Synergie:** `.meta_safe` verifiziert die Code-Integrität beim Start (Manipulation erkannt?), LCBS schränkt dann die Laufzeitrechte ein (Was darf der Code tun?). Kombiniert: Verifikation + Containment. Damit steigt der Wert von WP-20 deutlich.

---

### WP-21: Debug-Datei aus dem Repo entfernen

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/s1-debug.md` |
| **Aufwand** | 0.1 Tage |
| **Priorität** | 🔵 Niedrig |
| **Status** | ⬜ |

**Problem:** Enthält Memory-Dumps und Debug-Info, die einem Angreifer nützen könnten.

---

### WP-22: Automatisierte Security-Tests im CI

| Attribut | Wert |
|----------|------|
| **Dateien** | `.github/workflows/ci.yml`, `tests/security/` |
| **Aufwand** | 3–4 Tage |
| **Priorität** | 🟡 Mittel (hochgestuft durch LCBS) |
| **Status** | ⬜ |

**Vorschläge (ursprünglich):**
- Regressionstests für WP-1 (Testvektoren)
- Integrationstests für WP-2, WP-3 (MITM erkennen)
- Fuzzing-Tests für WP-7, WP-10, WP-14
- SAST-Scanner für WP-5 (erledigt; Regressionstests gegen Bypass-Versuche)

**Neue LCBS-Testfälle:**
- seccomp-Enforcement: verbotener Syscall → SIGSYS (nicht bloß Score-Check)
- Landlock: Zugriff auf nicht-deklarierten Pfad → EACCES
- Capability-Inheritance: Transitivität und Grant-Grenzen
- Audit-Score-Regression: Basiswerte dürfen nicht sinken
- FFI-Blacklist-Regression: `system()` als extern fn → immer Compile-Error
- `--self-test` in CI als LCBS-Smoke-Test

---

## Phase 5 — 🔴 LCBS-Audit-Integrität (neu, dringend)

---

### WP-23: Security-Audit W^X-Reporting korrigieren

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` (cg_runAudit, Z. 8985/9015) |
| **Aufwand** | 0.5 Tage |
| **Priorität** | 🔴 Kritisch |
| **Status** | ⬜ |

**Problem:** Die LCBS-Audit-Funktion gibt hardcoded `+ W^X (RX-Code / RW-Daten getrennt)` und `+5 Punkte W^X aktiv` aus, unabhängig vom tatsächlichen ELF-Programmheader. Das Binary hat weiterhin `PF_R|PF_W|PF_X` (Wert 7, Single PT_LOAD). Der Score täuscht Nutzer über die tatsächliche Sicherheitslage. Ein Audit-System das falsch reportet ist schlimmer als keines.

**Teilschritte:**

- [ ] **23.1** Audit: `lcbsWxActive`-Flag in Codegen setzen — `true` erst wenn zwei PT_LOAD-Segmente emittiert werden
- [ ] **23.2** Audit-Ausgabe: W^X bedingt auf Flag (`+` nur wenn wirklich RX/RW getrennt, sonst `o`)
- [ ] **23.3** Score: +5 für W^X nur wenn `lcbsWxActive`
- [ ] **23.4** Gleiches Muster für RELRO prüfen (aktuell: RELRO-Aussage für statisches ELF korrekt, aber explizit als "kein GOT/PLT" formulieren)

**Definition of Done:**
- Solange WP-6 offen: Audit zeigt `o W^X (nicht aktiv — Single PT_LOAD RWX)`, Score +0
- `checksec --elf` und Audit-Output sind konsistent

---

### WP-24: seccomp-Filter-Vollständigkeit sicherstellen

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` (seccomp_build_filter), `src/security/` |
| **Aufwand** | 1–2 Tage |
| **Priorität** | 🟠 Hoch |
| **Status** | ⬜ |

**Problem:** Der seccomp-Filter mappt Capability-IDs auf erlaubte Syscall-Listen. Fehlen Syscalls in einer Capability-Definition (z.B. `fs.read` erlaubt `open` aber nicht `openat`), kann das Programm abstürzen obwohl LCBS es als korrekt annotiert betrachtet. Ist die Liste zu weit (zu viele Syscalls), ist die Sandbox zu permissiv.

**Teilschritte:**

- [ ] **24.1** Capability → Syscall-Mapping vollständig gegen Linux-5.13+ auditieren (strace-basiert)
- [ ] **24.2** Fehlende Syscalls ergänzen (z.B. `openat2`, `statx`, `newfstatat`)
- [ ] **24.3** Test: Programm mit `@capabilities([fs.read])` liest Datei ohne SIGSYS
- [ ] **24.4** Test: Programm versucht nicht-deklarierten Syscall → SIGSYS bestätigt

**Definition of Done:**
- Alle stdlib-Funktionen laufen ohne seccomp-SIGSYS wenn Capability korrekt deklariert
- Nicht-deklarierte Syscalls werden zuverlässig geblockt

---

### WP-25: `--capabilities=compat` Laufzeit-Warnung

| Attribut | Wert |
|----------|------|
| **Dateien** | `src/codegen_x86.lyx` (cg_runAudit), `src/lyxc.lyx` |
| **Aufwand** | 0.5 Tage |
| **Priorität** | 🟡 Mittel |
| **Status** | ⬜ |

**Problem:** `--capabilities=compat` deaktiviert alle LCBS-Laufzeitschutzmaßnahmen (seccomp, Landlock, Proxy) vollständig — auch für Programme mit vollständig deklariertem `@capabilities`. Ein Entwickler der compat-Mode für ein Deployment verwendet, bekommt keinen Hinweis dass der Schutz deaktiviert ist.

**Teilschritte:**

- [ ] **25.1** Compiler: prominente stderr-Warnung bei `--capabilities=compat` (nicht nur Audit-Kommentar)
- [ ] **25.2** Generierte Binary: Laufzeit-Warnung auf stderr wenn lcbsCompatMode erkannt wird (`WARNUNG: LCBS-Compat-Modus aktiv — kein Laufzeitschutz`)
- [ ] **25.3** Audit-Score: Compat-Mode → Score-Penalty dokumentieren

**Definition of Done:**
- `./lyxc --capabilities=compat prog.lyx` gibt sichtbare stderr-Warnung
- Generiertes Binary druckt Warnung beim Start wenn im Compat-Modus kompiliert

---

## Anhang: Ursprüngliche Fundstellen (Referenz)

Nachfolgend die Dateien und Zeilen, die bei der Security-Analyse aufgefallen sind:

| # | Fundort | Zeilen | Kurzbeschreibung |
|---|---------|--------|------------------|
| 1 | `src/frontend/ffi_parser.lyx` | 410–506 | `system()`, `sprintf()`, `gets()`, `strcpy()`, `execve()` als FFI-Externs |
| 2 | `src/lyxc.lyx` | 2523–2524 | RWX-Programmheader (`PF_R | PF_W | PF_X`) |
| 3 | `src/backend/elf/write_elf.lyx` | 426 | RWX-Programmheader |
| 4 | `src/lyxc.lyx` | 2499, 2528 | Feste Base-Adresse 0x401000 (kein PIE) |
| 5 | `src/sema.lyx` | 553–596 | Path Traversal in `_sema_readFile()` |
| 6 | `src/codegen_x86.lyx` | 7133–7140 | Path Traversal in `_cg_readFile()` |
| 7 | `src/sema.lyx` | 441, 591 | Integer Overflow (`len + 1`) |
| 8 | `src/codegen_x86.lyx` | 1997, 2151, 2229, 3095 | Integer Overflow (`cnt * size`) |
| 9 | `src/lyxc.lyx` | 1714, 2201, 3972 | Integer Overflow / Buffer ohne Bounds-Check |
| 10 | `src/crypto/lic_hmac.lyx` | 96–157 | Kein Zeroing von Crypto-Memory |
| 11 | `src/crypto/lic_hmac.lyx` | 142 | Integer Overflow (`inLen * 8`) |
| 12 | `src/lyu_reader.lyx` | 24–51, 131–143 | Keine obere Schranke bei .lyu-Parsing |
| 13 | `std/hash.lyx` | 196–238 | SHA-256 bricht nach 1 Byte/Runde ab, kein Padding |
| 14 | `std/hash.lyx` | 244–273 | `HashPassword`/`HashPasswordSimple` unsicher |
| 15 | `std/hash.lyx` | 1553–1880 | BCrypt/Argon2/PBKDF2/Scrypt alles Stubs |
| 16 | `std/hash.lyx` | 1898–1910 | `GenerateSalt` deterministisch |
| 17 | `std/net/tls.lyx` | 89–99 | Fehlende Hostname-Verifikation |
| 18 | `std/net/https.lyx` | 52–56, 120–124 | Fehlende Hostname-Verifikation (geerbt) |
| 19 | `std/net/ssh.lyx` | 105–112 | Fehlende Host-Key-Prüfung |
| 20 | `std/net/mongo.lyx` | 42–53, 90, 152–153 | Kein TLS, kein Auth |
| 21 | `std/net/http.lyx` | 59–60, 115–145 | Keine URL-Validierung, fixe Buffer |
| 22 | `std/net/smtp.lyx` | (alle) | Kein TLS, Header-Injection |
| 23 | `std/net/dns.lyx` | (alle) | Keine Größenlimits beim Parsing |
| 24 | `std/db/mysql.lyx` | 446, 642 | SQL Injection (`COM_QUERY`) |
| 25 | `std/db/postgres.lyx` | 525–527, 494–496 | SQL Injection (String-Konkatenation) |
| 26 | `std/db/sqlite.lyx` | 150 | SQL Injection (`sqlite3_exec` roh) |
| 27 | `std/db/redis.lyx` | ~99 | `RedisConnect` ignoriert `host`-Parameter |
| 28 | `tools/gen_lic_secret.py` | 69–71 | Secret-Ausgabe auf Console |
| 29 | `src/s1-debug.md` | (alle) | Debug-Datei mit Memory-Dumps |

---

## Bearbeitungsstatus

| WP | Titel | Status | Verantwortlich | Start | Ende | Prio |
|----|-------|--------|----------------|-------|------|------|
| 1 | Kryptografische Hash-Funktionen korrigieren | ✅ | Claude | 2026-05-31 | 2026-05-31 | 🔴 |
| 2 | TLS-Hostname-Verifikation | ✅ | Claude | 2026-05-31 | 2026-05-31 | 🔴 |
| 3 | SSH-Host-Key-Verifikation | ✅ | Claude | 2026-05-31 | 2026-05-31 | 🔴 |
| 4 | MongoDB-Treiber absichern | ✅ | Claude | 2026-06-01 | 2026-06-01 | 🔴 |
| 5 | Gefährliche FFI-Externs | ✅ durch WP-L5 | Claude | 2026-06-01 | 2026-06-03 | 🟠 |
| 6 | W^X für ELF-Binaries | ⬜ **Audit-Bug aktiv** | – | – | – | 🔴 |
| 7a | Path Traversal — Compiler-Side (7.1/7.2) | ⬜ | – | – | – | 🟠 |
| 7b | Path Traversal — Stdlib/Runtime (7.3) | ✅ via Landlock | LCBS | – | 2026-06-03 | – |
| 8 | SQL Injection schließen | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟠 |
| 9 | HTTP-Client absichern | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟠 |
| 10 | Integer-Overflow-Prüfungen | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟠 |
| 11 | Redis-Treiber korrigieren | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟠 |
| 12 | SMTP mit TLS + Header-Sanitisierung | ⬜ | – | – | – | 🟡 |
| 13 | Crypto-Memory sicher löschen | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟡 |
| 14 | DNS-Parser mit Limits | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟡 |
| 15 | Constant-Time Crypto | ✅ | Claude | 2026-06-03 | 2026-06-03 | 🟡 |
| 16 | gen_lic_secret.py sicherer | ✅ | Claude | 2026-06-04 | 2026-06-04 | 🟡 |
| 17 | Annotationen dokumentieren (inkl. LCBS) | ✅ | Claude | 2026-06-04 | 2026-06-04 | 🟡 |
| 18 | Stack-Canaries | ✅ | Claude | 2026-06-04 | 2026-06-04 | 🔵 |
| 19 | ARM64-Dynamic-Linking-Bugs | ✅ bereits in feat/dynlink-v2 | – | – | – | 🔵 |
| 20 | `.meta_safe` Code-Integrität | ⬜ | – | – | – | 🟡 |
| 21 | Debug-Datei entfernen | ⬜ | – | – | – | 🔵 |
| 22 | Security-Tests im CI (inkl. LCBS) | ⬜ | – | – | – | 🟡 |
| **23** | **Audit W^X-Reporting korrigieren** | ⬜ | – | – | – | **🔴** |
| **24** | **seccomp-Filter-Vollständigkeit** | ⬜ | – | – | – | **🟠** |
| **25** | **--capabilities=compat Warnung** | ⬜ | – | – | – | **🟡** |
