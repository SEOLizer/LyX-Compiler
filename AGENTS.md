# AGENTS.md – Lyx Compiler (FreePascal)

Lyx ist ein nativer Compiler für die Sprache **Lyx**, geschrieben in **FreePascal (FPC 3.2.2)**.
Zielplattform: **Linux x86_64, ELF64**, ohne libc (reine Syscalls).
Spezifikation: `SPEC.md` (Architektur, Roadmap) · `ebnf.md` (v0.2.0+ Grammatik, Typen, Semantik).

## Build-Befehle

```bash
# Compiler bauen (Release)
fpc -O2 -Mobjfpc -Sh lyxc.lpr -olyxc

# Debug-Build (Range/Overflow/Stack-Checks, Heaptrace)
fpc -g -gl -Ci -Cr -Co -gh -Mobjfpc -Sh lyxc.lpr -olyxc

# Einzelne Unit prüfen (Syntax + Typcheck, kein Linking)
fpc -s -Mobjfpc -Sh frontend/lexer.pas

# Unit-Ausgabeverzeichnis (empfohlen)
fpc -FUlib/ -Mobjfpc -Sh lyxc.lpr -olyxc
```

## Tests

```bash
# Einzelnen Test kompilieren und ausführen
fpc -g -Mobjfpc -Sh tests/test_lexer.pas -otests/test_lexer && ./tests/test_lexer

# Alle Tests (Makefile-Konvention)
make test

# Erzeugtes Lyx-Binary testen (Integrationstest)
./lyxc examples/hello.lyx -o /tmp/hello && /tmp/hello
echo $?   # Exit-Code prüfen
```

FPCUnit (aus `fcl-test`) ist das Test-Framework. Jede Test-Unit registriert
ihre Suites im `initialization`-Abschnitt.

## Debug- und Überprüfungswerkzeuge

Bei jeder Spracherweiterung oder Backend-Änderung **müssen** diese Werkzeuge
aktiv genutzt werden, um Korrektheit und Sicherheit zu gewährleisten:

### 1. Statische Analyse (`--static-analysis`)

Führt 7 Analyse-Passes über den IR-Code aus. **Immer nach Backend-Änderungen ausführen:**

```bash
./lyxc test.lyx -o test --static-analysis
```

| Pass | Erkennt | Wann nutzen |
|------|---------|-------------|
| Data-Flow-Analyse | Def-Use-Ketten für alle Variablen | Nach neuen IR-Ops |
| Live-Variable-Analyse | Ungenutzte Variablen (Warnungen) | Nach Parser-Erweiterungen |
| Constant-Propagation | Bekannte Konstanten durch irAdd/irSub/irMul | Nach Optimierer-Änderungen |
| Null-Pointer-Analyse | Potenzielle Null-Dereferenzierungen | Nach neuen Pointer-Ops |
| Array-Bounds-Analyse | Statische Index-Safety (SAFE/UNVERIFIED) | Nach Array-Features |
| Terminierungs-Analyse | Unbounded Loops, rekursive Calls | Nach Control-Flow-Änderungen |
| Stack-Nutzungs-Analyse | Worst-Case-Stack pro Funktion | Nach neuen Builtins |

### 2. MC/DC Coverage (`--mcdc`, `--mcdc-report`)

Instrumentiert den Code für Modified Condition/Decision Coverage. **Für alle Control-Flow-Erweiterungen:**

```bash
./lyxc test.lyx -o test --mcdc --mcdc-report
```

- Zeigt **GAP** für nicht abgedeckte Pfade (Condition T/F, Decision T/F, never executed)
- Runtime-Counter im Data-Segment (`lock inc qword` für Thread-Safety)
- Report: Total decisions, fully covered, with gaps, MC/DC coverage %

**Bei neuen if/while/switch-Features:** MC/DC-Report prüfen, dass alle Branches instrumentiert sind.

### 3. Assembly Listing (`--asm-listing`)

Generiert source-annotiertes Assembly mit Hex-Bytes. **Für Backend-Debugging:**

```bash
./lyxc test.lyx -o test --asm-listing
# Erzeugt: test.lst
```

Format: `offset  hex_bytes  ir_mnemonic  ; source_file:line`

**Bei neuen IR→Backend-Mappings:** Listing prüfen, dass jede IR-Op korrekt übersetzt wird.

### 4. IR-Coverage-Test

Prüft 100% IR-Abdeckung in allen Backends:

```bash
cd compiler && ./tests/test_ir_coverage
```

**Nach jeder neuen IR-Operation:** Test muss in ALLEN Backends grün sein (x86_64, x86_64_win64, arm64, macosx64, xtensa, win_arm64, riscv).

### 5. Determinismus-Test

Validiert bit-für-bit reproduzierbare Builds:

```bash
cd compiler && ./tests/test_determinism
```

**Nach Backend-Änderungen:** Muss 18/18 Tests bestehen (10x-Stresstest inklusive).

### 6. Reference Interpreter

Validiert Compiler-Korrektheit via Bisimulation:

```bash
cd compiler && ./tests/test_reference_interpreter
```

**Nach IR-Änderungen:** 22/22 Tests müssen bestehen (Arithmetik, Bit-Ops, Vergleiche, Map/Set, Globals).

### 7. Test-Generierung

Fuzzing, Boundary-Value, Mutation Testing, Symbolic Execution:

```bash
cd compiler && ./tests/test_generation
```

**Nach Parser/Lexer-Erweiterungen:** Fuzzing mit 50+ random Inputs, 0 Crashes erforderlich.

### 8. TOR-Validierung (DO-178C TQL-5)

Tool Operational Requirements:

```bash
./lyxc --version        # TOR-001
./lyxc --build-info     # TOR-002
./lyxc --config         # TOR-003
cd compiler && ./tests/test_tor_validation  # 23/23 Tests
```

### 9. Call-Graph Analyse (`--call-graph`)

Analysiert den statischen Aufrufgraphen. **Bei Problemen mit Rekursion, WCET oder Stack-Tiefe:**

```bash
./lyxc test.lyx -o test --call-graph
```

- Zeigt alle Funktionen und ihre Aufrufer
- Erkennt rekursive Aufrufe (direkt und indirekt)
- Nützlich für DO-178C WCET-Analyse und Stack-Berechnung

**Bei unerwarteten Rekursionsfehlern oder Stack-Overflows:** Call-Graph prüfen.

### 10. Map-File Generator (`--map-file`)

Generiert Memory-Layout-Dokumentation. **Bei Adressproblemen, Debugging oder Audit:**

```bash
./lyxc test.lyx -o test --map-file
# Erzeugt: test.map
```

- Section-Übersicht (.text, .data, .rodata, .bss)
- Funktions-Symbole mit Adressen und Größen
- Globale Variablen mit Adressen
- Statistiken (Code/Data Size)

**Bei Speicherlayout-Problemen oder DO-178C 6.1 Compliance:** Map-File generieren.

## Projektstruktur

```
lyxc/
  lyxc.lpr                # Hauptprogramm (Entry)
  frontend/
    lexer.pas              # Tokenizer (Literale: Hex, Bin, Oct, @energy)
    parser.pas             # Recursive-Descent (SIMD, OOP, Maps, Sets)
    ast.pas                # AST-Knoten (inkl. EnergyLevel & VMT-Flags)
    sema.pas               # Semantische Analyse (Scopes, Type-Casting 'as')
  ir/
    ir.pas                 # 3-Address-Code (Opcodes: irMapSet, irSIMDAdd etc.)
    lower_ast_to_ir.pas    # AST → IR Transformation
  backend/
    backend_intf.pas       # Interfaces (ICodeEmitter, IObjectWriter)
    x86_64/
      x86_64_emit.pas      # x86_64 Encoding (SSE2 für f64/SIMD)
      x86_64_sysv.pas      # SysV Calling Convention
    elf/
      elf64_writer.pas     # ELF64 Header, .text, .data, .rodata (VMTs)
  util/
    diag.pas               # Diagnostik (Fehler, SourceSpan)
    bytes.pas              # TByteBuffer (LE-Encoding, Patching)
  tests/
    test_lexer.pas         # Tests für Literale und Escapes
    test_parser.pas        # Tests für komplexe Grammatik
  examples/
    hello.lyx              # Kuratierte Showcase-Programme
  tests/lyx/
    basic/                 # Grundlegende Sprach-Features
    functions/             # Funktionsaufrufe
    arrays/                # Statische Arrays
    dynarray/              # Dynamische Arrays
    oop/                   # OOP, Structs, VMT, Abstract Methods
    io/                    # I/O & Syscalls
    strings/               # String-Tests
    stdlib/                # Stdlib-Nutzung
    ...                    # Weitere Kategorien
```

## FreePascal Code-Style

### Unit-Kopf (jede Datei)

```pascal
{$mode objfpc}{$H+}
unit lexer;

interface

uses
  SysUtils, Classes,   // RTL zuerst
  diag, bytes;         // Projekt-Units danach

{ ... }

implementation

{ ... }

end.
```

### Naming-Konventionen

| Element           | Konvention         | Beispiel                         |
|-------------------|--------------------|----------------------------------|
| Unit-Datei        | snake_case         | `elf64_writer.pas`               |
| Typ (Klasse)      | `T` + PascalCase   | `TLexer`, `TAstNode`            |
| Typ (Enum)        | `T` + PascalCase   | `TTokenKind`, `TStorageKlass`    |
| Enum-Wert         | Kurzpräfix + Name  | `tkPlus`, `skVar`, `nkBinOp`    |
| Interface         | `I` + PascalCase   | `ICodeEmitter`                   |
| Record            | `T` + PascalCase   | `TSourceSpan`, `TToken`         |
| Variable/Param    | camelCase          | `tokenList`, `currentChar`      |
| Konstante (lokal) | camelCase          | `maxRegisters`                  |
| Konstante (Unit)  | PascalCase / UPPER | `MaxParams = 6`                 |
| Methode           | PascalCase         | `NextToken`, `EmitMovRegImm`    |
| Privates Feld     | `F` + PascalCase   | `FSource`, `FPosition`          |

### Enum-Präfixe (projektspezifisch)

```pascal
TTokenKind   = (tkIdent, tkIntLit, tkStrLit, tkPlus, tkMinus, tkIf, ...);
TStorageKlass = (skVar, skLet, skCo, skCon);
TNodeKind    = (nkIntLit, nkStrLit, nkBinOp, nkUnaryOp, nkCall, ...);
TLyxType     = (atInt64, atBool, atVoid, atPChar, atF64, atDynArray, ...);
```

### Formatierung

- **Einrückung**: 2 Spaces (keine Tabs)
- **Zeilenlänge**: max. 100 Zeichen
- **begin/end**: `begin` auf eigener Zeile, außer bei Einzeilern
- **Leerzeile** zwischen Methoden-Implementierungen
- Keine leeren `else`-Blöcke — stattdessen Guard-Clause mit `Exit`

### Fehlerbehandlung

```pascal
// Compiler-Fehler: über TDiagnostics mit SourceSpan
procedure TLexer.Error(const Msg: string; Span: TSourceSpan);
begin
  FDiag.Report(dkError, Msg, Span);
end;

// Interne Fehler (Compiler-Bugs): Assert oder Exception
Assert(Assigned(Node), 'ICE: Node darf nicht nil sein');
```

- **Compile-Fehler** (falsche Lyx-Syntax): `TDiagnostics.Report(dkError, ...)`
- **Interne Fehler** (Compiler-Bug): `Assert` oder `EInternalError`
- **Keine Exceptions** für normalen Kontrollfluss

### Speicherverwaltung

- Objekte, die du erstellst, gehören ihrem Erzeuger → `Free` im `Destroy`
- AST-Knoten gehören dem Parser → Parser gibt AST-Root frei
- `TByteBuffer` verwaltet seinen internen Speicher selbst
- Keine globalen Variablen für Zustand — alles in Instanzen kapseln

## Lyx-Sprachübersicht (Kurzreferenz)

Vollständige Spezifikation: siehe `SPEC.md` und `ebnf.md`.

**Typen**: `int64`, `bool`, `void`, `pchar`, `pchar?`, `f32`, `f64`, `array`, `Map<K,V>`, `Set<T>`, `parallel Array<T>`
**Speicherklassen**: `var` (mutable) · `let` (immutable) · `co` (readonly runtime) · `con` (compile-time)
**Builtins**: `exit(code)` · `PrintStr(s)` · `PrintInt(x)` · `Random()` · `RandomSeed(n)`
**Keywords**: `fn var let co con if else while return true false extern unit import pub as array struct class extends new dispose super static self Self private protected panic assert where value virtual override abstract`
**Zuweisung**: `:=` (nicht `=`)
**Blöcke**: `{ }` (nicht begin/end)
**Operatoren**: `+ - * / %` · `== != < <= > >=` · `&& || !` · `& | ^ ~ << >>` · `?? ?.` · `|>`

## Architektur-Regeln

1. **Frontend ↔ Backend Trennung**: Kein x86-Code im Frontend, keine AST-Knoten im Backend
2. **IR als Stabilitätsanker**: AST → IR → Maschinencode. Nie AST direkt zu Bytes
3. **ELF64 ohne libc**: `_start` ruft `main()`, dann `sys_exit`. Kein Linking gegen libc
4. **SysV ABI**: Parameter in RDI, RSI, RDX, RCX, R8, R9 · Return in RAX
5. **Builtins sind Spezialfälle**: Runtime-Snippets (PrintStr, PrintInt) werden eingebettet
6. **Jedes Token trägt SourceSpan**: Zeile + Spalte für Fehlermeldungen
7. **VMT (Virtual Method Table)**: Jede Klasse mit virtual/override/abstract Methoden generiert im .data-Segment eine VMT. Das erste Quadword eines Objekts auf dem Heap zeigt auf diese VMT.
8. **SIMD / ParallelArray**: Heap-Allokation für `parallel Array<T>` muss 16-Byte aligned sein (für SSE2). SIMD-Operationen werden auf irSIMD-Opcodes abgebildet.
9. **Energy-Awareness**: Das `@energy(n)` Pragma wird im `TFunctionNode` gespeichert. Level 1-2: Code-Dichte priorisieren. Level 5: Aggressives Loop Unrolling (8x).
10. **Null-Safety**: `pchar?` erlaubt Null-Werte, `pchar` (Standard) führt zu einem Compile-Fehler bei Null-Zuweisung.

## Git-Konventionen

```
feat(lexer): String-Escape-Sequenzen implementieren
fix(codegen): Off-by-one bei Stack-Alignment korrigieren
refactor(ir): ConstNode von LiteralNode trennen
test(parser): While-Statement-Tests ergänzen
docs: ebnf.md um ConstExpr-Regeln erweitert
```

- Keine `.idea/`-Dateien committen (→ `.gitignore`)
- Keine kompilierten Binaries committen (`.ppu`, `.o`, `.exe`)
- Spezifikationsänderungen separat committen (nicht mit Code mischen)

## Checkliste vor Code-Änderungen

1. `ebnf.md` und `SPEC.md` lesen — Grammatik und Architektur verstehen
2. Bestehende Unit-Struktur respektieren — keine Logik in falsche Schicht
3. Tests schreiben oder erweitern bevor/nachdem Code geändert wird
4. `fpc -g -Ci -Cr -Co` muss ohne Fehler durchlaufen
5. Enum-Präfixe konsistent halten (tk/sk/nk/at)
6. **Lexer**: Unterstützt er die neuen Basen (0x, $, 0b, %, 0o, &) und Unterstriche _?
7. **Sema**: Ist der Cast via `as` zwischen int64 und f64 valide? (Nutze cvtsi2sd / cvttsd2si)
8. **Codegen**: Beachtet der x86_64_emit die SysV-Calling Convention (RDI, RSI, RDX, RCX, R8, R9)?
9. **VMT**: Werden virtual/override/abstract Methoden korrekt in die VMT eingetragen?
10. **SIMD**: Ist die 16-Byte Ausrichtung für ParallelArray gewährleistet?

## Checkliste nach Code-Änderungen

Nach jeder Änderung an Lexer, Parser, IR oder Backend **müssen** diese Prüfungen durchlaufen werden:

1. **Compiler baut**: `make build` muss ohne Fehler durchlaufen
2. **Statische Analyse**: `./lyxc test.lyx -o test --static-analysis` — 0 Warnungen für neue Features
3. **MC/DC Coverage**: `./lyxc test.lyx -o test --mcdc --mcdc-report` — keine Gaps in neuen Branches
4. **Assembly Listing**: `./lyxc test.lyx -o test --asm-listing` — Hex-Bytes und IR-Mnemonics prüfen
5. **Call-Graph**: `./lyxc test.lyx -o test --call-graph` — Rekursion und Aufrufstruktur prüfen
6. **Map-File**: `./lyxc test.lyx -o test --map-file` — Speicherlayout verifizieren
7. **IR-Coverage**: `cd compiler && ./tests/test_ir_coverage` — 100% in allen 7 Backends
8. **Determinismus**: `cd compiler && ./tests/test_determinism` — 18/18 Tests müssen bestehen
9. **Reference Interpreter**: `cd compiler && ./tests/test_reference_interpreter` — 22/22 Tests
10. **Test-Generierung**: `cd compiler && ./tests/test_generation` — Fuzzing: 0 Crashes
11. **TOR-Validierung**: `cd compiler && ./tests/test_tor_validation` — 23/23 Tests
12. **Integrationstests**: `make test` — alle bestehenden Tests müssen grün bleiben
