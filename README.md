# Lyx

**Lyx** ist ein nativer Compiler für die gleichnamige Programmiersprache, geschrieben in FreePascal.
Er erzeugt direkt ausführbare **Linux x86_64 ELF64**, **Linux ARM64 ELF64** und **Windows x64 PE32+** Binaries — ohne libc, ohne Linker, unter Verwendung reiner Syscalls oder WinAPI.

```
Lyx Compiler v0.4.3
Copyright (c) 2026 Andreas Röne. All rights reserved.

✅ Cross-Compilation: Linux x86_64, Linux ARM64, Windows x64
✅ Complete Module System with Import/Export
✅ Cross-Unit Function Calls and Symbol Resolution
✅ Unified Call Path (internal/imported/extern)
✅ PLT/GOT Dynamic Linking for External Libraries
✅ Standard Library (std.math, std.io, std.string, std.geo, std.time, std.fs, std.regex, ...)
✅ IR-Level Inlining Optimization (v0.4.3)
✅ PascalCase Naming Conventions (v0.4.3)
✅ Integrated Linter with 10 Rules (--lint flag)
✅ Robust Parser with While/If/For/Switch/Function Support
✅ OOP: Classes, Inheritance, Constructors, Destructors
✅ Global Variables with Initialization
✅ Random/RandomSeed Builtins
✅ CLI Arguments (argc/argv) in Static ELF
✅ Option Types: Nullable Pointer (pchar?) with Null-Coalescing (??)
✅ SIMD: ParallelArray<T> with Element-wise Operations
✅ Dynamic Arrays: push/pop/len/free
✅ Strings & Slices: string type, slice_u8
✅ std/geo: GeoPoint, Distance, BoundingBox, DMS parsing
✅ std/time: Date/Time, Timezone support
✅ std/fs: File I/O, Directory operations
✅ std/pack: Binary serialization
✅ std/regex: Regex matching (v0.4.2)
✅ std/crt: ANSI Terminal control
✅ Panic & Assert: Runtime error handling (v0.4.2)
✅ Access Control: pub/private/protected for classes (v0.4.1)
✅ Namespaces: IO, OS, Math, Regex (v0.4.2)
✅ Debugging: --emit-asm and --dump-relocs Flags
✅ Peephole Optimizer (v0.5.0): Pattern-based instruction simplification
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
```

```
Hello Lyx
```

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
- `std.math`: Mathematical functions (`Abs64`, `Min64`, `Max64`, `Div64`, `Mod64`, `Sqrt64`, `Clamp64`, `Sign64`, `Lerp64`, `Map64`, `Sin64`, `Cos64`, `Hypot64`, `IsEven`, `IsOdd`, `NextPowerOfTwo`, `Pow64`, `Min3`, `Max3`, `InRange64`, `PopCount`, `Log2`, `Atan2Microdegrees`, `Cos64Inverse`, etc.)
- `std.io`: I/O functions (`PrintStr`, `PrintInt`, `Printf` with auto-conversion, `open`, `read`, `write`, `close`, `lseek`, `mkdir`, `unlink`, `rename`, etc.)
- `std.string`: Comprehensive string manipulation (`StrLength`, `StrCharAt`, `StrFind`, `StrToLower`, `StrToUpper`, `StrConcat`, `StrReplace`, etc.)
- `std.env`: Environment API (`ArgCount`, `Arg`, `Init`)
- `std.time`: Date and time functions (numerical calculations, timezone support)
- `std.geo`: Geolocation parser (`ParseLat`, `ParseLon`, `FormatDecimal`, `IsValidLat`, `IsValidLon`, `DistanceM`, `DistanceKm`, `MidpointLat`, `MidpointLon`)
- `std.fs`: Filesystem operations (open, read, write, close, file existence, stat, mkdir, unlink, rename)
- `std.crt`: ANSI Terminal Utilities (colors, cursor control)
- `std.pack`: Binary serialization (VarInt, int/float/string packing)
- `std.regex`: Regex matching (`RegexMatch`, `RegexSearch`, `RegexReplace`)
- `std.vector`: 2D Vector library (`Vec2`, `Vec2Add`, `Vec2Sub`, `Vec2Dot`, `Vec2Cross`, `Vec2Length`, `Vec2Distance`, `Vec2Normalize`, `Vec2Lerp`, `Vec2Rotate`, etc.)
- `std.list`: Dynamic and static lists (`ListInt64`, `StaticList8/16/32`, `Vec2List`, `RingBufferVec2`, `StackInt64`, `QueueInt64`)
- `std.rect`: Rectangle and bounding box utilities (`Rect`, `RectFromPoints`, `RectWidth`, `RectHeight`, `RectContains`, `RectUnion`, `RectIntersect`, etc.)
- `std.color`: RGBA color utilities (`Color`, `ColorRGB`, `ColorFromHex`, `ColorToHSL`, `ColorLerp`, `ColorBlend`, `ColorGrayscale`, etc.)
- `std.result`: Result type for error handling
- `std.error`: Error type and error handling utilities
- `std.circle`: Circle geometry utilities

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
| `pchar?`  | Nullable pointer (can be null)        |
| `string`  | Alias for `pchar` (null-terminated bytes)
| `array`   | Dynamic array (Heap, Fat-Pointer: ptr, len, cap) |
| `parallel Array<T>` | SIMD-optimized array (Heap, element-wise operations) |
| `struct`  | User-defined record type             |
| `class`   | User-defined reference type with inheritance |

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

### Access Control (v0.4.1)

Lyx supports access control keywords for class and struct members:

```lyx
type MyClass = class {
  pub pubField: int64;           // Accessible everywhere
  private privField: int64;       // Only within the class
  protected protField: int64;    // In class and subclasses
  
  pub fn pubMethod() { }
  private fn privMethod() { }
  protected fn protMethod() { }
};
```

| Keyword     | Description                                  |
|-------------|---------------------------------------------|
| `pub`       | Accessible everywhere (default)             |
| `private`   | Only within the declaring class             |
| `protected` | Within declaring class and derived classes  |

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
- `pub`/`private`/`protected` access control

### Nullable Types (v0.4.0)

Lyx supports nullable pointer types with the `?` suffix and null-coalescing operator:

```lyx
fn main(): int64 {
  var p: pchar? := null;    // nullable pointer
  var q: pchar;              // non-nullable pointer (standard)
  var r: pchar := p ?? "default";  // null-coalescing
  
  if (p == null) {
    PrintStr("p is null\n");
  };
  
  return 0;
}
```

**Nullable features:**
- `pchar?` can hold `null`
- `pchar` cannot be null (enforced at compile-time)
- `??` operator provides default value when null
- `== null` and `!= null` for null checks

### Regex Literals (v0.4.2)

Lyx supports regex literals with the `r"..."` syntax:

```lyx
fn main(): int64 {
  var email: pchar := r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$";
  var phone: pchar := r"\d{3}-\d{4}";
  
  // Regex functions
  if (RegexMatch(r"abc", "abcdef")) {
    PrintStr("Match!\n");
  };
  
  var pos: int64 := RegexSearch(r"\d+", "abc123def");
  PrintInt(pos);  // 3
  PrintStr("\n");
  
  return 0;
}
```

### Namespaces (v0.4.2)

Builtin functions can be called via namespaces (recommended, backward compatible):

```lyx
fn main(): int64 {
  // Direct call (backward compatible)
  PrintStr("Hello\n");
  
  // Namespace call (recommended)
  IO.PrintStr("Hello via namespace\n");
  OS.exit(0);
  
  return 0;
}
```

**Available namespaces:**
- `IO`: PrintStr, PrintInt, PrintFloat, open, read, write, close, etc.
- `OS`: exit, getpid
- `Math`: Random, RandomSeed
- `Regex`: Match, Search, Replace

### Panic and Assert (v0.4.2)

Runtime error handling with panic and assert:

```lyx
fn divide(a: int64, b: int64): int64 {
  if (b == 0) {
    panic("Division by zero!");
  };
  return a / b;
}

fn setAge(age: int64): void {
  assert(age >= 0 && age < 150, "Age must be between 0 and 149");
}

fn main(): int64 {
  setAge(25);    // OK
  // setAge(-5);  // Would panic with message
  
  return 0;
}
```

- **`panic(message)`**: Terminates program with error message on stderr
- **`assert(cond, message)`**: Checks condition, calls panic if false

### IR-Level Inlining (v0.4.3)

The compiler automatically inlines functions with 12 or fewer IR instructions:

```lyx
fn add(a: int64, b: int64): int64 {
  return a + b;
}

fn main(): int64 {
  var x: int64 := add(10, 20);  // Inlined to: var x: int64 := 10 + 20;
  PrintInt(x);  // 30
  return 0;
}
```

**Implementation:**
- Automatic detection of small functions
- Recursion prevention
- Proper argument mapping
- Multiple passes for nested functions

---

## Operators

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
| 9         | `??`               | Null-Coalescing         |

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

### Type-Casting with `as`

Lyx supports explicit type casts with the `as` syntax:

```lyx
fn main(): int64 {
  var x: int64 := 42;
  var f: f64 := x as f64;      // int64 -> f64 conversion
  var back: int64 := f as int64; // f64 -> int64 conversion
  
  // String conversions
  var s: pchar := IntToStr(x);
  var parsed: int64 := StrToInt(s);
  
  PrintInt(parsed);  // 42
  return 0;
}
```

**Supported casts:**
- `int64 as f64`: Integer to Float (SSE2 cvtsi2sd)
- `f64 as int64`: Float to Integer with Truncation (SSE2 cvttsd2si)
- Identity Casts: `int64 as int64`, `f64 as f64`
- String conversions via builtin functions

---

## Control Flow

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

#### for loop

```lyx
fn main(): int64 {
  var sum: int64 := 0;
  
  for i := 1 to 10 do {
    sum := sum + i;
  };
  
  PrintInt(sum);  // 55
  return 0;
}
```

#### switch / case

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

---

## Functions

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

---

## Builtins

Over 40 built-in functions are available without import (using PascalCase as of v0.4.3):

#### Basic I/O Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `PrintStr(s)`    | `pchar -> void`        | Outputs string until `\0`           |
| `PrintInt(x)`    | `int64 -> void`        | Outputs integer as decimal          |
| `Print | `f64Float(x)`  -> void`         | Outputs float (simplified)          |
| `Printf(fmt, ...)`| `pchar, ... -> int64` | Formatted output                   |
| `exit(code)`      | `int64 -> void`       | Terminates program with exit code   |

#### Random Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `Random()`        | `void -> int64`        | Returns pseudo-random number (0..2³¹-1) |
| `RandomSeed(s)`   | `int64 -> void`        | Sets seed for LCG                  |

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
| `StrCharAt(s, index)`       | `pchar, int64 -> int64`                    | Reads character at position        |
| `StrCompare(s1, s2)`       | `pchar, pchar -> int64`                    | String comparison (0=equal)        |
| `StrCopy(dest, src)`       | `pchar, pchar -> void`                     | Copies string                      |
| `IntToStr(x)`              | `int64 -> pchar`                           | Converts integer to string         |
| `StrToInt(s)`              | `pchar -> int64`                           | Converts string to integer         |

#### Math Builtins
| Function          | Signature               | Description                        |
|-------------------|------------------------|-------------------------------------|
| `abs(x)`          | `int64 -> int64`       | Absolute value                     |
| `odd(x)`          | `int64 -> bool`        | Checks if odd                      |
| `hi(x)`           | `int64 -> int64`       | High 32 bits                       |
| `lo(x)`           | `int64 -> int64`       | Low 32 bits                        |
| `fabs(x)`         | `f64 -> f64`           | Absolute value (Float)             |
| `sqrt(x)`         | `f64 -> f64`           | Square root                        |
| `sqr(x)`          | `f64 -> f64`           | Square (x²)                        |
| `round(x)`        | `f64 -> int64`         | Rounds to nearest integer          |
| `trunc(x)`        | `f64 -> int64`         | Truncates fractional part          |
| `pi()`            | `void -> f64`          | π constant                         |

---

## External Functions

The Lyx compiler supports declarations of external functions from system libraries:

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

#### Unified Call Path

The compiler correctly distinguishes between three call types:

| Call Type | Description | Codegen |
|-----------|--------------|---------|
| `cmInternal` | Call to function in same unit | `call rel32` (direct) |
| `cmImported` | Call to function from imported unit | `call rel32` (direct) |
| `cmExternal` | Call to external library function | `call __plt_<name>` (PLT/GOT) |

#### Dynamic vs. Static ELF Binaries

The compiler automatically detects whether external symbols are used:

- **Static ELF**: When no external functions are called
- **Dynamic ELF**: Automatically when using external symbols

---

## CLI Arguments

Static ELF binaries support command-line arguments:

```lyx
fn main(argc: int64, argv: pchar): int64 {
  PrintInt(ArgCount());
  PrintStr("\n");
  PrintStr(Arg(0));
  PrintStr("\n");
  return 0;
}
```

- `argc`: Number of arguments (including program name)
- `argv`: Array of argument strings

---

## Standard Library Reference

### std.math - Mathematics

```lyx
import std.math;

fn main(): int64 {
  var abs_val: int64 := Abs64(-42);
  var min_val: int64 := Min64(10, 20);
  var max_val: int64 := Max64(10, 20);
  var sqrt_val: int64 := Sqrt64(144);
  var clamped: int64 := Clamp64(150, 0, 100);  // 100
  var sign: int64 := Sign64(-5);  // -1
  
  // Random
  RandomSeed(42);
  var rand: int64 := RandomRange(100);
  
  // Fixed-point math
  var interpolated: int64 := Lerp64(0, 100, 500);  // 50 (50%)
  
  // Trig (microdegrees)
  var sin_val: int64 := Sin64(90000000);  // sin(90°) = 1.0
  var cos_val: int64 := Cos64(0);
  
  // Bit operations
  var is_even: bool := IsEven(42);
  var popcount: int64 := PopCount(255);  // 8
  
  return 0;
}
```

**Functions:** Abs64, Min64, Max64, Div64, Mod64, TimesTwo, Sqrt64, Clamp64, Sign64, Pow64, Min3, Max3, InRange64, Lerp64, Map64, Hypot64, Sin64, Cos64, IsEven, IsOdd, NextPowerOfTwo, IsPowerOfTwo, PopCount, Log2, RandomRange, RandomBetween, IntSqrt, Atan2Microdegrees, Cos64Inverse

### std.vector - 2D Vectors

```lyx
import std.vector;

fn main(): int64 {
  var v1: Vec2 := Vec2New(10, 20);
  var v2: Vec2 := Vec2New(5, 15);
  
  var sum: Vec2 := Vec2Add(v1, v2);
  var dot: int64 := Vec2Dot(v1, v2);
  var len: int64 := Vec2Length(v1);
  var normalized: Vec2 := Vec2Normalize(v1);
  
  // Rotation (microdegrees)
  var rotated: Vec2 := Vec2Rotate(v1, 90000000);  // 90°
  
  return 0;
}
```

**Types:** Vec2
**Functions:** Vec2New, Vec2Zero, Vec2FromScalar, Vec2Add, Vec2Sub, Vec2Mul, Vec2Div, Vec2Negate, Vec2Dot, Vec2Cross, Vec2LengthSquared, Vec2Length, Vec2DistanceSquared, Vec2Distance, Vec2Normalize, Vec2NormalizeSafe, Vec2Lerp, Vec2Clamp, Vec2Rotate, Vec2Rotate90, Vec2Rotate180, Vec2Rotate270, Vec2Equal, Vec2NotEqual, Vec2IsZero, Vec2Min, Vec2Max, Vec2Abs, Vec2Sign, Vec2Perpendicular, Vec2Project, Vec2Reflect, Vec2AngleTo, Vec2Heading

### std.geo - Geolocation

```lyx
import std.geo;

fn main(): int64 {
  var lat: int64 := ParseLat("52.520008");
  var lon: int64 := ParseLon("13.404954");
  
  if (IsValidLat(lat) && IsValidLon(lon)) {
    var dist: int64 := DistanceM(lat, lon, 48485000, 1130000);
    PrintInt(dist);  // Distance in meters
  };
  
  return 0;
}
```

**Functions:** ParseLat, ParseLon, FormatDecimal, IsValidLat, IsValidLon, DistanceM, DistanceKm, MidpointLat, MidpointLon

### std.color - Colors

```lyx
import std.color;

fn main(): int64 {
  var c: Color := ColorRGB(255, 128, 0);
  var blended: Color := ColorBlend(ColorRed(), ColorBlue());
  var hex: int64 := ColorToHex(c);
  
  var gray: Color := ColorGrayscale(c);
  var bright: Color := ColorBrighten(c, 50);
  
  return 0;
}
```

**Types:** Color
**Functions:** ColorNew, ColorRGB, ColorRGBA, ColorGray, ColorEmpty, ColorOpaque, ColorBlack, ColorWhite, ColorRed, ColorGreen, ColorBlue, ColorYellow, ColorCyan, ColorMagenta, ColorOrange, ColorPurple, ColorPink, ColorBrown, ColorGrayLight, ColorGrayDark, ColorIsOpaque, ColorIsTransparent, ColorIsValid, ColorWithAlpha, ColorWithRed, ColorWithGreen, ColorWithBlue, ColorBlend, ColorMultiply, ColorInvert, ColorGrayscale, ColorBrighten, ColorDarken, ColorSaturate, ColorLerp, ColorMix, ColorEqual, ColorNotEqual, ColorDistance, ColorFromHex, ColorToHex, ColorToHexARGB, ColorFromHSL, ColorToHSL

### std.rect - Rectangles

```lyx
import std.rect;

fn main(): int64 {
  var r: Rect := RectFromXYWH(10, 20, 100, 50);
  var w: int64 := RectWidth(r);
  var h: int64 := RectHeight(r);
  var area: int64 := RectArea(r);
  
  var p: Vec2 := Vec2New(50, 30);
  var contains: bool := RectContains(r, p);
  
  var r2: Rect := RectInflate(r, 10);
  
  return 0;
}
```

**Types:** Rect
**Functions:** RectNew, RectFromPoints, RectFromCenterSize, RectEmpty, RectFromXYWH, RectWidth, RectHeight, RectSize, RectCenter, RectArea, RectIsEmpty, RectIsValid, RectContains, RectContainsInclusive, RectInflate, RectDeflate, RectExpand, RectUnion, RectIntersect, RectIntersects, RectClampPoint, RectClamp, RectDistanceToPoint, RectTopLeft, RectTopRight, RectBottomLeft, RectBottomRight, RectCorners, RectLeft, RectRight, RectTop, RectBottom, RectEqual, RectToArray, RectFromArray

### std.list - Collections

```lyx
import std.list;

fn main(): int64 {
  // Static list (no heap)
  var list: StaticList8 := StaticList8New();
  StaticList8Add(list, 42);
  var val: int64 := StaticList8Get(list, 0);
  
  // Stack (LIFO)
  var stack: StackInt64 := StackInt64New();
  StackInt64Push(stack, 10);
  StackInt64Push(stack, 20);
  var top: int64 := StackInt64Pop(stack);  // 20
  
  // Queue (FIFO)
  var queue: QueueInt64 := QueueInt64New();
  QueueInt64Enqueue(queue, 1);
  QueueInt64Enqueue(queue, 2);
  var first: int64 := QueueInt64Dequeue(queue);  // 1
  
  // Ring buffer for GPS tracking
  var rb: RingBufferVec2 := RingBufferVec2New();
  
  return 0;
}
```

**Types:** StaticList8, StaticList16, Vec2List, RingBufferVec2, StackInt64, QueueInt64
**Functions:** ListInt64New, ListInt64WithCapacity, ListInt64Add, ListInt64Get, ListInt64Set, ListInt64Len, ListInt64Clear, ListInt64IsEmpty, StaticList8New, StaticList8Add, StaticList8Get, StaticList8Set, StaticList8Len, StaticList8Clear, StaticList8IsEmpty, Vec2ListNew, Vec2ListAdd, Vec2ListGet, Vec2ListSet, Vec2ListLen, Vec2ListClear, Vec2ListIsEmpty, Vec2ListLast, Vec2ListFirst, Vec2ListPushBack, Vec2ListPopBack, RingBufferVec2New, RingBufferVec2WithCapacity, RingBufferVec2Push, RingBufferVec2Pop, RingBufferVec2Peek, RingBufferVec2PeekLast, RingBufferVec2Len, RingBufferVec2IsEmpty, RingBufferVec2IsFull, RingBufferVec2Clear, StackInt64New, StackInt64Push, StackInt64Pop, StackInt64Peek, StackInt64IsEmpty, StackInt64IsFull, QueueInt64New, QueueInt64Enqueue, QueueInt64Dequeue, QueueInt64Peek, QueueInt64IsEmpty, QueueInt64IsFull

---

## Complete Examples

### FizzBuzz

```lyx
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
          PrintStr(IntToStr(i));
          PrintStr("\n");
        }
      }
    }
    i := i + 1;
  }
  return 0;
}
```

### Using Standard Library

```lyx
import std.math;
import std.string;

fn analyze_number(x: int64): void {
  PrintStr("Analyzing: ");
  PrintInt(x);
  PrintStr("\n");
  
  PrintStr("Absolute: ");
  PrintInt(Abs64(x));
  PrintStr("\n");
  
  if (IsOdd(x)) {
    PrintStr("Number is odd\n");
  } else {
    PrintStr("Number is even\n");  
  }
  
  var str_val: pchar := IntToStr(Abs64(x));
  var len: int64 := StrLength(str_val);
  
  PrintStr("String: '");
  PrintStr(str_val);
  PrintStr("' (length: ");
  PrintInt(len);
  PrintStr(")\n");
}

fn main(): int64 {
  analyze_number(-42);
  analyze_number(16);
  return 0;
}
```

---

## Build & Test

### Prerequisites

- **FreePascal Compiler** (FPC 3.2.2+)
- **Linux x86_64** (host platform) or cross-compiler for other targets
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
make test           # All unit tests (FPCUnit)
make e2e            # End-to-end smoke tests
```

---

## Compiler Diagnostics & Error Handling

The Lyx compiler provides comprehensive error reporting:

- **SourceSpan**: Every token carries file, line, and column information
- **Parse Errors**: Clear error messages with location
- **Type Errors**: Semantic analysis errors with context
- **Runtime Errors**: `panic()` and `assert()` for runtime validation

### Integrated Linter

Lyx includes a built-in linter as a separate compiler phase (after semantic analysis, before IR lowering):

```bash
# Run linter on file
./lyxc program.lyx --lint

# Lint only (don't compile)
./lyxc program.lyx --lint-only

# Disable linter
./lyxc program.lyx --no-lint
```

**Linter Rules (10 rules):**

| Rule | Code | Description |
|------|------|-------------|
| Unused Variable | W001 | Variable declared but never read |
| Unused Parameter | W002 | Function parameter never read |
| Variable Naming | W003 | Variables should use camelCase |
| Function Naming | W004 | Functions should use PascalCase |
| Constant Naming | W005 | Constants should use PascalCase or UPPER_CASE |
| Unreachable Code | W006 | Code after return statement |
| Empty Block | W007 | Empty blocks `{ }` |
| Shadowed Variable | W008 | Variable shadows outer variable |
| Mutable Never Mutated | W009 | `var` never assigned (should be `let`) |
| Empty Function | W010 | Reserved for future use |

For IDE integration, see `doc/HIGHLIGHTING.md`.

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
  [ Inlining ]      IR-Level Inlining Optimization (v0.4.3)
      |
  [ Peephole ]     Peephole Optimization (v0.5.0)
      |
  [ Backend ]       IR -> Machine code (Bytes)
      |
      +-- [ Linux:   x86_64_emit + elf64_writer ]  -> ELF64 Binary
      |
      +-- [ ARM64:   arm64_emit + elf64_arm64_writer ] -> ELF64 Binary
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
  ir_inlining.pas           IR-Level Inlining (v0.4.3)
backend/
  backend_types.pas         Shared types (External Symbols, Patches)
  x86_64/
    x86_64_emit.pas         x86_64 instruction encoding (Linux/SysV)
    x86_64_win64.pas        Windows x64 emitter (Shadow Space, IAT)
  arm64/
    arm64_emit.pas          ARM64 instruction encoding
  elf/
    elf64_writer.pas        ELF64 binary writer
    elf64_arm64_writer.pas  ARM64 ELF writer
  pe/
    pe64_writer.pas         PE32+ binary writer (DOS/COFF/Optional Header)
util/
  diag.pas                  Diagnostics (errors with line/column)
  bytes.pas                 TByteBuffer (byte encoding + patching)
tests/                      FPCUnit tests
  lyx/                      Lyx test programs (thematic)
examples/                   Curated showcase programs
std/                        Standard library
```

### Design Principles

- **Frontend/Backend Separation**: No x86 code in frontend, no AST nodes in backend.
- **IR as Stability Anchor**: Pipeline is always AST -> IR -> machine code.
- **Platform Abstraction**: Same IR input for Linux, ARM64, and Windows backends.
- **ELF64 without libc**: `_start` calls `main()`, then `sys_exit`. No linking against external libraries.
- **PE32+ with IAT**: Import Address Table for kernel32.dll functions (GetStdHandle, WriteFile, ExitProcess).
- **ARM64 Support**: Native ARM64 binaries using AAPCS64 calling convention.
- **Builtins embedded**: `PrintStr`, `PrintInt`, `PrintFloat`, `strlen` and `exit` are embedded as runtime snippets directly into the binary.
- **Every token carries SourceSpan**: Error messages always include file, line, and column.

---

## Grammar (EBNF)

The complete formal grammar is in [`ebnf.md`](ebnf.md).

```ebnf
Program     := { TopDecl } ;
TopDecl     := FuncDecl | ConDecl | TypeDecl ;
TypeDecl    := 'type' Ident ':=' ( StructType | ClassType | Type ) ';' ;
StructType  := 'struct' '{' { FieldDecl } '}' ;
ClassType   := 'class' [ 'extends' Ident ] '{' { ClassMember } '}' ;
FieldDecl   := Ident ':' Type ';' ;
ConDecl     := 'con' Ident ':' Type ':=' ConstExpr ';' ;
FuncDecl    := 'fn' Ident '(' [ ParamList ] ')' [ ':' RetType ] Block ;
Block       := '{' { Stmt } '}' ;
Stmt        := VarDecl | LetDecl | CoDecl | AssignStmt
             | IfStmt | WhileStmt | ForStmt | SwitchStmt
             | ReturnStmt | ExprStmt | AssertStmt | PanicStmt ;
```

---

## Roadmap

| Version | Features |
|---------|----------|
| **v0.0.1** | `PrintStr("...")`, `exit(n)`, ELF64 runs |
| **v0.0.2** | Integer expressions, `PrintInt(expr)` |
| **v0.1.2** | `var`, `let`, `co`, `con`, `if`, `while`, `return`, functions, SysV ABI |
| **v0.1.3** | ✅ Float literals (`f32`, `f64`), ✅ Arrays (literals, indexing, assignment) |
| **v0.1.4** | ✅ Module System, ✅ Dynamic ELF, ✅ PLT/GOT, ✅ Extern Functions, ✅ Varargs |
| **v0.1.5** | ✅ String-Library, ✅ Math-Builtins, ✅ Type-Casting (`as`) |
| **v0.1.6** | ✅ Struct literals, ✅ Instance methods with `self`, ✅ Static methods, ✅ Field assignment |
| **v0.1.7** | ✅ OOP: Classes with inheritance, ✅ `new`/`dispose`, ✅ Global variables, ✅ Random builtins |
| **v0.1.8** | ✅ Windows x64 Backend: PE32+ binary generation, ✅ Cross-Compilation |
| **v0.2.0** | ✅ Unified Call Path, ✅ Cross-Unit Function Resolution, ✅ CLI Flags |
| **v0.2.1** | ✅ Dynamic Arrays (heap-allocated, push/pop/len/free) |
| **v0.2.2** | ✅ SIMD / ParallelArray |
| **v0.3.0** | ✅ std.io: fd-based I/O via syscalls |
| **v0.3.1** | ✅ std.fs: stat, mkdir, unlink, rename |
| **v0.3.2** | ✅ Directories: getdents64, panic/assert |
| **v0.4.0** | ✅ Nullable Types (pchar?), ✅ CLI Arguments |
| **v0.4.1** | ✅ Access Control (pub/private/protected) |
| **v0.4.2** | ✅ Regex Literals, ✅ Namespaces, ✅ Panic & Assert |
| **v0.4.3** | ✅ IR-Level Inlining, ✅ PascalCase Naming Conventions, ✅ Integrated Linter |
| **v0.5.0** | ✅ **Peephole Optimizer**: Constant folding, identity ops, redundant moves, compare-with-zero simplification |
| **v1.0.0** | Stable systems language |

---

## License

Copyright (c) 2026 Andreas Röne. All rights reserved.
