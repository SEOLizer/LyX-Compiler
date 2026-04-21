# Lyx

**Lyx** is a native compiler for the homonymous programming language, written in FreePascal.
It produces directly executable binaries for multiple platforms without libc, without linker, using pure syscalls or WinAPI.

```
Lyx Compiler v0.8.2-aerospace
Copyright (c) 2026 Andreas Röne. All rights reserved.

✅ Cross-Compilation: Linux x86_64, Linux ARM64, Windows x64,
   macOS x86_64, macOS ARM64, ESP32/Xtensa, RISC-V RV64GC
✅ DO-178C TQL-5 Qualified Compiler (aerospace safety-critical)
✅ 100% IR Coverage in all 7 backends (TOR-011 validated)
✅ Reference Interpreter for compiler verification (22/22 tests)
✅ Deterministic code generation validated (18/18 tests)
✅ Architecture Parameter: --arch=x86_64|arm64|xtensa|riscv
✅ Target Parameter: --target=linux|arm64|win64|macosx64|macos-arm64|esp32|riscv
✅ Complete Module System with Import/Export
✅ Cross-Unit Function Calls and Symbol Resolution
✅ Unified Call Path (internal/imported/extern)
✅ PLT/GOT Dynamic Linking for External Libraries
✅ ARM64 Dynamic Linking fully functional (PLT/GOT, Hash Table, Relocations)
✅ Standard Library (std.math, std.io, std.string, std.geo, std.time, std.fs, ...)
✅ Network Library (std.net): 17 Protocols with RFC Compliance
✅ IR-Level Inlining Optimization (v0.4.3)
✅ IR-Level Optimizer (v0.5.0): Constant Folding, CSE, DCE, Copy Propagation, Strength Reduction
✅ PascalCase Naming Conventions (v0.4.3)
✅ Integrated Linter with 13 Rules (v0.4.3 / v0.5.5)
✅ Peephole Optimizer (v0.5.0): Constant folding, identity ops, redundant moves
✅ Robust Parser with While/If/For/Switch/Function Support
✅ OOP: Classes, Inheritance, Virtual Methods (VMT), Override
✅ Global Variables with Initialization
✅ Random/RandomSeed Builtins
✅ CLI Arguments (argc/argv) in Static ELF
✅ Option Types: Nullable Pointer (pchar?) with Null-Coalescing (??)
✅ SIMD: ParallelArray<T> with Element-wise Operations
✅ Dynamic Arrays: push/pop/len/free
✅ QBool: Probabilistic Boolean Type for quantum-like computing
✅ Associative Arrays: Map<K,V> and Set<T> with O(n) lookup
✅ In-Situ Data Visualizer: Inspect() builtin for runtime debugging
✅ String Concatenation: pchar + pchar via mmap'd buffers (v0.5.5)
✅ Float Formatting: PrintFloat(f64) and :width:decimals format specifier (v0.5.5)
✅ Enum Types: enum keyword with :: member access (v0.5.7)
✅ Exception Handling: try/catch/throw with nested scopes (v0.5.7)
✅ Multi-Return / Tuples: return (a, b) and var a, b := f() (v0.5.7)
✅ Generics: fn max[T](a: T, b: T): T — monomorphization (v0.5.7)
✅ Pattern Matching: match/case/default with => and OR patterns | (v0.5.7)
✅ MC/DC Instrumentation: DO-178C DAL A coverage (--mcdc, --mcdc-report) (v0.7.0)
✅ Assembly Listing: Source-annotated assembly output with hex bytes (--asm-listing) (v0.7.0)
✅ Runtime Assertions: Bounds, Null, Zero, Boolean checks at runtime (--runtime-checks) (v0.9.0)
✅ DWARF Debug Info: DWARF 4 sections for gdb/lldb/VS Code (-g) (v0.9.0)
✅ Static Analysis: Data-Flow, Live-Vars, Const-Prop, Null-Ptr, Array-Bounds, Termination, Stack (--static-analysis) (v0.7.0)
✅ Test Generation: Fuzzing, Boundary-Value, Mutation Testing, Symbolic Execution (v0.7.0)
✅ ESP32 Safety: Watchdog, Brownout, Flash-Verify, MPU, Stack-Canary (v0.7.0)
✅ ARM Cortex-M Safety: MPU, Fault-Handlers, Stack-Canary, TrustZone stubs (v0.7.0)
✅ RISC-V RV64GC Backend: PMP, CSR access, ecall/ebreak, atomic ops (v0.7.0)
✅ Dynamic String Builtins: StrNew/StrFree/StrLen/StrCharAt/StrSetChar/StrAppend/StrFromInt (v0.5.7)
✅ String Utility Builtins: StrFindChar/StrSub/StrAppendStr/StrConcat/StrCopy/IntToStr/FileGetSize (v0.5.7)
✅ HashMap Builtins: HashNew/HashSet/HashGet/HashHas — O(1) FNV-1a string→int64 map (v0.5.7)
✅ Argv Builtins: GetArgC/GetArg — access command-line arguments (v0.5.7)
✅ String Comparison Builtins: StrStartsWith/StrEndsWith/StrEquals (v0.5.7)
✅ String Library (std.string): StringBuilder class, StrTrim, StrSplit (v0.5.7)
✅ Safety Pragmas: @dal(A|B|C|D), @critical, @wcet(N), @stack_limit(N) — DO-178C function-level annotations (v0.8.0)
✅ Range Types: type T = int64 range Min..Max — compile-time and runtime bounds checking (v0.8.2)
✅ check() Builtin: check(cond) — runtime-only assertion without message, panics if false (v0.8.2)
✅ Integrity Management: @integrity(mode, interval) — unit/function-level radiation protection; .meta_safe ELF section with triple CRC32 (v0.9.0)
✅ VerifyIntegrity() Builtin: Runtime TMR majority-vote integrity check — compares 3 CRC32 hashes at runtime (v0.9.0)
✅ TMR Hash-Store: Compile-time CRC32 triple-hash embedded in data section; runtime comparison via movabs + cmp (v0.9.0)
✅ Endianness Annotations: @big_endian / @little_endian on structs for telemetry byte-order management (v0.9.0)
✅ Flat Structs: `flat struct` — compiler-enforced zero-pointer guarantee for zero-copy serialization (v0.9.0)
✅ Bit-Level Memory Mapping: `packed struct` with `at(N)` bit-position fields for hardware register mapping (v0.9.0)
✅ @redundant: Triple Modular Redundancy for global variables — 3 RAM copies with majority-vote reads (v0.9.0)
✅ @flight_crit: Strict FP determinism — MXCSR round-to-zero, disabled FP constant folding (v0.9.0)
```

---

## Singularity: Lyx has been self-hosting since March 30, 2026

On **March 30, 2026**, Lyx reached **Singularity** — the Lyx compiler fully compiles itself.

### What does Singularity mean?

A compiler is *self-hosted* when it can translate its own source code and produce a binary-identical result. This is proven through a multi-stage bootstrap chain:

```
Stage 1  lyxc (FPC-compiled)  →  compiles bootstrap/*.lyx  →  Stage 2
Stage 2  (Lyx-compiled)        →  compiles bootstrap/*.lyx  →  Stage 3
Stage 3  (Lyx-compiled)        →  compiles bootstrap/*.lyx  →  Stage 4
```

Once **MD5(Stage 3) = MD5(Stage 4)**, the compiler has reached a stable fixed point: it reproduces itself bit for bit. That is Singularity.

Stage 2 may differ from Stage 3 — the optimizing compiler generates better code for itself on the first pass. From Stage 3 onward, the fixed point is reached.

### Verified Hash (2026-03-30)

```
MD5  9100b4d4b170c38474ee7a5594023790
```

This hash applies to Stage 3, Stage 4, and all subsequent stages — the compiler is stably self-hosting.

Details on the bootstrap roadmap: [`selfhosted.md`](selfhosted.md)
Implementation: [`bootstrap/`](bootstrap/)

---

## Repository-Struktur

```
lyx-lang/                        # Repo-Root
├── compiler/                    # FPC-basierter Lyx-Compiler (lyxc)
│   ├── lyxc.lpr                 # Hauptprogramm (Einstiegspunkt)
│   ├── Makefile                 # Build-Regeln (Output: ../lyxc)
│   ├── frontend/                # Lexer, Parser, AST, Sema, Builtins
│   ├── backend/                 # Code-Generierung pro Plattform
│   │   ├── x86_64/              #   x86-64 Linux/Windows
│   │   ├── arm64/               #   ARM64 Linux
│   │   ├── elf/                 #   ELF64 Writer (Linux)
│   │   ├── pe/                  #   PE64 Writer (Windows)
│   │   ├── macho/               #   Mach-O Writer (macOS)
│   │   ├── macosx64/            #   macOS x86-64 Emitter
│   │   ├── win_arm64/           #   Windows ARM64
│   │   ├── esp32/               #   ESP32/Xtensa
│   │   └── xtensa/              #   Xtensa Emitter
│   ├── ir/                      # IR-Definitionen, Lowering, Optimierung
│   └── util/                    # Hilfsfunktionen (bytes, diag)
│
├── bootstrap/                   # Lyx-in-Lyx (WP-05..WP-09, in Arbeit)
│   ├── lexer.lyx                # Tokenizer in Lyx
│   ├── parser.lyx               # Parser in Lyx
│   ├── codegen.lyx              # Code-Generator in Lyx
│   └── lyxc_mini.lyx            # Mini-Compiler-Einstiegspunkt
│
├── std/                         # Standardbibliothek (Lyx-Code)
│   ├── math.lyx, io.lyx, ...    # Basis-Module
│   ├── net/                     # Netzwerk-Protokolle (14+)
│   └── validate/, math/, ...    # Weitere Module
│
├── tests/
│   ├── regression/              # Kern-Tests — müssen von beiden Compilern bestanden werden
│   │   ├── basic/               #   Grundlegende Sprachkonstrukte
│   │   ├── arrays/, control/    #   Arrays, Schleifen, Bedingungen
│   │   ├── oop/, structs/       #   OOP, Klassen, VMT
│   │   ├── strings/, math/      #   Strings, Math-Builtins
│   │   └── ...                  #   (25+ Kategorien)
│   └── feature_checks/          # Feature-Tests für neue Sprachfeatures
│       ├── generics/            #   fn max[T](...) — Monomorphisierung
│       ├── pattern_matching/    #   match/case/| — Pattern Matching
│       ├── tuples/              #   return (a, b), var a, b := f()
│       ├── enums/               #   enum Color { Red, Green, Blue }
│       └── exceptions/          #   try/catch/throw
│
├── scripts/                     # Build- und Bootstrap-Skripte
├── examples/                    # Lyx-Beispielprogramme (siehe unten)
│
├── Makefile                     # Root-Wrapper (delegiert an compiler/Makefile)
├── README.md                    # Diese Datei
├── CHANGELOG.md                 # Versionshistorie
├── selfhosted.md                # Selfhosting-Roadmap (WP-01..WP-09)
└── ebnf.md / DATATYPES.md       # Sprachspezifikation
```

### Examples (`examples/`)

Das `examples/`-Verzeichnis enthält kuratierte Beispielprogramme, die verschiedene Lyx-Sprachfeatures und -Bibliotheken demonstrieren. Die Examples sind nach Kategorien organisiert:

```
examples/
├── basics/              # Grundlegende Sprachfeatures
│   ├── hello.lyx                    # Hello World
│   ├── simple_return.lyx           # Einfache Rückgabe
│   ├── variables.lyx               # var, let, const, Rechnen
│   ├── control_flow.lyx            # if-else, while-Schleifen
│   ├── arrays.lyx                  # Statische Arrays
│   ├── functions.lyx               # Funktionen, Rekursion
│   └── strings.lyx                 # String-Grundlagen
│
├── algorithms/          # Sortier- und Suchalgorithmen
│   ├── quick_sort.lyx               # Quick Sort Algorithmus
│   ├── binary_search.lyx            # Binäre Suche
│   ├── fibonacci_dp.lyx             # Fibonacci (iterativ)
│   └── eratosthenes.lyx             # Sieb des Eratosthenes
│
├── bitwise/             # Bit-Operationen
│   ├── bitwise_operators.lyx        # AND, OR, XOR, NOT, Shifts
│   └── bit_flags.lyx                # Flags setzen/löschen/maskieren
│
├── math/                # Mathematik
│   └── matrix.lyx                    # 2D-Matrizen, Operationen
│
├── crypto/              # Kryptographie (Konzepte)
│   ├── base64.lyx                    # Base64 Encoding/Decoding
│   └── xor_cipher.lyx               # XOR-Verschlüsselung
│
├── memory/              # Speicherverwaltung
│   ├── pointer_basics.lyx           # Pointer-Konzepte, Adressen
│   ├── memory_management.lyx        # mmap, Allocation
│   └── malloc_free.lyx              # Dynamische Allokation
│
├── time/                # Zeit und Datum
│   ├── date_time.lyx                # Unix Epoch, Timestamps
│   ├── sleep_timer.lyx              # Warte-Funktionen, Timer
│   └── stopwatch.lyx               # Stoppuhr, Rundenzeiten
│
├── io/                  # Ein- und Ausgabe
│   ├── fs/                            # Dateisystem
│   │   ├── file_operations.lyx       # open, read, write, close
│   │   ├── file_read.lyx            # Datei lesen
│   │   ├── file_write.lyx           # Datei schreiben
│   │   └── file_lines.lyx           # Zeilenweises Lesen
│   ├── mmap/                         # Memory-mapped I/O
│   ├── ioctl/                        # ioctl-Operationen
│   └── net/                          # Netzwerk-Beispiele (TCP, UDP, DNS, etc.)
│
├── units/               # Modul-System (Units)
│   ├── math_utils.lyx               # Beispiel-Unit mit Funktionen
│   ├── string_utils.lyx             # String-Utility-Unit
│   ├── use_math_utils.lyx           # Import und Nutzung von Units
│   ├── myunit.lyx
│   ├── main_with_unit.lyx
│   └── test/                        # Unit-Tests
│
├── hardware/            # Hardware-spezifisch
│   ├── esp32_hello.lyx              # ESP32 Hello World
│   └── raspberry/                    # Raspberry Pi GPIO
│       ├── gpio_led.lyx             # LED ein-/ausschalten
│       ├── gpio_input.lyx           # Taster auslesen
│       ├── gpio_button_led.lyx      # Button + LED
│       ├── gpio_pwm.lyx             # PWM (Helligkeit)
│       ├── hc_sr04.lyx              # Ultraschall-Sensor
│       ├── i2c_sensor.lyx           # I2C-Sensoren
│       ├── spi_device.lyx           # SPI-Geräte
│       └── onewire_sensor.lyx       # 1-Wire (DS18B20)
│
├── games/               # Spiele
│   └── game1/
│
└── lyxvision/           # Lyxvision GUI-Demos
```

#### Examples kompilieren und ausführen

```bash
# Einzelnes Example kompilieren
./lyxc examples/basics/hello.lyx -o hello
./hello

# Alle Basics testen
./lyxc examples/basics/variables.lyx -o /tmp/vars && /tmp/vars

# Raspberry Pi GPIO Demo
./lyxc examples/hardware/raspberry/gpio_led.lyx -o /tmp/gpio_led && /tmp/gpio_led
```

#### Kategorien im Überblick

| Kategorie | Beschreibung | Example-Dateien |
|-----------|--------------|-----------------|
| **basics** | Grundlegende Syntax: Variablen, Schleifen, Funktionen | `hello.lyx`, `variables.lyx`, `functions.lyx` |
| **algorithms** | Sortier- und Suchalgorithmen | `quick_sort.lyx`, `binary_search.lyx` |
| **bitwise** | Bit-Operationen und Maskierung | `bitwise_operators.lyx`, `bit_flags.lyx` |
| **math** | Mathematische Konzepte | `matrix.lyx` |
| **crypto** | Encoding und einfache Verschlüsselung | `base64.lyx`, `xor_cipher.lyx` |
| **memory** | Pointer und Speicherverwaltung | `pointer_basics.lyx`, `memory_management.lyx` |
| **time** | Zeitberechnungen und Timer | `date_time.lyx`, `stopwatch.lyx` |
| **io/fs** | Dateisystem-Operationen | `file_operations.lyx`, `file_read.lyx` |
| **io/net** | Netzwerk-Programmierung | TCP/UDP/DNS Beispiele |
| **hardware** | Hardware-Zugriff | GPIO, I2C, SPI, 1-Wire |
| **units** | Modul-System | Import/Export, Bibliotheken |

### Bauen

```bash
# Aus dem Repo-Root (empfohlen):
make build          # erzeugt ./lyxc

# Direkt aus dem Compiler-Verzeichnis:
cd compiler && make build

# Debug-Build:
make debug          # erzeugt ./lyxc_debug

# End-to-End Tests:
make e2e
```

---

## Network Library (std.net)

Lyx includes a comprehensive network library with **17 protocol implementations**, all written in pure Lyx (no external dependencies except for TLS, SSH, and HTTPS which use system libraries via FFI).

### Supported Protocols

| Protocol | Type | Port | RFC | Module | Status |
|----------|------|------|-----|--------|--------|
| **TCP** | Stream | - | - | `std.net.socket` | ✅ |
| **UDP** | Datagram | - | - | `std.net.socket` | ✅ |
| **DNS** | UDP | 53 | RFC 1035 | `std.net.dns` | ✅ |
| **HTTP** | TCP | 80 | RFC 2616 | `std.net.http` | ✅ |
| **HTTPS** | TCP | 443 | RFC 2818 | `std.net.https` | ✅ |
| **TLS/SSL** | - | - | RFC 5246 | `std.net.tls` | ✅ |
| **SMTP** | TCP | 25/587 | RFC 5321 | `std.net.smtp` | ✅ |
| **IMAP** | TCP | 143/993 | RFC 3501 | `std.net.imap` | ✅ |
| **Telnet** | TCP | 23 | RFC 854 | `std.net.telnet` | ✅ |
| **NTP** | UDP | 123 | RFC 5905 | `std.net.ntp` | ✅ |
| **SNMP** | UDP | 161 | RFC 1157 | `std.net.snmp` | ✅ |
| **LDAP** | TCP | 389 | RFC 4511 | `std.net.ldap` | ✅ |
| **SSH** | TCP | 22 | RFC 4251 | `std.net.ssh` | ✅ |
| **BGP** | TCP | 179 | RFC 4271 | `std.net.bgp` | ✅ |
| **MQTT** | TCP | 1883 | MQTT 3.1.1 | `std.net.mqtt` | ✅ |
| **SIP** | UDP | 5060 | RFC 3261 | `std.net.sip` | ✅ |
| **QUIC** | UDP | 443 | RFC 9000 | `std.net.quic` | ⚠️ |
| **Whois** | TCP | 43 | RFC 3912 | `std.net.whois` | ✅ |

### Quick Examples

```lyx
// HTTP GET
import std.net.http;
var resp: HTTPResponse := HTTPGet("example.com", "/");
PrintStr(resp.bodyPtr);
HTTPResponseFree(resp);

// HTTPS (OpenSSL)
import std.net.https;
var resp: HTTPResponse := HTTPSGet("api.example.com", "/data");

// DNS
import std.net.dns;
var ip: int64 := GetHostByName("example.com");

// SMTP Email
import std.net.smtp;
var conn: SMTPConn := SMTPConnect("smtp.example.com", 587);
var email: SMTPEmail;
email.from := "sender@example.com";
email.to := "recipient@example.com";
email.subject := "Hello";
email.body := "Test from Lyx!";
SMTPSend(conn, email);
SMTPQuit(conn);

// IMAP Email
import std.net.imap;
var imap: IMAPConn := IMAPConnect("imap.example.com", 143);
IMAPLogin(imap, "user", "pass");
var mbox: IMAPMailbox := IMAPSelect(imap, "INBOX");
PrintInt(mbox.exists);
IMAPLogout(imap);

// NTP Time
import std.net.ntp;
var time: NTPTime := NTPGetTime("pool.ntp.org");
PrintInt(time.unixTime);

// MQTT Pub/Sub
import std.net.mqtt;
var mqtt: MQTTConn := MQTTConnect("broker.example.com", 1883, "client001");
MQTTSubscribe(mqtt, "sensor/#", 0);
MQTTPublishMsg(mqtt, "sensor/temp", "22.5", 4, 0);

// SNMP Network Management
import std.net.snmp;
var resp: SNMPResponse := SNMPGet("192.168.1.1", "public", oid, 9);

// LDAP Directory
import std.net.ldap;
var ldap: LDAPConn := LDAPConnect("ldap.example.com", 389);
LDAPBind(ldap, "cn=admin,dc=example,dc=com", "password");
LDAPSearch(ldap, "dc=example,dc=com", "(objectClass=*)", LDAP_SCOPE_SUBTREE);

// SSH Remote
import std.net.ssh;
var session: SSHSession := SSHSessionNew();
SSHConnect(session, "server.example.com", 22);
SSHAuth(session, "user", "pass");
var buf: int64 := SSHExecOutput(session, "ls -la\n", 4096);

// Telnet
import std.net.telnet;
var conn: TelnetConn := TelnetConnect("towel.blinkenlights.nl", 23);

// BGP Routing
import std.net.bgp;
var peer: BGPPeer := BGPConnect(BGPIPv4(192,168,1,1), 65001, 65000);
BGPWaitEstablished(peer);
BGPAdvertiseRoute(peer, BGPIPv4(10,0,0,0), 24, BGPIPv4(10,0,0,1));

// SIP VoIP
import std.net.sip;
var sip: SIPConn := SIPConnect("sip.example.com", 5060);
SIPRegister(sip, "alice", "secret", "example.com");

// Whois Domain Lookup
import std.net.whois;
var info: pchar := WhoisLookup("example.com");
PrintStr(info);
```

### Dependencies

| Module | External Dependency |
|--------|---------------------|
| Most protocols | None (pure syscall) |
| TLS/HTTPS | `libssl.so.3` (OpenSSL 3.x) |
| SSH | `libssh2.so.1` |

---

## Quick Start

```bash
# Build compiler
make build

# Compile and run Linux program (default target)
./lyxc examples/hello.lyx -o hello
./hello

# Cross-compile for different platforms
./lyxc examples/hello.lyx -o hello.exe --target=win64        # Windows
./lyxc examples/hello.lyx -o hello --target=macosx64         # macOS Intel
./lyxc examples/hello.lyx -o hello --target=macos-arm64      # macOS Apple Silicon
./lyxc examples/hello.lyx -o hello.elf --target=esp32        # ESP32
./lyxc examples/hello.lyx -o hello.rv --target=riscv         # RISC-V RV64GC

# Debug flags
./lyxc examples/hello.lyx --emit-asm      # Output IR as pseudo-assembler
./lyxc examples/hello.lyx --dump-relocs   # Show relocations and symbols
./lyxc examples/hello.lyx --no-opt         # Disable IR optimizations

# DO-178C Tool Qualification
./lyxc --version        # TOR-001: Version info
./lyxc --build-info     # TOR-002: Build identification
./lyxc --config         # TOR-003: Configuration dump
```

```
Hello Lyx
```

---

## Energy-Aware-Compiling

Lyx supports **Energy-Aware-Compiling** to generate energy-efficient machine code, controlled via CLI or function-level pragmas.

### CLI Option: `--target-energy=<1-5>`

```bash
# Compile with energy level 1 (battery-optimized, minimal power)
./lyxc program.lyx -o program --target-energy=1

# Compile with energy level 3 (balanced, default)
./lyxc program.lyx -o program --target-energy=3

# Compile with energy level 5 (maximum performance)
./lyxc program.lyx -o program --target-energy=5
```

#### Energy Levels

| Level | Name | Loop Unroll | Battery | SIMD | FPU | AVX2/AVX512 |
|-------|------|:-----------:|:-------:|:----:|:---:|:------------:|
| 1 | Minimal | 4× | ✅ | — | — | — |
| 2 | Low | 2× | ✅ | — | — | — |
| 3 | Medium | 1× | ✅ | ✅ | — | * |
| 4 | High | — | ✅ | ✅ | ✅ | * |
| 5 | Extreme | 8× | ✅ | ✅ | ✅ | * |

(* = only if CPU supports it)

### Function-Level Pragma: `@energy(level)`

You can override the global energy level for specific functions:

```lyx
// This function compiles with level 1 (battery-optimized)
@energy(1)
fn low_power_task(): int64 {
  var sum: int64 := 0;
  var i: int64 := 0;
  while i < 1000 {
    sum := sum + i;
    i := i + 1;
  }
  return sum;
}

// This function compiles with level 5 (maximum performance)
@energy(5)
fn compute_intensive(): int64 {
  var result: int64 := 0;
  // Heavy computation uses SIMD/FPU
  return result;
}

fn main(): int64 {
  // Uses global --target-energy level
  var x: int64 := low_power_task();
  var y: int64 := compute_intensive();
  return x + y;
}
```

### Energy Statistics

The compiler outputs detailed energy statistics after compilation:

```
=== Energy Statistics ===
Energy level:           3
CPU family:             1
Optimize for battery:   TRUE
Avoid SIMD:             TRUE
Avoid FPU:              FALSE
Cache locality:         TRUE
Register over memory:   TRUE

Total ALU operations:   42
Total FPU operations:    0
Total SIMD operations:   0
Total memory accesses:  17
Total branches:         8
Total syscalls:         3

Estimated energy units: 16955
Code size:              846 bytes
L1 cache footprint:    846 bytes
```

#### Statistics Explained

| Metric | Description |
|--------|-------------|
| `Total ALU operations` | Integer arithmetic (+, -, *, /, %, etc.) |
| `Total FPU operations` | Floating-point operations |
| `Total memory accesses` | Loads and stores |
| `Total branches` | Jumps, calls, returns |
| `Total syscalls` | System calls (read, write, exit, etc.) |
| `Estimated energy units` | Calculated sum of operation costs |
| `Code size` | Generated binary size in bytes |
| `L1 cache footprint` | Estimated L1 cache usage |

### How It Works

1. **Energy Model**: Each CPU has a cost table (Intel i7-10710U, AMD Ryzen 7-4700U, Intel Atom x5-Z8350)
2. **IR Annotation**: Every IR instruction gets an `EnergyCostHint` during lowering
3. **Tracking**: Backend counts operations per category during code generation
4. **Optimization** (future): Energy level affects instruction selection

### Use Cases

- **Embedded systems**: Use `--target-energy=1` for minimal power
- **Server applications**: Use `--target-energy=5` for maximum performance
- **Mixed workloads**: Use `@energy` pragma to optimize hot paths

---

## DO-178C Safety-Critical Features

Lyx supports **DO-178C DAL A/B/C** compliance for aerospace and safety-critical embedded systems.

### Safety Pragmas (v0.8.0)

Function-level safety annotations for DO-178C compliance can be applied in any combination before `fn`:

```lyx
// Full set of safety pragmas on one function
@dal(A) @critical @wcet(100) @stack_limit(512)
fn autopilot_update(): int64 {
  return 0;
}

// DAL-B with WCET budget
@dal(B) @wcet(1000)
fn fuel_monitor(): int64 { return 1; }

// Combined with @energy
@energy(3) @dal(C) @wcet(5000)
fn sensor_read(): int64 { return 42; }
```

| Pragma | Argument | Meaning |
|--------|----------|---------|
| `@dal(A)` | `A`, `B`, `C`, `D` | DO-178C Design Assurance Level |
| `@critical` | — | Safety-critical function marker |
| `@wcet(N)` | μs > 0 | Worst-Case Execution Time budget |
| `@stack_limit(N)` | Bytes > 0 | Maximum stack usage limit |

**Semantic rules:** `@critical`/`@wcet`/`@stack_limit` on `extern fn` → error.
`@dal(A)` without `@critical` → warning (DAL A implies critical).
Safety pragmas are stored in IR (`TIRFunction.SafetyPragmas`) for future WCET/stack-verification passes.

### Range Types (v0.8.2)

Integer types with inclusive value bounds for DO-178C bounds-correctness requirements:

```lyx
type Altitude = int64 range -1000..60000;   // meters above MSL
type Speed    = int64 range 0..300;          // knots
type Percent  = int64 range 0..100;

// Compile-time error (literal out of range):
var alt: Altitude := 70000;  // error: value 70000 is out of range [-1000..60000] for type Altitude

// Valid:
var alt: Altitude := 5000;   // OK

// Runtime check (non-constant value):
var spd: Speed := get_speed();  // panics at runtime if > 300
```

Any integer base type (`int8`–`int64`, `uint8`–`uint64`, `isize`, `usize`) can be used.
The bounds are inclusive on both ends. Violations in constant initializers are caught at compile time.
Non-constant values receive a runtime bounds check emitted as IR compare+branch+panic.

### Integrity Management (v0.9.0)

Unit-level integrity annotations for radiation-tolerant and safety-critical code (DO-178C, aerospace.pdf Section 2.5):

```lyx
// Software lockstep: redundant execution, check every 50 ms
@integrity(mode: software_lockstep, interval: 50)
unit flight.ctrl;

fn main(): int64 { return 0; }
```

```lyx
// Memory scrubbing: background CRC sweep every 100 ms
@integrity(mode: scrubbed, interval: 100)
unit nav.core;

fn main(): int64 { return 42; }
```

```lyx
// Hardware ECC: relies on hardware memory correction
@integrity(mode: hardware_ecc, interval: 250)
unit sensor.fusion;

fn main(): int64 { return 0; }
```

`@integrity` can also be placed on individual functions:

```lyx
@integrity(mode: scrubbed, interval: 100)
fn critical_update(): int64 { return 0; }
```

| Parameter | Values | Meaning |
|-----------|--------|---------|
| `mode` | `software_lockstep` | Redundant execution with result comparison |
| `mode` | `scrubbed` | Periodic background CRC memory sweep |
| `mode` | `hardware_ecc` | Relies on hardware ECC memory correction |
| `interval` | ms > 0 | Integrity check / scrub interval in milliseconds |

**Semantic rules:** `@integrity` on `extern fn` → error. `mode: scrubbed` without `interval` → warning.

**`.meta_safe` ELF section (aerospace.pdf Section 2.5.2):**
When `@integrity` is present on a `unit` declaration, the compiler emits a custom `.meta_safe` ELF section containing:

| Offset | Field | Description |
|--------|-------|-------------|
| 0..7 | `code_start_va` | Start VA of the code segment |
| 8..15 | `code_end_va` | End VA of the code segment |
| 16..19 | `mode` | 1=lockstep, 2=scrubbed, 3=hardware_ecc |
| 20..23 | `interval_ms` | Integrity interval in milliseconds |
| 24..31 | `recovery_ptr` | Recovery function pointer (0 = not set) |
| 32..8231 | triple CRC32 | Three identical CRC32 copies with 4096-byte separation |

Total section size: **8232 bytes** (0x2028). The triple CRC32 store provides radiation fault tolerance — a single-event upset corrupting one copy is detected by comparing all three.

Supported backends: **x86_64**, **ARM64**, **RISC-V**.

**VerifyIntegrity() Builtin (aerospace.pdf Section 2.5.3):**
The `VerifyIntegrity()` builtin performs a runtime TMR (Triple Modular Redundancy) majority-vote check:

```lyx
@integrity(mode: scrubbed, interval: 100)
unit;

fn main(): int64 {
  if (VerifyIntegrity()) {
    PrintStr("Integrity OK\n");
    return 0;
  } else {
    PrintStr("Integrity FAIL\n");
    return 1;
  }
}
```

The compiler embeds 3 identical CRC32 hashes of the code section into the data section.
At runtime, `VerifyIntegrity()` reads all 3 hashes and performs a majority vote:
if 2 or more agree, it returns `true`. This provides protection against single-event upsets (SEU) in memory.

**TMR Hash-Store (aerospace.pdf Section 2.5.2):**
The TMR hash store is embedded in the ELF data section with the following layout:

| Offset | Field | Description |
|--------|-------|-------------|
| 0..3 | `hash_copy_1` | CRC32-IEEE-802.3 of code section |
| 4..7 | `hash_copy_2` | CRC32-IEEE-802.3 of code section (redundant copy) |
| 8..11 | `hash_copy_3` | CRC32-IEEE-802.3 of code section (redundant copy) |
| 12..15 | `code_size` | Size of code section in bytes |
| 16..23 | `code_start_va` | Virtual address of code section start |

The `.meta_safe` section is marked with `SHF_ALLOC` so it is mapped into memory at runtime,
allowing `VerifyIntegrity()` to read the stored hashes.

**Endianness Annotations (aerospace.pdf Section 2.4):**
Structs can be annotated with `@big_endian` or `@little_endian` for telemetry data exchange between heterogeneous architectures:

```lyx
type TelemetryFrame = @big_endian struct {
  timestamp: int64;
  temperature: int16;
  status_flags: int8;
};
```

This marks the struct for explicit byte-order management when sending data from
a PowerPC (big-endian) to an x86 (little-endian) ground station, or vice versa.
The annotation is combinable with `@packed` for hardware register mapping.

### Tool Qualification (TQL-5)

The compiler is qualified as a **TQL-5 Development Tool** per DO-178C Section 12.2:

```bash
# Tool Operational Requirements
./lyxc --version        # TOR-001: Version (SemVer + TQL level)
./lyxc --build-info     # TOR-002: Build identification (hash, host, FPC version)
./lyxc --config         # TOR-003: Configuration dump (targets, architectures, features)
```

### MC/DC Coverage (DAL A)

Modified Condition/Decision Coverage instrumentation for DO-178C DAL A:

```bash
# Compile with MC/DC instrumentation
./lyxc program.lyx -o program --mcdc

# Generate coverage report
./lyxc program.lyx -o program --mcdc --mcdc-report
```

**Coverage Report:**
```
=== MC/DC Coverage Report ===
Total decisions: 3
Instrumented points: 5

Decision  | Function         | Line | T | F | Status
----------|------------------|------|---|---|--------
DEC-   0  | main             |    0 | ? | ? | PARTIAL
DEC-   1  | process_data     |    0 | ? | ? | PARTIAL
DEC-   0  | main             |    1 |  0   |       0 |       0 | GAP
  --> [GAP] Condition 0=TRUE: 0 hits
  --> [GAP] Condition 0=FALSE: 0 hits
  --> [GAP] Decision=TRUE: 0 hits
  --> [GAP] Decision=FALSE: 0 hits

=== Summary ===
Total decisions:    1
Fully covered:      0
With gaps:          1
MC/DC coverage:     0%
```

**Gap Detection:**
- Condition TRUE/FALSE hit tracking per decision
- Decision TRUE/FALSE hit tracking
- "Decision never executed" detection
- Atomic counter increments via `lock inc qword` for thread-safe runtime recording
```

### Deterministic Code Generation

Lyx guarantees **bit-for-bit reproducible builds**:

```bash
# Same source → identical binary (verified by hash)
./lyxc program.lyx -o build1.elf
./lyxc program.lyx -o build2.elf
# MD5(build1.elf) == MD5(build2.elf)
```

### Safety Backends

| Backend | Safety Features |
|---------|----------------|
| **ESP32/Xtensa** | Watchdog, Brownout, Flash-Verify, Secure Boot, MPU, Stack-Canary, Cache-Flush |
| **ARM Cortex-M** | MPU (8 regions), Fault-Handlers (HardFault/MemManage/BusFault), Stack-Canary, TrustZone stubs |
| **RISC-V RV64GC** | PMP (16 regions), Machine Mode, ECALL/EBREAK, CSR access, Fence/WFI |

### Reference Interpreter

A standalone reference interpreter validates compiler correctness via bisimulation:

```bash
# Run reference interpreter tests
cd compiler && ./tests/test_reference_interpreter
# 22/22 tests passed
```

### Static Analysis

Lyx includes a comprehensive static analysis pass for DO-178C compliance:

```bash
# Run static analysis during compilation
./lyxc program.lyx -o program --static-analysis
```

**Analysis Report:**
```
=== Static Analysis Report ===

--- Data-Flow Analysis (Def-Use Chains) ---
Total variables tracked: 10
  t0: defined at instr 19, used at 48 locations
  t1: defined at instr 3, used at 2 locations

--- Live Variable Analysis ---
  [WARN] t5: defined but never used

--- Constant Propagation ---
  t0 = 10 (known constant)
  t1 = 20 (known constant)
Known constants: 5/10

--- Null Pointer Analysis ---
  No pointer variables found.

--- Array Bounds Analysis ---
Safe: 0, Unverified: 0

--- Termination Analysis ---
  main: Terminates

--- Stack Usage Analysis ---
  Function              | Slots | Bytes | Recursive
  ----------------------|-------|-------|----------
  main                  |    13 |   104 | no

=== Warnings: 0 ===
```

**7 Analysis Passes:**
1. **Data-Flow Analysis**: Def-Use chains for all variables
2. **Live Variable Analysis**: Detects unused variables (warnings)
3. **Constant Propagation**: Tracks known constants through irAdd/irSub/irMul
4. **Null Pointer Analysis**: Tracks potentially null pointers and missing checks
5. **Array Bounds Analysis**: Static index safety verification
6. **Termination Analysis**: Detects unbounded loops and recursive calls
7. **Stack Usage Analysis**: Worst-case stack calculation per function

### Assembly Listing (DO-178C 6.1)

Lyx can generate a detailed assembly listing with source line annotations for audit and certification:

```bash
# Generate assembly listing alongside binary
./lyxc program.lyx -o program --asm-listing
```

**Example Output (`program.lst`):**
```
; ================================================
; Lyx Assembly Listing
; Generated by lyxc v0.7.0-aerospace
; DO-178C TQL-5 Qualified Compiler
; Architecture: x86_64
; ================================================

; -----------------------------------------------
; Function: main
; Locals: 3, Instructions: 10
; -----------------------------------------------

  ; program.lyx:3
         0  4D 8D 15 F9 FF FF FF 49  const_int t0, 10
  ; program.lyx:3
         8  89 22 48 83 EC 10 48 C7  store [local0], t0
  ; program.lyx:4
        10  C0 FF FF FF FF 48 89 04  const_int t1, 20
  ; program.lyx:5
        20  BE 03 00 00 00 48 89 E2  load t2, [local0]
  ; program.lyx:5
        28  45 31 D2 B8 2E 01 00 00  load t3, [local1]
  ; program.lyx:5
        30  0F 05 48 83 C4 10 48 8B  add t4, t2, t3
  ; program.lyx:6
        40  48 89 E5 E8 0F 00 00 00  load t5, [local2]
  ; program.lyx:6
        48  48 89 C7 48 B8 3C 00 00  ret t5
```

**Format:** `offset  hex_bytes  ir_mnemonic  ; source_file:line`

**Purpose:** Required for DO-178C DAL A/B/C certification — provides traceability from source code to generated machine code.

### DWARF Debug Info

Lyx can generate **DWARF 4 debug information** for integration with external debuggers (gdb, lldb, Visual Studio Code):

```bash
# Compile with DWARF debug info
./lyxc program.lyx -o program -g
```

**Generated Sections:**
```
  [ 2] .debug_str        STRTAB
  [ 3] .debug_abbrev     PROGBITS
  [ 4] .debug_info       PROGBITS
  [ 5] .debug_line       PROGBITS
  [ 6] .debug_frame      PROGBITS
```

**Debugging:**
```bash
# Inspect debug info
readelf -w program | head -50

# Debug with gdb
gdb ./program
(gdb) break test.lyx:5
(gdb) run
(gdb) print variable_name
```

**Purpose:** Source-level debugging in IDEs and debuggers, DO-178C traceability.

---

### Cross-Compilation

Lyx supports **cross-compilation** for multiple target platforms and architectures:

```bash
# Linux x86_64 ELF64 (default on Linux hosts)
./lyxc program.lyx -o program --target=linux

# Linux ARM64 ELF64 (for Raspberry Pi, Apple Silicon Linux, cloud servers)
./lyxc program.lyx -o program --target=arm64

# Windows PE32+ (from Linux)
./lyxc program.lyx -o program.exe --target=win64

# macOS x86_64 Mach-O (Intel Macs)
./lyxc program.lyx -o program --target=macosx64

# macOS ARM64 Mach-O (Apple Silicon Macs)
./lyxc program.lyx -o program --target=macos-arm64

# ESP32/Xtensa ELF32 (microcontroller)
./lyxc program.lyx -o program.elf --target=esp32

# RISC-V RV64GC ELF64
./lyxc program.lyx -o program.elf --target=riscv
```

#### Available Targets and Architectures

| Target Flag | Architecture | Object Format | Calling Convention | OS Interface | Status |
|-------------|--------------|---------------|-------------------|--------------|--------|
| `--target=linux` | x86_64 | ELF64 | SysV ABI (RDI, RSI, RDX, RCX, R8, R9) | Linux Syscalls | ✅ Stable |
| `--target=arm64` | ARM64 | ELF64 | AAPCS64 (X0-X7) | Linux Syscalls | ✅ Stable |
| `--target=win64` | x86_64 | PE32+ | Windows x64 (RCX, RDX, R8, R9 + Shadow) | kernel32.dll | ✅ Stable |
| `--target=macosx64` | x86_64 | Mach-O | SysV ABI (RDI, RSI, RDX, RCX, R8, R9) | BSD Syscalls | ✅ Stable |
| `--target=macos-arm64` | ARM64 | Mach-O | AAPCS64 (X0-X7) | BSD Syscalls | ✅ Stable |
| `--target=esp32` | Xtensa | ELF32 | Simplified SysV (A2-A7 params) | Syscalls | ⚠️ Experimental |
| `--target=riscv` | RV64GC | ELF64 | LP64D (A0-A7, FA0-FA7) | Linux Syscalls (ecall) | ✅ Stable |

#### Architecture Parameter

You can also explicitly specify the architecture using `--arch`:

```bash
# Default behavior (architecture inferred from target)
./lyxc program.lyx -o program --target=macos-arm64

# Explicit architecture specification
./lyxc program.lyx -o program --target=macosx64 --arch=x86_64
./lyxc program.lyx -o program --target=macos-arm64 --arch=arm64
./lyxc program.lyx -o program --target=esp32 --arch=xtensa
```

| Architecture Flag | Description |
|-------------------|-------------|
| `--arch=x86_64` | 64-bit x86 (Intel/AMD) |
| `--arch=arm64` | 64-bit ARM (Apple Silicon, Raspberry Pi 4+) |
| `--arch=xtensa` | Xtensa (ESP32 microcontroller) |
| `--arch=riscv` | RISC-V RV64GC (64-bit RISC) |

**Note:** The `--target` parameter is optional. The compiler automatically selects the host OS as the target. The `--arch` parameter is also optional - architecture is automatically inferred from the target.

#### CLI Help

```bash
./lyxc --help
```

```
Lyx Compiler v0.5.0
Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.

Verwendung: lyxc <datei.lyx> [-o <output>] [--target=TARGET] [--arch=ARCH]

Optionen:
  -o <datei>          Ausgabedatei (Standard: a.out bzw. a.exe)
  -I <pfad>         Include-Pfad für Module hinzufügen (mehrfach verwendbar)
  --std-path=PATH     Pfad zur Standardbibliothek überschreiben
  --target=TARGET    Zielplattform (win64, linux, arm64, macosx64, macos-arm64, esp32, riscv)
  --arch=ARCH       Architektur (x86_64, arm64, xtensa, riscv)
  --target-energy=<1-5>  Energy-Ziel setzen (1=Minimal, 5=Extreme)
  --emit-asm        IR als Pseudo-Assembler ausgeben
  --asm-listing    Assembly-Listing mit Source-Zeilen (DO-178C 6.1)
  --dump-relocs    Relocations und externe Symbole anzeigen
  --trace-imports Import-Auflösung debuggen
  --lint              Linter-Warnungen aktivieren
  --lint-only         Nur linten, nicht kompilieren
  --no-lint          Linter-Warnungen deaktivieren
  --no-opt           IR-Optimierungen deaktivieren (Standard: aktiv)
  --mcdc            MC/DC-Instrumentierung für DO-178C Coverage
  --mcdc-report     MC/DC-Coverage-Bericht nach Kompilierung
  --static-analysis   Statische Analyse (Data-Flow, Live-Vars, Stack, Null-Ptr)
  --call-graph     Statischer Aufrufgraph (WCET-Analyse, Rekursions-Erkennung)
  --map-file       Speicherlayout-Datei (.map) für Debug/Audit
  --runtime-checks  Runtime-Assertions (bounds, null, zero, boolean) für DO-178C
  -g               DWARF Debug Info für gdb/lldb/VS Code

TOR-Optionen (DO-178C Tool Qualification):
  --version        Versionsnummer ausgeben (TOR-001)
  --build-info     Build-Identifikation ausgeben (TOR-002)
  --config        Aktive Konfiguration ausgeben (TOR-003)
```

**Linter Rules (26 total):**

| Code | Rule | Description |
|------|------|-------------|
| W001 | `unused-variable` | Variable declared but never read |
| W002 | `unused-parameter` | Function parameter never read |
| W003 | `naming-variable` | Variable does not use camelCase |
| W004 | `naming-function` | Function does not use PascalCase |
| W005 | `naming-constant` | Constant does not use PascalCase or UPPER_CASE |
| W006 | `unreachable-code` | Code after `return` is unreachable |
| W007 | `empty-block` | Empty block `{ }` |
| W008 | `shadowed-variable` | Variable shadows an outer variable |
| W009 | `mutable-never-mutated` | `var` declared but never mutated — use `let` |
| W010 | `empty-function` | Non-void function has no `return` |
| W011 | `format-zero-decimals` | `:width:0` format specifier — use `PrintInt()` instead |
| W012 | `string-concat-literals` | `"a" + "b"` can be a single literal at compile time |
| W013 | `print-float-int-arg` | `PrintFloat(intLit as f64)` — use `PrintInt()` instead |
| W014 | `recursive-function` | Recursive function (for stack predictability — MISRA 5.2) |
| W015 | `implicit-type-cast` | Implicit type conversion without `as` (MISRA 5.2) |
| W016 | `dead-loop` | Infinite loop without exit condition / break |
| W017 | `pointer-arithmetic` | Pointer arithmetic (MISRA 5.2) |
| W018 | `incomplete-switch` | Switch without default or missing enum values (MISRA 5.2) |
| W019 | `function-too-long` | Function > 60 lines (MISRA 5.2) |
| W020 | `complex-function` | Cyclomatic complexity > 15 (MISRA 5.2) |
| W021 | `global-mutable` | `var` at module level (race conditions) |
| W022 | `todo-comment` | Find `// TODO` comments |
| W023 | `magic-number` | Hardcoded numbers (magic numbers) |
| W024 | `unbounded-loop` | While without limit() (WCET) |
| W025 | `resource-leak` | mmap without munmap (resource leak) |
| W026 | `unchecked-error` | Ignored error codes |

**Testing ARM64 binaries (on x86_64):**
```bash
# Install QEMU
sudo apt install qemu-user-static

# Run ARM64 binary
qemu-aarch64-static ./program
```

**Testing binaries on target platforms:**

| Platform | Testing Method |
|----------|----------------|
| Linux | Direct execution (`./program`) |
| Windows | Run via Wine or on Windows machine |
| macOS | Copy to Mac via SSH/SCP and execute |
| ESP32 | Flash to device and monitor via serial |
| RISC-V | Run via QEMU (`qemu-riscv64 ./program`) |

**Cross-compile for ESP32 (Xtensa):**
```bash
# Compile for ESP32 microcontroller
./lyxc examples/esp32_hello.lyx -o esp32_hello.elf --target=esp32

# Check ELF32 structure
readelf -h esp32_hello.elf
```

**Platform-Specific Details:**

| Platform | Architecture | Object Format | Register Set | ABI |
|----------|--------------|---------------|--------------|-----|
| **Linux x86_64** | x86_64 | ELF64 | RAX-R15 | SysV ABI (RDI, RSI, RDX, RCX, R8, R9) |
| **Linux ARM64** | ARM64 | ELF64 | X0-X30 | AAPCS64 (X0-X7) |
| **Windows x64** | x86_64 | PE32+ | RAX-R15 | Windows x64 (RCX, RDX, R8, R9 + Shadow Space) |
| **macOS x86_64** | x86_64 | Mach-O | RAX-R15 | SysV ABI (RDI, RSI, RDX, RCX, R8, R9) |
| **macOS ARM64** | ARM64 | Mach-O | X0-X30 | AAPCS64 (X0-X7) |
| **ESP32** | Xtensa | ELF32 | A0-A15 | Simplified SysV (A2-A7 params) |
| **RISC-V RV64GC** | RV64 | ELF64 | X0-X31, F0-F31 | LP64D (A0-A7, FA0-FA7) |

**ESP32 Built-in Syscalls:**
| Syscall | Number | Description |
|---------|--------|-------------|
| `SYS_EXIT` | 1 | Terminate program |
| `SYS_WRITE` | 4 | Write to STDOUT |
| `SYS_READ` | 3 | Read from STDIN |
| `SYS_GPIO_SET_MODE` | 100 | Configure GPIO pin |
| `SYS_GPIO_WRITE` | 101 | Write to GPIO |
| `SYS_GPIO_READ` | 102 | Read from GPIO |
| `SYS_UART_WRITE` | 200 | UART transmit |
| `SYS_UART_READ` | 201 | UART receive |
| `SYS_UART_CONFIG` | 202 | Configure UART |
| `SYS_GET_TIME` | 300 | Get timestamp |
| `SYS_DELAY_MS` | 301 | Delay in milliseconds |
| `SYS_RANDOM` | 302 | Generate random number |
| `SYS_RANDOM_SEED` | 303 | Set random seed |

**Cross-Platform Examples:**

macOS ARM64 (`examples/hello_macos_arm64.lyx`):
```lyx
fn main(): int64 {
  PrintStr("Hello from macOS ARM64 (Apple Silicon)!\n");
  return 0;
}
```

ESP32 (`examples/esp32_hello.lyx`):
```lyx
fn main(): int64 {
  PrintStr("Hello from ESP32!\n");
  return 0;
}
```

---

###

## The Lyx Language

Lyx is **procedural** and **statically typed** — inspired by C and Rust, with its own compact syntax.

### Hello World

```lyx
fn main(): int64 {
  PrintStr("Hello Lyx\n");
  return 0;
}
```

### Variables and Arithmetic

Four storage classes control mutability and lifetime:

```lyx
fn main(): int64 {
  var x: int64 := 10;       // mutable
  let y: int64 := 20;       // immutable after init
  co  z: int64 := x + y;    // readonly (runtime constant)

  x := x + 1;               // allowed: var is mutable
  // y := 0;                 // forbidden: let is immutable

  PrintInt(x + y + z);
  PrintStr("\n");
  return 0;
}
```

| Keyword | Mutable | Compile-time | Storage |
|---------|:--------:|:------------:|---------|
| `var`   | yes      | —            | Stack/Data (global) |
| `let`   | no       | —            | Stack/Data (global) |
| `co`    | no       | optional     | Stack    |
| `con`   | no       | yes          | Immediate / rodata |

### Global Variables

`var` and `let` can also be declared at the top level. These are stored in the data segment and are globally visible:

```lyx
var globalCounter: int64 := 0;
let maxSize: int64 := 1024;

fn increment() {
  globalCounter := globalCounter + 1;
}

fn main(): int64 {
  PrintInt(globalCounter);  // 0
  increment();
  increment();
  PrintInt(globalCounter);  // 2
  return 0;
}
```

Global variables:
- are stored in the data segment (not on the stack)
- can be initialized with constant integer values
- are visible in all functions
- can be marked `pub` for export

### Compile-Time Constants

`con` declarations exist at the top level and are resolved at compile time — no stack slot, directly embedded as immediate:

```lyx
con LIMIT: int64 := 5;
con MSG: pchar := "Loop\n";

fn main(): int64 {
  var i: int64 := 0;
  while (i < LIMIT) {
    PrintStr(MSG);
    i := i + 1;
  }
  return 0;
}
```

```
Loop
Loop
Loop
Loop
Loop
```

### Module System and Standard Library

Lyx supports a complete **import/export system** for organizing code into reusable modules:

```lyx
// std/math.lyx
pub fn Abs64(x: int64): int64 {
  if (x < 0) {
    return -x;
  }
  return x;
}

pub fn TimesTwo(x: int64): int64 {
  return x * 2;
}
```

```lyx
// main.lyx
import std.math;

fn main(): int64 {
  let result: int64 := Abs64(-42);
  PrintInt(TimesTwo(result));  // Output: 84
  return 0;
}
```

#### Module Resolution

The compiler resolves imports in the following order:

| Priority | Search Location | Description |
|----------|----------------|-------------|
| 1 | Relative to importing file | Local modules in the same directory |
| 2 | Project root | Working directory where compiler was invoked |
| 3 | `-I` include paths | Custom paths specified via `-I` flag |
| 4 | Standard library | System path (`./std/` or `/usr/lib/lyx/std/`) |

**Reserved `std` Namespace:**

Imports starting with `std.` are special: they skip local resolution and go directly to the standard library. This prevents accidental shadowing of standard modules:

```lyx
// Always loads from standard library, never local files
import std.math;
import std.io;
import std.string;
```

#### Include Paths (`-I`)

Use `-I` to add custom search paths for modules:

```bash
# Add external library path
./lyxc main.lyx -o main -I /path/to/mylib -I /path/to/otherlib

# Multiple -I flags are searched in order
./lyxc main.lyx -I ./vendor -I ./lib
```

#### Debugging Import Resolution (`--trace-imports`)

Use `--trace-imports` to debug module resolution issues:

```bash
./lyxc main.lyx --trace-imports
```

Output:
```
[TRACE] Resolving 'myhelper'...
[TRACE]   -> Trying: ./myhelper.lyx ... NOT FOUND
[TRACE]   -> Trying: /project/myhelper.lyx ... NOT FOUND
[TRACE]   -> Trying: /usr/lib/lyx/std/myhelper.lyx ... NOT FOUND
[TRACE]   -> Module NOT FOUND in any search path!

[TRACE] Resolving 'std.io'...
[TRACE]   Reserved prefix 'std' detected. Jumping to STD_PATH.
[TRACE]   -> Trying: /usr/lib/lyx/std/io.lyx ... FOUND!
```

#### Standard Library Path

The compiler searches for the standard library in this order:

1. `LYX_STD_PATH` environment variable
2. Relative to compiler binary: `../std/`
3. System path: `/usr/lib/lyx/std/`
4. Fallback: `./std/`

Override with `--std-path`:

```bash
./lyxc main.lyx --std-path=/custom/path/to/std
```

### Precompiled Units (`.lyu`)

Lyx unterstützt vorkompilierte Units (`.lyu`) für schnellere Kompilierung:

```bash
# Eine .lyx Datei zu .lyu kompilieren
./lyxc mymodule.lyx --compile-unit -o mymodule.lyu

# Kompilieren mit .lyu (wird autom. bevorzugt wenn vorhanden)
./lyxc main.lyx -o main --target=x86_64
```

Die `.lyu` Datei enthält:
- Exportierte `pub fn` Symbole mit Typ-Informationen
- Target-Architektur (x86_64, arm64)
- Versionsinformation

Falls die `.lyu` defekt ist, wird automatisch auf die `.lyx` Quelle zurückgegriffen.

```bash
./lyxc main.lyx --std-path=/custom/path/to/std
```

**Available Standard Library (52 units):**

Core:
- `std.system`: Builtins, Start/Exit, Panic
- `std.env`: Environment API (`ArgCount`, `Arg`)
- `std.os`: OS-level syscalls (`exit`, `sleep`, get/set environment variables)
- `std.process`: Process management (fork, exec, wait)

I/O:
- `std.io`: I/O functions (`print`, `PrintLn`, `PrintIntLn`, `exit(code)`)
- `std.fs`: Filesystem operations (open, read, write, close, exists, stat)
- `std.crt`: ANSI Terminal (colors, cursor control)
- `std.crt_raw`: Raw terminal mode

Math & Numerics:
- `std.math`: Math functions (`Abs64`, `Min64`, `Max64`, `Sqrt64`, `Clamp64`, `Sin64`, `Cos64`, `Hypot64`, etc.)
- `std.vector`: 2D Vector (`Vec2`)
- `std.vector_batch`: SIMD vector operations
- `std.math_batch`: SIMD math operations
- `std.stats`: Statistics (mean, variance, stddev)
- `std.stats_batch`: Batch statistics
- `std.geo`: Geolocation (Decimal Degrees, GeoPoint, Distance, BoundingBox)
- `std.conv`: Type conversion (int/float to string)
- `std.rect`: Rectangle utilities
- `std.circle`: Circle utilities
- `std.sort`: Sorting algorithms

Strings & Text:
- `std.string`: String manipulation (`StrLength`, `StrCharAt`, `StrFind`, `StrConcat`, etc.)
- `std.regex`: Regex matching
- `std.base64`: Base64 encoding/decoding
- `std.url`: URL parsing/encoding
- `std.html`: HTML utilities
- `std.xml`: XML parsing
- `std.yaml`: YAML parsing
- `std.json`: JSON parsing
- `std.uuid`: UUID generation
- `std.ini`: INI file parsing

Data Structures:
- `std.list`: Collections (`StaticList8`, `StackInt64`, `QueueInt64`, `RingBufferVec2`)
- `std.hash`: Hash map implementation
- `std.pack`: Binary serialization (VarInt, int/float/string packing)
- `std.buffer`: Binary buffer operations
- `std.alloc`: Custom memory allocator

Time & Date:
- `std.time`: Date/time functions
- `std.datetime`: DateTime with timezone

Networking:
- (future: `std.net`, `std.http`)

GUI & Graphics:
- `std.color`: RGBA Color utilities
- `std.x11`: X11 windowing
- `std.qt5_core`: Qt5 Core
- `std.qt5_gl`: Qt5 OpenGL
- `std.qt5_glx`: Qt5 GLX
- `std.qt5_egl`: Qt5 EGL
- `std.qt5_app`: Qt5 Application
- `std.lfd_parser`: LFD parser
- `std.lfd_factory`: LFD factory

Audio:
- `std.audio`: Audio I/O

Compression:
- `std.zlib`: zlib compression

Utilities:
- `std.log`: Logging
- `std.regex`: Regex
- `std.country`: Country codes
- `std.qbool`: Probabilistic Boolean (`QBool`, `Maybe()`, `Observe()`)
- `std.error`: Error handling
- `std.result`: Result/Either monad

Database (std.db):
- `std.db.mysql`: MySQL database client
- `std.db.redis`: Redis client
- `std.db.redis_simple`: Simplified Redis client

Crypto:
- `std.crypto.aes`: AES encryption
- `std.crypto.sha1`: SHA-1 hashing

Math:
- `std.math.constants`: Mathematical constants (PI, E, etc.)

Audio:
- `std.audio.alsa`: ALSA audio
- `std.audio.playback`: Audio playback
- `std.audio.mpg123`: MP3 playback

Networking:
- `std.net.socket`: BSD socket API
- `std.net.http`: HTTP client/server
- `std.net.https`: HTTPS (TLS)
- `std.net.tls`: TLS/SSL
- `std.net.dns`: DNS
- `std.net.ntp`: NTP client
- `std.net.ssh`: SSH client
- `std.net.smtp`: Email sending
- `std.net.imap`: Email receiving
- `std.net.mqtt`: MQTT (IoT messaging)
- `std.net.quic`: QUIC/HTTP3
- `std.net.bgp`: BGP routing
- `std.net.sip`: VoIP/SIP
- `std.net.whois`: WHOIS queries
- `std.net.ldap`: LDAP client
- `std.net.snmp`: SNMP monitoring
- `std.net.asn1`: ASN.1 parsing

Validation:
- `std.validate.vat`: VAT ID validation
- `std.validate.luhn`: Luhn checksum (credit cards)
- `std.validate.isbn`: ISBN validation
- `std.validate.iban`: IBAN validation
- `std.validate.ean`: EAN barcode validation

Other:
- `std.unit_ioctl`: Device I/O control

### Types

| Type       | Description                          |
|-----------|---------------------------------------|
| `int64`   | Signed 64-bit Integer                 |
| `int`     | Alias for `int64` (convention)        |
| `f32`     | 32-bit Floating-Point (IEEE 754)      |
| `f64`     | 64-bit Floating-Point (IEEE 754)     |
| `bool`    | `true` / `false`                     |
| `void`    | Only as function return type          |
| `pchar`   | Pointer to null-terminated bytes      |
| `string`  | Alias for `pchar` (null-terminated bytes)
| `array`   | Dynamic array (Heap, Fat-Pointer: ptr, len, cap) |
| `parallel Array<T>` | SIMD-optimized array (Heap, element-wise operations) |
| `struct`  | User-defined record type             |
| `QBool`   | Probabilistic boolean (0.0 to 1.0 probability) |
| `Map<K,V>` | Associative array (key-value pairs) |
| `Set<T>`  | Unordered collection of unique values |

Note: `int` and `string` are currently alias types (shortcuts) — `int` is internally treated as `int64`, `string` is mapped to `pchar`. No implicit casts — all types must match explicitly.

### Float Literals

Float literals are written with a decimal point and are of type `f64`:

```lyx
fn main(): int64 {
  var pi: f64 := 3.14159;
  var e: f64 := 2.71828;

  // Float constants at top level
  con PI: f64 := 3.1415926535;

  return 0;
}
```

### Dynamic Arrays

Lyx supports dynamic arrays, which are allocated on the heap and managed via a fat pointer (ptr, len, cap). They are resizable and can be manipulated with builtins like `push`, `pop`, `len`, and `free`.

```lyx
fn main(): int64 {
  // Dynamic array literal (heap-allocated)
  var dyn_arr: array := [10, 20, 30]; // ptr, len=3, cap=3

  PrintInt(len(dyn_arr)); // Output: 3
  PrintStr("\n");

  // Add and remove elements
  push(dyn_arr, 40);      // dyn_arr is now [10, 20, 30, 40]
  push(dyn_arr, 50);      // dyn_arr is now [10, 20, 30, 40, 50]
  var last: int64 := pop(dyn_arr); // last = 50, dyn_arr is [10, 20, 30, 40]

  PrintInt(len(dyn_arr)); // Output: 4
  PrintStr("\n");
  PrintInt(dyn_arr[0]);   // Output: 10
  PrintStr("\n");
  PrintInt(dyn_arr[3]);   // Output: 40
  PrintStr("\n");

  // Assign element
  dyn_arr[0] := 100;

  // Free memory (explicitly or at function end)
  free(dyn_arr);
  // Warning: After free, dyn_arr is invalid!
  return 0;
}
```

**Important properties:**
- **Heap Allocation**: Arrays are allocated with `mmap` on the heap and grow as needed.
- **Fat Pointer**: Internally represented as `{ pchar ptr, int64 len, int64 cap }`.
- **Builtins**: Special functions for manipulation: `push(arr, val)`, `pop(arr)`, `len(arr)`, `free(arr)`.
- **Type Homogeneity**: All elements of an array must have the same type (currently `int64`).
- **Bounds Checks**: Automatic runtime check on every index access.

### ParallelArray (SIMD)

ParallelArrays are SIMD-optimized, heap-allocated arrays that support element-wise operations:

```lyx
fn main(): int64 {
  // Create ParallelArray (1000 elements of type Int64)
  var vec: parallel Array<Int64> := parallel Array<Int64>(1000);

  // Read and write individual elements
  vec[0] := 42;
  var first: int64 := vec[0];   // 42

  // Element-wise SIMD operations
  var a: parallel Array<Int64> := parallel Array<Int64>(100);
  var b: parallel Array<Int64> := parallel Array<Int64>(100);
  var sum: parallel Array<Int64> := a + b;   // element-wise addition
  var diff: parallel Array<Int64> := a - b;  // element-wise subtraction

  return 0;
}
```

**Important properties:**
- **Heap Allocation**: Arrays are allocated with `mmap` on the heap (16-byte alignment for SSE2)
- **Element Types**: `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `F32`, `F64`
- **SIMD Operators**: `+`, `-`, `*`, `/`, `&&`, `||`, `^` and comparison operators (element-wise)
- **Scalar Access**: `vec[i]` returns a single scalar value of the element type

### QBool - Probabilistic Boolean Type

QBool is a probabilistic boolean type for quantum-like computing and uncertain reasoning. It stores a probability value between 0.0 (definitely false) and 1.0 (definitely true).

```lyx
import std.qbool;

fn main(): int64 {
  // Create uncertain values with Maybe()
  var is_rainy: QBool := Maybe(0.7);  // 70% chance of rain
  var is_cold: QBool := Maybe(0.4);   // 40% chance of cold
  
  // Probabilistic logical operators
  var will_stay_home: QBool := QBoolAnd(is_rainy, is_cold);
  
  // Observe - collapse to classical bool (random based on probability)
  var decision: bool := Observe(will_stay_home);
  
  // AI decision tree example
  var diagnosis: bool := Diagnose(0.8, 0.6, 0.7);
  
  return 0;
}
```

**Core Features:**
- `Maybe(probability)` - Creates a QBool with given probability (0.0 to 1.0)
- `Observe(q)` - Collapses quantum state to classical bool using random
- Deterministic borders: `Maybe(1.0)` = true, `Maybe(0.0)` = false

**Logical Operators (Probabilistic Algebra):**
- `QBoolAnd(a, b)`: P(A ∧ B) = P(A) × P(B)
- `QBoolOr(a, b)`: P(A ∨ B) = P(A) + P(B) - P(A) × P(B)
- `QBoolNot(a)`: P(¬A) = 1.0 - P(A)

**Advanced:**
- `EntangledPair` - Correlated QBool pairs (observing one affects the other)
- AI examples: Weather prediction, Medical diagnosis, Game AI decisions

### Associative Arrays (Maps and Sets)

Lyx supports associative data structures for key-value storage and unique collections. Both are heap-allocated and use linear search (O(n) lookup).

#### Maps

Maps store key-value pairs with unique keys:

```lyx
fn main(): int64 {
  // Map literal with key:value pairs
  var scores: Map<int64, int64> := {1: 100, 2: 200, 3: 300};
  
  // Index access (get value by key)
  var score: int64 := scores[1];   // 100
  PrintInt(score);
  PrintStr("\n");
  
  // Index assignment (insert or update)
  scores[4] := 400;                // Insert new key
  scores[1] := 150;                // Update existing key
  
  // Check if key exists
  if (1 in scores) {
    PrintStr("Key 1 exists\n");
  }
  
  // Get length
  PrintInt(len(scores));           // 4
  
  return 0;
}
```

#### Sets

Sets store unique values without duplicates:

```lyx
fn main(): int64 {
  // Set literal with values
  var ids: Set<int64> := {10, 20, 30};
  
  // Check membership
  if (20 in ids) {
    PrintStr("20 is in the set\n");
  }
  
  // Get length
  PrintInt(len(ids));              // 3
  
  return 0;
}
```

**Implementation details:**
- **Storage**: Heap-allocated with format `[len:8][cap:8][entries:16*cap]`
- **Lookup**: Linear search O(n) — suitable for small collections
- **Key types**: `int64`, `bool` (currently)
- **Supported operations**: Literal creation, index get/set (Map), `in` operator, `len()`

### Logging (`std.log`)

Lyx includes a simple logging module for debugging and diagnostics:

```lyx
import std.log;

fn main(): int64 {
  // Log messages with different levels
  log_debug("Debug information");
  log_info("General information");
  log_warn("Warning message");
  log_error("Error occurred");
  
  // Get log level (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR, 4=FATAL)
  var level: int64 := get_log_level();
  
  // Conditional logging
  log_debug_if(true, "This will be logged");
  log_debug_if(false, "This will NOT be logged");
  
  // Level to string
  var level_str: pchar := log_level_to_string(1);  // "INFO"
  
  // App lifecycle helpers
  log_app_start("MyApp");
  log_app_end(0);
  
  return 0;
}
```

**Functions:**
- `get_log_level()` / `set_log_level(level)` - Control minimum log level
- `log_level_to_string(level)` - Convert level to string
- `log_debug(msg)`, `log_info(msg)`, `log_warn(msg)`, `log_error(msg)`, `log_fatal(msg)`
- `log_debug_if(cond, msg)`, etc. - Conditional logging
- `log_section_enter(name)`, `log_section_exit(name)` - Section tracking
- `log_app_start(name)`, `log_app_end(code)` - Application lifecycle

### OS / System (`std.os`)

The OS module provides system-level functionality:

```lyx
import std.os;

fn main(): int64 {
  // Process information
  var pid: int64 := get_pid();
  PrintInt(pid);
  
  // Environment variables
  var home: pchar := env_get("HOME");
  env_set("MY_VAR", "value");
  var exists: bool := env_has("PATH");
  
  // Time functions
  var t: int64 := time();           // Unix timestamp (seconds)
  var t_ms: int64 := time_ms();     // Milliseconds
  
  // Sleep (milliseconds)
  sleep(100);  // 100ms
  
  // System information
  var os_name: pchar := get_os_name();   // "Linux"
  var arch: pchar := get_arch();         // "x86_64"
  
  // File system
  var exists: bool := path_exists("/tmp");
  
  // Path utilities
  var filename: pchar := path_filename("/path/to/file.txt");  // "file.txt"
  var is_abs: bool := path_is_absolute("/home/user");        // true
  
  return 0;
}
```

**Functions:**
- **Process**: `get_pid()`, `get_uid()`, `get_ppid()`
- **Environment**: `env_get(key)`, `env_set(key, val)`, `env_unset(key)`, `env_has(key)`
- **Time**: `time()`, `time_ms()`, `time_us()`
- **Sleep**: `sleep(ms)`, `sleep_seconds(s)`, `sleep_microseconds(us)`
- **System**: `get_os_name()`, `get_os_version()`, `get_arch()`, `get_page_size()`, `get_num_cores()`
- **Files**: `path_exists(path)`, `is_directory(path)`, `is_file(path)`
- **Paths**: `path_filename(path)`, `path_dirname(path)`, `path_is_absolute(path)`
- **User**: `get_home_dir()`, `get_temp_dir()`, `get_user_name()`

### Structs (Records)

Structs are defined with `type Name = struct { ... };` and instantiated with `TypeName { field: value, ... }`:

```lyx
type Point = struct {
  x: int64;
  y: int64;
};

type Rect = struct {
  left: int64;
  top: int64;
  right: int64;
  bottom: int64;
};

fn main(): int64 {
  // Struct literal with field initialization
  var p: Point := Point { x: 10, y: 20 };

  // Field access with dot notation
  PrintInt(p.x);        // 10
  PrintInt(p.y);        // 20

  // Field assignment
  p.x := 42;
  PrintInt(p.x);        // 42

  // Structs in expressions
  var sum: int64 := p.x + p.y;  // 62

  // Larger structs
  var r: Rect := Rect { left: 0, top: 0, right: 100, bottom: 50 };
  var width: int64 := r.right - r.left;   // 100

  return 0;
}
```

Structs are allocated on the stack (8 bytes per field). Access is done directly via offset calculation.

#### Instance Methods and `self`

Structs can contain methods that access the instance via `self`:

```lyx
type Counter = struct {
  count: int64;
  
  fn increment(): int64 {
    self.count := self.count + 1;
    return self.count;
  }
  
  fn get(): int64 {
    return self.count;
  }
};

fn main(): int64 {
  var c: Counter := 0;
  c.count := 10;
  c.increment();     // count is now 11
  return c.get();    // returns 11
}
```

**Important:**
- `self` is automatically available in instance methods
- `self` is a pointer to the struct instance
- Methods are internally mangled as `_L_<Struct>_<Method>(self, ...)`

#### Static Methods with `static`

Static methods have no `self` parameter and are called with `Type.method()`:

```lyx
type Math = struct {
  dummy: int64;   // placeholder field
  
  static fn add(a: int64, b: int64): int64 {
    return a + b;
  }
  
  static fn mul(a: int64, b: int64): int64 {
    return a * b;
  }
};

fn main(): int64 {
  var sum: int64 := Math.add(30, 12);   // 42
  var prod: int64 := Math.mul(6, 7);    // 42
  return sum;
}
```

**Static methods:**
- Are declared with `static fn`
- Have no implicit `self` parameter
- Are called with `TypeName.method()`
- Useful for utility functions and "constructors"

#### The `Self` Type

In methods, `Self` can be used as a return type (resolves to the struct type):

```lyx
type Point = struct {
  x: int64;
  y: int64;
  
  static fn origin(): Self {
    return Point { x: 0, y: 0 };
  }
};
```

**Note:** Struct return by value is still limited. Currently, static methods can return primitive types, but not structs.

### Classes (OOP) with Inheritance

Lyx supports OOP with classes, inheritance, constructors, destructors, and **Virtual Method Tables (VMT)** for polymorphism:

```lyx
type Animal = class {
  name: pchar;
  
  fn speak() {
    PrintStr("Some sound\n");
  }
};

type Dog = class extends Animal {
  breed: pchar;
  
  fn speak() {
    PrintStr("Woof!\n");
  }
  
  fn Create(n: pchar, b: pchar) {
    self.name := n;
    self.breed := b;
  }
  
  fn Destroy() {
    PrintStr("Dog destroyed\n");
  }
};

fn main(): int64 {
  var d: Dog := new Dog("Buddy", "Labrador");
  d.speak();              // "Woof!"
  dispose d;              // Calls Destroy()
  return 0;
}
```

#### Virtual Methods and VMT (Polymorphism)

Use `virtual` to declare methods that can be overridden, and `override` to override base class methods:

```lyx
type TBase = class {
  val: int64;
  
  // Virtual method - can be overridden by derived classes
  virtual fn GetValue(): int64 {
    return self.val;
  }
};

type TDerived = class extends TBase {
  extra: int64;
  
  // Override the virtual method from base class
  override fn GetValue(): int64 {
    return self.val + self.extra;
  }
};

fn main(): int64 {
  var base: TBase := new TBase();
  base.val := 10;
  
  var derived: TDerived := new TDerived();
  derived.val := 20;
  derived.extra := 30;
  
  // Polymorphic call via VMT
  PrintStr("Base.GetValue(): ");
  PrintInt(base.GetValue());    // Calls TBase.GetValue() -> 10
  PrintStr("\n");
  
  PrintStr("Derived.GetValue(): ");
  PrintInt(derived.GetValue()); // Calls TDerived.GetValue() -> 50
  PrintStr("\n");
  
  dispose base;
  dispose derived;
  return 0;
}
```

**Class features:**
- `class extends BaseClass` for inheritance
- `new ClassName()` for heap allocation
- `new ClassName(args)` calls constructor `Create`
- `dispose expr` calls `Destroy()` and frees memory
- `super.method()` for calling base class methods
- `virtual fn` declares a virtual method with VMT entry
- `override fn` overrides a virtual method from base class
- Heap-allocated (vs. stack-allocated structs)

### Operators

| Priority | Operators           | Description              |
|:--------:|---------------------|-------------------------|
| 1 (low) | `\|>`            | Pipe (function chaining) |
| 2         | `\|\|`            | Logical Or              |
| 3         | `&&`               | Logical And             |
| 4         | `==` `!=` `<` `<=` `>` `>=` | Comparison (returns `bool`) |
| 5         | `+` `-`            | Addition, Subtraction  |
| 6         | `*` `/` `%`        | Multiplication, Division, Modulo |
| 7 (high) | `!` `-` (unary)   | Logical NOT, Negation  |
| 8         | `as`               | Type-Casting            |

Assignment uses `:=` (not `=`).

### Increment and Decrement Operators

The `++` and `--` operators are available as **postfix statements**:

```lyx
var counter: int64 := 0;

fn main(): int64 {
  counter++;        // counter := counter + 1
  counter++;        // counter := counter + 1
  counter--;        // counter := counter - 1
  
  PrintInt(counter);  // 1
  return 0;
}
```

**Supported forms:**
- `ident++` / `ident--` - increment/decrement variable
- `obj.field++` / `obj.field--` - increment/decrement field
- `arr[idx]++` / `arr[idx]--` - increment/decrement array element

**Note:** These are statement forms (not expressions). They do not return a value.

### Pipe Operator `|>`

The pipe operator enables chaining functions in data flow order (left to right):

```lyx
fn double(x: int64): int64 { return x * 2; }
fn addOne(x: int64): int64 { return x + 1; }

fn main(): int64 {
  var x: int64 := 5;
  
  // New: Pipe operator (readable left to right)
  var result: int64 := x |> double() |> addOne();
  
  // Equivalent to classic notation:
  // var result: int64 := addOne(double(x));
  
  PrintInt(result);  // 11
  return 0;
}
```

**With additional arguments:**

```lyx
fn add(a: int64, b: int64): int64 { return a + b; }

fn main(): int64 {
  var x: int64 := 10;
  
  // x is inserted as the first argument
  var result: int64 := x |> add(5);  // equivalent to add(x, 5)
  
  PrintInt(result);  // 15
  return 0;
}
```

**Benefits:**
- Better readability: code reads like data flow
- Avoids deep nesting
- Simpler debugging through clear order

### Type-Casting with `as`

Lyx supports explicit type casts with the `as` syntax:

```lyx
fn main(): int64 {
  var x: int64 := 42;
  var f: f64 := x as f64;      // int64 -> f64 conversion
  var back: int64 := f as int64; // f64 -> int64 conversion
  
  // String conversions
  var s: pchar := IntToStr(x);
  var parsed: int64 := str_to_int(s);
  
  PrintInt(parsed);  // 42
  return 0;
}
```

**Supported casts:**
- `int64 as f64`: Integer to Float (SSE2 cvtsi2sd)
- `f64 as int64`: Float to Integer with Truncation (SSE2 cvttsd2si)
- Identity Casts: `int64 as int64`, `f64 as f64`
- String conversions via builtin functions

### Control Flow

#### if / else

```lyx
fn main(): int64 {
  var x: int64 := 42;
  if (x > 10) {
    PrintStr("greater\n");
  } else {
    PrintStr("smaller\n");
  }
  return 0;
}
```

#### while loop

```lyx
fn main(): int64 {
  var i: int64 := 0;
  while (i < 5) {
    PrintInt(i);
    PrintStr("\n");
    i := i + 1;
  }
  return 0;
}
```

```
0
1
2
3
4
```

#### Bool expressions as condition

```lyx
fn main(): int64 {
  var active: bool := true;
  if (active)
    PrintStr("active\n");
  return 0;
}
```

#### switch / case

switch/case has been added and now supports both block bodies and single statements per case. `break` terminates the nearest loop or current switch case.

Example (block bodies):

```lyx
fn classify(x: int64): int64 {
  switch (x % 3) {
    case 0: {
      PrintStr("divisible by 3\n");
      return 0;
    }
    case 1: {
      PrintStr("remainder 1\n");
      return 1;
    }
    default: {
      PrintStr("other\n");
      return 2;
    }
  }
}
```

Example (single-statement bodies):

```lyx
switch (n) {
  case 0: PrintStr("zero\n");
  case 1: PrintStr("one\n");
  default: PrintStr("many\n");
}
```

Note: `case` labels must currently be integers (int/int64); semantics and codegen treat `int` as 64-bit.

### Functions

Functions are global, follow the SysV ABI (parameters in registers), and support up to 6 parameters:

```lyx
fn add(a: int64, b: int64): int64 {
  return a + b;
}

fn main(): int64 {
  var x: int64 := add(2, 3);
  PrintInt(x);
  PrintStr("\n");
  return 0;
}
```

```
5
```

Functions without return type are implicitly `void`:

```lyx
fn greet() {
  PrintStr("Hello!\n");
}

fn main(): int64 {
  greet();
  return 0;
}
```

### Builtins

Over 30 built-in functions are available without import:

#### Basic I/O Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `PrintStr(s)`    | `pchar -> void`        | Outputs string until `\0`           |
| `PrintInt(x)`    | `int64 -> void`        | Outputs integer as decimal          |
| `PrintFloat(x)`  | `f64 -> void`          | Outputs float with sign, integer part, and 6 decimal digits |
| `exit(code)`      | `int64 -> void`        | Terminates program with exit code   |

#### Debugging: In-Situ Data Visualizer

The `Inspect()` builtin provides runtime debugging output for variables directly to stderr:

```lyx
fn main(): int64 {
  var count: int64 := 42;
  var isActive: bool := true;
  var message: pchar := "Hello, Debug!";
  
  Inspect(count);      // Outputs type and value to stderr
  Inspect(isActive);
  Inspect(message);
  
  return 0;
}
```

Output (on stderr):
```
=== count ===
Type: int64
Value: 42
=== isActive ===
Type: bool
Value: true
=== message ===
Type: pchar
Value: Hello, Debug!
```

**Supported types:**
- `int64`, `int32`, `int16`, `int8` (signed integers)
- `uint64`, `uint32`, `uint16`, `uint8` (unsigned integers)
- `bool` (outputs "true" or "false")
- `pchar` (outputs string content)
- `f32`, `f64` (floating-point, basic support)

**Features:**
- Output goes to stderr (file descriptor 2), not stdout
- Variable name is automatically extracted and displayed
- Type information is shown for each inspected value
- No imports required - available as builtin

#### Random Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `Random()`        | `void -> int64`        | Returns pseudo-random number (0..2³¹-1) |
| `RandomSeed(s)`   | `int64 -> void`        | Sets seed for LCG                  |

Example:
```lyx
fn main(): int64 {
  RandomSeed(42);           // Set seed
  
  var r1: int64 := Random();  // Random number
  var r2: int64 := Random();  // Another random number
  
  PrintInt(r1);
  PrintStr("\n");
  PrintInt(r2);
  return 0;
}
```

#### Array Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `push(arr, val)`  | `array, int64 -> void` | Appends element at end             |
| `pop(arr)`        | `array -> int64`       | Removes and returns last element   |
| `len(arr)`        | `array -> int64`       | Returns current element count      |
| `free(arr)`       | `array -> void`        | Frees heap memory                  |

#### String Manipulation Builtins
| Function                        | Signature                          | Description                                    |
|---------------------------------|------------------------------------|------------------------------------------------|
| `StrLen(s)`                     | `pchar -> int64`                   | String length (null-terminated)                |
| `StrCharAt(s, i)`               | `pchar, int64 -> int64`            | Read character at position                     |
| `StrSetChar(s, i, c)`           | `pchar, int64, int64 -> void`      | Write character at position                    |
| `StrNew(cap)`                   | `int64 -> pchar`                   | Allocate new string buffer (mmap)              |
| `StrFree(s)`                    | `pchar -> void`                    | Free string buffer (munmap)                    |
| `StrAppend(dest, src)`          | `pchar, pchar -> pchar`            | Append src to dest; returns new buffer         |
| `StrAppendStr(dest, src)`       | `pchar, pchar -> pchar`            | In-place append; returns same pointer          |
| `StrConcat(a, b)`               | `pchar, pchar -> pchar`            | Concatenate a and b into new buffer            |
| `StrCopy(s)`                    | `pchar -> pchar`                   | Allocate a copy of s                           |
| `StrFindChar(s, ch, start)`     | `pchar, int64, int64 -> int64`     | Find first occurrence of char from start       |
| `StrSub(s, start, len)`         | `pchar, int64, int64 -> pchar`     | Extract substring                              |
| `StrStartsWith(s, prefix)`      | `pchar, pchar -> bool`             | True if s starts with prefix                   |
| `StrEndsWith(s, suffix)`        | `pchar, pchar -> bool`             | True if s ends with suffix                     |
| `StrEquals(a, b)`               | `pchar, pchar -> bool`             | True if a and b are equal                      |
| `s1 + s2`                       | `pchar + pchar -> pchar`           | Concatenate via operator (mmap'd buffer)       |

**String Concatenation** uses `+` directly:

```lyx
fn main(): int64 {
  var s: pchar := "Hello" + ", " + "World!";
  PrintStr(s);  // Hello, World!
  PrintStr("\n");
  return 0;
}
```

#### String Library (`std.string`)

Import `std.string` for higher-level string utilities built on top of the builtins above.

**`StrTrim(s)`** — strips leading and trailing whitespace, returns a new heap-allocated string:

```lyx
import std.string;

var t: pchar := StrTrim("  hello  ");
PrintStr(t);   // hello
StrFree(t);
```

**`StrSplit(s, delim, out, maxParts)`** — splits `s` on `delim`, stores result pointers into `out` (an `int64` pointing to a pchar array), returns the number of parts. Each part is heap-allocated and must be freed with `StrFree`. Pass `maxParts` to limit the number of splits (the last part receives the remainder):

```lyx
import std.string;

var parts: int64 := mmap(0, 80, 3, 34, -1, 0);
var n: int64 := StrSplit("a,b,c", ",", parts, 10);
// n == 3
var p0: pchar := peek64(parts)      as pchar;   // "a"
var p1: pchar := peek64(parts + 8)  as pchar;   // "b"
var p2: pchar := peek64(parts + 16) as pchar;   // "c"
StrFree(p0); StrFree(p1); StrFree(p2);
```

**`StringBuilder`** — a growable string builder class:

```lyx
import std.string;

fn main(): int64 {
  var sb: StringBuilder := new StringBuilder();
  sb.Init(16);
  sb.Append("Hello");
  sb.Append(", ");
  sb.Append("World");
  sb.AppendChar(33);   // '!'
  sb.AppendInt(42);

  var result: pchar := sb.ToString();
  PrintStr(result);    // Hello, World!42
  PrintStr("\n");
  StrFree(result);

  sb.Clear();
  sb.Append("After clear");
  var r2: pchar := sb.ToString();
  PrintStr(r2);        // After clear
  StrFree(r2);

  sb.FreeBuffer();
  dispose sb;
  return 0;
}
```

| Method | Description |
|--------|-------------|
| `sb.Init(cap)` | Allocate internal buffer with initial capacity |
| `sb.Append(s)` | Append a `pchar` string |
| `sb.AppendChar(c)` | Append a single character (as `int64`) |
| `sb.AppendInt(n)` | Append integer as decimal string |
| `sb.ToString()` | Return heap-allocated copy of the current content |
| `sb.Clear()` | Reset length to 0 (keeps buffer allocated) |
| `sb.FreeBuffer()` | Release the internal buffer (call before `dispose sb`) |

> **Note:** The release method is named `FreeBuffer()`, not `Free()`, because `Free` is a reserved VMT slot on the base `TObject` class.

#### Float Formatting

`PrintFloat` outputs a float value to stdout. For formatted output with controlled decimal places, use the Pascal-style `:width:decimals` specifier in function arguments:

```lyx
fn main(): int64 {
  var pi: f64 := 3.14159265358979;
  var vol: f64 := 12.5;

  PrintStr(pi:0:2);    // 3.14
  PrintStr("\n");
  PrintStr(vol:0:4);   // 12.5000
  PrintStr("\n");

  return 0;
}
```

The `:width:decimals` specifier lowers to `format_float(value, width, decimals)` which returns a `pchar` (heap-allocated, 64 bytes). The `width` field is reserved for future padding support.

#### String Conversion Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `IntToStr(x)`     | `int64 -> pchar`       | Converts integer to string (mmap'd buffer) |
| `StrFromInt(x)`   | `int64 -> pchar`       | Alias for `IntToStr`               |
| `FileGetSize(p)`  | `pchar -> int64`       | Returns file size in bytes (open+lseek+close) |

#### HashMap Builtins
O(1) string→int64 hash map using FNV-1a hashing with open addressing.

| Function                    | Signature                          | Description                        |
|-----------------------------|------------------------------------|------------------------------------|
| `HashNew(cap)`              | `int64 -> pchar`                   | Allocate map with `cap` slots (mmap) |
| `HashSet(m, key, val)`      | `pchar, pchar, int64 -> void`      | Insert or update key→val           |
| `HashGet(m, key)`           | `pchar, pchar -> int64`            | Lookup value (0 if missing)        |
| `HashHas(m, key)`           | `pchar, pchar -> bool`             | True if key exists                 |

#### Argv Builtins
| Function      | Signature        | Description                              |
|---------------|------------------|------------------------------------------|
| `GetArgC()`   | `-> int64`       | Number of command-line arguments         |
| `GetArg(i)`   | `int64 -> pchar` | Pointer to argv[i] (not heap-allocated)  |

#### Math Builtins (22 functions)
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `abs(x)`          | `int64 -> int64`       | Absolute value                     |
| `odd(x)`          | `int64 -> bool`        | Checks if odd                      |
| `hi(x)`           | `int64 -> int64`       | High 32 bits                       |
| `lo(x)`           | `int64 -> int64`       | Low 32 bits                       |
| `swap(x)`         | `int64 -> int64`       | Swaps 32-bit words                 |
| `fabs(x)`         | `f64 -> f64`           | Absolute value (Float)             |
| `sqrt(x)`         | `f64 -> f64`           | Square root                        |
| `sqr(x)`          | `f64 -> f64`           | Square (x²)                        |
| `round(x)`        | `f64 -> int64`         | Rounds to nearest integer          |
| `trunc(x)`        | `f64 -> int64`         | Truncates fractional part          |
| `IntPart(x)`     | `f64 -> int64`         | Alias for `trunc()`                |
| `frac(x)`         | `f64 -> f64`           | Fractional part                   |
| `pi()`            | `void -> f64`          | π constant                         |
| `sin(x)`, `cos(x)`, `exp(x)`, `ln(x)`, `arctan(x)` | `f64 -> f64` | Transcendental functions (Placeholder) |

### External Functions (v0.2.0)

The Lyx compiler now supports declarations of external functions from system libraries with a unified call path:

```lyx
extern fn malloc(size: int64): pchar;
extern fn printf(format: pchar, ...): int64;
extern fn strlen(str: pchar): int64;

fn main(): int64 {
  let ptr: pchar := malloc(64);
  let len: int64 := strlen("Hello");
  printf("Allocated %d bytes, string length: %d\n", 64, len);
  return 0;
}
```

#### Unified Call Path (v0.2.0)

The compiler now correctly distinguishes between three call types:

| Call Type | Description | Codegen |
|-----------|--------------|---------|
| `cmInternal` | Call to function in same unit | `call rel32` (direct) |
| `cmImported` | Call to function from imported unit | `call rel32` (direct) |
| `cmExternal` | Call to external library function | `call __plt_<name>` (PLT/GOT) |

#### Varargs Support

External functions can declare variable argument lists with `...`:

```lyx
extern fn printf(fmt: pchar, ...): int64;

fn main(): int64 {
  printf("Int: %d, String: %s, Float: %f\n", 42, "test", 3.14);
  return 0;
}
```

#### Dynamic vs. Static ELF Binaries

The compiler automatically detects whether external symbols are used:

- **Static ELF**: When no external functions are called
- **Dynamic ELF**: Automatically when using external symbols

```bash
# Static binary (no external calls)
./lyxc hello.lyx -o hello_static
# Output: "Generating static ELF (no external symbols)"

# Dynamic binary (with malloc/printf)
./lyxc extern_example.lyx -o extern_dynamic  
# Output: "Generating dynamic ELF with 2 external symbols"
```

#### Library Mapping

The compiler automatically maps symbols to appropriate libraries:

| Symbol | Library |
|--------|---------|
| `printf`, `malloc`, `strlen`, `exit` | `libc.so.6` |
| `sin`, `cos`, `sqrt` | `libm.so.6` |
| Unknown symbols | `libc.so.6` (fallback) |

#### PLT/GOT Mechanism

Dynamic binaries use the **Procedure Linkage Table (PLT)** and **Global Offset Table (GOT)**:

- **PLT Stubs**: Each external function gets a PLT entry
- **GOT Entries**: Contain runtime addresses of library functions
- **Relocations**: Dynamic linker patches GOT at runtime

```bash
# Analyze ELF structure
readelf -l extern_binary    # PT_INTERP, PT_DYNAMIC headers
readelf -d extern_binary    # NEEDED libraries, Symbol tables

# Debug output with new flag
./lyxc program.lyx --dump-relocs    # Shows external symbols and PLT patches
./lyxc program.lyx --emit-asm        # Shows IR as pseudo-assembler
```

### Standard Units

A comprehensive set of standard units is located in the `std/` directory, providing ergonomic library functions:

- **std/math.lyx** – Integer helpers (`Abs64`, `Min64`, `Max64`, `Div64`, `Mod64`, `TimesTwo`, `Sqrt64`, `Clamp64`, `Sign64`, `Lerp64`, `Map64`, `Sin64`, `Cos64`, `Hypot64`, `IsEven`, `IsOdd`, `NextPowerOfTwo`)
- **std/io.lyx** – I/O wrappers (`print`, `PrintLn`, `PrintIntLn`, `ExitProc`, `Printf` with auto-type-conversion)
- **std/string.lyx** – Comprehensive string library with 28+ functions: `StrToUpper`, `StrToLower`, `StrFind`, `StrReplace`, `StrRepeat`, `StrPadLeft`, `StrPadRight`, `StrTrim`, `StrSplit`, `StringBuilder` class, and more
- **std/env.lyx** – Environment API (`init`, `ArgCount`, `Arg`)
- **std/time.lyx** – Date and time calculations (numerical, timezone support)
- **std/geo.lyx** – Geolocation: GeoPoint, DistanceM, BoundingBox, DMS parsing, Navigation
- **std/fs.lyx** – Filesystem: open, read, write, close, file operations
- **std/crt.lyx** – ANSI Console Utilities (colors, cursor, clrscr). See `tests/lyx/crt/test_crt_ansi.lyx` for a demo.
- **std/pack.lyx** – Binary serialization (VarInt, int/float/string)
- **std/regex.lyx** – Regex matching

#### String Library Example

```lyx
import std.string;

fn main(): int64 {
  var text: pchar := "Hello World";
  var len: int64 := StrLength(text);           // Native Builtin
  var first: int64 := str_char_at(text, 0);     // 'H' = 72
  
  // String manipulation
  var lower: pchar := "buffer_space_here";
  StrToLower(lower, text);                    // "hello world"
  
  // String tests  
  var starts: bool := StrStartsWith(text, "Hello"); // true
  var pos: int64 := StrFind(text, "World");          // 6
  
  PrintInt(len);    // 11
  PrintStr("\n");
  return 0;
}
```

#### Math Builtins Example

```lyx
fn main(): int64 {
  var x: int64 := -42;
  var y: f64 := 16.0;
  
  // Native Integer Math (no imports needed)
  PrintInt(abs(x));         // 42
  PrintInt(hi(x));          // High 32 bits
  PrintInt(lo(x));          // Low 32 bits
  
  // Native Float Math  
  var root: f64 := sqrt(y);  // 4.0
  var square: f64 := sqr(y); // 256.0
  var rounded: int64 := round(root); // 4
  
  PrintFloat(pi());         // 3.14159...
  return 0;
}
```

#### Import Example

```lyx
import std.math;
import std.io;
import std.string;
import std.env; // optional

fn main(argc: int64, argv: pchar): int64 {
  // Automatic argc/argv initialization (no manual init() needed)
  PrintIntLn(ArgCount());
  PrintStr(Arg(0));
  PrintStr("\n");
  
  // Combined usage of different libraries
  var result: int64 := Abs64(-123);
  var str_result: pchar := IntToStr(result);
  PrintLn(str_result);
  
  return 0;
}
```

### CI / Integration Tests

- GitHub Actions CI builds the compiler, runs unit tests, and additionally compiles and executes the test programs in `tests/lyx/` to verify runtime integration. The `make e2e` target compiles and runs `hello.lyx`, `print_int.lyx`, and `test_crt_ansi.lyx`; optional `test_crt_raw.lyx` is only executed if the `CRT_RAW` CI variable is set.

```lyx
fn main(): int64 {
  PrintInt(0);
  PrintStr("\n");
  PrintInt(12345);
  PrintStr("\n");
  PrintInt(-42);
  PrintStr("\n");
  return 0;
}
```

```
0
12345
-42
```

### String Escape Sequences

| Escape | Meaning       |
|--------|---------------|
| `\n`   | Newline       |
| `\r`   | Carriage return |
| `\t`   | Tabulator     |
| `\\`   | Backslash     |
| `\"`   | Quote         |
| `\0`   | Null byte     |

### Comments

```lyx
// Line comment

/* Block comment
   spanning multiple lines */
```

### Reserved Keywords

```
fn  var  let  co  con  if  else  while  switch  case  break  default  return  true  false  extern  array  as  import  pub  unit  type  struct  static  self  Self  class  extends  new  dispose  super  virtual  override
```

- `extern` is used for external function declarations
- `as` is used for type casting
- `import`, `pub`, `unit` are used for the module system
- `type`, `struct` are used for user-defined types
- `class`, `extends` for OOP with inheritance
- `new` for heap allocation of class instances
- `dispose` for explicit memory deallocation
- `super` for calling base class methods
- `static` marks static methods (without `self` parameter)
- `virtual` declares a method as virtual with VMT entry
- `override` overrides a virtual method from base class
- `self` references the current instance in methods
- `Self` as return type in methods (resolves to struct type)

---

## Practical SO Library Examples (v0.1.5)

### Memory Management with malloc/free

```lyx
extern fn malloc(size: int64): pchar;
extern fn free(ptr: pchar): void;

fn main(): int64 {
  // Allocate dynamic memory
  let buffer: pchar := malloc(256);
  
  // Use buffer (simplified)
  PrintStr("Buffer allocated at: ");
  
  // Free memory again
  free(buffer);
  
  PrintStr("Memory freed\n");
  return 0;
}
```

### Formatted Output with printf

```lyx
extern fn printf(format: pchar, ...): int64;

fn main(): int64 {
  var count: int64 := 42;
  var pi: f64 := 3.14159;
  var name: pchar := "Lyx";
  
  // Output various data types
  printf("Language: %s\n", name);
  printf("Count: %d\n", count);  
  printf("Pi: %.2f\n", pi);
  printf("Mixed: %s has %d features!\n", name, count);
  
  return 0;
}
```

### String Processing

```lyx
extern fn strlen(str: pchar): int64;
extern fn strcat(dest: pchar, src: pchar): pchar;
extern fn strcpy(dest: pchar, src: pchar): pchar;

fn main(): int64 {
  var greeting: pchar := "Hello";
  var target: pchar := "World";
  
  var len1: int64 := strlen(greeting);
  var len2: int64 := strlen(target);
  
  printf("'%s' has %d characters\n", greeting, len1);
  printf("'%s' has %d characters\n", target, len2);
  
  return 0;
}
```

### Math Library Functions

```lyx
extern fn sin(x: f64): f64;
extern fn cos(x: f64): f64; 
extern fn sqrt(x: f64): f64;

fn main(): int64 {
  var angle: f64 := 1.5708;  // π/2
  var number: f64 := 16.0;
  
  printf("sin(%.4f) = %.4f\n", angle, sin(angle));
  printf("cos(%.4f) = %.4f\n", angle, cos(angle));
  printf("sqrt(%.1f) = %.4f\n", number, sqrt(number));
  
  return 0;
}
```

## Complete Examples

### FizzBuzz with Math Builtins

```lyx
import std.string;

con MAX: int64 := 15;

fn main(): int64 {
  var i: int64 := 1;
  while (i <= MAX) {
    var div3: bool := (i % 3) == 0;
    var div5: bool := (i % 5) == 0;
    
    if (div3 && div5) {
      PrintStr("FizzBuzz\n");
    } else {
      if (div3) {
        PrintStr("Fizz\n");
      } else {
        if (div5) {
          PrintStr("Buzz\n");
        } else {
          // Native string conversion
          var str: pchar := IntToStr(i);
          PrintStr(str);
          PrintStr("\n");
        }
      }
    }
    i := i + 1;
  }
  return 0;
}
```

### Combined String and Math Operations

```lyx
import std.string;

fn analyze_number(x: int64): void {
  PrintStr("Analyzing: ");
  PrintInt(x);
  PrintStr("\n");
  
  // Native Math Builtins
  PrintStr("Absolute: ");
  PrintInt(abs(x));
  PrintStr("\n");
  
  if (odd(x)) {
    PrintStr("Number is odd\n");
  } else {
    PrintStr("Number is even\n");  
  }
  
  // String conversion and manipulation
  var str_val: pchar := IntToStr(abs(x));
  var len: int64 := StrLength(str_val);
  
  PrintStr("String representation: '");
  PrintStr(str_val);
  PrintStr("' (length: ");
  PrintInt(len);
  PrintStr(")\n");
  
  // Float casting and math
  var float_val: f64 := (abs(x) as f64);
  var sqrt_val: f64 := sqrt(float_val);
  PrintStr("Square root: ");
  PrintFloat(sqrt_val);
  PrintStr("\n\n");
}

fn main(): int64 {
  analyze_number(-42);
  analyze_number(16);
  analyze_number(123);
  return 0;
}
```

---

## Build & Test

### Prerequisites

- **FreePascal Compiler** (FPC 3.2.2+)
- **Linux x86_64** (host platform)
- GNU Make

### Build Compiler

```bash
make build          # Release build (-O2)
make debug          # Debug build with checks (-g -gl -Ci -Cr -Co -gh)
```

### Compile Lyx Program

```bash
# Linux ELF64 (default)
./lyxc input.lyx -o output
./output
echo $?             # Check exit code

# Windows PE32+ (Cross-compilation)
./lyxc input.lyx -o output.exe --target=win64
# Run on Windows or Wine
```

### Tests

```bash
make test           # All unit tests (FPCUnit) - 15 suites, all pass
make e2e            # End-to-end smoke tests
./tests/test_pe64  # PE64 writer tests
```

---

## Architecture

```
Source code (.lyx)
      |
  [ Lexer ]         Tokenizer -> TToken-Stream
      |
  [ Parser ]        Recursive-Descent -> AST
      |
  [ Sema ]          Semantic analysis (Scopes, Types)
      |
  [ IR Lowering ]   AST -> 3-Address-Code IR
      |
  [ IR Optimizer ]  Constant Folding, CSE, DCE, Copy Propagation, Strength Reduction
      |
  [ Inlining ]      Function inlining optimization
      |
  [ Backend ]       IR -> Machine code (Bytes)
      |
      +-- [ Linux x86_64: x86_64_emit + elf64_writer ]   -> ELF64 Binary
      |
      +-- [ Linux ARM64:  arm64_emit + elf64_writer ]    -> ELF64 Binary
      |
      +-- [ Windows x64:  x86_64_win64 + pe64_writer ]   -> PE32+ Binary
      |
      +-- [ macOS x86_64: macosx64_emit + macho64_writer ] -> Mach-O Binary
      |
  Executable (ELF64, PE32+, or Mach-O, without libc)
```

### Project Structure

```
lyxc.lpr                  Main program
frontend/
  lexer.pas                 Tokenizer
  parser.pas                Recursive-Descent Parser
  ast.pas                   AST node types
  sema.pas                  Semantic analysis
ir/
  ir.pas                    IR node types (3-Address-Code)
  lower_ast_to_ir.pas       AST -> IR transformation
  ir_optimize.pas           IR optimizations (Constant Folding, CSE, DCE, etc.)
  ir_inlining.pas           Function inlining
backend/
  backend_types.pas         Shared types (External Symbols, Patches)
  x86_64/
    x86_64_emit.pas         x86_64 instruction encoding (Linux/SysV)
    x86_64_win64.pas        Windows x64 emitter (Shadow Space, IAT)
  arm64/
    arm64_emit.pas          ARM64 instruction encoding (AAPCS64)
  elf/
    elf64_writer.pas        ELF64 binary writer (Linux x86_64/ARM64)
  pe/
    pe64_writer.pas         PE32+ binary writer (DOS/COFF/Optional Header)
  macho/
    macho64_writer.pas      Mach-O 64-bit binary writer (macOS)
    syscalls_macos.pas      macOS BSD syscall constants
  macosx64/
    macosx64_emit.pas       macOS x86_64 code emitter
util/
  diag.pas                  Diagnostics (errors with line/column)
  bytes.pas                 TByteBuffer (byte encoding + patching)
tests/                      FPCUnit tests
  lyx/                      Lyx test programs (thematic)
examples/                   Curated showcase programs
```

### Design Principles

- **Frontend/Backend Separation**: No x86 code in frontend, no AST nodes in backend.
- **IR as Stability Anchor**: Pipeline is always AST -> IR -> machine code.
- **Platform Abstraction**: Same IR input for Linux and Windows backends.
- **ELF64 without libc**: `_start` calls `main()`, then `sys_exit`. No linking against external libraries.
- **PE32+ with IAT**: Import Address Table for kernel32.dll functions (GetStdHandle, WriteFile, ExitProcess).
- **Builtins embedded**: `PrintStr`, `PrintInt`, `PrintFloat`, `strlen` and `exit` are embedded as runtime snippets directly into the binary.
- **Every token carries SourceSpan**: Error messages always include file, line, and column.

---

## Editor Highlighting & Grammar

- An initial TextMate/VSCode grammar is in the repo at `syntaxes/lyx.tmLanguage.json`. It covers keywords, types, literals, comments, and basic constructs and is iteratively refined.
- Short-term, a pragmatic mapping via `.gitattributes` is used so GitHub highlighting is immediately visible: `*.lyx linguist-language=Rust` (fallback).
- Goal: Contribution to the GitHub Linguist library with a final TextMate grammar so `.lyx` files are natively highlighted on GitHub.

Note for local testing (VSCode)
- Open the repo in VSCode and use "Extension Development Host" to load `syntaxes/aurum.tmLanguage.json`.
- With "Developer: Inspect TM Scopes" you can check token scopes.

## Grammar (EBNF)

The complete formal grammar is in [`ebnf.md`](ebnf.md).

```ebnf
Program     := { TopDecl } ;
TopDecl     := FuncDecl | ConDecl | TypeDecl ;
TypeDecl    := 'type' Ident ':=' ( StructType | Type ) ';' ;
StructType  := 'struct' '{' { FieldDecl } '}' ;
FieldDecl   := Ident ':' Type ';' ;
ConDecl     := 'con' Ident ':' Type ':=' ConstExpr ';' ;
FuncDecl    := 'fn' Ident '(' [ ParamList ] ')' [ ':' RetType ] Block ;
Block       := '{' { Stmt } '}' ;
Stmt        := VarDecl | LetDecl | CoDecl | AssignStmt
             | IfStmt | WhileStmt | ReturnStmt | ExprStmt | Block ;
Expr        := OrExpr ;
OrExpr      := AndExpr { '||' AndExpr } ;
AndExpr     := CmpExpr { '&&' CmpExpr } ;
CmpExpr     := AddExpr [ CmpOp AddExpr ] ;
AddExpr     := MulExpr { ( '+' | '-' ) MulExpr} ;
MulExpr     := UnaryExpr { ( '*' | '/' | '%' ) UnaryExpr } ;
UnaryExpr   := ( '!' | '-' ) UnaryExpr | Primary ;
Primary     := IntLit | FloatLit | BoolLit | StringLit | ArrayLit | StructLit
             | Ident | Call | IndexAccess | FieldAccess | '(' Expr ')' ;
ArrayLit    := '[' [ Expr { ',' Expr } ] ']' ;
StructLit   := Ident '{' [ FieldInit { ',' FieldInit } ] '}' ;
FieldInit   := Ident ':' Expr ;
FieldAccess := Primary '.' Ident ;
IndexAccess := Primary '[' Expr ']' ;
FloatLit    := [0-9]+ '.' [0-9]+ ;
```

---

## Roadmap

| Version | Features |
|---------|----------|
| **v0.0.1** | `PrintStr("...")`, `exit(n)`, ELF64 runs |
| **v0.0.2** | Integer expressions, `PrintInt(expr)` |
| **v0.1.2** | `var`, `let`, `co`, `con`, `if`, `while`, `return`, functions, SysV ABI |
| **v0.1.3** | ✅ Float literals (`f32`, `f64`), ✅ Arrays (literals, indexing, assignment) |
| **v0.1.4** | ✅ SO-Library Integration, ✅ Dynamic ELF, ✅ PLT/GOT, ✅ Extern Functions, ✅ Varargs, ✅ Module System |
| **v0.1.5** | ✅ String-Library (20+ functions), ✅ Math-Builtins (22 functions), ✅ Type-Casting (`as`), ✅ String conversion |
| **v0.1.6** | ✅ Struct literals (`Point { x: 10, y: 20 }`), ✅ Instance methods with `self`, ✅ Static methods (`static fn`), ✅ `Self` type, ✅ Field assignment (`p.x := value`), ✅ Index assignment (`arr[i] := value`) |
| **v0.1.7** | ✅ OOP: Classes with inheritance (`class extends`), ✅ `new`/`dispose` for heap objects, ✅ Constructors with arguments, ✅ Destructors, ✅ `super` for base class calls, ✅ Global variables (`var`/`let` at top-level), ✅ `Random()`/`RandomSeed()` builtins, ✅ Pipe operator (`|>`) for function chaining, ✅ Increment/Decrement (`++`/`--`) as statements |
| **v0.1.8** | ✅ Windows x64 Backend: PE32+ binary generation, ✅ Cross-Compilation (`--target=win64`), ✅ Windows x64 Calling Convention (Shadow Space), ✅ IAT/Import Directory for kernel32.dll |
| **v0.2.0** | ✅ **Unified Call Path** (internal/imported/extern), ✅ Cross-Unit Function Resolution, ✅ PLT-Stub generation for external calls, ✅ ELF Dynamic Linking Fixes (DT_NEEDED, DT_PLTREL), ✅ CLI Flags (`--emit-asm`, `--dump-relocs`), ✅ Extended ABI test catalog |
| **v0.2.1** | ✅ **Dynamic Arrays** (heap-allocated, fat-pointer, `push`/`pop`/`len`/`free` builtins, literal initialization, bounds checks, return statements) |
| **v0.2.2** | ✅ **SIMD / ParallelArray**: `parallel Array<T>(size)`, element-wise operations (`+`,`-`,`*`,`/`), scalar index access, complete IR lowering |
| **v0.3.0** | std.io: fd-based I/O (open/read/write/close syscalls) |
| **v0.3.1** | std.fs: stat, mkdir, unlink, rename |
| **v0.3.2** | Directories: getdents64, DirIter |
| **v0.4.0** | std/math: Fixed-Point math (Sqrt64, Clamp64, Lerp64, Map64, Sin64, Cos64, Hypot64) |
| **v0.4.1** | std/geo: GeoPoint type, DistanceM, BoundingBox, DMS parsing, Navigation |
| **v1.0.0** | Stable systems language: Modules stable, SysV ABI stable, std.io/fs, Diagnostics |

---

## License

This software is licensed under the **Lyx Proprietary & Community License (LPCL) v1.0**.

- **Free for**: Personal use and educational institutions
- **Commercial use**: Requires a separate license agreement
- **Forks/Modifications**: Allowed for non-commercial distribution only
- **AI/ML Training**: Strictly prohibited without written permission

See [LICENSE](LICENSE) for the full license text.

Copyright (c) 2026 Andreas Röne. All rights reserved.
