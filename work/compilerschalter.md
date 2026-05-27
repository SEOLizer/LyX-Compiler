# Lyx Compiler — Kompilier-Bedingungen und Laufzeit-Prüfschalter

## Übersicht

Zwei orthogonale Systeme:

| System | Wann aktiv | Zweck |
|--------|-----------|-------|
| `@if` | Compile-Zeit | Bedingte Kompilierung — totes Code-Zweig wird nie ins IR überführt |
| `@io_check` / `@overflow_check` | Laufzeit (compiler-gesteuert) | Sicherheits-/Performance-Schalter für I/O-Fehlerbehandlung und Arithmetik-Overflow |

Lyx verwendet **keinen textuellen Präprozessor** wie C. `@if` ist AST-basiert: beide Zweige werden geparst, nur der aktive Zweig erreicht die IR-/Codegen-Phase.

---

## EBNF

```ebnf
(* Neue Top-Level-Direktiven *)
GlobalDirective   = "@io_check"        "(" BoolLiteral ")" ";"
                  | "@overflow_check"  "(" BoolLiteral ")" ";" ;

BoolLiteral       = "true" | "false" ;

(* Erweiterung der Top-Level-Deklarationen *)
TopDecl           = ConDecl | VarDecl | FnDecl | TypeDecl | EnumDecl
                  | ExternFnDecl | ImportDecl | DimDecl | UtypeDecl
                  | GlobalDirective
                  | CondBlockTop ;

(* Bedingte Kompilierung auf Top-Level *)
CondBlockTop      = "@if" "(" ConstExpr ")" "{" { TopDecl } "}"
                    [ "@else" "{" { TopDecl } "}" ] ;

(* Bedingte Kompilierung innerhalb von Funktionen *)
Statement         = ... | CondBlockStmt | GlobalDirective ;

CondBlockStmt     = "@if" "(" ConstExpr ")" "{" { Statement } "}"
                    [ "@else" "{" { Statement } "}" ] ;

(* Erlaubte Ausdrücke in ConstExpr *)
ConstExpr         = ConstAtom
                  | "!" ConstExpr
                  | ConstExpr ("&&" | "||") ConstExpr
                  | ConstExpr ("==" | "!=" | "<" | "<=" | ">" | ">=") ConstExpr
                  | "(" ConstExpr ")" ;

ConstAtom         = BoolLiteral | IntLiteral | ConIdent ;
ConIdent          = (* zuvor deklarierte con-Konstante oder System-Konstante *) ;
```

---

## Design-Entscheidungen

### Lexer — kein neues Token nötig
Der Lexer emittiert `TK_AT` (= 111) für `@`. Das nächste Token ist dann entweder
`TK_IF`, `TK_ELSE` (bereits Keywords) oder `TK_IDENT` (`"io_check"`, `"overflow_check"`).
Der Parser unterscheidet die Fälle durch Lookahead — kein Lexer-Umbau nötig.

### AST-Pruning statt IR-Pruning
`@if`-Zweige werden in der **Sema-Phase** gestrichen. Weder IR-Generierung noch
Codegen sehen `NK_AT_IF`. Das ist einfacher als ein IR-Pruning und verhindert
versehentliche IR-Artefakte aus toten Zweigen.

### io_check-Zustand als Codegen-Flag
`@io_check(false)` ist kein Scope-Stack — es ist ein einfaches Boolean-Flag im
`Codegen`-Objekt (wie `runtimeChecks`). Es gilt ab der Direktive bis zur nächsten
gegenteiligen Direktive oder bis Ende des Top-Level-Scopes.

### IOResult-Builtin
Wenn `@io_check(false)` aktiv ist, werden Fehler-Return-Werte in ein
Compiler-verwaltetes Global `_lyx_io_result: int64` geschrieben.
`IOResult()` ist ein neues Builtin, das diesen Wert liest.

---

## System-Konstanten

Vom Compiler vor Sema-Start injizierte `con`-Konstanten:

```lyx
// Arch-Codes (TARGET_ARCH)
pub con ARCH_X86_64:  int64 := 1;
pub con ARCH_ARM64:   int64 := 2;
pub con ARCH_RISCV64: int64 := 3;
pub con ARCH_ARM_CM:  int64 := 4;

// OS-Codes (TARGET_OS)
pub con OS_LINUX:   int64 := 1;
pub con OS_MACOS:   int64 := 2;
pub con OS_WINDOWS: int64 := 3;
pub con OS_BARE:    int64 := 4;   // kein Betriebssystem (Embedded)

// Laufzeit-Konstanten (zur Compile-Zeit gesetzt)
pub con TARGET_ARCH: int64 := 1;  // Wert aus CompilerConfig.target
pub con TARGET_OS:   int64 := 1;  // Wert aus CompilerConfig.os

// Bool-Shortcuts (abgeleitet, ebenfalls injiziert)
pub con TARGET_X86_64:  bool := true;   // TARGET_ARCH == ARCH_X86_64
pub con TARGET_ARM64:   bool := false;
pub con TARGET_RISCV64: bool := false;
pub con TARGET_ARM_CM:  bool := false;
pub con TARGET_LINUX:   bool := true;   // TARGET_OS == OS_LINUX
pub con TARGET_MACOS:   bool := false;
pub con TARGET_WINDOWS: bool := false;
pub con TARGET_BARE:    bool := false;
```

Verwendungsbeispiel:
```lyx
@if (TARGET_ARCH == ARCH_X86_64) {
  pub fn fast_memcpy(dst: int64, src: int64, n: int64): void { ... }
} @else {
  pub fn fast_memcpy(dst: int64, src: int64, n: int64): void { ... }
}
```

---

## Work Packages

---

### WP-CS-01 — Neue NK_-Konstanten in `src/parser.lyx`

**Ziel:** Zwei neue AST-Node-Kinds deklarieren.

Anfügen in `src/parser.lyx` nach `NK_FOR_C = 102`:

```lyx
pub con NK_AT_IF:        int64 := 103; // @if/@else bedingte Kompilierung
pub con NK_AT_DIRECTIVE: int64 := 104; // @io_check / @overflow_check
```

**Node-Layout `NK_AT_IF`:**

| Slot | Inhalt |
|------|--------|
| `c0` | Bedingungsausdruck (normaler Expr-AST; Sema wertet ihn aus) |
| `c1` | Then-Block (`NK_BLOCK`) |
| `c2` | Else-Block (`NK_BLOCK`) oder 0 |

**Node-Layout `NK_AT_DIRECTIVE`:**

| Slot | Inhalt |
|------|--------|
| `iv` | Direktiv-Art: `0` = `@io_check`, `1` = `@overflow_check` |
| `iv2` | Wert: `0` = `false`, `1` = `true` |

**Abhängigkeiten:** keine  
**Geschätzte Komplexität:** trivial (2 Zeilen)

---

### WP-CS-02 — Parser: `@if` auf Top-Level (`src/parser.lyx`)

**Ziel:** `@if(ConstExpr) { TopDecl* } [@else { TopDecl* }]` auf Top-Level parsen.

**Einstiegspunkt:** `_parseTopDecl()` (oder die Schleife, die Top-Decls sammelt).

```
Wenn TK_AT gesehen:
  Advance();
  Wenn nächstes Token TK_IF:
    → _parseAtIf(toplevel=true)
  Wenn nächstes Token TK_IDENT("io_check"):
    → _parseAtDirective(kind=0)   // WP-CS-04
  Wenn nächstes Token TK_IDENT("overflow_check"):
    → _parseAtDirective(kind=1)   // WP-CS-04
  Sonst:
    → bestehende @-Behandlung (Unary-Op, at()-Adressierung) beibehalten
```

**`_parseAtIf(toplevel: bool)` Pseudo-Code:**
```
Expect(TK_IF)
Expect(TK_LPAREN)
var cond := ParseExpr()      // normaler Ausdruck, Sema wertet ihn aus
Expect(TK_RPAREN)
Expect(TK_LBRACE)
var thenBody := parseBlock(toplevel)   // TopDecl* oder Statement*
Expect(TK_RBRACE)
var elseBody := 0
if Check(TK_AT):
  Advance()
  if Check(TK_ELSE):
    Advance()
    Expect(TK_LBRACE)
    elseBody := parseBlock(toplevel)
    Expect(TK_RBRACE)
n := _alloc(NK_AT_IF, ti)
_sc0(n, cond)
_sc1(n, thenBody)
_sc2(n, elseBody)
return n
```

`parseBlock(toplevel)`:
- `toplevel=true` → ruft wiederholt `_parseTopDecl()` auf, bis `}` kommt  
- `toplevel=false` → ruft wiederholt `_parseStmt()` auf, bis `}` kommt  
Rückgabe: `NK_BLOCK`-Node der Kindknoten.

**Abhängigkeiten:** WP-CS-01  
**Geschätzte Komplexität:** klein–mittel

---

### WP-CS-03 — Parser: `@if` auf Statement-Level (`src/parser.lyx`)

**Ziel:** `@if` innerhalb von Funktionskörpern parsen.

**Einstiegspunkt:** `_parseStmt()`.

```
Wenn aktueller Token TK_AT und nächster TK_IF:
  Advance() × 2
  → _parseAtIf(toplevel=false)
```

Identischer AST wie WP-CS-02, nur `parseBlock(false)` statt `parseBlock(true)`.

**Abhängigkeiten:** WP-CS-01, WP-CS-02  
**Geschätzte Komplexität:** trivial (delegiert an WP-CS-02)

---

### WP-CS-04 — Parser: `@io_check` / `@overflow_check` (`src/parser.lyx`)

**Ziel:** `@io_check(true|false);` und `@overflow_check(true|false);` parsen — erlaubt auf Top-Level und in Funktionen.

**`_parseAtDirective(kind: int64)` Pseudo-Code:**
```
Advance()                            // überspringt "io_check" / "overflow_check" Ident
Expect(TK_LPAREN)
var val: int64 := 0
if Check(TK_TRUE):  val := 1; Advance()
elif Check(TK_FALSE): val := 0; Advance()
else: ParseError("@io_check/@overflow_check erwartet true oder false")
Expect(TK_RPAREN)
Expect(TK_SEMI)
n := _alloc(NK_AT_DIRECTIVE, ti)
_siv(n, kind)    // c0-Slot als iv: 0=io_check, 1=overflow_check
_siv2(n, val)    // iv2: 0=false, 1=true
return n
```

**Hinweis:** `TK_TRUE` und `TK_FALSE` sind bereits definiert (Lexer kennt `true`/`false`).

**Abhängigkeiten:** WP-CS-01  
**Geschätzte Komplexität:** klein

---

### WP-CS-05 — Sema: System-Konstanten injizieren (`src/sema.lyx`, `src/lyxc.lyx`)

**Ziel:** Vor der Sema-Phase die Compile-Zeit-Konstanten `TARGET_ARCH`, `TARGET_OS` etc. in die Sema-Symboltabelle eintragen.

**Implementierung in `src/lyxc.lyx`**, direkt vor dem Sema-Aufruf:

```lyx
pub fn injectSystemConstants(sema: Sema, cfg: CompilerConfig): void {
  // Arch-Codes
  sema_injectConInt(sema, "ARCH_X86_64"c,  1);
  sema_injectConInt(sema, "ARCH_ARM64"c,   2);
  sema_injectConInt(sema, "ARCH_RISCV64"c, 3);
  sema_injectConInt(sema, "ARCH_ARM_CM"c,  4);

  // OS-Codes
  sema_injectConInt(sema, "OS_LINUX"c,   1);
  sema_injectConInt(sema, "OS_MACOS"c,   2);
  sema_injectConInt(sema, "OS_WINDOWS"c, 3);
  sema_injectConInt(sema, "OS_BARE"c,    4);

  // Laufzeit-Werte aus dem Build-Ziel
  var arch: int64 := cfg_archCode(cfg);   // x86_64=1, arm64=2, ...
  var os:   int64 := cfg_osCode(cfg);     // linux=1, macos=2, ...
  sema_injectConInt(sema, "TARGET_ARCH"c, arch);
  sema_injectConInt(sema, "TARGET_OS"c,   os);

  // Bool-Shortcuts
  sema_injectConBool(sema, "TARGET_X86_64"c,  arch == 1);
  sema_injectConBool(sema, "TARGET_ARM64"c,   arch == 2);
  sema_injectConBool(sema, "TARGET_RISCV64"c, arch == 3);
  sema_injectConBool(sema, "TARGET_ARM_CM"c,  arch == 4);
  sema_injectConBool(sema, "TARGET_LINUX"c,   os == 1);
  sema_injectConBool(sema, "TARGET_MACOS"c,   os == 2);
  sema_injectConBool(sema, "TARGET_WINDOWS"c, os == 3);
  sema_injectConBool(sema, "TARGET_BARE"c,    os == 4);
}
```

**Neue Hilfsfunktionen in `src/sema.lyx`:**

```lyx
pub fn sema_injectConInt(sema: Sema, name: pchar, val: int64): void
  // Trägt eine int64-Konstante in die globale Symboltabelle ein (wie con Decl)

pub fn sema_injectConBool(sema: Sema, name: pchar, val: bool): void
  // Trägt eine bool-Konstante ein
```

**`cfg_archCode` / `cfg_osCode` in `lyxc.lyx`:**

```lyx
fn cfg_archCode(cfg: CompilerConfig): int64 {
  if cfg.target == TARGET_X86_64    { return 1; }
  if cfg.target == TARGET_ARM64     { return 2; }
  if cfg.target == TARGET_RISCV64   { return 3; }
  if cfg.target == TARGET_ARM_CM    { return 4; }
  return 1;  // Default: x86_64
}

fn cfg_osCode(cfg: CompilerConfig): int64 {
  if cfg.target == TARGET_X86_64         { return 1; }  // Linux
  if cfg.target == TARGET_MACOS_X86_64   { return 2; }
  if cfg.target == TARGET_WINDOWS_X86_64 { return 3; }
  if cfg.target == TARGET_ANDROID_ARM64  { return 1; }  // Android = Linux-Kern
  if cfg.target == TARGET_ARM_CM         { return 4; }  // Bare metal
  return 1;
}
```

**Abhängigkeiten:** keine  
**Geschätzte Komplexität:** mittel

---

### WP-CS-06 — Sema: `@if` Constant-Folding + Branch-Pruning (`src/sema.lyx`)

**Ziel:** `NK_AT_IF`-Knoten auswerten und den toten Zweig aus dem AST entfernen.

**Konstanten-Evaluator `sema_evalConstExpr(sema, node): int64`** (0=false, ≠0=true/Wert):

```
NK_LIT_BOOL  → 1 wenn true, 0 wenn false
NK_LIT_INT   → direkter int64-Wert
NK_IDENT     → sema_lookupConst(sema, name) → Wert aus der Symboltabelle
NK_BINOP(&&) → evalConstExpr(c0) != 0 && evalConstExpr(c1) != 0
NK_BINOP(||) → evalConstExpr(c0) != 0 || evalConstExpr(c1) != 0
NK_BINOP(==) → evalConstExpr(c0) == evalConstExpr(c1) → 0/1
NK_BINOP(!=) → entsprechend
NK_BINOP(<)  → ...
NK_UNOP(!)   → evalConstExpr(c0) == 0 → 0/1
Sonst        → Sema-Fehler: "Kein Compile-Zeit-Ausdruck"
```

**Branch-Pruning in `sema_visitNode(sema, node)`:**

```
case NK_AT_IF:
  var condVal := sema_evalConstExpr(sema, node.c0)
  if condVal != 0:
    // Then-Zweig: normal durch Sema laufen lassen
    sema_visitBlock(sema, node.c1)
    // Else-Zweig: verwerfen (node.c2 = 0 setzen)
    node.c2 := 0
    // NK_AT_IF durch Then-Block ersetzen (node.kind := NK_BLOCK, node.c0 := node.c1)
    // ODER: den Then-Block inline ins Parent-Block heben
    ast_replaceNodeWithBlock(node, node.c1)
  else:
    if node.c2 != 0:
      sema_visitBlock(sema, node.c2)
      ast_replaceNodeWithBlock(node, node.c2)
    else:
      ast_removeNode(node)   // kein Else → leeres Statement
```

**Wichtig:** Beide Zweige werden geparst (Syntaxfehler in totem Code werden gemeldet),
aber **nur der aktive Zweig** geht durch die vollständige Typenprüfung und
Symbolauflösung.

**Abhängigkeiten:** WP-CS-01, WP-CS-02, WP-CS-05  
**Geschätzte Komplexität:** mittel–groß

---

### WP-CS-07 — Sema: `@io_check` / `@overflow_check` Scope-Zustand (`src/sema.lyx`)

**Ziel:** `NK_AT_DIRECTIVE`-Knoten in der Sema-Phase verarbeiten und Zustand
weiterreichen, sodass Codegen die Flags korrekt setzt.

**Sema-Verarbeitung:**

```
case NK_AT_DIRECTIVE:
  var kind  := node.iv    // 0=io_check, 1=overflow_check
  var value := node.iv2   // 0=false, 1=true
  if kind == 0: sema.ioCheckEnabled    := value
  if kind == 1: sema.overflowCheckEnabled := value
  // Node bleibt im AST — Codegen liest ihn und setzt sein Flag
```

**Neue Felder im `Sema`-Objekt** (`src/sema.lyx`):

```lyx
ioCheckEnabled:       int64;   // 1=true (Default), 0=false
overflowCheckEnabled: int64;   // 0=false (Default), 1=true
```

Initialisierung: `self.ioCheckEnabled := 1; self.overflowCheckEnabled := 0;`

**Neue Felder im `Codegen`-Objekt** (`src/codegen_x86.lyx`):

```lyx
ioCheckEnabled:       int64;   // aus sema übernommen; default 1
overflowCheckEnabled: int64;   // aus sema übernommen; default 0
```

Übergabe in `lyxc.lyx` (nach dem Sema-Lauf, vor `cg.Generate()`):
```lyx
cg.ioCheckEnabled       := sema.ioCheckEnabled;
cg.overflowCheckEnabled := sema.overflowCheckEnabled;
```

**Hinweis:** Der `NK_AT_DIRECTIVE`-Knoten wird **nicht** aus dem AST entfernt.
Der Codegen verarbeitet ihn direkt, um die Flags zur richtigen Statement-Position
im Code zu aktualisieren (Direktiven können mehrfach in einer Funktion vorkommen).

**Abhängigkeiten:** WP-CS-01, WP-CS-04  
**Geschätzte Komplexität:** klein

---

### WP-CS-08 — Codegen: `NK_AT_DIRECTIVE` verarbeiten (`src/codegen_x86.lyx`)

**Ziel:** Im Codegen, wenn `NK_AT_DIRECTIVE` angetroffen wird, die Flags aktualisieren.

In `cg_emitStmt()` (oder dem Top-Level-Dispatch):

```
case CGN_AT_DIRECTIVE:   // CGN_AT_DIRECTIVE := 104
  var kind  := node.iv
  var value := node.iv2
  if kind == 0: self.ioCheckEnabled       := value
  if kind == 1: self.overflowCheckEnabled := value
  // Kein Code emittieren
```

Neue Konstante in `src/codegen_x86.lyx`:
```lyx
con CGN_AT_DIRECTIVE: int64 := 104;
```

**Abhängigkeiten:** WP-CS-07  
**Geschätzte Komplexität:** trivial

---

### WP-CS-09 — Codegen: `@io_check` für I/O-Builtins + `IOResult` (`src/codegen_x86.lyx`)

**Ziel:** I/O-Syscall-Builtins erhalten nach dem Syscall einen Fehler-Check,
gesteuert durch `self.ioCheckEnabled`.

**Betroffene Builtins:** `open`, `read`, `write`, `close`, `lseek`, `mmap`, `munmap`

**Prinzip nach jedem dieser Syscalls:**

```
; RAX enthält den Syscall-Rückgabewert
mov [_lyx_io_result], rax        ; immer schreiben (für IOResult())
test rax, rax
jns .ok                          ; if rax >= 0: kein Fehler
; Fehlerfall:
cmp self.ioCheckEnabled, 1
jne .ok                          ; @io_check(false): still fortfahren
; Panic emittieren (vorhandene cg_emitInlinePanic nutzen)
lea rdi, [rip + io_error_msg]
call _lyx_panic / inline panic
.ok:
```

**`_lyx_io_result` Global:**
Ein 8-Byte-Slot im `.data`-Segment des ELF, Adresse via `lea rax, [rip+offset]`.
Initialisiert mit 0.

**Neues Builtin `IOResult()`** im Codegen:

```
} else if cg_seq(fname, fnlen, "IOResult", 8) {
  // Lädt _lyx_io_result → rax
  emit: mov rax, [rip + _lyx_io_result_offset]
```

**Fehlermeldungsstring** (im `.data`-Segment):
```
"lyxc: I/O error (use @io_check(false) to suppress)\n"
```

**Reihenfolge der Änderungen in `cg_emitBuiltinCall()`:**

Für jeden betroffenen Builtin nach dem `syscall`-Opcode:
```lyx
if self.ioCheckEnabled != 0 || true {  // immer IOResult schreiben
  self.cg_emitIoResultSave();          // mov [_lyx_io_result], rax
}
if self.ioCheckEnabled != 0 {
  self.cg_emitIoCheckPanic();          // test rax + jns + panic
}
```

Neue Hilfsmethoden:
- `fn cg_emitIoResultSave()` — speichert RAX in `_lyx_io_result`
- `fn cg_emitIoCheckPanic()` — emittiert den Fehler-Branch

**Abhängigkeiten:** WP-CS-07, WP-CS-08  
**Geschätzte Komplexität:** mittel

---

### WP-CS-10 — Codegen: `@overflow_check` für Arithmetik (`src/codegen_x86.lyx`)

**Ziel:** Bei `self.overflowCheckEnabled != 0` nach signierten Ganzzahl-Operationen
den Overflow-Flag prüfen und bei Overflow panic auslösen.

**Betroffene Operationen:** Signierte Addition (`+`), Subtraktion (`-`), Multiplikation (`*`)

**x86_64-Mechanismus:**

```asm
; signed add:
add rax, rcx
jo  .overflow      ; Jump if Overflow Flag gesetzt
...
.overflow:
  lea rdi, [rip + overflow_msg]
  ; inline panic
```

**Implementierung in `cg_emitBinop()` (Operatoren `+`, `-`, `*` für `int64`):**

```lyx
if self.overflowCheckEnabled != 0 {
  self.cg_emitOverflowPanic();  // jo + inline panic
}
```

**Neue Methode `cg_emitOverflowPanic()`:**
Emittiert:
```asm
jo short +5           ; skip-over für den Normalfall
; inline panic body:
lea rdi, [rip + overflow_msg_offset]
mov esi, overflow_msg_len
mov edi, 2
mov eax, 1
syscall               ; write to stderr
mov edi, 134          ; exit code SIGABRT convention
mov eax, 60
syscall               ; exit
```

**Fehlermeldung:**
```
"lyxc: integer overflow detected\n"
```

**Wichtiger Hinweis:** `f64`-Arithmetik ist nicht betroffen (IEEE 754 hat eigene
Overflow-Semantik). Unsigned-Operationen (`uint64`) ebenfalls nicht (kein OF nach
unsigned add). Nur `int64`-Operatoren.

**Abhängigkeiten:** WP-CS-07, WP-CS-08  
**Geschätzte Komplexität:** mittel

---

### WP-CS-11 — Tests & Snapshot-Tests

**Ziel:** Korrektheit beider Systeme durch automatisierte Tests sicherstellen.

#### @if-Tests (`tests/`)

| Testfall | Erwartung |
|---------|-----------|
| `@if(true) { fn f() { return 1; } }` | `f()` im Binary vorhanden |
| `@if(false) { fn f() { return 1; } }` | `f()` nicht im Binary |
| `@if(true) { ... } @else { fn g() {} }` | `g()` nicht im Binary |
| `con A: bool := true; @if(A) { ... }` | con-Lookup klappt |
| `@if(TARGET_X86_64) { ... }` | System-Konstante klappt |
| `@if(TARGET_ARCH == 1) { ... }` | Vergleich mit int-Konstante klappt |
| `@if(true && false) { ... }` | Logik-Kombination |
| `@if` mit Syntaxfehler im toten Zweig | Parse-Fehler wird trotzdem gemeldet |
| `@if` auf Statement-Level | Funktioniert in Funktionskörper |

#### @io_check-Tests

| Testfall | Erwartung |
|---------|-----------|
| `@io_check(false); open("no.txt", 0, 0);` | Kein Crash, IOResult enthält -2 |
| `open("no.txt", 0, 0);` (Standard) | Panic / exit(1) |
| `@io_check(false); ... @io_check(true); open(...);` | Nach Reset panic aktiv |
| `IOResult()` nach fehlgeschlagenem `read()` | Fehler-Code korrekt |

#### @overflow_check-Tests

| Testfall | Erwartung |
|---------|-----------|
| `@overflow_check(true); var x := 9223372036854775807 + 1;` | Panic |
| `@overflow_check(false); var x := maxInt + 1;` | Kein Crash, Wraparound |

**Snapshot-Tests:** Für jeden Testfall wird `readelf -S` / `objdump -d` Output
als Snapshot gespeichert und mit `make snapshot` geprüft.

**Abhängigkeiten:** WP-CS-01 bis WP-CS-10  
**Geschätzte Komplexität:** mittel

---

## Empfohlene Implementierungsreihenfolge

```
WP-CS-01  NK_-Konstanten  (trivial, Fundament)
WP-CS-02  Parser @if Top-Level
WP-CS-03  Parser @if Statement-Level
WP-CS-04  Parser @io_check/@overflow_check
WP-CS-05  Sema System-Konstanten
WP-CS-06  Sema Branch-Pruning          ← größte Einzelaufgabe
WP-CS-07  Sema Directive-Scope
WP-CS-08  Codegen Directive-Dispatch
WP-CS-09  Codegen @io_check
WP-CS-10  Codegen @overflow_check
WP-CS-11  Tests
```

WP-CS-02/03/04 können nach WP-CS-01 parallel bearbeitet werden.  
WP-CS-05 ist unabhängig von WP-CS-02–04.  
WP-CS-09/10 können parallel nach WP-CS-08 bearbeitet werden.

---

## Offene Fragen / Entscheidungen

| # | Frage | Optionen |
|---|-------|---------|
| F-1 | Soll der tote `@if`-Zweig vollständig durch Sema laufen (Typen- und Symbolprüfung) oder nur syntaktisch? | Nur Syntax (aktueller Plan): schneller, weniger false positives. Vollständig: findet Fehler in ungenutztem Code frühzeitig. |
| F-2 | `@io_check` nur auf Builtin-Syscalls oder auch auf zukünftige File/IO-Klassen? | Aktuell nur Builtins. Klassen-basiertes I/O (v0.9+) kann dasselbe Flag lesen. |
| F-3 | Soll `@overflow_check` auch für `int32`/`int16`/`int8` gelten? | Aktuell nur `int64`. Kleinere Typen werden sowieso auf 64 Bit hochgerechnet. |
| F-4 | `@io_check`-Zustand nach Funktionsende zurücksetzen? | Aktuell gilt es bis zur nächsten Direktive. Pascal-Modell: Scope-Stack. Scope-Stack wäre sauberer, aber komplexer. |
| F-5 | `@else @if` Ketten (wie `#elif` in C)? | Aktuell nicht geplant. Kann als `@else { @if(...) { } }` geschachtelt werden. |
| F-6 | Sollen System-Konstanten aus einer eigenen `sys.lyx`-Datei gelesen oder direkt injiziert werden? | Injektion (aktueller Plan) ist einfacher; eine `sys.lyx` erlaubt User-Dokumentation. |
