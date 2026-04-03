# Lyx Compiler ToDo Liste

## Backend-Parität (nicht-x86_64)

Das Referenz-Backend ist **x86_64 Linux** (`compiler/backend/x86_64/x86_64_emit.pas`).
Alle anderen Backends haben erhebliche Lücken bei Builtins und IR-Opcodes.

---

### ARM64 Linux (`compiler/backend/arm64/arm64_emit.pas`)

**Implementiert ✅:** PrintStr, PrintInt, exit, open, read, write, close, lseek, unlink, rename, mkdir, rmdir, chmod, Random, RandomSeed, now_unix, now_unix_ms, sleep_ms, RegexMatch/Search/Replace (Stubs), NEON SIMD, DynArray (Push/Pop/Len/Free), VMT, Dynamic Linking (PLT/GOT), String Builtins S0-S7

**String-Builtins S0 (Implementiert ✅):**
- [x] `str_concat` – pchar + pchar via mmap
- [x] `StrLen` – null-terminierte Länge
- [x] `StrCharAt` / `StrSetChar` – Zeichenzugriff
- [x] `StrNew(cap)` / `StrFree(s)` – mmap/munmap
- [x] `StrAppend(dest, src)` – reallozierend
- [x] `StrFromInt(n)` – Integer→String

**String-Builtins S1–S7 (Implementiert ✅):**
- [x] `StrFindChar(s, ch, start)` / `StrSub(s, start, len)`
- [x] `StrAppendStr(dest, src)` / `StrConcat(a, b)` / `StrCopy(s)`
- [x] `IntToStr(n)` / `FileGetSize(path)`
- [x] `HashNew(cap)` / `HashSet` / `HashGet` / `HashHas`
- [ ] `GetArgC()` / `GetArg(i)`
- [x] `StrStartsWith` / `StrEndsWith` / `StrEquals`

**Fehlt ❌ – Sonstige Builtins:**
- [x] `PrintFloat` / `Println` / `printf` (PrintFloat implementiert, Println/printf Stub)
- [ ] `mmap` / `munmap` (als Builtin-Aufruf, nicht nur intern)
- [ ] `ioctl` / `getpid`
- [ ] `peek8/16/32/64` / `poke8/16/32/64` / `buf_get_byte` / `buf_put_byte`
- [ ] `format_float` (`:width:decimals` Format-Specifier)
- [ ] `Inspect` (Debug-Visualizer)
- [ ] Socket-Builtins: `sys_socket`, `sys_bind`, `sys_listen`, `sys_accept`, `sys_connect`, `sys_recvfrom`, `sys_sendto`, `sys_setsockopt`, `sys_getsockopt`, `sys_fcntl`, `sys_shutdown`

**Offen – bekannte Bugs:**
- [x] ~~SIGBUS bei PLT/GOT-basiertem Dynamic Linking~~ (X16-Register-Konflikt, `feat/dynlink-v2`) — behoben via X17
- [ ] Float-Codegen (SSE2 → ARM64 NEON Mapping für `format_float`)

---

### macOS x86_64 (`compiler/backend/macosx64/macosx64_emit.pas`)

**Implementiert ✅:** exit, PrintStr, Println, PrintInt

**Fehlt ❌ – IO-Builtins:**
- [ ] `PrintFloat` / `printf`
- [ ] `open` / `read` / `write` / `close` / `lseek`
- [ ] `unlink` / `rename` / `mkdir` / `rmdir` / `chmod`
- [ ] `ioctl` / `mmap` / `munmap`
- [ ] `getpid`

**Fehlt ❌ – String-Builtins (alle):**
- [ ] `str_concat`, `StrLen`, `StrCharAt`, `StrSetChar`, `StrNew`, `StrFree`, `StrAppend`, `StrFromInt`
- [ ] S1–S7 komplett (StrFindChar, StrSub, StrAppendStr, StrConcat, StrCopy, IntToStr, FileGetSize, Hash*, GetArgC, GetArg, StrStartsWith, StrEndsWith, StrEquals)

**Fehlt ❌ – Sonstige:**
- [ ] `Random` / `RandomSeed`
- [ ] `peek*` / `poke*` / `buf_get_byte` / `buf_put_byte`
- [ ] `format_float`
- [ ] `Inspect`
- [ ] Socket-Builtins (Mach-O syscall-Nummern: `SYS_MACOS_*`)
- [ ] VMT / DynArray / Closures

**Hinweis:** macOS verwendet andere Syscall-Nummern (0x2000000-Präfix) und die System-V ABI.
Alle Strings und mmap müssen auf macOS-Syscalls umgestellt werden (analog zu `SYS_MACOS_*`-Konstanten in x86_64_emit.pas).

---

### Windows ARM64 (`compiler/backend/win_arm64/win_arm64_emit.pas`)

**Implementiert ✅:** — (Skeleton, keine Builtins)

**Fehlt ❌ – Alle Builtins** (Grundlage zuerst):
- [ ] `PrintStr` / `PrintInt` / `PrintFloat` / `Println` – via Win32 `WriteFile`
- [ ] `exit` – via `ExitProcess`
- [ ] `open` / `read` / `write` / `close` – via `CreateFileW` / `ReadFile` / `WriteFile` / `CloseHandle`
- [ ] `mmap` / `munmap` – via `VirtualAlloc` / `VirtualFree`
- [ ] Alle String-Builtins (S0 + S1–S7)
- [ ] `Random` / `RandomSeed`
- [ ] `peek*` / `poke*`
- [ ] Socket-Builtins – via WinSock2 (`WSAStartup`, `socket`, `connect`, etc.)
- [ ] `GetArgC` / `GetArg` – via `GetCommandLineW` / `CommandLineToArgvW`
- [ ] `Inspect`

**Hinweis:** Windows ARM64 nutzt den Microsoft ABI (x0–x7 Parameter, keine Syscalls – alles über Win32 API).
Der PE64-Writer (`compiler/backend/win_arm64/pe64_arm64_writer.pas`) existiert bereits.
Imports müssen als IAT-Einträge in den PE-Header eingetragen werden (kein PLT, sondern `__imp_`-Pointer).

---

### Xtensa / ESP32 (`compiler/backend/xtensa/xtensa_emit.pas`)

**Implementiert ✅:** exit, PrintStr (via sys_write)

**Fehlt ❌ – Builtins:**
- [ ] `PrintInt` – itoa-Loop + write
- [ ] `PrintFloat` – nicht sinnvoll ohne FPU; niedrige Priorität
- [ ] `StrLen` / `StrCharAt` / `StrSetChar` / `StrNew` / `StrFree` / `StrAppend` / `StrFromInt`
- [ ] `S1–S7` komplett (StrFindChar, StrSub, StrConcat, IntToStr, Hash*, GetArgC/GetArg, StrEquals etc.)
- [ ] `Random` / `RandomSeed`
- [ ] `peek8/16/32` / `poke8/16/32` (für Memory-Mapped I/O – besonders wichtig auf ESP32)
- [ ] `open` / `read` / `write` / `close` (SPIFFS/LittleFS Dateisystem)

**Hinweis:** Xtensa hat kein Linux-Syscall-Interface. Alle I/O-Builtins müssen gegen die ESP-IDF-API (`uart_write_bytes`, `esp_vfs_*`) oder direkt gegen UART-Register implementiert werden.
`mmap`/`munmap` sind auf ESP32 nicht sinnvoll — `StrNew`/`StrFree` müssen auf `heap_caps_malloc`/`heap_caps_free` gemappt werden.

---

### Empfohlene Reihenfolge

| Priorität | Backend | Aufgabe |
|-----------|---------|---------|
| Hoch | ARM64 Linux | String-Builtins S0 (StrNew/StrFree/StrLen/StrAppend/StrFromInt) |
| Hoch | ARM64 Linux | String-Builtins S1–S7 (port from x86_64) |
| Hoch | ARM64 Linux | Float-Codegen / format_float (NEON) |
| Mittel | macOS x86_64 | IO-Builtins (open/read/write/close/lseek) + String S0 |
| Mittel | macOS x86_64 | String S1–S7 (identisch zu x86_64 — nur Syscall-Nummern tauschen) |
| Mittel | ARM64 Linux | Socket-Builtins (ARM64-Syscall-Nummern anpassen) |
| Niedrig | Windows ARM64 | PrintStr/PrintInt/exit via Win32 API als Baseline |
| Niedrig | Windows ARM64 | mmap→VirtualAlloc + String S0 |
| Niedrig | Xtensa | PrintInt + peek/poke (für MMIO) |
| Niedrig | Xtensa | StrNew→heap_caps_malloc + String S0 |

---

## Aktuelle Aufgaben

### std.net Library

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **IPv6 Support** | `SockAddrIn6` struct existiert, wird aber nicht verwendet |

### data Library - Fehlende Features (Pandas-Parität)

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **Map Aggregates** | MapSum, MapMin, MapMax, MapAvg (benötigt Iterator-Support) |

### Dynamic Linking

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **ARM64 libc init fix** | CRT-Start-Code (crt1.o) emittieren, `__libc_start_main` aufrufen |
| Niedrig | **ARM64 PIE (ET_DYN) Binary** | Position Independent Executable für bessere libc-Kompatibilität |

### C FFI

_(keine offenen Aufgaben)_

### Backend

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **Windows VMT Tests** | Virtual Calls auf echter Windows-Hardware testen |

### Sprache / Frontend

_(keine offenen Aufgaben)_

### Tech Debts

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **`std/geo.lyx` Return-Type** | `[GeoPoint, GeoPoint]` als Array-Type-Literal im Parser |

#### `std/geo.lyx` — Teilaufgaben

| # | Aufgabe | Datei | Beschreibung |
|---|---------|-------|--------------|
| 1 | **`atTuple` Typ definieren** | `ast.pas` | Neues `TAurumType.atTuple` + `TTupleElemTypes` Record |
| 2 | **Parser: `[T, T, ...]` parsen** | `parser.pas` | In `ParseTypeExFull` nach `[`: wenn Identifier statt Integer → Tuple-Type parsen |
| 3 | **Parser: Tuple-Elementtypen speichern** | `parser.pas` | `ParseTypeEx` erweitern um `out tupleElemTypes` oder separate Liste |
| 4 | **Sema: Tuple-Return prüfen** | `sema.pas` | Return-Type-Check: `[GeoPoint, GeoPoint]` Literal passt zu `[GeoPoint, GeoPoint]` Annotation |
| 5 | **IR: Tuple-Return lowering** | `lower_ast_to_ir.pas` | Array-Literal mit Struct-Elementen als Tuple-Return → `irReturnStruct` oder Hidden-Ptr |
| 6 | **Backend: Tuple-Return codegen** | `x86_64_emit.pas` | SysV ABI: 2 Structs ≤16B → RAX:RDX, >16B → Hidden-Ptr in RDI |

**Betroffene Funktionen in `std/geo.lyx`:**
- `BoundingBoxFromPoints(p1, p2): [GeoPoint, GeoPoint]` (Zeile 247)
- `CalculateBoundingBox(center, radiusM): [GeoPoint, GeoPoint]` (Zeile 496)

### Dokumentation

_(keine offenen Aufgaben)_

---

## Abgeschlossene Aufgaben

### Telnet Client (März 2026)

- [x] **std/net/telnet.lyx** - RFC 854 Telnet Client (TelnetConnect, TelnetRead, TelnetWrite)
- [x] **Telnet Commands** - IAC, DO, DONT, WILL, WONT, SB, SE
- [x] **Option Negotiation** - ECHO, SUPPRESS-GA, BINARY, TERMINAL_TYPE
- [x] **IAC Filtering** - Telnet commands aus Read-Daten filtern
- [x] **IAC Escaping** - IAC-Bytes beim Senden verdoppeln
- [x] **Test-Programm** - tests/lyx/net/test_telnet.lyx

### EAN/ISBN/UPC Validation (März 2026)

- [x] **std/validate/ean.lyx** - Business Identifier Validations (EAN13Validate, EAN13CheckDigit, ISBN13Validate)
- [x] **EAN-13** - 13-stelliger Barcode mit Checksummen-Algorithmus (1/3 Gewichtung)
- [x] **EAN-8** - 8-stelliger Barcode (komprimierte Variante)
- [x] **EAN-14/GTIN-14** - 14-stelliger Trade Item Number
- [x] **ISBN-13** - International Standard Book Number (978/979 Prefix)
- [x] **ISBN-10** - Legacy ISBN mit 'X' Support (mod 11 Checksum)
- [x] **UPC-A** - 12-stelliger North American Barcode
- [x] **Country Detection** - GS1 Prefix → Land Mapping (80+ Regionen)
- [x] **Formatting** - EAN13Format, EAN8Format für Lesbarkeit
- [x] **Test-Programm** - tests/lyx/validate/test_ean.lyx

### ISBN/ISSN Module (März 2026)

- [x] **std/validate/isbn.lyx** - ISBN/ISSN Validierung und Konvertierung (ISBN13ValidateFull, ISBN10To13, ISBN13To10)
- [x] **ISBN-13 Validation** - 13-stellig mit Bindestrichen, EAN-13 Format (978/979 Prefix)
- [x] **ISBN-10 Validation** - 10-stellig mit 'X' Support, mod 11 Checksumme
- [x] **ISBN-10 ↔ 13 Konvertierung** - Bidirektionale Konvertierung (nur 978 Prefix)
- [x] **ISBN Formatting** - Standard-Hyphens (978-3-16-148410-0, 0-306-40615-2)
- [x] **ISBN Normalisierung** - ISBNNormalize für Bindestriche/Leerzeichen
- [x] **ISSN Validation** - International Standard Serial Number (XXXX-XXXX)
- [x] **ISSN Checksumme** - Mod 11 Algorithmus (identisch mit ISBN-10)
- [x] **ISSN Formatting** - Mit Bindestrich formatiert
- [x] **Type Detection** - ISBNDetectType für ISBN-10/13/ISSN Erkennung
- [x] **Test-Programm** - tests/lyx/validate/test_isbn.lyx

### Luhn/Credit Card Validation (März 2026)

- [x] **std/validate/luhn.lyx** - Luhn Algorithmus + Credit Card Validierung (LuhnValidate, CreditCardType, CreditCardValidate)
- [x] **Luhn Algorithmus** - Mod 10 Checksumme (doppeltes Gewicht alle 2 Stellen)
- [x] **Transposition Detection** - Erkennt Zahlendreher durch fehlerhafte Checksumme
- [x] **Credit Card Types** - Visa, Mastercard, Amex, Discover, Diners, JCB, Maestro, UnionPay
- [x] **Type Detection** - CreditCardType nach Prefix (4=Visa, 5=MC, 34/37=Amex, etc.)
- [x] **Formatting** - CreditCardFormat (4-4-4-4, 4-6-5 für Amex, 4-6-4 für Diners)
- [x] **Masking** - CreditCardMask (nur letzte 4 Ziffern sichtbar)
- [x] **Test Numbers** - CreditCardGenerateTest für Testkarten
- [x] **IMEI Validation** - IMEIValidate (15-stellig, Luhn)
- [x] **Test-Programm** - tests/lyx/validate/test_luhn.lyx

### IBAN Validation (März 2026)

- [x] **std/validate/iban.lyx** - ISO 13616 IBAN Validation (IBANValidate, IBANCalculateCheck, IBANFormat)
- [x] **Mod 97 Algorithmus** - ISO 13616: Rearrange + Convert Letters + Mod 97 == 1
- [x] **Check Digit** - IBANCalculateCheck für IBAN-Generierung
- [x] **Country Support** - 50+ Länder (DE, AT, CH, FR, GB, IT, ES, NL, etc.)
- [x] **Country Length** - IBANCountryLength für länderspezifische Längenprüfung
- [x] **Country Name** - IBANGetCountryName (Deutschland, Schweiz, etc.)
- [x] **Formatting** - IBANFormat mit Leerzeichen (4er-Gruppen)
- [x] **Bank ID** - IBANGetBankId für Bankleitzahl/Sort Code Extraktion
- [x] **Normalisierung** - IBANNormalize (Leerzeichen entfernen, Uppercase)
- [x] **Test-Programm** - tests/lyx/validate/test_iban.lyx

### Country Codes (März 2026)

- [x] **std/country.lyx** - ISO 3166-1 alpha-2 Ländercodes mit Metadaten (CountryGetName, CountryGetCode, CountryGetCurrency)
- [x] **67 Länder** - Europa (36), Asien (12), Amerika (8), Nahost (5), Afrika (4), Ozeanien (2)
- [x] **Country Name** - CountryGetName(code) für Ländernamen (Deutschland, Schweiz, etc.)
- [x] **Code Lookup** - CountryGetCode(name) für Code-Suche nach Name
- [x] **Currency** - CountryGetCurrency(code) für ISO 4217 Währungscodes (EUR, USD, CHF, etc.)
- [x] **Region** - CountryGetRegion(code) für Kontinent (Europa, Asien, etc.)
- [x] **ISO Numeric** - CountryGetNumeric(code) für numerische Ländercodes
- [x] **Validation** - CountryIsValid(code) für Code-Prüfung
- [x] **Test-Programm** - tests/lyx/test_country.lyx

### VAT ID Validation (März 2026)

- [x] **std/validate/vat.lyx** - EU VAT Number Validation (VATValidate, VATGetCountryName, VATGetFormat)
- [x] **27 EU Länder** - DE (9 digits), AT (U+8), BE (10), FR (11 alpha), IT (11), ES (9), NL (12), PL (10), PT (9), SE (12), etc.
- [x] **Länderspezifische Checksummen** - BE (mod 97), PL (gewichtete Summe), IT (Luhn), PT (mod 11)
- [x] **Format-Regeln** - AT erfordert 'U', SE endet mit '01', IE letter rules, CY last=letter
- [x] **VAT Name** - VATGetCountryName (USt-IdNr., BTW-Nr., P.IVA, NIPC, etc.)
- [x] **Format Description** - VATGetFormat für menschenlesbare Formate
- [x] **Normalisierung** - VATNormalize (Leerzeichen/Bindestriche, Uppercase)
- [x] **Test-Programm** - tests/lyx/validate/test_vat.lyx

### Statistics & Aggregation (März 2026)

- [x] **std/stats.lyx** - Array Aggregate Functions (ArraySum, ArrayMin, ArrayMax, ArrayAvg, ArrayMedian, ArrayCount, ArrayProduct)
- [x] **Array Aggregates** - Sum, Min, Max, Avg, Median, Count, Product, First, Last
- [x] **Index Operations** - ArrayIndexOf, ArrayLastIndexOf, ArrayContains, ArrayCountValue
- [x] **Sorting** - ArraySort (Insertion Sort, O(n²)), ArrayReverse
- [x] **Filtering** - ArrayFilterGt, ArrayFilterLt, ArrayFilterRange
- [x] **Statistical** - ArrayVariance (Population), ArrayStdDev, ArrayRange, ArraySumSquares
- [x] **Higher-Order** - Clamp64, Percentage64, InRange64, AbsDiff64
- [x] **Map Stubs** - MapCount, MapSum, MapMin, MapMax, MapAvg (benötigt Iterator-Support)
- [x] **Test-Programm** - tests/lyx/test_stats.lyx

### Mathematical Constants (März 2026)

- [x] **std/math/constants.lyx** - Fundamental dimensionless constants (PI, E, TAU, PHI, SQRT2, SQRT3)
- [x] **Circle Constants** - PI, TAU (2π), INV_PI, HALF_PI, THIRD_PI, QUARTER_PI, SIXTH_PI
- [x] **Exponential** - E, INV_E, E_SQUARED
- [x] **Golden Ratio** - PHI, INV_PHI, PHI_SQUARED
- [x] **Square Roots** - SQRT2, SQRT3, SQRT5, INV_SQRT2, INV_SQRT3, SQRT_PI
- [x] **Logarithms** - LN2, LN10, LOG2E, LOG10E, LOG2_10, LOG10_2
- [x] **Conversion** - DEG_TO_RAD, RAD_TO_DEG, DegToRad(), RadToDeg()
- [x] **Machine** - EPSILON, MAX_SAFE_INT, F64_MAX, F64_MIN
- [x] **Approximate** - ApproxEqual(), ApproxZero(), ApproxOne()
- [x] **Test-Programm** - tests/lyx/test_math_constants.lyx

### SMTP Client (März 2026)

- [x] **std/net/smtp.lyx** - RFC 5321 SMTP Client (SMTPConnect, SMTPSend, SMTPQuit)
- [x] **SMTP Commands** - EHLO, MAIL FROM, RCPT TO, DATA, QUIT
- [x] **Response Parsing** - 3-digit SMTP response code parsing
- [x] **Message Building** - Headers (From, To, Subject) + Body + Dot-stuffing
- [x] **High-level API** - SMTPSend() - complete email send in one call
- [x] **Test-Programm** - tests/lyx/net/test_smtp.lyx

### Data Library - Pandas-like (März 2026)

- [x] **data/core.lyx** - DataFrame, Series, Index, GroupBy, Missing Values (DataFrameNew, DataFrameFilter, DataFrameGroupBy)
- [x] **Series** - 1D typisierter Array (int64/string) mit Labels
- [x] **DataFrame** - 2D-Tabelle mit benannten Spalten
- [x] **Selection/Filter** - DataFrameFilter, DataFrameSlice, CompareInt
- [x] **Column Ops** - AddColumn, DropColumn, RenameColumn, Cell Access
- [x] **GroupBy** - DataFrameGroupBy, GroupBySum, GroupByCount (Split-Apply-Combine)
- [x] **Missing Values** - FillNA, DropNA, IsNA
- [x] **Statistics** - SeriesSum, SeriesMean, SeriesMin, SeriesMax, SeriesCount, SeriesValueCounts
- [x] **data/io.lyx** - CSV I/O (ReadCSV, WriteCSV)
- [x] **CSV Parsing** - Header, Delimiter, Quotes, Type-Inferenz
- [x] **CSV Writing** - DataFrame to CSV with header
- [x] **Display** - DataFramePrint (Table format)
- [x] **Test-Programm** - tests/lyx/data/test_core.lyx

### IMAP Client (März 2026)

- [x] **std/net/imap.lyx** - RFC 3501 IMAP Client (IMAPConnect, IMAPLogin, IMAPSelect, IMAPFetchRaw)
- [x] **IMAP Commands** - LOGIN, SELECT, LIST, FETCH, LOGOUT
- [x] **Tagged Commands** - A001, A002, ... Sequence-Nummern
- [x] **Untagged Responses** - * OK, * EXISTS, * RECENT, * UNSEEN, * UIDVALIDITY
- [x] **Multi-line Reading** - FETCH und LIST Responses mit mehreren Zeilen
- [x] **Data Items** - FLAGS, ENVELOPE, BODY, RFC822, UID
- [x] **Test-Programm** - tests/lyx/net/test_imap.lyx

### NTP Client (März 2026)

- [x] **std/net/ntp.lyx** - RFC 5905 NTP Client (NTPGetTime, NTPParseResponse)
- [x] **NTP Packet** - 48-byte UDP Paket mit LI+VN+Mode Header
- [x] **Timestamps** - 64-bit NTP Timestamps (32s + 32f), NTP-Epoch Offset
- [x] **Time Formatting** - NTPFormatTime() für YYYY-MM-DD HH:MM:SS UTC
- [x] **UDP Transport** - UDPSocket SendTo/Recv für NTP-Anfragen
- [x] **Test-Programm** - tests/lyx/net/test_ntp.lyx

### SNMP Client (März 2026)

- [x] **std/net/asn1.lyx** - ASN.1/BER Encoding/Decoding (Integer, OctetString, OID, Null, Sequence)
- [x] **std/net/snmp.lyx** - RFC 1157/1905 SNMP Client (SNMPGet, SNMPBuildGetRequest, SNMPBuildGetNextRequest)
- [x] **SNMP PDU** - GET, GETNEXT, GETRESPONSE mit RequestId, ErrorStatus, ErrorIndex
- [x] **SNMP Types** - COUNTER32, GAUGE32, TIMETICKS, IPADDRESS
- [x] **SNMPv1/v2c** - Version + Community String Authentifizierung
- [x] **Value Parsing** - SNMPResponseAsString, SNMPResponseAsInteger
- [x] **Test-Programm** - tests/lyx/net/test_snmp.lyx

### LDAP Client (März 2026)

- [x] **std/net/ldap.lyx** - RFC 4511 LDAP Client (LDAPConnect, LDAPBind, LDAPSearch, LDAPUnbind)
- [x] **LDAP Bind** - Simple Bind mit DN + Password Authentifizierung
- [x] **LDAP Search** - BASE, ONE_LEVEL, SUBTREE Scopes mit Filter
- [x] **LDAP Unbind** - Saubere Trennung
- [x] **LDAP Result Codes** - Vollständige RFC 4511 Fehlercodes (SUCCESS bis OTHER)
- [x] **Test-Programm** - tests/lyx/net/test_ldap.lyx

### SSH Client (März 2026)

- [x] **std/net/ssh.lyx** - libssh2 FFI Wrapper (SSHSessionNew, SSHConnect, SSHAuth, SSHExec, SSHOpenShell)
- [x] **SSH Session** - libssh2_session_init_ex, libssh2_session_handshake
- [x] **SSH Auth** - libssh2_userauth_password_ex (Passwort-Authentifizierung)
- [x] **SSH Channels** - libssh2_channel_open_ex, libssh2_channel_process_startup
- [x] **SSH Exec** - SSHExec(session, command) für Remote-Kommandoausführung
- [x] **SSH Shell** - SSHOpenShell(session) für interaktive Sessions
- [x] **SSH I/O** - SSHRead, SSHWrite, SSHEof, SSHSendEof
- [x] **Test-Programm** - tests/lyx/net/test_ssh.lyx

### QUIC Framework (März 2026)

- [x] **std/net/quic.lyx** - RFC 9000 QUIC v1 Protokoll-Framework (QUICConnect, QUICOpenStream, QUICStreamWrite/Read)
- [x] **Packet Structure** - Initial, 0-RTT, Handshake, Retry, 1-RTT Pakettypen
- [x] **Header Encoding** - Long/Short Header, Connection ID, Version
- [x] **Variable-length Integer** - QUIC Varint Encoding (1/2/4/8 Bytes)
- [x] **Frame Types** - CRYPTO, STREAM, ACK, PADDING, CONNECTION_CLOSE, RESET_STREAM
- [x] **Transport Parameters** - Max Data, Max Streams, Idle Timeout, ACK Delay
- [x] **UDP Transport** - UDPSocket Integration für QUIC-Datenübertragung
- [x] **Test-Programm** - tests/lyx/net/test_quic.lyx
- [x] **Hinweis** - Vollständiges QUIC erfordert TLS 1.3 (OpenSSL 3.2+ oder quiche/ngtcp2)

### BGP Client (März 2026)

- [x] **std/net/bgp.lyx** - RFC 4271 BGP-4 Speaker (BGPConnect, BGPAdvertiseRoute, BGPWithdrawRoute)
- [x] **BGP FSM** - Idle, Connect, Active, OpenSent, OpenConfirm, Established
- [x] **BGP Messages** - OPEN, UPDATE, NOTIFICATION, KEEPALIVE
- [x] **OPEN Exchange** - BGPSendOpen + BGPParseOpen + BGPWaitEstablished
- [x] **Route Advertisement** - BGPAdvertiseRoute mit NLRI + Path Attributes
- [x] **Route Withdrawal** - BGPWithdrawRoute mit Withdrawn Routes
- [x] **Path Attributes** - ORIGIN, AS_PATH, NEXT_HOP, LOCAL_PREF, MED
- [x] **IPv4 Helpers** - BGPIPv4, BGPFormatIPv4
- [x] **Test-Programm** - tests/lyx/net/test_bgp.lyx

### MQTT Client (März 2026)

- [x] **std/net/mqtt.lyx** - MQTT v3.1.1 Client (MQTTConnect, MQTTSubscribe, MQTTPublishMsg, MQTTReceive)
- [x] **MQTT Packets** - CONNECT, CONNACK, PUBLISH, SUBSCRIBE, SUBACK, UNSUBSCRIBE, PINGREQ, PINGRESP, DISCONNECT
- [x] **QoS Levels** - QOS 0 (At most once), QOS 1 (At least once), QOS 2 (Exactly once)
- [x] **Variable-length Encoding** - MQTT Remaining Length (1-4 Bytes)
- [x] **Topic Support** - String Topics mit Wildcards (#, +)
- [x] **Keepalive** - PINGREQ/PINGRESP Session Maintenance
- [x] **Test-Programm** - tests/lyx/net/test_mqtt.lyx

### SIP Client (März 2026)

- [x] **std/net/sip.lyx** - RFC 3261 SIP Client (SIPConnect, SIPRegister, SIPSendMessage, SIPOptions)
- [x] **SIP Methods** - REGISTER, INVITE, ACK, BYE, CANCEL, OPTIONS, MESSAGE, SUBSCRIBE, NOTIFY
- [x] **SIP Status Codes** - 1xx-6xx Complete Code Collection (RFC 3261)
- [x] **SIP Headers** - Via, From, To, Call-ID, CSeq, Contact, Max-Forwards, Expires
- [x] **Random Generation** - Call-ID, Branch, Tag via /dev/urandom
- [x] **Status Parsing** - SIPParseStatusCode, SIPParseHeader
- [x] **Test-Programm** - tests/lyx/net/test_sip.lyx

### Whois Client (März 2026)

- [x] **std/net/whois.lyx** - RFC 3912 Whois Client (WhoisQuery, WhoisLookup, WhoisLookupIP)
- [x] **TLD Auto-Selection** - WhoisServerForDomain für .com, .net, .org, .de, .uk, .eu
- [x] **IPv4 Lookup** - WhoisLookupIP via whois.arin.net
- [x] **Field Extraction** - WhoisExtractField für Response-Parsing
- [x] **IPv4 Formatting** - WhoisFormatIPv4
- [x] **Test-Programm** - tests/lyx/net/test_whois.lyx

### HTTPS Client via OpenSSL 3.x (März 2026)

- [x] **std/net/tls.lyx** - OpenSSL 3.x Wrapper (TLSInit, TLSConnect, TLSRead, TLSWrite, TLSClose, TLSFree)
- [x] **SNI Support** - Server Name Indication für moderne HTTPS-Server
- [x] **Zertifikatsprüfung** - SSL_CTX_set_default_verify_paths + SSL_get_verify_result
- [x] **std/net/https.lyx** - HTTPS Client (HTTPSGet, HTTPSPost) über TLS-verschlüsseltem TCP
- [x] **Test-Programm** - tests/lyx/net/test_https.lyx

### ARM64 Dynamic Linking – ELF Generation Fixes (März 2026)

- [x] **DT_NEEDED Library-Name** - Library-Name aus `externSymbols[i].LibraryName` statt Symbolname
- [x] **dynsymOffset berechnung** - Verwendet dynstrSize (aligned to 8) statt hardcoded 8
- [x] **LOAD(RW) p_align** - Korrektes p_align (pageSize) in PT_LOAD(RW) Program Header
- [x] **Hash-Tabelle nchain** - `nchain = symCount + 1` (inkl. null symbol)
- [x] **MOVZ/MOVK Encoding** - Korrekte Instruktionen für GOT_BASE (0x402058) in _start
- [x] **Section Header VAs** - Korrekt relativ zu dynstrOffset
- [x] **PLT mit X17** - GOT-Lookups über X17 statt X16 (vermeidet Register-Kollision)
- [x] **WriteLdrImm9 Helper** - PLT Instruktion Encoding (LDR mit signed offset)
- [x] **strlen Inline-Code** - Workaround für libc init: strlen wird inline generiert

### Dynamic Linking & Section Headers (März 2026)

- [x] **Sektionstabellen (static ELF)** - .text + .shstrtab Section Headers → objdump -d und readelf -S funktionieren
- [x] **cmExternal Erkennung** - irCall mit CallMode=cmExternal wird im Backend erkannt
- [x] **AddExternalSymbol** - Externe Symbole werden in FExternalSymbols registriert
- [x] **PLT-Stubs** - PLT0 (16B) + PLTn (16B/Symbol) am Ende des Code-Buffers generiert
- [x] **Call-Via-PLT** - Externe Calls generieren call @plt_SymName, Labels vor Patching registriert
- [x] **extern fn strlen** - Funktionalität verifiziert: strlen("Hello") = 5, strlen("Hello Dynamic!") = 14

### Nested Functions & Closures (März 2026)

- [x] **Parser** - `fn` in ParseStmt erkannt, erzeugt TAstFuncStmt Wrapper
- [x] **AST** - TAstFuncStmt (TAstFuncDecl als TAstStmt), Forward-Deklaration für TAstFuncDecl
- [x] **Sema** - Name im Scope registriert für Call-Resolution
- [x] **Lower** - LowerNestedFunc: Context save/restore, separate TIRFunction
- [x] **Closures: AST** - TCapturedVar, CapturedVars, NeedsStaticLink, ParentFuncName
- [x] **Closures: Sema** - Scope-Level-Tracking, ResolveSymbolLevel, Capture-Erkennung
- [x] **Closures: IR** - irLoadCaptured Opcode, cmStaticLink CallMode, TIRFunction.CapturedVars
- [x] **Closures: Lower** - Static-Link als Slot 0, Capture-Lade-Code via irLoadCaptured
- [x] **Closures: Backend** - irLoadCaptured (mov rax,[rbp]+mov rcx,[rax+offset]), cmStaticLink Args

### ARM64 VMT Support (März 2026)

- [x] **VMT-Datenstrukturen** - FVMTLabels, FVMTLeaPositions, FVMTAddrLeaPositions im ARM64 Emitter
- [x] **Virtual Call Dispatch** - ldr x0,[x0] + ldr x0,[x0,#idx*8] + blr x0
- [x] **VMT-Tabellenerzeugung** - Methoden-Pointer im Code-Segment nach Funktionen
- [x] **VMT-Entry-Patching** - Funktion-Adressen via Mangled Name in VMT eintragen
- [x] **VMT-Adresse laden** - ADRP+ADD für irLoadGlobalAddr mit _vmt_ Prefix
- [x] **Helpers** - WriteBlr (indirekter Call), WriteLdrRegOffset (LDR mit Offset)

### SSE2 Float-Codegen Linux x86_64 (März 2026)

- [x] **SSE2-Hilfsfunktionen** - WriteMovsdLoad/Store, WriteAddsd, WriteSubsd, WriteMulsd, WriteDivsd, WriteUcomisd, WriteCvtsi2sd, WriteCvttsd2si
- [x] **Float IR-Branches** - irConstFloat, irFAdd, irFSub, irFMul, irFDiv, irFNeg, irFCmp*, irFToI, irIToF
- [x] **Lexer Float-Bug** - Unterstriche bei Float-Literalen entfernen
- [x] **irConstStr Patching** - FStringOffsets-Prüfung entfernt (verhinderte LEA-Patching)
- [x] **irLoadElem Slot-Konflikt** - RAX-Save via push/pop statt [rbp-8]

### irAnd/irOr/irNot (März 2026)

- [x] **irAnd** - Bitweises AND (and rax, rcx)
- [x] **irOr** - Bitweises OR (or rax, rcx)
- [x] **irNot** - Bool-Not (test + sete + movzx)
- [x] **irNor** - NOR (or + test + sete)
- [x] **irXor** - Bitweises XOR (xor rax, rcx)

### Array Literals in Expression-Position (März 2026)

- [x] **LowerArrayLit** - Stack-Allokation, REVERSE-Order Store, irLoadLocalAddr
- [x] **Bounds-Check-Bugfix** - irJmp skip Labels nach irLoadElem/irStoreElem
- [x] **irAnd-Ersatz** - Zwei separate irCmpLt/irCmpGe + irBrTrue statt irAnd

### VMT Support (v0.5.1)

- [x] **Linux ARM64 VMT** - VMT-Tabelle, Virtual Calls, VMT-Pointer bei `new`
- [x] **Windows x86_64 VMT** - VMT-Tabelle im PE, Virtual Calls, RTTI
- [x] **IR Opcodes** - 100% Coverage für ARM64 (93/93 Opcodes)

### std.net Library (v0.5.x)

- [x] **TCP Sockets** - SocketNew/Bind/Listen/Accept/Connect/Close
- [x] **Unix Domain Sockets** - AF_UNIX, sockaddr_un
- [x] **DNS Resolution** - GetHostByName(), ResolveHost()
- [x] **HTTP Client** - HTTPGet(), HTTPPost(), HTTPSend()
- [x] **HTTPS Client** - OpenSSL 3.x FFI (std.net.tls + std.net.https) mit SNI + Zertifikatsprüfung
- [x] **TLS/SSL** - TLSInit(), TLSConnect(), TLSRead(), TLSWrite() via libssl.so.3
- [x] **Telnet Client** - RFC 854 (TelnetConnect, TelnetRead, TelnetWrite, Option Negotiation)
- [x] **SMTP Client** - RFC 5321 (SMTPConnect, SMTPSend, SMTPQuit, EHLO/MAIL/RCPT/DATA)
- [x] **IMAP Client** - RFC 3501 (IMAPConnect, IMAPLogin, IMAPSelect, IMAPFetchRaw, IMAPList)
- [x] **NTP Client** - RFC 5905 (NTPGetTime, NTPParseResponse, NTPFormatTime)
- [x] **SNMP Client** - RFC 1157/1905 (SNMPGet, SNMPBuildGetRequest, ASN.1/BER Encoding)
- [x] **LDAP Client** - RFC 4511 (LDAPConnect, LDAPBind, LDAPSearch, LDAPUnbind)
- [x] **SSH Client** - libssh2 FFI (SSHConnect, SSHAuth, SSHExec, SSHOpenShell, SSHRead/Write)
- [x] **QUIC Framework** - RFC 9000 (QUICConnect, QUICOpenStream, Packet/Framing Layer)
- [x] **BGP Client** - RFC 4271 (BGPConnect, BGPAdvertiseRoute, BGPWithdrawRoute, BGP FSM)
- [x] **MQTT Client** - MQTT v3.1.1 (MQTTConnect, MQTTSubscribe, MQTTPublishMsg, MQTTReceive)
- [x] **SIP Client** - RFC 3261 (SIPConnect, SIPRegister, SIPSendMessage, SIPOptions)
- [x] **Whois Client** - RFC 3912 (WhoisQuery, WhoisLookup, WhoisLookupIP, WhoisExtractField)
- [x] **TCP Connection Pool** - TCPConnectionPoolNew/Acquire/Release/Close
- [x] **Struct Array Bug** - Arrays aus Structs entfernt (Compiler-Bug Workaround)

### Backend Fixes

- [x] **IR Float Bug** - `irFSub/irFMul/irFDiv` statt `irSub/irMul/irDiv`
- [x] **ARM64 SIMD** - NEON-Hilfsfunktionen (Add, Sub, Mul, And, Or, etc.)
- [x] **ARM64 DynArray** - irDynArrayPush/Pop/Len/Free
- [x] **Map/Set** - irMapRemove, irSetRemove, irMapFree, irSetFree

### Frontend

- [x] **Zahlenbasen** - Hex (`0xFF`, `$FF`), Binär (`0b1010`, `%1010`), Oktal (`0o77`, `&77`)
- [x] **Unterstriche** - Trenner in Zahlen (`0b1100_1010`)
- [x] **Where-Klausel** - Typ-Constraints mit `where { value >= 0 }`

---

## Versionsverlauf

### v0.5.5 (März 2026)
- `pchar + pchar` String-Konkatenation via `mmap`-Buffer und `rep movsb`
- `PrintFloat(f64)` Builtin: SSE2-basiert, Vorzeichen + Ganzzahl + 6 Dezimalstellen
- `:width:decimals` Format-Specifier (Pascal-style): `pi:0:2` → `format_float` Builtin
- Linter: 3 neue Regeln (W011 `format-zero-decimals`, W012 `string-concat-literals`, W013 `print-float-int-arg`)
- HTTPS Client via OpenSSL 3.x FFI (std.net.tls + std.net.https)
- TLS/SSL: TLSInit, TLSConnect, TLSRead, TLSWrite, TLSClose, TLSFree
- Telnet Client (RFC 854): TelnetConnect, TelnetRead, TelnetWrite, Option Negotiation
- SMTP Client (RFC 5321): SMTPConnect, SMTPSend, SMTPQuit, EHLO/MAIL/DATA
- IMAP Client (RFC 3501): IMAPConnect, IMAPLogin, IMAPSelect, IMAPFetchRaw, IMAPList
- NTP Client (RFC 5905): NTPGetTime, NTPParseResponse, NTPFormatTime
- SNMP Client (RFC 1157/1905): SNMPGet, SNMPBuildGetRequest, ASN.1/BER Encoding
- LDAP Client (RFC 4511): LDAPConnect, LDAPBind, LDAPSearch, LDAPUnbind
- SSH Client (libssh2): SSHConnect, SSHAuth, SSHExec, SSHOpenShell
- QUIC Framework (RFC 9000): Packet Structure, Varint Encoding, Stream Framing
- BGP Client (RFC 4271): BGPConnect, BGPAdvertiseRoute, BGP FSM, Path Attributes
- MQTT Client (v3.1.1): MQTTConnect, MQTTSubscribe, MQTTPublishMsg, QoS Levels
- SIP Client (RFC 3261): SIPConnect, SIPRegister, SIPSendMessage, SIPOptions
- Whois Client (RFC 3912): WhoisQuery, WhoisLookup, WhoisLookupIP, WhoisExtractField
- EAN/ISBN/UPC Validation: EAN13Validate, EAN13CheckDigit, ISBN13Validate, ISBN10Validate, UPCAValidate, Country Detection
- ISBN/ISSN Module: ISBN13ValidateFull, ISBN10ValidateFull, ISBN10To13, ISBN13To10, ISSNValidate, ISBN/ISSN Formatting
- Luhn/Credit Card Validation: LuhnValidate, CreditCardType, CreditCardValidate, CreditCardMask, CreditCardFormat, 8 Kreditkarten-Typen, IMEI Validation
- IBAN Validation (ISO 13616): IBANValidate, IBANCalculateCheck, IBANFormat, 50+ Länder, Bank ID Extraktion
- Country Codes (ISO 3166-1): CountryGetName, CountryGetCode, CountryGetCurrency, 67 Länder, Region Detection
- VAT ID Validation (EU 27): VATValidate, VATGetCountryName, VATGetFormat, 27 Länder mit Checksummen
- Statistics Module: ArraySum, ArrayMin, ArrayMax, ArrayAvg, ArrayMedian, ArrayCount, ArraySort, ArrayFilter, ArrayVariance, ArrayStdDev
- Mathematical Constants: PI, E, TAU, PHI, SQRT2, SQRT3, DegToRad, RadToDeg, ApproxEqual
- Data Library (Pandas): DataFrame, Series, CSV I/O, GroupBy, Filter, Slice, Missing Values, Join, Pivot, Melt, Correlation, Sort, Head/Tail, Concat, Replace, Rank, CumSum, Shift, Diff, Index Labels, Float64, Rolling, Agg, Apply, Boolean Indexing, String Ops, GetDummies, Normalize, DateTime, Sample, Cut, MultiIndex, Interpolate
- ARM64 Dynamic Linking vollständig funktional (PLT/GOT, Hash-Tabelle, Relocations)

### v0.5.4 (März 2026)
- C FFI: Windows x64 IAT-Import (`GetExternLibrary` → `msvcrt.dll`, `FindOrAddImportDll/Func`)
- C FFI: macOS x86_64 + ARM64 Dynamic Mach-O (`LC_LOAD_DYLIB` + dyld bind opcodes + Stub-PLT)
- macOS x86_64: volle IR-Coverage (70 Opcodes) via `TX86_64Emitter` mit `SetTargetOS(atmacOS)`
- `importC` auf ARM64: extern fn via PLT/GOT statt Inline-Stub
- `TTargetOS` als gemeinsamer Typ in `backend_types.pas`

### v0.5.3 (März 2026)
- Sektionstabellen für statisches ELF (objdump -d support)
- PLT/GOT Dynamic Linking (extern fn → PLT-Stubs → libc.so.6)
- cmExternal Call-Routing über PLT
- ARM64 VMT Support (Virtual Call, ADRP/ADD, VMT-Tabellen)
- Nested Functions (Lifting-Ansatz, ohne Closures)
- Closures via Static-Link (Parent-RBP als impliziter Parameter)
- C FFI: `extern fn ... link "libname"` und `importC "header.h" link "libname"`
- C Header Parser (TCHeaderParser) mit GCC-Attribut-Handling

### v0.5.2 (März 2026)
- SSE2 Float-Codegen für Linux x86_64
- irAnd/irOr/irNot/irNor/irXor im x86_64 Backend
- Array-Literale in Expression-Position (LowerArrayLit)
- Bounds-Checking Bugfix (irJmp skip Labels)

### v0.5.1 (März 2026)
- Linux ARM64 VMT Support
- 100% IR Opcode Coverage für ARM64
- std.net: DNS, Connection Pool, HTTP Client
- IR Float Bugfix

### v0.5.0 (März 2026)
- IR Optimizer: Constant Folding, CSE, DCE, Copy Propagation
- Windows x86_64 VMT Support
- Map<K,V> und Set<T>
- In-Situ Data Visualizer

### v0.4.3 (Februar 2026)
- IR-Level Inlining
- PascalCase Naming Conventions
