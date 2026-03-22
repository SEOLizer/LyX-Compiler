# Lyx Compiler ToDo Liste

## Aktuelle Aufgaben

### std.net Library

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **IPv6 Support** | `SockAddrIn6` struct existiert, wird aber nicht verwenden |
| Niedrig | **SSH Client** | SSH-Client via libssh FFI |

### Dynamic Linking

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | ~~**GOT-Einträge validieren**~~ ✅ | Initiale Werte der GOT prüfen (lazy binding) |
| Niedrig | ~~**macOS Dynamic Linking**~~ ✅ | PLT/GOT für Mach-O implementieren (LC_LOAD_DYLIB + Stub-PLT) |
| Niedrig | ~~**ARM64 PLT/GOT Implementation**~~ ✅ | LDR (literal) + BR X17 PLT-Stubs, DT_PLTREL fix, dataBuf im RW-Segment |
| Mittel | **ARM64 libc init fix** | CRT-Start-Code (crt1.o) emittieren, `__libc_start_main` aufrufen |
| Niedrig | **ARM64 PIE (ET_DYN) Binary** | Position Independent Executable für bessere libc-Kompatibilität |

### C FFI

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | ~~**Windows x64 FFI**~~ ✅ | `GetExternLibrary` in `win64_emit.pas` auswerten → DLL-Name für IAT-Import |
| Niedrig | ~~**macOS x86_64 FFI**~~ ✅ | Dynamic Mach-O: `LC_LOAD_DYLIB` + Stub-PLT für `extern fn link` |
| Niedrig | ~~**macOS ARM64 FFI**~~ ✅ | Dynamic Mach-O ARM64: `LC_LOAD_DYLIB` + Stub-PLT für `extern fn link` |
| Niedrig | ~~**`importC` auf ARM64**~~ ✅ | `importC "header.h"` mit `--target=linux-arm64` testen und verifizieren |

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

### SMTP Client (März 2026)

- [x] **std/net/smtp.lyx** - RFC 5321 SMTP Client (SMTPConnect, SMTPSend, SMTPQuit)
- [x] **SMTP Commands** - EHLO, MAIL FROM, RCPT TO, DATA, QUIT
- [x] **Response Parsing** - 3-digit SMTP response code parsing
- [x] **Message Building** - Headers (From, To, Subject) + Body + Dot-stuffing
- [x] **High-level API** - SMTPSend() - complete email send in one call
- [x] **Test-Programm** - tests/lyx/net/test_smtp.lyx

### IMAP Client (März 2026)

- [x] **std/net/imap.lyx** - RFC 3501 IMAP Client (IMAPConnect, IMAPLogin, IMAPSelect, IMAPFetchRaw)
- [x] **IMAP Commands** - LOGIN, SELECT, LIST, FETCH, LOGOUT
- [x] **Tagged Commands** - A001, A002, ... Sequence-Nummern
- [x] **Untagged Responses** - * OK, * EXISTS, * RECENT, * UNSEEN, * UIDVALIDITY
- [x] **Multi-line Reading** - FETCH und LIST Responses mit mehreren Zeilen
- [x] **Data Items** - FLAGS, ENVELOPE, BODY, RFC822, UID
- [x] **Test-Programm** - tests/lyx/net/test_imap.lyx

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
- HTTPS Client via OpenSSL 3.x FFI (std.net.tls + std.net.https)
- TLS/SSL: TLSInit, TLSConnect, TLSRead, TLSWrite, TLSClose, TLSFree
- Telnet Client (RFC 854): TelnetConnect, TelnetRead, TelnetWrite, Option Negotiation
- SMTP Client (RFC 5321): SMTPConnect, SMTPSend, SMTPQuit, EHLO/MAIL/DATA
- IMAP Client (RFC 3501): IMAPConnect, IMAPLogin, IMAPSelect, IMAPFetchRaw, IMAPList
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
