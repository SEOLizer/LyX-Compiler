# Lyx Compiler User Guide

## Document Information

| Field | Value |
|-------|-------|
| **Document** | USER-GUIDE-001 |
| **Version** | 0.7.0-aerospace |
| **Date** | 2026-04-03 |
| **Status** | Released |

---

## 1. Getting Started

### 1.1 Installation

```bash
# Clone the repository
git clone <repository-url>
cd lyx-lang

# Build the compiler
cd compiler && make build
cd ..

# Verify installation
./lyxc --version
```

### 1.2 Your First Program

Create a file `hello.lyx`:

```lyx
fn main(): int64 {
  PrintStr("Hello, Lyx!\n");
  return 0;
}
```

Compile and run:

```bash
./lyxc hello.lyx -o hello
./hello
```

Output:
```
Hello, Lyx!
```

### 1.3 Cross-Compilation

```bash
# Linux x86_64 (default on Linux)
./lyxc hello.lyx -o hello --target=linux

# Windows x64
./lyxc hello.lyx -o hello.exe --target=win64

# ARM64 Linux (Raspberry Pi, cloud servers)
./lyxc hello.lyx -o hello --target=arm64

# macOS Intel
./lyxc hello.lyx -o hello --target=macosx64

# macOS Apple Silicon
./lyxc hello.lyx -o hello --target=macos-arm64

# ESP32 microcontroller
./lyxc hello.lyx -o hello.elf --target=esp32

# RISC-V RV64GC
./lyxc hello.lyx -o hello.elf --target=riscv
```

---

## 2. Language Basics

### 2.1 Variables

```lyx
fn main(): int64 {
  var mutable: int64 := 10;    // Can be changed
  let immutable: int64 := 20;   // Cannot be changed
  co runtime_const: int64 := 30; // Runtime constant
  con compile_const: int64 := 40; // Compile-time constant

  mutable := mutable + 1;       // OK
  // immutable := 0;            // Error: immutable

  return mutable + immutable;
}
```

### 2.2 Functions

```lyx
fn add(a: int64, b: int64): int64 {
  return a + b;
}

fn greet(name: pchar) {
  PrintStr("Hello, ");
  PrintStr(name);
  PrintStr("!\n");
}

fn main(): int64 {
  var result: int64 := add(3, 4);
  PrintInt(result);  // 7
  greet("World");
  return 0;
}
```

### 2.3 Control Flow

```lyx
fn main(): int64 {
  var x: int64 := 42;

  // If/else
  if (x > 10) {
    PrintStr("greater\n");
  } else {
    PrintStr("smaller\n");
  }

  // While loop
  var i: int64 := 0;
  while (i < 5) {
    PrintInt(i);
    PrintStr("\n");
    i := i + 1;
  }

  // Switch
  switch (x % 3) {
    case 0: PrintStr("divisible by 3\n");
    case 1: PrintStr("remainder 1\n");
    default: PrintStr("other\n");
  }

  return 0;
}
```

### 2.4 Arrays

```lyx
fn main(): int64 {
  // Dynamic array
  var arr: array := [10, 20, 30];

  PrintInt(len(arr));   // 3
  PrintInt(arr[0]);     // 10

  push(arr, 40);
  PrintInt(len(arr));   // 4

  var last: int64 := pop(arr);
  PrintInt(last);       // 40

  free(arr);
  return 0;
}
```

### 2.5 Structs

```lyx
type Point = struct {
  x: int64;
  y: int64;

  fn distance(): f64 {
    return sqrt64(self.x * self.x + self.y * self.y);
  }
};

fn main(): int64 {
  var p: Point := Point { x: 3, y: 4 };
  PrintInt(p.x);      // 3
  PrintInt(p.y);      // 4
  return 0;
}
```

### 2.6 Classes (OOP)

```lyx
type Shape = class {
  virtual fn area(): f64 { return 0.0; }
};

type Circle = class extends Shape {
  radius: f64;

  override fn area(): f64 {
    return 3.14159 * self.radius * self.radius;
  }

  fn Create(r: f64) {
    self.radius := r;
  }
};

fn main(): int64 {
  var c: Circle := new Circle(5.0);
  // c.area() → 78.53975
  dispose c;
  return 0;
}
```

---

## 3. Standard Library

### 3.1 Using Modules

```lyx
import std.math;
import std.string;
import std.os;

fn main(): int64 {
  var abs_val: int64 := Abs64(-42);
  PrintInt(abs_val);  // 42

  var pid: int64 := get_pid();
  PrintInt(pid);

  return 0;
}
```

### 3.2 Logging

```lyx
import std.log;

fn main(): int64 {
  log_app_start("MyApp");
  log_info("Application started");
  log_debug("Debug information");
  log_warn("Warning message");
  log_error("Error occurred");
  log_app_end(0);
  return 0;
}
```

### 3.3 Network

```lyx
import std.net.http;

fn main(): int64 {
  var resp: HTTPResponse := HTTPGet("example.com", "/");
  PrintStr(resp.bodyPtr);
  HTTPResponseFree(resp);
  return 0;
}
```

---

## 4. Safety Features

### 4.1 MC/DC Coverage

```bash
# Compile with MC/DC instrumentation
./lyxc program.lyx -o program --mcdc

# Generate coverage report
./lyxc program.lyx -o program --mcdc --mcdc-report
```

### 4.2 Static Analysis

```bash
# Run all 7 analysis passes
./lyxc program.lyx -o program --static-analysis
```

### 4.3 ESP32 Safety

```lyx
fn main(): int64 {
  // Initialize watchdog (5 second timeout)
  watchdog_init(5000);

  // Configure brownout detection (2.8V)
  brownout_config(2800);

  // Main loop
  var i: int64 := 0;
  while (i < 1000) {
    watchdog_feed();  // Feed watchdog
    i := i + 1;
  }

  // Check stack canary
  if (stack_canary_check() != 0) {
    PrintStr("Stack overflow detected!\n");
    return 1;
  }

  return 0;
}
```

### 4.4 RISC-V Safety

```lyx
fn main(): int64 {
  // Configure PMP region 0: flash memory (read-only, executable)
  pmp_config(0, 0x40000000, 0x1000000, PMP_CFG_R or PMP_CFG_X or PMP_CFG_A_NAPOT);

  // Configure PMP region 1: stack (read-write, no execute)
  pmp_config(1, 0x80000000, 0x10000, PMP_CFG_R or PMP_CFG_W or PMP_CFG_A_NAPOT);

  // Lock regions
  pmp_lock(0);
  pmp_lock(1);

  // Memory barrier
  fence();

  return 0;
}
```

---

## 5. Advanced Topics

### 5.1 Generics

```lyx
fn max[T](a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}

fn main(): int64 {
  var x: int64 := max(10, 20);  // 20
  return x;
}
```

### 5.2 Pattern Matching

```lyx
fn describe(n: int64): int64 {
  match (n) {
    case 0 => { PrintStr("zero\n"); return 0; }
    case 1 | 2 => { PrintStr("small\n"); return 1; }
    case 3 | 4 | 5 => { PrintStr("medium\n"); return 2; }
    default => { PrintStr("large\n"); return 3; }
  }
}
```

### 5.3 Exception Handling

```lyx
fn risky() {
  throw;  // Throw exception
}

fn main(): int64 {
  try {
    risky();
  } catch {
    PrintStr("Caught exception\n");
  }
  return 0;
}
```

### 5.4 Pipe Operator

```lyx
fn double(x: int64): int64 { return x * 2; }
fn addOne(x: int64): int64 { return x + 1; }

fn main(): int64 {
  var result: int64 := 5 |> double() |> addOne();
  PrintInt(result);  // 11
  return 0;
}
```

---

## 6. Troubleshooting

### 6.1 Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `undefined identifier` | Missing import or typo | Check import statements and spelling |
| `type mismatch` | Incompatible types | Use `as` for explicit casting |
| `stack overflow` | Deep recursion | Increase stack size or use iteration |
| `segmentation fault` | Null pointer or bounds error | Use `--static-analysis` to detect |

### 6.2 Debugging

```bash
# Enable linter warnings
./lyxc program.lyx --lint

# Dump IR as pseudo-assembler
./lyxc program.lyx --emit-asm

# Show relocations and symbols
./lyxc program.lyx --dump-relocs

# Trace import resolution
./lyxc program.lyx --trace-imports

# Run static analysis
./lyxc program.lyx --static-analysis
```

---

## 7. References

- **COMPILER_MANUAL.md**: Complete compiler documentation
- **SPEC.md**: Full language specification
- **ebnf.md**: Grammar definition
- **README.md**: Project overview
- **aerospace-todo.md**: DO-178C compliance roadmap
