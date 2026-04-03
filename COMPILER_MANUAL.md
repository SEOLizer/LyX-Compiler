# Lyx Compiler Manual

## Document Information

| Field | Value |
|-------|-------|
| **Document** | COMPILER-MANUAL-001 |
| **Version** | 0.7.0-aerospace |
| **Date** | 2026-04-03 |
| **Status** | Released |
| **Compiler** | Lyx Compiler (lyxc) v0.7.0-aerospace |
| **DO-178C** | TQL-5 Qualified |

---

## 1. Introduction

### 1.1 Purpose

This manual provides complete documentation for the Lyx Compiler (lyxc), a native compiler for the Lyx programming language written in FreePascal. It produces directly executable binaries for multiple platforms without libc, without linker, using pure syscalls or WinAPI.

### 1.2 Scope

This manual covers:
- Language specification overview
- Compiler usage and options
- Target platforms and architectures
- Safety-critical features (DO-178C)
- Build and deployment procedures

### 1.3 Target Audience

- Application developers using the Lyx language
- Safety engineers performing DO-178C certification
- Compiler maintainers and contributors

---

## 2. Language Specification

### 2.1 Overview

Lyx is a **procedural**, **statically typed** programming language inspired by C and Rust, with its own compact syntax. It is designed for safety-critical embedded systems and aerospace applications.

### 2.2 Types

| Type | Description | Size |
|------|-------------|------|
| `int64` / `int` | Signed 64-bit Integer | 8 bytes |
| `f32` | 32-bit Floating-Point (IEEE 754) | 4 bytes |
| `f64` | 64-bit Floating-Point (IEEE 754) | 8 bytes |
| `bool` | `true` / `false` | 1 byte |
| `void` | Only as function return type | — |
| `pchar` | Pointer to null-terminated bytes | 8 bytes |
| `pchar?` | Nullable pointer | 8 bytes |
| `array` | Dynamic array (heap, fat pointer) | 24 bytes |
| `parallel Array<T>` | SIMD-optimized array | 24 bytes |
| `struct` | User-defined record type | Varies |
| `class` | Heap-allocated OOP type | Varies |
| `Map<K,V>` | Associative array | Varies |
| `Set<T>` | Unordered unique collection | Varies |
| `QBool` | Probabilistic boolean (0.0-1.0) | 8 bytes |

### 2.3 Storage Classes

| Keyword | Mutable | Compile-time | Storage |
|---------|:-------:|:------------:|---------|
| `var` | yes | — | Stack/Data (global) |
| `let` | no | — | Stack/Data (global) |
| `co` | no | optional | Stack |
| `con` | no | yes | Immediate / rodata |

### 2.4 Operators

| Priority | Operators | Description |
|:--------:|-----------|-------------|
| 1 (low) | `\|>` | Pipe (function chaining) |
| 2 | `\|\|` | Logical Or |
| 3 | `&&` | Logical And |
| 4 | `==` `!=` `<` `<=` `>` `>=` | Comparison (returns `bool`) |
| 5 | `+` `-` | Addition, Subtraction |
| 6 | `*` `/` `%` | Multiplication, Division, Modulo |
| 7 (high) | `!` `-` (unary) | Logical NOT, Negation |
| 8 | `as` | Type-Casting |

### 2.5 Control Flow

- `if (condition) { ... } else { ... }`
- `while (condition) { ... }`
- `switch (expr) { case N: ... default: ... }`
- `return expr;`

### 2.6 Functions

```lyx
fn add(a: int64, b: int64): int64 {
  return a + b;
}

fn greet() {
  PrintStr("Hello!\n");
}
```

### 2.7 OOP: Classes with VMT

```lyx
type Animal = class {
  name: pchar;
  virtual fn speak() { PrintStr("sound\n"); }
};

type Dog = class extends Animal {
  override fn speak() { PrintStr("woof\n"); }
};
```

### 2.8 Generics

```lyx
fn max[T](a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}
```

### 2.9 Pattern Matching

```lyx
match (x) {
  case 0 => PrintStr("zero\n");
  case 1 | 2 => PrintStr("small\n");
  default => PrintStr("other\n");
}
```

### 2.10 Exception Handling

```lyx
try {
  risky_operation();
} catch {
  PrintStr("error occurred\n");
}
```

---

## 3. Compiler Usage

### 3.1 Basic Usage

```bash
# Compile and run (default target: host OS)
./lyxc program.lyx -o program
./program

# Cross-compile for different platforms
./lyxc program.lyx -o program.exe --target=win64
./lyxc program.lyx -o program --target=arm64
./lyxc program.lyx -o program --target=riscv
```

### 3.2 Command-Line Options

| Option | Description |
|--------|-------------|
| `-o <file>` | Output file (default: a.out / a.exe) |
| `-I <path>` | Add include path for modules (repeatable) |
| `--std-path=PATH` | Override standard library path |
| `--target=TARGET` | Target platform (linux, win64, arm64, macosx64, macos-arm64, esp32, riscv) |
| `--arch=ARCH` | Architecture (x86_64, arm64, xtensa, riscv) |
| `--target-energy=<1-5>` | Energy level (1=minimal, 5=extreme) |
| `--emit-asm` | Output IR as pseudo-assembler |
| `--dump-relocs` | Show relocations and external symbols |
| `--trace-imports` | Debug import resolution |
| `--lint` | Enable linter warnings |
| `--lint-only` | Lint only, don't compile |
| `--no-lint` | Disable linter warnings |
| `--no-opt` | Disable IR optimizations |
| `--mcdc` | MC/DC instrumentation (DO-178C DAL A) |
| `--mcdc-report` | Generate MC/DC coverage report |
| `--static-analysis` | Run static analysis (7 passes) |
| `--version` | Show version (TOR-001) |
| `--build-info` | Show build identification (TOR-002) |
| `--config` | Show configuration (TOR-003) |

### 3.3 Target Platforms

| Target | Architecture | Format | ABI | Status |
|--------|-------------|--------|-----|--------|
| `linux` | x86_64 | ELF64 | SysV ABI | ✅ Stable |
| `arm64` | ARM64 | ELF64 | AAPCS64 | ✅ Stable |
| `win64` | x86_64 | PE32+ | Windows x64 | ✅ Stable |
| `macosx64` | x86_64 | Mach-O | SysV ABI | ✅ Stable |
| `macos-arm64` | ARM64 | Mach-O | AAPCS64 | ✅ Stable |
| `esp32` | Xtensa | ELF32 | Simplified SysV | ⚠️ Experimental |
| `riscv` | RV64GC | ELF64 | LP64D | ✅ Stable |

---

## 4. Built-in Functions

### 4.1 I/O Builtins

| Function | Signature | Description |
|----------|-----------|-------------|
| `PrintStr(s)` | `pchar → void` | Output string until null terminator |
| `PrintInt(x)` | `int64 → void` | Output integer as decimal |
| `PrintFloat(x)` | `f64 → void` | Output float (sign + integer + 6 decimals) |
| `Println(s)` | `pchar → void` | Output string + newline |
| `exit(code)` | `int64 → void` | Terminate with exit code |

### 4.2 Debugging

| Function | Signature | Description |
|----------|-----------|-------------|
| `Inspect(x)` | `any → void` | Runtime debug output to stderr |

### 4.3 Random

| Function | Signature | Description |
|----------|-----------|-------------|
| `Random()` | `void → int64` | Pseudo-random number (LCG) |
| `RandomSeed(s)` | `int64 → void` | Set LCG seed |

### 4.4 Array Builtins

| Function | Signature | Description |
|----------|-----------|-------------|
| `push(arr, val)` | `array, int64 → void` | Append element |
| `pop(arr)` | `array → int64` | Remove and return last |
| `len(arr)` | `array → int64` | Element count |
| `free(arr)` | `array → void` | Free heap memory |

### 4.5 String Builtins

| Function | Signature | Description |
|----------|-----------|-------------|
| `StrLen(s)` | `pchar → int64` | String length |
| `StrCharAt(s, i)` | `pchar, int64 → int64` | Character at position |
| `StrSetChar(s, i, c)` | `pchar, int64, int64 → void` | Set character |
| `StrNew(cap)` | `int64 → pchar` | Allocate buffer |
| `StrFree(s)` | `pchar → void` | Free buffer |
| `StrAppend(dest, src)` | `pchar, pchar → pchar` | Append (reallocating) |
| `StrConcat(a, b)` | `pchar, pchar → pchar` | Concatenate |
| `StrCopy(s)` | `pchar → pchar` | Duplicate string |
| `StrFindChar(s, ch, start)` | `pchar, int64, int64 → int64` | Find character |
| `StrSub(s, start, len)` | `pchar, int64, int64 → pchar` | Extract substring |
| `StrFromInt(n)` | `int64 → pchar` | Integer to string |
| `StrStartsWith(s, prefix)` | `pchar, pchar → bool` | Prefix check |
| `StrEndsWith(s, suffix)` | `pchar, pchar → bool` | Suffix check |
| `StrEquals(a, b)` | `pchar, pchar → bool` | Equality check |

### 4.6 System Builtins

| Function | Signature | Description |
|----------|-----------|-------------|
| `getpid()` | `void → int64` | Process ID |
| `sleep_ms(ms)` | `int64 → void` | Sleep milliseconds |
| `now_unix()` | `void → int64` | Unix timestamp |
| `now_unix_ms()` | `void → int64` | Unix timestamp (ms) |
| `open(path, flags, mode)` | `pchar, int64, int64 → int64` | Open file |
| `read(fd, buf, count)` | `int64, pchar, int64 → int64` | Read from file |
| `write(fd, buf, count)` | `int64, pchar, int64 → int64` | Write to file |
| `close(fd)` | `int64 → int64` | Close file |
| `mmap(size, prot, flags)` | `int64, int64, int64 → pchar` | Memory map |
| `munmap(addr, size)` | `pchar, int64 → void` | Unmap memory |

### 4.7 Safety Builtins (ESP32)

| Function | Description |
|----------|-------------|
| `watchdog_feed()` | Feed task watchdog |
| `watchdog_init(timeout_ms)` | Initialize watchdog |
| `brownout_check()` | Check voltage (mV) |
| `brownout_config(threshold_mV)` | Set brownout threshold |
| `flash_verify(offset, size)` | Flash integrity check (CRC32) |
| `secure_boot()` | Verify secure boot |
| `mpu_config(region, addr, size, cfg)` | Configure PMP region |
| `cache_flush()` | Flush cache for DMA |
| `stack_canary_check()` | Check stack canary |
| `wdt_reset()` | Force watchdog reset |
| `coredump_save()` | Save coredump to flash |

### 4.8 Safety Builtins (RISC-V)

| Function | Description |
|----------|-------------|
| `pmp_config(region, addr, size, cfg)` | Configure PMP region |
| `pmp_lock(region)` | Lock PMP region |
| `ebreak()` | Breakpoint instruction |
| `fence()` | Memory barrier |
| `fence_i()` | Instruction fence |
| `csr_read(csr_num)` | Read CSR |
| `csr_write(csr_num, value)` | Write CSR |
| `csr_set(csr_num, mask)` | Set CSR bits |
| `csr_clear(csr_num, mask)` | Clear CSR bits |
| `get_mhartid()` | Get hart ID |
| `get_mcycle()` | Get cycle counter |
| `get_time()` | Get time CSR |
| `wfi()` | Wait for interrupt |
| `mret()` | Return from machine mode |
| `sret()` | Return from supervisor mode |

### 4.9 Safety Builtins (ARM Cortex-M)

| Function | Description |
|----------|-------------|
| `mpu_enable()` | Enable MPU |
| `mpu_config(region, addr, size, ap)` | Configure MPU region |
| `stack_canary_check()` | Check stack canary |
| `set_unprivileged()` | Switch to unprivileged mode |
| `set_privileged()` | Switch to privileged mode |
| `get_fault_status()` | Read CFSR/HFSR |
| `get_fault_address()` | Read MMFAR/BFAR |
| `clear_fault_status()` | Clear fault status |
| `bkpt()` | Breakpoint instruction |

---

## 5. Standard Library

### 5.1 Available Modules

| Module | Description |
|--------|-------------|
| `std.math` | Mathematical functions (Abs64, Min64, Max64, Sqrt64, Sin64, Cos64, etc.) |
| `std.io` | I/O functions (print, PrintLn, Printf) |
| `std.string` | String manipulation (StrLength, StrFind, StrToLower, StrToUpper, etc.) |
| `std.env` | Environment API (ArgCount, Arg, init) |
| `std.time` | Date and time functions |
| `std.geo` | Geolocation (Decimal Degrees, Distance, BoundingBox) |
| `std.fs` | Filesystem operations (open, read, write, close) |
| `std.crt` | ANSI Terminal utilities (colors, cursor control) |
| `std.pack` | Binary serialization (VarInt, packing) |
| `std.regex` | Regex matching |
| `std.qbool` | Probabilistic Boolean Type |
| `std.vector` | 2D Vector library |
| `std.list` | Collections (StaticList, Stack, Queue, RingBuffer) |
| `std.rect` | Rectangle utilities |
| `std.color` | RGBA Color utilities |
| `std.log` | Logging module (debug, info, warn, error, fatal) |
| `std.os` | OS module (pid, env, time, sleep, system info) |
| `std.net` | Network library (17 protocols: TCP, UDP, DNS, HTTP, HTTPS, TLS, SMTP, IMAP, etc.) |

---

## 6. DO-178C Safety Features

### 6.1 Tool Qualification (TQL-5)

The Lyx compiler is qualified as a **TQL-5 Development Tool** per DO-178C Section 12.2.

```bash
./lyxc --version        # TOR-001: Version
./lyxc --build-info     # TOR-002: Build identification
./lyxc --config         # TOR-003: Configuration
```

### 6.2 MC/DC Coverage (DAL A)

```bash
./lyxc program.lyx -o program --mcdc
./lyxc program.lyx -o program --mcdc --mcdc-report
```

### 6.3 Static Analysis

```bash
./lyxc program.lyx -o program --static-analysis
```

7 analysis passes:
1. Data-Flow Analysis (Def-Use chains)
2. Live Variable Analysis (unused variable detection)
3. Constant Propagation (known constant tracking)
4. Null Pointer Analysis (null dereference detection)
5. Array Bounds Analysis (index safety)
6. Termination Analysis (unbounded loop detection)
7. Stack Usage Analysis (worst-case calculation)

### 6.4 Deterministic Code Generation

Lyx guarantees **bit-for-bit reproducible builds**:
- Same source + same config → identical binary (verified by hash)
- No non-deterministic optimizations
- No time-dependent decisions
- Fixed register allocation
- Fixed stack layout calculation

---

## 7. Build System

### 7.1 Building the Compiler

```bash
# From repo root (recommended):
make build          # produces ./lyxc

# From compiler directory:
cd compiler && make build

# Debug build:
make debug          # produces ./lyxc_debug

# End-to-end tests:
make e2e
```

### 7.2 Compiler Structure

```
compiler/
├── lyxc.lpr                 # Main program (entry point)
├── Makefile                 # Build rules
├── frontend/                # Lexer, Parser, AST, Sema
├── backend/                 # Code generation per platform
│   ├── x86_64/              #   x86-64 Linux/Windows
│   ├── arm64/               #   ARM64 Linux
│   ├── macosx64/            #   macOS x86-64
│   ├── win_arm64/           #   Windows ARM64
│   ├── xtensa/              #   ESP32/Xtensa
│   ├── riscv/               #   RISC-V RV64GC
│   ├── arm_cm/              #   ARM Cortex-M
│   ├── elf/                 #   ELF64 Writers
│   ├── pe/                  #   PE64 Writer
│   └── macho/               #   Mach-O Writer
├── ir/                      # IR definitions, lowering, optimization
│   ├── ir.pas               #   IR instruction definitions
│   ├── lower_ast_to_ir.pas  #   AST → IR lowering
│   ├── ir_inlining.pas      #   Function inlining
│   ├── ir_optimize.pas      #   Constant folding, CSE, DCE
│   ├── ir_mcdc.pas          #   MC/DC instrumentation
│   └── ir_static_analysis.pas # Static analysis (7 passes)
├── util/                    # Utilities (bytes, diag)
└── tests/                   # Test suite
```

---

## 8. Version History

### v0.7.0-aerospace (2026-04-03)

**New Features:**
- DO-178C TQL-5 Tool Qualification (TOR-001, TOR-002, TOR-003)
- MC/DC Instrumentation for DAL A coverage
- Static Analysis: 7 passes (Data-Flow, Live-Vars, Const-Prop, Null-Ptr, Array-Bounds, Termination, Stack)
- Test Generation: Fuzzing, Boundary-Value, Mutation Testing, Symbolic Execution
- RISC-V RV64GC Backend with PMP, CSR access, ecall/ebreak
- ARM Cortex-M Safety Backend with MPU, Fault-Handlers, Stack-Canary
- ESP32 Safety Features: Watchdog, Brownout, Flash-Verify, MPU, Stack-Canary
- 100% IR Coverage in all 7 backends (TOR-011 validated)
- Reference Interpreter for compiler verification (22/22 tests)
- Deterministic code generation validated (18/18 tests)

### v0.6.0-aerospace (2026-03-30)

**New Features:**
- Self-hosting compiler (Singularity achieved)
- Windows ARM64 full builtins
- Xtensa/ESP32 builtins
- macOS x86_64 builtins
- ARM64 Linux full builtins

### v0.5.7 (2026-03-25)

**New Features:**
- Exception Handling: try/catch/throw
- Multi-Return / Tuples
- Generics with monomorphization
- Pattern Matching: match/case/default
- Dynamic String Builtins
- HashMap Builtins (FNV-1a)
- Argv Builtins

---

## 9. Known Issues and Workarounds

### 9.1 ESP32 Backend

| Issue | Severity | Workaround |
|-------|----------|------------|
| Segfault during compilation | Medium | Use simpler programs, avoid deep recursion |
| Dynamic linking not implemented | Low | Use static linking only |
| Limited standard library support | Low | Use built-in functions only |

### 9.2 ARM Cortex-M Backend

| Issue | Severity | Workaround |
|-------|----------|------------|
| TrustZone support is stub only | Low | Use M-mode only for critical code |
| No hardware FPU support | Medium | Use software float emulation |

### 9.3 RISC-V Backend

| Issue | Severity | Workaround |
|-------|----------|------------|
| Dynamic linking not implemented | Low | Use static linking only |
| Limited atomic operation support | Low | Use LR/SC for simple cases |

### 9.4 General

| Issue | Severity | Workaround |
|-------|----------|------------|
| Large programs may exceed stack limits | Medium | Increase stack size or reduce recursion |
| Some IR operations are stubs in non-primary backends | Low | Use x86_64 Linux as primary target |

---

## 10. References

- **DO-178C**: Software Considerations in Airborne Systems and Equipment Certification
- **DO-331**: Model-Based Development and Verification
- **DO-332**: Object-Oriented Technology and Related Techniques
- **DO-333**: Formal Methods Supplement to DO-178C and DO-278A
- **SPEC.md**: Complete Lyx Language Specification
- **ebnf.md**: Lyx Grammar (v0.2.0+)
- **AGENTS.md**: Compiler development guide
- **selfhosted.md**: Self-hosting bootstrap roadmap
