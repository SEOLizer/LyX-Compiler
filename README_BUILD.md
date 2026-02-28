# Pure Lyx FS API - Build Anleitung

## Übersicht
Diese Anleitung zeigt, wie man die Pure Syscall FS API für x86_64 und ARM64 baut und testet.

## Voraussetzungen
- Linux x86_64 System
- FreePascal Compiler (fpc) >= 3.2.2
- NASM Assembler (nasm) >= 2.0

## Projektstruktur
```
aurum/
  sys_linux_x64.s          # x86_64 Assembler-Brücke
  sys_linux_arm64.s         # ARM64 Assembler-Brücke
  std/
    fs.lyx                  # Pure Syscall FS API
    string.lyx              # String-Hilfsfunktionen
    error.lyx               # Fehlerbehandlung
    time.lyx                # Zeitfunktionen (inkl. IntToString)
  test/
    test_fs_pure.lyx       # x86_64 Testprogramm
    test_fs_arm64.lyx      # ARM64 Testprogramm
```

## Build-Prozess

### 1. Assembler-Dateien kompilieren
```bash
# x86_64 Assembler-Brücke
nasm -f elf64 -o sys_linux_x64.o sys_linux_x64.s

# ARM64 Assembler-Brücke
nasm -f elf64 -o sys_linux_arm64.o sys_linux_arm64.s
```

### 2. Testprogramm für x86_64 bauen
```bash
# Testprogramm mit Assembler-Brücke linken
fpc -Mobjfpc -Sh -CX -FUlib/ -o test_fs_pure test_fs_pure.lyx sys_linux_x64.o
```

### 3. Testprogramm für ARM64 bauen
```bash
# ARM64 Testprogramm
fpc -Mobjfpc -Sh -CX -FUlib/ -o test_fs_arm64 test_fs_arm64.lyx sys_linux_arm64.o
```

### 4. Tests ausführen
```bash
# x86_64 Tests
./test_fs_pure

# ARM64 Tests (falls auf ARM64 System)
./test_fs_arm64
```

## Makefile

```makefile
# Makefile für Pure Lyx FS API

TARGETS = test_fs_pure test_fs_arm64

FPC = fpc
NASM = nasm

FPC_FLAGS = -Mobjfpc -Sh -CX -FUlib/
NASM_FLAGS = -f elf64

.PHONY: all
all: $(TARGETS)

test_fs_pure: test_fs_pure.lyx sys_linux_x64.o
	$(FPC) $(FPC_FLAGS) -o$@ test_fs_pure.lyx sys_linux_x64.o

test_fs_arm64: test_fs_arm64.lyx sys_linux_arm64.o
	$(FPC) $(FPC_FLAGS) -o$@ test_fs_arm64.lyx sys_linux_arm64.o

sys_linux_x64.o: sys_linux_x64.s
	$(NASM) $(NASM_FLAGS) -o $@ $<

sys_linux_arm64.o: sys_linux_arm64.s
	$(NASM) $(NASM_FLAGS) -o $@ $<

.PHONY: test
test: all
	@echo "=== Running x86_64 Tests ==="
	@./test_fs_pree || (echo "x86_64 Tests FAILED"; exit 1)
	@echo "=== ALL TESTS PASSED ==="

.PHONY: clean
clean:
	rm -f *.o *.ppu test_fs_pure test_fs_arm64
```

## Schnellstart

```bash
# Alles bauen
make all

# Tests ausführen
make test

# Aufräumen
make clean
```

## Troubleshooting

1. **NASM nicht gefunden:**
   ```bash
   sudo apt-get install nasm
   ```

2. **FreePascal nicht gefunden:**
   ```bash
   sudo apt-get install fpc
   ```

3. **ARM64 auf x86_64 System:**
   - ARM64 Tests funktionieren nur auf ARM64 Hardware
