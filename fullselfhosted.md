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
| `lexer.lyx`          | 763   | ✅ Vollständig |
| `parser.lyx`         | 1.042 | ✅ Vollständig |
| `sema.lyx`           | 691   | ✅ Vollständig |
| `codegen_x86.lyx`    | 2.439 | ✅ Direkte AST→x86_64 ELF64 |
| `linter.lyx`         | 547   | ✅ W001/W006/W007/W010 |
| `lyxc_mini.lyx`      | 160   | ✅ Entry Point |
| **Gesamt**           | **5.642** | |

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
| **Exception Handling**      | try/catch/finally/throw               | ❌ |
| **Closures**                | Nested Functions + Captured Variables | ❌ |
| **Generics**                | Monomorphization                      | ❌ |
| **Pattern Matching**        | match + Destrukturierung              | switch/case (basic) |
| **Range Types**             | `1..100`, Constraint-Expressions      | ❌ |
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

**Status:** Abgeschlossen | **Abhängigkeit:** WP-11

**Ziel:** Nested Functions mit Zugriff auf umschließende Scope-Variablen (Captured Variables).

**Zu implementieren:**
1. **Parser:** Nested Function-Deklarationen innerhalb von Functions/Methods
2. **Sema:** Capture-Analyse — welche Variablen werden von innen gelesen/geschrieben?
3. **Codegen:** Static-Link-Mechanismus
   - Outer-Frame-Pointer als versteckter Parameter (via `rdi` oder `[rbp+16]`)
   - Captured-Variables: Zugriff via `[static_link + offset]`
4. **Function-Pointer-Typ:** `fn(T1, T2): U` als Erst-Klassen-Typ
5. **Closure-Objekt:** {function_ptr, captured_env_ptr}

**Referenz:** `compiler/ir/ir.pas` (TIRClosure), `compiler/ir/lower_ast_to_ir.pas`

**Schätzung:** 3 Sessions

---

### WP-14: Generics / Type-Parameter-Monomorphization

**Status:** Abgeschlossen | **Abhängigkeit:** WP-11, WP-12

**Ziel:** Generische Funktionen und Klassen mit vollständiger Monomorphization.

**Zu implementieren:**
1. **Parser:** `fn Foo<T>(x: T): T { ... }`, `type Container<T> = class { ... }`
2. **Sema:** Type-Parameter-Binding, Constraint-Prüfung (`T: Comparable`)
3. **Monomorphization:** Bei jedem Aufruf von `Foo<i32>(...)` → erzeuge spezialisierte
   Funktion `Foo_i32` mit konkreten Typen (oder nutze Type-Erasure für einfache Fälle)
4. **Instantiation-Cache:** Vermeide doppelte Spezialisierungen
5. **Generic Stdlib-Typen:** `Array<T>`, `List<T>`, `Map<K,V>`, `Set<T>`

**Referenz:** `compiler/frontend/sema.pas` (Generic-Tracking), `compiler/ir/lower_ast_to_ir.pas`

**Schätzung:** 4 Sessions

---

### WP-15: Pattern Matching & Match-Expressions

**Status:** Abgeschlossen | **Abhängigkeit:** WP-11

**Ziel:** Vollständiges `match`-Statement mit Destrukturierung.

**Zu implementieren:**
1. **Parser:** `match expr { case Pattern => expr, ... }`
2. **Patterns:** Literal-Patterns, Enum-Patterns, Struct-Destrukturierung, Wildcard `_`, Guards
3. **Sema:** Exhaustiveness-Check (alle Cases abgedeckt?), Pattern-Typ-Kompatibilität
4. **Codegen:** Entscheidungsbaum-Generierung (Sprung-Tabellen für dichte Ranges)
5. **Enum-Payload:** `match result { case Ok(v) => ..., case Err(e) => ... }`

**Referenz:** `compiler/frontend/parser.pas` (parseMatch), `compiler/ir/lower_ast_to_ir.pas`

**Schätzung:** 2 Sessions

---

### WP-16: Vollständiges OOP (Vererbung, Interfaces, Zugriffskontrolle)

**Status:** In Bearbeitung | **Abhängigkeit:** WP-14

> **Hinweis (2026-04-05):** 
> - Kritischer Bug in `SafetyPragmas.FPDeterministic` gefunden und behoben.
>   Fix: `FPDeterministic := False` in `ir.pas`, `ast.pas`, `parser.pas`
> - Bootstrap WP-16: Parser + Sema erweitert für `extends`, `implements`, `interface`, `isType`

**Ziel:** Feature-Parität mit dem FPC-Compiler für OOP.

**Zu implementieren (Bootstrap):**
1. **Vererbung:** `type Dog = class extends Animal { ... }`
   - VMT-Erweiterung: Kind-VMT enthält Eltern-Einträge + neue Methoden
   - `super.method(...)` — Aufruf der Eltern-Implementierung
2. **Interfaces:** `type Drawable = interface { fn Draw(): void; }`
   - `type Circle = class implements Drawable { ... }`
   - Interface-VMT-Pointer pro Klasse
   - `x as Drawable` — Interface-Cast mit Runtime-Type-Check
3. **Access Control:** `pub`, `protected`, `priv` in Sema durchsetzen
4. **Abstract Classes/Methods:** `abstract fn foo(): void`
5. **Class-Felder:** Initialisierungs-Reihenfolge, Default-Werte

**Bereits vorhanden (Bootstrap - fb50f08):**
- `extends` Parser (NK_CLASS_DECL.c2 = parent)
- `implements` Parser (NK_CLASS_DECL.c3 = interfaces list)
- `interface` Parser (NK_IFACE_DECL)
- `isType` Expression (NK_IS_EXPR in Parser + Sema)

**Bereits vorhanden (FPC-Compiler):**
- Classes + VMT (WP-10a)
- Abstract Methods (partial)
- `isType` Expression

**Referenz:** `compiler/frontend/ast.pas` (OOP-Nodes), `compiler/backend/x86_64/x86_64_emit.pas`

**Schätzung:** 3 Sessions

---

### WP-17: Range Types & Type Constraints

**Status:** In Bearbeitung (Bootstrap) | **Abhängigkeit:** WP-11

**Ziel:** `1..100`-Range-Typen und Constraint-Expressions für sichere Typdefinitionen.

**Zu implementieren (Bootstrap):**
1. **Parser:** `type Port = i32 where value >= 0 && value <= 65535`
2. **Sema:** Constraint-Validierung bei Zuweisung (statisch wo möglich, sonst Runtime-Check)
3. **Codegen:** Runtime-Assertion für Constraints (`panic` bei Verletzung, konfigurierbar)
4. **Range-Literal:** `1..100` als Range-Ausdruck (z.B. in for-Schleifen)

**Bereits vorhanden (Bootstrap - Branch feat/wp17-range-types-bootstrap):**
- `TK_RANGE` Token (Lexer: `..` vs `...`)
- `NK_RANGE` Node für Range-Ausdruck (c0=start, c1=end)
- `NK_WHERE` Node für Where-Clause (c0=base type, c1=constraint)
- Range Expression Parsing in ParsePostfix (`1..100`)
- Where Clause Parsing in ParseType
- TY_RANGE Type in Sema
- Sema-Type-Checking für Range und Where

**Schätzung:** 1 Session

---

### Phase 2: IR-Schicht

---

### WP-18: IR-Datenstrukturen in Lyx

**Status:** Ausstehend | **Abhängigkeit:** WP-11, WP-16

**Ziel:** Vollständige IR-Datenstrukturen im Bootstrap-Compiler.

**Zu implementieren in `bootstrap/ir.lyx`:**
1. **`TIROpKind`-Enum:** Alle ~100 IR-Opcodes aus `compiler/ir/ir.pas`
   - Konstanten, Arithmetik, Float-Ops, Vergleiche, Bitwise
   - Memory (Load/Store Local/Global, Adressen)
   - Typ-Konversionen (Cast, SExt, ZExt, Trunc, FToI, IToF)
   - Funktionsaufrufe (irCall, irCallBuiltin, irVirtualCall)
   - Kontrollfluss (irJmp, irBrTrue, irBrFalse, irLabel, irFuncExit)
   - Struct-Ops (LoadField, StoreField, LoadFieldHeap, StoreFieldHeap)
   - Array-Ops (StackAlloc, StoreElem, LoadElem)
   - Dyn-Array-Ops (Push, Pop, Len, Free)
   - Exception-Ops (PushHandler, PopHandler, Throw)
   - SIMD-Ops (SIMDAdd..SIMDStoreElem)
   - Map/Set-Ops (MapNew..MapFree, SetNew..SetFree)
   - Spezielle (irPanic, irInspect, irIsType, irAlloc, irFree)
2. **`TIRInstr`-Struktur** (analog FPC): op, dest, src1, src2, src3, immInt, immFloat,
   immStr, labelName, argTemps, castFrom/ToType, callMode, isVirtualCall, vmtIndex,
   selfSlot, structSize, fieldSize, sourceLine, sourceFile
3. **`TIRFunction`-Struktur:** name, instructions[], localCount, paramCount,
   returnStructSize, capturedVars, needsStaticLink
4. **`TIRModule`-Struktur:** functions[], strings[], globalVars[], classDecls[]
5. **Allokator:** mmap-basiertes Instruction-Array mit Grow-Mechanismus
6. **`ir_dump`-Funktion:** Debugging-Ausgabe der IR in Textform

**Referenz:** `compiler/ir/ir.pas` (TIROpKind, TIRInstr, TIRFunction, TIRModule)

**Schätzung:** 2 Sessions | **Output:** `bootstrap/ir.lyx`

---

### WP-19: AST→IR Lowering (Basis)

**Status:** Ausstehend | **Abhängigkeit:** WP-18

**Ziel:** Vollständiges Lowering von Ausdrücken und einfachen Statements zu IR.

**Zu implementieren in `bootstrap/ir_lower.lyx`:**
1. **Ausdrucks-Lowering:**
   - Literale → `irConstInt`, `irConstFloat`, `irConstStr`
   - Binäre Ops → `irAdd`, `irSub`, `irMul`, `irDiv`, `irMod`, bitweise Ops
   - Float-Ops → `irFAdd`, `irFSub`, etc.
   - Vergleiche → `irCmpEq`, `irCmpLt`, etc.
   - Casts → `irCast`, `irSExt`, `irZExt`, `irFToI`, `irIToF`
   - Variable-Reads → `irLoadLocal` / `irLoadGlobal`
   - Funktionsaufrufe → `irCall` / `irCallBuiltin`
2. **Statement-Lowering:**
   - Zuweisungen → `irStoreLocal` / `irStoreGlobal`
   - if/else → `irBrTrue/False` + `irLabel` + `irJmp`
   - while → Loop-Header `irLabel` + `irBrFalse` Exit
   - for → Loop-Variable + Step + Exit-Label
   - return → `irFuncExit`
   - break/continue → `irJmp` zu Exit/Header-Label
3. **Variablen-Verwaltung:** Lokale Variable → Slot-Nummer, `localCount`-Tracking
4. **Label-Generator:** Eindeutige Label-Namen (`L0`, `L1`, ...) pro Funktion

**Referenz:** `compiler/ir/lower_ast_to_ir.pas` (LowerExpr, LowerStmt)

**Schätzung:** 3 Sessions | **Output:** `bootstrap/ir_lower.lyx` (Basis-Version)

---

### WP-20: AST→IR Lowering (OOP, Structs, Klassen, Generics)

**Status:** Ausstehend | **Abhängigkeit:** WP-19, WP-16, WP-14

**Ziel:** Vollständiges Lowering von OOP-Konstrukten, Structs und generischen Typen.

**Zu implementieren:**
1. **Struct-Lowering:**
   - Struct-Feld-Zugriff → `irLoadField` / `irStoreField`
   - Struct-by-Value: Kopieren aller Felder
   - Struct-Rückgabe > 16 Bytes: Hidden-Output-Pointer
2. **Klassen-Lowering:**
   - `new T()` → `irAlloc(size)` + `irStoreField(vmtSlot, vmtAddr)`
   - Methoden-Aufruf (statisch) → `irCall(mangled_name, self, args...)`
   - Virtueller Aufruf → `irLoadFieldHeap(obj, 0)` (VMT-Pointer) + `irVirtualCall`
   - `dispose obj` → `irFree`
3. **Interface-Lowering:** Interface-VMT-Lookup, Interface-Pointer-Paar {obj, ifaceVMT}
4. **Dyn-Array-Lowering:** fat-pointer {ptr, len, cap}, Push → `irDynArrayPush`, etc.
5. **Exception-Lowering:** try/catch → `irPushHandler` / `irPopHandler` / `irThrow`
6. **Closure-Lowering:** Static-Link, Captured-Variable-Zugriffe
7. **Generics-Lowering:** Aufruf spezialisierter Monomorphisierungen
8. **SIMD-Lowering:** `ParallelArray<T>` → `irSIMDAdd`, etc.
9. **Map/Set-Lowering:** `irMapNew`, `irMapGet`, etc.

**Referenz:** `compiler/ir/lower_ast_to_ir.pas` (LowerClassMethod, LowerStructDecl, etc.)

**Schätzung:** 4 Sessions | **Output:** `bootstrap/ir_lower.lyx` (vollständig)

---

### WP-21: IR-Optimierungen in Lyx

**Status:** Ausstehend | **Abhängigkeit:** WP-18

**Ziel:** Die fünf Kern-Optimierungen des FPC-Compilers in Lyx portieren.

**Zu implementieren in `bootstrap/ir_optimize.lyx`:**
1. **Constant Folding:** `irConstInt(3) irAdd irConstInt(4)` → `irConstInt(7)`
   - Arithmetik, Float-Ops, Vergleiche, Bitwise
   - Auch über mehrere Instruktionen (Propagation)
2. **Copy Propagation:** `t1 = a; t2 = t1 + b` → `t2 = a + b`
3. **Dead Code Elimination:** Unreachable Code nach `irJmp`/`irFuncExit` entfernen;
   Instruktionen deren `dest` nie gelesen wird
4. **Common Subexpression Elimination (CSE):** Gleiche Berechnung in selber Expression
   → gemeinsames Temp-Register
5. **Strength Reduction:** `x * 2` → `x << 1`, `x * 0` → `0`, etc.
6. **Iterativer Durchlauf:** 2-Pass-Optimierung (wie FPC: Pass 1 + Pass 2)

**Referenz:** `compiler/ir/ir_optimize.pas` (~1.161 LOC)

**Schätzung:** 2 Sessions | **Output:** `bootstrap/ir_optimize.lyx`

---

### WP-22: Function Inlining

**Status:** Ausstehend | **Abhängigkeit:** WP-21

**Ziel:** Inline-Expansion kleiner Funktionen für Performance.

**Zu implementieren in `bootstrap/ir_inline.lyx`:**
1. **Inline-Heuristik:** Threshold (z.B. ≤20 Instruktionen) + keine Rekursion
2. **Inline-Expansion:** Kopiere IR-Instruktionen der Callee, ersetze `irFuncExit` durch
   Sprung zur Fortsetzung, ersetze Parameter durch Argumente
3. **Label-Umbenennung:** Eindeutige Labels nach Inline (Suffix `_inl_N`)
4. **Call-Graph-Analyse:** Erkenne rekursive Funktionen (nicht inlinen)
5. **@noinline-Pragma:** Respektiere Benutzer-Anweisung

**Referenz:** `compiler/ir/ir_inlining.pas` (~320 LOC)

**Schätzung:** 1 Session | **Output:** `bootstrap/ir_inline.lyx`

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

### WP-12: Exception Handling - Bereits implementiert
- ✅ **Codegen:** setjmp/longjmp-basierte Exception-Implementierung in `codegen_x86.lyx`
- ✅ **Builtin-Exceptions:** `panic(msg)` — schreibt auf stderr, longjmp oder exit(1)
- ✅ **finally-Block:** Cleanup-Code auf Erfolgs- und Fehler-Pfad generiert

### WP-13: Closures & Nested Functions - Teilweise implementiert
- ✅ **Parser:** Nested Function-Deklarationen innerhalb von Blocks (`ParseNestedFunc`)
- ✅ **Parser:** `NK_FN_PTR` Type für Function-Pointer (`fn(T1, T2): R`)
- ✅ **Codegen:** Static-Link-Support in Codegen-Klasse (`staticLinkOffset`, `outerFuncName`)
- ✅ **Codegen:** `cg_genNestedFunc` für verschachtelte Funktionen mit eigenem Prolog
- ✅ **Codegen:** Captured-Variable-Zugriff via `[rbp+16]` (static link) in IDENT handling
- ✅ **Codegen:** Static-Link-Übergabe bei Aufruf verschachtelter Funktionen (in r10)
- ✅ **Sema:** Capture-Analyse Stub (`_analyzeCaptures`, `_collectCaptures`, `_addCapturedVar`)
- ✅ **Codegen:** Closure-Objekt Stub (via static link Implementierung)

### WP-14: Generics - Bereits implementiert
- ✅ **Parser:** Type-Parameter-Parsing (`<T, U>`) in `ParseFuncDecl`
- ✅ **Parser:** Generic Type-Arguments in Funktionsaufrufen (`fn<T>(args)`) in `ParseExpr`
- ✅ **Parser:** `_parseTypeArgs()` für Generic-Call-Syntax
- ✅ **Sema:** `TY_GENERIC_INST` und `TY_TYPE_PARAM` Type-Konstanten
- ✅ **Sema:** `_resolveGenericCall()` für Type-Argument-Validierung
- ✅ **Sema:** `_getMonomorphInstance()` Stub für Instantiation-Cache
- ✅ **Sema:** `instCache` Buffer für Generic-Instanziierung

### WP-15: Pattern Matching - Verbleibende Stubs
- ❌ **Codegen:** Entscheidungsbaum-Generierung (Sprung-Tabellen für dichte Ranges)
- ❌ **Sema:** Exhaustiveness-Check (alle Cases abgedeckt?)
- ❌ **Sema:** Enum-Payload-Patterns (`case Ok(v) => ...`)
- ❌ **Sema:** Struct-Destrukturierung

### WP-11: Bekannte Issues
- ❌ **Float-Literal-Parsing:** Token-ID-Kollision TK_CHAR (177) verursacht Fehler bei `3.14`
  - Lösung erfordert Refactoring der Token-IDs im Lexer

### Phase 1: Sprachkern-Vollständigkeit (Offene WPs)
- ✅ **WP-14:** Generics / Type-Parameter-Monomorphization (Parser + Sema)
- ✅ **WP-15:** Pattern Matching & Match-Expressions (Parser + Sema)
- ❌ **WP-16:** Vollständiges OOP (Vererbung, Interfaces, Access Control)
- ❌ **WP-17:** Range Types & Type Constraints

### Phase 2: IR-Schicht
- ❌ **WP-18:** IR-Datenstrukturen in Lyx (ir.lyx)
- ❌ **WP-19:** AST→IR Lowering (Basis)
- ❌ **WP-20:** AST→IR Lowering (OOP, Structs, Generics)
- ❌ **WP-21:** IR-Optimierungen in Lyx
- ❌ **WP-22:** Function Inlining

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
