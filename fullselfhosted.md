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

## 📋 Offene TODOs

Nachfolgende Features sind noch nicht im Bootstrap-Compiler implementiert:

### Priorität 1 (CLI-Parität — Leicht)

| # | Feature | Beschreibung | Aufwand |
|---|---------|--------------|---------|
| 1 | `--no-opt` | IR-Optimierungen deaktivieren | 1 Tag |
| 2 | `--lint-only` | Nur linten, nicht kompilieren | 1 Tag |
| 3 | `--no-lint` | Linter deaktivieren (explizit) | 1 Tag |
| 4 | `--std-path=PATH` | Stdlib-Pfad überschreiben | 1 Tag |
| 5 | `--arch=ARCH` | Architektur-Override | 2 Tage |

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

### Gesamt: ~40-50 Tage

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

*Zuletzt aktualisiert: 2026-04-06*
