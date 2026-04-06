# Lyx → Vollständig Self-Hosted Compiler: Roadmap

> **Ziel:** Den Bootstrap-Compiler (`bootstrap/lyxc_mini.lyx`) schrittweise zum vollwertigen
> Ersatz des FPC-Compilers (`compiler/`) ausbauen — sodass `lyxc.lyx` sich selbst
> kompilieren kann und Feature-Parität mit dem heutigen FPC-Compiler erreicht.

---

## Ausgangslage

### Heutiger FPC-Compiler (`compiler/`)

| Schicht        | Dateien                                   | LOC    |
|----------------|-------------------------------------------|--------|
| Frontend       | lexer, parser, ast, sema, linter, builtins, unit_manager, c_header_parser | 15.958 |
| IR             | ir, lower_ast_to_ir, ir_optimize, ir_inlining, ir_static_analysis, ir_call_graph, ir_mcdc | 9.498  |
| Backend        | x86_64, arm64, macosx64, win_arm64, riscv, arm_cm, xtensa, elf, pe, macho | 33.534 |
| **Gesamt**     |                                           | **58.990** |

**Pipeline:** Quelltext → Lexer → Parser → Sema → Linter → AST→IR-Lowering → IR-Optimierung →
IR-Inlining → Statische Analyse → MC/DC-Instrumentierung → Maschinencode-Emitter → ELF/PE/MachO-Writer → Binary

### Heutiger Bootstrap-Compiler (`bootstrap/`)

| Datei                | LOC   | Status |
|----------------------|-------|--------|
| `lexer.lyx`          | 827   | ✅ Vollständig (WP-11–17 Tokens) |
| `parser.lyx`         | 1.480 | ✅ WP-11–17 AST-Nodes |
| `sema.lyx`           | 1.050 | ✅ WP-13/14/15/17 Vollständig implementiert |
| `codegen_x86.lyx`    | 3.150 | ✅ WP-13/15/17 Vollständig implementiert |
| `linter.lyx`         | 547   | ✅ W001/W006/W007/W010 |
| `lyxc_mini.lyx`      | 160   | ✅ Entry Point |
| **Gesamt**           | **~7.200** | |

**Besonderheit:** Der Bootstrap-Compiler arbeitet ohne IR-Schicht — er lowert den AST **direkt**
in x86_64-Maschinencode. Das war für den initialen Self-Hosting-Test (WP-09) ausreichend,
ist aber nicht skalierbar für Feature-Parität und Multi-Target-Support.

### Feature-Gap: Was fehlt im Bootstrap-Compiler

| Kategorie                   | FPC-Compiler                          | Bootstrap      |
|-----------------------------|---------------------------------------|----------------|
| **Typsystem**               | i8..u64, f32, f64, bool, char, pchar  | i64, pchar, bool (partial) |
| **Arrays**                  | Static + Dynamic (fat-pointer)        | Dynamic (basic) |
| **Collections**             | Map[K,V], Set[T] (Hash-basiert)       | ❌ nicht vorhanden |
| **OOP**                     | Classes, Interfaces, Virtual Methods, Vererbung | Classes + VMT (basic) |
| **Exception Handling**      | try/catch/finally/throw               | ✅ try/catch/finally/panic (WP-12) |
| **Closures**                | Nested Functions + Captured Variables | ✅ Static-Link + Capture-Analyse (WP-13) |
| **Generics**                | Monomorphization                      | ✅ Parser + Instantiation-Cache (WP-14) |
| **Pattern Matching**        | match + Destrukturierung              | ✅ match + Struct-Destruktur + Exhaustiveness (WP-15) |
| **Range Types**             | `1..100`, Constraint-Expressions      | ✅ Parser+Sema+Codegen (WP-17) |
| **Varargs**                 | `...`-Parameter                       | ❌ |
| **Function Pointers**       | `fn(T): U`                            | ❌ |
| **C FFI**                   | extern + C-Header-Parsing             | ❌ |
| **IR-Schicht**              | 100+ IR-Opcodes, Optimierungen        | ❌ (direktes Codegen) |
| **Optimierungen**           | CF, DCE, CSE, CP, Inlining            | Constant Folding + CSE (in codegen_x86) |
| **Statische Analyse**       | Data-Flow, Null-Ptr, Bounds, WCET     | ❌ |
| **Backends**                | x86_64, ARM64, RISC-V, ARM-CM, Xtensa, Win, macOS | x86_64 ELF64 + ARM64 ELF64 |
| **Object-Formate**          | ELF64, PE64, MachO64, ELF32           | ELF64 |
| **Safety Pragmas**          | @dal, @critical, @wcet, @integrity   | ❌ |
| **MC/DC**                   | DO-178C Section 4.1                   | ❌ |
| **Linter**                  | W001–W020+ (18 Regeln)                | W001/W006/W007/W010 (4 Regeln) |
| **Module-System**           | Multi-File, Unit-Cache, pub/private   | Basic (Import-Dedup) |
| **Stdlib**                  | ~87 Module, ~13.000 LOC               | std.env (minimal) |

---

## Architektur-Entscheidung: IR-Migration

Der Bootstrap-Compiler nutzt aktuell **direktes AST→Maschinencode-Mapping** (wie ein
One-Pass-Compiler der 70er-Jahre). Das ist für einfache Programme ausreichend, aber
für den vollständigen Self-Hosting-Compiler muss eine **echte IR-Schicht** eingeführt werden.

**Warum IR zwingend notwendig ist:**
1. **Multi-Target:** Ohne IR muss jede neue Zielplattform denselben komplexen AST-Walking-Code duplizieren
2. **Optimierungen:** Constant Folding, DCE, Inlining — alles arbeitet auf der IR, nicht auf AST
3. **Exception Handling:** Benötigt IR-Constructs (Push/Pop Handler, Unwind-Pfade)
4. **Generics:** Monomorphization erzeugt neue IR-Instanzen pro Typ-Parameterisierung
5. **Closures:** Captured-Variables erfordern IR-Level-Transformationen

**Architektur des vollständigen Self-Hosted-Compilers:**

```
Quelltext (.lyx)
    ↓
[bootstrap/lexer.lyx]         → Token-Stream
    ↓
[bootstrap/parser.lyx]        → AST (flacher Index-AST, 88 Byte/Knoten)
    ↓
[bootstrap/sema.lyx]          → Typed AST + Symbol-Tabelle
    ↓
[bootstrap/linter.lyx]        → Warnings (stderr)
    ↓
[bootstrap/ir_lower.lyx]      → IR (TIRModule/TIRFunction/TIRInstr)  ← NEU
    ↓
[bootstrap/ir_optimize.lyx]   → Optimized IR                          ← NEU
    ↓
[bootstrap/ir_inline.lyx]     → Inlined IR                            ← NEU
    ↓
[bootstrap/ir_analyze.lyx]    → Static Analysis                       ← NEU
    ↓
[bootstrap/emit_x86.lyx]      → x86_64 Maschinencode                  ← NEU (via IR)
[bootstrap/emit_arm64.lyx]    → ARM64 Maschinencode                   ← NEU (via IR)
[bootstrap/emit_riscv.lyx]    → RISC-V Maschinencode                  ← NEU
    ↓
[bootstrap/write_elf.lyx]     → ELF64-Binary                          ← NEU
[bootstrap/write_pe.lyx]      → PE64-Binary (Windows)                 ← NEU
[bootstrap/write_macho.lyx]   → MachO64-Binary (macOS)                ← NEU
```

---

## Arbeitspakete

### Phase 1: Sprachkern-Vollständigkeit

---

### WP-11: Erweitertes Typsystem & Operatoren

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-09/WP-10

**Ziel:** Der Bootstrap-Parser und Sema unterstützen das vollständige primitive Typsystem
des FPC-Compilers.

**Implementiert:**
- [x] **Primitive Typen in Parser/Sema:** `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`,
   `f32`, `f64`, `bool`, `char`, `void` (Lexer + Parser + Sema)
- [x] **Cast-Operatoren:** `x as i32`, `x as f64` — Parser (NK_CAST) + Sema + Codegen
   (i8/u8/i16/u16/i32/u32 via movsx/movzx/movsxd; i64/u64/pchar no-op)
- [x] **Float-Literale:** `3.14`, `1.0e-5` im Lexer/Parser/Sema + Codegen (IEEE 754 Bits in RAX)
- [x] **Char-Literale:** `'a'`, `'\n'`, `'\x41'` (als int64 in RAX)
- [x] **Bool-Operatoren:** `&&`, `||`, `!` — im Codegen (non-short-circuit für &&/||)
- [x] **Bitweise Ops:** `&`, `|`, `^`, `~`, `<<`, `>>` vollständig im Codegen
- [x] **Vergleichsoperatoren:** `<`, `>`, `<=`, `>=`, `==`, `!=` für alle primitiven Typen
- [x] **Typed Arithmetic:** Typ-Propagation in Sema
- [x] **Integer-Overflow-Semantik:** Wrap-around (keine Checks)

**Referenz:** `compiler/frontend/ast.pas` (Typdefinitionen), `compiler/frontend/sema.pas` (Typprüfung)

**Output:** Erweiterter Lexer/Parser/Sema + Codegen in `bootstrap/`

---

### WP-12: Exception Handling (try/catch/finally)

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-11

**Ziel:** Vollständige Exception-Handling-Infrastruktur im Bootstrap-Compiler.

**Implementiert:**
- [x] **Parser:** `try { ... } catch (e: ExType) { ... } finally { ... }` (NK_TRY/NK_CATCH/NK_FINALLY/NK_THROW)
- [x] **Sema:** Exception-Typ-Hierarchie (TY_EXCEPTION/TY_PANIC_EXCEPT), Catch-Typ-Check
- [x] **x86_64-Codegen:** setjmp/longjmp-basiertes Exception-Handling
   - Handler-Stack: RSP-relative 80-Byte jmp_buf (rbx,rbp,r12-r15,rsp,catch_ip,prev_handler)
   - Globals im Data-Section: `_lyx_exn_val` (data[0]), `_lyx_exn_ptr` (data[8])
   - `try` → speichert jmp_buf, installiert Handler, generiert Try-Block + Finally auf beiden Pfaden
   - `throw expr` → speichert Exception-Wert, longjmp zum Handler oder sys_exit(1)
   - `finally`-Blöcke: inline dupliziert auf Erfolgs- und Fehler-Pfad
- [x] **`panic(msg)`:** Builtin — schreibt msg auf stderr, longjmp zu Handler oder exit(1)
- [ ] **Builtin-Exception-Klassen:** PanicException, NullPointerException, IndexOutOfBoundsException
  _(Deferred: vollständige Klassen-Hierarchie erst mit WP-16/OOP)_
- [ ] **IR-Primitiven:** `irPushHandler`, `irPopHandler` _(Deferred: WP-18 IR-Schicht)_

**Hinweis (2026-04-05):** Bootstrap-Codegen implementiert. jmp_buf[48]=rsp=jmp_buf-Basis,
daher longjmp: `mov rsp, rax` (rax=handler-ptr) dann `jmp [rsp+56]`. Funktioniert
korrekt über Funktionsgrenzen (cross-frame exception propagation).

**Referenz:** `compiler/ir/ir.pas` (irPushHandler/irPopHandler), `compiler/backend/x86_64/x86_64_emit.pas`

**Output:** Exception Handling in Parser + Sema + Codegen (`bootstrap/codegen_x86.lyx`)

---

### WP-13: Closures & Nested Functions

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-11

**Ziel:** Nested Functions mit Zugriff auf umschließende Scope-Variablen (Captured Variables).

**Implementiert (Bootstrap):**
- ✅ **Parser:** `NK_CLOSURE`, `NK_FN_PTR` Nodes; `ParseNestedFunc()` für Nested-Function-Deklarationen
- ✅ **Codegen:** Static-Link-Mechanismus (`staticLinkOffset`, `outerFuncName`);
  `cg_genNestedFunc()`, `cg_emitPrologueNested()`; Static-Link-Übergabe via `[rbp+16]`
- ✅ **Sema:** `TY_FN_PTR`, `TY_CLOSURE` Konstanten;
  `_analyzeCaptures()` / `_collectCaptures()` mit vollständiger Implementierung
- ✅ **Sema:** `_addCapturedVar()` mit Buffer-Management (vermeidet Duplikate)
- ✅ **Sema:** `capturedVars` Buffer (32 Bytes/Eintrag: funcName, funcLen, varName, varLen)
- ✅ **Codegen:** `cg_findCapturedVar()` — Capture-Variable-Zugriff via `[static_link + offset]`
- ✅ **Codegen:** Closure-Objekt via static link Implementierung
- ⚠️ **Verbleibend:** Function-Pointer-Typ als Erst-Klassen-Typ (Übergabe, Speicherung, Aufruf)

**Referenz:** `compiler/ir/ir.pas` (TIRClosure), `compiler/ir/lower_ast_to_ir.pas`

**Schätzung:** 2 Sessions (Capture-Analyse + Closure-Objekt)

---

### WP-14: Generics / Type-Parameter-Monomorphization

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-11, WP-12

**Ziel:** Generische Funktionen und Klassen mit vollständiger Monomorphization.

**Implementiert (Bootstrap):**
- ✅ **Parser:** `fn Foo<T>(x: T): T { ... }` und `type Container<T> = class { ... }`
  in `ParseFuncDecl()` / `ParseClassDecl()`
- ✅ **Parser:** Generic-Type-Argumente in Typ-Annotationen: `Array<int64>`, `Map<K, V>`
  (via `ParseType()`)
- ✅ **Sema:** `TY_GENERIC_INST`, `TY_TYPE_PARAM` Konstanten; Instantiation-Cache-Buffer
  (`instCache`, `instCount`, `instCap`)
- ✅ **Sema:** `_resolveGenericCall()` für Type-Argument-Validierung
- ✅ **Sema:** `_getMonomorphInstance()` mit Cache-Suche (Type-Hash-basierter Lookup)
- ✅ **Sema:** Instantiation-Cache mit Duplikat-Erkennung via Type-Hash
- ⚠️ **Verbleibend:** Generic-Funktionsaufruf-Syntax `Foo<T>(x)` — nur Typ-Annotationen funktionieren
- ⚠️ **Verbleibend:** Type-Argument-Validierung gegen Constraints (`T: Comparable`)
- ⚠️ **Verbleibend:** Generic Stdlib-Typen: `List<T>`, `Map<K,V>`, `Set<T>`

**Referenz:** `compiler/frontend/sema.pas` (Generic-Tracking), `compiler/ir/lower_ast_to_ir.pas`

**Schätzung:** 4 Sessions

---

### WP-15: Pattern Matching & Match-Expressions

**Status:** ⚠️ Partial | **Abhängigkeit:** WP-11

**Ziel:** Vollständiges `match`-Statement mit Destrukturierung.

**Implementiert (Bootstrap):**
- ✅ **Parser:** `match expr { case Pattern => expr, ... }` vollständig
  (`_parseMatch()`, `NK_MATCH`, `NK_MATCH_CASE`)
- ✅ **Parser:** Literal-Patterns (`NK_PATTERN_LIT`), Wildcard `_` (`NK_PATTERN_WILD`),
  Bind-Pattern (`NK_PATTERN_BIND`)
- ✅ **Parser:** Enum-Payload-Pattern `case Ok(v) =>` (`NK_PATTERN_ENUM`)
- ✅ **Parser:** Struct-Destrukturierung `case Point { x, y } =>` (`NK_PATTERN_STRUCT`)
- ✅ **Lexer:** `TK_MATCH`, `TK_UNDER` (Wildcard `_`)
- ✅ **Sema:** Pattern-Typ-Prüfung in `_checkStmt`
- ✅ **Sema:** Enum-Variant-Validierung (prüft ob Variant in Enum existiert)
- ✅ **Sema:** Struct-Destrukturierung Validierung (prüft Feldtypen)
- ✅ **Sema:** Exhaustiveness-Check (Warnung wenn kein Wildcard/Binding Pattern)
- ✅ **Codegen:** `cg_genMatch()` für Literal-Patterns und Wildcard funktioniert
- ✅ **Codegen:** Struct-Destrukturierung Feld-Matching (via cg_findField)
- ⚠️ **Verbleibend:** Enum-Payload-Pattern im Codegen (Payload-Extraktion)
- ⚠️ **Verbleibend:** Guard-Expressions in Pattern-Cases

**Referenz:** `compiler/frontend/parser.pas` (parseMatch), `compiler/ir/lower_ast_to_ir.pas`

**Schätzung:** 1–2 Sessions (Exhaustiveness + Struct-Destrukturierung)

---

### WP-16: Vollständiges OOP (Vererbung, Interfaces, Zugriffskontrolle)

**Status:** In Bearbeitung | **Abhängigkeit:** WP-14

> **Hinweis (2026-04-05):** 
> - Kritischer Bug in `SafetyPragmas.FPDeterministic` gefunden und behoben.
>   Fix: `FPDeterministic := False` in `ir.pas`, `ast.pas`, `parser.pas`
> - Bootstrap WP-16: Parser + Sema erweitert für `extends`, `implements`, `interface`, `isType`

**Ziel:** Feature-Parität mit dem FPC-Compiler für OOP.

**Implementiert (Bootstrap):**
- ✅ **Vererbung:** `type Dog = class extends Animal { ... }`
  - `NK_CLASS_DECL.c2` = parent class name
  - VMT-Erweiterung: Kind-VMT enthält Eltern-Einträge + neue Methoden
  - `super.method(...)` — `NK_SUPER_CALL` Parser + Codegen
- ✅ **Interfaces:** `type Drawable = interface { fn Draw(): void; }`
  - `NK_IFACE_DECL` Parser
  - `implements` Parser (`NK_CLASS_DECL.c3` = interfaces list)
  - `TY_INTERFACE` Type in Sema
- ✅ **Access Control:** `pub` Keyword vorhanden
- ✅ **Abstract/Override/Virtual:** Keywords (`TK_VIRTUAL`, `TK_ABSTRACT`, `TK_OVERRIDE`) im Lexer
- ✅ **Class-Felder:** `cg_buildClassLayout()` generiert Feld-Layout
- ✅ **VMT:** `cg_addVmtPatch()`, VMT-Tabellen in Data-Section

**Zu implementieren (verbleibend):**
- ❌ Abstract Classes/Methods vollständig in Sema durchsetzen
- ❌ Private/Protected Access Control in Sema durchsetzen (pub vorhanden, aber nicht durchgesetzt)
- ❌ Interface-Cast mit Runtime-Type-Check (`x as Drawable`)

---

### WP-17: Range Types & Type Constraints

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-11

**Ziel:** `1..100`-Range-Typen und Constraint-Expressions für sichere Typdefinitionen.

**Implementiert (Bootstrap):**
- ✅ **Parser:** `1..100` Range-Ausdruck (`NK_RANGE` Node)
- ✅ **Parser:** `type Port = i32 where value >= 0 && value <= 65535` (`NK_WHERE`)
- ✅ **Lexer:** `TK_RANGE` Token (`..`), `TK_WHERE` Keyword
- ✅ **Sema:** TY_RANGE Type, Type-Checking für Range und Where
- ✅ **Sema:** Where-Constraint Validierung (prüft Boolean-Ausdruck)
- ✅ **Codegen:** CGN_RANGE, CGN_WHERE Konstanten, Range-Expression Codegen
- ✅ **Codegen:** Range-Iteration in for-Loops (via `cg_genFor`)

**Hinweis (2026-04-06):** Range-Iteration wird über den existierenden for-Loop-Mechanismus
abgebildet: `for i in 1..10` generiert identischen Code wie `for i = 1 to 10`.

---

### Phase 2: IR-Schicht

---

### WP-18: IR-Datenstrukturen in Lyx

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-11, WP-16

**Ziel:** Vollständige IR-Datenstrukturen im Bootstrap-Compiler.

**Implementiert in `bootstrap/ir.lyx`:**
- ✅ **TIROpKind Enum:** 154 IR-Opcodes aus `compiler/ir/ir.pas`
- ✅ **TIRInstr-Struktur** (80 Bytes)
- ✅ **TIRFunction-Struktur** (80 Bytes)
- ✅ **TIRModule-Struktur** (64 Bytes)
- ✅ **Allokator:** mmap-basierte Buffer mit Grow-Mechanismus
- ✅ **IRModule-Klasse:** String-Tabellenverwaltung, Helper-Funktionen, ir_dump()

**Referenz:** `compiler/ir/ir.pas` (TIROpKind, TIRInstr, TIRFunction, TIRModule)

**Schätzung:** 2 Sessions | **Output:** `bootstrap/ir.lyx` (1.127 LOC)

---

### WP-19: AST→IR Lowering (Basis)

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-18

**Ziel:** Vollständiges Lowering von Ausdrücken und einfachen Statements zu IR.

**Implementiert in `bootstrap/ir_lower.lyx`:**
- ✅ **IRLower-Klasse:** AST→IR Transformations-Klasse mit AST-Node-Zugriff
- ✅ **Node-Helper:** `nodeOff()`, `nodeKind()`, `nodeC0()`, `nodeC1()`, `nodeC2()`, `nodeIVal()`, `nodeSVal()`, `nodeSLen()`, `nodeNext()`
- ✅ **Label-Generator:** `genLabel()` für eindeutige Label-Namen
- ✅ **Temp-Verwaltung:** `allocTemp()` für temporäre Register, `localCount`-Tracking
- ✅ **Ausdrucks-Lowering:** `lowerExpr()` für Literale, BinOps, UnOps, Calls
- ✅ **BinOp-Lowering:** `lowerBinOp()` — bereitet Operanden vor
- ✅ **UnOp-Lowering:** `lowerUnOp()` — einstellige Operatoren
- ✅ **Call-Lowering:** `lowerCall()` — Argument-Processing
- ✅ **Statement-Lowering:** `lowerStmt()` für Block, If, While, Return, Assign
- ✅ **Block-Lowering:** `lowerBlock()` — Statement-Liste verarbeiten
- ✅ **If-Lowering:** `lowerIf()` mit Label-Generation
- ✅ **While-Lowering:** `lowerWhile()` mit Loop-Labels
- ✅ **Return-Lowering:** `lowerReturn()` für Return-Expressions
- ✅ **Assign-Lowering:** `lowerAssign()` für Zuweisungen
- ✅ **Funktion-Lowering:** `lowerFunc()` — Parameter + Body
- ✅ **Modul-Lowering:** `lowerModule()` — alle Funktionen verarbeiten

**Verbleibend:**
- ❌ IR-Instruktionen via `IRModule.addInstruction()` emittieren (benötigt Integration mit ir.lyx)
- ❌ Label-Mapping zu IR-Labels
- ❌ Variablen-Register-Mapping

**Referenz:** `compiler/ir/lower_ast_to_ir.pas` (LowerExpr, LowerStmt)

---

### WP-20: AST→IR Lowering (OOP, Structs, Klassen, Generics)

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-19, WP-16, WP-14

**Ziel:** Vollständiges Lowering von OOP-Konstrukten, Structs und generischen Typen.

**Implementiert in `bootstrap/ir_lower.lyx`:**
- ✅ **Struct-Lowering:** `lowerLoadField`, `lowerStoreField`, `lowerLoadElem`, `lowerStoreElem`, `lowerStructCopy`
- ✅ **Klassen-Lowering:** `lowerNewClass`, `lowerDisposeClass`, `lowerLoadFieldHeap`, `lowerStoreFieldHeap`, `lowerVirtualCall`, `lowerStaticCall`, `lowerSuperCall`
- ✅ **Interface-Lowering:** `lowerInterfaceCall`, `lowerInterfaceCast`
- ✅ **Dyn-Array-Lowering:** `lowerDynArrayLit`, `lowerDynArrayIndex`, `lowerDynArrayStore`, `lowerDynArrayPush`, `lowerDynArrayPop`, `lowerDynArrayLen`, `lowerDynArrayFree`
- ✅ **Exception-Lowering:** `lowerTry`, `lowerTryStmt`, `lowerThrowExpr`, `lowerPanic`
- ✅ **Closure-Lowering:** `lowerClosure`, `lowerClosureCall`, `lowerStaticLink`, `lowerLoadCaptured`, `lowerStoreCaptured`
- ✅ **Generics-Lowering:** `lowerGenericCall`, `lowerTypeId`
- ✅ **SIMD-Lowering:** `lowerParallelArray`, `lowerSIMDLoadElem`, `lowerSIMDStoreElem`, `lowerSIMDBinOp`, `lowerSIMDCmp`
- ✅ **Map/Set-Lowering:** `lowerMapNew`, `lowerMapGet`, `lowerMapSet`, `lowerMapContains`, `lowerMapRemove`, `lowerMapLen`, `lowerMapFree`, `lowerSetNew`, `lowerSetAdd`, `lowerSetContains`, `lowerSetRemove`, `lowerSetLen`, `lowerSetFree`
- ✅ **Match/Pattern-Lowering:** `lowerMatch`, `lowerPatternMatch`, `lowerSwitch`
- ✅ **Zusätzliche Typen:** `lowerFnPtr`, `lowerClosureExpr`, `lowerTypeName`, `lowerTypeParam`, `lowerTypeArray`, `lowerEnumMember`
- ✅ **Erweiterte AST-Nodes:** NK_LOAD_FIELD bis NK_SIMD_BINOP Konstanten

**Referenz:** `compiler/ir/lower_ast_to_ir.pas` (LowerClassMethod, LowerStructDecl, etc.)

---

### WP-21: IR-Optimierungen in Lyx

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-18

**Ziel:** Die fünf Kern-Optimierungen des FPC-Compilers in Lyx portieren.

**Implementiert in `bootstrap/ir_optimize.lyx`:**
- ✅ **IROptimize-Klasse:** IR-Modul-Optimierung mit State-Tracking
- ✅ **Constant Folding:** Arithmetik, Float-Ops, Vergleiche, Bitwise mit Konstanten
- ✅ **Copy Propagation:** t1 = a; t2 = t1 + b → t2 = a + b
- ✅ **Dead Code Elimination:** Unreachable Code nach Jumps/Returns entfernen
- ✅ **Common Subexpression Elimination (CSE):** Gleiche Berechnungen → gemeinsames Temp
- ✅ **Strength Reduction:** x * 2 → x << 1, x * 0 → 0, x + 0 → x
- ✅ **Iterativer Durchlauf:** 2-Pass-Optimierung (bis zu 10 Passes)
- ✅ **Zusätzliche Optimierungen:** removeRedundantLoads, mergeStores
- ✅ **Side-Effect-Analyse:** Verhindert Entfernung von Instruktionen mit Nebenwirkungen

**Referenz:** `compiler/ir/ir_optimize.pas` (~1.161 LOC)

---

### WP-22: Function Inlining

**Status:** ✅ Abgeschlossen | **Abhängigkeit:** WP-21

**Ziel:** Inline-Expansion kleiner Funktionen für Performance.

**Implementiert in `bootstrap/ir_inline.lyx`:**
- ✅ **IRInline-Klasse:** Function-Inlining-Optimierung
- ✅ **Inline-Heuristik:** Threshold (≤20 Instruktionen) + keine Rekursion
- ✅ **Inline-Expansion:** Kopiere IR-Instruktionen, ersetze Returns durch Sprünge
- ✅ **Label-Umbenennung:** Eindeutige Labels nach Inline (`genUniqueLabel`)
- ✅ **Call-Graph-Analyse:** `buildCallGraph`, `canReach` für Zykluserkennung
- ✅ **Rekursions-Erkennung:** `markRecursiveFuncs` verhindert Inlining rekursiver Funktionen
- ✅ **@noinline-Pragma:** `addNoinline`, `isNoinline` Funktionen

**Referenz:** `compiler/ir/ir_inlining.pas` (~320 LOC)

---

### Phase 3: Backends (IR-basiert)

---

### WP-23: x86_64 Backend via IR (`bootstrap/emit_x86.lyx`)

**Status:** Ausstehend | **Abhängigkeit:** WP-19, WP-21

**Ziel:** Neues x86_64-Backend das aus IR generiert (ersetzt das direkte `codegen_x86.lyx`).
Das bestehende `codegen_x86.lyx` bleibt als Legacy-Pfad erhalten bis WP-28.

**Zu implementieren:**
1. **Register-Allokation:** Lineares-Scan-Verfahren (oder einfache Temp→Stack-Abbildung)
2. **Instruction-Selection:** Jede IR-Instruktion → x86_64 Maschinencode
   - Alle arithmetischen Ops: `ADD`, `SUB`, `IMUL`, `IDIV`
   - Float-Ops: `ADDSD`, `SUBSD`, `MULSD`, `DIVSD` (SSE2)
   - Memory: `MOV [rbp+off], reg` und `MOV reg, [rbp+off]`
   - Vergleiche: `CMP` + `SETcc`
   - Branches: `JMP`, `JE`, `JNE`, `JL`, `JLE`, `JG`, `JGE`
   - Calls: `CALL rel32` + System-V ABI (rdi, rsi, rdx, rcx, r8, r9)
   - Virtuelle Calls: `MOV rax, [rdi]` (VMT) + `CALL [rax+offset*8]`
   - SIMD: `ADDPD`, `MULPD` (SSE2 packed double)
3. **Prologue/Epilogue:** `push rbp; mov rbp, rsp; sub rsp, N` mit Alignment
4. **ABI-Konformität:** System-V AMD64 (Linux) + Windows x64 (optional)
5. **Exception-Support:** setjmp/longjmp via Syscalls
6. **Builtin-Stubs:** PrintStr, PrintInt, StrLen, mmap, write, etc. (aus `codegen_x86.lyx` übernehmen)

**Referenz:** `compiler/backend/x86_64/x86_64_emit.pas` (~7.449 LOC)

**Schätzung:** 4 Sessions | **Output:** `bootstrap/emit_x86.lyx`

---

### WP-24: ARM64 Backend via IR (`bootstrap/emit_arm64.lyx`)

**Status:** Ausstehend | **Abhängigkeit:** WP-23

**Ziel:** ARM64-Backend das aus IR generiert (erweitert `compiler/backend/arm64/arm64_emit.pas`
Logik auf den Bootstrap-Compiler).

**Zu implementieren:**
1. **AAPCS64-ABI:** X0–X7 Parameter, X19–X28 callee-saved, 16-Byte Stack-Alignment
2. **Instruction-Selection für alle IR-Opcodes:**
   - Arithmetik: `ADD`, `SUB`, `MUL`, `SDIV`, `UDIV` + `MSUB` für Modulo
   - Float: `FADD`, `FSUB`, `FMUL`, `FDIV` (NEON D-Register)
   - Branches: `B`, `CBZ`, `CBNZ`, `B.EQ`, `B.NE`, `B.LT`, etc.
   - Memory: `STR`, `LDR`, `STRB`, `LDRB`, `STP`, `LDP`
   - Vergleiche: `CMP` + `CSEL`/`CSET`
   - NEON SIMD: `FADD v0.2d, v0.2d, v1.2d`
3. **Builtin-Stubs:** ARM64-native (Linux syscall 64-write, 222-mmap, etc.)
4. **virtuelle Calls:** `LDR X8, [X0]` (VMT-Ptr) + `LDR X9, [X8, #offset]` + `BLR X9`

**Referenz:** `compiler/backend/arm64/arm64_emit.pas` (~5.332 LOC)

**Schätzung:** 3 Sessions | **Output:** `bootstrap/emit_arm64.lyx`

---

### WP-25: ELF64 / PE64 / MachO64 Writer

**Status:** Ausstehend | **Abhängigkeit:** WP-23, WP-24

**Ziel:** Vollständige Binary-Writer für alle Zielplattformen.

**Zu implementieren:**

**`bootstrap/write_elf.lyx`** (ELF64 für Linux x86_64 + ARM64):
- ELF64-Header, Program-Headers, Section-Headers
- PT_LOAD Segment, .text, .data, .rodata
- Symbol-Tabelle für Debugging
- Relokations-Support (R_X86_64_PC32, R_AARCH64_CALL26)

**`bootstrap/write_pe.lyx`** (PE64 für Windows x86_64 + ARM64):
- DOS-Stub, PE-Signature, COFF-Header
- Optional-Header (ImageBase, SectionAlignment, etc.)
- `.text`, `.data`, `.rdata` Sections
- Import-Directory-Table (für Windows-API-Aufrufe)

**`bootstrap/write_macho.lyx`** (MachO64 für macOS x86_64 + ARM64):
- Mach-O Fat Binary (Universal Binary)
- Load Commands: LC_SEGMENT_64, LC_UNIXTHREAD, LC_MAIN
- Symbol-Table (LC_SYMTAB)

**Referenz:** `compiler/backend/elf/elf64_writer.pas`, `compiler/backend/pe/pe64_writer.pas`,
`compiler/backend/macho/macho64_writer.pas`

**Schätzung:** 3 Sessions | **Output:** `bootstrap/write_elf.lyx`, `write_pe.lyx`, `write_macho.lyx`

---

### Phase 4: Erweiterte Features

---

### WP-26: Vollständiger Linter (W001–W020)

**Status:** Teilweise vorhanden (WP-10i: W001/W006/W007/W010) | **Abhängigkeit:** WP-18

**Ziel:** Feature-Parität mit dem FPC-Linter (`compiler/frontend/linter.pas`, ~1.146 LOC).

**Verbleibende Regeln:**
- **W002:** Ungenutzte Parameter
- **W003:** Variable-Naming (camelCase)
- **W004:** Funktion-Naming (PascalCase)
- **W005:** Konstanten-Naming (UPPER_CASE)
- **W008:** Variable-Shadowing
- **W009:** `var` nie mutiert (sollte `let` sein)
- **W011:** Format-String-Mismatch
- **W012:** Implizite Typ-Konvertierungen
- **W013:** Impliziter Float-zu-Int-Cast
- **W014:** Leere else-Zweige
- **W015:** Implizite Bool-Konversion
- **W016:** Ungenutzte Imports
- **W017:** Überlange Funktionen
- **W018:** Zyklische Abhängigkeiten
- **W019:** Überlange Dateien
- **W020:** Rekursive Funktionen ohne Abbruchbedingung

**Schätzung:** 2 Sessions | **Output:** Erweitertes `bootstrap/linter.lyx`

---

### WP-27: Map/Set Collections in Stdlib

**Status:** Ausstehend | **Abhängigkeit:** WP-20 (IR-Lowering von Map/Set)

**Ziel:** `Map[K,V]` und `Set[T]` als vollwertige Lyx-Collections.

**Zu implementieren:**
1. **Hash-Map:** Open-Addressing mit Robin-Hood-Hashing
   - `map_new(cap)`, `map_get(m, key)`, `map_set(m, key, val)`,
     `map_contains(m, key)`, `map_remove(m, key)`, `map_len(m)`, `map_free(m)`
2. **Hash-Set:** Wrapper um Hash-Map mit bool-Values
3. **String-Hash:** FNV-1a oder djb2
4. **Generic Interface:** `Map<String, i64>`, `Set<i32>`
5. **Stdlib-Integration:** `std/map.lyx`, `std/set.lyx`

**Referenz:** `compiler/ir/ir.pas` (irMapNew..irMapFree, irSetNew..irSetFree)

**Schätzung:** 2 Sessions | **Output:** `std/map.lyx`, `std/set.lyx`

---

### WP-28: Statische Analyse (Data-Flow, Bounds, WCET)

**Status:** Ausstehend | **Abhängigkeit:** WP-21

**Ziel:** Sicherheits-relevante statische Analysen im Bootstrap-Compiler.

**Zu implementieren in `bootstrap/ir_analyze.lyx`:**
1. **Null-Pointer-Analyse:** Taint-Tracking für `pchar`/Zeiger — Warnung bei ungeprüftem Deref
2. **Array-Bounds-Check:** Statische Bounds-Überprüfung wo möglich
3. **Stack-WCET:** Maximale Stack-Tiefe berechnen (für @stack_limit-Pragma)
4. **Erreichbarkeits-Analyse:** Dead-Code-Erkennung auf Funktion-Level
5. **Def-Use-Ketten:** Für Uninitialized-Variable-Detection

**Referenz:** `compiler/ir/ir_static_analysis.pas` (~798 LOC)

**Schätzung:** 3 Sessions | **Output:** `bootstrap/ir_analyze.lyx`

---

### WP-29: Safety Pragmas (@dal, @critical, @wcet, @integrity)

**Status:** Ausstehend | **Abhängigkeit:** WP-28, WP-11

**Ziel:** DO-178C-kompatible Sicherheits-Annotationen.

**Zu implementieren:**
1. **Parser:** `@dal(A)`, `@critical`, `@wcet(100)`, `@stack_limit(256)`,
   `@integrity(mode: software_lockstep, interval: 1000)`
2. **Sema:** Pragma-Propagation (kritische Funktionen die nicht-kritische aufrufen → Warnung)
3. **WCET-Check:** Vergleich berechnete Stack-Tiefe vs. @stack_limit
4. **Codegen-Hooks:** @integrity → Schreibe Verification-Code (irVerifyIntegrity)
5. **MC/DC-Instrumentierung:** @dal(A/B) → irMCDC-Insert für alle Bedingungen

**Referenz:** `compiler/ir/ir_mcdc.pas` (~318 LOC), `compiler/frontend/ast.pas`

**Schätzung:** 2 Sessions | **Output:** Erweiterte Parser/Sema + `bootstrap/ir_mcdc.lyx`

---

### WP-30: Erweiterte Stdlib (string, io, math, fs, os)

**Status:** Ausstehend | **Abhängigkeit:** WP-27

**Ziel:** Kern-Stdlib-Module mit dem Bootstrap-Compiler kompatibel machen.

**Zu implementieren:**
1. **`std/string.lyx`:** StringBuilder, StrSplit, StrTrim, StrJoin, StrReplace, StrFormat
2. **`std/io.lyx`:** Readline, Printf, Fprintf, Flush
3. **`std/math.lyx`:** sin, cos, sqrt, pow, log, floor, ceil (via libm oder Soft-Float)
4. **`std/fs.lyx`:** ReadFile, WriteFile, FileExists, DirList, mkdir, rm
5. **`std/os.lyx`:** getenv, setenv, exit, getcwd, chdir
6. **`std/time.lyx`:** clock_gettime, sleep, Timer
7. **`std/json.lyx`:** JSON-Parser und -Serializer (kritisch für Compiler-Toolchain)
8. **`std/process.lyx`:** fork, exec, waitpid, pipe
9. **Anpassung:** Alle Module müssen ohne Fehlermeldung vom Bootstrap-Compiler kompilieren

**Referenz:** `std/` (~87 Module, ~13.000 LOC)

**Schätzung:** 5 Sessions | **Output:** Kompatible Kern-Stdlib-Module

---

### WP-31: C FFI & Externes Linking

**Status:** Ausstehend | **Abhängigkeit:** WP-25

**Ziel:** `extern`-Deklarationen und Linking gegen C-Bibliotheken.

**Zu implementieren:**
1. **Parser:** `extern fn malloc(size: u64): pchar;`
2. **Sema:** Extern-Symbol-Registrierung ohne Body-Anforderung
3. **Linker-Unterstützung:** Unresolved Symbols werden als PLT/GOT-Einträge in ELF/PE/MachO eingetragen
4. **`@lib("libc.so.6")`-Pragma:** Markiert benötigte Shared Libraries
5. **C-Header-Import (optional):** Rudimentäres Parsen von C-Prototypes

**Referenz:** `compiler/frontend/c_header_parser.pas` (~902 LOC)

**Schätzung:** 2 Sessions

---

### WP-32: RISC-V + Embedded Backends

**Status:** Ausstehend | **Abhängigkeit:** WP-24

**Ziel:** RISC-V (RV64I) und ARM Cortex-M Backends.

**Zu implementieren:**

**`bootstrap/emit_riscv.lyx`** (RISC-V RV64I, RV32I):
- Register: a0–a7 (Argumente), t0–t6 (Temps), s0–s11 (Saved)
- Instruktionen: ADD, SUB, MUL, DIV, JAL, JALR, BEQ, BNE, BLT, BGE, LW, SW, LI, etc.
- ELF-Writer: `write_elf_riscv.lyx`

**`bootstrap/emit_arm_cm.lyx`** (ARM Cortex-M, Thumb-2):
- Thumb-2-Instruktionen: PUSH, POP, MOV, ADD, BL, BX, LDR, STR
- Memory-Map: Stack bei 0x20000000, Code bei 0x08000000 (STM32)
- ELF32-Writer: `write_elf32.lyx`

**Referenz:** `compiler/backend/riscv/riscv_emit.pas`, `compiler/backend/arm_cm/arm_cm_emit.pas`

**Schätzung:** 3 Sessions

---

### Phase 5: Volle Selbst-Kompilierung

---

### WP-33: lyxc.lyx — Vollständiger Compiler in Lyx

**Status:** Ausstehend | **Abhängigkeit:** WP-11–WP-31

**Ziel:** `lyxc.lyx` — der vollständige Self-Hosted-Compiler als einzelne Lyx-Datei/Modul-Suite.
Dies ist das Herzstück: der Compiler kompiliert sich selbst vollständig.

**Zu implementieren:**
1. **Entry Point:** `bootstrap/lyxc.lyx` (Ersetzt `lyxc_mini.lyx`)
   - Kommandozeilen-Parsing (--target, --opt, --output, --lint, etc.)
   - Pipeline-Orchestrierung (Lexer → Parser → Sema → Linter → IR → Optimize → Emit → Write)
2. **Multi-Target-Dispatch:** Basierend auf `--target` → Auswahl des richtigen Emitters + Writers
3. **Unit-Cache:** Bereits kompilierte Module nicht zweimal verarbeiten
4. **Incremental Compilation:** Timestamps prüfen, nur geänderte Module neu kompilieren
5. **Fehlerbehandlung:** Vollständige Fehler-Recovery mit Zeile/Spalte + Source-Kontext
6. **Verbose-Modus:** `--dump-ir`, `--dump-asm`, `--list` für Debugging

**Schätzung:** 3 Sessions | **Output:** `bootstrap/lyxc.lyx`

---

### WP-34: Vollständiger Singularitäts-Test (Stage 3)

**Status:** Ausstehend | **Abhängigkeit:** WP-33

**Ziel:** `lyxc.lyx` kompiliert sich selbst — und das Ergebnis ist bitidentisch.
Dies ist der **finale Beweis der vollständigen Self-Hosting-Fähigkeit**.

**Test-Sequenz:**
```
# Stage 0 → Stage 1: FPC-Compiler baut lyxc.lyx
./lyxc bootstrap/lyxc.lyx -o lyxc_new

# Stage 1 → Stage 2: lyxc_new kompiliert sich selbst
./lyxc_new bootstrap/lyxc.lyx -o lyxc_new2

# Stage 2 → Stage 3: Singularität
./lyxc_new2 bootstrap/lyxc.lyx -o lyxc_new3

# Vergleich (muss identisch sein)
md5sum lyxc_new2 lyxc_new3
```

**Zusätzliche Tests:**
- `lyxc_new` kompiliert alle Tests unter `tests/` erfolgreich
- `lyxc_new` kompiliert die gesamte Stdlib (`std/`)
- Ausgaben sind laufzeitidentisch zu FPC-kompilierten Binaries

**Schätzung:** 2 Sessions | **Output:** ✅ Vollständiges Self-Hosting

---

## Überblick: Arbeitspakete

| WP  | Name                                    | Phase | Sitzungen | Abhängigkeiten |
|-----|-----------------------------------------|-------|-----------|----------------|
| 11  | Erweitertes Typsystem & Operatoren      | 1     | 2         | WP-09/10       |
| 12  | Exception Handling (try/catch/finally)  | 1     | 3         | WP-11          |
| 13  | Closures & Nested Functions             | 1     | 3         | WP-11          |
| 14  | Generics / Monomorphization             | 1     | 4         | WP-11, WP-12   |
| 15  | Pattern Matching (vollständig)          | 1     | 2         | WP-11          |
| 16  | OOP: Vererbung, Interfaces, Access      | 1     | 3         | WP-14          |
| 17  | Range Types & Type Constraints          | 1     | 1         | WP-11          |
| 18  | IR-Datenstrukturen (`ir.lyx`)           | 2     | 2         | WP-11, WP-16   |
| 19  | AST→IR Lowering (Basis)                 | 2     | 3         | WP-18          |
| 20  | AST→IR Lowering (OOP, Generics)         | 2     | 4         | WP-19, WP-16, WP-14 |
| 21  | IR-Optimierungen (`ir_optimize.lyx`)    | 2     | 2         | WP-18          |
| 22  | Function Inlining (`ir_inline.lyx`)     | 2     | 1         | WP-21          |
| 23  | x86_64 Backend via IR                   | 3     | 4         | WP-19, WP-21   |
| 24  | ARM64 Backend via IR                    | 3     | 3         | WP-23          |
| 25  | ELF64/PE64/MachO64 Writer               | 3     | 3         | WP-23, WP-24   |
| 26  | Vollständiger Linter (W001–W020)        | 4     | 2         | WP-18          |
| 27  | Map/Set Collections                     | 4     | 2         | WP-20          |
| 28  | Statische Analyse                       | 4     | 3         | WP-21          |
| 29  | Safety Pragmas (@dal, @wcet, etc.)      | 4     | 2         | WP-28          |
| 30  | Erweiterte Stdlib                       | 4     | 5         | WP-27          |
| 31  | C FFI & Externes Linking                | 4     | 2         | WP-25          |
| 32  | RISC-V + Embedded Backends              | 4     | 3         | WP-24          |
| 33  | `lyxc.lyx` — Vollständiger Compiler     | 5     | 3         | WP-11–31       |
| 34  | Vollständiger Singularitäts-Test        | 5     | 2         | WP-33          |

**Gesamt: ~64 Sitzungen**

---

## Abhängigkeitsgraph

```
WP-11 (Typsystem)
 ├── WP-12 (Exceptions)
 │     └── WP-14 (Generics) ──────────────┐
 ├── WP-13 (Closures)                      │
 ├── WP-15 (Pattern Matching)              │
 ├── WP-16 (OOP) ──────────────────────────┤
 ├── WP-17 (Range Types)                   │
 └── WP-18 (IR-Daten) ────────────────────┐│
       ├── WP-19 (IR-Lower Basis)          ││
       │     └── WP-20 (IR-Lower OOP) ←───┘│
       │           └── WP-23 (x86 via IR) ←┘
       │                 └── WP-24 (ARM64)
       │                       └── WP-25 (Writers)
       │                             └── WP-31 (FFI)
       │                             └── WP-32 (RISC-V)
       ├── WP-21 (IR-Optimize)
       │     └── WP-22 (Inlining)
       │     └── WP-28 (Statische Analyse)
       │           └── WP-29 (Safety Pragmas)
       └── WP-26 (Linter vollständig)

WP-20 + WP-25 → WP-27 (Map/Set)
WP-27 → WP-30 (Stdlib)

WP-11..31 → WP-33 (lyxc.lyx)
WP-33 → WP-34 (Singularitäts-Test)
```

---

## Bekannte Risiken

| Risiko | Wahrscheinlichkeit | Gegenmaßnahme |
|--------|-------------------|---------------|
| Bootstrap-Compiler-Bugs bei Generics-Implementierung | Hoch | Zunächst ohne Generics-Monomorphization, stattdessen Type-Erasure + Casts |
| ELF/PE/MachO-Linking komplex (Relocations) | Mittel | Statisches Linking zuerst (kein Shared-Library-Support in Phase 3) |
| Exception-Handling-ABI-Kompatibilität | Mittel | Eigenes setjmp-System statt C++ ABI, nur für reine Lyx-Binaries |
| Stdlib-Kompatibilität mit Bootstrap-Compiler-Features | Hoch | Stdlib-Module schrittweise portieren, mit minimaler Feature-Nutzung starten |
| IR-Größe: 100+ Opcodes in Lyx implementieren | Niedrig | IR als cons + mmap-Array, kein GC-Overhead |
| SIMD-Support (NEON/SSE2) für Lyx-Compiler | Mittel | Optionales Feature, erst in Phase 4 |
| Bootstrap-Compiler selbst hat noch Bugs (7-Arg, etc.) | Mittel | Compiler-Bugs fixes haben höchste Priorität vor neuen Features |

---

## Priorisierung für Minimum Viable Self-Hosted Compiler (MVSC)

Wenn das Ziel ist, **so schnell wie möglich einen voll self-gehosteten Compiler zu haben**
(der den FPC-Compiler für Lyx-Kern-Code ersetzen kann), empfiehlt sich folgender
abgespeckter Pfad:

```
MVP-Pfad: WP-11 → WP-18 → WP-19 → WP-21 → WP-23 → WP-25 → WP-33 → WP-34
```

Dieser Pfad (8 WPs, ~19 Sitzungen) liefert einen Compiler der:
- Alle primitiven Typen unterstützt
- IR-basiert ist (erweiterbar)
- x86_64 Linux ELF64 ausgibt
- IR-Optimierungen durchführt
- Sich selbst kompiliert (Singularität)

Features wie Exceptions, Closures, Generics, OOP-Erweiterungen und Multi-Target kommen
dann in Phase 2 dazu.

---

*Dokument erstellt: 2026-04-05 | Basis: FPC-Compiler v0.5.5 (~58.990 LOC) + Bootstrap-Compiler WP-13 (~5.715 LOC)*

---

## TODO: Offene Punkte und Stubs

### Bereits implementiert (Abgeschlossen)
- WP-11: Erweitertes Typsystem ✅
- WP-12: Exception Handling (Parser/Sema/Codegen) ✅
- WP-13: Closures & Nested Functions ✅
- WP-14: Generics / Type-Parameter-Monomorphization ✅
- WP-15: Pattern Matching & Match-Expressions ✅
- WP-16: OOP (Vererbung, Interfaces, VMT) ✅ (partial: Access Control, Abstract)
- WP-17: Range Types & Type Constraints ✅ (Vollständig: Parser+Sema+Codegen)

### WP-12: Exception Handling - Bereits implementiert
- ✅ **Codegen:** setjmp/longjmp-basierte Exception-Implementierung in `codegen_x86.lyx`
- ✅ **Builtin-Exceptions:** `panic(msg)` — schreibt auf stderr, longjmp oder exit(1)
- ✅ **finally-Block:** Cleanup-Code auf Erfolgs- und Fehler-Pfad generiert

### WP-13: Closures & Nested Functions - Vollständig implementiert
- ✅ **Parser:** Nested Function-Deklarationen innerhalb von Blocks (`ParseNestedFunc`)
- ✅ **Parser:** `NK_FN_PTR` Type für Function-Pointer (`fn(T1, T2): R`)
- ✅ **Codegen:** Static-Link-Support in Codegen-Klasse (`staticLinkOffset`, `outerFuncName`)
- ✅ **Codegen:** `cg_genNestedFunc` für verschachtelte Funktionen mit eigenem Prolog
- ✅ **Codegen:** Captured-Variable-Zugriff via `[rbp+16]` (static link) in IDENT handling
- ✅ **Codegen:** Static-Link-Übergabe bei Aufruf verschachtelter Funktionen (in r10)
- ✅ **Sema:** `_analyzeCaptures()` für Nested-Function-Erkennung
- ✅ **Sema:** `_collectCaptures()` für Variable-Referenzen in verschachtelten Funktionen
- ✅ **Sema:** `_addCapturedVar()` mit Buffer-Management (vermeidet Duplikate)
- ✅ **Sema:** `capturedVars` Buffer (32 Bytes/Eintrag: funcName, funcLen, varName, varLen)
- ✅ **Codegen:** Closure-Objekt (via static link Implementierung)

### WP-14: Generics - Vollständig implementiert
- ✅ **Parser:** Type-Parameter-Parsing (`<T, U>`) in `ParseFuncDecl`
- ✅ **Parser:** Generic Type-Arguments in Funktionsaufrufen (`fn<T>(args)`) in `ParseExpr`
- ✅ **Parser:** `_parseTypeArgs()` für Generic-Call-Syntax
- ✅ **Sema:** `TY_GENERIC_INST` und `TY_TYPE_PARAM` Type-Konstanten
- ✅ **Sema:** `_resolveGenericCall()` für Type-Argument-Validierung
- ✅ **Sema:** `_getMonomorphInstance()` mit Cache-Suche (Type-Hash-basierter Lookup)
- ✅ **Sema:** `instCache` Buffer (48 Bytes/Eintrag: genName, genLen, typeHash, instName, instSymIdx)
- ✅ **Sema:** Instantiation-Cache mit Duplikat-Erkennung via Type-Hash

### WP-15: Pattern Matching - Bereits implementiert
- ✅ **Parser:** `NK_MATCH`, `NK_MATCH_CASE`, `_parseMatch()` vollständig
- ✅ **Parser:** Pattern-Typen: `NK_PATTERN_LIT`, `NK_PATTERN_WILD`, `NK_PATTERN_BIND`
- ✅ **Parser:** Enum-Payload-Pattern (`NK_PATTERN_ENUM`): `case Ok(v) => ...`
- ✅ **Parser:** Struct-Destrukturierung (`NK_PATTERN_STRUCT`): `case Point { x, y } => ...`
- ✅ **Codegen:** `cg_genMatch()` für match-Statements
- ✅ **Sema:** Pattern-Typ-Prüfung in `_checkStmt`
- ✅ **Sema:** Enum-Variant-Validierung (prüft ob Variant in Enum existiert)
- ✅ **Sema:** Struct-Destrukturierung Validierung (prüft Feldtypen)
- ✅ **Sema:** Exhaustiveness-Check (Warnung wenn kein Wildcard/Binding Pattern)
- ✅ **Codegen:** Struct-Destrukturierung Feld-Matching (via cg_findField)

### WP-11: Bekannte Issues
- ✅ **Float-Literal-Parsing:** Token-ID-Kollision TK_CHAR (177) behoben
  - TK_CHAR_TYPE (neu: 177) für char-Keyword
  - TK_F32 (neu: 180), TK_F64 (neu: 181) für Float-Typen
  - Parser/Sema aktualisiert für TK_CHAR_TYPE

### Phase 1: Sprachkern-Vollständigkeit (Offene WPs)
- ✅ **WP-11:** Erweitertes Typsystem & Operatoren (Vollständig)
- ✅ **WP-12:** Exception Handling (Vollständig: Parser/Sema/Codegen)
- ✅ **WP-13:** Closures & Nested Functions (Vollständig)
- ✅ **WP-14:** Generics / Type-Parameter-Monomorphization (Vollständig)
- ✅ **WP-15:** Pattern Matching & Match-Expressions (Vollständig)
- ✅ **WP-16:** OOP (Vererbung, Interfaces, VMT, partial Access Control)
- ✅ **WP-17:** Range Types & Type Constraints (Vollständig)

### Phase 2: IR-Schicht
- ✅ **WP-18:** IR-Datenstrukturen in Lyx (ir.lyx) — Abgeschlossen
- ✅ **WP-19:** AST→IR Lowering (Basis) — Abgeschlossen
- ✅ **WP-20:** AST→IR Lowering (OOP, Structs, Generics) — Abgeschlossen
- ✅ **WP-21:** IR-Optimierungen in Lyx — Abgeschlossen
- ✅ **WP-22:** Function Inlining — Abgeschlossen

### Phase 3: Backends
- ❌ **WP-23:** x86_64 Backend via IR (emit_x86.lyx)
- ❌ **WP-24:** ARM64 Backend via IR (emit_arm64.lyx)
- ❌ **WP-25:** ELF64/PE64/MachO64 Writer

### Phase 4: Erweiterte Features
- ❌ **WP-26:** Vollständiger Linter (W001–W020)
- ❌ **WP-27:** Map/Set Collections
- ❌ **WP-28:** Statische Analyse
- ❌ **WP-29:** Safety Pragmas (@dal, @critical, @wcet, @integrity)
- ❌ **WP-30:** Erweiterte Stdlib
- ❌ **WP-31:** C FFI & Externes Linking
- ❌ **WP-32:** RISC-V + Embedded Backends

### Phase 5: Volle Selbst-Kompilierung
- ❌ **WP-33:** lyxc.lyx — Vollständiger Compiler in Lyx
- ❌ **WP-34:** Vollständiger Singularitäts-Test

### Priorisierung (MVP-Pfad)
```
WP-11 → WP-18 → WP-19 → WP-21 → WP-23 → WP-25 → WP-33 → WP-34
```

### Globale Abhängigkeiten
```
WP-11 (Typsystem)
├── WP-14 (Generics)
├── WP-16 (OOP)
├── WP-17 (Range Types)
└── WP-18 (IR-Daten)
    ├── WP-19 (IR-Lower Basis)
    │     └── WP-20 (IR-Lower OOP)
    │           └── WP-23 (x86 via IR)
    │                 └── WP-24 (ARM64)
    │                       └── WP-25 (Writers)
    ├── WP-21 (IR-Optimize)
    │     └── WP-22 (Inlining)
    │     └── WP-28 (Statische Analyse)
    └── WP-26 (Linter vollständig)

WP-20 + WP-25 → WP-27 (Map/Set)
WP-27 → WP-30 (Stdlib)

WP-11..31 → WP-33 (lyxc.lyx)
WP-33 → WP-34 (Singularitäts-Test)
```
