# Aerospace TODO – Lyx als Safety-Critical Compiler

## Überblick

Dieses Dokument beschreibt den Fortschritt und die offenen Tasks zur Qualifizierung
von **Lyx** als Compiler für **safety-critical Aerospace-Software** (DO-178C DAL A/B/C).

Basierend auf **aerospace.pdf v2** (Lyx Aerospace Extension) mit neuen Features:
- Flightoperations (Deterministik, Echtzeit)
- Construction (Hardware-Integration)
- Mission-Handling (Formale Sicherheit)
- Telemetrie (Datenübertragung)
- Integritäts-Management-System (TMR, Scrubber)

**Stand:** 2026-04-04 | **Version:** 0.9.0-aerospace

---

## ✅ Abgeschlossene Tasks (89 von 127)

### 1. DO-178C Software Compliance

#### 1.1 Tool Qualification (TQL-5) – 3/6 ✅
- [x] **TQL-5 Einstufung** → Lyx als TQL-5 Tool klassifiziert
- [x] **Tool Operational Requirements (TOR)** → `tor_lyx.md` mit 20 TORs
- [x] **Tool Validation** → `test_tor_validation.pas` (23/23 Tests bestanden)

#### 1.2 Compiler-Verifikation – 1/5 ✅
- [x] **Reference Interpreter** → `test_reference_interpreter.pas` (22/22 Tests: Arithmetik, Bit-Ops, Vergleiche, Map/Set, Globals)

#### 1.3 Deterministischer Codegen – 5/5 ✅ KOMPLETT
- [x] Keine nicht-deterministischen Optimierungen
- [x] Reproduzierbare Builds → `test_determinism.pas` (18/18 Tests, 10x-Stresstest)
- [x] Keine zeitabhängigen Entscheidungen
- [x] Feste Register-Allokierung
- [x] Feste Stack-Layout-Berechnung

---

### 3. Backend-Sicherheit

#### 3.1 ESP32 / Xtensa – 6/6 ✅ KOMPLETT
- [x] Watchdog-Integration → `watchdog_init()`, `watchdog_feed()`, `wdt_reset()` + Init im `_start`
- [x] Brownout-Detection → `brownout_check()`, `brownout_config()` (2.8V Default)
- [x] Flash-Sicherheit → `flash_verify()` (CRC32), `secure_boot()`
- [x] Secure Boot → `secure_boot()` builtin
- [x] Memory Protection Unit → `mpu_config()`, 5 Regionen definiert
- [x] Cache-Kohärenz → `cache_flush()` builtin

#### 3.2 ARM Cortex-M – 4/5 ✅
- [x] MPU-Konfiguration → `mpu_config()`, `mpu_enable()`, 8 Regionen, AP-Bits
- [x] Fault-Handler → Vector Table, CFSR/HFSR, MMFAR/BFAR, `get_fault_status()`
- [x] Stack-Canary → `stack_canary_check()`, 3 Canaries, $DEADBEEF pattern
- [x] Privileged/Unprivileged Mode → `set_unprivileged()`, `set_privileged()`

#### 3.3 RISC-V – 4/4 ✅ KOMPLETT
- [x] PMP (Physical Memory Protection) → `pmp_config()`, `pmp_lock()`, 16 Regionen, NAPOT/NA4/TOR
- [x] Machine Mode → `mret()`, `sret()`, `get_mhartid()`, `get_mcycle()`, CSR-Zugriff
- [x] Ecall/Ebreak → `ecall_syscall()`, `ebreak()`, `wfi()`, `fence()`, `fence_i()`
- [x] Atomic Operations → RV64A Extension (LR/SC) im Emitter integriert

---

### 4. Test-Abdeckung (MC/DC)

#### 4.1 MC/DC – 4/4 ✅ KOMPLETT
- [x] MC/DC-Instrumentierung → `ir_mcdc.pas` Pass, `--mcdc` CLI-Flag, `__mcdc_record` in allen 7 Backends
- [x] Coverage-Tracking → `TMCDCDecision` mit HitCount, ConditionResults, DecisionResult
- [x] MC/DC-Bericht → `GenerateReport()` mit `--mcdc-report` Flag
- [x] **Lücken-Erkennung** → `AnalyzeGaps()` erkennt nicht abgedeckte Pfade: Condition T/F, Decision T/F, never executed

#### 4.2 Test-Generierung – 4/4 ✅ KOMPLETT
- [x] Symbolic Execution → 15 Pfade durch if/else-Bäume, Path-Condition-Tracking
- [x] Boundary-Value-Analyse → 28 Tests (int64, Strings, Arrays, Functions) – alle bestanden
- [x] Mutation Testing → 3 Mutationen, 1 killed (33% Score)
- [x] Fuzzing → 50 zufällige Programme, 0 Crashes, 50 unique inputs

---

### 5. Statische Analyse

#### 5.1 Compiler-interne Analysen – 7/7 ✅ KOMPLETT
- [x] Data-Flow-Analyse → Def-Use-Ketten mit Use-Location-Tracking
- [x] Live-Variable-Analyse → Unused-Var-Warnungen via `--static-analysis`
- [x] Constant-Propagation → irConstInt/irAdd/irSub/irMul, 5/10 Konstanten erkannt
- [x] Null-Pointer-Analyse → ConstStr-Tracking, Null-Check-Erkennung
- [x] Array-Bounds-Analyse → irLoadElem/irStoreElem Tracking, SAFE/UNVERIFIED
- [x] Terminierungs-Analyse → Loop-Erkennung via irJmp/irBrTrue/irBrFalse
- [x] Stack-Nutzungs-Analyse → Slot-Count, Byte-Berechnung, Rekursions-Erkennung

---

### 8. Dokumentation

#### 8.2 Compiler-Dokumentation – 5/5 ✅ KOMPLETT
- [x] **Compiler Manual** → `COMPILER_MANUAL.md` (700+ Zeilen)
- [x] **User Guide** → `USER_GUIDE.md` (Getting Started, Language, Safety, Advanced)
- [x] **Verification Report** → `VERIFICATION_REPORT.md` (111/111 Tests)
- [x] **Change Log** → `CHANGELOG.md` mit v0.7.0-aerospace Eintrag
- [x] **Problem Reports** → `COMPILER_MANUAL.md` Section 9 (Known Issues)

---

### 2. Spracherweiterungen

#### 2.1 Safety-Pragmas – 1/3 ✅
- [x] **Pragma-Parser** → `@dal(A|B|C|D)`, `@critical`, `@wcet(N)`, `@stack_limit(N)` – Parser, AST, IR-Propagation, Sema-Checks; `test_pragma_parser.pas` (30/30 Tests)

#### 2.2 Range-Typen – 1/1 ✅ KOMPLETT
- [x] **Range-Typen** → `type T = intN range Min..Max` – Lexer `tkDotDot`, Parser, Sema Compile-Time-Check, IR Runtime-Check; `test_range_types.pas` (33/33 Tests)

#### 6.1 Codegen-Sicherheit – 1/4 ✅
- [x] **Assembly-Listing** → `asm_listing.pas`, `TAsmListingGenerator`, `--asm-listing` Flag; Source-Zeilen-Kommentare für alle 4 Hauptarchitekturen (x86_64, ARM64, RISC-V, Xtensa)

#### 7.1 Laufzeit-Sicherheit – 1/2 ✅
- [x] **assert() Builtin** → `TAstAssert`, `nkAssert` AST-Node, Parser+Sema+IR-Lowering; `assert(cond, msg)` mit bool-Condition und Fehlermeldung

---

### 10. Spezifische Implementierungs-Tasks (teilweise)

#### 10.3 Backend – 3/6 ✅
- [x] Watchdog-Integration (ESP32 ✅)
- [x] MPU/PMP-Konfigurations-Generierung (ESP32 ✅)
- [x] Stack-Canary-Insertion (ESP32 ✅)

---

## ❌ Offene Tasks (46), priorisiert nach aerospace.pdf v2

### 🔴 P0 – Kritisch (DO-178C DAL A Voraussetzung)

| # | Task | Sektion | Aufwand | Bezug aerospace.pdf |
|---|------|---------|---------|---------------------|
| ~~1~~ | ~~**MC/DC Lücken-Erkennung**~~ | ~~4.1~~ | ~~Mittel~~ | ✅ |
| ~~2~~ | ~~**Assembly-Listing**~~ | ~~6.1~~ | ~~Mittel~~ | ✅ |
| ~~3~~ | ~~**assert() Builtin**~~ | ~~7.1~~ | ~~Mittel~~ | ✅ |
| ~~4~~ | ~~**MISRA-Regel: Keine impliziten Typkonvertierungen**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ (MISRA C) |
| ~~5~~ | ~~**MISRA-Regel: Keine unbenutzten Variablen/Parameter**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ |
| ~~43~~ | ~~**@integrity Blöcke**~~ | ~~2.5.1~~ | ~~Hoch~~ | ✅ **ERLEDIGT** – `TIntegrityMode`/`TIntegrityAttr` in `backend_types`, Lexer/Parser: `@integrity(mode: software_lockstep\|scrubbed\|hardware_ecc, interval: N)` vor `unit` und `fn`; Sema: extern-Fehler + scrubbed-ohne-interval-Warnung; IR: `TIRModule.UnitIntegrity`; `test_integrity_blocks.pas` (28/28 Tests) |
| ~~44~~ | ~~**.meta_safe ELF Section**~~ | ~~2.5.2~~ | ~~Hoch~~ | ✅ **ERLEDIGT** – `WriteElf64WithMetaSafe`/`WriteElf64ARM64WithMetaSafe`/`WriteElf64RISCVWithMetaSafe` (x86_64, ARM64, RISC-V); CRC32-IEEE-802.3 Triple-Hash-Store (3 identische Kopien, 4096-Byte-Separation); ELF Section Headers: NULL + .text + .shstrtab + .meta_safe; Header-Layout: code_start_va, code_end_va, mode, interval_ms, recovery_ptr=0; Sektionsgröße: 8232 Bytes; `test_meta_safe.pas` (39/39 Tests) |
| 45 | **VerifyIntegrity() Builtin** | 2.5.3 | Mittel | Section 2.5.3 |
| 46 | **TMR Hash-Store Unterstützung** | 2.5.2 | Hoch | Section 2.5.2 |

### 🟠 P1 – Hoch (wichtig für DAL B/C)

| # | Task | Sektion | Aufwand | Bezug aerospace.pdf |
|---|------|---------|---------|---------------------|
| ~~6~~ | ~~**Pragma-Parser**~~ | ~~2.1, 10.1~~ | ~~Hoch~~ | ✅ |
| ~~7~~ | ~~**Range-Typen**~~ | ~~2.2, 10.1~~ | ~~Hoch~~ | ✅ (Einheiten-Sicherheit) |
| ~~7b~~ | ~~**check() Builtin**~~ | ~~7.1~~ | ~~Niedrig~~ | ✅ |
| ~~8~~ | ~~**Call-Graph**~~ | ~~6.1~~ | ~~Mittel~~ | ✅ |
| ~~9~~ | ~~**Map-File**~~ | ~~6.1~~ | ~~Mittel~~ | ✅ |
| ~~10~~ | ~~**Pattern-Matching**~~ | ~~7.2, 10.1~~ | ~~Mittel~~ | ✅ |
| ~~11~~ | ~~**MC/DC-Test-Suite**~~ | ~~10.4~~ | ~~Mittel~~ | ✅ |
| 12 | **TrustZone (Cortex-M33+)** | 3.2 | Hoch | Section 3.2 |
| ~~47~~ | ~~**Bounded While Loops**~~ | ~~2.1~~ | ~~Mittel~~ | ✅ **ERLEDIGT** – `tkLimit` Token, `TAstWhile.CreateBounded`, Parser mit `limit(...)`, Sema Typ-Check; Syntax: `while (cond) limit(n)` |
| 48 | **@flight_crit Sektion** | 2.1 | Mittel | Section 2.1 |
| 49 | **Priority-Attribute für Funktionen** | 2.1 | Mittel | Section 2.1 (Echtzeit-Scheduling) |
| 50 | **Bit-Level Memory Mapping** | 2.2 | Mittel | Section 2.2: `at(bit_position)` |
| 51 | **@redundant Attribut (TMR)** | 2.2 | Mittel | Section 2.2 |
| 52 | **@big_endian / @little_endian** | 4 | Niedrig | Section 4 |

### 🟡 P2 – Mittel (nice-to-have für DAL C)

| # | Task | Sektion | Aufwand | Bezug aerospace.pdf |
|---|------|---------|---------|---------------------|
| 13 | **Symbol-Table: DWARF** | 6.1 | Hoch | Section 8 |
| ~~15~~ | ~~**MISRA: Keine rekursiven Funktionen**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ (Stack-Safety) |
| ~~16~~ | ~~**MISRA: Keine impliziten Typkonvertierungen**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ |
| ~~17~~ | ~~**MISRA: Keine Pointer-Arithmetik**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ **ERLEDIGT** – Linter W017 `lrPointerArithmetic`, erkennt p + n, p - n |
| ~~18~~ | ~~**MISRA: Switch-Cases vollständig**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ **ERLEDIGT** – Linter W018 `lrIncompleteSwitch`, warnt ohne default |
| ~~19~~ | ~~**MISRA: Maximale Funktionslänge (60)**~~ | ~~5.2~~ | ~~Niedrig~~ | ✅ **ERLEDIGT** – Linter W019 `lrFunctionTooLong`, Statement-Zählung |
| ~~20~~ | ~~**MISRA: Zyklomatische Komplexität (15)**~~ | ~~5.2~~ | ~~Mittel~~ | ✅ **ERLEDIGT** – Linter W020 `lrComplexFunction`, if/while/for/switch-Zählung |
| 53 | **WCET-Schätzung** | 10.2 | Hoch | Section 2.1 |
| ~~54~~ | ~~**Stack-Analyse über Call-Grenzen**~~ | ~~10.2~~ | ~~Mittel~~ | ✅ **ERLEDIGT** – `TStaticAnalyzer.AnalyzeStackUsageWithCallGraph`, `TCallGraph.GetCalleesList`, Worst-Case-Stack über Call-Graph |
| 55 | **Design by Contract (pre/post)** | 3 | Hoch | Section 2.3 |
| 56 | **RingBuffer<T> Typ** | 4 | Mittel | Section 4 |
| 57 | **Flat Structs für Zero-Copy** | 4 | Niedrig | Section 4 |
| 58 | **Floating Point Deterministik** | 7 | Niedrig | Section 7 |

### 🟢 P3 – Niedrig (langfristig / formal)

| # | Task | Sektion | Aufwand | Bezug aerospace.pdf |
|---|------|---------|---------|---------------------|
| 25 | **Tool Verification (Bootstrapping)** | 1.1 | Hoch | - |
| 26 | **Configuration Management** | 1.1 | Niedrig | - |
| 27 | **QA: Review-Prozesse** | 1.1 | Niedrig | - |
| 28 | **Formale Spezifikation (Coq)** | 1.2 | Sehr Hoch | Section 2.3 |
| 29 | **Proof of Correctness** | 1.2 | Sehr Hoch | - |
| 30 | **Bisimulation** | 1.2 | Sehr Hoch | - |
| 31 | **Formal-verifizierte Tests** | 10.4 | Sehr Hoch | - |
| 59 | **@requirement("ID") Attribut** | 5.4 | Niedrig | Section 5.4 |
| 60 | **Bidirektionale Traceability** | 5.4 | Mittel | Section 5.4 |
| 61 | **MIL-STD-1553 / SpaceWire** | 5.5 | Hoch | Section 5.5 |
| 62 | **HIL/SIL Simulation** | 5.6 | Hoch | Section 5.6 |
| 63 | **Shadow Stack** | 2.5.4 | Hoch | Section 2.5.4 |
| 64 | **Parity-Alloc für Heap** | 2.5.4 | Mittel | Section 2.5.4 |
| 65 | **Panic-Strategien für kritische Sektionen** | 5.1 | Mittel | Section 5.1 |
| 66 | **Error State Machine** | 5.1 | Mittel | Section 5.1 |
| 67 | **Static Memory Pools** | 5.2 | Mittel | Section 5.2 |
| 68 | **@interrupt_handler Attribut** | 5.3 | Mittel | Section 5.3 |
| 69 | **Priority Ceiling Protocol** | 5.3 | Mittel | Section 5.3 |
| 70 | **Dead-Code-Elimination** | 10.2 | Mittel | - |
| 71 | **`unsafe`-Block-Semantik** | 10.1 | Mittel | Section 4 |
| 72 | **Inline-Assembly-Sicherheit** | 6.2 | Mittel | - |
| 73 | **verify() Builtin** | 7.1 | Niedrig | Section 2.3 |
| 74 | **Assertion-Levels (@dal)** | 7.1 | Niedrig | - |
| 75 | **Keine Heap-Allokation nach Init** | 5.2 | Mittel | Section 4 |
| 76 | **Automatische Coverage-Reports** | 8.1 | Niedrig | Section 5.4 |
| 77 | **Task-Deklarationen (@period)** | 2.3, 10.1 | Hoch | Section 2.1 |
| 78 | **Concurrency-Modell** | 2.3 | Sehr Hoch | Section 5.3 |

---

## Fortschritt

| Kategorie | Erledigt | Offen | Fortschritt |
|-----------|----------|-------|-------------|
| **1. DO-178C Compliance** | 9 | 8 | 53% |
| **2. Spracherweiterungen** | 9 | 9 | 50% |
| **3. Backend-Sicherheit** | 14 | 1 | 93% |
| **4. Test-Abdeckung** | 9 | 0 | 100% |
| **5. Statische Analyse** | 10 | 5 | 67% |
| **6. Codegen-Sicherheit** | 2 | 8 | 20% |
| **7. Laufzeit-Sicherheit** | 2 | 6 | 25% |
| **8. Dokumentation** | 5 | 3 | 63% |
| **9. Build/CI** | 0 | 7 | 0% |
| **10. Implementierungs-Tasks** | 8 | 10 | 44% |
| **11. Aerospace Extension (NEW)** | 3 | 11 | 21% |
| **GESAMT** | **89** | **38** | **70%** |

---

## Neue Tasks aus aerospace.pdf v2 (Zusammenfassung)

### Flightoperations (Section 2.1)
- Bounded While Loops: `while (x < y) limit(1000)`
- @flight_crit / @critical_state
- Priority-Attribute

### Construction (Section 2.2)
- Bit-Level Mapping: `field: u12 at(0)`
- @redundant für TMR

### Mission-Handling (Section 2.3)
- Design by Contract: `pre()`, `post()`
- Ranged Types (bereits implementiert!)

### Telemetrie (Section 4)
- Endianness: @big_endian / @little_endian
- RingBuffer<T>
- Flat structs

### Integritäts-Management (Section 2.5)
- @integrity(mode: scrubbed, interval: 100)
- .meta_safe Section
- VerifyIntegrity() builtin
- Shadow Stack

### Fehlende Bereiche (Section 5)
- Panic-Strategien
- Memory Pools
- Interrupt-Handler
- Requirement-IDs
- HIL/SIL Testing

---

## Empfohlene nächste Schritte (Priorität)

1. ~~**@integrity Blöcke**~~ ✅ ERLEDIGT
2. ~~**`.meta_safe` ELF Section**~~ ✅ ERLEDIGT (P0, #44)
3. **VerifyIntegrity() Builtin** (P0, #45) – Runtime-Validierung
4. **TMR Hash-Store** (P0, #46) – Dreifach-redundante Hashes
5. **TMR / @redundant Attribut** (P1) – Strahlungstoleranz
6. **Shadow Stack** (P3) – Control-Flow-Schutz

---

## Referenzen

- **DO-178C**: Software Considerations in Airborne Systems
- **MISRA C:2023**: Guidelines for critical systems
- **ECSS-E-ST-40C**: European Co-operation for Space Standardization
- **ECSS-Q-ST-80C**: Software product and software system assurance
- **aerospace.pdf v2**: Lyx Aerospace Extension Konzept (2026-04-03)
