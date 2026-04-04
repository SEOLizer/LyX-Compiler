# Aerospace TODO – Lyx als Safety-Critical Compiler

## Überblick

Dieses Dokument beschreibt den Fortschritt und die offenen Tasks zur Qualifizierung
von **Lyx** als Compiler für **safety-critical Aerospace-Software** (DO-178C DAL A/B/C).

**Stand:** 2026-04-03 | **Version:** 0.7.0-aerospace

---

## ✅ Abgeschlossene Tasks (71 von 113)

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

### 10. Spezifische Implementierungs-Tasks (teilweise)

#### 10.3 Backend – 3/6 ✅
- [x] Watchdog-Integration (ESP32 ✅)
- [x] MPU/PMP-Konfigurations-Generierung (ESP32 ✅)
- [x] Stack-Canary-Insertion (ESP32 ✅)

---

## ❌ Offene Tasks (42), neu bewertet und priorisiert

### 🔴 P0 – Kritisch (DO-178C DAL A Voraussetzung)

| # | Task | Sektion | Aufwand | Status |
|---|------|---------|---------|--------|
| ~~1~~ | ~~**MC/DC Lücken-Erkennung**~~ | ~~4.1~~ | ~~Mittel~~ | ✅ **ERLEDIGT** – `AnalyzeGaps()`, Runtime-Counter im Data-Segment, `--mcdc-report` zeigt Gaps |
| 2 | **Assembly-Listing** | 6.1 | Mittel | Generierter Code muss mit Source-Zeilen verknüpft sein für Audit und Debugging |
| 3 | **assert() / check() Builtins** | 7.1 | Mittel | Runtime-Assertions für DAL A – `assert()` (compile+runtime), `check()` (runtime only) |
| 4 | **MISRA-Regel: Keine impliziten Typkonvertierungen** | 5.2 | Niedrig | Sema-Checker Erweiterung – einfache Regel, großer Sicherheitsgewinn |
| 5 | **MISRA-Regel: Keine unbenutzten Variablen/Parameter** | 5.2 | Niedrig | Bereits teilweise durch Live-Variable-Analyse abgedeckt, muss nur als Fehler eskaliert werden |

### 🟠 P1 – Hoch (wichtig für DAL B/C)

| # | Task | Sektion | Aufwand | Begründung |
|---|------|---------|---------|------------|
| 6 | **Pragma-Parser** (`@dal`, `@critical`, `@wcet`, `@stack_limit`) | 2.1, 10.1 | Hoch | Grundlage für alle safety-spezifischen Compiler-Features |
| 7 | **Range-Typen im Typsystem** | 2.2, 10.1 | Hoch | `type Altitude = int64 range -1000..60000` – Compile-Zeit und Runtime-Checks |
| 8 | **Call-Graph: Statischer Aufrufgraph** | 6.1 | Mittel | Erforderlich für WCET-Analyse und Stack-Berechnung über Call-Grenzen hinweg |
| 9 | **Map-File: Speicherlayout aller Symbole** | 6.1 | Mittel | Debug-Information für Zertifizierung und Audit |
| 10 | **Result-Typ mit Pattern-Matching** | 7.2, 10.1 | Mittel | Strukturierte Fehlerbehandlung ohne Exceptions (nicht deterministisch) |
| 11 | **MC/DC-Test-Suite für alle Backend-Pfade** | 10.4 | Mittel | Sicherstellen dass MC/DC-Instrumentierung in allen 7 Backends korrekt funktioniert |
| 12 | **TrustZone (Cortex-M33+)** | 3.2 | Hoch | Secure/Non-Secure Trennung – nur relevant wenn M33 Target aktiv genutzt wird |

### 🟡 P2 – Mittel (nice-to-have für DAL C)

| # | Task | Sektion | Aufwand | Begründung |
|---|------|---------|---------|------------|
| 13 | **Symbol-Table: DWARF Debug-Information** | 6.1 | Hoch | Debugger-Unterstützung, aber nicht zwingend für DO-178C erforderlich |
| 14 | **Objektcode-Diff: Byte-für-Byte-Vergleich** | 6.1 | Niedrig | Automatisierter Diff zwischen Builds – teilweise durch Determinismus-Tests abgedeckt |
| 15 | **MISRA-Regel: Keine rekursiven Funktionen** | 5.2 | Niedrig | Bereits durch Terminierungs-Analyse erkannt, muss nur als Fehler eskaliert werden |
| 16 | **MISRA-Regel: Keine Pointer-Arithmetik** | 5.2 | Niedrig | Sema-Checker Erweiterung |
| 17 | **MISRA-Regel: Switch-Cases vollständig** | 5.2 | Niedrig | Parser/Sema-Checker Erweiterung |
| 18 | **MISRA-Regel: Maximale Funktionslänge (60 Zeilen)** | 5.2 | Niedrig | Linter-Regel |
| 19 | **MISRA-Regel: Maximale Zyklomatische Komplexität (15)** | 5.2 | Mittel | IR-Pass zur Komplexitätsberechnung |
| 20 | **WCET-Schätzung als IR-Pass** | 10.2 | Hoch | Worst-Case Execution Time – benötigt @wcet Pragma und Call-Graph |
| 21 | **Stack-Nutzungs-Analyse über Call-Grenzen** | 10.2 | Mittel | Erweiterung der bestehenden Stack-Analyse |
| 22 | **Deterministische Register-Allokierung** | 10.3 | Mittel | Backend-Erweiterung für reproduzierbare Register-Zuweisung |
| 23 | **Fuzzing für Lexer/Parser** | 10.4 | Mittel | Erweiterung des bestehenden Fuzzing-Frameworks |
| 24 | **Mutation-Testing für Compiler** | 10.4 | Mittel | Erweiterung des bestehenden Mutation-Testing |

### 🟢 P3 – Niedrig (langfristig / formal)

| # | Task | Sektion | Aufwand | Begründung |
|---|------|---------|---------|------------|
| 25 | **Tool Verification (Bootstrapping)** | 1.1 | Hoch | Compiler kompiliert sich bereits selbst (Singularität), aber formaler Nachweis fehlt |
| 26 | **Configuration Management** | 1.1 | Niedrig | Git-basierte Versionierung existiert bereits, muss nur dokumentiert werden |
| 27 | **Quality Assurance: Review-Prozesse** | 1.1 | Niedrig | Prozess-Definition, keine Code-Änderung |
| 28 | **Formale Spezifikation (Coq/Isabelle)** | 1.2 | Sehr Hoch | CompCert-Ansatz – langfristiges Forschungsziel |
| 29 | **Proof of Correctness** | 1.2 | Sehr Hoch | AST → IR → Maschinencode Beweis – langfristiges Forschungsziel |
| 30 | **Bisimulation** | 1.2 | Sehr Hoch | Beweis dass generierter Code gleiche Semantik hat – langfristiges Forschungsziel |
| 31 | **Formal-verifizierte Testfälle (Coq)** | 10.4 | Sehr Hoch | Abhängig von formaler Spezifikation |
| 32 | **Dead-Code-Elimination (DAL D/C)** | 10.2 | Mittel | IR-Pass – nützlich aber nicht kritisch |
| 33 | **`unsafe`-Block-Semantik** | 10.1 | Mittel | Inline-Assembly nur in `unsafe` Blöcken |
| 34 | **Inline-Assembly-Sicherheit** | 6.2 | Mittel | Clobber-Liste, Analyse – abhängig von `unsafe`-Block |
| 35 | **verify() Builtin** | 7.1 | Niedrig | Formale Verifikation-Hinweis – benötigt Coq-Integration |
| 36 | **Assertion-Levels (@dal)** | 7.1 | Niedrig | Abhängig von Pragma-System |
| 37 | **Keine dynamische Speicherallokation nach Initialisierung** | 5.2 | Mittel | IR-Pass zur Erkennung von mmap/alloc nach main() |
| 38 | **Requirement-IDs im Source-Code** | 8.1, 10.1 | Niedrig | `@req("SWR-001")` Pragma – abhängig von Pragma-System |
| 39 | **Bidirektionale Traceability** | 8.1 | Mittel | Requirement ↔ Code ↔ Test – Tooling, kein Compiler-Feature |
| 40 | **Automatische Coverage-Reports** | 8.1 | Niedrig | Erweiterung des MC/DC-Reports |
| 41 | **Task-Deklarationen für Echtzeit-Systeme** | 2.3, 10.1 | Hoch | `task @period(10ms)` – RTOS-Integration, eigenes Feature-Set |
| 42 | **Concurrency-Modell (Shared Data, Deadlock, Priority-Inversion)** | 2.3 | Sehr Hoch | Vollständiges Concurrency-Modell – langfristiges Ziel |

---

## Fortschritt

| Kategorie | Erledigt | Offen | Fortschritt |
|-----------|----------|-------|-------------|
| **1. DO-178C Compliance** | 9 | 8 | 53% |
| **2. Spracherweiterungen** | 0 | 15 | 0% |
| **3. Backend-Sicherheit** | 14 | 1 | 93% |
| **4. Test-Abdeckung** | 8 | 0 | 100% |
| **5. Statische Analyse** | 7 | 8 | 47% |
| **6. Codegen-Sicherheit** | 0 | 9 | 0% |
| **7. Laufzeit-Sicherheit** | 0 | 7 | 0% |
| **8. Dokumentation** | 5 | 3 | 63% |
| **9. Build/CI** | 0 | 7 | 0% |
| **10. Implementierungs-Tasks** | 3 | 11 | 21% |
| **GESAMT** | **45** | **70** | **39%** |

---

## Empfohlene nächste Schritte (Priorität)

1. **MC/DC Lücken-Erkennung** (P0 #1) – Runtime-Coverage-Daten in den instrumentierten Binarys sammeln
2. **Assembly-Listing** (P0 #2) – Source-Zeilennummern in generierten Code einbetten
3. **assert()/check() Builtins** (P0 #3) – Runtime-Assertions für DAL A
4. **MISRA-Regeln** (P0 #4-5) – Sema-Checker Erweiterungen (geringer Aufwand, hoher Nutzen)
5. **Pragma-Parser** (P1 #6) – Grundlage für @dal, @critical, @wcet, @stack_limit

---

## Referenzen

- **DO-178C**: Software Considerations in Airborne Systems and Equipment Certification
- **DO-331**: Model-Based Development and Verification
- **DO-332**: Object-Oriented Technology and Related Techniques
- **DO-333**: Formal Methods Supplement to DO-178C and DO-278A
- **CompCert**: The CompCert C Verified Compiler (INRIA)
- **MISRA C:2023**: Guidelines for critical systems
- **ARINC 653**: Avionics Application Software Standard Interface
