# Lyx Compiler ToDo Liste

## Aktuelle Aufgaben

### std.net Library

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **IPv6 Support** | `SockAddrIn6` struct existiert, wird aber nicht verwendet |
| Mittel | **HTTP Client** | HTTPS-Client für std.net implementieren |
| Niedrig | **TLS Support** | TLS/SSL für sichere Verbindungen |

### Dynamic Linking

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **GOT-Einträge validieren** | Initiale Werte der GOT prüfen (lazy binding) |
| Niedrig | **macOS Dynamic Linking** | PLT/GOT für Mach-O implementieren |
| Niedrig | **ARM64 Dynamic Linking** | PLT/GOT für ARM64 Linux implementieren |

### Backend

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **Windows VMT Tests** | Virtual Calls auf echter Windows-Hardware testen |
| Niedrig | **macOS ARM64 VMT** | VMT-Support für macOS ARM64 (Mach-O) |

### Sprache / Frontend

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **Nested Functions** | Interne Helper könnten als nested functions definiert werden |

### Tech Debts

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **Leere Arrays + push** | Compiler-Crash bei `var a := []; push(a, 42)` |
| Niedrig | **`std/geo.lyx` Return-Type** | `[GeoPoint, GeoPoint]` als generischer Array-Typ im Parser |
| Niedrig | **`irLoadLocalAddr` Large Offsets** | RBP-relative Offsets > 127 Bytes prüfen |

### Dokumentation

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **lyxvision.md** | "TODO" Überschrift ist veraltet - Module sind implementiert |
| Niedrig | **dyn.md** | Debugging-Tasks für PLT/GOT dokumentieren |

---

## Abgeschlossene Aufgaben

### Dynamic Linking & Section Headers (März 2026)

- [x] **Sektionstabellen (static ELF)** - .text + .shstrtab Section Headers → objdump -d und readelf -S funktionieren
- [x] **cmExternal Erkennung** - irCall mit CallMode=cmExternal wird im Backend erkannt
- [x] **AddExternalSymbol** - Externe Symbole werden in FExternalSymbols registriert
- [x] **PLT-Stubs** - PLT0 (16B) + PLTn (16B/Symbol) am Ende des Code-Buffers generiert
- [x] **Call-Via-PLT** - Externe Calls generieren call @plt_SymName, Labels vor Patching registriert
- [x] **extern fn strlen** - Funktionalität verifiziert: strlen("Hello") = 5, strlen("Hello Dynamic!") = 14

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

### v0.5.3 (März 2026)
- Sektionstabellen für statisches ELF (objdump -d support)
- PLT/GOT Dynamic Linking (extern fn → PLT-Stubs → libc.so.6)
- cmExternal Call-Routing über PLT

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
