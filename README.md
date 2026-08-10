# Lyx Programming Language

> A self-hosting systems programming language focused on native code generation, predictable performance, minimal runtime dependencies, and built-in capability-based security.

![Version](https://img.shields.io/badge/version-v1.0.15E-blue)
![Status](https://img.shields.io/badge/status-self--hosting-success)
![Platform](https://img.shields.io/badge/linux-x86__64-success)
![Platform](https://img.shields.io/badge/linux-arm64-success)
![Platform](https://img.shields.io/badge/windows-PE32%2B-success)
![License](https://img.shields.io/badge/license-proprietary-lightgrey)

---

## Overview

Lyx is a statically typed compiled programming language designed for building native software without requiring external runtimes, virtual machines, or managed execution environments.

The compiler is written entirely in Lyx and successfully compiles itself (self-hosting). Starting from a FreePascal bootstrap, the compiler can reproduce itself through multiple generations until consecutive builds become binary-identical.

---

## Why Lyx?

Lyx combines native control with modern safety features:

- **Native by default** — direct ELF64/PE32+/ARM64 code generation, no runtime overhead
- **Zero-privilege sandbox** — Capability-Based Security (LCBS) enforced at compile time and runtime via seccomp-BPF and Landlock
- **Predictable performance** — explicit memory layout, no GC, deterministic execution
- **Self-hosting** — the compiler compiles itself; no external toolchain required
- **Rich standard library** — networking, cryptography, databases, PDF, SVG, HL7, EDI and more, all in pure Lyx

| Language | Inspiration |
|----------|-------------|
| Pascal   | Readability |
| C        | Native control |
| Rust     | Modern safety features |
| Go       | Simplicity |
| Zig      | Toolchain philosophy |

---

## Current Status

### Compiler

| Component              | Status            |
|------------------------|-------------------|
| Lexer                  | Stable            |
| Parser                 | Stable            |
| Semantic Analysis      | Stable            |
| Type System            | Stable            |
| IR Optimizer           | Stable            |
| ELF64 Backend (x86-64) | Stable            |
| ELF64 Backend (ARM64)  | Stable            |
| PE32+ Backend (x86-64) | Beta              |
| Android APK Builder    | Stable            |
| LyxOS Backend (IR/Simulation, Phase 0–7) | Stable         |
| LyxOS Backend (LBF-Nativ Production, Phase 8) | In Development |
| Stack Canaries (WP-18) | Stable            |
| LCBS / seccomp / Landlock | Stable         |
| Precompiled Units (.lyu) | Stable          |
| Self-Hosting           | Stable            |
| LSP Support            | Planned           |

### Bootstrap Chain

```text
Stage 1: FreePascal → lyxc (bootstrap binary)
Stage 2: lyxc       → lyxc (first self-compiled)
Stage 3: lyxc       → lyxc
Stage 4: lyxc       → lyxc

SHA-256(Stage 3) == SHA-256(Stage 4)  →  fixed point reached
```

---

## Hello World

```lyx
fn main(): int64 {
    PrintLn("Hello, World!");
    return 0;
}
```

```bash
lyxc hello.lyx
./hello
```

---

## Language Features

### Variables and Constants

```lyx
var counter: int64 := 0;
con MaxValue: int64 := 100;
```

### Nullable Types

```lyx
var ptr: pchar?;
var result := ptr ?? "default";
```

### Dynamic Arrays

```lyx
var numbers: array<int64>;
```

### Classes and Inheritance

```lyx
type Animal = class {
    virtual fn Speak(): void;
};

type Dog = class : Animal {
    override fn Speak(): void { PrintLn("Woof"); }
};
```

### Pipe-Forward Operator

```lyx
var result := input |> trim() |> toLower() |> validate();
```

### Match Expressions

```lyx
match status {
    200 => PrintLn("OK");
    404 => PrintLn("Not found");
    _   => PrintLn("Other");
}
```

### Dimensional Analysis

```lyx
dim Length;
dim Time;

utype Meter  : f64 [Length];
utype Second : f64 [Time];
// compile-time error: cannot add Meter + Second
```

### Low-Level Memory Control

```lyx
flat struct Packet {
    id:    uint32;
    flags: uint16;
}

packed struct Register {
    enabled at(0): bool;
    mode    at(1): uint8;
}

@big_endian
struct NetworkHeader { ... }
```

---

## Capability-Based Security (LCBS)

Lyx enforces Zero-Privilege by default. Every system access must be explicitly declared via `@capabilities`.

```lyx
// No @capabilities → no OS access; any syscall triggers SIGSYS
fn main(): int64 {
    PrintLn("Safe by default.");
    return 0;
}

// Explicit capability declaration
@capabilities([fs.read, network.tcp.connect])
fn fetchData(): void {
    // Only file reads and outbound TCP are permitted.
    // All other syscalls → SECCOMP_RET_KILL_PROCESS
    // All other paths   → EACCES (Landlock)
}
```

**Runtime enforcement stack (installed automatically before `main`):**

| Layer | Mechanism | Violation |
|-------|-----------|-----------|
| Syscall filter | seccomp-BPF | `SECCOMP_RET_KILL_PROCESS` |
| Filesystem isolation | Landlock (Linux ≥ 5.13) | `EACCES` |
| Network filtering | Userspace proxy | connection refused |
| Stack integrity | Stack canaries (getrandom) | abort |

**Migration tooling:**

```bash
lyxc --migrate-capabilities old_program.lyx  # generate @capabilities manifest
lyxc --capabilities=compat  old_program.lyx  # disable sandbox (transition period)
lyxc --self-test                             # run LCBS integration tests
```

**Security audit output on every build:**
```
Sicherheits-Score: 40/40  (+10 FFI, +5 W^X, +5 RELRO, +10 grant, +5 seccomp, +5 landlock)
```

---

## Standard Library

The standard library is written entirely in Lyx. All modules are available as source (`.lyx`) and as precompiled units (`.lyu`).

### Core

| Module | Description |
|--------|-------------|
| `std.alloc` | Heap allocator |
| `std.os` | OS primitives |
| `std.process` | Process management |
| `std.fs` | Filesystem (read, write, stat, directory) |
| `std.log` | Structured logging |
| `std.time` | Clock, timestamps |
| `std.thread` | Threading primitives |
| `std.ini` | INI file parser |
| `std.yaml` | YAML parser |

### Mathematics

| Module | Description |
|--------|-------------|
| `std.math` | Basic math functions |
| `std.math.constants` | Mathematical constants (π, e, …) |
| `std.hash` | Hash maps |
| `std.list` | Linked lists |

### Strings

| Module | Description |
|--------|-------------|
| `std.strtype` | `String` — owned byte string (class, operators) |
| `std.text` | `Text` — validated UTF-8, codepoint-aware (class, operators) |
| `std.string` | String utilities |
| `std.unicode` | Opt-in: normalisation (NFC/NFD), case folding, classification |
| `std.unicode_case` | Opt-in: full Unicode simple case mapping |
| `std.grapheme` | Opt-in: grapheme cluster segmentation (UAX #29) |
| `std.regex` | Regular expressions |
| `std.url` | URL parsing and encoding |

### Networking

| Module | Description |
|--------|-------------|
| `std.net.socket` | Raw TCP/UDP sockets |
| `std.net.http` | HTTP/1.1 client + server |
| `std.net.https` | TLS-wrapped HTTP |
| `std.net.tls` | TLS layer |
| `std.net.dns` | DNS resolver |
| `std.net.smtp` | SMTP client |
| `std.net.mqtt` | MQTT 3.1.1 / 5.0 |
| `std.net.quic` | QUIC transport |
| `std.net.ssh` | SSH client |
| `std.net.telnet` | Telnet client |
| `std.net.ntp` | NTP time sync |
| `std.net.sip` | SIP (VoIP) |
| `std.net.bgp` | BGP routing |
| `std.net.snmp` | SNMP |
| `std.net.whois` | WHOIS lookup |
| `std.net.asn1` | ASN.1 / DER / BER |
| `std.net.mongo` | MongoDB wire protocol |

### Cryptography

| Module | Description |
|--------|-------------|
| `std.crypto.aes` | AES-128/256 (ECB, CBC, GCM) |
| `std.crypto.sha1` | SHA-1 |
| `std.crypto.sha256` | SHA-256 |
| `std.crypto.hmac` | HMAC |
| `std.crypto.md5` | MD5 |
| `std.crypto.rsa` | RSA encrypt/decrypt/sign |
| `std.crypto.ecc` | Elliptic Curve Cryptography |
| `std.crypto.x25519` | X25519 key exchange |
| `std.crypto.rand` | Cryptographic random |
| `std.crypto.pqc.mlkem` | ML-KEM (CRYSTALS-Kyber, FIPS 203) |
| `std.crypto.pqc.mldsa` | ML-DSA (CRYSTALS-Dilithium, FIPS 204) |
| `std.crypto.pqc.slhdsa` | SLH-DSA (SPHINCS+, FIPS 205) |
| `std.crypto.pqc.hybrid` | Classical + PQC hybrid schemes |

### Databases

| Module | Description |
|--------|-------------|
| `std.db.sqlite` | SQLite3 (via FFI) |
| `std.db.mysql` | MySQL/MariaDB client |
| `std.db.redis` | Redis client |
| `std.db.redis_simple` | Simplified Redis interface |

### Document Generation

| Module | Description |
|--------|-------------|
| `std.pdf` | PDF builder |
| `std.pdf.reader` | PDF reader |
| `std.pdf.graphics` | Vector graphics in PDF |
| `std.pdf.builder` | High-level PDF document API |
| `std.svg.builder` | SVG generation |
| `std.svg.parser` | SVG parsing |

### Healthcare & Messaging

| Module | Description |
|--------|-------------|
| `std.hl7.core` | HL7 v2 MLLP transport + MSH/ACK engine |
| `std.hl7.adt` | ADT — Patient Administration (A01–A40+) |
| `std.hl7.orders` | ORM/OML/ORR/RAS — Order Management |
| `std.hl7.results` | ORU/OUL — Observation Results (OBX, NTE, SPM) |

### Electronic Data Interchange

| Module | Description |
|--------|-------------|
| `std.edi.*` | EDI (EDIFACT/X12) with AS2/SFTP partner profiles |

### Geolocation

| Module | Description |
|--------|-------------|
| `std.geo` | Coordinate calculations, distance, geocoding |

### Validation

| Module | Description |
|--------|-------------|
| `std.validate.iban` | IBAN |
| `std.validate.bic` | BIC/SWIFT |
| `std.validate.isbn` | ISBN-10/13 |
| `std.validate.issn` | ISSN |
| `std.validate.ean` | EAN-8/13 |
| `std.validate.luhn` | Luhn algorithm |
| `std.validate.isin` | ISIN |
| `std.validate.vat` | EU VAT numbers |
| `std.validate.de_personal` | German ID/passport |
| + more | BIC, ISMN, ISRC, LEI, ORCID, US SSN, … |

### Machine Learning

| Module | Description |
|--------|-------------|
| `std.ml` | Inference engine |
| `std.fasttext` | fastText text classification |

### UI / Terminal

| Module | Description |
|--------|-------------|
| `std.lyxvision` | Terminal UI framework |
| `std.lfd_parser` | Lyx Form Definition (GUI layout DSL) |

### Mobile / Embedded

| Module | Description |
|--------|-------------|
| `std.android.apk_builder` | Android APK builder |
| `std.android.zip_writer` | ZIP writer |
| `std.qt5_core` | Qt5 Core bindings (Linux) |

---

## Precompiled Units

```bash
# Compile a unit to .lyu
lyxc mymodule.lyx --compile-unit -o mymodule.lyu

# Use normally — compiler prefers .lyu when available
lyxc main.lyx
```

---

## Compiler Architecture

```text
Source (.lyx / .lyu)
        │
        ▼
+-------------------+
|       Lexer       |
+-------------------+
        │
        ▼
+-------------------+
|      Parser       |
+-------------------+
        │
        ▼
+-------------------+
| Semantic Analysis |
| + LCBS Validator  |
| + FFI Validator   |
+-------------------+
        │
        ▼
+-------------------+
|  Intermediate IR  |
+-------------------+
        │
        ▼
+-------------------+
|    IR Optimizer   |  ← Constant Folding, DCE, CSE,
+-------------------+     Copy Propagation, Strength Reduction
        │
        ▼
+-------------------------------+
| Backend                       |
|  ELF64 x86-64 (Linux)        |
|  ELF64 ARM64  (Linux/Android) |
|  PE32+ x86-64 (Windows)       |
|  APK          (Android)       |
|  LyxOS        (bare-metal)    |
+-------------------------------+
        │
        ▼
  Native Executable
```

---

## Building the Compiler

### Linux (x86-64)

```bash
git clone https://github.com/SEOLizer/Lyx.git
cd Lyx
make
```

### Running Tests

```bash
make test      # unit + compiler tests
make e2e       # integration tests
```

---

## Optimization Pipeline

| Pass | Description |
|------|-------------|
| Constant Folding | Evaluates constant expressions at compile time (including negative constants) |
| Dead Code Elimination | Removes instructions whose results are never used |
| Common Subexpression Elimination | Deduplicates identical computations within a basic block |
| Copy Propagation | Eliminates redundant copy temporaries |
| Strength Reduction | Replaces multiplications/divisions with shifts where possible |
| Peephole Optimization | Backend-level instruction pattern replacement |

---

## LyxOS Backend

LyxOS is a purpose-built OS target for Lyx programs. It defines its own binary format (**LBF — Lyx Binary Format**) and a 137-syscall ABI, providing deterministic execution, built-in capability enforcement, and an integrated AI inference layer at the kernel level.

Two binary formats are used:

| Format | Magic | Purpose |
|--------|-------|---------|
| **LBF-IR** | `LBF\0` | IR opcode bytecode — emitted via `--emit=lbf` (for testing/simulation) |
| **LBF-Nativ** | `LYX!` | Native x86-64/ARM64 machine code, 4 KB page-aligned, CRC32C-protected blocks — production format. A native loader (`lbf_run`) validates and executes a `LYX!` file in-process (mmap RWX + jump, no ELF intermediate). |

### Implementation Status

**Phase 0–7 — IR / Simulation layer (25 Work Packages): complete**

| Area | Work Packages | Status |
|------|---------------|--------|
| LBF-IR serialiser + interpreter (`lbf_run`) | LX-00, LX-24 | ✅ Done |
| Target registration, entry point, I/O, memory | LX-01 – LX-05 | ✅ Done |
| VFS, I/O devices, poll | LX-06, LX-07 | ✅ Done |
| Network syscalls (0x0600–0x0609) | LX-08 | ✅ Done |
| Processes, threads, IPC, synchronisation | LX-09, LX-10 | ✅ Done |
| Time syscalls | LX-11 | ✅ Done |
| Capabilities, pledge, unveil | LX-12 | ✅ Done |
| Task scheduler, `@parallel` | LX-13 | ✅ Done |
| AI inference layer (model, context, embedding, vector index, knowledge graph) | LX-14 – LX-16 | ✅ Done |
| Lyra agent interface | LX-17 | ✅ Done |
| IOFS: Island & Ocean filesystem | LX-18 | ✅ Done |
| Runtime library, stdlib adaptation, error return convention | LX-19 – LX-21 | ✅ Done |
| Debug & telemetry, integration tests | LX-22, LX-23 | ✅ Done |

**Phase 8 — LBF-Nativ production format (12 Work Packages): nearly complete**

| Work Package | Description | Status |
|--------------|-------------|--------|
| LX-25 | Block Header I/O | ✅ Done |
| LX-26 | Genesis-Content Serializer | ✅ Done |
| LX-27 | TLV Framework | ✅ Done |
| LX-28 | Section Block Emitter | ✅ Done |
| LX-29 | Supply Chain Security | ✅ Done |
| LX-30 | LBF-Nativ backend | ✅ Done |
| LX-31 | `lbf_loader` + native runtime (`lbf_run`) | ✅ Done |
| LX-32 | `lbf_import` IOFS import | ✅ Done |
| LX-33 | Dependency resolver | ✅ Done |
| LX-34 | Zero-Load Executor (Kernel) | In Development |
| LX-35 | `lbf-dump` inspection tool | ✅ Done |
| LX-36 | Lifecycle descriptor | ✅ Done |

Compile and run a LyxOS program today (via the IR interpreter):

```bash
lyxc --target=lyxos --emit=lbf prog.lyx -o prog.lbf
lbf_run prog.lbf
```

---

## Roadmap

### In Progress

- LyxOS Phase 8 — Zero-Load Kernel Executor (LX-34; LX-25–36 otherwise complete)
- ARM64 backend — virtual methods / VMT + inheritance (procedural, structs, static methods done)
- Language Server Protocol (LSP)
- Incremental compilation

### Planned

- Generic types
- Package manager
- IDE integration (VS Code, JetBrains)
- Formal language standard
- Full cross-compilation toolchain

---

## Safety-Critical Extensions

Lyx includes optional features for aerospace, embedded, industrial, and mission-critical environments:

- `@dal(A)` — DO-178C Design Assurance Level annotations
- `@critical` — marks functions for additional verification
- `@wcet(cycles)` — worst-case execution time annotations
- Triple Modular Redundancy support
- Deterministic floating-point execution
- Hardware register mapping via `packed struct`
- Memory scrubbing support
- Stack integrity via hardware-seeded canaries

These features are entirely optional and do not affect ordinary application development.

---

## Security

Before shipping a binary, lyxc runs a full security audit:

```
Sicherheits-Score: 40/40
  +10  FFI validation (no unchecked OS-class extern fns)
  + 5  W^X enforcement
  + 5  RELRO
  +10  capability grant/restrict chain verified
  + 5  seccomp-BPF installed
  + 5  Landlock filesystem isolation installed
```

Security is non-negotiable: binaries that fail the audit do not compile without explicit opt-out.

---

## License

Copyright © 2026 Andreas Röne. All rights reserved.
