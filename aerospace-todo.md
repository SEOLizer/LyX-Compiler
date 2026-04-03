# Aerospace TODO – Lyx als Safety-Critical Compiler

## Überblick

Dieses Dokument beschreibt die notwendigen Erweiterungen und Sicherungsmaßnahmen,
um **Lyx** als Compiler für **safety-critical Aerospace-Software** (DO-178C DAL A/B/C)
qualifizieren zu können.

Ziel: Lyx generiert **deterministischen, verifizierbaren, tracebaren Maschinencode**
für eingebettete Systeme (ESP32, ARM Cortex-M, RISC-V), der den Anforderungen der
Luftfahrtstandards genügt.

---

## 1. DO-178C Software Compliance

### 1.1 Tool Qualification (TQL-5)

Der Compiler selbst muss als **Development Tool** qualifiziert werden.

- [x] **TQL-5 Einstufung**: Lyx als TQL-5 Tool (kann Fehler in Zielcode einführen)
- [x] **Tool Operational Requirements (TOR)**: Spezifikation der Compiler-Funktionen → `tor_lyx.md`
- [x] **Tool Validation**: Nachweis, dass Lyx die TOR erfüllt → `test_tor_validation.pas` (23/23 Tests)
- [ ] **Tool Verification**: Verifikation des Compilers selbst (Bootstrapping + Tests)
- [ ] **Configuration Management**: Versionierung aller Compiler-Komponenten
- [ ] **Quality Assurance**: Unabhängige Review-Prozesse für Compiler-Änderungen

### 1.2 Compiler-Verifikation

- [ ] **Formale Spezifikation** der Lyx-Semantik (Coq/Isabelle)
- [ ] **Proof of Correctness**: AST → IR → Maschinencode Transformation beweisen
- [ ] **CompCert-Ansatz**: Jede IR-Transformationsstufe formal verifizieren
- [x] **Reference Interpreter**: Lyx-Programm-Semantik als Referenz-Implementierung → `test_reference_interpreter.pas` (22/22 Tests)
- [ ] **Bisimulation**: Beweis, dass generierter Code die gleiche Semantik hat

### 1.3 Deterministischer Codegen

- [x] **Keine nicht-deterministischen Optimierungen**: Keine Hash-basierten Orderings
- [x] **Reproduzierbare Builds**: Gleicher Input → immer gleicher Output (Byte-für-Byte) → `test_determinism.pas` (18/18 Tests)
- [x] **Keine zeitabhängigen Entscheidungen**: Kein Timestamp, keine Random-Werte im Codegen
- [x] **Feste Register-Allokierung**: Deterministische Register-Zuweisung
- [x] **Feste Stack-Layout-Berechnung**: Vorhersagbare Stack-Nutzung

---

## 2. Lyx-Spracherweiterungen für Aerospace

### 2.1 Pragma-System

```lyx
@dal("A")           // Design Assurance Level
@critical           // Kritische Funktion – keine Optimierungen
@no_inline          // Funktion nicht inlinen
@stack_limit(256)   // Maximale Stack-Nutzung in Bytes
@wcet(100)          // Worst-Case Execution Time in µs
@pure               // Keine Seiteneffekte (für formale Verifikation)
@total              // Totale Funktion (immer terminierend)
```

- [ ] Pragma-Parser im Lexer implementieren
- [ ] Pragma-Semantik im Sema-Checker validieren
- [ ] Pragma-Information an IR und Backend weiterreichen
- [ ] @wcet: Statische WCET-Analyse im Backend
- [ ] @stack_limit: Stack-Nutzungs-Analyse und Warnung bei Überschreitung

### 2.2 Typ-Erweiterungen

```lyx
// Range-basierte Typen für statische Analyse
type Altitude = int64 range -1000..60000;
type Heading = int32 range 0..360;
type Voltage = f64 range 0.0..32.0;

// Nicht-Null-Typen
type SensorData = array[8] of u8 not_null;

// Zeit-Typen
type Timestamp = uint64;  // Nanosekunden seit Epoch
type Duration = uint64;   // Nanosekunden
```

- [ ] Range-Typen im Typsystem implementieren
- [ ] Range-Checks zur Compile-Zeit (wenn möglich)
- [ ] Range-Checks zur Laufzeit (als Assertions)
- [ ] Nicht-Null-Typen für Pointer
- [ ] Überlauf-Erkennung für arithmetische Operationen

### 2.3 Concurrency-Modell

```lyx
// Periodische Tasks
task @period(10ms) @priority(1) flight_control() { ... }
task @period(100ms) @priority(2) sensor_read() { ... }
task @event(nav_data) @priority(3) nav_update() { ... }

// Shared Data mit Protection
shared var altitude: Altitude protected by mutex;
```

- [ ] Task-Deklaration im Parser
- [ ] Scheduling-Information an Backend (für RTOS-Integration)
- [ ] Shared-Data-Protection mit Mutex/Semaphore
- [ ] Deadlock-Erkennung zur Compile-Zeit
- [ ] Priority-Inversion-Analyse

---

## 3. Backend-Sicherheit

### 3.1 ESP32 / Xtensa

- [x] **Watchdog-Integration**: Automatischer Watchdog-Reset im Entry-Code → `watchdog_init()`, `watchdog_feed()`, `wdt_reset()` + Init im `_start`
- [x] **Brownout-Detection**: Spannungseinbruch-Erkennung → `brownout_check()`, `brownout_config()` + Init im `_start` (2.8V Default)
- [x] **Flash-Sicherheit**: Code-Integritätsprüfung beim Laden → `flash_verify()` (CRC32), `secure_boot()`
- [x] **Secure Boot**: Signierte Firmware-Verifikation → `secure_boot()` builtin
- [x] **Memory Protection Unit (MPU)**: Stack/Heap-Trennung → `mpu_config(region, addr, size, access)`, 5 Regionen definiert
- [x] **Cache-Kohärenz**: Explizite Cache-Flushes für DMA → `cache_flush()` builtin

### 3.2 ARM Cortex-M

- [x] **MPU-Konfiguration**: Automatische MPU-Setup-Generierung → `mpu_config(region, addr, size, ap)`, `mpu_enable()`, 8 Regionen, AP-Bits, Memory Types
- [x] **Fault-Handler**: HardFault, MemManage, BusFault Handler → Vector Table, CFSR/HFSR/DFSR, MMFAR/BFAR, `get_fault_status()`, `get_fault_address()`, `clear_fault_status()`
- [x] **Stack-Canary**: Stack-Overflow-Erkennung → `stack_canary_check()`, 3 Canaries (top/middle/bottom), $DEADBEEF pattern
- [x] **Privileged/Unprivileged Mode**: Trennung von kritischem und nicht-kritischem Code → `set_unprivileged()`, `set_privileged()`, CONTROL register
- [ ] **TrustZone**: Secure/Non-Secure Trennung (für Cortex-M33+) → `tz_init()`, `tz_enter_nonsecure()`, `tz_sau_config()` (Stubs)

### 3.3 RISC-V

- [x] **PMP (Physical Memory Protection)**: Automatische PMP-Konfiguration → `pmp_config(region, addr, size, cfg)`, `pmp_lock(region)`, 16 Regionen, NAPOT/NA4/TOR Modes
- [x] **Machine Mode**: Nur M-Mode für kritischen Code → `mret()`, `sret()`, `get_mhartid()`, `get_mcycle()`, CSR-Zugriff via `csr_read/write/set/clear()`
- [x] **Ecall/Ebreak**: System-Call-Interface für RTOS → `ecall_syscall(num)`, `ebreak()`, `wfi()`, `fence()`, `fence_i()`
- [x] **Atomic Operations**: LR/SC für Lock-free Datenstrukturen → RV64A Extension im Emitter integriert (LR/SC-Instruktionen verfügbar)

---

## 4. Test-Abdeckung (MC/DC)

### 4.1 Modified Condition/Decision Coverage

DO-178C DAL A erfordert **MC/DC** für alle Entscheidungen.

- [x] **MC/DC-Instrumentierung**: Compiler generiert Coverage-Points → `ir_mcdc.pas` Pass, `--mcdc` CLI-Flag, `__mcdc_record` Builtin in allen 7 Backends
- [x] **Coverage-Tracking**: Jeder Condition-Zweig wird gezählt → `TMCDCDecision` mit HitCount, ConditionResults, DecisionResult
- [x] **MC/DC-Bericht**: Automatischer Report nach Testlauf → `GenerateReport()` mit `--mcdc-report` Flag
- [ ] **Lücken-Erkennung**: Nicht abgedeckte Pfade markieren

```lyx
// Generierte Instrumentierung (intern)
if (a && b) {
  // MC/DC: a=T,b=T → entry
  __mc_dc_record(DECISION_1, a, b, true);
  ...
}
```

### 4.2 Test-Generierung

- [x] **Symbolic Execution**: Automatische Testfall-Generierung → `test_generation.pas`: 15 Pfade durch if/else-Bäume, symbolische Variablen, Path-Condition-Tracking
- [x] **Boundary-Value-Analyse**: Tests für Grenzwerte von Range-Typen → int64 (±1, int8/16/32), Strings (empty, long, escapes), Arrays (empty, 1000, OOB), Functions (0-6 params, recursion)
- [x] **Mutation Testing**: Code-Mutationen zur Test-Qualitätsmessung → Operator-Ersetzung, Condition-Negation, Constant-Change (33% Mutation Score)
- [x] **Fuzzing**: Random-Input-Tests für Parser und Sema → 50 zufällige Lyx-Programme, 0 Crashes, 50 unique inputs

---

## 5. Statische Analyse

### 5.1 Compiler-interne Analysen

- [x] **Data-Flow-Analyse**: Def-Use-Ketten für alle Variablen → `ir_static_analysis.pas`: Def-Use-Chains mit Use-Location-Tracking
- [x] **Live-Variable-Analyse**: Unbenutzte Variablen erkennen → `--static-analysis` CLI-Flag, Warnung für unused vars
- [x] **Constant-Propagation**: Konstanten-Faltung für Range-Checks → irConstInt/irAdd/irSub/irMul propagation, 5/10 Konstanten erkannt
- [x] **Null-Pointer-Analyse**: Potenzielle Null-Dereferenzierungen → ConstStr-Tracking, Null-Check-Erkennung
- [x] **Array-Bounds-Analyse**: Statische Index-Prüfung → irLoadElem/irStoreElem Tracking, SAFE/UNVERIFIED Status
- [x] **Terminierungs-Analyse**: Endlosschleifen-Erkennung (für @total) → Loop-Erkennung via irJmp/irBrTrue/irBrFalse, Bounded-Loop-Erkennung
- [x] **Stack-Nutzungs-Analyse**: Worst-Case-Stack-Berechnung → Slot-Count, Byte-Berechnung, Rekursions-Erkennung

### 5.2 MISRA-ähnliche Regeln

- [ ] **Keine impliziten Typkonvertierungen** (außer safe widening)
- [ ] **Keine rekursiven Funktionen** (für Stack-Vorhersagbarkeit)
- [ ] **Keine dynamische Speicherallokation** nach Initialisierung
- [ ] **Keine Pointer-Arithmetik** (außer Array-Zugriff)
- [ ] **Alle Switch-Cases müssen vollständig sein**
- [ ] **Keine unbenutzten Variablen oder Parameter**
- [ ] **Maximale Funktionslänge** (z.B. 60 Zeilen)
- [ ] **Maximale Zyklomatische Komplexität** (z.B. 15)

---

## 6. Code-Generierung-Sicherheit

### 6.1 Verifizierbarer Output

- [ ] **Assembly-Listing**: Generierter Code mit Source-Zeilennummern
- [ ] **Objektcode-Diff**: Byte-für-Byte-Vergleich zwischen Builds
- [ ] **Symbol-Table**: Vollständige Debug-Information (DWARF)
- [ ] **Map-File**: Speicherlayout aller Symbole
- [ ] **Call-Graph**: Statischer Aufrufgraph aller Funktionen

### 6.2 Inline-Assembly-Sicherheit

```lyx
// Nur in @unsafe Blöcken erlaubt
unsafe {
  asm volatile("wfi");
}
```

- [ ] Inline-Assembly nur mit `unsafe`-Block
- [ ] Clobber-Liste muss vollständig sein
- [ ] Inline-Assembly darf keine @critical Funktionen verlassen
- [ ] Statische Analyse der Assembly-Semantik (soweit möglich)

---

## 7. Laufzeit-Sicherheit

### 7.1 Assertions und Checks

```lyx
@critical
fn calculate_altitude(sensor: Sensor) -> Altitude {
  assert(sensor.valid, "Sensor data invalid");
  assert(sensor.altitude >= -1000 && sensor.altitude <= 60000,
         "Altitude out of range");
  
  let result = sensor.altitude * calibration_factor;
  check(result >= -1000 && result <= 60000);  // Runtime check
  return result as Altitude;
}
```

- [ ] `assert()`: Compile-Zeit und Laufzeit-Assertions
- [ ] `check()`: Nur Laufzeit-Checks (kann in DAL D deaktiviert werden)
- [ ] `verify()`: Formale Verifikation-Hinweis (für Beweiser)
- [ ] Assertion-Levels: @dal("A") = alle aktiv, @dal("C") = nur assert

### 7.2 Error Handling

```lyx
// Result-Typ für fehleranfällige Operationen
type Result<T, E> = struct {
  value: T?;
  error: E?;
}

fn read_sensor() -> Result<SensorData, SensorError> {
  // ...
}
```

- [ ] Result-Typ mit Pattern-Matching
- [ ] Keine Exceptions (nicht deterministisch)
- [ ] Alle Fehler müssen behandelt werden (Compiler-Warnung sonst)
- [ ] Error-Propagation mit `?`-Operator

---

## 8. Dokumentation und Traceability

### 8.1 Anforderungs-Traceability

- [ ] **Requirement-IDs** im Source-Code verankern
- [ ] **Bidirektionale Traceability**: Requirement ↔ Code ↔ Test
- [ ] **Automatische Reports**: Coverage-Matrizen für Zertifizierung

```lyx
@req("SWR-001", "SWR-002")
fn flight_control_loop() {
  // Implementiert Anforderung SWR-001 und SWR-002
}
```

### 8.2 Compiler-Dokumentation

- [x] **Compiler Manual**: Vollständige Sprachspezifikation → `COMPILER_MANUAL.md` (700+ Zeilen, Typen, Builtins, CLI, Safety, Stdlib, Version History, Known Issues)
- [x] **User Guide**: Bedienung des Compilers → `USER_GUIDE.md` (Getting Started, Language Basics, Stdlib, Safety, Advanced Topics, Troubleshooting)
- [x] **Verification Report**: Nachweis der Compiler-Korrektheit → `VERIFICATION_REPORT.md` (111/111 Tests, TOR, Reference Interpreter, Determinism, MC/DC, Static Analysis, Test Generation)
- [x] **Change Log**: Vollständige Historie aller Änderungen → `CHANGELOG.md` aktualisiert mit v0.7.0-aerospace Eintrag
- [x] **Problem Reports**: Bekannte Issues und Workarounds → `COMPILER_MANUAL.md` Section 9 (ESP32, ARM Cortex-M, RISC-V, General issues)

---

## 9. Build-System und CI/CD

### 9.1 Reproduzierbare Builds

- [ ] **Deterministische Builds**: Gleicher Input → gleicher Output
- [ ] **Build-Artefakte**: Alle Intermediate-Files speichern
- [ ] **Hash-Verification**: SHA-256 aller Output-Dateien
- [ ] **Cross-Compilation**: Host-unabhängige Builds

### 9.2 Continuous Integration

- [ ] **Regressionstests**: Alle Tests bei jedem Commit
- [ ] **MC/DC-Coverage**: Automatische Coverage-Berichte
- [ ] **Static Analysis**: Alle Analysen bei jedem Build
- [ ] **Formal Verification**: Coq/Isabelle-Beweise bei Änderungen
- [ ] **Binary Diff**: Byte-für-Byte-Vergleich mit Referenz-Build

---

## 10. Spezifische Lyx-Implementierungs-Tasks

### 10.1 Frontend

- [ ] Pragma-Parser (`@dal`, `@critical`, `@wcet`, etc.)
- [ ] Range-Typen im Typsystem
- [ ] `unsafe`-Block-Semantik
- [ ] `assert`/`check`/`verify` als Builtins
- [ ] Result-Typ mit Pattern-Matching
- [ ] Requirement-Annotationen (`@req`)
- [ ] Task-Deklarationen für Echtzeit-Systeme

### 10.2 IR

- [ ] MC/DC-Instrumentierung als IR-Pass
- [ ] Data-Flow-Analyse-Pass
- [ ] Stack-Nutzungs-Analyse-Pass
- [ ] WCET-Schätzung als IR-Pass
- [ ] Dead-Code-Elimination (nur für DAL D/C)

### 10.3 Backend

- [x] Watchdog-Integration (ESP32 ✅, ARM, RISC-V)
- [x] MPU/PMP-Konfigurations-Generierung (ESP32 ✅)
- [ ] Fault-Handler-Generierung
- [x] Stack-Canary-Insertion (ESP32 ✅)
- [ ] Assembly-Listing mit Source-Annotation
- [ ] Deterministische Register-Allokierung

### 10.4 Tests

- [ ] MC/DC-Test-Suite für alle Backend-Pfade
- [ ] Mutation-Testing für Compiler
- [ ] Fuzzing für Lexer/Parser
- [ ] Formal-verifizierte Testfälle (Coq)

---

## Priorisierung

| Phase | Tasks | Ziel |
|-------|-------|------|
| **Phase 1** | Pragma-System, Range-Typen, Assertions | Sprachbasis |
| **Phase 2** | Statische Analyse, MISRA-Regeln | Code-Qualität |
| **Phase 3** | MC/DC-Instrumentierung, Coverage | Test-Abdeckung |
| **Phase 4** | Deterministischer Codegen, Repro-Builds | Verifizierbarkeit |
| **Phase 5** | Formale Spezifikation (Coq) | Korrektheitsbeweis |
| **Phase 6** | Tool Qualification Package | DO-178C Zertifizierung |

---

## Referenzen

- **DO-178C**: Software Considerations in Airborne Systems and Equipment Certification
- **DO-331**: Model-Based Development and Verification (Supplement to DO-178C)
- **DO-332**: Object-Oriented Technology and Related Techniques
- **DO-333**: Formal Methods Supplement to DO-178C and DO-278A
- **CompCert**: The CompCert C Verified Compiler (INRIA)
- **MISRA C:2023**: Guidelines for the use of the C language in critical systems
- **ARINC 653**: Avionics Application Software Standard Interface
- **AUTOSAR**: Automotive Software Architecture (ähnliche Anforderungen)
