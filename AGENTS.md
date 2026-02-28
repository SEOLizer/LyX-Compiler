# AGENTS.md – Lyx Compiler (FreePascal)

Lyx ist ein nativer Compiler für die Sprache **Lyx**, geschrieben in **FreePascal (FPC 3.2.2)**.
Zielplattform: **Linux x86_64, ELF64**, ohne libc (reine Syscalls).
Spezifikation: `SPEC.md` (Architektur, Roadmap) · `ebnf.md` (Grammatik, Typen, Semantik).

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

## Projektstruktur

```
lyxc/
  aurumc.lpr              # Hauptprogramm (Entry)
  frontend/
    lexer.pas              # Tokenizer → TToken-Stream
    parser.pas             # Recursive-Descent → AST
    ast.pas                # AST-Knotentypen
    sema.pas               # Semantische Analyse (Scopes, Typen)
  ir/
    ir.pas                 # 3-Address-Code IR-Knoten
    lower_ast_to_ir.pas    # AST → IR Transformation
  backend/
    backend_intf.pas       # Interfaces (ICodeEmitter, IObjectWriter)
    x86_64/
      x86_64_emit.pas      # x86_64 Instruktions-Encoding
      x86_64_sysv.pas      # SysV Calling Convention
    elf/
      elf64_writer.pas      # ELF64 Header + Segmente
  util/
    diag.pas               # Diagnostik (Fehler, SourceSpan)
    bytes.pas              # TByteBuffer (WriteU8/U16/U32/U64LE, Patch)
  tests/
    test_lexer.pas         # Tests für Lexer
    test_parser.pas        # Tests für Parser
    test_codegen.pas       # Tests für Backend
  examples/
    hello.lyx               # Kuratierte Showcase-Programme
  tests/lyx/
    basic/                  # Grundlegende Sprach-Features
    functions/              # Funktionsaufrufe
    arrays/                 # Statische Arrays
    dynarray/               # Dynamische Arrays
    oop/                    # OOP, Structs, VMT
    io/                     # I/O & Syscalls
    strings/                # String-Tests
    stdlib/                 # Stdlib-Nutzung
    ...                     # Weitere Kategorien
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
| Typ (Klasse)      | `T` + PascalCase   | `TLexer`, `TAstNode`             |
| Typ (Enum)        | `T` + PascalCase   | `TTokenKind`, `TStorageKlass`    |
| Enum-Wert         | Kurzpräfix + Name  | `tkPlus`, `skVar`, `nkBinOp`    |
| Interface         | `I` + PascalCase   | `ICodeEmitter`                   |
| Record            | `T` + PascalCase   | `TSourceSpan`, `TToken`          |
| Variable/Param    | camelCase          | `tokenList`, `currentChar`       |
| Konstante (lokal) | camelCase          | `maxRegisters`                   |
| Konstante (Unit)  | PascalCase / UPPER | `MaxParams = 6`                  |
| Methode           | PascalCase         | `NextToken`, `EmitMovRegImm`     |
| Privates Feld     | `F` + PascalCase   | `FSource`, `FPosition`           |

### Enum-Präfixe (projektspezifisch)

```pascal
TTokenKind   = (tkIdent, tkIntLit, tkStrLit, tkPlus, tkMinus, tkIf, ...);
TStorageKlass = (skVar, skLet, skCo, skCon);
TNodeKind    = (nkIntLit, nkStrLit, nkBinOp, nkUnaryOp, nkCall, ...);
TLyxType   = (atInt64, atBool, atVoid, atPChar);
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

Vollständige Spezifikation: siehe `ebnf.md`.

**Typen**: `int64`, `bool`, `void`, `pchar`
**Speicherklassen**: `var` (mutable) · `let` (immutable) · `co` (readonly runtime) · `con` (compile-time)
**Builtins**: `exit(code)` · `PrintStr(s)` · `PrintInt(x)`
**Keywords**: `fn var let co con if else while return true false extern`
**Zuweisung**: `:=` (nicht `=`)
**Blöcke**: `{ }` (nicht begin/end)

## Architektur-Regeln

1. **Frontend ↔ Backend Trennung**: Kein x86-Code im Frontend, keine AST-Knoten im Backend
2. **IR als Stabilitätsanker**: AST → IR → Maschinencode. Nie AST direkt zu Bytes
3. **ELF64 ohne libc**: `_start` ruft `main()`, dann `sys_exit`. Kein Linking gegen libc
4. **SysV ABI**: Parameter in RDI, RSI, RDX, RCX, R8, R9 · Return in RAX
5. **Builtins sind Spezialfälle**: Runtime-Snippets (PrintStr, PrintInt) werden eingebettet
6. **Jedes Token trägt SourceSpan**: Zeile + Spalte für Fehlermeldungen

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
