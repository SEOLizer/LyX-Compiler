# Lyx Programming Language

> A self-hosting systems programming language focused on native code generation, predictable performance, minimal runtime dependencies, and long-term maintainability.

![Version](https://img.shields.io/badge/version-v0.9.5B-blue)
![Status](https://img.shields.io/badge/status-self--hosting-success)
![Platform](https://img.shields.io/badge/linux-x86__64-success)
![License](https://img.shields.io/badge/license-proprietary-lightgrey)

---

# Overview

Lyx is a statically typed compiled programming language designed for building native software without requiring external runtimes, virtual machines, or managed execution environments.

The project began with a simple objective:

> Build a modern compiler that generates real native executables while remaining understandable, maintainable, and capable of self-hosting.

Today Lyx includes:

- Native ELF64 code generation
- Self-hosting compiler
- Modular standard library
- Static type system
- Object-oriented programming support
- Dynamic arrays
- Nullable types
- SIMD support
- Compile-time constants
- Unit and dimensional analysis
- Advanced memory layout control
- Safety-critical programming extensions
- Multi-stage optimization pipeline
- **Capability-Based Security (LCBS)** — Zero-Privilege runtime sandboxing

The compiler is written in Lyx and successfully compiles itself.

---

# Why Lyx?

Many modern languages trade simplicity for abstraction.

Lyx follows a different philosophy:

- Native machine code first
- Minimal runtime assumptions
- Explicit control over memory layout
- Predictable performance
- Small and understandable compiler architecture
- Self-hosting as a primary design goal

Lyx attempts to combine:

| Language | Inspiration |
|-----------|-------------|
| Pascal | Readability |
| C | Native control |
| Rust | Modern language features |
| Go | Simplicity |
| Zig | Toolchain philosophy |

without becoming a clone of any of them.

---

# Current Status

## Compiler

| Component | Status |
|------------|---------|
| Lexer | Stable |
| Parser | Stable |
| Semantic Analysis | Stable |
| Type System | Stable |
| Optimizer | Stable |
| ELF64 Backend | Stable |
| Self-Hosting | Stable |
| ARM64 Backend | In Development |
| PE32+ Backend | In Development |
| LSP Support | Planned |

---

# Self Hosting

Lyx is fully self-hosting.

The compiler can compile its own source code and reproduce itself through a bootstrap chain.

```text
Stage 1
FreePascal Compiler
        ↓
lyxc

Stage 2
lyxc → lyxc

Stage 3
lyxc → lyxc

Stage 4
lyxc → lyxc
```

Once consecutive compiler generations become binary-identical, a fixed point has been reached.

```text
MD5(Stage3) == MD5(Stage4)
```

This demonstrates bootstrap stability and compiler reproducibility.

---

# Compiler Architecture

```text
Source Code (.lyx)
        │
        ▼
+------------------+
|      Lexer       |
+------------------+
        │
        ▼
+------------------+
|      Parser      |
+------------------+
        │
        ▼
+------------------+
|       AST        |
+------------------+
        │
        ▼
+------------------+
| Semantic Analysis|
+------------------+
        │
        ▼
+------------------+
| Intermediate IR  |
+------------------+
        │
        ▼
+------------------+
|   Optimizer      |
+------------------+
        │
        ▼
+------------------+
| Backend (ELF/PE) |
+------------------+
        │
        ▼
Native Executable
```

The architecture intentionally separates:

- Frontend
- Intermediate Representation
- Optimizer
- Target Backends

to simplify future platform support.

---

# Hello World

```lyx
fn main(): int64 {
    PrintLn("Hello World");
    return 0;
}
```

Compile:

```bash
lyxc hello.lyx
```

Run:

```bash
./hello
```

---

# Language Example

```lyx
fn factorial(n: int64): int64 {
    if (n <= 1) {
        return 1;
    }

    return n * factorial(n - 1);
}

fn main(): int64 {
    PrintLn(factorial(10));
    return 0;
}
```

---

# Standard Library

Lyx ships with a modular standard library.

## Core

```text
std.system
std.env
std.os
std.process
```

## Mathematics

```text
std.math
std.random
```

## Strings

```text
std.string
std.regex
```

## Filesystem

```text
std.fs
```

## Time

```text
std.time
```

## Serialization

```text
std.pack
```

## Console

```text
std.crt
```

## Geolocation

```text
std.geo
```

---

# Import System

```lyx
import std.io;
import std.math;
import std.string;

fn main(): int64 {
    PrintLn("Imports work.");
    return 0;
}
```

---

# Module Resolution

Modules are resolved in the following order:

1. Relative to importing file
2. Project root
3. Include paths (`-I`)
4. Standard library

The `std.*` namespace is reserved and always resolves to the standard library.

---

# Environment Variables

```bash
export LYX_PATH=/usr/include/lyx
export LYX_STD_PATH=/usr/include/lyx/std
```

Equivalent CLI options:

```bash
-I <path>
--std-path=<path>
```

---

# Precompiled Units

Lyx supports precompiled units.

Compile:

```bash
lyxc mymodule.lyx --compile-unit -o mymodule.lyu
```

Use:

```bash
lyxc main.lyx
```

The compiler automatically prefers `.lyu` files when available.

---

# Core Language Features

## Variables

```lyx
var counter: int64 := 0;
let name: pchar := "Lyx";
co buildVersion: int64 := 42;
con MaxValue: int64 := 100;
```

---

## Nullable Types

```lyx
var ptr: pchar?;
```

```lyx
var result := ptr ?? "default";
```

---

## Dynamic Arrays

```lyx
var numbers: array<int64>;
```

---

## Classes

```lyx
class Animal {
    virtual fn Speak();
}
```

---

## Inheritance

```lyx
class Dog : Animal {
    override fn Speak();
}
```

---

## Compile-Time Constants

```lyx
con MaxConnections: int64 := 1000;
```

---

# Advanced Features

## Dimensional Analysis

```lyx
dim Length;
dim Time;

utype Meter : f64 [Length];
utype Second : f64 [Time];
```

Compile-time validation prevents invalid calculations.

---

## Flat Structures

```lyx
flat struct Packet {
    id: uint32;
    flags: uint16;
}
```

---

## Packed Bitfield Structures

```lyx
packed struct Register {
    enabled at(0): bool;
    mode    at(1): uint8;
}
```

---

## Endianness Control

```lyx
@big_endian
struct Header {
}
```

---

# Safety Critical Extensions

Lyx includes optional features intended for aerospace, embedded, industrial, and mission-critical environments.

Examples include:

- Integrity annotations
- Triple Modular Redundancy
- Runtime integrity verification
- Hardware register mapping
- Deterministic floating point execution
- Memory scrubbing support

These features are entirely optional and do not affect ordinary application development.

---

# Optimization Pipeline

Current optimization stages include:

- Constant Folding
- Dead Code Elimination
- Common Subexpression Elimination
- Copy Propagation
- Strength Reduction
- Peephole Optimization

---

# Building The Compiler

## Linux

```bash
git clone https://github.com/SEOLizer/Lyx.git

cd Lyx

make
```

---

# Running Tests

```bash
make test
```

Integration tests:

```bash
make e2e
```

---

# Documentation

Documentation is divided into several parts.

| Document | Purpose |
|-----------|----------|
| Language Specification | Syntax and semantics |
| EBNF Grammar | Formal grammar |
| Compiler Internals | Architecture |
| Standard Library Reference | API documentation |
| Bootstrap Guide | Self-hosting process |
| Backend Documentation | Code generation |

---

# Roadmap

## Near-Term

- ARM64 backend
- Windows PE backend
- Improved diagnostics
- Generic types
- Package manager

## Long-Term

- Full cross compilation
- Incremental compilation
- Language Server Protocol
- IDE integration
- Formal language standard

---

# Design Principles

Lyx is built around a small set of principles:

1. Native code generation
2. Predictable execution
3. Explicit control
4. Maintainable compiler architecture
5. Long-term self-hosting
6. Stable language evolution

---

# Contributing

Contributions, bug reports, design discussions, and language proposals are welcome.

Before implementing major language changes, please discuss them through an issue or design proposal.

---

# Security (LCBS)

Lyx includes a built-in **Capability-Based Security** system (LCBS) that enforces Zero-Privilege by default.

```lyx
// Without @capabilities: no OS access, no network, no hardware
fn main(): int64 {
  PrintLn("Safe by default.");
  return 0;
}

// Explicitly declare what you need:
@capabilities([fs.read, hardware.gpio(pin: 18)])
fn sensorMain(): int64 {
  // Only file reads and GPIO pin 18 are permitted.
  // All other syscalls → SIGSYS (seccomp KILL_PROCESS).
  // All other paths → EACCES (Landlock).
  return 0;
}
```

**Runtime mechanisms** (all installed automatically before `main()`):
- **seccomp-BPF** — syscall whitelist; `SECCOMP_RET_KILL_PROCESS` for violations
- **Landlock** — path-based filesystem isolation (Linux ≥ 5.13)
- **Userspace Proxy** — IP/port filtering for network capabilities

**Migration tools:**
```bash
lyxc --migrate-capabilities old_program.lyx   # generate @capabilities manifest
lyxc --capabilities=compat old_program.lyx    # compile without sandbox (transition)
lyxc --self-test                               # run LCBS integration tests
```

**Security Audit** is printed to stderr on every build:
```
Sicherheits-Score: 40/40  (+10 FFI, +5 W^X, +5 RELRO, +10 grant, +5 seccomp, +5 landlock)
```

Full documentation: [capabilities.md](capabilities.md)

---

# License 

Copyright © Andreas Röne

All rights reserved.
