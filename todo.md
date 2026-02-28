# Todo: Plattform-Unterstützung für Lyx

## Zusammenfassung der aktuellen Unterstützung

| Plattform | Status | Anmerkungen |
|-----------|--------|-------------|
| **x86_64 Linux** | ⚠️ Teilweise | Statisch vollständig, Dynamic Linking: Emitter ✅, Writer ⚠️ (Segfault bei Ausführung) |
| **x86_64 Windows** | ✅ Vollständig | PE32+, kernel32.dll Imports, Windows API |
| **ARM64 Linux** | ⚠️ Teilweise | Statisch vollständig, Dynamic Linking: Emitter ✅, Writer 🔲 |
| **ARM64 Windows** | ❌ Fehlt | Kein PE64 ARM64 Writer |
| **macOS** | ❌ Fehlt | Kein Mach-O Writer |

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

### Priorität 4: Cross-Compilation Tests

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

1. **Sofort**: ARM64 Dynamic Linking Writer implementieren - Emitter-Seite ist fertig, fehlt nur noch der Writer
2. **Mittelfristig**: Windows ARM64 - wichtig für Cross-Platform-Compiler
3. **Langfristig**: macOS - nice to have, aber geringere Priorität

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

Legende:
- ✅ = Implementiert und getestet
- ⚠️ = Teilweise implementiert
- ❌ = Nicht implementiert
- n/a = Nicht anwendbar
