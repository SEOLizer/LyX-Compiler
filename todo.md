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
| Hoch | **PLT/GOT Debugging** | dyn.md Debugging-Tasks für dynamisches Linking |
| Hoch | Sektionstabellen aktivieren | Temporär Sektionstabellen für objdump aktivieren |
| Mittel | GOT-Einträge validieren | Initiale Werte der GOT prüfen |

### Backend

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Mittel | **Windows VMT Tests** | Virtual Calls auf echter Windows-Hardware testen |
| Niedrig | **macOS ARM64 VMT** | VMT-Support für macOS ARM64 (Mach-O) |

### Sprache / Frontend

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **Float Literals** | Dummy-Werte durch echte Float-Literal-Parsing ersetzen |
| Niedrig | **Array Literals** | Dummy-Werte durch echte Array-Literal-Parsing ersetzen |
| Niedrig | **Nested Functions** | Interne Helper könnten als nested functions definiert werden |

### Dokumentation

| Priorität | Task | Beschreibung |
|-----------|------|--------------|
| Niedrig | **lyxvision.md** | "TODO" Überschrift ist veraltet - Module sind implementiert |
| Niedrig | **dyn.md** | Debugging-Tasks für PLT/GOT dokumentieren |

---

## Abgeschlossene Aufgaben

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

### IR-Lowering

- [x] **Float Literale** - Dummy-Parsing in AST für `3.14`, `-1.5e+10`
- [x] **Array Literale** - Dummy-Parsing in AST für `[1, 2, 3]`

### Frontend

- [x] **Zahlenbasen** - Hex (`0xFF`, `$FF`), Binär (`0b1010`, `%1010`), Oktal (`0o77`, `&77`)
- [x] **Unterstriche** - Trenner in Zahlen (`0b1100_1010`)
- [x] **Where-Klausel** - Typ-Constraints mit `where { value >= 0 }`

---

## Versionsverlauf

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
