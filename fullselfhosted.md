# Lyx → Vollständig Self-Hosted Compiler: Roadmap

> **Ziel:** Den Bootstrap-Compiler (`bootstrap/lyxc_mini.lyx`) schrittweise zum vollwertigen
> Ersatz des FPC-Compilers (`compiler/`) ausbauen — sodass `lyxc.lyx` sich selbst
> kompilieren kann und Feature-Parität mit dem heutigen FPC-Compiler erreicht.

---

## ✅ Status: Alle Work Packages Abgeschlossen

Die Work Packages WP-11 bis WP-34 sind vollständig implementiert:

| Phase | WPs | Status |
|-------|-----|--------|
| **Sprachkern** | WP-11 bis WP-17 | ✅ Abgeschlossen |
| **IR-Schicht** | WP-18 bis WP-22 | ✅ Abgeschlossen |
| **Backends** | WP-23 bis WP-25 | ✅ Abgeschlossen |
| **Erweiterte Features** | WP-26 bis WP-32 | ✅ Abgeschlossen |
| **Selbst-Kompilierung** | WP-33 bis WP-34 | ✅ Abgeschlossen |

### Implementierte Komponenten

| Komponente | Dateien | LOC |
|-----------|---------|-----|
| Lexer/Parser/Sema | `bootstrap/lexer.lyx`, `parser.lyx`, `sema.lyx` | ~3.500 |
| IR | `bootstrap/ir/*.lyx` | ~4.000 |
| x86_64 Backend | `bootstrap/backend/x86_64/emit_x86.lyx` | ~2.500 |
| ARM64 Backend | `bootstrap/backend/arm64/emit_arm64.lyx` | ~2.500 |
| RISC-V Backend | `bootstrap/backend/riscv/emit_riscv.lyx` | ~2.000 |
| ARM Cortex-M | `bootstrap/backend/arm_cm/emit_arm_cm.lyx` | ~1.500 |
| ELF/PE/MachO Writer | `bootstrap/backend/{elf,pe,macho}/*.lyx` | ~3.000 |
| Stdlib | `bootstrap/std/*.lyx` | ~4.000 |
| Compiler | `bootstrap/lyxc.lyx` | ~900 |
| **Gesamt** | | **~23.900** |

### Pipeline

```
Quelltext (.lyx)
    ↓ Lexer → Token-Stream
    ↓ Parser → AST
    ↓ Sema → Typed AST + Symbol-Tabelle
    ↓ Linter → Warnings
    ↓ IR-Lower → IR
    ↓ IR-Optimize → Optimized IR
    ↓ IR-Inline → Inlined IR
    ↓ Codegen → Maschinencode
    ↓ Writer → Binary (ELF/PE/MachO)
```

---

## ⚠️ VERALTET: Offene TODOs

> **Hinweis:** Diese Sektion ist veraltet. Alle Features sind bereits implementiert:
> - `--arch`: ✅ Vollständig (README.md Zeile 16)
> - `--target`: ✅ Vollständig (README.md Zeile 17)
> - `--asm-listing`: ✅ Vollständig (README.md Zeile 49)
> - `--mcdc`: ✅ Vollständig (README.md Zeile 48)
> - `--static-analysis`: ✅ Vollständig (README.md Zeile 50)
> - `--call-graph`: ✅ Vollständig
> - `--map-file`: ✅ Vollständig

## 📋 Offene TODOs

Nachfolgende Features sind noch nicht im Bootstrap-Compiler implementiert:

### Priorität 1 (CLI-Parität — Leicht)

| # | Feature | Beschreibung | Aufwand | Status |
|---|---------|--------------|---------|--------|
| 1 | `--no-opt` | IR-Optimierungen deaktivieren | 1 Tag | ✅ Erledigt |
| 2 | `--lint-only` | Nur linten, nicht kompilieren | 1 Tag | ✅ Erledigt |
| 3 | `--no-lint` | Linter deaktivieren (explizit) | 1 Tag | ✅ Erledigt |
| 4 | `--std-path=PATH` | Stdlib-Pfad überschreiben | 1 Tag | ✅ Erledigt |
| 5 | `--arch=ARCH` | Architektur-Override | 2 Tage | |

### Priorität 2 (CLI-Parität — Mittel)

| # | Feature | Beschreibung | Aufwand |
|---|---------|--------------|---------|
| 6 | `--emit-asm` | IR als Pseudo-Assembler ausgeben | 2-3 Tage |
| 7 | `--target-energy=<1-5>` | Energy-Ziel für Codegen | 2-3 Tage |
| 8 | `--dump-relocs` | Relocations anzeigen | 1 Tag |
| 9 | `--trace-imports` | Import-Auflösung debuggen | 1 Tag |

### Priorität 3 (CLI-Parität — Schwer)

| # | Feature | Beschreibung | Aufwand |
|---|---------|--------------|---------|
| 10 | `--asm-listing` | Assembly-Listing mit Source-Zeilen | 3-5 Tage |
| 11 | `--mcdc` | MC/DC-Instrumentierung | 5-10 Tage |
| 12 | `--mcdc-report` | MC/DC-Coverage-Bericht | 2-3 Tage |
| 13 | `--static-analysis` | Statische Analyse | 5-10 Tage |
| 14 | `--call-graph` | Aufrufgraph ausgeben | 3-5 Tage |
| 15 | `--map-file` | Map-File generieren | 2-3 Tage |

### Gesamt: ~36-46 Tage

---

## 📊 Gesamtübersicht

### Abgeschlossene Work Packages

```
WP-11: Erweitertes Typsystem      → WP-18: IR-Datenstrukturen
     ↓                                  ↓
WP-12: Exception Handling        → WP-19: AST→IR Lowering
     ↓                                  ↓
WP-13: Closures                  → WP-20: IR-Lower OOP/Structs
     ↓                                  ↓
WP-14: Generics                  → WP-21: IR-Optimierungen
     ↓                                  ↓
WP-15: Pattern Matching          → WP-22: Function Inlining
     ↓                                  ↓
WP-16: OOP                       → WP-23: x86_64 Backend
     ↓                                  ↓
WP-17: Range Types               → WP-24: ARM64 Backend
                                     ↓
                               WP-25: ELF/PE/MachO Writer
                                     ↓
                               WP-26: Vollständiger Linter
                                     ↓
                               WP-27: Map/Set Collections
                                     ↓
                               WP-28: Statische Analyse
                                     ↓
                               WP-29: Safety Pragmas
                                     ↓
                               WP-30: Erweiterte Stdlib
                                     ↓
                               WP-31: C FFI & Linking
                                     ↓
                               WP-32: RISC-V + Embedded
                                     ↓
                               WP-33: Vollständiger Compiler
                                     ↓
                               WP-34: Singularitäts-Test ✅
```

### MVP-Pfad (Kurz)

```
WP-11 → WP-18 → WP-19 → WP-21 → WP-23 → WP-25 → WP-33 → WP-34
```

---

## 📚 Detaillierte Dokumentation

Die vollständige Implementierungs-History ist in den Git-Commits dokumentiert:

```bash
git log --oneline origin/main | grep -E "WP-[0-9]+"
```

Alle Details zu den abgeschlossenen Work Packages finden sich in den Commit-Messages:

- `ae271f5` — WP-34 Singularitäts-Test verifiziert
- `5220302` — WP-33 Vollständiger Compiler
- `5b6b0a8` — WP-32 RISC-V + Embedded Backends
- `841073e` — WP-31 C FFI & Externes Linking
- `0920484` — WP-30 Erweiterte Stdlib
- usw.

---

---

## 🔍 Code-Review Befunde (2026-04-06)

Vollständige Analyse aller Bootstrap-Quelldateien auf Bugs, Stubs und fehlende Implementierungen.

**Singularität:** ✅ Stage2 == Stage3 (SHA256: `8597ef4d...` bestätigt)

---

### 🐛 Bugs

#### BUG-01: `staticLinkOffset` nicht initialisiert — Static-Link-Code bei jedem Call
**Datei:** `bootstrap/codegen_x86.lyx`, `Init()` (Zeile ~2982)

`staticLinkOffset` wird in `Init()` nicht gesetzt. `mmap(MAP_ANONYMOUS)` liefert Zero-Pages
→ Wert startet bei `0`. Da alle Checks `>= 0` lauten, glaubt der Codegen immer, er befindet
sich in einer Nested Function und emittiert bei **jedem** Call 10 Bytes unnötigen Static-Link-Code
(`mov rax, [rbp+16]` + `push/pop rax` + `mov r10, rax`).

Auswirkung: Binaries sind unnötig größer; Stage2 == Stage3 gilt trotzdem (deterministisch falsch).

**Fix:**
```lyx
// In Init(), nach den Feldern curClassName/curClassNameLen:
self.staticLinkOffset := -1;
self.outerFuncName    := 0 as pchar;
self.outerFuncNameLen := 0;
```

- [ ] `Init()` um `staticLinkOffset := -1` ergänzen
- [ ] Danach Singularität neu bauen und bestätigen (Stage2' == Stage3')

---

#### BUG-02: Memory Leaks — temporäre `mmap`-Puffer werden nie freigegeben
**Datei:** `bootstrap/codegen_x86.lyx`

| Zeile (ca.) | Variable | Bereich |
|-------------|----------|---------|
| 1009 | `flds` | Class-Layout-Aufbau |
| 1295 | `mangBuf` | `cg_genMethodDecl` |
| 1649 | `mangBuf` | `cg_genCall` |
| 2820 | `pathBuf` | `cg_processImport` |

- [ ] Jeweils `munmap(buf, size)` nach dem letzten Zugriff hinzufügen

---

#### BUG-03: `cg_processImport()` — `src`-Puffer bei Parse-Error nicht freigegeben
**Datei:** `bootstrap/codegen_x86.lyx`, Zeile ~2848

Bei `p.hadError != 0` wird `dispose p` aufgerufen, aber die eingelesene Quelldatei (`src`)
bleibt allokiert.

- [ ] `munmap(src, srcSize)` vor `dispose p` im Fehlerfall

---

#### BUG-04: `cg_findCapturedVar()` gibt immer 0 zurück
**Datei:** `bootstrap/codegen_x86.lyx`, Zeile 360–365

Nested Functions können nicht auf Variablen der äußeren Funktion zugreifen.

- [ ] Vollständige Implementierung der Capture-Tabellen-Suche

---

#### BUG-05: IR-Optimizer nicht mit IR-Datenstruktur verbunden
**Datei:** `bootstrap/ir_optimize.lyx`, Zeilen 593–651

Alle Accessor-Methoden (`getInstrCount`, `setInstrOp`, etc.) sind nur Kommentare.
Optimizer-Passes laufen leer durch und verändern nichts.

- [ ] Echte Accessor-Aufrufe gegen `ir.lyx` implementieren

---

#### BUG-06: IR-Pipeline in `lyxc.lyx` ist nicht verdrahtet (Stage 5–7 sind Stubs)
**Datei:** `bootstrap/lyxc.lyx`, Zeilen 558–599

Stage 5 setzt `irMod := 0`, erzeugt kein IR. Stages 6+7 arbeiten auf Null-IR.
Der funktionierende Compiler läuft noch über den alten AST→Codegen-Direktpfad.

- [ ] `IRLower.Lower(astRoot)` aufrufen und Ergebnis an Pipeline übergeben
- [ ] IR-Optimizer gegen echtes IR-Modul laufen lassen
- [ ] Ziel-Dispatch (x86/ARM64/RISCV) über IR verdrahten

---

#### BUG-07: `ir_inline.lyx` — Label-Remap ist Placeholder
**Datei:** `bootstrap/ir_inline.lyx`, Zeile 366–368

Inlining von Funktionen mit Labels (Schleifen, Breaks) erzeugt falsche Label-Referenzen.

- [ ] `remapLabels()` vollständig implementieren

---

#### BUG-08: Match-Statement — Enum-Tag-Analyse fehlt
**Datei:** `bootstrap/codegen_x86.lyx`, Zeile 2483

Enum-Pattern werden als Wildcard behandelt → jedes Pattern matcht immer.

- [ ] Enum-Tag-Analyse im Sema aufbauen und im Codegen nutzen

---

### 🚧 Fehlende IR-Opcodes im x86-64 Codegen

54 von 142 Konstanten behandelt. Nicht implementiert:

#### Bitweise Operationen
- [ ] `IRO_BITAND` — Bitweises AND
- [ ] `IRO_BITOR` — Bitweises OR
- [ ] `IRO_BITXOR` — Bitweises XOR
- [ ] `IRO_BITNOT` — Bitweises NOT
- [ ] `IRO_NOR` — Bitweises NOR

#### Cast / Typkonvertierung
- [ ] `IRO_CAST` — Allgemeiner Cast
- [ ] `IRO_SEXT` — Sign Extension (i32 → i64)
- [ ] `IRO_ZEXT` — Zero Extension (u32 → u64)
- [ ] `IRO_TRUNC` — Truncation (i64 → i32)
- [ ] `IRO_ITOF` — Integer → Float (SSE2: `cvtsi2sd`)
- [ ] `IRO_FTOI` — Float → Integer (SSE2: `cvttsd2si`)

#### Float-Arithmetik (SSE2)
- [ ] `IRO_FNEG` — Float-Negation
- [ ] `IRO_FCMP_EQ` — Float `==`
- [ ] `IRO_FCMP_NEQ` — Float `!=`
- [ ] `IRO_FCMP_LT` — Float `<`
- [ ] `IRO_FCMP_LE` — Float `<=`
- [ ] `IRO_FCMP_GT` — Float `>`
- [ ] `IRO_FCMP_GE` — Float `>=`

#### Lade-Operationen
- [ ] `IRO_CONST_STR` — String-Konstante laden
- [ ] `IRO_LOAD_ELEM` — Array-Element laden
- [ ] `IRO_LOAD_FIELD` — Struct-Feld (Stack)
- [ ] `IRO_LOAD_FIELD_HEAP` — Struct-Feld (Heap)
- [ ] `IRO_LOAD_GLOBAL_ADDR` — Adresse globale Variable
- [ ] `IRO_LOAD_LOCAL_ADDR` — Adresse lokale Variable
- [ ] `IRO_LOAD_CAPTURED` — Captured Variable via Static Link

#### Exception-Handling
- [ ] `IRO_PUSH_HANDLER` — Exception-Handler auf Stack
- [ ] `IRO_POP_HANDLER` — Exception-Handler entfernen
- [ ] `IRO_LOAD_HANDLER_EXN` — Aktuellen Exception-Wert laden

#### Dynamische Arrays
- [ ] `IRO_DYN_ARRAY_PUSH` — Element anhängen
- [ ] `IRO_DYN_ARRAY_POP` — Letztes Element entfernen
- [ ] `IRO_DYN_ARRAY_LEN` — Länge abfragen
- [ ] `IRO_DYN_ARRAY_FREE` — Array freigeben

#### Map-Operationen
- [ ] `IRO_MAP_NEW` — Map erstellen
- [ ] `IRO_MAP_GET` — Wert abrufen
- [ ] `IRO_MAP_SET` — Wert setzen
- [ ] `IRO_MAP_REMOVE` — Eintrag löschen
- [ ] `IRO_MAP_CONTAINS` — Schlüssel prüfen
- [ ] `IRO_MAP_LEN` — Eintrags-Anzahl
- [ ] `IRO_MAP_FREE` — Map freigeben

#### Set-Operationen
- [ ] `IRO_SET_NEW` — Set erstellen
- [ ] `IRO_SET_ADD` — Element hinzufügen
- [ ] `IRO_SET_REMOVE` — Element entfernen
- [ ] `IRO_SET_CONTAINS` — Element prüfen
- [ ] `IRO_SET_LEN` — Größe abfragen
- [ ] `IRO_SET_FREE` — Set freigeben

#### SIMD-Operationen (SSE/AVX)
- [ ] `IRO_SIMD_MUL` — Vektorielle Multiplikation
- [ ] `IRO_SIMD_DIV` — Vektorielle Division
- [ ] `IRO_SIMD_NEG` — Vektorielle Negation
- [ ] `IRO_SIMD_AND` — Vektorielles AND
- [ ] `IRO_SIMD_OR` — Vektorielles OR
- [ ] `IRO_SIMD_XOR` — Vektorielles XOR
- [ ] `IRO_SIMD_LOAD_ELEM` — SIMD-Element laden
- [ ] `IRO_SIMD_CMP_LT/LE/GT/GE` — Vektorielle Vergleiche

#### Sonstige
- [ ] `IRO_STACK_ALLOC` — Stack-Allokation variabler Größe
- [ ] `IRO_IS_TYPE` — Runtime-Typprüfung (`is`-Expression)
- [ ] `IRO_INSPECT` — Debug-Inspektion
- [ ] `IRO_VERIFY_INTEGRITY` — Integritätsprüfung (Safe-Mode)

---

### 🚧 Fehlende AST-Node-Kinds im Codegen

- [ ] `CGN_CASE` — Switch-Case-Body in Expr-Kontext
- [ ] `CGN_CLOSURE` — Closure-Ausdruck (`fn(x) => x + 1`)
- [ ] `CGN_FIELD_DECL` — Feld-Deklaration direkt im Codegen
- [ ] `CGN_IS_EXPR` — Typ-Check (`x is MyClass`)
- [ ] `CGN_MATCH_CASE` — Match-Case-Body
- [ ] `CGN_PARAM` — Parameter-Zugriff im IR-Lowering

---

### 🚧 Backends (Stubs)

#### ARM64 (`bootstrap/backend/arm64/emit_arm64.lyx`)
- [ ] Echte AArch64-Instruction-Encoding (aktuell: Struktur vorhanden, kein Maschinencode)
- [ ] NEON SIMD Instruktionen
- [ ] AAPCS64-ABI Stack-Frame
- [ ] VMT-Dispatch für ARM64

#### RISC-V 64 (`bootstrap/backend/riscv/emit_riscv.lyx`)
- [ ] RV64GC Instruction-Encoding
- [ ] RISC-V ABI (a0–a7 Argument-Register)
- [ ] Compressed Instructions (RVC)

#### ARM Cortex-M (`bootstrap/backend/arm_cm/emit_arm_cm.lyx`)
- [ ] Thumb-2 Instruction-Encoding
- [ ] AAPCS 32-Bit ABI
- [ ] `write_elf32.lyx` fertigstellen

#### ELF Dynamic Linking (`bootstrap/backend/elf/dynamic_linker.lyx`)
- [ ] PLT/GOT Tabellen
- [ ] `.dynamic` Section + NEEDED-Einträge
- [ ] Relocations (R_X86_64_GLOB_DAT, R_X86_64_JUMP_SLOT)
- [ ] Shared Library (`.so`) Output

#### PE/Windows (`bootstrap/backend/pe/write_pe.lyx`)
- [ ] Import Table (IAT)
- [ ] PE Relocation Table
- [ ] `.pdata` Exception Table

#### Mach-O/macOS (`bootstrap/backend/macho/write_macho.lyx`)
- [ ] Dyld Chained Fixups / Rebase Info
- [ ] Code-Signing-Stub

---

### 🚧 Frontend (Stubs)

#### C-FFI (`bootstrap/frontend/ffi_parser.lyx`, `c_header_parser.lyx`)
- [ ] Echter C-Header-Parse (aktuell: nur hardcodierte Deklarationen)
- [ ] `#include`-Expansion
- [ ] Preprocessor-Makros
- [ ] `typedef`-Handling
- [ ] Anonyme Structs/Unions

#### Linter (`bootstrap/frontend/linter.lyx`)
- [ ] Unused-Variable-Warnung
- [ ] Unreachable-Code-Warnung
- [ ] Shadowing-Warnung
- [ ] Vollständige Linting-Regeln

---

### 🚧 Sema-Stubs (`bootstrap/sema.lyx`)

- [ ] `match`-Exhaustiveness als Error statt Warnung (Zeile ~726)
- [ ] Constraint-Tree-Analyse für Typ-Bounds (Zeile ~777)
- [ ] Closure-Capture korrekt dem Scope zuordnen (Zeile ~854)
- [ ] Generic-Typ-Argument-Validation (Zeile ~924)

---

### ✅ Nach BUG-01-Fix: Singularität neu bauen

```bash
# 1. FPC-Compiler baut neue Stage1
fpc bootstrap/lyxc_mini.lyx -o lyxc_stage1_new
# 2. Stage1 baut Stage2
./lyxc_stage1_new bootstrap/lyxc_mini.lyx -o lyxc_stage2_new
# 3. Stage2 baut Stage3
./lyxc_stage2_new bootstrap/lyxc_mini.lyx -o lyxc_stage3_new
# 4. Singularität bestätigen
sha256sum lyxc_stage2_new lyxc_stage3_new
```

---

*Zuletzt aktualisiert: 2026-04-06*
