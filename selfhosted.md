# Lyx → Self-Hosted Compiler: Roadmap

> Ziel: Der Lyx-Compiler (`lyxc`) wird in Lyx selbst geschrieben.
> Aktueller Stand: v0.5.5, Compiler in Free Pascal (FPC), ~40.000 LOC.

---

## Strategie

**Bootstrap in Stufen:**

```
Stufe 0 (jetzt):  lyxc.pas   → kompiliert Lyx-Code (FPC-Compiler)
Stufe 1 (Ziel):   lyxc.lyx   → kompiliert sich selbst (vom FPC-Compiler gebaut)
Stufe 2 (Zukunft):lyxc.lyx   → kompiliert sich selbst (vom Stufe-1-lyxc gebaut)
```

**Ansatz: Minimaler Bootstrap-Compiler**
Wir schreiben keinen voll-feature-kompatiblen Compiler. Der erste selbst-gehostete
Compiler muss nur genug Lyx können, um *sich selbst* zu kompilieren. Features wie
IPv6-Support, DataFrame, LyxVision etc. kommen erst in Stufe 2.

---

## Ist-Analyse: Was funktioniert heute

| Feature | Status | Anmerkung |
|---------|--------|-----------|
| Structs | ✅ | Felder, Dot-Access |
| Klassen / OOP | ✅ | Vererbung, VMT, Interface |
| Dynamische Arrays | ✅ | `Array<T>`, `.length`, push/pop |
| `switch/case` | ✅ | Auf int-Konstanten |
| `while`, `for`, `if` | ✅ | |
| `pchar` + Stringbuiltins | ✅ | StrLength, StrCharAt, StrCopy |
| File I/O | ✅ | ReadFile, WriteFile (std.fs) |
| `main(argc, argv)` | ✅ | CLI-Args zugänglich |
| `mmap` / `poke8/16` | ✅ | gerade gefixt |
| `con` Konstanten | ✅ | Global und lokal |
| Modulimport | ✅ | |
| Schreiben von ELF-Binaries | ✅ | Vollständig |
| OOP (Klassen) | ✅ | Heap-allokiert |
| `pchar` Concat (`+`) | ✅ | Über mmap-Buffer |

---

## Bekannte Bugs (müssen vor Self-Hosting gefixt sein)

| # | Bug | Auswirkung | Priorität |
|---|-----|------------|-----------|
| B1 | **16-byte Struct Parameter** | Structs mit 2 Slots (>8 Bytes) als Funktionsparameter übergeben → falscher Inhalt (Prologue speichert nur RDI, nicht RSI) | ✅ Behoben (diese Session) |
| B2 | **mmap Arg-Übergabe** | Zweites mmap-Argument (length) wurde aus Src2 gelesen (uninitialisiert) statt ArgTemps[1] → EINVAL | ✅ Behoben (diese Session) |
| B3 | **16-byte Struct Return Order** | RAX/RDX wurden in falscher Slot-Reihenfolge gespeichert | ✅ Behoben (letzte Session) |
| B4 | **poke64/peek64 ungetestet** | Nach mmap-Fix: funktioniert jetzt korrekt | ✅ Behoben (diese Session) |

---

## Fehlende Sprachfeatures

| # | Feature | Workaround möglich? | Aufwand | Prio für Self-Host |
|---|---------|--------------------|---------|--------------------|
| F1 | **`enum` Typen** | `con`-Konstanten (int64) | M | ✅ Implementiert (diese Session) |
| F2 | **`string` Typ** (dynamisch wachsend) | `pchar` + mmap-Buffer manuell | S | ✅ Implementiert (diese Session) |
| F3 | **Exception Handling** (try/catch) | `panic()` + Rückkabecode | S | ✅ Implementiert (diese Session) |
| F4 | **Multi-Return** / Tuple | Out-Parameter (Pointer) | S | ✅ Implementiert (diese Session) |
| F5 | **Generics** (echte) | Spezialisierte Typen pro Datentyp | XL | ✅ Implementiert (diese Session) |
| F6 | **Pattern Matching** | `switch` + Hilfsvariablen | M | ✅ Implementiert (diese Session) |

**Legende:** S=Klein, M=Mittel, L=Groß, XL=Sehr groß

---

## Fehlende Stdlib für den Compiler

| # | Feature | Workaround | Priorität |
|---|---------|------------|-----------|
| S1 | **StrFindChar + StrSub** | ✅ Implementiert (feat/string-utils) | Hoch |
| S2 | **StrAppendStr / StrConcat / StrCopy** | ✅ Implementiert (feat/string-utils) | Hoch |
| S3 | **IntToStr(n)** | ✅ Implementiert (feat/string-utils) | Mittel |
| S4 | **FileGetSize(path)** | ✅ Implementiert (feat/string-utils) | Mittel |
| S5 | **HashMap O(1) (string→int64)** | ✅ Implementiert (feat/string-utils) | Mittel |
| S6 | **GetArgC / GetArg** | ✅ Implementiert (feat/string-utils) | Mittel |
| S7 | **StrStartsWith / StrEndsWith / StrEquals** | ✅ Implementiert (feat/string-utils) | Niedrig |

---

## Workpakete

Jedes Paket ist so geschnitten, dass es in **einer Claude-Session** (~2-3h) abgeschlossen werden kann.

---

### WP-01: Bug Fix – 16-byte Struct Parameter (Blocker)

**Status: ✅ Bereits gelöst (nicht durch RDI+RSI-Split, sondern durch Pointer-Passing)**

**Beschreibung (ursprünglich):**
Wenn eine Funktion einen Struct-Parameter mit >8 Bytes bekommt, schreibt der Prologue
nur RDI (bytes 0-7) in den Stack, aber nicht RSI (bytes 8-15). Resultat: Felder in der
zweiten Hälfte des Structs enthalten Garbage.

**Warum bereits gelöst:**
Lyx übergibt Struct-Parameter grundsätzlich per implizitem Pointer (RDI = Adresse des
Structs auf dem Caller-Stack), nicht als Wert in RDI+RSI. Der Prologue speichert RDI
(den Pointer) in Slot 0 — das reicht vollständig. Felder werden über `[rdi+offset]`
adressiert. Sowohl 16-Byte- als auch 24-Byte-Structs wurden verifiziert (test_struct16_roundtrip.lyx, Exit 0, korrekte Feldwerte).

**Verifiziert mit:**
- `tests/regression/structs/test_struct16_roundtrip.lyx` → `a: 42`, `b: 99` ✅
- Inline-Test mit 24-byte Triple-Struct → `sum=6` ✅

**Abhängigkeiten:** keine

---

### WP-02: Stdlib – StringBuilder & String-Hilfsfunktionen ✅ ERLEDIGT

**Beschreibung:**
Für den Lexer und Parser brauchen wir dynamisches String-Building und String-Analyse.
Wir brauchen keinen neuen Sprachtyp – eine `StringBuilder`-Klasse in Lyx reicht.

**Dateien:**
- `std/string.lyx` – erweitert

**Was erledigt wurde:**
1. **`StringBuilder`-Klasse** ✅ – `Init`, `Append`, `AppendChar`, `AppendInt`, `ToString`, `Clear`, `FreeBuffer`
   - Hinweis: Methode heißt `FreeBuffer()` statt `Free()` da `Free` ein TObject-VMT-Slot ist
2. **`StrSplit(s, delim, out: int64, maxParts: int64): int64`** ✅
3. **`StrTrim(s): pchar`** ✅ – heap-allocated trimmed copy
4. **`StrStartsWith(s, prefix): bool`** ✅ – bereits als Builtin vorhanden
5. **`StrEndsWith(s, suffix): bool`** ✅ – bereits als Builtin vorhanden
6. **`IntToStr(n: int64): pchar`** ✅ – bereits als Builtin vorhanden

**Nebenfix (Compiler-Bugs behoben):**
- `StrAppendStr` `jl`-Overflow (signed byte overflow bei >127 Byte Realloc-Pfad) – gefixt
- `poke64`/`peek64`/`poke16`/`peek16`/`poke32`/`peek32` fehlten in `lower_ast_to_ir.pas` – gefixt
- Importierte Klassen-Methoden wurden nicht kompiliert (IR + Sema) – gefixt

**Test:** `tests/feature_checks/strings/test_stringbuilder.lyx` ✅

**Abhängigkeiten:** keine

---

### WP-03: Stdlib – File Utilities & Argv ✅ DONE

**Beschreibung:**
Vollständige Datei-Lese-Infrastruktur für den Compiler: Quelltext lesen, Dateigröße abfragen,
und CLI-Argumente als echte `pchar`-Array-Elemente lesen.

**Dateien:**
- `std/fs.lyx` – erweitert
- `std/env.lyx` – erweitert

**Umgesetzt:**
1. **`FileSize(path: pchar): int64`** – war bereits vorhanden
2. **`FileReadAll(path: pchar): pchar`** – mmap-Buffer, liest alles, null-terminiert ✅
3. **`ArgvGet(argv: pchar, i: int64): pchar`** – `peek64(argv + i*8)` ✅
4. **`ArgvGetStr(argc, argv, name): pchar`** – `--flag=value` Parser ✅

**Compiler-Fixes:** syscall-Emitter für `open/close/lseek/write/unlink/rename` ergänzt;
`GetArgV()` als Builtin; kritischer Call-Mode-Bug behoben (cmImported vs cmInternal).

**Test:** `tests/feature_checks/stdlib/test_filereadall.lyx` ✅ (liest sich selbst, 1629 Bytes, 65 Zeilen)

**Abhängigkeiten:** keine

---

### WP-04: Enum-Typen ✅ DONE

**Beschreibung:**
Enums machen Token-Typen, AST-Node-Typen und IR-Opcodes viel lesbarer.
Als Workaround können `con`-Konstanten verwendet werden, aber echte Enums verbessern
die Codequalität erheblich.

**Umgesetzt:**
1. Syntax: `enum TokenKind { tkIdent, tkInt, tkPlus };` → int64-Konstanten (0, 1, 2, ...) ✅
2. Explizite Werte: `enum HttpStatus { OK = 200, NOT_FOUND = 404 };` ✅
3. Gemischt: explizit + auto-increment ✅
4. `switch` auf Enum-Werte funktioniert (int64) ✅
5. Enum-Typ in Sema: `var x: TokenKind := tkIdent` → `atInt64` ✅
6. Enum-Typ in Funktionsparametern ✅
7. Rückwärtskompatibilität: alte Semicolon-Syntax weiterhin unterstützt ✅

**Compiler-Fixes:** IR-Lowerer: `var x: EnumType := enumValue` wurde fälschlich als
Funktionszeiger behandelt (TAstIdent-Heuristik). Fix: FConstMap vor fnPtr-Branch prüfen.
Sema: FEnumTypes-Registry; VarDecl + Param-Auflösung für Enum-Typen.

**Test:** `tests/lyx/enums/test_enum_basic.lyx` ✅

**Abhängigkeiten:** keine

---

### WP-05: Self-Hosted Lexer ✅ DONE

**Beschreibung:**
Schreibe den Lyx-Lexer in Lyx. Dies ist der erste echte Bootstrap-Schritt.
Der Lexer liest `pchar`-Quelltext und produziert eine Liste von Token.

**Datei:** `bootstrap/lexer.lyx`

**Umgesetzt:**
1. `pub type Lexer = class` mit 17 Feldern, 13 Methoden ✅
2. 120 `pub con TK_*` Token-Konstanten ✅
3. Keywords, Identifiers, Operatoren (alle Lyx-Operatoren) ✅
4. Integer-Literale: Dezimal, Hex (`0xFF`), Binär (`0b1010`) ✅
5. String-Literale mit Escape-Sequenzen ✅
6. Char-Literale ✅
7. Zeilenkommentare `//` und Block-Kommentare `/* */` ✅
8. `Peek()` ohne Verbrauch ✅
9. `LexerTokKindStr()` Hilfsfunktion ✅

**Compiler-Fixes (IR-Lowerer):**
- Importierte Klassen müssen `pub` deklariert sein (sonst null-Pointer-Allokation)
- Field-Offset-Fallback für importierte Klassen-Methoden (sema läuft nicht auf importierten Methoden)
- Namespace-Methodenaufruf-Rewriting (`self.method()` → `_L_ClassName_method(self)`) im IR-Lowerer

**Test:** `tests/lyx/bootstrap/test_lexer.lyx` ✅ (alle 7 Tests bestanden)

**Abhängigkeiten:** WP-02 (StringBuilder), WP-03 (FileReadAll)

---

### WP-06: Self-Hosted Parser (Basis)

**Beschreibung:**
Schreibe den Lyx-Parser in Lyx. Baut einen flachen AST auf, der als int64-indiziertes
Array repräsentiert wird (kein echter Baum mit Pointern – stattdessen Index-Referenzen).

**Datei:** `bootstrap/parser.lyx`

**AST-Repräsentation (kompakt):**
```lyx
// AST-Node-Typen als Konstanten
con NK_FUNC_DECL: int64 := 1;
con NK_VAR_DECL:  int64 := 2;
con NK_BINOP:     int64 := 3;
// ...

struct AstNode {
  kind:   int64;   // NK_xxx
  child0: int64;   // Index in nodes-Array (-1 = kein)
  child1: int64;   // Index in nodes-Array (-1 = kein)
  child2: int64;   // Index in nodes-Array (-1 = kein)
  tokIdx: int64;   // Token-Index für Fehlermeldungen
  iVal:   int64;   // int-Wert (für Literale, etc.)
}
```

**Minimales Subset (reicht für Bootstrap):**
- Funktionsdeklarationen
- Variablendeklarationen
- Ausdrücke (binäre Operatoren, Funktionsaufrufe, Literale)
- `if`, `while`, `return`
- Struct-Deklarationen (für Token/AstNode etc.)
- `import`-Statements

**Was zu tun:**
1. Recursive-Descent Parser für das minimale Subset
2. Fehlerausgabe mit Zeilennummer
3. Kein Recovery – bei Fehler panic

**Test:** `tests/lyx/bootstrap/test_parser.lyx`
Input: `bootstrap/lexer.lyx` selbst (oder eine Hilfsdatei)
Expected: Korrekte Node-Anzahl, keine Abstürze

**Abhängigkeiten:** WP-05 (Lexer)

---

### WP-07: Self-Hosted Typ-Checker (Minimal)

**Beschreibung:**
Minimale semantische Analyse: Symboltabelle für Funktionen und Variablen,
Typ-Auflösung für primitive Typen, Grundvalidierung.

**Datei:** `bootstrap/sema.lyx`

**Symboltabelle:**
```lyx
struct Symbol {
  name:    pchar;  // null-terminated
  nameLen: int64;
  kind:    int64;  // SYM_FUNC, SYM_VAR, SYM_STRUCT, ...
  typeId:  int64;  // primitiver Typ-Code
  nodeIdx: int64;  // AST-Node-Index
}
```

**Was zu tun:**
1. Lineare Symboltabelle (Array of Symbol, O(n) Lookup – für Bootstrap reicht das)
2. Zwei-Pass:
   - Pass 1: Sammle alle Funktions- und Struct-Namen
   - Pass 2: Löse Typen auf, prüfe Variablen-Definitionen
3. Einfache Typ-Prüfung: int64, pchar, bool, void
4. Fehlermeldung bei undefiniertem Symbol

**Test:** `tests/lyx/bootstrap/test_sema.lyx`

**Abhängigkeiten:** WP-06 (Parser)

---

### WP-08: Self-Hosted x86_64 Code Generator

**Beschreibung:**
Der wichtigste und komplexeste Schritt. Emittiert x86_64 Maschinencode direkt aus dem AST.
Kein IR – direkter AST → Binärcode Weg für maximale Einfachheit.

**Datei:** `bootstrap/codegen_x86.lyx`

**Ansatz:**
- Stack-basierte Auswertung (kein Register-Allokator nötig)
- Alle Werte auf Stack (`push`/`pop`)
- Einfaches Frame-Layout: `rbp`-relative Slots
- Nur statische ELF64 (kein PLT/GOT, kein Dynamic Linking)

**Was zu tun:**
1. **ELF64-Writer** (minimal):
   - ELF-Header
   - `.text` Section mit Code
   - `.data` Section für String-Literale
   - Symbol-Table für `_start`
2. **Code Emitter** (Klasse):
   - `EmitU8(b)`, `EmitU32(n)`, `EmitU64(n)` – Bytes schreiben
   - `EmitCall(label)`, `EmitRet()`, `EmitPush(reg)`, `EmitPop(reg)`
   - `EmitMovRegImm(reg, val)`, `EmitMovMemReg(rbp, off, reg)`, etc.
3. **Ausdruck-Generierung** (rekursiv):
   - Literale: `mov rax, IMM`
   - Variablen: `mov rax, [rbp+offset]`
   - BinOp: beide Seiten auswerten, kombinieren
   - Funktionsaufruf: Argumente in RDI/RSI/RDX/RCX/R8/R9
4. **Statement-Generierung:**
   - `var x: int64 := expr` → allokiere Slot, berechne Wert
   - `if (cond) { ... } else { ... }` → `cmp + jz/jnz`
   - `while (cond) { ... }` → Loop mit Rücksprung
   - `return expr` → `mov rax, val; mov rsp, rbp; pop rbp; ret`
5. **Funktionsdeklarationen:**
   - Prologue: `push rbp; mov rbp, rsp; sub rsp, N`
   - Parameter als Slots
   - Epilogue: `mov rsp, rbp; pop rbp; ret`
6. **Builtin-Calls:** PrintStr, PrintInt (direkt als Syscall-Sequenzen)

**Test:** `tests/lyx/bootstrap/test_codegen.lyx`
Kompiliere eine einfache `.lyx`-Datei und führe das Ergebnis aus.

**Abhängigkeiten:** WP-06 (Parser), WP-07 (Sema)

---

### WP-09: Bootstrap-Test – Kompiliere lyxc-mini mit sich selbst

**Beschreibung:**
Führe den kompletten Bootstrap durch. Schreibe einen minimalen `lyxc-mini.lyx`
der WP-05 bis WP-08 zusammenführt und als eigenständiger Compiler funktioniert.

**Was zu tun:**
1. `bootstrap/lyxc_mini.lyx` – verbindet Lexer + Parser + Sema + Codegen
2. **Stage 1:** `./lyxc bootstrap/lyxc_mini.lyx -o lyxc_mini` (mit FPC-Compiler)
3. **Stage 2:** `./lyxc_mini bootstrap/lyxc_mini.lyx -o lyxc_mini2`
4. **Vergleich:** `diff lyxc_mini lyxc_mini2` → muss identisch sein (oder deterministisch gleich)
5. Wenn Stage 2 korrekt ist: **Self-Hosting erreicht!**

**Akzeptanzkriterium:**
`lyxc_mini` kann eine Teilmenge von Lyx kompilieren und dabei sich selbst reproduzieren.

**Abhängigkeiten:** WP-05 bis WP-08

---

### WP-10: Stage 2 – Feature-Parität mit FPC-Compiler

**Beschreibung:**
Erweitere `lyxc_mini.lyx` schrittweise bis er alle Lyx-Features unterstützt
und schließlich den vollen `lyxc.lyx` kompilieren kann.

**Sub-Pakete (je eine Session):**

| Sub-WP | Feature | Abhängigkeit |
|--------|---------|--------------|
| 10a | Klassen + VMT | WP-09 |
| 10b | Dynamische Arrays | WP-09 |
| 10c | `switch/case` | WP-09 |
| 10d | Structs mit Feldzugriff | WP-09 |
| 10e | Modulimport | WP-09 |
| 10f | Enum-Typen | WP-04 + WP-09 |
| 10g | Optimierungen (Constant Folding, CSE) | 10a-10f |
| 10h | ARM64 Backend | 10a-10f |
| 10i | Linter | 10a-10f |
| 10j | Vollständiger Self-Host-Test | alle |

---

## Reihenfolge & Abhängigkeiten

```
WP-01 (Bug Fix: 16-byte Struct Param)
  │
  ├── WP-02 (StringBuilder & String-Utils)
  │     │
  │     ├── WP-03 (File Utils & Argv)
  │     │     │
  │     │     └─┐
  │     └────────┤
  │               │
  │   WP-04 (Enums) ─────────────────────┐
  │                                       │
  └───────────── WP-05 (Lexer) ──────────┤
                    │                     │
                    └── WP-06 (Parser) ───┤
                           │              │
                           └── WP-07 (Sema)
                                  │
                                  └── WP-08 (Codegen)
                                         │
                                         └── WP-09 (Bootstrap-Test)
                                                │
                                                └── WP-10 (Feature-Parität)
```

---

## Aufwandsschätzung

| Paket | Sessions | Schwierigkeit |
|-------|----------|---------------|
| WP-01 | 1 | Mittel (Kenntnis der Prologue-Generierung nötig) |
| WP-02 | 1 | Leicht |
| WP-03 | 0.5 | Leicht |
| WP-04 | 2 | Mittel (Parser + Sema-Änderungen) |
| WP-05 | 2 | Mittel (viele Tokenkombinationen) |
| WP-06 | 2-3 | Mittel-Schwer (Ausdrucks-Grammatik) |
| WP-07 | 1-2 | Mittel |
| WP-08 | 3-4 | Schwer (x86_64 Encoding, ELF) |
| WP-09 | 1 | Leicht (Zusammenführung) |
| WP-10 | 5-10 | Mittel-Schwer (iterativ) |
| **Gesamt** | **~20-25 Sessions** | |

---

## Entscheidungen & Prinzipien

1. **Kein OOP im Bootstrap-Compiler** – Nur Structs und Funktionen (einfacher zu bootstrappen)
2. **Kein GC** – Manuelle Speicherverwaltung mit mmap/munmap; Compiler-Läufe sind kurzlebig
3. **Kein IR** im Mini-Compiler – Direkt AST → x86_64 (spart ein ganzes Transformationspass)
4. **Subset-Ansatz** – Bootstrap-Compiler muss nur Lyx-Subset kennen, den er selbst verwendet
5. **Deterministische Ausgabe** – Kein Randomness in Code-Layout (wichtig für Stage-2-Vergleich)
6. **Con-Konstanten statt Enums** – bis WP-04 abgeschlossen ist

---

## Was NICHT benötigt wird (für Stage 1)

- Kein Garbage Collector (mmap-Puffer reichen)
- Keine echten Generics (spezialisierte Typen reichen)
- Kein Exception Handling (panic() reicht)
- Kein ARM64/Windows Backend (erst Stage 2)
- Keine Linter-Integration (erst Stage 2)
- Kein Debuginfo (erst Stage 2)
- Keine IR-Optimierungen (erst Stage 2)

---

## Bekannte Risiken

| Risiko | Wahrscheinlichkeit | Gegenmaßnahme |
|--------|-------------------|---------------|
| Weitere 16-byte Struct Bugs | Mittel | Avoid struct params >8 Bytes im Bootstrap-Compiler |
| Dynamic Array push/pop Bugs | Niedrig | Frühzeitig testen (WP-02) |
| x86_64 Encoding Fehler im Codegen | Hoch | Byte-für-Byte mit `objdump` vergleichen |
| Stage-2-Compiler weicht ab | Mittel | Deterministisches Layout erzwingen |
| Rekursion im Parser (Stack Overflow) | Niedrig | Iterative Loops bevorzugen |

---

*Erstellt: 2026-03-25 | Lyx v0.5.5 | Ziel: Self-Hosted Compiler in ~20-25 Sessions*
