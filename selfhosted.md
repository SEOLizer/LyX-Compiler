# Lyx → Self-Hosted Compiler: Roadmap

> Ziel: Der Lyx-Compiler (`lyxc`) wird in Lyx selbst geschrieben.
> Aktueller Stand: v0.5.5, Compiler in Free Pascal (FPC), ~40.000 LOC.

---

## Strategie

**Bootstrap in Stufen:**

```
Stufe 0 (jetzt):  lyxc.pas   → kompiliert Lyx-Code (FPC-Compiler)
Stufe 1 (Ziel):   lyxc.lyx   → kompiliert sich selbst (vom FPC-Compiler gebaut)
Stufe 2 (Zukunft):lyxc.lyx   → kompiliert sich selbst (vom Stufe-1-lyxc gebaut)
```

**Ansatz: Minimaler Bootstrap-Compiler**
Wir schreiben keinen voll-feature-kompatiblen Compiler. Der erste selbst-gehostete
Compiler muss nur genug Lyx können, um *sich selbst* zu kompilieren. Features wie
IPv6-Support, DataFrame, LyxVision etc. kommen erst in Stufe 2.

---

## Ist-Analyse: Was funktioniert heute

| Feature | Status | Anmerkung |
|---------|--------|-----------|
| Structs | ✅ | Felder, Dot-Access |
| Klassen / OOP | ✅ | Vererbung, VMT, Interface |
| Dynamische Arrays | ✅ | `Array<T>`, `.length`, push/pop |
| `switch/case` | ✅ | Auf int-Konstanten |
| `while`, `for`, `if` | ✅ | |
| `pchar` + Stringbuiltins | ✅ | StrLength, StrCharAt, StrCopy |
| File I/O | ✅ | ReadFile, WriteFile (std.fs) |
| `main(argc, argv)` | ✅ | CLI-Args zugänglich |
| `mmap` / `poke8/16` | ✅ | gerade gefixt |
| `con` Konstanten | ✅ | Global und lokal |
| Modulimport | ✅ | |
| Schreiben von ELF-Binaries | ✅ | Vollständig |
| OOP (Klassen) | ✅ | Heap-allokiert |
| `pchar` Concat (`+`) | ✅ | Über mmap-Buffer |

---

## Bekannte Bugs (müssen vor Self-Hosting gefixt sein)

| # | Bug | Auswirkung | Priorität |
|---|-----|------------|-----------|
| B1 | **16-byte Struct Parameter** | Structs mit 2 Slots (>8 Bytes) als Funktionsparameter übergeben → falscher Inhalt (Prologue speichert nur RDI, nicht RSI) | ✅ Behoben (diese Session) |
| B2 | **mmap Arg-Übergabe** | Zweites mmap-Argument (length) wurde aus Src2 gelesen (uninitialisiert) statt ArgTemps[1] → EINVAL | ✅ Behoben (diese Session) |
| B3 | **16-byte Struct Return Order** | RAX/RDX wurden in falscher Slot-Reihenfolge gespeichert | ✅ Behoben (letzte Session) |
| B4 | **poke64/peek64 ungetestet** | Nach mmap-Fix: funktioniert jetzt korrekt | ✅ Behoben (diese Session) |

---

## Fehlende Sprachfeatures

| # | Feature | Workaround möglich? | Aufwand | Prio für Self-Host |
|---|---------|--------------------|---------|--------------------|
| F1 | **`enum` Typen** | `con`-Konstanten (int64) | M | ✅ Implementiert (diese Session) |
| F2 | **`string` Typ** (dynamisch wachsend) | `pchar` + mmap-Buffer manuell | S | ✅ Implementiert (diese Session) |
| F3 | **Exception Handling** (try/catch) | `panic()` + Rückkabecode | S | ✅ Implementiert (diese Session) |
| F4 | **Multi-Return** / Tuple | Out-Parameter (Pointer) | S | ✅ Implementiert (diese Session) |
| F5 | **Generics** (echte) | Spezialisierte Typen pro Datentyp | XL | ✅ Implementiert (diese Session) |
| F6 | **Pattern Matching** | `switch` + Hilfsvariablen | M | ✅ Implementiert (diese Session) |

**Legende:** S=Klein, M=Mittel, L=Groß, XL=Sehr groß

---

## Fehlende Stdlib für den Compiler

| # | Feature | Workaround | Priorität |
|---|---------|------------|-----------|
| S1 | **StrFindChar + StrSub** | ✅ Implementiert (feat/string-utils) | Hoch |
| S2 | **StrAppendStr / StrConcat / StrCopy** | ✅ Implementiert (feat/string-utils) | Hoch |
| S3 | **IntToStr(n)** | ✅ Implementiert (feat/string-utils) | Mittel |
| S4 | **FileGetSize(path)** | ✅ Implementiert (feat/string-utils) | Mittel |
| S5 | **HashMap O(1) (string→int64)** | ✅ Implementiert (feat/string-utils) | Mittel |
| S6 | **GetArgC / GetArg** | ✅ Implementiert (feat/string-utils) | Mittel |
| S7 | **StrStartsWith / StrEndsWith / StrEquals** | ✅ Implementiert (feat/string-utils) | Niedrig |

---

## Workpakete

Jedes Paket ist so geschnitten, dass es in **einer Claude-Session** (~2-3h) abgeschlossen werden kann.

---

### WP-01: Bug Fix – 16-byte Struct Parameter (Blocker)

**Status: ✅ Bereits gelöst (nicht durch RDI+RSI-Split, sondern durch Pointer-Passing)**

**Beschreibung (ursprünglich):**
Wenn eine Funktion einen Struct-Parameter mit >8 Bytes bekommt, schreibt der Prologue
nur RDI (bytes 0-7) in den Stack, aber nicht RSI (bytes 8-15). Resultat: Felder in der
zweiten Hälfte des Structs enthalten Garbage.

**Warum bereits gelöst:**
Lyx übergibt Struct-Parameter grundsätzlich per implizitem Pointer (RDI = Adresse des
Structs auf dem Caller-Stack), nicht als Wert in RDI+RSI. Der Prologue speichert RDI
(den Pointer) in Slot 0 — das reicht vollständig. Felder werden über `[rdi+offset]`
adressiert. Sowohl 16-Byte- als auch 24-Byte-Structs wurden verifiziert (test_struct16_roundtrip.lyx, Exit 0, korrekte Feldwerte).

**Verifiziert mit:**
- `tests/regression/structs/test_struct16_roundtrip.lyx` → `a: 42`, `b: 99` ✅
- Inline-Test mit 24-byte Triple-Struct → `sum=6` ✅

**Abhängigkeiten:** keine

---

### WP-02: Stdlib – StringBuilder & String-Hilfsfunktionen ✅ ERLEDIGT

**Beschreibung:**
Für den Lexer und Parser brauchen wir dynamisches String-Building und String-Analyse.
Wir brauchen keinen neuen Sprachtyp – eine `StringBuilder`-Klasse in Lyx reicht.

**Dateien:**
- `std/string.lyx` – erweitert

**Was erledigt wurde:**
1. **`StringBuilder`-Klasse** ✅ – `Init`, `Append`, `AppendChar`, `AppendInt`, `ToString`, `Clear`, `FreeBuffer`
   - Hinweis: Methode heißt `FreeBuffer()` statt `Free()` da `Free` ein TObject-VMT-Slot ist
2. **`StrSplit(s, delim, out: int64, maxParts: int64): int64`** ✅
3. **`StrTrim(s): pchar`** ✅ – heap-allocated trimmed copy
4. **`StrStartsWith(s, prefix): bool`** ✅ – bereits als Builtin vorhanden
5. **`StrEndsWith(s, suffix): bool`** ✅ – bereits als Builtin vorhanden
6. **`IntToStr(n: int64): pchar`** ✅ – bereits als Builtin vorhanden

**Nebenfix (Compiler-Bugs behoben):**
- `StrAppendStr` `jl`-Overflow (signed byte overflow bei >127 Byte Realloc-Pfad) – gefixt
- `poke64`/`peek64`/`poke16`/`peek16`/`poke32`/`peek32` fehlten in `lower_ast_to_ir.pas` – gefixt
- Importierte Klassen-Methoden wurden nicht kompiliert (IR + Sema) – gefixt

**Test:** `tests/feature_checks/strings/test_stringbuilder.lyx` ✅

**Abhängigkeiten:** keine

---

### WP-03: Stdlib – File Utilities & Argv ✅ DONE

**Beschreibung:**
Vollständige Datei-Lese-Infrastruktur für den Compiler: Quelltext lesen, Dateigröße abfragen,
und CLI-Argumente als echte `pchar`-Array-Elemente lesen.

**Dateien:**
- `std/fs.lyx` – erweitert
- `std/env.lyx` – erweitert

**Umgesetzt:**
1. **`FileSize(path: pchar): int64`** – war bereits vorhanden
2. **`FileReadAll(path: pchar): pchar`** – mmap-Buffer, liest alles, null-terminiert ✅
3. **`ArgvGet(argv: pchar, i: int64): pchar`** – `peek64(argv + i*8)` ✅
4. **`ArgvGetStr(argc, argv, name): pchar`** – `--flag=value` Parser ✅

**Compiler-Fixes:** syscall-Emitter für `open/close/lseek/write/unlink/rename` ergänzt;
`GetArgV()` als Builtin; kritischer Call-Mode-Bug behoben (cmImported vs cmInternal).

**Test:** `tests/feature_checks/stdlib/test_filereadall.lyx` ✅ (liest sich selbst, 1629 Bytes, 65 Zeilen)

**Abhängigkeiten:** keine

---

### WP-04: Enum-Typen ✅ DONE

**Beschreibung:**
Enums machen Token-Typen, AST-Node-Typen und IR-Opcodes viel lesbarer.
Als Workaround können `con`-Konstanten verwendet werden, aber echte Enums verbessern
die Codequalität erheblich.

**Umgesetzt:**
1. Syntax: `enum TokenKind { tkIdent, tkInt, tkPlus };` → int64-Konstanten (0, 1, 2, ...) ✅
2. Explizite Werte: `enum HttpStatus { OK = 200, NOT_FOUND = 404 };` ✅
3. Gemischt: explizit + auto-increment ✅
4. `switch` auf Enum-Werte funktioniert (int64) ✅
5. Enum-Typ in Sema: `var x: TokenKind := tkIdent` → `atInt64` ✅
6. Enum-Typ in Funktionsparametern ✅
7. Rückwärtskompatibilität: alte Semicolon-Syntax weiterhin unterstützt ✅

**Compiler-Fixes:** IR-Lowerer: `var x: EnumType := enumValue` wurde fälschlich als
Funktionszeiger behandelt (TAstIdent-Heuristik). Fix: FConstMap vor fnPtr-Branch prüfen.
Sema: FEnumTypes-Registry; VarDecl + Param-Auflösung für Enum-Typen.

**Test:** `tests/lyx/enums/test_enum_basic.lyx` ✅

**Abhängigkeiten:** keine

---

### WP-05: Self-Hosted Lexer ✅ DONE

**Beschreibung:**
Schreibe den Lyx-Lexer in Lyx. Dies ist der erste echte Bootstrap-Schritt.
Der Lexer liest `pchar`-Quelltext und produziert eine Liste von Token.

**Datei:** `bootstrap/lexer.lyx`

**Umgesetzt:**
1. `pub type Lexer = class` mit 17 Feldern, 13 Methoden ✅
2. 120 `pub con TK_*` Token-Konstanten ✅
3. Keywords, Identifiers, Operatoren (alle Lyx-Operatoren) ✅
4. Integer-Literale: Dezimal, Hex (`0xFF`), Binär (`0b1010`) ✅
5. String-Literale mit Escape-Sequenzen ✅
6. Char-Literale ✅
7. Zeilenkommentare `//` und Block-Kommentare `/* */` ✅
8. `Peek()` ohne Verbrauch ✅
9. `LexerTokKindStr()` Hilfsfunktion ✅

**Compiler-Fixes (IR-Lowerer):**
- Importierte Klassen müssen `pub` deklariert sein (sonst null-Pointer-Allokation)
- Field-Offset-Fallback für importierte Klassen-Methoden (sema läuft nicht auf importierten Methoden)
- Namespace-Methodenaufruf-Rewriting (`self.method()` → `_L_ClassName_method(self)`) im IR-Lowerer

**Test:** `tests/lyx/bootstrap/test_lexer.lyx` ✅ (alle 7 Tests bestanden)

**Abhängigkeiten:** WP-02 (StringBuilder), WP-03 (FileReadAll)

---

### WP-06: Self-Hosted Parser (Basis) ✅ DONE

**Beschreibung:**
Schreibe den Lyx-Parser in Lyx. Baut einen flachen AST auf, der als int64-indiziertes
Array repräsentiert wird (kein echter Baum mit Pointern – stattdessen Index-Referenzen).

**Datei:** `bootstrap/parser.lyx`

**AST-Repräsentation (kompakt):**
```lyx
// AST-Node-Typen als Konstanten
con NK_FUNC_DECL: int64 := 1;
con NK_VAR_DECL:  int64 := 2;
con NK_BINOP:     int64 := 3;
// ...

struct AstNode {
  kind:   int64;   // NK_xxx
  child0: int64;   // Index in nodes-Array (-1 = kein)
  child1: int64;   // Index in nodes-Array (-1 = kein)
  child2: int64;   // Index in nodes-Array (-1 = kein)
  tokIdx: int64;   // Token-Index für Fehlermeldungen
  iVal:   int64;   // int-Wert (für Literale, etc.)
}
```

**Minimales Subset (reicht für Bootstrap):**
- Funktionsdeklarationen
- Variablendeklarationen
- Ausdrücke (binäre Operatoren, Funktionsaufrufe, Literale)
- `if`, `while`, `return`
- Struct-Deklarationen (für Token/AstNode etc.)
- `import`-Statements

**Was zu tun:**
1. Recursive-Descent Parser für das minimale Subset
2. Fehlerausgabe mit Zeilennummer
3. Kein Recovery – bei Fehler panic

**Test:** `tests/lyx/bootstrap/test_parser.lyx`
Input: `bootstrap/lexer.lyx` selbst (oder eine Hilfsdatei)
Expected: Korrekte Node-Anzahl, keine Abstürze

**Abhängigkeiten:** WP-05 (Lexer)

---

### WP-07: Self-Hosted Typ-Checker (Minimal) ✅ DONE

**Beschreibung:**
Minimale semantische Analyse: Symboltabelle für Funktionen und Variablen,
Typ-Auflösung für primitive Typen, Grundvalidierung.

**Datei:** `bootstrap/sema.lyx`

**Symboltabelle:**
```lyx
struct Symbol {
  name:    pchar;  // null-terminated
  nameLen: int64;
  kind:    int64;  // SYM_FUNC, SYM_VAR, SYM_STRUCT, ...
  typeId:  int64;  // primitiver Typ-Code
  nodeIdx: int64;  // AST-Node-Index
}
```

**Was zu tun:**
1. Lineare Symboltabelle (Array of Symbol, O(n) Lookup – für Bootstrap reicht das)
2. Zwei-Pass:
   - Pass 1: Sammle alle Funktions- und Struct-Namen
   - Pass 2: Löse Typen auf, prüfe Variablen-Definitionen
3. Einfache Typ-Prüfung: int64, pchar, bool, void
4. Fehlermeldung bei undefiniertem Symbol

**Test:** `tests/lyx/bootstrap/test_sema.lyx`

**Abhängigkeiten:** WP-06 (Parser)

---

### WP-07b: Compiler Bug Fixes (lyxc FPC source) ✅ DONE

Drei Compiler-Bugs entdeckt beim Entwickeln von WP-07 und anschließend gefixt:

**Bug 1 – Importierte Konstanten in Klassenmethoden (Priorität: Hoch)**
- **Problem:** Konstanten wie `PARSER_NODE_SIZE`, `NK_FUNC_DECL` aus `bootstrap.parser`
  lieferten Garbage-Werte, wenn sie in Methoden einer anderen Klasse (`Sema`) verwendet wurden.
- **Ursache:** In `LowerImportedUnits` wurde Phase 1 (Klassenmethoden lowern) in der gleichen
  Iteration wie die Konstantenregistrierung ausgeführt. Da Units in umgekehrter Reihenfolge
  verarbeitet werden (Sema vor Parser), waren Konstanten aus Parser noch nicht in `FConstMap`,
  wenn Semas Methoden gelowert wurden.
- **Fix:** `lower_ast_to_ir.pas` – Drei-Phasen-Ansatz: Phase 0 registriert alle Typen und
  Konstanten aus ALLEN Units, bevor Phase 1 Klassenmethoden lowert.
- **Workaround in sema.lyx:** Lokale `con`-Kopien (`SEMA_NODE_SIZE := 88`, `SNK_FUNC_DECL := 2`, …)

**Bug 2 – VMT-Label-Lookup in x86_64-Codegen (Priorität: Mittel)**
- **Problem:** Bei `new SomeClass()` wurde der VMT-Pointer aller Klassen auf die erste Klasse
  in `module.ClassDecls` gepatcht, weil `FVMTLabels` zum Zeitpunkt der Funktionsemission leer ist.
- **Ursache:** `FVMTAddrLeaPositions` speicherte einen `VMTLabelIndex` (default 0), der beim
  Lookup immer fehlschlug – da `FVMTLabels` erst nach allen Funktionen befüllt wird.
- **Fix:** `x86_64_emit.pas` – Statt Index jetzt Label-Name speichern; Name-Lookup im
  Patch-Schritt, nachdem `FVMTLabels` vollständig befüllt ist.

**Bug 3 – Klassen-Instanzen als Methodenparameter (Priorität: Mittel)**
- **Problem:** Parameter wie `p: Parser` in einer anderen Klasse (`Sema`) hatten kein
  `ClassDecl` gesetzt → `p.nodes`, `p.NKind(0)` konnten nicht aufgelöst werden.
- **Ursache:** In `TSema.Analyze` wurden Methodenparameter ohne `TypeName`/`ClassDecl` registriert.
- **Fix:** `sema.pas` – Parameter-Symbol bekommt jetzt `sym.TypeName := p.TypeName` und
  `sym.ClassDecl` aus `FClassTypes`-Lookup.
- **Workaround:** Primitive Werte einzeln übergeben: `s.Init(p.src, p.srcLen, p.nodes, …)`

**Dateien geändert:**
- `compiler/ir/lower_ast_to_ir.pas` – drei-phasige `LowerImportedUnits`
- `compiler/backend/x86_64/x86_64_emit.pas` – VMT-Label by name statt by index
- `compiler/frontend/sema.pas` – `TypeName`/`ClassDecl` für Methodenparameter

**Abhängigkeiten:** WP-07

---

### WP-08: Self-Hosted x86_64 Code Generator ✅ DONE

**Beschreibung:**
Der wichtigste und komplexeste Schritt. Emittiert x86_64 Maschinencode direkt aus dem AST.
Kein IR – direkter AST → ELF64-Binärcode, stack-basiert, ohne Register-Allokator.

**Datei:** `bootstrap/codegen_x86.lyx`

**Umgesetzt:**
1. **`Codegen`-Klasse** (~900 LOC) ✅
   - 20 Felder: code/data mmap-Buffer, locals/labels/patches-Tabellen
   - Alle Methoden mit `cg_`-Präfix (VMT-Kollisions-Workaround)
   - Lokale `con`-Kopien aller Parser/Lexer-Konstanten (Importierter-Konstanten-Bug-Workaround)
2. **ELF64-Writer** (minimal, single PT_LOAD) ✅
   - ELF-Header + PHdr: 120 Bytes Header, dann Code + Daten
   - Load-Adresse: 0x400000, Entry = 0x400078 (_start)
   - `WriteELF(path: pchar)` schreibt fertiges ELF via `open/write/close`
3. **Feste Helper-Stubs** (157 Bytes, offset 0 im Code-Buffer) ✅
   - `_start` (17 B): ruft `main`, danach sys_exit mit Return-Code
   - `_lyx_strlen` (15 B): null-terminierte Länge
   - `_lyx_print_str` (26 B): sys_write(1, buf, len)
   - `_lyx_print_int` (99 B): int64 → Dezimalstring → sys_write
4. **Backpatching** ✅
   - CALL-Patches: rel32 nach allen Funktionen aufgelöst (Labels-Tabelle)
   - STR-Patches: RIP-relative LEA-Displacements für String-Literale
5. **Ausdruck-Generierung** (stack-basiert) ✅
   - Literale: `mov rax, IMM64` / `lea rax, [rip+disp32]`
   - Variablen: `mov rax, [rbp+off]`
   - BinOp: LHS→rax, push; RHS→rax; pop rbx; Operation
   - Alle Vergleichsoperatoren: `cmp + setXX + movzx`
   - Logisch: `&&`, `||`, `!`
6. **Statement-Generierung** ✅
   - `var`/`con`: Slot allokieren, Initialwert berechnen, speichern
   - `if`/`else`: `cmp + jz` mit Backpatch
   - `while`: Loop mit Back-Edge
   - `for` (als while synthetisiert)
   - `return`: Wert in rax, Epilog, ret
   - `assign`: Ausdruck berechnen, in Slot speichern
7. **Builtin-Calls** ✅
   - `PrintStr` → call _lyx_print_str
   - `PrintInt` → call _lyx_print_int
   - `StrLen` → call _lyx_strlen
   - `mmap` → sys_mmap (9) mit r10=flags, r8=fd, r9=0
   - `poke8/16/32/64`, `peek8/32/64`: inline Byte/Dword/Qword Zugriff
   - Alle anderen Aufrufe: normaler CALL + Patch

**Compiler-Fixes (lyxc FPC source):**
- `parser.pas`: `:=` in `var`/`con`-Deklarationen nach SIMD-PR kaputt → Accept(tkAssign or tkSingleEq) ✅
- `sema.pas`: `pchar + int64` und `int64 + pchar` als Pointer-Arithmetik erlaubt ✅

**Bekannter Bug-Workaround:**
- `poke8(buf + 0, x)` crasht (Constant-Folding `+0` → Copy-Propagation-Bug im Lyx-Compiler) → Fix: `buf` direkt ohne `+ 0` ✅

**Test:** `tests/lyx/bootstrap/test_codegen.lyx` – alle 5 Tests ✅
- Test 1: `fn main(): int64 { PrintStr("hello\n"); return 0; }` → `/tmp/test_cg_hello` gibt "hello" aus ✅
- Test 2: `fn add(x, y): int64 { return x+y; }` → `/tmp/test_cg_add` gibt "7" aus ✅
- Test 3: `countDown(3)` mit while-Schleife → `/tmp/test_cg_while` gibt "3 2 1 " aus ✅
- Test 4: ELF-Magic-Verifikation → `127 69 76 70` ✅
- Test 5: `fn sum(n): int64` mit Akkumulator → `/tmp/test_cg_sum` gibt "55" aus ✅

**Abhängigkeiten:** WP-06 (Parser), WP-07 (Sema)

---

### WP-09: Bootstrap-Test – Kompiliere lyxc-mini mit sich selbst ✅ ERLEDIGT

**Beschreibung:**
Führe den kompletten Bootstrap durch. Schreibe einen minimalen `lyxc-mini.lyx`
der WP-05 bis WP-08 zusammenführt und als eigenständiger Compiler funktioniert.

**Umgesetzt:**
1. `bootstrap/lyxc_mini.lyx` – verbindet Lexer + Parser + Sema + Codegen ✅
2. **Stage 1:** `./lyxc bootstrap/lyxc_mini.lyx -o lyxc_mini` (mit FPC-Compiler) ✅
3. **Stage 2:** `./lyxc_mini bootstrap/lyxc_mini.lyx -o lyxc_mini2` ✅
4. **Vergleich:** `md5sum lyxc_mini2 lyxc_mini3` → identisch (`0237b1180d92bff8e330ac2f971949c1`) ✅
5. **Self-Hosting erreicht!** ✅

**Compiler-Bugs entdeckt und gefixt:**
- Bug 4: 7-Argument-Methoden-Overflow (Sema.Init hatte self+6=7 Total-Args → r9 overflow)
  Fix: tokCount entfernt, `pTokCount` auf 1000000 hardcoded
- Bug 5: `break` in while-Schleifen wurde als NOP (0x90) kompiliert
  Fix: `jmp rel32` + linked-list-in-placeholder-Ansatz in `cg_genWhile`
- Bug 6: r8/r9 Parameter nicht gespillt in Methoden-Prologs
  Fix: `cg_spillR8`/`cg_spillR9` in `cg_genMethodDecl`/`cg_genFuncDecl`

**Akzeptanzkriterium:**
`lyxc_mini` kann eine Teilmenge von Lyx kompilieren und dabei sich selbst reproduzieren. ✅ ERREICHT

**Abhängigkeiten:** WP-05 bis WP-08

---

### WP-10: Stage 2 – Feature-Parität mit FPC-Compiler

**Beschreibung:**
Erweitere `lyxc_mini.lyx` schrittweise bis er alle Lyx-Features unterstützt
und schließlich den vollen `lyxc.lyx` kompilieren kann.

**Sub-Pakete (je eine Session):**

| Sub-WP | Feature | Abhängigkeit |
|--------|---------|--------------|
| 10a | Klassen + VMT | WP-09 | ✅ COMPLETE
| 10b | Dynamische Arrays | WP-09 | ✅ COMPLETE
| 10c | `switch/case` | WP-09 | ✅ COMPLETE
| 10d | Structs mit Feldzugriff | WP-09 | ✅ COMPLETE
| 10e | Modulimport | WP-09 | ✅ COMPLETE
| 10f | Enum-Typen | WP-04 + WP-09 | ✅ COMPLETE
| 10g | Optimierungen (Constant Folding, CSE) | 10a-10f |
| 10h | ARM64 Backend | 10a-10f |
| 10i | Linter | 10a-10f |
| 10j | Vollständiger Self-Host-Test | alle |

---

## Reihenfolge & Abhängigkeiten

```
WP-01 (Bug Fix: 16-byte Struct Param)
  │
  ├── WP-02 (StringBuilder & String-Utils)
  │     │
  │     ├── WP-03 (File Utils & Argv)
  │     │     │
  │     │     └─┐
  │     └────────┤
  │               │
  │   WP-04 (Enums) ─────────────────────┐
  │                                       │
  └───────────── WP-05 (Lexer) ──────────┤
                    │                     │
                    └── WP-06 (Parser) ───┤
                           │              │
                           └── WP-07 (Sema)
                                  │
                                  └── WP-08 (Codegen)
                                         │
                                         └── WP-09 (Bootstrap-Test)
                                                │
                                                └── WP-10 (Feature-Parität)
```

---

## Aufwandsschätzung

| Paket | Sessions | Schwierigkeit |
|-------|----------|---------------|
| WP-01 | 1 | Mittel (Kenntnis der Prologue-Generierung nötig) |
| WP-02 | 1 | Leicht |
| WP-03 | 0.5 | Leicht |
| WP-04 | 2 | Mittel (Parser + Sema-Änderungen) |
| WP-05 | 2 | Mittel (viele Tokenkombinationen) |
| WP-06 | 2-3 | Mittel-Schwer (Ausdrucks-Grammatik) |
| WP-07 | 1-2 | Mittel |
| WP-08 | 3-4 | Schwer (x86_64 Encoding, ELF) |
| WP-09 | 1 | Leicht (Zusammenführung) |
| WP-10 | 5-10 | Mittel-Schwer (iterativ) |
| **Gesamt** | **~20-25 Sessions** | |

---

## Entscheidungen & Prinzipien

1. **Kein OOP im Bootstrap-Compiler** – Nur Structs und Funktionen (einfacher zu bootstrappen)
2. **Kein GC** – Manuelle Speicherverwaltung mit mmap/munmap; Compiler-Läufe sind kurzlebig
3. **Kein IR** im Mini-Compiler – Direkt AST → x86_64 (spart ein ganzes Transformationspass)
4. **Subset-Ansatz** – Bootstrap-Compiler muss nur Lyx-Subset kennen, den er selbst verwendet
5. **Deterministische Ausgabe** – Kein Randomness in Code-Layout (wichtig für Stage-2-Vergleich)
6. **Con-Konstanten statt Enums** – bis WP-04 abgeschlossen ist

---

## Was NICHT benötigt wird (für Stage 1)

- Kein Garbage Collector (mmap-Puffer reichen)
- Keine echten Generics (spezialisierte Typen reichen)
- Kein Exception Handling (panic() reicht)
- Kein ARM64/Windows Backend (erst Stage 2)
- Keine Linter-Integration (erst Stage 2)
- Kein Debuginfo (erst Stage 2)
- Keine IR-Optimierungen (erst Stage 2)

---

## Bekannte Risiken

| Risiko | Wahrscheinlichkeit | Gegenmaßnahme |
|--------|-------------------|---------------|
| Weitere 16-byte Struct Bugs | Mittel | Avoid struct params >8 Bytes im Bootstrap-Compiler |
| Dynamic Array push/pop Bugs | Niedrig | Frühzeitig testen (WP-02) |
| x86_64 Encoding Fehler im Codegen | Hoch | Byte-für-Byte mit `objdump` vergleichen |
| Stage-2-Compiler weicht ab | Mittel | Deterministisches Layout erzwingen |
| Rekursion im Parser (Stack Overflow) | Niedrig | Iterative Loops bevorzugen |

---

*Erstellt: 2026-03-25 | Lyx v0.5.5 | Ziel: Self-Hosted Compiler in ~20-25 Sessions*
