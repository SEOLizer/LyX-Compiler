# Lyx

**Lyx** ist ein nativer Compiler für die gleichnamige Programmiersprache, geschrieben in FreePascal.
Er erzeugt direkt ausführbare **Linux x86_64 ELF64-** und **Windows x64 PE32+-Binaries** — ohne libc, ohne Linker, rein über Syscalls bzw. WinAPI.

```
Lyx Compiler v0.1.7
Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.

✅ Vollständiges Module System mit Import/Export
✅ Cross-Unit Function Calls und Symbol Resolution  
✅ Standard Library (std.math, std.io, std.string)
✅ Robuste Parser mit While/If/Function Support
✅ OOP: Classes, Vererbung, Konstruktoren, Destruktoren
✅ Globale Variablen mit Initialisierung
✅ Random/RandomSeed Builtins
✅ Cross-Compilation: Linux ELF64 und Windows PE32+
```

---

## Schnellstart

```bash
# Compiler bauen
make build

# Linux-Programm kompilieren und ausführen
./lyxc examples/hello.lyx -o hello
./hello

# Windows-Programm cross-kompilieren
./lyxc examples/hello.lyx -o hello.exe --target=win64
```

```
Hello Lyx
```

### Cross-Compilation

Lyx unterstützt **Cross-Compilation** zwischen Linux und Windows:

```bash
# Linux ELF64 (Standard auf Linux-Hosts)
./lyxc program.lyx -o program --target=linux

# Windows PE32+ (von Linux aus)
./lyxc program.lyx -o program.exe --target=win64
```

| Zielplattform | Format | Calling Convention | OS-Interface |
|---------------|--------|-------------------|--------------|
| `linux` | ELF64 | SysV ABI (RDI, RSI, RDX, RCX, R8, R9) | Syscalls |
| `win64` | PE32+ | Windows x64 (RCX, RDX, R8, R9 + Shadow Space) | kernel32.dll |

**Hinweis:** Der `--target`-Parameter ist optional. Der Compiler wählt automatisch das Host-Betriebssystem als Ziel.

---

## Die Sprache Lyx

Lyx ist **prozedural** und **statisch typisiert** — inspiriert von C und Rust, mit einer eigenen, kompakten Syntax.

### Hello World

```lyx
fn main(): int64 {
  PrintStr("Hello Lyx\n");
  return 0;
}
```

### Variablen und Arithmetik

Vier Speicherklassen steuern Veränderbarkeit und Lebensdauer:

```lyx
fn main(): int64 {
  var x: int64 := 10;       // mutable
  let y: int64 := 20;       // immutable nach Init
  co  z: int64 := x + y;    // readonly (Runtime-Konstante)

  x := x + 1;               // erlaubt: var ist mutable
  // y := 0;                 // verboten: let ist immutable

  PrintInt(x + y + z);
  PrintStr("\n");
  return 0;
}
```

| Keyword | Veränderbar | Compilezeit | Speicher |
|---------|:-----------:|:-----------:|----------|
| `var`   | ja          | —           | Stack/Data (global) |
| `let`   | nein        | —           | Stack/Data (global) |
| `co`    | nein        | optional    | Stack    |
| `con`   | nein        | ja          | Immediate / rodata |

### Globale Variablen

`var` und `let` können auch auf Top-Level deklariert werden. Diese werden im Data-Segment gespeichert und sind global sichtbar:

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

Globale Variablen:
- werden im Data-Segment gespeichert (nicht auf dem Stack)
- können mit konstanten Integer-Werten initialisiert werden
- sind in allen Funktionen sichtbar
- können `pub` für exportiert werden

### Compile-Time-Konstanten

`con`-Deklarationen existieren auf Top-Level und werden zur Compilezeit aufgelöst — kein Stackslot, direkt als Immediate eingebettet:

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

### Module System und Standard Library

Lyx unterstützt ein vollständiges **Import/Export-System** für die Organisation von Code in wiederverwendbare Module:

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

**Verfügbare Standard Library:**
- `std.math`: Mathematische Funktionen (`Abs64`, `Min64`, `Max64`, `TimesTwo`)
- `std.io`: I/O Funktionen (`print`, `PrintLn`, `PrintIntLn`, `ExitProc`)
- `std.string`: Umfassende String-Manipulation (`StrLength`, `StrCharAt`, `StrFind`, `StrToLower`, etc.)
- `std.env`: Environment-API (`ArgCount`, `Arg`, `init`)
- `std.time`: Datums- und Zeit-Funktionen (numerische Berechnungen)
- `std.geo`: Geolocation-Parser für Decimal Degrees

### Typen

| Typ       | Beschreibung                          |
|-----------|---------------------------------------|
| `int64`   | Signed 64-bit Integer                 |
| `int`     | Alias für `int64` (konventionell)     |
| `f32`     | 32-bit Floating-Point (IEEE 754)      |
| `f64`     | 64-bit Floating-Point (IEEE 754)      |
| `bool`    | `true` / `false`                      |
| `void`    | Nur als Funktions-Rückgabetyp         |
| `pchar`   | Pointer auf nullterminierte Bytes     |
| `string`  | Alias für `pchar` (nullterminierte Bytes)
| `array`   | Array-Typ (Stack-allokiert)           |
| `struct`  | Benutzerdefinierter Record-Typ        |

Hinweis: `int` und `string` sind derzeit Alias-Typen (bzw. Abkürzungen) — `int` wird intern als `int64` behandelt, `string` wird als `pchar` gemappt. Keine impliziten Casts — alle Typen müssen explizit übereinstimmen.

### Float-Literale

Float-Literale werden mit Dezimalpunkt geschrieben und sind vom Typ `f64`:

```lyx
fn main(): int64 {
  var pi: f64 := 3.14159;
  var e: f64 := 2.71828;

  // Float-Konstanten auf Top-Level
  con PI: f64 := 3.1415926535;

  return 0;
}
```

### Arrays

Arrays werden auf dem Stack allokiert und können literale Initialisierung, Lesezugriff und Zuweisung:

```lyx
fn main(): int64 {
  // Array-Literal
  var arr: array := [10, 20, 30];

  // Element lesen
  var first: int64 := arr[0];    // 10

  // Element zuweisen
  arr[0] := 100;

  // Dynamischer Index
  var i: int64 := 1;
  var second: int64 := arr[i];   // 20

  return 0;
}
```

Alle Elemente eines Arrays müssen denselben Typ haben (derzeit `int64`).

### Structs (Records)

Structs werden mit `type Name = struct { ... };` definiert und mit `TypeName { field: value, ... }` instanziiert:

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
  // Struct-Literal mit Feldinitialisierung
  var p: Point := Point { x: 10, y: 20 };

  // Feldzugriff mit Punkt-Notation
  PrintInt(p.x);        // 10
  PrintInt(p.y);        // 20

  // Feldzuweisung
  p.x := 42;
  PrintInt(p.x);        // 42

  // Structs in Ausdrücken
  var sum: int64 := p.x + p.y;  // 62

  // Größere Structs
  var r: Rect := Rect { left: 0, top: 0, right: 100, bottom: 50 };
  var width: int64 := r.right - r.left;   // 100

  return 0;
}
```

Structs werden auf dem Stack allokiert (8 Bytes pro Feld). Der Zugriff erfolgt direkt über Offset-Berechnung.

#### Instanz-Methoden und `self`

Structs können Methoden enthalten, die über `self` auf die Instanz zugreifen:

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
  c.increment();     // count ist jetzt 11
  return c.get();    // gibt 11 zurück
}
```

**Wichtig:**
- `self` ist automatisch in Instanz-Methoden verfügbar
- `self` ist ein Pointer auf die Struct-Instanz
- Methoden werden intern als `_L_<Struct>_<Method>(self, ...)` gemangled

#### Statische Methoden mit `static`

Statische Methoden haben keinen `self`-Parameter und werden mit `Type.method()` aufgerufen:

```lyx
type Math = struct {
  dummy: int64;   // Platzhalter-Feld
  
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

**Statische Methoden:**
- Werden mit `static fn` deklariert
- Haben keinen impliziten `self`-Parameter
- Werden mit `TypeName.method()` aufgerufen
- Nützlich für Utility-Funktionen und "Konstruktoren"

#### Der `Self`-Typ

In Methoden kann `Self` als Rückgabetyp verwendet werden (wird zum Struct-Typ aufgelöst):

```lyx
type Point = struct {
  x: int64;
  y: int64;
  
  static fn origin(): Self {
    return Point { x: 0, y: 0 };
  }
};
```

**Hinweis:** Struct-Rückgabe by-value ist noch eingeschränkt. Aktuell können statische Methoden primitive Typen zurückgeben, aber keine Structs.

### Klassen (Classes) mit Vererbung

Lyx unterstützt OOP mit Klassen, Vererbung, Konstruktoren und Destruktoren:

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
  dispose d;              // Ruft Destroy() auf
  return 0;
}
```

**Klassen-Features:**
- `class extends BaseClass` für Vererbung
- `new ClassName()` für Heap-Allokation
- `new ClassName(args)` ruft Konstruktor `Create` auf
- `dispose expr` ruft `Destroy()` auf und gibt Speicher frei
- `super.method()` für Aufruf der Basisklassen-Methode
- Heap-allokiert (im Gegensatz zu Stack-allokierten Structs)

### Operatoren

| Priorität | Operatoren           | Beschreibung              |
|:---------:|----------------------|---------------------------|
| 1 (niedrig) | `\|>`            | Pipe (Funktionsverkettung) |
| 2         | `||`                 | Logisches Oder            |
| 3         | `&&`                 | Logisches Und             |
| 4         | `==` `!=` `<` `<=` `>` `>=` | Vergleich (liefert `bool`) |
| 5         | `+` `-`              | Addition, Subtraktion     |
| 6         | `*` `/` `%`          | Multiplikation, Division, Modulo |
| 7 (hoch)  | `!` `-` (unär)       | Logisches NOT, Negation   |
| 8         | `as`                 | Type-Casting              |

Zuweisung erfolgt mit `:=` (nicht `=`).

### Inkrement- und Dekrement-Operatoren

Die Operatoren `++` und `--` sind als **Postfix-Statements** verfügbar:

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

**Unterstützte Formen:**
- `ident++` / `ident--` - Variable inkrementieren/dekrementieren
- `obj.field++` / `obj.field--` - Feld inkrementieren/dekrementieren
- `arr[idx]++` / `arr[idx]--` - Array-Element inkrementieren/dekrementieren

**Hinweis:** Dies sind Statement-Formen (keine Expressions). Sie liefern keinen Wert zurück.

### Pipe-Operator `|>`

Der Pipe-Operator ermöglicht das Verketten von Funktionen in der Reihenfolge des Datenflusses (von links nach rechts):

```lyx
fn double(x: int64): int64 { return x * 2; }
fn addOne(x: int64): int64 { return x + 1; }

fn main(): int64 {
  var x: int64 := 5;
  
  // Neu: Pipe-Operator (lesbar von links nach rechts)
  var result: int64 := x |> double() |> addOne();
  
  // Äquivalent zur klassischen Schreibweise:
  // var result: int64 := addOne(double(x));
  
  PrintInt(result);  // 11
  return 0;
}
```

**Mit zusätzlichen Argumenten:**

```lyx
fn add(a: int64, b: int64): int64 { return a + b; }

fn main(): int64 {
  var x: int64 := 10;
  
  // x wird als erstes Argument eingefügt
  var result: int64 := x |> add(5);  // äquivalent zu add(x, 5)
  
  PrintInt(result);  // 15
  return 0;
}
```

**Vorteile:**
- Bessere Lesbarkeit: Code liest sich wie der Datenfluss
- Vermeidet tiefe Schachtelung
- Einfacheres Debugging durch klare Reihenfolge

### Type-Casting mit `as`

Lyx unterstützt explizite Type-Casts mit der `as`-Syntax:

```lyx
fn main(): int64 {
  var x: int64 := 42;
  var f: f64 := x as f64;      // int64 -> f64 Konvertierung
  var back: int64 := f as int64; // f64 -> int64 Konvertierung
  
  // String-Konvertierungen
  var s: pchar := IntToStr(x);
  var parsed: int64 := str_to_int(s);
  
  PrintInt(parsed);  // 42
  return 0;
}
```

**Unterstützte Casts:**
- `int64 as f64`: Integer zu Float (SSE2 cvtsi2sd)
- `f64 as int64`: Float zu Integer mit Truncation (SSE2 cvttsd2si)
- Identity Casts: `int64 as int64`, `f64 as f64`
- String-Konvertierungen über Builtin-Funktionen

### Kontrollfluss

#### if / else

```lyx
fn main(): int64 {
  var x: int64 := 42;
  if (x > 10) {
    PrintStr("gross\n");
  } else {
    PrintStr("klein\n");
  }
  return 0;
}
```

#### while-Schleife

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

#### Bool-Ausdrücke als Bedingung

```lyx
fn main(): int64 {
  var active: bool := true;
  if (active)
    PrintStr("aktiv\n");
  return 0;
}
```

#### switch / case

switch/case wurde ergänzt und unterstützt nun fallweise sowohl Block‑Bodies als auch einzelne Statements. `break` beendet die nächsthöhere Schleife oder den aktuellen switch‑Fall.

Beispiel (Block‑Bodies):

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

Beispiel (Single‑Statement‑Bodies):

```lyx
switch (n) {
  case 0: PrintStr("zero\n");
  case 1: PrintStr("one\n");
  default: PrintStr("many\n");
}
```

Hinweis: `case`‑Labels müssen momentan Ganzzahlen (int/int64) sein; Semantik und Codegen behandeln `int` als 64‑Bit.
### Funktionen

Funktionen sind global, folgen der SysV ABI (Parameter in Registern) und unterstützen bis zu 6 Parameter:

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

Funktionen ohne Rückgabetyp sind implizit `void`:

```lyx
fn greet() {
  PrintStr("Hallo!\n");
}

fn main(): int64 {
  greet();
  return 0;
}
```

### Builtins

Über 30 eingebaute Funktionen stehen ohne Import zur Verfügung:

#### Basis I/O Builtins
| Funktion          | Signatur               | Beschreibung                        |
|-------------------|------------------------|-------------------------------------|
| `PrintStr(s)`    | `pchar -> void`        | Gibt String bis `\0` aus            |
| `PrintInt(x)`    | `int64 -> void`        | Gibt Integer als Dezimalzahl aus    |
| `PrintFloat(x)`  | `f64 -> void`          | Gibt Float aus (vereinfacht)        |
| `exit(code)`      | `int64 -> void`        | Beendet das Programm mit Exit-Code  |

#### Random Builtins
| Funktion          | Signatur               | Beschreibung                        |
|-------------------|------------------------|-------------------------------------|
| `Random()`        | `void -> int64`        | Liefert Pseudo-Zufallszahl (0..2³¹-1) |
| `RandomSeed(s)`   | `int64 -> void`        | Setzt den Seed für den LCG          |

Beispiel:
```lyx
fn main(): int64 {
  RandomSeed(42);           // Seed setzen
  
  var r1: int64 := Random();  // Zufallszahl
  var r2: int64 := Random();  // Weitere Zufallszahl
  
  PrintInt(r1);
  PrintStr("\n");
  PrintInt(r2);
  return 0;
}
```

#### String-Manipulation Builtins
| Funktion                    | Signatur                                    | Beschreibung                        |
|-----------------------------|---------------------------------------------|-------------------------------------|
| `StrLength(s)`             | `pchar -> int64`                           | Berechnet String-Länge              |
| `str_char_at(s, index)`     | `pchar, int64 -> int64`                    | Liest Character an Position         |
| `str_set_char(s, index, c)` | `pchar, int64, int64 -> void`             | Setzt Character an Position         |
| `StrCompare(s1, s2)`       | `pchar, pchar -> int64`                   | String-Vergleich (0=gleich)         |
| `str_copy_builtin(dest, src)` | `pchar, pchar -> void`                   | Kopiert String                      |

#### String-Konvertierung Builtins
| Funktion          | Signatur               | Beschreibung                        |
|-------------------|------------------------|-------------------------------------|
| `IntToStr(x)`   | `int64 -> pchar`       | Konvertiert Integer zu String       |
| `str_to_int(s)`   | `pchar -> int64`       | Konvertiert String zu Integer       |

#### Math Builtins (22 Funktionen)
| Funktion          | Signatur               | Beschreibung                        |
|-------------------|------------------------|-------------------------------------|
| `abs(x)`          | `int64 -> int64`       | Absoluter Wert                      |
| `odd(x)`          | `int64 -> bool`        | Prüft ob ungerade                   |
| `hi(x)`           | `int64 -> int64`       | Hohe 32 Bits                        |
| `lo(x)`           | `int64 -> int64`       | Niedrige 32 Bits                    |
| `swap(x)`         | `int64 -> int64`       | Vertauscht 32-Bit Words             |
| `fabs(x)`         | `f64 -> f64`           | Absoluter Wert (Float)              |
| `sqrt(x)`         | `f64 -> f64`           | Quadratwurzel                       |
| `sqr(x)`          | `f64 -> f64`           | Quadrat (x²)                        |
| `round(x)`        | `f64 -> int64`         | Rundet zur nächsten Ganzzahl       |
| `trunc(x)`        | `f64 -> int64`         | Schneidet Nachkommastellen ab      |
| `IntPart(x)`     | `f64 -> int64`         | Alias für `trunc()`                 |
| `frac(x)`         | `f64 -> f64`           | Nachkommateil                       |
| `pi()`            | `void -> f64`          | π-Konstante                         |
| `sin(x)`, `cos(x)`, `exp(x)`, `ln(x)`, `arctan(x)` | `f64 -> f64` | Transzendente Funktionen (Placeholder) |

### Externe Funktionen (v0.1.5+)

Der Lyx-Compiler unterstützt jetzt Deklarationen externer Funktionen aus System-Libraries:

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

#### Varargs-Unterstützung

Externe Funktionen können variable Argumentlisten mit `...` deklarieren:

```lyx
extern fn printf(fmt: pchar, ...): int64;

fn main(): int64 {
  printf("Int: %d, String: %s, Float: %f\n", 42, "test", 3.14);
  return 0;
}
```

#### Dynamische vs. Statische ELF-Binaries

Der Compiler erkennt automatisch, ob externe Symbole verwendet werden:

- **Statische ELF**: Wenn keine externen Funktionen aufgerufen werden
- **Dynamische ELF**: Automatisch bei Verwendung externer Symbole

```bash
# Statisches Binary (keine externen Aufrufe)
./lyxc hello.lyx -o hello_static
# Output: "Generating static ELF (no external symbols)"

# Dynamisches Binary (mit malloc/printf)
./lyxc extern_example.lyx -o extern_dynamic  
# Output: "Generating dynamic ELF with 2 external symbols"
```

#### Library-Zuordnung

Der Compiler ordnet Symbole automatisch den passenden Libraries zu:

| Symbol | Library |
|--------|---------|
| `printf`, `malloc`, `strlen`, `exit` | `libc.so.6` |
| `sin`, `cos`, `sqrt` | `libm.so.6` |
| Unbekannte Symbole | `libc.so.6` (Fallback) |

#### PLT/GOT-Mechanik

Dynamische Binaries nutzen die **Procedure Linkage Table (PLT)** und **Global Offset Table (GOT)**:

- **PLT-Stubs**: Jede externe Funktion erhält einen PLT-Eintrag
- **GOT-Entries**: Enthalten Runtime-Adressen der Library-Funktionen
- **Relocations**: Dynamic Linker patcht GOT zur Laufzeit

```bash
# ELF-Struktur analysieren
readelf -l extern_binary    # PT_INTERP, PT_DYNAMIC Headers
readelf -d extern_binary    # NEEDED libraries, Symbol tables
```

### Standard-Units

Ein umfassendes Set von Standard-Units befindet sich im Verzeichnis `std/` und bietet ergonomische Bibliotheksfunktionen:

- **std/math.lyx** – Integer-Hilfen (`Abs64`, `Min64`, `Max64`, `Div64`, `Mod64`, `TimesTwo`)
- **std/io.lyx** – I/O-Wrappers (`print`, `PrintLn`, `PrintIntLn`, `ExitProc`)
- **std/string.lyx** – Umfassende String-Library mit über 15 Funktionen
- **std/env.lyx** – Environment-API (`init`, `ArgCount`, `Arg`)
- **std/time.lyx** – Datums- und Zeit-Berechnungen (numerische Berechnungen)
- **std/geo.lyx** – Geolocation-Parser für Decimal Degrees
- **std/crt.lyx** – ANSI Console Utilities (Farben, Cursor, clrscr). Siehe `examples/test_crt_ansi.lyx` für eine Demo.

#### String-Library Beispiel

```lyx
import std.string;

fn main(): int64 {
  var text: pchar := "Hello World";
  var len: int64 := StrLength(text);           // Native Builtin
  var first: int64 := str_char_at(text, 0);     // 'H' = 72
  
  // String-Manipulation
  var lower: pchar := "buffer_space_here";
  StrToLower(lower, text);                    // "hello world"
  
  // String-Tests  
  var starts: bool := StrStartsWith(text, "Hello"); // true
  var pos: int64 := StrFind(text, "World");          // 6
  
  PrintInt(len);    // 11
  PrintStr("\n");
  return 0;
}
```

#### Math-Builtins Beispiel

```lyx
fn main(): int64 {
  var x: int64 := -42;
  var y: f64 := 16.0;
  
  // Native Integer-Math (keine Imports nötig)
  PrintInt(abs(x));         // 42
  PrintInt(hi(x));          // Hohe 32 Bits
  PrintInt(lo(x));          // Niedrige 32 Bits
  
  // Native Float-Math  
  var root: f64 := sqrt(y);  // 4.0
  var square: f64 := sqr(y); // 256.0
  var rounded: int64 := round(root); // 4
  
  PrintFloat(pi());         // 3.14159...
  return 0;
}
```

#### Import-Beispiel

```lyx
import std.math;
import std.io;
import std.string;
import std.env; // optional

fn main(argc: int64, argv: pchar): int64 {
  // Automatische argc/argv-Initialisierung (kein manuelles init() nötig)
  PrintIntLn(ArgCount());
  PrintStr(Arg(0));
  PrintStr("\n");
  
  // Kombinierte Verwendung verschiedener Libraries
  var result: int64 := Abs64(-123);
  var str_result: pchar := IntToStr(result);
  PrintLn(str_result);
  
  return 0;
}
```

CI / Integrationstests

- Die GitHub Actions CI baut den Compiler, führt Unit-Tests und zusätzlich kompiliert und führt die Beispielprogramme in `examples/` (inkl. `examples/test_crt_ansi.lyx`) aus, um die Laufzeitintegration zu prüfen. Das `make e2e`-Target kompiliert und führt `hello.lyx`, `PrintInt.lyx` und `test_crt_ansi.lyx`; optionales `test_crt_raw.lyx` wird nur ausgeführt, wenn die CI-Variable `CRT_RAW` gesetzt ist.


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

### String-Escape-Sequenzen

| Escape | Bedeutung       |
|--------|-----------------|
| `\n`   | Zeilenumbruch   |
| `\r`   | Wagenrücklauf   |
| `\t`   | Tabulator        |
| `\\`   | Backslash        |
| `\"`   | Anführungszeichen|
| `\0`   | Null-Byte        |

### Kommentare

```lyx
// Zeilenkommentar

/* Blockkommentar
   über mehrere Zeilen */
```

### Reservierte Keywords

```
fn  var  let  co  con  if  else  while  switch  case  break  default  return  true  false  extern  array  as  import  pub  unit  type  struct  static  self  Self  class  extends  new  dispose  super
```

- `extern` wird für externe Funktionsdeklarationen verwendet
- `as` wird für Type-Casting verwendet
- `import`, `pub`, `unit` werden für das Module-System verwendet
- `type`, `struct` werden für benutzerdefinierte Typen verwendet
- `class`, `extends` für OOP mit Vererbung
- `new` für Heap-Allokation von Klasseninstanzen
- `dispose` für explizite Speicherfreigabe
- `super` für Aufruf von Basisklassenmethoden
- `static` markiert statische Methoden (ohne `self`-Parameter)
- `self` referenziert die aktuelle Instanz in Methoden
- `Self` als Rückgabetyp in Methoden (wird zum Struct-Typ aufgelöst)

---

## Praktische SO-Library Beispiele (v0.1.5)

### Memory Management mit malloc/free

```lyx
extern fn malloc(size: int64): pchar;
extern fn free(ptr: pchar): void;

fn main(): int64 {
  // Dynamischer Speicher allokieren
  let buffer: pchar := malloc(256);
  
  // Buffer verwenden (vereinfacht)
  PrintStr("Buffer allocated at: ");
  
  // Speicher wieder freigeben
  free(buffer);
  
  PrintStr("Memory freed\n");
  return 0;
}
```

### Formatierte Ausgabe mit printf

```lyx
extern fn printf(format: pchar, ...): int64;

fn main(): int64 {
  var count: int64 := 42;
  var pi: f64 := 3.14159;
  var name: pchar := "Lyx";
  
  // Verschiedene Datentypen ausgeben
  printf("Language: %s\n", name);
  printf("Count: %d\n", count);  
  printf("Pi: %.2f\n", pi);
  printf("Mixed: %s has %d features!\n", name, count);
  
  return 0;
}
```

### String-Verarbeitung

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

### Math-Library Funktionen

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

## Vollständige Beispiele

### FizzBuzz mit Math-Builtins

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
          // Native String-Konvertierung
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

### String- und Math-Operations kombiniert

```lyx
import std.string;

fn analyze_number(x: int64): void {
  PrintStr("Analyzing: ");
  PrintInt(x);
  PrintStr("\n");
  
  // Native Math-Builtins
  PrintStr("Absolute: ");
  PrintInt(abs(x));
  PrintStr("\n");
  
  if (odd(x)) {
    PrintStr("Number is odd\n");
  } else {
    PrintStr("Number is even\n");  
  }
  
  // String-Konvertierung und -Manipulation
  var str_val: pchar := IntToStr(abs(x));
  var len: int64 := StrLength(str_val);
  
  PrintStr("String representation: '");
  PrintStr(str_val);
  PrintStr("' (length: ");
  PrintInt(len);
  PrintStr(")\n");
  
  // Float-Casting und Math
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

### Voraussetzungen

- **FreePascal Compiler** (FPC 3.2.2+)
- **Linux x86_64** (Host-Plattform)
- GNU Make

### Compiler bauen

```bash
make build          # Release-Build (-O2)
make debug          # Debug-Build mit Checks (-g -gl -Ci -Cr -Co -gh)
```

### Lyx-Programm kompilieren

```bash
# Linux ELF64 (Standard)
./lyxc eingabe.lyx -o ausgabe
./ausgabe
echo $?             # Exit-Code prüfen

# Windows PE32+ (Cross-Compilation)
./lyxc eingabe.lyx -o ausgabe.exe --target=win64
# Ausführung unter Windows oder Wine
```

### Tests

```bash
make test           # Alle Unit-Tests (FPCUnit)
make e2e            # End-to-End Smoke-Tests
./tests/test_pe64   # PE64 Writer Tests
```

---

## Architektur

```
Quellcode (.lyx)
      |
  [ Lexer ]         Tokenizer -> TToken-Stream
      |
  [ Parser ]        Recursive-Descent -> AST
      |
  [ Sema ]          Semantische Analyse (Scopes, Typen)
      |
  [ IR Lowering ]   AST -> 3-Address-Code IR
      |
  [ Backend ]       IR -> Maschinencode (Bytes)
      |
      +-- [ Linux:   x86_64_emit + elf64_writer ]  -> ELF64 Binary
      |
      +-- [ Windows: x86_64_win64 + pe64_writer ]  -> PE32+ Binary
      |
  Executable (ELF64 oder PE32+, ohne libc)
```

### Projektstruktur

```
lyxc.lpr                  Hauptprogramm
frontend/
  lexer.pas                 Tokenizer
  parser.pas                Recursive-Descent Parser
  ast.pas                   AST-Knotentypen
  sema.pas                  Semantische Analyse
ir/
  ir.pas                    IR-Knotentypen (3-Address-Code)
  lower_ast_to_ir.pas       AST -> IR Transformation
backend/
  backend_types.pas         Gemeinsame Typen (External Symbols, Patches)
  x86_64/
    x86_64_emit.pas         x86_64 Instruktions-Encoding (Linux/SysV)
    x86_64_win64.pas        Windows x64 Emitter (Shadow Space, IAT)
  elf/
    elf64_writer.pas        ELF64 Binary-Writer
  pe/
    pe64_writer.pas         PE32+ Binary-Writer (DOS/COFF/Optional Header)
util/
  diag.pas                  Diagnostik (Fehler mit Zeile/Spalte)
  bytes.pas                 TByteBuffer (Byte-Encoding + Patching)
tests/                      FPCUnit-Tests
examples/                   Beispielprogramme in Lyx
```

### Design-Prinzipien

- **Frontend/Backend-Trennung**: Kein x86-Code im Frontend, keine AST-Knoten im Backend.
- **IR als Stabilitätsanker**: Die Pipeline ist immer AST -> IR -> Maschinencode.
- **Plattform-Abstraktion**: Gleicher IR-Input für Linux und Windows Backends.
- **ELF64 ohne libc**: `_start` ruft `main()`, danach `sys_exit`. Kein Linking gegen externe Libraries.
- **PE32+ mit IAT**: Import Address Table für kernel32.dll-Funktionen (GetStdHandle, WriteFile, ExitProcess).
- **Builtins eingebettet**: `PrintStr`, `PrintInt`, `PrintFloat`, `strlen` und `exit` werden als Runtime-Snippets direkt ins Binary geschrieben.
- **Jedes Token trägt SourceSpan**: Fehlermeldungen enthalten immer Datei, Zeile und Spalte.

---

## Editor-Hervorhebung & Grammatik

- Eine initiale TextMate/VSCode‑Grammatik liegt im Repo unter `syntaxes/lyx.tmLanguage.json`. Sie deckt Keywords, Typen, Literale, Kommentare und grundlegende Konstrukte ab und wird iterativ verfeinert.
- Kurzfristig wird ein pragmatisches Mapping per `.gitattributes` genutzt, damit GitHub‑Highlighting sofort sichtbar ist: `*.lyx linguist-language=Rust` (Fallback).
- Ziel: Contribution zur GitHub‑Linguist‑Bibliothek mit einer finalen TextMate‑Grammatik, damit `.lyx`‑Dateien nativ auf GitHub hervorgehoben werden.

Hinweis zum Testen lokal (VSCode)
- Öffne das Repo in VSCode und nutze den "Extension Development Host", um `syntaxes/aurum.tmLanguage.json` zu laden.
- Mit "Developer: Inspect TM Scopes" kannst du Token‑Scopes prüfen.

## Grammatik (EBNF)

Die vollständige formale Grammatik befindet sich in [`ebnf.md`](ebnf.md).

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
AddExpr     := MulExpr { ( '+' | '-' ) MulExpr } ;
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
| **v0.0.1** | `PrintStr("...")`, `exit(n)`, ELF64 läuft |
| **v0.0.2** | Integer-Ausdrücke, `PrintInt(expr)` |
| **v0.1.2** | `var`, `let`, `co`, `con`, `if`, `while`, `return`, Funktionen, SysV ABI |
| **v0.1.3** | ✅ Float-Literale (`f32`, `f64`), ✅ Arrays (Literale, Indexing, Zuweisung) |
| **v0.1.4** | ✅ SO-Library Integration, ✅ Dynamic ELF, ✅ PLT/GOT, ✅ Extern Functions, ✅ Varargs, ✅ Module System |
| **v0.1.5** | ✅ String-Library (20+ Funktionen), ✅ Math-Builtins (22 Funktionen), ✅ Type-Casting (`as`), ✅ String-Konvertierung |
| **v0.1.6** | ✅ Struct-Literale (`Point { x: 10, y: 20 }`), ✅ Instanz-Methoden mit `self`, ✅ Statische Methoden (`static fn`), ✅ `Self`-Typ, ✅ Feld-Zuweisung (`p.x := value`), ✅ Index-Zuweisung (`arr[i] := value`) |
| **v0.1.7** | ✅ OOP: Classes mit Vererbung (`class extends`), ✅ `new`/`dispose` für Heap-Objekte, ✅ Konstruktoren mit Argumenten, ✅ Destruktoren, ✅ `super` für Basisklassenaufrufe, ✅ Globale Variablen (`var`/`let` auf Top-Level), ✅ `Random()`/`RandomSeed()` Builtins, ✅ Pipe-Operator (`|>`) für Funktionsverkettung, ✅ Inkrement/Dekrement (`++`/`--`) als Statements |
| **v0.1.8** | ✅ Windows x64 Backend: PE32+ Binary-Erzeugung, ✅ Cross-Compilation (`--target=win64`), ✅ Windows x64 Calling Convention (Shadow Space), ✅ IAT/Import Directory für kernel32.dll |
| **v0.2** | Struct by-value Rückgabe, Pointer-Typen, Null-Safety Phase 2 |
| **v1** | Objektdateien, Multi-Unit Linking, Package Manager |

---

## Lizenz

Copyright (c) 2026 Andreas Röne. Alle Rechte vorbehalten.
