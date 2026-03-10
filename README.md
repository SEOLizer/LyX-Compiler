# Lyx

**Lyx** is a native compiler for the homonymous programming language, written in FreePascal.
It produces directly executable **Linux x86_64 ELF64**, **Linux ARM64 ELF64**, and **Windows x64 PE32+ binaries** — without libc, without linker, using pure syscalls or WinAPI.

```
Lyx Compiler v0.5.0
Copyright (c) 2026 Andreas Röne. All rights reserved.

✅ Cross-Compilation: Linux x86_64, Linux ARM64, Windows x64
✅ Complete Module System with Import/Export
✅ Cross-Unit Function Calls and Symbol Resolution
✅ Unified Call Path (internal/imported/extern)
✅ PLT/GOT Dynamic Linking for External Libraries
✅ Standard Library (std.math, std.io, std.string, std.geo, std.time, std.fs, ...)
✅ IR-Level Inlining Optimization (v0.4.3)
✅ IR-Level Optimizer (v0.5.0): Constant Folding, CSE, DCE, Copy Propagation, Strength Reduction
✅ PascalCase Naming Conventions (v0.4.3)
✅ Integrated Linter with 10 Rules (v0.4.3)
✅ Peephole Optimizer (v0.5.0): Constant folding, identity ops, redundant moves
✅ Robust Parser with While/If/For/Switch/Function Support
✅ OOP: Classes, Inheritance, Constructors, Destructors
✅ Global Variables with Initialization
✅ Random/RandomSeed Builtins
✅ CLI Arguments (argc/argv) in Static ELF
✅ Option Types: Nullable Pointer (pchar?) with Null-Coalescing (??)
✅ SIMD: ParallelArray<T> with Element-wise Operations
✅ Dynamic Arrays: push/pop/len/free
✅ QBool: Probabilistic Boolean Type for quantum-like computing
✅ Associative Arrays: Map<K,V> and Set<T> with O(n) lookup
```

---

## Quick Start

```bash
# Build compiler
make build

# Compile and run Linux program
./lyxc examples/hello.lyx -o hello
./hello

# Cross-compile for Windows
./lyxc examples/hello.lyx -o hello.exe --target=win64

# Debug flags
./lyxc examples/hello.lyx --emit-asm      # Output IR as pseudo-assembler
./lyxc examples/hello.lyx --dump-relocs   # Show relocations and symbols
./lyxc examples/hello.lyx --no-opt         # Disable IR optimizations
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

### Cross-Compilation

Lyx supports **cross-compilation** for three target platforms:

```bash
# Linux x86_64 ELF64 (default on Linux hosts)
./lyxc program.lyx -o program --target=linux

# Linux ARM64 ELF64 (for Raspberry Pi, Apple Silicon Linux, cloud servers)
./lyxc program.lyx -o program --target=arm64

# Windows PE32+ (from Linux)
./lyxc program.lyx -o program.exe --target=win64
```

| Target Platform | Format | Calling Convention | OS Interface |
|-----------------|--------|-------------------|--------------|
| `linux` | ELF64 | SysV ABI x86_64 (RDI, RSI, RDX, RCX, R8, R9) | Syscalls |
| `arm64` | ELF64 | AAPCS64 (X0-X7) | Syscalls |
| `win64` | PE32+ | Windows x64 (RCX, RDX, R8, R9 + Shadow Space) | kernel32.dll |

**Note:** The `--target` parameter is optional. The compiler automatically selects the host OS as the target.

**Testing ARM64 binaries (on x86_64):**
```bash
# Install QEMU
sudo apt install qemu-user-static

# Run ARM64 binary
qemu-aarch64-static ./program
```

---

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

**Available Standard Library:**
- `std.math`: Mathematical functions (`Abs64`, `Min64`, `Max64`, `Sqrt64`, `Clamp64`, `Sign64`, `Lerp64`, `Map64`, `Sin64`, `Cos64`, `Hypot64`, `IsEven`, `IsOdd`, `NextPowerOfTwo`, etc.)
- `std.io`: I/O functions (`print`, `PrintLn`, `PrintIntLn`, `ExitProc`, `Printf` with auto-conversion)
- `std.string`: Comprehensive string manipulation (`StrLength`, `StrCharAt`, `StrFind`, `StrToLower`, `StrToUpper`, `StrConcat`, `StrReplace`, etc.)
- `std.env`: Environment API (`ArgCount`, `Arg`, `init`)
- `std.time`: Date and time functions (numerical calculations, timezone support)
- `std.geo`: Geolocation parser for Decimal Degrees, GeoPoint, Distance calculations, BoundingBox, DMS parsing
- `std.fs`: Filesystem operations (open, read, write, close, file existence)
- `std.crt`: ANSI Terminal Utilities (colors, cursor control)
- `std.pack`: Binary serialization (VarInt, int/float/string packing)
- `std.regex`: Regex matching
- `std.qbool`: Probabilistic Boolean Type (`QBool`, `Maybe()`, `Observe()`, `QBoolAnd`, `QBoolOr`, `QBoolNot`, Entanglement)
- `std.vector`: 2D Vector library (`Vec2`)
- `std.list`: Collections (`StaticList8`, `StackInt64`, `QueueInt64`, `RingBufferVec2`)
- `std.rect`: Rectangle utilities (`Rect`)
- `std.color`: RGBA Color utilities

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

Lyx supports OOP with classes, inheritance, constructors, and destructors:

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

**Class features:**
- `class extends BaseClass` for inheritance
- `new ClassName()` for heap allocation
- `new ClassName(args)` calls constructor `Create`
- `dispose expr` calls `Destroy()` and frees memory
- `super.method()` for calling base class methods
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
| `PrintFloat(x)`  | `f64 -> void`          | Outputs float (simplified)          |
| `exit(code)`      | `int64 -> void`        | Terminates program with exit code   |

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
| Function                    | Signature                                    | Description                        |
|-----------------------------|---------------------------------------------|-------------------------------------|
| `StrLength(s)`             | `pchar -> int64`                           | Calculates string length           |
| `str_char_at(s, index)`     | `pchar, int64 -> int64`                    | Reads character at position        |
| `str_set_char(s, index, c)` | `pchar, int64, int64 -> void`             | Sets character at position         |
| `StrCompare(s1, s2)`       | `pchar, pchar -> int64`                   | String comparison (0=equal)        |
| `str_copy_builtin(dest, src)` | `pchar, pchar -> void`                   | Copies string                      |

#### String Conversion Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `IntToStr(x)`   | `int64 -> pchar`       | Converts integer to string          |
| `str_to_int(s)`   | `pchar -> int64`       | Converts string to integer          |

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
- **std/string.lyx** – Comprehensive string library with 25+ functions
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
fn  var  let  co  con  if  else  while  switch  case  break  default  return  true  false  extern  array  as  import  pub  unit  type  struct  static  self  Self  class  extends  new  dispose  super
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
      +-- [ Linux:   x86_64_emit + elf64_writer ]  -> ELF64 Binary
      |
      +-- [ Windows: x86_64_win64 + pe64_writer ]  -> PE32+ Binary
      |
  Executable (ELF64 or PE32+, without libc)
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
  elf/
    elf64_writer.pas        ELF64 binary writer
  pe/
    pe64_writer.pas         PE32+ binary writer (DOS/COFF/Optional Header)
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

Copyright (c) 2026 Andreas Röne. All rights reserved.
