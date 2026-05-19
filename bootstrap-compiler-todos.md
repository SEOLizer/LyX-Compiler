# Bootstrap-Compiler Fahrplan: S2 → vollständige S0-Parität

Dieses Dokument beschreibt alle Arbeitspakete (WPs), die nötig sind, um den
Bootstrap-Compiler (S2/S3, `bootstrap/`) auf den vollständigen Funktionsumfang
des FPC-kompilierten Referenz-Compilers (S0, `compiler/`) zu bringen.

**Stand:** S3 ist self-hosted und stabil. S2 kompiliert sich selbst korrekt
(S3 == S4 byte-identisch). Der Abstand zu S0 liegt hauptsächlich in fehlenden
Sprachfeatures, Backends, Analyse-Passes und den Tooling-Schichten.

**Konvention:** WP-BC-NN (Bootstrap Compiler, Nummer). Jedes WP enthält
genaue Dateinamen aus `bootstrap/` oder `compiler/` als Referenz.

---

## Phase 1 — IR & Codegen-Vervollständigung (kleine Lücken)

### WP-BC-01: Fehlende IR-Opcodes implementieren ✅

**Status:** Erledigt — Branch `feat/wp-bc-01-assert-sqrt-builtins`, Singularität bestätigt.

**Ziel:** Die IR-Opcode-Tabelle von S2 (`bootstrap/ir.lyx`) auf vollständige
S0-Parität bringen.

**Fehlende Opcodes (S0 `compiler/ir/ir.pas` hat sie, S2 nicht):**

| Opcode | Beschreibung | S0-Zeile |
|--------|-------------|----------|
| `irMove` | Kopier-Instruktion (für Strength Reduction, Copy Propagation) | ir.pas:22 |
| `irFSqrt` | Floating-Point Quadratwurzel | ir.pas:25 |
| `irLoadStructAddr` | Basisadresse eines struct-Locals laden (benötigt StructSize) | ir.pas:33 |
| `irAssertBounds` | Bounds-Check: `assert(0 <= Src1 < ImmInt)`, panic bei Fehler | ir.pas:84 |
| `irAssertNotNull` | Null-Check: `assert(Src1 != 0)` | ir.pas:85 |
| `irAssertNotZero` | Zero-Check: `assert(Src1 != 0)` | ir.pas:86 |
| `irAssertTrue` | Boolean-Check: `assert(Src1 != 0)` | ir.pas:87 |

**Zu tun:**
- `IRO_MOVE`, `IRO_FSQRT`, `IRO_LOAD_STRUCT_ADDR` in `bootstrap/ir.lyx` eintragen
- `IRO_ASSERT_BOUNDS`, `IRO_ASSERT_NOT_NULL`, `IRO_ASSERT_NOT_ZERO`, `IRO_ASSERT_TRUE` eintragen
- Lowering in `bootstrap/ir_lower.lyx` für alle neuen Opcodes
- Codegen in `bootstrap/codegen_x86.lyx`: `irFSqrt` → `sqrtsd` (SSE2), Assert* → `test`+`je panic_label`
- S3 self-hosting nach dem WP verifizieren

---

### WP-BC-02: Fehlende Built-in-Funktionen ✅

**Status:** Erledigt — Branch `feat/wp-bc-02-missing-builtins`, S2=S3 sha256 `195a48f6…`.

**Ziel:** Alle Built-ins aus `compiler/frontend/builtins.pas` in S2 verfügbar
machen.

**In S0, aber nicht in S2 (`bootstrap/codegen_x86.lyx`):**

| Funktion | Signatur | Namespace |
|----------|----------|-----------|
| `PrintFloat` | `(f64) → void` | IO |
| `Println` | `(pchar) → void` | IO |
| `printf` | `(pchar, ...) → void` (varargs) | IO |
| `unlink` | `(pchar) → int64` | IO |
| `rename` | `(pchar, pchar) → int64` | IO |
| `mkdir` | `(pchar, int64) → int64` | IO |
| `rmdir` | `(pchar) → int64` | IO |
| `ioctl` | `(int64, int64, int64) → int64` | IO |
| `exit` | `(int64) → void` | OS |
| `getpid` | `() → int64` | OS |
| `Random` | `() → int64` | Math |
| `RandomSeed` | `(int64) → void` | Math |
| `str_concat` | `(pchar, pchar) → pchar` | — |
| `StrNew` | `(int64) → pchar` | — |
| `StrFree` | `(pchar) → void` | — |
| `StrSetChar` | `(pchar, int64, int64) → void` | — |
| `StrAppend` | `(pchar, pchar) → pchar` | — |
| `StrAppendStr` | `(pchar, pchar) → pchar` | — |
| `StrConcat` | `(pchar, pchar) → pchar` | — |
| `StrCopy` | `(pchar) → pchar` | — |
| `StrFromInt` | `(int64) → pchar` | — |
| `IntToStr` | `(int64) → pchar` | — |
| `StrFindChar` | `(pchar, int64, int64) → int64` | — |
| `StrStartsWith` | `(pchar, pchar) → bool` | — |
| `StrEndsWith` | `(pchar, pchar) → bool` | — |
| `StrEquals` | `(pchar, pchar) → bool` | — |
| `FileGetSize` | `(pchar) → int64` | — |
| `HashNew` | `(int64) → pchar` | — |
| `HashSet` | `(pchar, pchar, int64) → void` | — |
| `HashGet` | `(pchar, pchar) → int64` | — |
| `HashHas` | `(pchar, pchar) → bool` | — |
| `GetArgC` | `() → int64` | — |
| `GetArg` | `(int64) → pchar` | — |
| `breakpoint` | `() → void` | — |
| `profile_enter` | `(pchar) → void` | — |
| `profile_leave` | `(pchar) → void` | — |
| `profile_report` | `() → void` | — |
| `trace` | `(pchar) → void` | — |
| `trace_int` | `(int64) → void` | — |
| `trace_str` | `(pchar, pchar) → void` | — |

**Zu tun:**
- `cg_genCall` in `bootstrap/codegen_x86.lyx` um alle fehlenden Fälle erweitern
- Implementierungen als inline-Syscall-Sequenzen oder Thunk-Code generieren
- `profile_*` und `trace_*` können zunächst als Stubs (NOP) implementiert werden

---

### WP-BC-03: Optimizer — Unreachable-Block-Elimination ✅

**Status:** Erledigt — Branch `feat/wp-bc-03-unreachable-blocks`, S2=S3 sha256 `ec849307…`.

**Ziel:** `EliminateUnreachableBlocks` aus S0 (`compiler/ir/ir_optimize.pas:450`)
in S2 implementieren.

S2 (`bootstrap/ir_optimize.lyx`) hat bereits: constant folding, dead code
elimination, copy propagation, CSE, strength reduction, redundant-load-removal,
merge-stores. Fehlend: das Entfernen von Code, der nach einem unbedingten
`irJmp`/`irFuncExit` steht (dead basic blocks).

**Zu tun:**
- `fn eliminateUnreachableBlocks()` in `bootstrap/ir_optimize.lyx` implementieren
- CFG-Traversal: alle von `IRO_JMP` / `IRO_FUNC_EXIT` nicht erreichbaren Blöcke
  entfernen
- Im `optimize()`-Aufruf nach DCE einreihen

---

## Phase 2 — Sprachfeatures (mittlerer Aufwand)

### WP-BC-04: `repeat..until`-Schleife ✅

**Status:** Erledigt — Branch `feat/wp-bc-04-repeat-until`, S2=S3 sha256 `6fae4c3a…`.

**Ziel:** `repeat { body } until (cond)` parsen und codegenieren.

**Referenz:** S0 `nkRepeatUntil` in `compiler/frontend/ast.pas:130`,
`compiler/frontend/parser.pas:1541`, `compiler/ir/lower_ast_to_ir.pas`

**Zu tun:**
- Token `TK_REPEAT` (41) und `TK_UNTIL` (42) sind bereits in `bootstrap/lexer.lyx`
- Parser: `ParseRepeatUntilStmt` in `bootstrap/parser.lyx` implementieren
- `NK_REPEAT_UNTIL` in Sema-Checker `bootstrap/sema.lyx`
- IR-Lowering: Schleifenblock → Cond-Check am Ende (prüfe nach body)
- Codegen in `bootstrap/codegen_x86.lyx`

---

### WP-BC-05: Tupel-Typen und Tupel-VarDecl ✅

**Status:** Erledigt — Branch `feat/wp-bc-05-tuple-vardecl`, S2=S3 sha256 `d7075675…`.

**Ziel:** Multi-Return-Tupel `(T1, T2)` sowie `var a, b := fn()` unterstützen.

**Referenz:** S0 `atTuple`, `nkTupleLit`, `nkTupleVarDecl` in
`compiler/frontend/ast.pas:36,123,134`

**Zu tun:**
- `TY_TUPLE` in `bootstrap/sema.lyx` definieren
- `nkTupleLit`: Parser-Erweiterung für `(expr, expr, ...)`
- `nkTupleVarDecl`: `var a, b := expr` dekonstruiert Tupeltyp
- Sema: Tupel-Typprüfung (gleiche Stelligkeit, kompatible Elementtypen)
- IR-Lowering: Tupel als sequentielle temporäre Variablen (ABI: via Stack/Registers)
- Codegen: Rückgabe mehrerer Werte im SysV ABI (rax + rdx für 2 Werte)

---

### WP-BC-06: Map/Set-Literale und `in`-Operator ✅

**Status:** Erledigt — Branch `feat/wp-bc-06-map-set-in`, S2=S3 sha256 `74c86b27…`.

**Ziel:** `{"key": val}` Map-Literale, `{1, 2, 3}` Set-Literale und
`x in collection` Containment-Operator.

**Referenz:** S0 `nkMapLit`, `nkSetLit`, `nkInExpr` in
`compiler/frontend/ast.pas:126`

**Zu tun:**
- Parser: Map-Literal `{ expr: expr, ... }` und Set-Literal `{ expr, ... }`
- Parser: `in`-Operator (Token `TK_IN` = 64, bereits in Lexer)
- Sema: Typprüfung für Map/Set-Literale
- IR-Lowering: Map-Literal → Folge von `IRO_MAP_NEW` + `IRO_MAP_SET`-Calls;
  Set-Literal → `IRO_SET_NEW` + `IRO_SET_ADD`; `in` → `IRO_MAP_CONTAINS` /
  `IRO_SET_CONTAINS`
- S2 hat `IRO_MAP_*` und `IRO_SET_*` bereits definiert (ir.lyx:160–172)

---

### WP-BC-07: `assert` und `check`-Statements ✅

**Status:** Erledigt — Branch `feat/wp-bc-07-assert-sema`, Singularität bestätigt.

**Ziel:** `assert(cond)` und `check(expr)` als Sprachkonstrukte.

**Referenz:** S0 `nkAssert` (`compiler/frontend/ast.pas:132`),
`nkCheck` (Ausdrucks-Form)

**Zu tun:**
- `TK_ASSERT` (59) ist bereits in `bootstrap/lexer.lyx`
- Parser: `assert(cond)` → `nkAssert`-Node
- Sema: `cond` muss bool-Typ haben
- IR-Lowering: → `IRO_ASSERT_TRUE` + Panic-String als ImmStr
- Codegen: bereits via WP-BC-01

---

### WP-BC-08: `dispose`-Statement ✅

**Status:** Erledigt — Branch `feat/wp-bc-08-dispose`, Singularität bestätigt.

**Ziel:** `dispose obj` für manuelle Klassen-Objekt-Freigabe.

**Referenz:** S0 `nkDispose` (`compiler/frontend/ast.pas:132`,
`compiler/frontend/parser.pas`), `TK_DISPOSE` = 52

**Zu tun:**
- Token `TK_DISPOSE` (52) bereits in Lexer
- Parser: `dispose expr` → `nkDispose`
- Sema: `expr` muss ein Klassentyp sein
- IR-Lowering: → Destruktor-Aufruf (falls vorhanden) + `IRO_FREE`
- Codegen: bereits funktionsfähig

---

### WP-BC-09: `pool`-Statement ✅

**Status:** Erledigt — Branch `feat/wp-bc-09-pool`, S2=S3 sha256 `9183bfdb…`.

**Ziel:** `pool { ... }` für scoped Pool-Allokationen.

**Referenz:** S0 `nkPool` (`compiler/frontend/ast.pas:130`), `TK_POOL` = 43

**Zu tun:**
- Token `TK_POOL` (43) bereits in Lexer
- Parser: `pool { stmt* }` → `nkPool`
- Sema: alle `pool_alloc`-Calls im Block werden dem Pool zugeordnet
- IR-Lowering: Scope-Eintritt → `IRO_POOL_ALLOC`-Marker; Scope-Austritt →
  `IRO_POOL_FREE` (bereits in `bootstrap/ir.lyx:115–116`)

---

### WP-BC-10: `panic`-Ausdruck ✅

**Status:** Erledigt — Branch `feat/wp-bc-10-panic`, S2=S3 sha256 `7cb895ec…`.

**Ziel:** `panic("message")` als Expressions-Statement.

**Referenz:** S0 `nkPanic` (`compiler/frontend/ast.pas:125`)

**Zu tun:**
- `TK_PANIC` (58) bereits in Lexer
- Parser: `panic(strExpr)` → `nkPanic`; Rückgabetyp: `void` (never)
- Sema: Typ ist `never` / beliebig (kann in jedem Typ-Kontext stehen)
- IR-Lowering: → `IRO_PANIC` (bereits in `bootstrap/ir.lyx:139`)
- Codegen: S2 hat `panic` bereits als Built-in (`cg_seq "panic"`)

---

### WP-BC-11: `match`-Statement Verbesserungen ✅

**Status:** Erledigt — Branch `feat/wp-bc-11-match-improvements`, S2=S3 sha256 `5ed83bdc…`.

**Ziel:** Vollständige Pattern-Matching-Semantik wie in S0.

**Referenz:** S0 `ParseMatchStmt` in `compiler/frontend/parser.pas:1619`,
`ParseMatchPattern` in parser.pas:1690

**S2 hat bereits:** Basis-match, Wildcard, Literal-Patterns, Enum-Destrukturierung.

**Fehlend in S2:**
- Exhaustiveness-Check: Prüfung ob alle Enum-Varianten abgedeckt sind
- Or-Patterns: `case 1 | 2 | 3:` mehrere Muster in einem Case
- Pattern-Guards: `case x if x > 0:` zusätzliche Bedingung
- Struct-Destrukturierung: `case Point{x, y}:`
- Nested Patterns: `case Some(Some(x)):`

**Zu tun:**
- Sema-Pass: nach Typanalyse Exhaustiveness-Check für Enum-Match
- Parser: `|`-getrennte Pattern-Liste pro Case
- Parser: `if guard`-Syntax nach Pattern
- Sema: Guard-Ausdrucks-Typcheck (muss bool sein)

---

### WP-BC-12: `for`-Schleife (Range-basiert) ✅

**Status:** Erledigt — Branch `feat/wp-bc-12-for-range`, S2=S3 sha256 `48a6bbc5…`.

**Ziel:** `for i := 0 to n { }` und `for i := n downto 0 { }` vollständig
implementieren.

**Referenz:** S0 `nkFor` (`compiler/frontend/ast.pas:130`), `TK_TO` = 38,
`TK_DOWNTO` = 39

**S2 hat bereits:** `TK_FOR`, `TK_TO`, `TK_DOWNTO` im Lexer.

**Zu tun:**
- Parser: `for ident := expr to/downto expr { body }` in `bootstrap/parser.lyx`
  (note: `to` ist TK_TO = 38, kein reserviertes Schlüsselwort-Problem in S2
  da es im Parser-Kontext nach `to` korrekt behandelt wird)
- Sema: Schleifenvariable als `int64` deklarieren, Bound-Typ prüfen
- IR-Lowering: → Init + Vergleich + Inkrement/Dekrement + Branch
- Codegen: bereits via standard while-Loop-Codegen abgedeckt

---

### WP-BC-13: Format-Ausdruck (Pascal-Style) ✅

**Status:** Erledigt — Branch `feat/wp-bc-13-format-expr`, S2=S3 sha256 `e4560edb…`.

**Ziel:** `expr:width:decimals` für formatierte Ausgabe.

**Referenz:** S0 `nkFormatExpr` in `compiler/frontend/ast.pas:145`,
`compiler/frontend/parser.pas:2994`

**Zu tun:**
- Parser: Nachbearbeitung von Primärausdrücken — wenn auf `expr` ein `:` folgt
  und danach ein Integer-Literal, als `nkFormatExpr` parsen
- Sema: width und decimals müssen Integer-Konstanten sein
- IR-Lowering: → sprintf-ähnliche Darstellung oder formatierter PrintFloat-Call
- Codegen: Format-String on-the-fly generieren

---

## Phase 3 — Typsystem-Erweiterungen

### WP-BC-14: Nullable Pointer-Typ (`pchar?`) ✅

**Status:** Erledigt — Branch `feat/wp-bc-14-nullable-pchar`, S2=S3 sha256 `07637c91…`.

**Ziel:** `atPCharNullable` — optionaler Pointer-Typ für Null-Safety.

**Referenz:** S0 `atPCharNullable` in `compiler/frontend/ast.pas:28`,
Null-Coalescing `??`-Operator (`TK_NULLCOALESCE`), `as?`-Cast

**Zu tun:**
- `TY_PCHAR_NULLABLE` in `bootstrap/sema.lyx` definieren
- Parser: `pchar?` als Typannotation
- Sema: `pchar?` und `pchar` sind inkompatibel ohne expliziten Check
- Sema: `x ?? fallback` → wenn x null → fallback; sonst → x
- Sema: `x as? T` → optional cast
- IR-Lowering: `??` → compare-null + select
- Codegen: identisch mit regulärem Pointer

---

### WP-BC-15: Regex-Literale ✅

**Status:** Erledigt — Branch `feat/wp-bc-15-regex-literals`, S2=S3 sha256 `50fef23a…`.

**Ziel:** `r"pattern"` Regex-Literal als eigener Typ.

**Referenz:** S0 `nkRegexLit` in `compiler/frontend/ast.pas:121`,
`compiler/frontend/regex_engine.pas`

**Zu tun:**
- Lexer: `r"..."` Syntax → `TK_REGEX_LIT` (oder als nkRegexLit-Node)
- Sema: Regex-Literal-Typ (vorerst `pchar` mit Regex-Semantik)
- IR-Lowering: Regex-String als Konstante in Data-Section; ggf. Kompilierung
  via Runtime-Regex-Engine

---

### WP-BC-16: Dimensionsanalyse / Einheiten-Typsystem ✅

**Status:** Erledigt — Branch `feat/wp-bc-16-dim-utype`, S2=S3 sha256 `527f7c71…`.

**Ziel:** `dim`, `utype` und Einheits-kompatible Typen (z.B. für Luft- und
Raumfahrt-Code).

**Referenz:** S0 `GetDimForUnitTag`, `GetDimNameForExpr`, `ComputeResultUnitTag`,
`GetUtypeRangeInfo` in `compiler/frontend/sema.pas:1467–1591`

**Zu tun:**
- Token `TK_DIM`, `TK_UTYPE` im Lexer definieren
- Parser: `dim Length: f64` und `utype Meters: Length` Deklarationen
- Sema: Einheiten-Kompatibilitätsprüfung bei Arithmetik
- Sema: Bereichs-Validierung für utype-Variablen (min/max aus Deklaration)
- IR-Lowering: vorerst identisch mit `f64` (Einheits-Info nur zur Compilezeit)

---

### WP-BC-17: Ring-Buffer-Typ ✅

**Status:** Erledigt — Branch `feat/wp-bc-17-ringbuffer`, S2=S3 sha256 `3edc9255…`.

**Ziel:** `atRingBuffer` — lock-freier Ring-Buffer als First-Class-Typ.

**Referenz:** S0 `atRingBuffer` in `compiler/frontend/ast.pas:34`

**Zu tun:**
- `TY_RING_BUFFER` in `bootstrap/sema.lyx`
- Parser: `RingBuffer<T>` Typsyntax
- Sema: Typprüfung für push/pop/len-Operationen
- IR-Lowering: Implementierung als Built-in-Inline-Operationen
- Codegen: atomare Load/Store-Sequenzen (LOCK XADD etc.)

---

### WP-BC-18: SIMD / Parallel-Array-Typ ✅

**Status:** Erledigt — Branch `feat/wp-bc-18-simd-parallel`, S2=S3 sha256 `0224ba54…`.

**Ziel:** `atParallelArray` — SIMD-Vektor-Typ mit expliziter Hardware-Nutzung.

**Referenz:** S0 `atParallelArray` in `compiler/frontend/ast.pas:33`;
`IRO_SIMD_*` bereits in `bootstrap/ir.lyx:142–157`

**Zu tun:**
- `TY_PARALLEL_ARRAY` in `bootstrap/sema.lyx`
- Parser: `parallel [N]T` Typsyntax (oder `@parallel` Annotation)
- Sema: Typprüfung für SIMD-Operationen
- Codegen: SSE2/AVX2-Instruktionen für `IRO_SIMD_*` emittieren
  (S2 hat alle SIMD-Opcodes definiert, aber Codegen fehlt)
- x86_64: `movdqu`/`paddd`/`vaddps` etc. je nach Breite

---

## Phase 4 — OOP & Generics vervollständigen

### WP-BC-19: Vollständige VMT-Konstruktion ✅

**Status:** Erledigt — Branch `feat/wp-bc-19-vmt-construction`, Singularität bestätigt sha256 `0f15b8c6…`.

**Ziel:** Vollständige Virtual-Method-Table-Generierung wie in S0.

**Referenz:** S0 `ResolveVMTForClasses` in `compiler/frontend/sema.pas:4665`,
`RegisterInheritedMethods` in sema.pas:4889,
VMT-Patching in `compiler/backend/x86_64/x86_64_emit.pas`

**S2 hat bereits:** Basis-VMT-Infrastruktur für einfache Klassenvererbung.

**Fehlend in S2:**
- Vollständige Vererbungskette mit N Ebenen
- `super.method()` Auflösung
- Kovariant-Rückgabe-Checks
- Geerbte Methoden im VMT korrekt eingetragen

**Zu tun:**
- `sema.lyx`: Multi-Level-Inheritance-Traversal für VMT-Slots
- `sema.lyx`: Eltern-Methoden in VMT eintragen wenn Kind sie nicht überschreibt
- `codegen_x86.lyx`: VMT-Patch-Adressen korrekt berechnen (absolute VA)
- Sema: `override`-Keyword-Prüfung (Signatur muss übereinstimmen)

---

### WP-BC-20: Abstrakte Klassen und Methoden ✅

**Status:** Erledigt — Branch `feat/wp-bc-20-abstract-classes`, Singularität bestätigt sha256 `2bc17547…`.

**Ziel:** `abstract` Klassen und Methoden erzwingen Implementierungspflicht.

**Referenz:** S0 `TK_ABSTRACT` = 67; `IsAbstract`-Flag in Sema

**Zu tun:**
- Token `TK_ABSTRACT` (67) bereits in Lexer
- Parser: `abstract fn name(...)` → `IsAbstract`-Flag im FuncDecl-Node
- Parser: `abstract class` → Klasse kann nicht direkt instanziiert werden
- Sema: Prüfung dass alle abstrakten Methoden in konkreten Subklassen
  implementiert werden
- Sema: Fehler bei `new AbstractClass()`

---

### WP-BC-21: Interface-Vertragsprüfung ✅

**Status:** Erledigt — Branch `feat/wp-bc-21-interface-contract`, Singularität bestätigt sha256 `a81c5adc…`.

**Ziel:** Vollständige Prüfung ob Klasse alle Interface-Methoden implementiert.

**Referenz:** S0 `CheckMemberAccess`, Interface-Auflösung in
`compiler/frontend/sema.pas:4415`

**S2 hat bereits:** Basis-Interface-Deklaration und -Parsing.

**Fehlend:**
- Sema-Pass: prüft für jede `class C implements I`-Deklaration ob alle
  Methoden von `I` in `C` vorhanden sind
- Korrekte Fehlerausgabe mit Methodennamen
- Mehrfach-Interface-Implementierung (`implements I1, I2, I3`)

---

### WP-BC-22: Sichtbarkeits-Checks (private/protected/public) ✅

**Status:** Erledigt — Branch `feat/wp-bc-22-visibility-checks`, Singularität bestätigt sha256 `6f33da06…`.

**Ziel:** `private`, `protected` und `pub` Zugriffsmodifikatoren erzwingen.

**Referenz:** S0 `TVisibility` + `CheckMemberAccess` in `compiler/frontend/sema.pas:4415`

**Zu tun:**
- Sema: bei Feldzugriff `obj.field` prüfen ob `field` im Kontext sichtbar ist
- `private`: nur innerhalb der eigenen Klasse
- `protected`: Klasse + Subklassen
- `pub`: überall (Default-Verhalten heute)
- Fehler: "Feld X ist private"

---

### WP-BC-23: Generics — Constraints und `where`-Klauseln ✅

**Status:** Erledigt — Branch `feat/wp-bc-23-generic-constraints`, Singularität bestätigt sha256 `4f754437…`.

**Ziel:** Typ-Parameter-Bounds und `where T: Interface`-Constraints prüfen.

**Referenz:** S0 `MonomorphizeStruct` in `compiler/frontend/sema.pas:1627`,
`ResolveTypeAlias` in sema.pas:1615

**S2 hat bereits:** Basis-Generic-Deklaration (`fn foo[T](...)`) und einfache
Monomorphisierung (WP-14).

**Fehlend:**
- `where T: SomeInterface` Constraint-Syntax
- Sema: bei Generics-Instanziierung prüfen ob `T` alle Constraints erfüllt
- Vollständige Monomorphisierung (Körper kopieren + Typen einsetzen)
- Generic-Structs mit Methoden vollständig instanziieren

---

### WP-BC-24: Vollständige Generic-Monomorphisierung mit Codegen ✅

**Status:** Erledigt — Branch `feat/wp-bc-24-generic-monomorphization`, Singularität bestätigt sha256 `c834945d…`.

**Ziel:** Für jede Generic-Instanziierung eigenen Maschinencode generieren.

**Referenz:** `MonomorphizeStruct` generiert neuen `TAstStructDecl`; der
Codegen emittiert für jede Instanz eine eigene Funktion.

**S2 hat bereits:** Cache für instanziierte generische Funktionen (sema.lyx:189).

**Fehlend:**
- Vollständiges Kopieren des Funktions-/Struct-Körpers mit Typ-Substitution
- Vermeidung von Duplikat-Instanziierungen bei gleichen Typargumenten
- Generische Methoden auf generischen Structs

---

## Phase 5 — Analyse-Werkzeuge

### WP-BC-25: DWARF Debug-Info-Generierung ✅

**Status:** Erledigt — Branch `feat/wp-bc-25-dwarf-debug-info`, Singularität `6e24fd5d…`.

**Ziel:** `.debug_info`, `.debug_line`, `.debug_frame`, `.debug_abbrev`,
`.debug_str`-Sektionen in der erzeugten ELF-Datei.

**Referenz:** S0 `compiler/ir/dwarf_gen.pas` (528 Zeilen)

**Zu tun:**
- Neue Datei `bootstrap/dwarf_gen.lyx` implementieren
- LEB128-Encoding-Funktionen (signed + unsigned)
- DWARF-Abbreviation-Table für Compilation Unit + Subprogram + Variable
- Line-Number-Programm (DWARF Standard Section 6.2)
- `.debug_frame` mit CFA-Regeln für x86_64 (RSP/RBP-Tracking)
- ELF-Writer in `codegen_x86.lyx` um Debug-Sektionen erweitern
- Zeilennummern aus AST-Spans durchpropagieren
- CLI-Flag `--debug` / `-g`

---

### WP-BC-26: Call-Graph-Analyse ✅

**Status:** Erledigt — Branch `feat/wp-bc-26-call-graph`, Singularität `c42798d4…`.

**Ziel:** Vollständiger statischer Call-Graph wie in S0.

**Referenz:** S0 `compiler/ir/ir_call_graph.pas` (260 Zeilen)

**Zu tun:**
- Neue Datei `bootstrap/ir_call_graph.lyx`
- AST-Traversal: alle Funktionsaufrufe erfassen
- Direkte und indirekte (Funktionszeiger) Kanten
- Rekursionserkennung (direkt + indirekt)
- Erreichbarkeits-Analyse von `main` aus
- Ausgabe: unused-functions-Warnung
- Integration in Inliner (`bootstrap/ir_inline.lyx`): Rekursive Funktionen
  werden nicht inlined (bereits vorhanden, aber mit rudimentärem Callgraph)

---

### WP-BC-27: Statische Analyse

**Ziel:** Datenfluss-, Null-Pointer-, Bounds- und Terminierungsanalyse.

**Referenz:** S0 `compiler/ir/ir_static_analysis.pas` (690 Zeilen)

**Zu tun:**
- Neue Datei `bootstrap/ir_static_analysis.lyx`
- `AnalyzeDataFlow`: Use-Def-Chains, uninitialisierte Variablen erkennen
- `AnalyzeLiveVariables`: Liveness-Analyse (Grundlage für Register-Allokator)
- `AnalyzeConstantPropagation`: Konstantenwerte durch Datenfluss verfolgen
- `AnalyzeNullPointers`: Null-Dereference-Kandidaten erkennen
- `AnalyzeArrayBounds`: Potenzielle Out-of-Bounds-Zugriffe melden
- `AnalyzeTermination`: Funktionen die nicht immer einen Wert zurückgeben
- `AnalyzeStackUsageWithCallGraph`: maximale Stack-Tiefe berechnen

---

### WP-BC-28: MC/DC Coverage-Instrumentierung

**Ziel:** Modified Condition/Decision Coverage für Safety-kritischen Code.

**Referenz:** S0 `compiler/ir/ir_mcdc.pas` (300 Zeilen)

**Zu tun:**
- Neue Datei `bootstrap/ir_mcdc.lyx`
- Entscheidungspunkte (if/while/match) im IR identifizieren
- `IRO_CALL_BUILTIN`-Instruktionen für Coverage-Datenpunkte einfügen
- Runtime-Coverage-Daten in separatem ELF-Segment ablegen
- Report-Generierung: Coverage-Prozentsatz pro Funktion
- CLI-Flag `--mcdc`

---

### WP-BC-29: Vollständiger Linter

**Ziel:** Style-Checks und Warnungen wie in S0.

**Referenz:** S0 `compiler/frontend/linter.pas` (~700 Zeilen)

**Regeln aus S0 (alle in `bootstrap/` fehlend):**
- `naming-function`: Funktionsnamen müssen camelCase sein
- `naming-variable`: Variablennamen müssen camelCase sein
- `empty-function`: Leere Funktionen warnen
- `recursive-function`: Rekursive Funktionen markieren
- `function-too-long`: Funktionen über N Zeilen
- `complex-function`: zu viele Verzweigungen (Cyclomatic Complexity)
- `unused-variable`: deklarierte aber nie gelesene Variablen
- `unused-import`: importierte Units, die nichts verwenden
- `implicit-cast`: implizite Integer-Erweiterung
- `dead-code`: Code nach `return`/`panic`

**Zu tun:**
- Neue Datei `bootstrap/linter.lyx`
- AST-Traversal mit Scope-Stack
- Pro-Symbol: read/write-Counter
- CLI-Flag `--lint` / `--no-lint`

---

### WP-BC-30: C-Header-Parser (FFI)

**Ziel:** `#include`-artige C-Header-Deklarationen für FFI.

**Referenz:** S0 `compiler/frontend/c_header_parser.pas` (300 Zeilen)

**Zu tun:**
- Neue Datei `bootstrap/c_header_parser.lyx`
- Einfacher C-Typ-Parser: `int`, `long`, `char*`, `void`, `struct` etc.
- `extern fn` Deklarationen aus `.h`-Dateien generieren
- `MapCTypeToLyx`-Funktion: C-Typ → Lyx-Typ (z.B. `char*` → `pchar`)
- Präprozessor-Direktiven `#define` / `#ifdef` überspringen
- CLI-Flag `--include header.h`

---

## Phase 6 — Multi-Architektur-Backends

### WP-BC-31: macOS x86_64 Backend

**Ziel:** Mach-O-Binaries für macOS (Intel) generieren.

**Referenz:** S0 `compiler/backend/macosx64/macosx64_emit.pas` (3.379 Zeilen),
`compiler/backend/macho/macho64_writer.pas`

**Zu tun:**
- Neue Datei `bootstrap/backend/macos_x86.lyx`
- Mach-O-64-Format: Header, Load Commands (`LC_SEGMENT_64`, `LC_UNIXTHREAD`,
  `LC_DYSYMTAB`)
- BSD-Syscall-Nummern (0x2000000-Prefix): `write`=4, `exit`=1, `mmap`=197, etc.
- System V AMD64 ABI (gleich wie Linux): nur Syscall-Interface unterscheidet sich
- Linking: keine PLT/GOT nötig für statische Binaries
- CLI-Flag `--target macos-x86_64`

---

### WP-BC-32: Windows x86_64 Backend (PE64)

**Ziel:** PE64-Binaries (.exe) für Windows 64-bit.

**Referenz:** S0 `compiler/backend/pe/pe64_writer.pas`,
`compiler/backend/x86_64/x86_64_win64.pas`

**Zu tun:**
- Neue Datei `bootstrap/backend/win_x86.lyx`
- PE64-Format: DOS-Stub, PE-Header, Optional Header, Section Table
- `.text`, `.data`, `.rdata`, `.idata` (Import Table) Sektionen
- Windows x64 ABI: RCX/RDX/R8/R9 für erste 4 Integer-Args (statt SysV),
  32-byte Shadow Space auf dem Stack
- Import Table für `kernel32.dll`: `WriteFile`, `ExitProcess`, `VirtualAlloc`
- Kein syscall — alle OS-Calls via Windows API (IAT)
- CLI-Flag `--target windows-x86_64`

---

### WP-BC-33: ARM64/AArch64 Linux Backend

**Ziel:** ELF64-Binaries für ARM64 (AArch64) Linux.

**Referenz:** S0 `compiler/backend/arm64/arm64_emit.pas` (5.429 Zeilen),
`compiler/backend/elf/elf64_arm64_writer.pas`

**Zu tun:**
- Neue Datei `bootstrap/backend/arm64_linux.lyx`
- AArch64 Instruction Encoding (32-bit fixed-width)
- Basis-Instruktionen: `MOV`/`MOVZ`/`MOVK`, `ADD`/`SUB`/`MUL`, `LDR`/`STR`,
  `B`/`BL`/`CBZ`/`CBNZ`, `SVC #0` für Syscalls
- Linux AArch64 ABI: x0–x7 für Argumente, x8 für Syscall-Nummer
- Linux ARM64 Syscall-Nummern: `write`=64, `exit`=93, `mmap`=222, etc.
- ELF64-ARM64-Header (e_machine = 0xB7 = EM_AARCH64)
- Stack-Frame: FP (x29) + LR (x30)
- CLI-Flag `--target linux-arm64`

---

### WP-BC-34: ARM64 macOS (Apple Silicon) Backend

**Ziel:** Mach-O-ARM64-Binaries für Apple Silicon (M1/M2/M3).

**Referenz:** S0 `compiler/backend/arm64/arm64_emit.pas` mit macOS-Zweig

**Zu tun:**
- Aufbauend auf WP-BC-31 (Mach-O) und WP-BC-33 (AArch64 Codegen)
- BSD-Syscall-Nummern für XNU ARM64 (0x80000000-Prefix)
- `svc #0x80` für Syscalls (statt `svc #0` unter Linux)
- Mach-O ARM64: `cputype = 0x0100000C` (CPU_TYPE_ARM64)
- CLI-Flag `--target macos-arm64`

---

### WP-BC-35: Windows ARM64 Backend

**Ziel:** PE64-ARM64-Binaries (.exe) für Windows on ARM.

**Referenz:** S0 `compiler/backend/win_arm64/win_arm64_emit.pas` (3.547 Zeilen),
`compiler/backend/win_arm64/pe64_arm64_writer.pas`

**Zu tun:**
- Aufbauend auf WP-BC-32 (PE64) und WP-BC-33 (AArch64 Codegen)
- Windows ARM64 ABI: x0–x7 für Args, Home Space (je 8 Bytes für x0–x3)
- PE64-Maschinen-Typ: `IMAGE_FILE_MACHINE_ARM64` = 0xAA64
- Import Table für `kernel32.dll` via ARM64-IAT-Stubs
- CLI-Flag `--target windows-arm64`

---

### WP-BC-36: RISC-V (RV64GC) Linux Backend

**Ziel:** ELF64-RISC-V-Binaries für RV64 Linux.

**Referenz:** S0 `compiler/backend/riscv/riscv_emit.pas` (1.601 Zeilen),
`compiler/backend/elf/elf64_riscv_writer.pas`

**Zu tun:**
- Neue Datei `bootstrap/backend/riscv_linux.lyx`
- RV64I Instruction Encoding: R/I/S/B/U/J-Format (32-bit)
- Basis-Instruktionen: `LUI`/`AUIPC`, `ADD`/`SUB`/`MUL`/`DIV`, `LW`/`LD`/`SW`/`SD`,
  `BEQ`/`BNE`/`BLT`/`BGE`, `JAL`/`JALR`, `ECALL`
- RISC-V LP64 ABI: a0–a7 für Argumente, a7 für Syscall-Nummer
- Linux RISC-V Syscall-Nummern: `write`=64, `exit`=93, `mmap`=222
- ELF64-RISC-V-Header (e_machine = 0xF3 = EM_RISCV)
- CLI-Flag `--target linux-riscv64`

---

### WP-BC-37: ARM Cortex-M (Bare Metal) Backend

**Ziel:** Thumb-2-ELF für ARM Cortex-M Mikrocontroller.

**Referenz:** S0 `compiler/backend/arm_cm/arm_cm_emit.pas` (1.521 Zeilen),
`compiler/backend/arm_cm/arm_cm_defs.pas`

**Zu tun:**
- Neue Datei `bootstrap/backend/arm_cm.lyx`
- Thumb-2 Instruction Encoding (16-bit + 32-bit gemischt)
- Basis-Instruktionen: `MOV`/`MOVW`/`MOVT`, `ADD`/`SUB`/`MUL`, `LDR`/`STR`,
  `B`/`BL`/`CBZ`, `SVC` für RTOS-Calls oder Bare-Metal-Traps
- ARM EABI: r0–r3 für Argumente, r14 = LR, r15 = PC
- ELF32-ARM-Header (e_machine = 0x28 = EM_ARM)
- Startup-Code: `.vectors`-Sektion mit Reset-Handler
- kein `mmap` — manuelle Heap-Verwaltung via `sbrk`-Äquivalent
- CLI-Flag `--target arm-cm4` / `--target arm-cm33`

---

### WP-BC-38: Xtensa (ESP32) Backend

**Ziel:** ELF32-Binaries für Xtensa LX6/LX7 (ESP32 / ESP32-S3).

**Referenz:** S0 `compiler/backend/xtensa/xtensa_emit.pas` (2.200 Zeilen),
`compiler/backend/esp32/elf32_writer.pas`

**Zu tun:**
- Neue Datei `bootstrap/backend/xtensa.lyx`
- Xtensa Instruction Encoding (24-bit oder 16-bit narrow)
- Basis-Instruktionen: `MOVI`/`MOV.N`, `ADD`/`SUB`/`MUL16S`, `L32I`/`S32I`,
  `BEQZ`/`BNEZ`/`J`/`CALL0`/`RET`
- ESP32 IDF Calling Convention: a2–a7 für Argumente, Windowed Registers
- ELF32-Xtensa: e_machine = 0x5E = EM_XTENSA
- `esp_idf_syscalls.lyx` für ESP-IDF API-Bindings
- CLI-Flag `--target esp32` / `--target esp32s3`

---

## Phase 7 — Spezialfunktionen

### WP-BC-39: `Inspect` In-Situ-Datenvisualisierer

**Ziel:** `Inspect(expr)` für interaktives Runtime-Debugging.

**Referenz:** S0 `nkInspect` in `compiler/frontend/ast.pas:127`;
`IRO_INSPECT` bereits in `bootstrap/ir.lyx:153`

**Zu tun:**
- Sema: `Inspect(expr)` für beliebige Typen (Sonderbehandlung wie in S0)
- IR-Lowering: `IRO_INSPECT` mit Typ-Info und Variablenname als ImmStr
- Codegen: Serialisierung des Wertes als lesbaren String + `write`-Syscall
- Für Struct-Typen: Felder mit Namen ausgeben
- Format: `[Inspect:varname@line] value` auf stderr

---

### WP-BC-40: Profiling-Infrastruktur

**Ziel:** `profile_enter`/`profile_leave`/`profile_report` als funktionale
Laufzeit-Profiling-Schicht.

**Referenz:** S0 `builtins.pas:103–105`

**S2 hat:** `profile_enter` und `profile_leave` als Built-in-Namen registriert,
aber keine Implementierung (aktuell: Stubs oder unimplementiert).

**Zu tun:**
- Codegen für `profile_enter(name)`: RDTSC lesen, Eintrag in Profil-Tabelle
- Codegen für `profile_leave(name)`: RDTSC lesen, Delta akkumulieren
- `profile_report()`: alle akkumulierten Daten nach stderr schreiben
- Profil-Tabelle: mmap-basierter Hash-Map im Data-Segment
- Format: `[PROFILE] funcname: N calls, X ns total, Y ns avg`

---

### WP-BC-41: LFD Qt-UI-Builder

**Ziel:** `Form`/`Widget`/`Layout`/`Signal`-Syntax für deklarative Qt5-UIs.

**Referenz:** S0 `compiler/ir/lfd_codegen.pas` (vollständig),
`compiler/frontend/ast.pas:61–152` (Widget/Layout/Signal-Typen)

**Unterstützte Widgets (wie S0):**
`Label`, `PushButton`, `CheckBox`, `RadioButton`, `LineEdit`, `TextEdit`,
`GroupBox`, `TabWidget`, `ScrollArea`, `StackedWidget`, `ComboBox`,
`ListWidget`, `TreeWidget`, `TableWidget`, `ProgressBar`, `Slider`,
`SpinBox`, `DateEdit`, `MenuBar`, `ToolBar`, `Action`, `Separator`, `Spacer`

**Unterstützte Layouts:** `Vertical`, `Horizontal`, `Grid`, `Form`

**Unterstützte Signale:**
`OnClick`, `OnToggle`, `OnChange`, `OnSelect`, `OnDblClick`, `OnReturn`,
`OnEditingFinished`

**Zu tun:**
- Neue Token im Lexer: `TK_FORM`, `TK_WIDGET`, `TK_LAYOUT`, `TK_SIGNAL`
- Parser: LFD-Syntax parsen → `nkLfdForm`-Node-Baum
- Neue Datei `bootstrap/lfd_codegen.lyx`
- `GenerateHeader(form)` → Qt5-C++-Header-Datei als String
- `GenerateSource(form)` → Qt5-C++-Implementierungs-Datei als String
- Ausgabe: `.h`+`.cpp` Dateipaar (kein Lyx→Binary-Codegen, da Qt5 C++ benötigt)
- Namens-Abbildung: `lfdPushButton` → `QPushButton`, etc.

---

## Prioritäten-Übersicht

```
╔══════════════════════════════════════════════════════════════════╗
║ Prio 1 (Sofort, einfach)        Prio 2 (Mittel, wichtig)        ║
║ WP-BC-01  Fehlende IR-Opcodes   WP-BC-05  Tupel-Typen            ║
║ WP-BC-02  Fehlende Built-ins    WP-BC-06  Map/Set-Literale       ║
║ WP-BC-03  Unreachable-Blocks    WP-BC-11  Match-Verbesserungen   ║
║ WP-BC-07  assert/check          WP-BC-12  for-Schleife           ║
║ WP-BC-10  panic-Ausdruck        WP-BC-14  Nullable pchar?        ║
║ WP-BC-04  repeat..until         WP-BC-19  VMT vollständig        ║
╠══════════════════════════════════════════════════════════════════╣
║ Prio 3 (Mittel, aufwändig)      Prio 4 (Groß, strategisch)      ║
║ WP-BC-20  Abstract classes      WP-BC-31  macOS x86_64           ║
║ WP-BC-21  Interface-Checks      WP-BC-32  Windows x86_64         ║
║ WP-BC-22  Sichtbarkeits-Checks  WP-BC-33  ARM64 Linux            ║
║ WP-BC-23  Generic Constraints   WP-BC-34  ARM64 macOS (M-Serie)  ║
║ WP-BC-24  Generic Monomorph.    WP-BC-35  Windows ARM64          ║
║ WP-BC-25  DWARF Debug-Info      WP-BC-36  RISC-V Linux           ║
║ WP-BC-26  Call-Graph            WP-BC-37  ARM Cortex-M           ║
║ WP-BC-27  Statische Analyse     WP-BC-38  Xtensa/ESP32           ║
║ WP-BC-29  Vollständiger Linter  WP-BC-41  LFD Qt-UI-Builder      ║
╠══════════════════════════════════════════════════════════════════╣
║ Prio 5 (Nice-to-have)                                            ║
║ WP-BC-08  dispose-Statement     WP-BC-16  Dim-Analyse            ║
║ WP-BC-09  pool-Statement        WP-BC-17  Ring-Buffer-Typ        ║
║ WP-BC-13  Format-Ausdruck       WP-BC-18  SIMD/Parallel-Array    ║
║ WP-BC-15  Regex-Literale        WP-BC-28  MC/DC Coverage         ║
║ WP-BC-30  C-Header-Parser       WP-BC-39  Inspect-Visualizer     ║
║                                 WP-BC-40  Profiling-Infra        ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## Abstand S2 ↔ S0 in Zahlen

| Kategorie | S0 | S2 heute | Lücke |
|-----------|-----|----------|-------|
| Lexer-Tokens | ~180 | ~170 | ~10 |
| AST-Knotenarten | 45+ | 40+ | ~10 |
| Typen | 18 | 15 | 3 |
| IR-Opcodes | 113 | 111 (+2 noch ungenutzt) | 7 |
| Optimierungspässe | 6 | 7 (S2 hat mehr als S0!) | 0 |
| Inlining-Passes | 1 | 1 | 0 |
| Built-in-Funktionen | 47 | 25 | ~22 |
| Backends (Architekturen) | 8 | 1 (x86_64 Linux) | 7 |
| Binary-Formate | 5 | 1 (ELF64 Linux) | 4 |
| DWARF-Debug-Info | Ja | Nein | 1 WP |
| Linter | Vollständig | Stub | 1 WP |
| Statische Analyse | Vollständig | Nein | 1 WP |
| MC/DC Coverage | Ja | Nein | 1 WP |
| C-Header-Parser | Ja | Nein | 1 WP |
| LFD Qt-UI-Builder | Vollständig | Nein | 1 WP |
| Call-Graph | Ja | Einfach | 1 WP |

**Gesamtanzahl WPs:** 41

**Geschätzte Reihenfolge bis vollständige Parität (ohne Multi-Backend):**
Phase 1–3: ~8–12 WPs → ~70% Sprach-Parität  
Phase 1–5: ~30 WPs → ~90% Parität (alle Sprachfeatures + Analyse)  
Phase 1–7: 41 WPs → 100% Parität
