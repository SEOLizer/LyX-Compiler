# DATATYPES.md – Lyx Datentypen-Übersicht

## Aktuell unterstützte Datentypen

### 1. Ganzzahl-Typen (signiert)

| Typ     | Bits | Wertebereich                                               | Status | Literale    |
|---------|------|------------------------------------------------------------|--------|-------------|
| `int8`  | 8    | -128 bis 127                                               | ✅ Full | `42i8`      |
| `int16` | 16   | -32,768 bis 32,767                                         | ✅ Full | `42i16`     |
| `int32` | 32   | -2,147,483,648 bis 2,147,483,647                           | ✅ Full | `42i32`     |
| `int64` | 64   | -9,223,372,036,854,775,808 bis 9,223,372,036,854,775,807  | ✅ Full | `42` (std)  |
| `int`   | 64   | Alias für `int64`                                          | ✅ Full | `42`        |

### 2. Ganzzahl-Typen (unsigniert)

| Typ      | Bits | Wertebereich                                          | Status | Literale    |
|----------|------|-------------------------------------------------------|--------|-------------|
| `uint8`  | 8    | 0 bis 255                                             | ✅ Full | `42u8`      |
| `uint16` | 16   | 0 bis 65,535                                          | ✅ Full | `42u16`     |
| `uint32` | 32   | 0 bis 4,294,967,295                                   | ✅ Full | `42u32`     |
| `uint64` | 64   | 0 bis 18,446,744,073,709,551,615                     | ✅ Full | `42u64`     |

### 3. Plattform-abhängige Typen

| Typ     | Beschreibung                  | Status    | Anmerkung                         |
|---------|-------------------------------|-----------|-----------------------------------|
| `isize` | Pointer-Größe (signiert)      | ⚠️ Partial | Typ definiert; Tests/ABI prüfen   |
| `usize` | Pointer-Größe (unsigniert)    | ⚠️ Partial | Typ definiert; Tests/ABI prüfen   |

### 4. Fließkomma-Typen

| Typ   | Bits | IEEE 754 | Status | Literale |
|-------|------|----------|--------|----------|
| `f32` | 32   | single   | ✅ Full | `3.14f32` / `3.14` |
| `f64` | 64   | double   | ✅ Full | `3.14` / `3.14f64` |

> Status: Frontend (Lexer, Parser, AST, Sema), IR-Lowering und grundlegende Codegen‑Pfad für f32/f64 sind implementiert. Feinheiten der optimierten Float‑Codegenerierung können noch erweitert werden.

### 5. Zeichen- und String-Typen

| Typ     | Beschreibung               | Status | Literale |
|---------|----------------------------|--------|----------|
| `char`  | Einzelnes Zeichen (ASCII/Unicode codepoint) | ✅ Full | `'a'`, Escape-Sequenzen |
| `pchar` | Null-terminierter String (statisch, read-only) | ✅ Full | `"hello"` |
| `string`| Dynamisch wachsender String (mmap-Heap, v0.5.7) | ✅ Full | via `StrNew` |

**Dynamische Strings (v0.5.7):** `string`-Werte verwenden einen 16-Byte-Header vor dem Datenpuffer (`[capacity:8][length:8]`). Der zurückgegebene `pchar`-Zeiger zeigt auf die Nutzdaten und ist kompatibel mit `PrintStr`.

**String-Builtins (v0.5.7):**

| Funktion | Signatur | Beschreibung |
|----------|----------|--------------|
| `StrNew` | `(cap: int64): string` | Allokiert neuen String mit Kapazität `cap` |
| `StrFree` | `(s: string)` | Gibt String-Speicher frei (munmap) |
| `StrLen` | `(s: string): int64` | Länge des Strings (ohne Null-Terminator) |
| `StrCharAt` | `(s: string, i: int64): int64` | Zeichen an Position `i` als int64 |
| `StrSetChar` | `(s: string, i: int64, c: int64)` | Setzt Zeichen an Position `i` |
| `StrAppend` | `(s: string, c: int64): string` | Hängt Zeichen an, gibt neuen Puffer zurück |
| `StrFromInt` | `(n: int64): string` | Konvertiert int64 zu String |

```lyx
var s: string := StrNew(64);
s := StrAppend(s, 72);   // 'H'
s := StrAppend(s, 105);  // 'i'
PrintStr(s);             // "Hi"
StrFree(s);
```

### 6. Enum-Typen (v0.5.7)

Enums definieren eine benannte Menge von Integer-Konstanten.

```
EnumDecl  := 'enum' Ident '{' EnumBody '}' ;
EnumBody  := EnumMember { ',' EnumMember } ;
EnumMember := Ident [ '=' IntLiteral ] ;
EnumAccess := Ident '::' Ident ;
```

| Merkmal | Beschreibung |
|---------|--------------|
| Basistyp | `int64` (implizit) |
| Auto-Nummerierung | Startet bei 0, inkrementiert automatisch |
| Explizite Werte | `Name = <literal>` erlaubt |
| Zugriff | `EnumName::Wert` (Namespace-Operator `::`) |
| Vergleich | Mit `==` / `!=` gegen int64-Werte |

```lyx
enum Color { Red, Green, Blue }
enum Status { Ok = 0, Err = 1 }

fn main(): int64 {
  var c: int64 := Color::Green;   // c = 1
  if (c == Color::Green) {
    PrintStr("green\n");
  }
  return 0;
}
```

### 7. Tuple-Typen (v0.5.7)

Funktionen können mehrere Werte als Tuple zurückgeben.

```
TupleReturn  := '(' Expr { ',' Expr } ')' ;
TupleUnpack  := 'var' Ident { ',' Ident } ':=' CallExpr ';' ;
```

| Merkmal | Beschreibung |
|---------|--------------|
| Max. Elemente | Beliebig (aktuell bis 8 getestet) |
| Speicher | Stack-basiert via RDX/RAX für 2 Werte |
| Unpack | `var a, b := f()` — gleichzeitige Zuweisung |

```lyx
fn divmod(a: int64, b: int64): (int64, int64) {
  return (a / b, a % b);
}

fn main(): int64 {
  var q, r := divmod(17, 5);
  PrintInt(q);   // 3
  PrintInt(r);   // 2
  return 0;
}
```

### 8. Sonstige Typen

| Typ    | Beschreibung            | Status | Verwendung |
|--------|-------------------------|--------|------------|
| `bool` | Wahrheitswert           | ✅ Full | `true`, `false` |
| `void` | Kein Rückgabewert       | ✅ Full | Funktionen ohne Return |

### 9. Interne Typen

| Typ            | Verwendung                                 |
|----------------|--------------------------------------------|
| `atUnresolved` | Temporär während Typprüfung                 |

## Status-Legende

- ✅ **Full**: Vollständig implementiert (Parser, Sema, IR, Codegen)
- ⚠️ **Partial**: Teilweise implementiert (fehlende Komponenten oder Tests)
- ❌ **Missing**: Definiert, aber nicht implementiert
- 🔄 **WIP**: Work in Progress

## Implementierungsdetails

### Storage-Klassen-Kompatibilität

| Storage-Klasse | Beschreibung           | Status (HEAD) |
|----------------|------------------------|---------------|
| `var`          | Veränderbar            | ✅ Unterstützt für alle primitiven Typen |
| `let`          | Unveränderbar          | ✅ Unterstützt für alle primitiven Typen |
| `co`           | Compile-time readonly  | ✅ Unterstützt |
| `con`          | Compile-time constant  | ✅ Unterstützt |

**Getestet und funktionsfähig (Frontend + IR + grundlegende Codegen):**
- Integer-Typen (int8..int64, uint8..uint64)
- Boolean (`bool`)
- Char (`char`) inkl. Escape‑Sequenzen
- Strings (`pchar`/`string`) mit Literalunterstützung
- Floating-Point (f32, f64): Literal‑Parsing, Typprüfung, Konvertierungen und Basis‑Codegen
- Array‑Literal‑Parsing und elementare Load/Store-Operationen (Frontend und grundlegender Backend‑Support)

### Typkonvertierung

- **Automatisch**: Zwischen Integer‑Typen verschiedener Breiten
- **Explizit**: Mit Casts (teilweise implementiert)
- **Konstanten‑Folding**: Literale werden beim IR/Codegen auf Zielbreite behandelt

### Code-Generation-Status

#### Vollständig implementiert:
- Integer-Typen (8–64 Bit, signed/unsigned)
- `bool`, `char`, `pchar`, `string`
- Basis‑Floating‑Point‑Operationen (Loads/Stores, cvt, movsd/movss) und Konversionen
- Konstanten‑Folding mit Truncation/Extension
- Load/Store mit korrekter Breite

#### Teilweise implementiert:
- `isize`, `usize`: Typen sind definiert; ABI/Architekturtests fehlen
- Arrays: Frontend (Literals, Typprüfung) ist vollständig; komplexere Array‑Codegen (statische Layouts, Slicing, dynamische Allokation) ist noch in Arbeit

#### Fehlend / noch zu erweitern:
- Strukturen/Records (vollständiger Speicherlayout‑Support)
- Pointer‑Arithmetik (feinere Operationen)
- Union‑Typen

## Status-Update: HEAD (aktueller Stand)

Die aktuellen Änderungen haben folgende Lücken geschlossen und Features hinzugefügt:

- Frontend: Char‑ und Float‑Literal‑Lexing/Parsing implementiert
- IR/Backend: Grundlegende Float‑Operationen (cvtsi2sd, cvttsd2si, movsd) und Array Load/Store-Emissionen implementiert
- Platform‑Types (`isize`/`usize`) sind als Typen vorhanden; Tests/ABI‑Überprüfung stehen noch aus

## Test-Abdeckung (Stand: Februar 2026)

### ✅ Getestet / grün:
- Integer‑Primitiven (int8..int64, uint8..uint64)
- Boolean (`bool`)
- Char‑Literale und Escape‑Sequenzen
- String‑Literale (`pchar`/`string`) in Kombination mit Builtins (z.B. PrintStr)
- Float‑Literals (f32, f64) — Parsing, Sema, Basiscodierung
- Array‑Literal‑Parsing und elementare Load/Store im Backend

### ⚠️ Zu verifizieren:
- `isize`/`usize` auf mehreren Architekturen
- Edge‑Cases bei Integer‑Overflow/Underflow
- Vollständiger Float‑Codegen (optimierte Sequenzen, ABI‑Konventionen für float‑Returns in SSE regs)

## Roadmap (aktualisiert)

### Kurzfristig
1. Tests für `isize`/`usize` hinzufügen und ABI‑Konformität prüfen
2. Erweiterte Array‑Codegen (statische Arrays, Layouts)
3. Pattern Matching: `match` auf Strings und Enums erweitern

### Mittelfristig
1. Strukturen/Records implementieren (Layout + Feldzugriff)
2. Pointer‑Arithmetik und dereferenzierung vervollständigen
3. Generics auf Strukturen ausweiten (aktuell: nur Funktionen)

### Langfristig
1. Union‑Typen
2. Smart‑Pointer
3. Garbage Collector (optional)

## Beispiele

```lyx
// Integer-Typen
var a: int8 := 127;
let b: uint16 := 65535;

// Floats
var pi: f32 := 3.14159;
let e: f64 := 2.718281828;

// Char & String
var ch: char := '\n';
let msg: pchar := "Hello, World!";

// Arrays (Literal + einfache Load/Store)
var arr := [1, 2, 3];
let first := arr[0];

// Function signatures
fn get_byte(): uint8 { return 255; }
fn get_flag(): bool { return true; }
```
