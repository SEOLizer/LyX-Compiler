# Tool Operational Requirements (TOR) – Lyx Compiler

## Dokument-Informationen

| Feld | Wert |
|------|------|
| **Dokument** | TOR-LYX-001 |
| **Version** | 0.1.0 |
| **Datum** | 2026-04-03 |
| **Status** | Entwurf |
| **Tool** | Lyx Compiler (lyxc) |
| **TQL** | TQL-5 (DO-178C Section 12.2) |
| **DAL** | A/B/C (alle Levels abgedeckt) |

---

## 1. Zweck

Dieses Dokument definiert die **Tool Operational Requirements (TOR)** für den Lyx Compiler.
Es beschreibt, welche Funktionen der Compiler bereitstellen muss, um als qualifiziertes
Development Tool gemäß **DO-178C TQL-5** eingesetzt werden zu können.

---

## 2. Tool-Identifikation

### TOR-001: Tool-Versionierung

| Feld | Wert |
|------|------|
| **ID** | TOR-001 |
| **Priorität** | Kritisch |
| **Beschreibung** | Der Compiler muss eine eindeutige Versionsnummer ausgeben |
| **Verifikation** | `lyxc --version` gibt MAJOR.MINOR.PATCH aus |
| **Akzeptanzkriterium** | Ausgabe entspricht SemVer 2.0 |

### TOR-002: Build-Identifikation

| Feld | Wert |
|------|------|
| **ID** | TOR-002 |
| **Priorität** | Kritisch |
| **Beschreibung** | Jeder Build muss einen eindeutigen Hash enthalten |
| **Verifikation** | `lyxc --build-info` gibt Git-Commit-Hash, Build-Datum, Host-OS aus |
| **Akzeptanzkriterium** | Hash ist reproduzierbar und eindeutig |

### TOR-003: Konfigurations-Status

| Feld | Wert |
|------|------|
| **ID** | TOR-003 |
| **Priorität** | Kritisch |
| **Beschreibung** | Der Compiler muss seine aktive Konfiguration ausgeben |
| **Verifikation** | `lyxc --config` zeigt Target-Architektur, Optimierungslevel, aktivierte Features |
| **Akzeptanzkriterium** | Alle Konfigurationsparameter sind dokumentiert |

---

## 3. Funktionale Anforderungen

### 3.1 Code-Generierung

#### TOR-010: Deterministische Code-Generierung

| Feld | Wert |
|------|------|
| **ID** | TOR-010 |
| **Priorität** | Kritisch |
| **Beschreibung** | Gleicher Source-Input + gleiche Konfiguration → identischer Output (Byte-für-Byte) |
| **Verifikation** | Zwei Builds desselben Source mit gleichem Config → `diff` der Binaries zeigt keine Unterschiede |
| **Akzeptanzkriterium** | SHA-256 der Output-Dateien ist identisch |

#### TOR-011: Vollständige IR-Abdeckung

| Feld | Wert |
|------|------|
| **ID** | TOR-011 |
| **Priorität** | Kritisch |
| **Beschreibung** | Jede IR-Operation muss in jedem unterstützten Backend implementiert sein |
| **Verifikation** | Test-Suite deckt alle IR-Operationen für alle Targets ab |
| **Akzeptanzkriterium** | 100% IR-Abdeckung in Tests |

#### TOR-012: Fehlermeldungen mit Source-Position

| Feld | Wert |
|------|------|
| **ID** | TOR-012 |
| **Priorität** | Kritisch |
| **Beschreibung** | Jeder Compiler-Fehler muss Datei, Zeile und Spalte enthalten |
| **Verifikation** | Test mit fehlerhaftem Source → Fehlermeldung enthält Position |
| **Akzeptanzkriterium** | Format: `datei.lyx:zeile:spalte: Fehler: Beschreibung` |

### 3.2 Semantische Analyse

#### TOR-020: Typsicherheit

| Feld | Wert |
|------|------|
| **ID** | TOR-020 |
| **Priorität** | Kritisch |
| **Beschreibung** | Keine Typfehler dürfen unbemerkt passieren |
| **Verifikation** | Typfehler-Testfälle → Compiler-Fehler |
| **Akzeptanzkriterium** | 0 false negatives bei Typfehlern |

#### TOR-021: Null-Safety

| Feld | Wert |
|------|------|
| **ID** | TOR-021 |
| **Priorität** | Kritisch |
| **Beschreibung** | Nullable-Typen (`T?`) müssen explizit sein |
| **Verifikation** | Null-Zuweisung an non-nullable → Compiler-Fehler |
| **Akzeptanzkriterium** | Keine impliziten Null-Konvertierungen |

#### TOR-022: Range-Checks

| Feld | Wert |
|------|------|
| **ID** | TOR-022 |
| **Priorität** | Hoch |
| **Beschreibung** | Range-Überschreitungen müssen zur Compile-Zeit erkannt werden |
| **Verifikation** | `let x: int8 range 0..100 = 200` → Compiler-Fehler |
| **Akzeptanzkriterium** | Statische Range-Verletzungen werden erkannt |

### 3.3 Backend-Sicherheit

#### TOR-030: Stack-Überlauf-Erkennung

| Feld | Wert |
|------|------|
| **ID** | TOR-030 |
| **Priorität** | Kritisch |
| **Beschreibung** | Compiler warnt bei möglicher Stack-Übernutzung |
| **Verifikation** | Funktion mit großer Stack-Nutzung → Warnung |
| **Akzeptanzkriterium** | Stack-Usage-Berechnung ist konservativ (überschätzt, nicht unterschätzt) |

#### TOR-031: ABI-Konformität

| Feld | Wert |
|------|------|
| **ID** | TOR-031 |
| **Priorität** | Kritisch |
| **Beschreibung** | Generierter Code muss der Target-ABI entsprechen |
| **Verifikation** | ABI-Compliance-Tests für jedes Target |
| **Akzeptanzkriterium** | 100% ABI-Compliance in Tests |

---

## 4. Nicht-funktionale Anforderungen

### TOR-040: Reproduzierbarkeit

| Feld | Wert |
|------|------|
| **ID** | TOR-040 |
| **Priorität** | Kritisch |
| **Beschreibung** | Builds müssen auf verschiedenen Host-Systemen reproduzierbar sein |
| **Verifikation** | Build auf Host A und Host B → gleiche Binaries |
| **Akzeptanzkriterium** | SHA-256 identisch über mindestens 2 Host-Systeme |

### TOR-041: Keine versteckten Abhängigkeiten

| Feld | Wert |
|------|------|
| **ID** | TOR-041 |
| **Priorität** | Kritisch |
| **Beschreibung** | Compiler darf keine versteckten Abhängigkeiten (libc, etc.) haben |
| **Verifikation** | Strace/Dependency-Check zeigt nur erwartete Abhängigkeiten |
| **Akzeptanzkriterium** | Keine impliziten Runtime-Abhängigkeiten |

### TOR-042: Deterministische Optimierung

| Feld | Wert |
|------|------|
| **ID** | TOR-042 |
| **Priorität** | Kritisch |
| **Beschreibung** | Optimierungen müssen deterministisch sein (keine Hash-Orderings) |
| **Verifikation** | Mehrere Builds mit -O2 → gleiche Binaries |
| **Akzeptanzkriterium** | Keine nicht-deterministischen Datenstrukturen im Optimizer |

---

## 5. Test-Anforderungen

### TOR-050: Unit-Test-Abdeckung

| Feld | Wert |
|------|------|
| **ID** | TOR-050 |
| **Priorität** | Kritisch |
| **Beschreibung** | Mindestens 90% Code-Coverage im Compiler |
| **Verifikation** | Coverage-Report nach Testlauf |
| **Akzeptanzkriterium** | ≥ 90% Statement-Coverage |

### TOR-051: Integrationstests

| Feld | Wert |
|------|------|
| **ID** | TOR-051 |
| **Priorität** | Kritisch |
| **Beschreibung** | End-to-End-Tests für jede Target-Architektur |
| **Verifikation** | Test-Programme kompilieren und auf Target ausführen |
| **Akzeptanzkriterium** | Alle Integrationstests bestehen |

### TOR-052: Regressionstests

| Feld | Wert |
|------|------|
| **ID** | TOR-052 |
| **Priorität** | Kritisch |
| **Beschreibung** | Jeder Bug-Fix erhält einen Regressionstest |
| **Verifikation** | Regressionstest-Suite läuft bei jedem Commit |
| **Akzeptanzkriterium** | 0 Regressionen in der Test-Suite |

---

## 6. Dokumentations-Anforderungen

### TOR-060: Sprachspezifikation

| Feld | Wert |
|------|------|
| **ID** | TOR-060 |
| **Priorität** | Kritisch |
| **Beschreibung** | Vollständige formale Spezifikation der Lyx-Sprache |
| **Verifikation** | SPEC.md und ebnf.md sind aktuell und vollständig |
| **Akzeptanzkriterium** | Jedes Sprachkonstrukt ist spezifiziert |

### TOR-061: Benutzerhandbuch

| Feld | Wert |
|------|------|
| **ID** | TOR-061 |
| **Priorität** | Hoch |
| **Beschreibung** | Dokumentation aller Compiler-Optionen und Features |
| **Verifikation** | `lyxc --help` und Handbuch sind konsistent |
| **Akzeptanzkriterium** | Alle Optionen dokumentiert |

### TOR-062: Änderungsprotokoll

| Feld | Wert |
|------|------|
| **ID** | TOR-062 |
| **Priorität** | Kritisch |
| **Beschreibung** | Jede Änderung muss dokumentiert und nachverfolgbar sein |
| **Verifikation** | Git-History mit konventionellen Commit-Messages |
| **Akzeptanzkriterium** | Jede Änderung hat eine beschreibende Commit-Message |

---

## 7. Traceability-Matrix

| TOR-ID | Implementierung | Test | Status |
|--------|----------------|------|--------|
| TOR-001 | `lyxc --version` | `test_tool_version.pas` | ❌ |
| TOR-002 | `lyxc --build-info` | `test_build_info.pas` | ❌ |
| TOR-003 | `lyxc --config` | `test_config.pas` | ❌ |
| TOR-010 | Deterministischer Codegen | `test_determinism.pas` | ❌ |
| TOR-011 | Vollständige IR-Abdeckung | `test_ir_coverage.pas` | ❌ |
| TOR-012 | Fehlermeldungen mit Position | `test_error_positions.pas` | ✅ |
| TOR-020 | Typsicherheit | `test_type_safety.pas` | ✅ |
| TOR-021 | Null-Safety | `test_null_safety.pas` | ✅ |
| TOR-022 | Range-Checks | `test_range_checks.pas` | ❌ |
| TOR-030 | Stack-Überlauf-Erkennung | `test_stack_usage.pas` | ❌ |
| TOR-031 | ABI-Konformität | `test_abi_compliance.pas` | ✅ |
| TOR-040 | Reproduzierbarkeit | `test_reproducible.pas` | ❌ |
| TOR-041 | Keine versteckten Abhängigkeiten | `test_dependencies.pas` | ❌ |
| TOR-042 | Deterministische Optimierung | `test_deterministic_opt.pas` | ❌ |
| TOR-050 | Unit-Test-Abdeckung | Coverage-Report | ❌ |
| TOR-051 | Integrationstests | `tests/lyx/` | ✅ |
| TOR-052 | Regressionstests | `make test` | ✅ |
| TOR-060 | Sprachspezifikation | SPEC.md, ebnf.md | ✅ |
| TOR-061 | Benutzerhandbuch | `lyxc --help` | ❌ |
| TOR-062 | Änderungsprotokoll | Git-History | ✅ |

---

## 8. Glossar

| Begriff | Definition |
|---------|------------|
| **DO-178C** | Software Considerations in Airborne Systems and Equipment Certification |
| **TQL-5** | Tool Qualification Level 5 – Tool kann Fehler in Zielcode einführen |
| **DAL** | Design Assurance Level (A = kritischste, D = am wenigsten kritisch) |
| **TOR** | Tool Operational Requirements |
| **MC/DC** | Modified Condition/Decision Coverage |
| **ABI** | Application Binary Interface |
| **IR** | Intermediate Representation |
