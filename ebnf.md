# Lyx v0.2.0 – Sprachspezifikation

Ziel: Minimaler, nativer Compiler für **Linux x86_64 (ELF64)**, erweiterbar durch saubere Trennung von Frontend/IR/Backend.

---

## 1) Lexikalische Regeln

### Whitespace

* Leerzeichen, Tabs, Zeilenumbrüche trennen Tokens.

### Kommentare

* Zeilenkommentar: `//` bis Zeilenende
* Blockkommentar (optional, empfohlen): `/* ... */` (nicht verschachtelt)

### Identifier

* Regex: `[A-Za-z_][A-Za-z0-9_]*`
* case-sensitive

### Literale

* **Int64**: Dezimal: `0` oder `[1-9][0-9]*` (optional führendes `-` als unary operator)
* **Float64**: `[0-9]+ '.' [0-9]+` (z.B. `3.14159`, `2.718`)
* **Stringliteral**: `" ... "` mit Escapes:

    * `\n`, `\r`, `\t`, `\\`, `\"`, `\0`
    * Ergebnis ist **nullterminiert** im `.rodata`

### Keywords (reserviert)

`fn var let co con if else while for to downto do repeat until switch case break default return true false null extern unit import pub as array struct class extends new dispose super static self Self private protected panic assert where value`

### Integer-Literale mit verschiedenen Basen

Lyx unterstützt Integer-Literale in verschiedenen Zahlenbasen:

```
IntLiteral    := DecimalLiteral | HexLiteral | BinaryLiteral | OctalLiteral ;
DecimalLiteral := [0-9] { [0-9_] } ;
HexLiteral     := ( '0x' | '0X' | '$' ) [0-9a-fA-F_] { [0-9a-fA-F_] } ;
BinaryLiteral  := ( '0b' | '0B' | '%' ) [01_] { [01_] } ;
OctalLiteral   := ( '0o' | '0o' | '&' ) [0-7_] { [0-7_] } ;
```

Unterstriche (`_`) können als Trenner zur Lesbarkeit verwendet werden.

**Beispiele:**
```
42           // Dezimal
0xFF, $FF   // Hexadezimal (255)
0b1010, %1010 // Binär (10)
0o77, &77    // Oktal (63)
1_000_000    // Mit Unterstrich
0b1100_1010  // Binär mit Unterstrich (202)
```

Alle Integer-Literale werden intern als `int64` behandelt.

### Operatoren / Trennzeichen

* Zuweisung: `:=`
* Arithmetik: `+ - * / %`
* **String-Verkettung**: `+` (bei pchar + pchar)
* Vergleich: `== != < <= > >=`
* Logik: `&& || !`
* Bitweise: `& | ^ ~ << >>`
* Null-Safety: `? ?? ?.`
* Pipe: `|>`
* Sonstiges: `(` `)` `{` `}` `:` `,` `;` `.` `@`

---

## Energy-Aware-Compiling (v0.3.1+ ✅ ABGESCHLOSSEN)

### @energy Pragma

Funktionen können mit einem Energy-Level kompiliert werden:

```
EnergyAttr = "@energy" "(" IntLiteral ")"
FnDecl = [ EnergyAttr ] "fn" Ident "(" [ ParamList ] ")" [ ":" Type ] Block
```

Beispiele:
```lyx
@energy(1)
fn low_power_mode(): int64 {
  // Kompiliert mit Energy-Level 1 (minimal)
  return 0;
}

@energy(5)
fn high_performance(): int64 {
  // Kompiliert mit Energy-Level 5 (extrem)
  return compute();
}
```

### Energy-Levels

| Level | Name | Loop Unroll | Battery | SIMD | FPU |
|-------|------|-------------|---------|------|-----|
| 1 | Minimal | 4× | ✅ | — | — |
| 2 | Low | 2× | ✅ | — | — |
| 3 | Medium | 1× | ✅ | ✅ | — |
| 4 | High | — | ✅ | ✅ | ✅ |
| 5 | Extreme | 8× | ✅ | ✅ | ✅ |

---

## 2) Typen

### Primitive Typen

* `int64`  (signed 64-bit, bestehender Haupttyp)
* `int8`, `int16`, `int32`, `int64`  (signed Integer-Familie, Kurzform: **int**)
* `uint8`, `uint16`, `uint32`, `uint64`  (unsigned Integer-Familie, Kurzform: **uint**)
* `f32`, `f64`  (Floating-Point Typen: 32-bit und 64-bit)
* `bool`   (`true` / `false`)
* `void`   (nur als Funktionsrückgabetyp)
* `pchar`  (Pointer, 64-bit; non-nullable, Standard für Stringliterale)
* `pchar?` (Nullable Pointer, kann `null` sein)
* `array`  (Array-Typ für Stack-allokierte Arrays)
* `parallel Array<T>` (SIMD-optimiertes, heap-allokiertes Array mit Element-Typ T; ✅ v0.2.2)
* `Map<K, V>` (Hash-Map mit Key-Typ K und Value-Typ V; v0.5.0)
* `Set<T>` (Hash-Set mit Element-Typ T; v0.5.0)

### SIMD / ParallelArray (v0.2.2 ✅ ABGESCHLOSSEN)

ParallelArrays sind heap-allokierte, SIMD-optimierte Arrays mit einem festen Element-Typ:

```lyx
var vec: parallel Array<Int64> := parallel Array<Int64>(1000);
var first: int64 := vec[0];       // Skalar-Rückgabe
vec[0] := 42;                      // Element-Zuweisung
var sum: parallel Array<Int64> := vec + vec;  // element-weise SIMD-Op
```

**Element-Typen**: `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `F32`, `F64`

**SIMD-Operatoren** (element-weise): `+`, `-`, `*`, `/`, `&&`, `||`, `^`, `==`, `!=`, `<`, `<=`, `>`, `>=`

**Speichermodell**:
- Heap-allokiert via `irAlloc`/mmap mit 16-Byte-Alignment (SSE2)
- Gespeichert als einzelner Pointer-Slot im Stack-Frame
- Index-Zugriff gibt einen Skalar des Element-Typs zurück

### Nullable Typen (v0.4.0 ✅ ABGESCHLOSSEN)

### Panic und Assert (v0.3.2 ✅ ABGESCHLOSSEN)

### Map und Set (v0.5.0 ✅ ABGESCHLOSSEN)

Maps und Sets sind heap-allokierte assoziative Datenstrukturen mit linearer Suche (O(n) Lookup).

**Grammatik:**
```
MapType       := 'Map' '<' Type ',' Type '>' ;
SetType       := 'Set' '<' Type '>' ;
MapLiteral    := '{' [ MapEntry { ',' MapEntry } ] '}' ;
SetLiteral    := '{' Expr { ',' Expr } '}' ;
MapEntry      := Expr ':' Expr ;
InExpr        := Expr 'in' Expr ;
MapIndexExpr  := Expr '[' Expr ']' ;
MapIndexAssign := Expr '[' Expr ']' ':=' Expr ;
```

**Map-Literal (Key-Value-Paare mit Doppelpunkt):**
```lyx
var scores: Map<int64, int64> := {1: 100, 2: 200, 3: 300};
var empty: Map<int64, int64> := {};
```

**Set-Literal (Werte ohne Doppelpunkt):**
```lyx
var ids: Set<int64> := {10, 20, 30};
```

**Implementierte Operationen:**

| Operation | Syntax | Beschreibung |
|-----------|--------|--------------|
| Insert/Update | `map[key] := value` | Setzt oder überschreibt Key |
| Get | `map[key]` | Gibt Value zurück |
| Contains | `key in map` | Prüft Existenz (bool) |
| Size | `len(map)` | Anzahl Einträge |
| Set Add | via Literal | Erstellt Set mit Werten |
| Set Contains | `value in set` | Prüft Mitgliedschaft (bool) |

**Erlaubte Key/Element-Typen:** `int64`, `bool` (aktuell)
**Value-Typen (Map):** `int64` (aktuell)

**Speichermodell:**
- Heap-allokiert via `mmap` syscall
- Layout: `[len:8 bytes][cap:8 bytes][entries:16*cap bytes]`
- Entry-Format: `[key:8 bytes][value:8 bytes]`
- Lineare Suche O(n) — geeignet für kleine Sammlungen (< 100 Einträge)
- Initiale Kapazität: 8 Entries

**IR-Opcodes:**
- `irMapNew`, `irMapSet`, `irMapGet`, `irMapContains`, `irMapLen`
- `irSetNew`, `irSetAdd`, `irSetContains`, `irSetLen`

**Nicht implementiert (geplant):**
- `remove()` — Löschen von Einträgen
- `keys()` / `values()` — Iteratoren
- `for key, value in map` — Iteration
- Hash-basierter O(1) Lookup mit FNV-1a

### Regex-Literale (v0.4.2 ✅ ABGESCHLOSSEN)

### Inkrement- und Dekrement-Operatoren (✅ ABGESCHLOSSEN)

Die Operatoren `++` und `--` sind als **Postfix-Statements** verfügbar:

```
IncDecStmt      := LValue ( '++' | '--' ) ';' ;
LValue          := Ident { FieldOrIndexSuffix } ;
FieldOrIndexSuffix
                := '.' Ident
                | '[' Expr ']' ;
```

**Desugaring:**
- `x++` wird zu `x := x + 1`
- `x--` wird zu `x := x - 1`

**Beispiele:**
```lyx
counter++;           // counter := counter + 1
arr[idx]++;          // arr[idx] := arr[idx] + 1
player.health--;     // player.health := player.health - 1
```

**Wichtig:** Dies sind Statements, keine Expressions. Sie können nicht in Ausdrücken verwendet werden.

### Return-Regeln

* Funktion mit Rückgabetyp `int64/bool/pchar/f64` muss auf allen Pfaden `return <expr>;` liefern
* Funktion mit `void` erlaubt `return;` oder gar keinen return (dann implizit `return;`)

### Type-Casting Regeln

* `as`-Casting ist explizit und erlaubt folgende Konvertierungen:
  * `int64 as f64`: Integer zu Float (SSE2 cvtsi2sd)
  * `f64 as int64`: Float zu Integer mit Truncation (SSE2 cvttsd2si)
  * Identity Casts: `int64 as int64`, `f64 as f64` (No-Op)
* Cast-Kompatibilität wird zur Compile-Zeit geprüft
* Ungültige Casts erzeugen Compile-Fehler

### Bool-Regeln

* `if`/`while` verlangen `bool`
* `&&`/`||` short-circuit (Codegen muss Sprünge setzen)

### Builtin-Funktionen Regeln

* Über 30 Builtin-Funktionen sind ohne Import verfügbar
* Builtins werden nicht als externe Symbole behandelt (statische ELF-Generation)
* String-Builtins arbeiten mit null-terminierten pchar
* Math-Builtins nutzen native x86-64 Instruktionen für maximale Performance

---

## 8) Codegen-Anforderungen (Backend v0.1.7)

### Output

* ELF64 Executable, Linux x86_64
* `_start` als Entry
* Automatische Static/Dynamic ELF Auswahl

### Minimaler Instruction-Satz (Backend-Emitter)

* `mov reg, imm64`
* `mov reg, [rbp-off]` / `mov [rbp-off], reg` (locals)
* `lea reg, [rip+disp32]` (globale Variablen, RIP-relative Adressierung)
* `add/sub/imul/idiv` (int64 arith)
* `cmp` + `setcc`/`cmov` oder Sprünge (bool)
* `jmp`, `je/jne/jl/jle/jg/jge` (control flow)
* `call`, `ret` (Funktionen)
* `syscall` (builtins/entry)

### Heap-Speicher (Klassen)

* `new`: `mmap` syscall für Allokation
* `dispose`: `munmap` syscall für Freigabe
* VTable für virtuelle Methoden (in Planung)

### Runtime-Snippets (eingebettet)

* `PrintStr`: strlen-loop + write
* `PrintInt`: itoa + write
* `Random`: LCG-Implementierung (seed * 1103515245 + 12345) mod 2^31
* `RandomSeed`: Setzt LCG-Seed im Data-Segment

---

## 9) Beispiele

### Hello

```lyx
fn main(): int64 {
  PrintStr("Hello Lyx\n");
  return 0;
}
```

### Globale Variablen

```lyx
var counter: int64 := 0;

fn increment() {
  counter := counter + 1;
}

fn main(): int64 {
  PrintInt(counter);  // 0
  increment();
  increment();
  PrintInt(counter);  // 2
  return 0;
}
```

### Klassen mit Vererbung

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
  dispose d;
  return 0;
}
```

### Random

```lyx
fn main(): int64 {
  RandomSeed(42);
  
  var r1: int64 := Random();
  var r2: int64 := Random();
  
  PrintInt(r1);
  PrintStr("\n");
  PrintInt(r2);
  return 0;
}
```

### Bitweise Operatoren

```lyx
fn main(): int64 {
  var a: int64 := 12;
  var b: int64 := 10;

  PrintInt(a & b);    // AND:  8
  PrintInt(a | b);    // OR:  14
  PrintInt(a ^ b);    // XOR:  6
  PrintInt(1 << 4);   // SHL: 16
  PrintInt(256 >> 3); // SHR: 32
  PrintInt(~0);       // NOT: -1

  // Kombination: Mask-and-Shift
  var flags: int64 := (5 << 4) | 3;  // = 83
  PrintInt(flags);

  return 0;
}
```

**Präzedenz** (niedrig → hoch): `||` → `&&` → `|` → `^` → `&` → Vergleich → `<< >>` → `+ -` → `* / %` → Unär (`! - ~`)

### Variablen + while + Type-Casting

```lyx
con LIMIT: int64 := 5;

fn main(): int64 {
  var i: int64 := 0;
  while (i < LIMIT) {
    PrintInt(i);
    PrintStr("\n");
    
    // Type-Casting Beispiel
    var f: f64 := i as f64;
    var sqrt_val: f64 := sqrt(f);
    var back_to_int: int64 := sqrt_val as int64;
    
    // String-Konvertierung
    var str_val: pchar := int_to_str(i);
    PrintStr("String: ");
    PrintStr(str_val);
    PrintStr("\n");
    
    i := i + 1;
  }
  return 0;
}
```

### Module-System Beispiel

```lyx
unit math.utils;

import std.string;

pub fn factorial(n: int64): int64 {
  if (n <= 1) { return 1; }
  return n * factorial(n - 1);
}

pub fn format_number(x: int64): pchar {
  return int_to_str(abs(x));
}
```

... (rest unchanged)

Diese Erweiterung passt zu Lyxs Pascal-ähnlichem Stil, erweitert um AI/ML-Features aus Sever/A.[web:21][page:0] Der Parser braucht ~10 neue Regeln; Codegen kann LLVM/CUDA-Backend nutzen für GPU (z. B. via FFI zu cuBLAS).[cite:15]

## Implementierungs-Hinweise
- **Tensor-Codegen**: Compiler erzeugt CUDA-Kernels; Fallback zu CPU via OpenBLAS.
- **Probabilistic**: Zero-Cost Abstractions – option/result als Tagged Unions (1 Byte Discriminant).
- **GPU-Setup**: Built-in `@gpu` triggert Linker-Flags (-lcudart); für Linux/RTX3060.[cite:12]
- **Nächster Schritt**: Vollständige EBNF-Datei oder Parser-Test in Rust/Lark generieren?
