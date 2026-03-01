# Todo: Plattform-Unterstützung für Lyx

## Zusammenfassung der aktuellen Unterstützung

| Plattform | Status | Anmerkungen |
|-----------|--------|-------------|
| **x86_64 Linux** | ⚠️ Teilweise | Statisch vollständig, Dynamic Linking: Emitter ✅, Writer ⚠️ (Segfault bei Ausführung) |
| **x86_64 Windows** | ✅ Vollständig | PE32+, kernel32.dll Imports, Windows API |
| **ARM64 Linux** | ⚠️ Teilweise | Statisch vollständig, Dynamic Linking: Emitter ✅, Writer 🔲 |
| **ARM64 Windows** | ❌ Fehlt | Kein PE64 ARM64 Writer |
| **macOS** | ❌ Fehlt | Kein Mach-O Writer |
| **Energy-Aware** | ⚠️ Teilweise | Architektur bereinigt ✅, x86_64-Tracking ⚠️ (Stats noch 0), ARM64 minimal ✅, Tests ❌ |

---

## Bereits implementiert

### x86_64 Linux (ELF64)
- Statische ELF64-Dateien
- **⚠️ Dynamic Linking (PLT/GOT)**: Emitter und Writer implementiert, aber Segfault bei Ausführung - Debugging nötig
- Alle IR-Operationen: Integer, Float, Strings, Arrays, Structs, Klassen
- Heap-Allokation (mmap/munmap)
- Random Builtin
- Alle Syscalls (read, write, open, close, etc.)

### x86_64 Windows (PE32+)
- PE64-Format mit Import Table
- kernel32.dll Imports: GetStdHandle, WriteFile, ExitProcess, VirtualAlloc
- Windows API: CreateFileA, ReadFile, WriteFile, CloseHandle, SetFilePointer, DeleteFileA, MoveFileA, CreateDirectoryA, RemoveDirectoryA, SetFileAttributesA
- Builtins: PrintStr, PrintInt, exit, Random, RandomSeed
- String- und Global-Variable-Support
- Floating Point (SSE2)

### ARM64 Linux (ELF64) - Status aktualisiert
- Vollständiger ARM64 Instruction Encoder (AArch64)
  - MOVZ, MOVK, LDR, STR, ADD, SUB, MUL, DIV, MOD
  - Branch: B, BL, CBZ, CBNZ, B.cond
  - Compare: CMP, CSET
  - Floating Point: FMOV, FADD, FSUB, FMUL, FDIV, FCMP, FCVTZS, SCVTF
- Builtins: PrintStr (mit strlen), PrintInt (itoa), Random, RandomSeed
- **⚠️ Dynamic Linking (PLT/GOT): Emitter-Seite implementiert, Writer fehlt noch**
- Globale Variablen
- PC-relative Adressierung (ADR, ADRP)

---

## Todo: Was noch zu tun ist

### Priorität 1: Dynamic Linking Debugging (x86_64 & ARM64)

**Beschreibung**: Beide Dynamic Linking Implementierungen haben Probleme. x86_64 hat einen Segfault bei Ausführung, ARM64 ist noch nicht vollständig implementiert.

**x86_64 Debugging**:
- [ ] Segfault bei Ausführung debuggen
- [ ] PLT/GOT-Relocations überprüfen
- [ ] Dynamic Linker Integration testen

**ARM64 Implementierung**:
- [ ] ARM64 Dynamic Linking Writer implementieren (siehe x86_64 als Referenz)
- [ ] PT_DYNAMIC Program Header
- [ ] .rela.plt / .rela.dyn Sektionen
- [ ] Testen mit QEMU

**Schätzung**: 2-3 Tage

---

### Priorität 2: Windows ARM64 Support

**Beschreibung**: PE32+ Dateien für Windows auf ARM64 (Windows on ARM).

**Aufgaben**:
1. [ ] Neuer PE64 ARM64 Writer (`pe64_arm64_writer.pas`)
   - ARM64 Machine Type: IMAGE_FILE_MACHINE_ARM64 ($AA64)
   - ARM64 Instruction Encoding (bereits in `arm64_emit.pas` vorhanden)
2. [ ] Windows API Adapter für ARM64
   - Universal Windows Platform (UWP) APIs oder
   - winevt.dll, kernel32.dll (ARM64 Varianten)
3. [ ] Windows ARM64 Syscall-Nummern (statt x64)
4. [ ] Testen auf Windows ARM64 Hardware oder QEMU

**Schätzung**: 3-5 Tage

---

### Priorität 3: macOS Support

**Beschreibung**: Mach-O Format für macOS auf x86_64 und ARM64 (Apple Silicon).

**Aufgaben**:
1. [ ] Mach-O Writer (`macho64_writer.pas` für x86_64, `macho64_arm64_writer.pas` für ARM64)
   - Mach-O Header (64-bit)
   - Load Commands
   - Code/Data Segments (LC_SEGMENT_64)
   - Entry Point (LC_MAIN oder LC_UNIXTHREAD)
2. [ ] macOS Syscalls (BSD APIs)
   - write, read, exit statt Linux syscalls
3. [ ] dyld Integration (Dynamic Linking)
   - Symbol Stubs / Lazy Symbol Pointers
4. [ ] ABI: macOS Calling Convention (ähnlich SysV, aber andere Register)
5. [ ] Testing auf macOS oder Cross-Compilation

**Schätzung**: 5-7 Tage

---

### Priorität 4: Energy-Aware-Compiling vervollständigen

**Beschreibung**: Energy-Aware-Compiling ist begonnen, aber nicht durchgängig integriert. Ziel ist es, dem Compiler zu ermöglichen, energieeffizienten Maschinencode zu erzeugen — gesteuert über `--target-energy=<1-5>` und optional über Sprach-Pragmas.

#### Aktueller Stand

| Komponente | Status | Details |
|------------|--------|---------|
| **Basis-Typen** (`backend_types.pas`) | ✅ | Nur Enums: `TEnergyLevel`, `TCPUFamily` (bereinigt) |
| **CPU-Energiemodell** (`energy_model.pas`) | ✅ | Single Source of Truth — 3 CPU-Profile, alle Typen und Config-Funktionen |
| **x86_64-Backend** (`x86_64_emit.pas`) | ✅ | Energy-Felder, `GetEnergyStats`, `SetEnergyLevel`, Tracking aktiv |
| **CLI-Flag** (`lyxc.lpr`) | ✅ | `--target-energy=<1-5>`, zentrale `PrintEnergyStats`-Ausgabe |
| **ARM64-Backend** (`arm64_emit.pas`) | ✅ | Vollständiges Energy-Tracking: Felder, Methoden, IR-Mapping |
| **IR-Ebene** (`ir.pas`) | ✅ | `EnergyCostHint` Feld, `GetIROpEnergyCost()`, `SetEnergyCostHint()` |
| **Lowering** (`lower_ast_to_ir.pas`) | ✅ | Energy-Kosten werden beim IR-Emit automatisch annotiert |
| **Sprach-Level** | ✅ | `@energy(level)` Pragma vor fn-Deklarationen |
| **Win64-Backend** | ❌ | Kein Energy-Support |
| **SPEC.md** | ✅ | Dokumentiert (Kapitel "Energy-Aware-Compiling") |
| **ebnf.md** | ✅ | EnergyAttr Produktionsregel dokumentiert |
| **Tests** | ✅ | test_energy_tracking.lyx, test_energy_attr.lyx |

#### Verbleibende optionale Optimierungen

- **Energy-basierte Instruction Selection**: Energy-Level beeinflusst noch nicht die Codegenerierung
- **Win64-Backend**: Kein Energy-Support
- **ARM64-CPU-Modelle**: Nur cfX86_64 und cfARM64 (keine Cortex-A Profile)

#### Bekannte verbleibende Probleme

- **Keine echten Optimierungen**: Energy-Level beeinflusst noch nicht die Instruction Selection
- **Win64-Backend**: Kein Energy-Support implementiert

#### Erledigte Architektur-Bereinigung (Phase 1 ✅)

- [x] Duplizierte Typen konsolidiert — `energy_model.pas` ist Single Source of Truth
- [x] `backend_types.pas` enthält nur noch Enums (`TEnergyLevel`, `TCPUFamily`) + Dynamic-Linking-Typen
- [x] Globale Variable `CurrentEnergyConfig` nur noch in `energy_model.pas`
- [x] `SetEnergyLevel` / `GetEnergyConfig` / `ResetEnergyConfig` nur noch in `energy_model.pas`
- [x] `x86_64_emit.pas` und `arm64_emit.pas` importieren `energy_model` und nutzen zentrale Typen
- [x] `lyxc.lpr`: kaputte Kontrollstruktur repariert, 5× duplizierte Stats-Ausgabe durch `PrintEnergyStats` ersetzt
- [x] Bugs behoben: Tippfehler, Array-Größen, Record-Feld-Reihenfolge, ALU-Kostenberechnung
- [x] Kompiliert sauber mit `-Ci -Cr -Co`, Smoke-Test bestanden

#### Aufgaben

**Phase 2: x86_64-Backend durchgängig integrieren** (Schätzung: 2-3 Tage) ✅
- [x] `TrackEnergy()` an jeder relevanten Stelle in `EmitFromIR` aufrufen (ALU-Ops, Memory-Ops, Branch-Ops, Syscalls)
- [x] `GetEnergyStats()` liefert korrekte Werte (ALU, FPU, Memory, Branch, Syscall-Zähler)
- [ ] `ApplyEnergyOptimizationsForLevel()` mit echten Optimierungen füllen:
  - `eelMinimal`/`eelLow`: Register-Allokation bevorzugen, unnötige Loads/Stores eliminieren
  - `eelMedium`: SSE statt x87 FPU wo sinnvoll
  - `eelHigh`/`eelExtreme`: Instruction Selection (z.B. `LEA` statt `ADD+MUL`, `XOR reg,reg` statt `MOV reg,0`)
- [ ] `SelectEnergyEfficientInstruction()` in Instruction-Selection-Pfade einbauen
- [x] Verifizieren: `GetEnergyStats()` nach Kompilation liefert korrekte Werte ✅ (test_inc_dec.lyx: ALU=2, Memory=7, Branch=7, Syscalls=9)

**Phase 3: ARM64-Backend Energy-Support** (Schätzung: 2 Tage) ✅
- [x] `GetEnergyStats()` implementiert (CodeSize + L1-Footprint)
- [x] Vollständige Energy-Felder analog zu x86_64 (`FEnergyContext`, `FCurrentCPU`, Tracking-Zähler)
- [x] `TrackEnergy()` im ARM64-Codegen aufrufen
- [x] `SetEnergyLevel(level)` Methode hinzugefügt

**Phase 3: ARM64-Backend Energy-Support** (Schätzung: 2 Tage)
- [x] `GetEnergyStats()` implementiert (CodeSize + L1-Footprint)
- [ ] Vollständige Energy-Felder analog zu x86_64 (`FEnergyContext`, `FCurrentCPU`, Tracking-Zähler)
- [ ] ARM64-spezifisches CPU-Energiemodell (Cortex-A72, Cortex-A53, Apple M1) in `energy_model.pas`
- [ ] `UpdateEnergyStatsForOperation()` im ARM64-Codegen aufrufen

**Phase 4: IR-Level Energy-Annotationen** (Schätzung: 2-3 Tage) ✅
- [x] `TIRInstruction` um `EnergyCostHint: UInt64` erweitern
- [x] Lowering (`lower_ast_to_ir.pas`): Energie-Kosten-Hinweise an IR-Knoten annotieren (via `SetEnergyCostHint`)
- [ ] IR-Optimierungspass: Energy-basierte Instruction Reordering (Cache-freundlichere Reihenfolge) — optional
- [ ] IR-Optimierungspass: Redundante Load/Store-Elimination bei hohem Energy-Level — optional

**Phase 5: Sprach-Level-Integration (optional)** (Schätzung: 3-5 Tage) ✅
- [x] Pragma `@energy(level)` auf Funktionsebene — überschreibt globales Level pro Funktion
- [x] Parser: Attribut vor `fn`-Deklarationen parsen
- [x] AST: `TFnDecl` um `EnergyLevel: TEnergyLevel` erweitern
- [x] Lowering: Energy-Level von AST zu IR propagieren
- [x] Backend: Energy-Level pro Funktion anwenden vor dem Codegen

**Phase 6: Tests & Dokumentation** (Schätzung: 1-2 Tage) ✅
- [x] Unit-Tests für `energy_model.pas` (Kostenberechnung, CPU-Modell-Lookup)
- [x] Unit-Tests für Energy-Tracking im x86_64-Emitter
- [x] Integrationstests: gleiches Lyx-Programm mit `--target-energy=1` vs `--target-energy=5` kompilieren und Statistiken vergleichen
- [x] Integrationstest: `@energy(1)` Pragma auf Funktion, Rest auf Level 3
- [x] `SPEC.md` um Energy-Aware-Architektur-Abschnitt erweitern
- [x] `ebnf.md` um `@energy` Pragma-Grammatik erweitern (falls Phase 5 umgesetzt)
- [x] `README.md` mit Energy-Aware-Compiling Dokumentation

#### Energy-Levels (Referenz)

| Level | Name | Loop Unroll | Battery | Cache | SIMD | FPU | AVX2 | AVX512 |
|-------|------|-------------|---------|-------|------|-----|------|--------|
| 0 | None | — | — | — | — | — | — | — |
| 1 | Minimal | 4× | ✅ | ✅ | — | — | — | — |
| 2 | Low | 2× | ✅ | ✅ | — | — | — | — |
| 3 | Medium | 1× | ✅ | ✅ | ✅ | — | ✅* | — |
| 4 | High | — | ✅ | ✅ | ✅ | ✅ | ✅* | — |
| 5 | Extreme | 8× | ✅ | ✅ | ✅ | ✅ | ✅* | ✅* |

(*) nur wenn CPU das Feature unterstützt

---

### Priorität 5: Cross-Compilation Tests

**Beschreibung**: Automatisierte Tests für alle Plattform-Kombinationen.

**Aufgaben**:
1. [ ] ARM64 Linux Test-Suite erstellen
2. [ ] Windows x64 Test-Suite (Cross-Compile auf Linux mit wine)
3. [ ] CI/CD Pipeline für alle Plattformen

---

## Architektur-Überlegungen

### Plattform-Abstraktion verbessern

Aktuell sind die Emitter-Klassen hardcodiert:
- `TX86_64Emitter` (Linux)
- `TWin64Emitter` (Windows x64)
- `TARM64Emitter` (Linux ARM64)

Eine bessere Abstraktion wäre:

```pascal
type
  TTargetArch = (archX86_64, archARM64);
  TTargetOS = (osLinux, osWindows, osMacOS);
  
  ICodeEmitter = interface
    ['{GUID}']
    procedure EmitFromIR(module: TIRModule);
    function GetCodeBuffer: TByteBuffer;
    function GetDataBuffer: TByteBuffer;
  end;
  
  IObjectWriter = interface
    ['{GUID}']
    procedure WriteToFile(const filename: string);
  end;
```

### Syscall-Abstraktion

Syscalls sind plattformspezifisch. Für Cross-Platform-I/O:
- Linux: syscalls (NR_read=0, NR_write=1, etc.)
- Windows: Win32 API (kernel32.dll)
- macOS: BSD syscalls

Optionen:
1. **Runtime-Adapter**: Compiler generiert plattformspezifischen Code
2. **Stdlib**: `std/io.lyx` mit `ifdef` oder Traits

---

## Kurzfristige Empfehlung

1. **Sofort**: ARM64 Dynamic Linking Writer implementieren — Emitter-Seite ist fertig, fehlt nur noch der Writer
2. ~~**Sofort**: Energy-Aware Architektur bereinigen~~ → ✅ **Erledigt** (Phase 1 abgeschlossen)
3. **Nächster Schritt**: x86_64-Backend Energy-Tracking durchgängig integrieren (Phase 2)
4. **Mittelfristig**: ARM64 Energy-Support vervollständigen + Windows ARM64
5. **Langfristig**: Sprach-Level Energy-Pragmas, macOS-Support

---

## Build-Befehle

```bash
# x86_64 Linux
fpc -O2 -Mobjfpc -Sh lyxc.lpr -olyxc

# ARM64 Linux (Cross-Compile mit FPC aarch64-linux)
fpc -Parm64 -O2 -Mobjfpc -Sh lyxc.lpr -olyxc-arm64

# Windows x64 (Cross-Compile mit FPC win64)
fpc -Twin64 -O2 -Mobjfpc -Sh lyxc.lpr -olyxc.exe
```

---

## Getestete Features pro Plattform

| Feature | x86_64 Linux | x86_64 Windows | ARM64 Linux |
|---------|---------------|----------------|-------------|
| Integer Ops | ✅ | ✅ | ✅ |
| Float Ops | ✅ | ✅ | ✅ |
| Strings | ✅ | ✅ | ✅ |
| Arrays | ✅ | ✅ | ✅ |
| Structs | ✅ | ✅ | ✅ |
| Classes | ✅ | ✅ | ❌ |
| Heap (new/dispose) | ✅ | ✅ | ❌ |
| Dynamic Linking | ✅ | n/a | ⚠️ |
| Random | ✅ | ✅ | ✅ |
| I/O Syscalls | ✅ | ✅ | ✅ |
| Globals | ✅ | ✅ | ✅ |
| Energy-Aware | ⚠️ | ❌ | ⚠️ |

Legende:
- ✅ = Implementiert und getestet
- ⚠️ = Teilweise implementiert
- ❌ = Nicht implementiert
- n/a = Nicht anwendbar
