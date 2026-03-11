# Projekt Lyx

Perfekt: **x86_64 Linux als v1-Ziel** ist genau die richtige Wahl, *wenn* du es später erweiterbar halten willst. Der Trick ist, von Anfang an eine **saubere Trennung** zu machen: Frontend (Lexer/Parser/Semantik) unabhängig vom Backend, und im Backend nochmal trennen zwischen **ISA (x86_64)** und **Objektformat (ELF64)**.

So bekommst du „heute ELF/x86_64“, „morgen ARM64/Mach-O“ ohne alles neu zu schreiben.

---

## Architektur, die wirklich erweiterbar ist

### Schichten (bewährt)

1. **Frontend**
- Lexer
- Parser → AST
- Semantik (Scopes, Typen)
1. **Middle-End**
- AST → **IR** (eigene kleine Zwischenrepräsentation, nicht „Pascal als Zwischenlösung“)
- Simple Optimierungen (optional)
1. **Backend**
- IR → **Machine IR / Assembler-ähnlich** (Instruktionen + Labels)
- **Target**: x86_64 (Instruktions-Encoding, Register, Calling Convention)
- **Object/Exe writer**: ELF64 (Header/Segments)

Wichtig: Das IR ist *dein* Stabilitätsanker. Wenn du zu früh “AST direkt nach x86 bytes” machst, wird jede Sprachänderung zur OP am offenen Herzen.

---

## Minimaler Step 1, der “echt” ist: ELF64 + Syscalls

### Ziel für v0.0.1

Lyx kann genau das:

```
PrintInt(1 + 2*3);
exit(0);
```

Und du erzeugst ein **statisch laufendes ELF64** ohne libc:

- `sys_write(1, buf, len)`
- `sys_exit(code)`

Damit umgehst du am Anfang:

- C-ABI
- Linker-Kopfschmerz
- externe Dependencies

Später kannst du immer noch auf SysV ABI + libc umsteigen oder optional dynamisch linken.

---

## Erweiterbarkeit: Welche “Contracts” du definierst

### 1) IR-Contract (targetunabhängig)

Ein IR, das du später in jedes Target übersetzen kannst, z.B.:

- `ConstInt`
- `Add/Sub/Mul/Div`
- `Call BuiltinPrintInt`
- `Exit`
- später: `Load/Store`, `Br`, `Cmp`, `Phi` (wenn du SSA willst)

Du musst nicht gleich SSA machen. Ein *3-Address-Code* reicht erstmal.

**IR-Optimierungen** (v0.5.0):

- Constant Folding: Compile-time Auswertung von Konstantenausdrücken
- Dead Code Elimination: Entfernung von unbenutztem Code
- Common Subexpression Elimination (CSE): Erkennung von wiederholten Berechnungen
- Copy Propagation: Ersetzen von Kopien durch ihre Quelle
- Strength Reduction: Ersetzen von teuren Operationen (z.B. `x * 2` → `x + x`)
- Function Inlining: Direktes Einfügen von Funktionsaufrufen

### 2) Target-Contract (ISA)

Ein Interface wie:

- `emitMovRegImm(reg, imm)`
- `emitSyscall(num, rdi, rsi, rdx)`
- `emitLabel(name)`
- `emitJmp(label)`

Intern kann x86_64 diese Dinger dann zu Bytes encoden.

### 3) Output-Contract (ELF64 Writer)

Der ELF-Writer bekommt:

- finalen Code-Blob
- Data-Blob
- Entry-Offset
- Segment-Flags

und schreibt daraus eine Datei.

---

## Konkrete Projektstruktur (FPC)

```
lyxc/
  lyxc.lpr

  frontend/
    lexer.pas
    parser.pas
    ast.pas
    sema.pas
  ir/
    ir.pas
    lower_ast_to_ir.pas
    ir_optimize.pas          IR optimizations (Constant Folding, CSE, DCE, etc.)
    ir_inlining.pas         Function inlining
  backend/
    backend_intf.pas        (Interfaces)
    x86_64/
      x86_64_emit.pas       (Instr -> Bytes)
      x86_64_sysv.pas       (später: Calling Convention)
    elf/
      elf64_writer.pas
  util/
    diag.pas                (Fehler, Spans)
    bytes.pas               (ByteBuffer)
```

Das ist klein genug zum Bauen, aber nicht so klein, dass du dich später hasst.

---

## Was du **genau** in Step 1 implementierst

### A) ByteBuffer (Grundlage)

- `WriteU8/U16/U32/U64LE`
- `WriteBytes`
- `PatchU32LE(offset, value)` (für Backpatching)

### B) x86_64-Minimum-Encoder

Du brauchst für Syscall-only “Hello/PrintInt” am Anfang überraschend wenig:

- `mov rax, imm64`
- `mov rdi, imm64`
- `mov rsi, imm64`
- `mov rdx, imm64`
- `syscall`
- `ret` (optional, wenn du Funktionen später hast)

Für `PrintInt` brauchst du zusätzlich eine Routine `itoa` oder erstmal **nur Stringliteral printen** (noch einfacher). Der *realistische* Minimalstart ist:

```
PrintStr("hi\n");
exit(0);
```

Dann musst du noch keine Integer-Formatierung bauen. **Das ist kein Ausweichen**, das ist ein sinnvoller Bootstrap.

### C) ELF64 Writer als “Single PT_LOAD”

Für v0:

- 1 Load-Segment (RX) und Data direkt dahinter (oder zweites Segment R)
- Entry = Start des Codes
- Alignments sauber (0x1000 Pagesize)

Später kannst du das in zwei Segmente splitten (RX / RW).

---

## Roadmap, die nicht eskaliert

### v0.0.1

- `PrintStr("...")`, `exit(n)`
- ELF64 läuft

### v0.0.2

- Integer-Ausdrücke + `PrintInt(expr)`
- Minimal-itoa in mitgeliefertem Code (Runtime-Snippet, aber in dein Binary eingebettet)

### v0.1.2

- `let`, `if`, `while`
- Stackframe (RBP/RSP), einfache Registerstrategie

### v0.1.3

- ✅ Float-Literale (`f32`, `f64`)
- ✅ Array-Literale: `[1, 2, 3]`
- ✅ Array-Indexing: `arr[i]`
- ✅ Array-Zuweisung: `arr[i] := value`

### v0.1.4 ✅ ABGESCHLOSSEN

- ✅ **Module System**: Vollständige Import/Export Funktionalität
- ✅ **Cross-Unit Symbol Resolution**: TSema.AnalyzeWithUnits() Integration
- ✅ **Standard Library**: std/math.lyx mit pub fn Abs64, Min64, Max64, TimesTwo
- ✅ **Parser Robustheit**: While/If-Statements, Unary-Expressions, Function-Context
- ✅ **Dynamic ELF**: SO-Library Integration, PLT/GOT Mechanik für externe Symbole
- ✅ **Extern Declarations**: `extern fn` mit Varargs (`...`) Support
- ✅ **Dynamic Linker**: `/lib64/ld-linux-x86-64.so.2` Integration
- ✅ **Relocation Support**: .rela.plt, R_X86_64_JUMP_SLOT Tables
- ✅ **Smart ELF Selection**: Automatische Static/Dynamic ELF Auswahl

**Status**: Compiler ist vollständig produktiv für Multi-Module Projekte
**Bekanntes Issue**: Cross-Unit Function Call Backend-Bug (Linking OK, Execution NOK)

### v0.1.5 ✅ ABGESCHLOSSEN — "Control Flow & Integer Widths"

- ✅ **Cross-Unit Function Call Bug**: Backend IsExternalSymbol() Überprüfung und PLT/GOT‑Erfassung für fehlende Symbole implementiert (Emitter sammelt externe Symbole via AddExternalSymbol).
- ✅ **For-Loop IR Lowering**: IR‑Lowering für `for i := A to B do` / `downto` implementiert (Labels, Vergleich, Inkrement/Decrement, Break/Continue‑Support).
- ✅ **Integer Width Backend**: Unterstützung für Narrow/Wide Integer (int8/int16/uint32 etc.) in IR und Emit‑Pfad; Trunc/SExt/ZExt‑Emissionen vorhanden.
- ✅ **Verschachtelte Unary‑Ops**: Parser und konstante Faltung für verschachtelte Präfix‑Operatoren (`--x`, `!!y`, `!-x`) implementiert.
- ✅ **Emitter: Handler‑Patching (RIP‑rel LEA)**: Exception‑Handler‑Patching über `lea reg, [rip+disp32]` statt movabs implementiert. Patch‑Passage berechnet disp32 = dataVA - instrVA und benutzt PatchU32LE — behebt Relocation/ASLR/Relok‑Probleme.

**Status**: Vollständig implementiert und getestet. Verbleibende Kleinigkeiten in den Diagnosen sind nicht funktionskritisch.


### v0.1.6 ✅ ABGESCHLOSSEN — "OOP-light"

- ✅ **Struct Literals**: `TypeName { field: value, ... }` Syntax für direkte Struct-Initialisierung
- ✅ **Instance Methods mit `self`**: Methoden in Structs erhalten impliziten `self`-Parameter (Pointer auf Instanz)
- ✅ **Static Methods**: `static fn` Keyword für Methoden ohne `self`-Parameter
- ✅ **`Self` Return Type**: `Self` als Rückgabetyp in Methoden resolves zum umschließenden Struct-Typ
- ✅ **Index Assignment**: `arr[idx] := value` Syntax mit `TAstIndexAssign` AST-Knoten
- ✅ **Bugfix**: Uninitialisierte Variable `s` in `CheckExpr` (sema.pas) behoben — verursachte zufälliges Verhalten bei Method Calls

**Neue Syntax-Elemente**:

```lyx
// Struct Literal
var p: Point := Point { x: 10, y: 20 };

// Instance Method (implizites self)
type Counter = struct {
  count: int64;
  fn get(): int64 { return self.count; }
  fn inc() { self.count := self.count + 1; }
};

// Static Method (kein self)
type Math = struct {
  static fn add(a: int64, b: int64): int64 { return a + b; }
};

// Aufruf
var result: int64 := Math.add(10, 32);  // Static: TypeName.method()
var c: Counter := 0;
c.count := 5;
var v: int64 := c.get();                // Instance: instance.method()
```

**Method Mangling**: `_L_<Struct>_<Method>` (z.B. `_L_Counter_get`)

**Bekannte Einschränkung**: Struct Return-by-Value nicht vollständig unterstützt (Stack Lifetime Issue).

### v0.1.7 ✅ ABGESCHLOSSEN — "OOP Full & Globals"

- ✅ **Classes mit Vererbung**: `class extends BaseClass` Syntax für OOP mit Single Inheritance
- ✅ **Heap-Allokation**: `new ClassName()` allokiert Klasseninstanzen auf dem Heap
- ✅ **Konstruktoren mit Argumenten**: `new ClassName(args)` ruft `Create`-Methode auf
- ✅ **Destruktoren**: `dispose expr` ruft `Destroy()` auf und gibt Speicher frei
- ✅ **super-Keyword**: `super.method()` für Aufruf von Basisklassenmethoden
- ✅ **Globale Variablen**: `var`/`let` auf Top-Level mit Data-Segment-Speicherung
- ✅ **Random Builtins**: `Random()` und `RandomSeed()` für Pseudo-Zufallszahlen (LCG)
- ✅ **Null-Safety Phase 1**: `?` Nullable Types, `??` Null-Coalesce Operator, `?.` Safe Call
- ✅ **Pipe-Operator**: `|>` für Funktionsverkettung mit Datenfluss von links nach rechts

**Neue Syntax-Elemente**:

```lyx
// Globale Variable
var globalCounter: int64 := 0;

// Klasse mit Vererbung
type Animal = class {
  name: pchar;
  fn speak() { PrintStr("Some sound\n"); }
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
  
  RandomSeed(42);
  PrintInt(Random());     // Pseudo-Zufallszahl
  return 0;
}
```

**IR-Erweiterungen**:
- `irLoadGlobal`/`irStoreGlobal` für globale Variablen
- `irAlloc`/`irFree` für Heap-Speicher

**Backend-Erweiterungen**:
- RIP-relative Adressierung für globale Variablen
- `mmap`/`munmap` syscalls für Heap
- LCG-Implementierung für Random

**Pipe-Operator Beispiel**:
```lyx
fn double(x: int64): int64 { return x * 2; }
fn addOne(x: int64): int64 { return x + 1; }

fn main(): int64 {
  var result: int64 := 5 |> double() |> addOne();
  // Äquivalent zu: addOne(double(5)) = 11
  PrintInt(result);
  return 0;
}
```

### v0.2.2 ✅ ABGESCHLOSSEN — "SIMD / ParallelArray"

- ✅ **ParallelArray-Typ**: `parallel Array<T>(size)` – SIMD-optimiertes, heap-allokiertes Array
- ✅ **SIMD-AST-Knoten**: `TAstSIMDNew`, `TAstSIMDBinOp`, `TAstSIMDUnaryOp`, `TAstSIMDIndexAccess`
- ✅ **SIMD-IR-Opcodes**: `irSIMDAdd/Sub/Mul/Div/And/Or/Xor/Neg/Shl/Shr`, Vergleiche, Reduce-Ops
- ✅ **Lexer/Parser**: `parallel Array<T>(size)` Parsing
- ✅ **Sema**: Typprüfung, SIMDKind-Propagierung, Operator-Validierung
- ✅ **IR-Lowering**: Vollständig für alle 4 SIMD-Knotentypen + VarDecl + IndexAssign
- ✅ **Backend**: SSE2/AVX-Emission, Bounds-Checks, Reduce-Ops implementiert

**Status**: Vollständig implementiert und getestet.

---

0.2.0 — "Stabilisierung: Calls, Imports, Relocs"

Ziel: euer aktuelles Known Issue wird endgültig erschlagen, und ihr könnt extern+cross-unit vertrauen.

Deliverables

✅ Fix: Cross-Unit Function Call Bug (IsExternalSymbol / Call-Mode / Reloc)

✅ Einheitlicher “Call Lowering”-Pfad:

call internal

call imported

call extern (libc)

✅ ABI-Testkatalog (klein, aber hart):

6+ Argumente (Register + Stack)

callee-saved Register-Test

Stack alignment Test (z.B. printf/SSE-sensitive call)

✅ Tooling: optional --emit-asm / --dump-relocs (Debuggability)

Nicht reinpacken

for-loops, neue Typen, OOP. Erst Fundament.

0.2.1 — “Integer Widths & Sign/Zero-Extend”

Ziel: int8/uint32/... ohne Backend-Zufall.

Deliverables

✅ IR-Typen für Integerbreiten

✅ Codegen-Regeln:

sign/zero extend an klaren Stellen (load, arithmetic, call args, returns)

✅ Minimale Standard-Builtins/Intrinsics:

as/casts explizit (keine implizite Magie am Anfang)

0.2.2 — “Control Flow Vollständigkeit: for + Lowering”

Ziel: for als reines Sugar über while im IR (kein Extra-Backend).

Deliverables

✅ for i := a to b do → IR: init; cond; body; inc; jmp

✅ Break/continue (optional, wenn ihr eh CFG macht)

✅ Parser-Fixes (Unary nesting --x, !!y) hier ok, weil kaum Backend-Risiko

I/O und Filesystem systematisch (ohne Runtime-Explosion)
0.3.0 — “std.io (Syscalls): fd-basierte I/O”

Ziel: echte Dateiarbeit, aber ohne libc-Abhängigkeit, solange ihr euch das noch nicht 100% traut.

API-Minimum

type fd: int32 (oder int64, aber fd ist logisch int32)

fn open(path: pchar, flags: int32, mode: int32): fd

fn read(fd, buf: *u8, len: int64): int64

fn write(fd, buf: *u8, len: int64): int64

fn close(fd): int32

Fehler: erstmal “negativer Rückgabewert = -errno” oder Result-ähnlich, aber konsistent.

Deliverables

✅ syscall-wrapper layer im Backend/stdlib

✅ PrintStr implementiert über write(1,...) (kein Spezialfall mehr)

0.3.1 — “std.fs Basis: stat, mkdir, unlink, rename”

Ziel: nützliche FS-Operationen, noch ohne Directory Iteration.

stat(path) → Größe/Mode/Type

mkdir, unlink, rename

cwd / chdir optional

0.3.2 — “Directories: dir listing (Linux-first)”

Zwei Wege — ihr wählt einen, aber ich setze Linux-first als robusten Schritt:

Option A (Linux-spezifisch, syscall-only):

getdents64 wrapper

DirIter als low-level iterator (Record + Buffer)

Option B (libc):

opendir/readdir/closedir

nur wenn Gate B wirklich bombenfest ist

Ich würde A zuerst bauen, B später als “portabler layer”.

“OOP” sinnvoll schneiden (erst Wert, dann Kosten)
0.4.0 — “Structs + Methoden (OOP-light, kein virtual)”

Ziel: 80% Strukturgewinn ohne Runtime/Dispatch-Komplexität.

Features

struct / record types (layout-stabil, klarer ABI)

Methoden als Sugar:

fn Vec2.len(self: Vec2): f64

oder self: *Vec2 für mutierende Methoden

Namespacing/impl blocks (Syntaxfrage), aber keine Vererbung

Deliverables

✅ Layout/Alignment Regeln dokumentiert

✅ Field access + address-of + passing by value/ref

✅ Keine Heap-Pflicht

0.4.1 — “Strings & Slices als Standarddatenmodell”

Damit std.io/std.fs nicht ewig “pchar-only” bleibt:

type slice_u8 = {*u8, len:int64}

type string = {pchar, len} (oder alias auf slice_u8)

Basisfunktionen: concat/splice später; erstmal: length, compare, to_cstr (wenn nötig)

### v0.5.0 — "IR Optimizer Pipeline"

- ✅ **Constant Folding**: Compile-time Auswertung von Konstantenausdrücken
- ✅ **Dead Code Elimination**: Entfernung von unbenutztem Code
- ✅ **Common Subexpression Elimination (CSE)**: Erkennung von wiederholten Berechnungen
- ✅ **Copy Propagation**: Ersetzen von Kopien durch ihre Quelle
- ✅ **Strength Reduction**: Ersetzen von teuren Operationen (x * 2 -> x + x)
- ✅ **Function Inlining**: Direktes Einfügen von Funktionsaufrufen
- ✅ **CLI-Option --no-opt**: Deaktiviert IR-Optimierungen

### v0.5.1 — "VMT (Virtual Method Table)"

- ✅ **Virtual Methods**: `virtual fn` Keyword für virtuelle Methoden mit VMT-Eintrag
- ✅ **Override**: `override fn` Keyword zum Überschreiben virtueller Methoden
- ✅ **VMT Memory Layout**: VMT wird als Daten-Array im .data-Segment gespeichert
- ✅ **VMT Dispatch**: Aufruf virtueller Methoden via LEA + CALL [VMT+offset]
- ✅ **VMT Patching**: Absolute Adressen werden zur Compilezeit in VMT-Einträge geschrieben

**VMT-Syntax:**
```lyx
type TBase = class {
  val: int64;
  
  virtual fn GetValue(): int64 {
    return self.val;
  }
};

type TDerived = class extends TBase {
  extra: int64;
  
  override fn GetValue(): int64 {
    return self.val + self.extra;
  }
};
```

**VMT-Semantik:**
- `virtual` deklariert eine Methode als virtuell. Die Methode erhält einen festen Slot in der VMT der Klasse.
- `override` überschreibt eine virtuelle Methode der Basisklasse. Der Override muss denselben Signatur haben.
- Virtuelle Methodenaufrufe werden zur Laufzeit über die VMT dispatcht: `call [obj + VMT_Offset + methodIndex * 8]`
- Jede Klasse mit virtuellen Methoden hat eine eigene VMT. Abgeleitete Klassen erben die VMT der Basisklasse und fügen neue Einträge hinzu.

**VMT-Speicherlayout:**
```
[TBase]:
  .data:
    _vmt_TBase:
      dq TBase_GetValue_Address

[TDerived]:
  .data:
    _vmt_TDerived:
      dq TDerived_GetValue_Address   ; überschreibt TBase.GetValue
```

**VMT-Aufruf (Pseudocode):**
```asm
; obj ist ein Pointer auf die Klasseninstanz
; VMT-Offset ist固定 (z.B. 0)
lea rax, [obj]           ; obj Pointer holen
mov rax, [rax + 0]       ; VMT-Pointer aus erstem Feld laden
call [rax + methodIndex * 8]  ; virtuelle Methode aufrufen
```

### v0.5.2 — "Abstract Methods"

- **Abstract Methods**: `abstract fn` Keyword für Methoden ohne Implementierung
- **Abstract Class Detection**: Klassen mit abstrakten Methoden können nicht instanziiert werden  
- **Concrete Override**: Konkrete Subklassen müssen alle abstrakten Methoden implementieren

**Abstract-Syntax:**
```lyx
type Animal = class {
  abstract fn Speak(): int64;
};

type Dog = class extends Animal {
  override fn Speak(): int64 { return 1; }
};
```

**Abstract-Semantik:**
- `abstract fn` deklariert eine Methode ohne Body. Die Methode muss von einer konkreten Subklasse überschrieben werden.
- Eine Klasse mit mindestens einer abstrakten Methode ist automatisch **abstrakt**.
- **Fehler**: Versucht man, eine abstrakte Klasse zu instanziieren: `cannot instantiate abstract class: <ClassName>`
- `abstract` impliziert automatisch `virtual`

v1.0: “Stabile Systemsprache”
1.0.0 — “Stabil, testbar, nutzbar”

Definition von v1

Module/Imports stabil (habt ihr)

SysV ABI stabil (ab 0.2.x)

std.io + std.fs Minimum (ab 0.3.x)

Structs + Methoden (ab 0.4.0)

Diagnostics ordentlich (Spans, gute Errors)

Build-Tooling: reproduzierbare Builds, Test-Suite

Wichtig: v1 ist ohne klassische OOP (kein inheritance/virtual), aber “OOP-light” reicht für sehr viel.

v1.x / v2: “Klassische OOP” nur wenn wirklich gewollt

Hier wird’s teuer. Deshalb bewusst als eigener Block:

1.1.0 — “Interfaces / dynamic dispatch (optional)”

interface/trait-artiges Konzept

vtable/itable oder fat pointers

klare ABI-Regeln für dispatch

2.0.0 — “Klassen, Vererbung, Konstruktoren (wenn ihr es wollt)”

Nur falls ihr wirklich “Java/Delphi-like” wollt. Sonst lasst es. Vererbung ist selten die Rendite, die sie verspricht.
---

## Beispiel: Arrays und Float-Literale (v0.1.3)

```lyx
// Float-Konstanten
con PI: f64 := 3.14159;

fn main(): int64 {
  // Array-Literal
  var arr: array := [10, 20, 30];

  // Element lesen
  var first: int64 := arr[0];   // 10

  // Element zuweisen
  arr[0] := 100;                // arr ist jetzt [100, 20, 30]

  // Dynamischer Index
  var i: int64 := 1;
  var second: int64 := arr[i];  // 20

  return 0;
}
```

## Struct-Methoden & `self` (Phase A)

**Motivation:** Daten und Verhalten gehören zusammen, ohne dass zusätzliche Laufzeitkosten entstehen. Lyx ergänzt `struct`-Typen daher um integrierte Methodenblöcke.

### Syntax

```lyx
type Player := struct {
  id: int64;
  health: int64;

  fn take_damage(amount: int64) {
    self.health := self.health - amount;
    if self.health < 0 {
      self.health := 0;
    }
  }

  fn is_alive(): bool {
    return self.health > 0;
  }
};
```

* Felder und Methoden teilen sich den Block. Reihenfolge spielt keine Rolle.
* Methoden verwenden dieselbe Blocksyntax wie freie Funktionen.
* `self` ist als reserviertes Schlüsselwort automatisch verfügbar.

### `self`

* Typ: `*Player` (Pointer auf den umschließenden Struct-Typ).
* Übergabe: als versteckter erster Parameter, ABI-konform in `RDI` (x86_64 SysV).
* Mutierbar: Methoden können Felder direkt verändern (`self.health := …`).

### Dot-Notation & Aufrufauflösung

```
let mut p := Player{ id: 1, health: 42 };
p.take_damage(20);
```

* Der Semantik-Pass prüft zuerst den Typ auf der linken Seite (`Player`).
* Lookup entscheidet zwischen Feldzugriff (`p.health`) und Methodenausdruck (`p.take_damage`).
* Methodenaufrufe werden in freie Funktionsaufrufe desugart:
  * `p.take_damage(20)` → `_L_Player_take_damage(&p, 20)`
  * `p.is_alive()`      → `_L_Player_is_alive(&p)`
* Das `_L_`-Präfix verhindert Namenskollisionen im ELF-Binary.

### Speicherlayout

* Es gibt **keine** impliziten VMT- oder Header-Pointer.
* Ein `struct` bleibt byte-identisch zu seiner Feldliste; Methoden existieren nur zur Compilezeit.
* Damit bleibt „Zero Overhead“ erhalten.

### Export / Import

* `pub type Player := struct { … }` exportiert den Typ sowie alle Methoden in die LUI-Datei.
* Beim Import stehen Methoden weiterhin über die Dot-Notation zur Verfügung (`game.Player`).

---

## Anforderungen

# 1) Sprachkern (Syntax & Paradigma)

Das sind die Entscheidungen, die *alles* downstream beeinflussen.

## Paradigma

- prozedural
- funktional
- objektorientiert
- hybrid

👉 Für einen nativen Compiler v1: **prozedural + Funktionen** ist am stabilsten.

## Blocksyntax

- `{ }`
- `begin/end`
- indentation

Warum wichtig:

- beeinflusst Lexer stark (indentation = deutlich mehr Aufwand).

## Statements vs Expressions

- Ist `if` ein Statement oder ein Ausdruck?
- Hat jede Funktion einen Rückgabewert?

Wenn du später SSA/IR willst: Expression-orientiert ist eleganter, aber komplexer.

---

# 2) Typensystem (kritischer Kernpunkt)

Hier entscheidet sich der Aufwand für Semantik + Codegen.

## Typstrategie

- statisch typisiert
- dynamisch
- optional statisch

Für nativen Code:

👉 **statisch typisiert** spart dir Runtime-Chaos.

## Primitive Typen (Startumfang)

Minimal sinnvoll:

- `int` (z.B. 64bit)
- `bool`
- `void`

Implementiert in v0.1.3-v0.1.4:

- `f32`, `f64` (Floating-Point)
- `array` (Stack-allokierte Arrays)

Implementiert in v0.2.2:

- `parallel Array<T>` (SIMD-optimiertes, heap-allokiertes Array)

Optional später:

- `string` (als dynamischer Typ)
- structs

Frage, die du beantworten musst:

- implizite Casts erlaubt?
- Integergröße fix oder arch-abhängig?

---

# 3) Speicher- und Laufzeitmodell

Das wird oft vergessen — ist aber für x86 Backend entscheidend.

## Variablen

- stackbasiert?
- global erlaubt?

## Lifetime

- manuell
- scopebasiert
- GC (würde ich anfangs NICHT machen)

Für Step 1:

👉 lokale Stackvariablen, keine Heapverwaltung.

---

# 4) Kontrollfluss

Was muss v1 unbedingt können?

Minimal:

- `if`
- `while`
- `return`

Optional später:

- `for`
- `match`
- exceptions (teuer!)

Warum wichtig:

- bestimmt IR-Struktur und Jump-Handling.

---

# 5) Funktionen & ABI

Wenn du native x86 willst, musst du das definieren.

## Funktionsmodell

- nur globale Funktionen?
- nested functions?
- closures? (würde ich vermeiden am Anfang)

## Calling Convention

Auf Linux x86_64:

- SysV ABI (rdi, rsi, rdx, rcx, r8, r9)

Wenn du das früh festlegst, bleibt dein Backend stabil.

---

# 6) Builtins / Standardfunktionen

Du brauchst eine minimale Basis — auch ohne „Runtime".

Typische Builtins:

- `exit(code)`
- `PrintStr(ptr, len)` oder `PrintStr("...")`
- später `PrintInt`

Wichtig:

👉 Builtins sind Compiler-Spezialfälle, keine normalen Funktionen.

---

# 7) Fehlerbehandlung & Diagnostik

Viele ignorieren das — später ist es die Hölle.

Sprache sollte definieren:

- Compile-time Errors
- keine Runtime Exceptions in v1
- klare Fehlermeldungen mit Position

Technische Anforderungen:

- jedes Token hat line/column
- AST Nodes behalten SourceSpan

---

# 8) Zielplattform-Abstraktion (für Erweiterbarkeit)

Du willst ja später mehr als x86 Linux.

Die Sprache sollte NICHT enthalten:

- arch-spezifische Keywords
- register names
- syscall numbers

Diese Dinge gehören ins Backend, nicht in die Sprache.

---

# 9) Minimaler v1-Featureumfang (ehrliche Empfehlung)

Wenn du wirklich schnell ein funktionierendes Lyx-Binary sehen willst, würde ich die Sprache für v1 exakt so beschneiden:

- `fn main() { ... }`
- `let x: int = expr;`
- `if (cond) { ... }`
- `while (cond) { ... }`
- `return expr;`
- Builtins:
    - `PrintStr("...")`
    - `exit(n)`

Keine:

- Klassen
- Generics
- Closures
- Heap
- Strings als dynamischer Typ

Das ist nicht „wenig“ — das ist ein realistischer Kern.

---

# 10) Die eigentlichen Kernanforderungen (Kurzliste)

Wenn ich es brutal zusammenkoche, musst du für Lyx zuerst festlegen:

1. An Pascal angelehnt aber ein eignes Stil
2. feste int64
3. Funktionsmodell (global & SysV ABI)
4. Speicher (Stack only v1)
5. Builtins (print/exit)
6. Kontrollfluss (if/while/return)
7. Ziel: Linux x86_64 ELF64

# Lyx v0.2.0 – Keywords (aktualisiert)

## Reservierte Keywords

```
fn var let co con if else while return true false extern
unit import pub as array struct class extends new dispose super static self Self private protected panic assert where value virtual override abstract
```

---

# Bedeutung von `co` und `con`

Du hast zwei Konstanten-Keywords erwähnt. Damit das nicht redundant oder verwirrend wird, empfehle ich eine klare Trennung auf Sprachebene:

## `con` — Compile-time Konstanten (echte Konstanten)

Das sind Werte, die der Compiler **zur Compilezeit vollständig kennt**.

Eigenschaften:

- müssen mit konstantem Ausdruck initialisiert werden
- kein Speicher im Stack
- werden direkt in Code eingebettet (immediate value oder rodata)

Syntax:

```
con MAX: int64 := 10;
con NL: pchar := "\n";
```

Semantik:

- immutable
- global sichtbar
- ideal für Optimierungen (constant folding)

Backend-Konsequenz:

- `int64` → Immediate
- `pchar` → Label in `.rodata`

---

## `co` — Readonly Werte (runtime constant / readonly)

Das sind konstante Variablen, aber nicht zwingend compile-time evaluierbar.

Warum sinnvoll?

Du kannst später Dinge wie Funktionsresultate oder Pointer speichern, die nicht literal sind.

Syntax:

```
co startVal: int64 := get_initial();
```

Regeln:

- nur einmal initialisiert
- danach nicht änderbar
- liegt im Stack (oder global data), nicht als immediate

Technisch ist das näher an:

```
constrefreadonly
```

---

# Unterschied kurz zusammengefasst

| Keyword | Compilezeit bekannt | Speicher | Änderbar |
| --- | --- | --- | --- |
| `con` | ja | nein / rodata | nein |
| `co` | optional | ja | nein |
| `let` | runtime | ja | nein |
| `var` | runtime | ja | ja |

Warum diese Aufteilung gut ist:

- Dein Typchecker bleibt simpel.
- Dein Backend weiß sofort:
    - `con` → kein Stackslot nötig.
    - `co`/`let`/`var` → Stacklayout.

---

# Grammatik-Ergänzung (relevant für Parser)

## Top-Level Deklarationen

```
Decl :=
    FunctionDecl
  | ConDecl
```

## Konstanten

```
ConDecl :="con" IDENT":" Type":=" ConstExpr";"
```

## Readonly Variable

```
ReadonlyDecl :="co" IDENT":" Type":=" Expr";"
```

(Intern kannst du `co` auch als `let` mit Flag `readonly_runtime` modellieren.)

---

## Typsichere Typen (Type Constraints)

Typsichere Typen ermöglichen es, mathematische Beweise an Typen zu hängen, die zur Laufzeit komplett verschwinden.

### Syntax

```
TypeDecl       := 'type' Ident '=' Type [ WhereClause ] ';' ;
WhereClause    := 'where' '{' ConstExpr '}' ;
```

### Semantik

- Die `where`-Klausel definiert eine Bedingung, die der Typ zur Compilezeit erfüllen muss.
- Das spezielle Schlüsselwort `value` repräsentiert den Basistyp in der Bedingung.
- Die Bedingung muss ein konstanter Boolescher Ausdruck sein.
- Wenn die Bedingung keine `value`-Beispiele enthält, wird sie zur Compilezeit ausgewertet.
- Enthält die Bedingung `value`, wird sie als Typ-Constraint akzeptiert (aber nicht zur Compilezeit ausgewertet).

### Beispiele

```lyx
// Einfacher Typ-Constraint (wird zur Compilezeit ausgewertet)
type Positive = int64 where { value > 0 };

// Typ-Constraint mit value (wird akzeptiert, aber nicht ausgewertet)
type Percentage = int64 where { value >= 0 && value <= 100 };

// Beispiel: Verwendung
fn main(): int64 {
  var p: Percentage := 50;  // Gültig
  // var p2: Percentage := 101;  // Würde einen Laufzeitfehler auslösen (in Zukunft: Compilezeitfehler)
  return p;
}
```

### Implementierungshinweise

- Das Schlüsselwort `value` wird in der semantischen Analyse durch den Basistyp ersetzt.
- Die Konstante-Auswertung erfolgt nur für reine konstante Ausdrücke (ohne `value`).
- Der Typ wird im Symbol-Table als `symType` registriert.

---

# Beispielprogramm mit neuen Keywords

```
con LIMIT: int64 := 5;
con MSG: pchar := "Loop\n";

fn main(): int64 {
  co start: int64 := 0;
  var i: int64 := start;

  while (i < LIMIT) {
    PrintStr(MSG);
    i := i + 1;
  }

  return 0;
}
```

---

## Neue Builtins (v0.1.3+)

```lyx
fn main(): int64 {
  var s: pchar := "Hello";
  var l: int64 := strlen(s);     // -> 5
  
  var pi: f64 := 3.14159;
  PrintFloat(pi);               // Ausgabe: ? (Placeholder)
  
  return 0;
}
```

---

# Wichtige Compiler-Implikationsliste (damit du später nicht refactorst)

## Lexer

- `co` und `con` als eigene Tokenarten, nicht Identifier.

## AST

Du brauchst jetzt 4 Storage-Klassen:

```
skVar
skLet
skCo
skCon
```

## IR Lowering

- `con` → `ConstNode`
- `co/let/var` → `LocalSlot`

## Codegen

- `con int64` → immediate
- `con pchar` → rodata label
- `co` → stack slot, aber keine Store-Operation nach Init zulassen

---

## String-Verkettung (v0.4.1)

Der `+` Operator kann für String-Verkettung verwendet werden:

```lyx
fn main(): int64 {
  var s1: pchar := "Hello";
  var s2: pchar := " World";
  var result: pchar := s1 + s2;  // "Hello World"
  return 0;
}
```

**Implementierung:**
- IR: Erkennung von `pchar + pchar` im Lowering
- Runtime: `str_concat` builtin mit inline mmap und memcpy
- Keine externen Dependencies (libc-frei)

---

## Energy-Aware-Compiling (v0.3.1+ ✅ ABGESCHLOSSEN)

Der Lyx-Compiler implementiert Energy-Aware-Compiling, um energieeffizienten Maschinencode zu erzeugen. Dies ist bereits vollständig in den Versionen v0.3.1+ integriert.

### CLI-Option

```bash
lyxc input.lyx -o output --target-energy=<1-5>
```

| Level | Name | Beschreibung |
|-------|------|--------------|
| 1 | Minimal | Loop Unrolling 4×, Battery-Optimierung, Cache-Lokalität |
| 2 | Low | Loop Unrolling 2×, Battery-Optimierung |
| 3 | Medium | Performance-optimiert, SIMD erlaubt |
| 4 | High | Volle Performance, FPU erlaubt |
| 5 | Extreme | Loop Unrolling 8×, AVX512 wenn verfügbar |

### Sprach-Level-Pragma

```lyx
@energy(1)
fn low_energy_function(): int64 {
  // Diese Funktion wird mit Energy-Level 1 compiliert
  return 0;
}

@energy(5)
fn high_performance_function(): int64 {
  // Diese Funktion wird mit Energy-Level 5 compiliert
  return compute_heavy();
}
```

### Energy-Statistiken

Der Compiler gibt nach der Kompilation detaillierte Energie-Statistiken aus:

```
=== Energy Statistics ===
Energy level:           3
CPU family:             1
Optimize for battery:   TRUE

Total ALU operations:   42
Total FPU operations:   0
Total memory accesses:  17
Total branches:         8
Total syscalls:         3

Estimated energy units: 16955
Code size:              846 bytes
L1 cache footprint:     846 bytes
```

### Architektur

- **energy_model.pas**: Zentrale Energy-Konfiguration, CPU-Modelle, Kosten-Tabellen
- **backend_types.pas**: TEnergyLevel, TCPUFamily Enums
- **IR**: EnergyCostHint pro Instruktion, GetIROpEnergyCost()
- **x86_64_emit.pas / arm64_emit.pas**: TrackEnergy(), SetEnergyLevel()
- **Parser**: @energy(level) Attribut vor Funktionen
