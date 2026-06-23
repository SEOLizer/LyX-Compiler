# Changelog - Lyx Compiler

## Version 1.0.1A (Juni 2026)

Patch-Release auf Basis von V1.0.0A. Schwerpunkt: Sicherheits-Härtung, Korrektheit
und Erweiterung der Backend-/Nativ-Unterstützung.

### Security (Audit-Verifikationspass)
- FFI-Sandbox **fail-closed**: unbekannte Externs erfordern `@cap(...)`; PROCESS-Klasse
  + no-link-Pfad gehärtet (`FFI_CLASS_UNKNOWN`, TCB-Modell std.*/src.*).
- `calloc()` Integer-Overflow-Guard; alle `read()`-Pfade (inkl. `cg_readFile`) OOB-gehärtet.
- DNS-rdata-Doku-Hazard (64- vs 128-Byte-Puffer) behoben; TLS-Hostname-Verifikation
  per CI verankert. RandInt64 silent-0 → `exit(1)`.
- Jeder Fix mit CI-Regressionstest (sec_*-Suite).

### Korrektheit
- `--std-path=` Off-by-one (lieferte `=PATH`) behoben.
- Makefile-Paketversion synchronisiert.

### Backend / Nativ
- **ARM64-Backend wiederbelebt**: con-Namens-Kollision (Target-Routing), `_start`→main,
  lokales/nested Assignment, PrintInt, Arrays, Globals, plain structs + statische Methoden
  (qemu-verifiziert). x86 unverändert.
- **Nativer LYX!-Loader/Runtime** (`lbf_run`): LYX!-Datei laden + in-process ausführen
  (mmap RWX + Sprung). `_indirect_call_0/_1` im x86-Codegen.

Singularität S3==S4 erhalten; `make test` grün.

## Version 1.0.0A (Juni 2026)

Erste Alpha-Version (V1.0.0A) — vollständiger Sprachkern, self-hosting (Singularität),
echte OOP-Vererbung und Backend-Parität inkl. vollständigem Windows-PE32+-Target.
Enthält lyxc-Fix-Backlog L1–L6, WP-A2 (Windows), WP-28..37 (Security), V-1..3 und
BUG-1..8.

### OOP / Vererbung

- **L1 — Feld-Layout-Vererbung**: Felder einer Basisklasse werden in das Layout der abgeleiteten Klasse flach vorangestellt; geerbte Felder erhalten korrekte Offsets (`cg_buildClassLayout`/`cg_buildStructLayout`).
- **L2 — virtuelle Dispatch über Basis-Pointer**: `extends`-Parent korrekt erfasst (Parser `_sc2`-Setter-Bug); `override`/`abstract` implizieren `virtual`; virtuelle Methoden werden dynamisch über die vtable aufgerufen (`cg_genCall`); abgeleitete Klassen erben die vtable, `override` ersetzt den Slot, geerbte nicht-überschriebene Slots werden base→derived propagiert.

### Parser

- **L4 — `[N]T` Prefix-Array-Felder**: `kids: [4]Node;` wird geparst (führendes Integer-Literal nach `[` disambiguiert gegen Tuple-Typen); erzeugt denselben Array-Knoten wie die Suffix-Form `T[N]`.
- **L5 — `form` als Soft-Keyword**: `form` ist überall als normaler Bezeichner nutzbar; das Top-Level-`form`-Konstrukt wird kontextuell per Text erkannt.
- **L6 — lesbare Diagnostik**: Parse-Fehler nennen Token-Namen und das tatsächliche Lexem statt roher Token-IDs (z. B. „expected IDENT, got form 'form'").

### Windows PE32+ — vollständiges OOP & Funktionen (WP-A2)

- **A2.1**: Trampolin-Zone exakt auf die `CG_H_*`-Helper-Offsets ausgerichtet — `wine hello.exe` gibt korrekt aus (vorher Müll, weil PrintStr-Calls in den PrintInt-Helper durchfielen).
- **A2.2**: Unified Base-Relocation — Codegen registriert absolute VMT-Pointer; PE-Backend emittiert echte `.reloc`-Blöcke (`IMAGE_REL_BASED_DIR64`) + rebased die Werte → ASLR-tauglich.
- **A2.3**: `new`/alloc nutzt `VirtualAlloc` statt Linux-`mmap`-syscall.
- **A2.4**: `_start`→`main`-Aufruf korrigiert (`relMain + 14`) — alle user-Funktions-/Methoden-Calls funktionieren.
- Verifiziert unter wine: Funktionen, Rekursion, virtuelle Dispatch, Vererbung, Felder, Heap, Output.

### Security (WP-28..37)

- **WP-28**: Kernel-Mode-Guard Allowlist — `@kernel_mode` Attribut blockiert unsichere Imports
- **WP-29**: Ed25519-Lizenzverifikation — asymmetrische Signaturprüfung ohne RSA-Overhead
- **WP-30**: HTTP Custom-Header CRLF-Injection-Schutz — `\r\n` in Header-Werten wird abgelehnt
- **WP-31**: `FileReadAll` 256-MB-Limit — schützt vor OOM-Angriffen via überdimensionale Dateien; explizite Größenprüfung auch in lyxc selbst (Seed-Binary-Invarianz)
- **WP-32**: TOCTOU-Schutz `ms_appendMetaSafe` — atomares Append mit POSIX-Locks
- **WP-33**: String-Library Bounds-Hardening — alle Slice/Sub-Operationen prüfen Grenzen
- **WP-34**: Codegen-Buffer-Größenlimit — verhindert Stack-Overflow bei pathologischen Inputs
- **WP-35**: LYU-Parser symCount-Limit — begrenzt Symboltabellengröße in Precompiled Units
- **WP-36**: `SecureZero` Compiler-Barriere — `poke8`-basiertes Nullen verhindert Dead-Store-Elimination
- **WP-37**: `RandInt64` Fehlerbehandlung — `getrandom`-Fehler werden propagiert, kein Silent-Fail

### V1-Blocker (LyxOS Self-Hosting)

- **V-1**: `--target=lyxos` Segfault bei großen Programmen — behoben
- **V-2**: LyxOS Builtin-I/O falsche Syscall-Nummern — `sys_open=0x200`, `sys_read=0x202`, `sys_write=0x203` korrekt gesetzt
- **V-3**: `lyxc` dynamisch gelinkt via `explicit_bzero` — ersetzt durch `poke8`-Loop (PR #789); `lyxc` ist jetzt vollständig statisch

### P0-Blocker (V1.0.0A Milestone)

- **WP-A2**: Windows PE32+ `.reloc`-Section + ASLR (PR #791) — `win_x86.lyx` und `win_arm64.lyx` emittieren jetzt eine gültige `.reloc`-Section mit leerem `IMAGE_BASE_RELOCATION`-Block; BaseReloc-DataDir korrekt verdrahtet; `DllCharacteristics=0x8160` (DYNAMIC_BASE|NX_COMPAT|HIGH_ENTROPY_VA)

### Security Audit Fixes (PR #790)

- **SEC-BUG-05**: `PathNormalize` — segment-stack-basierter Algorithmus ersetzt fehlerhaften one-pass `..`-Handler; 80-Byte Buffer-Overflow gefixt; sicherer gegen path-traversal-Angriffe

### Compiler-Bugs (BUG-1..8)

- BUG-1: Importierte Konstanten im Bootstrap — behoben
- BUG-2: VMT-Kollision bei identischen Methodennamen — behoben
- BUG-3: Klassen-Instanz-Parameter — behoben
- BUG-4: 7-Argument-Overflow — behoben
- BUG-5: `break` als NOP in verschachtelten Schleifen — behoben
- BUG-6: r8/r9 werden nicht gespillt — behoben
- BUG-7: `BUG-1`-Typenfeld-Offset — behoben (PR #769)
- BUG-8: TypeName.field Offset immer 0 — behoben

### Test Suite

- `make test` grün: alle Tests PASS (LX-25..36, net_frame 45 Tests, WP-28..37 je 20 Tests)
- sec_wp37 in Makefile eingetragen

### P1-Status (86% ✅, Kriterium ≥80%)

C1 TmpFile, C2 Trig-Funktionen, C4 StrFormat, C5 URL-Encode/Build/Resolve, C6 HTTP PUT/DELETE/PATCH/HEAD, C8 log_info_kv — alle implementiert.
A4 (`@big_endian` ARM64 REV-Emission) bleibt offen.

---

## Unreleased

### Parser
- **Multi-import syntax**: `import a, b, c;` expandiert direkt in drei `NK_IMPORT`-Knoten — kein neuer AST-Knoten, Sema/Lowering/Codegen unverändert. Beide Formen sind gültig.

## Version 0.7.0-aerospace (April 2026) 🎉

### 🚀 **DO-178C Compliance**

#### **Tool Qualification (TQL-5)**
- `--version` flag (TOR-001): SemVer + TQL level output
- `--build-info` flag (TOR-002): Build hash, host, FPC version, determinism
- `--config` flag (TOR-003): All configuration parameters documented
- TOR-010: Deterministic code generation validated (SHA-256 comparison)
- TOR-011: 100% IR coverage in all 6 backends
- TOR-012: Error messages with source positions
- TOR-040: Reproducible builds (10x stress test passed)
- TOR-041: No hidden dependencies (static binary, no libc)
- TOR-042: Deterministic optimization

#### **MC/DC Instrumentation (DAL A)**
- `--mcdc` flag for coverage instrumentation
- `--mcdc-report` for coverage report generation
- `__mcdc_record` builtin in all 7 backends
- Coverage report: Decision | Function | Line | T | F | Status

#### **Static Analysis (7 Passes)**
- `--static-analysis` flag
- **Data-Flow Analysis**: Def-Use chains with use-location tracking
- **Live Variable Analysis**: Detects unused variables (warnings)
- **Constant Propagation**: Tracks known constants through irAdd/irSub/irMul
- **Null Pointer Analysis**: Tracks potentially null pointers from ConstStr
- **Array Bounds Analysis**: Static index safety verification
- **Termination Analysis**: Detects unbounded loops and recursive calls
- **Stack Usage Analysis**: Worst-case stack calculation per function

#### **Test Generation**
- **Fuzzing**: 50 random Lyx programs, 0 crashes, 50 unique inputs
- **Boundary-Value Analysis**: 28 tests across 4 categories (all passed)
- **Mutation Testing**: 3 mutations generated, 1 killed (33% score)
- **Symbolic Execution**: 15 paths explored through if/else trees

### 🌐 **New Backends**

#### **RISC-V RV64GC** (`--target=riscv`)
- Full RV64I emitter with LP64D ABI
- PMP configuration (16 regions, NAPOT/NA4/TOR modes)
- CSR access (read/write/set/clear)
- ECALL/EBREAK, Fence/WFI
- Machine Mode support (mret, get_mhartid, get_mcycle)
- ELF64 writer for RISC-V (EM_RISCV=243)

#### **ARM Cortex-M** (`compiler/backend/arm_cm/`)
- MPU configuration (8 regions, 6 AP modes)
- Fault handlers (HardFault, MemManage, BusFault, UsageFault)
- Stack canary detection ($DEADBEEF pattern)
- Privileged/Unprivileged mode switching
- TrustZone stubs (M33+)

### 🛡️ **Safety Features**

#### **ESP32 Safety**
- Watchdog: `watchdog_init()`, `watchdog_feed()`, `wdt_reset()`
- Brownout: `brownout_check()`, `brownout_config()`
- Flash: `flash_verify()`, `secure_boot()`
- MPU: `mpu_config()`, `pmp_lock()`
- Stack: `stack_canary_check()`
- Cache: `cache_flush()`
- Coredump: `coredump_save()`

#### **ARM Cortex-M Safety**
- MPU: `mpu_enable()`, `mpu_config()`
- Fault: `get_fault_status()`, `get_fault_address()`, `clear_fault_status()`
- Stack: `stack_canary_check()`
- Mode: `set_unprivileged()`, `set_privileged()`
- Debug: `bkpt()`

#### **RISC-V Safety**
- PMP: `pmp_config()`, `pmp_lock()`
- CSR: `csr_read()`, `csr_write()`, `csr_set()`, `csr_clear()`
- Control: `ebreak()`, `fence()`, `fence_i()`, `wfi()`, `mret()`, `sret()`
- Info: `get_mhartid()`, `get_mcycle()`, `get_time()`

### 📊 **IR Coverage**
- **100% IR coverage** in all 7 backends (113/113 operations)
- x86_64: ✅ 100% · x86_64_win64: ✅ 100% · arm64: ✅ 100%
- macosx64: ✅ 100% · xtensa: ✅ 100% · win_arm64: ✅ 100% · riscv: ✅ 100%

### 📚 **Documentation**
- **COMPILER_MANUAL.md**: Complete compiler documentation
- **USER_GUIDE.md**: User-facing guide with examples
- **VERIFICATION_REPORT.md**: DO-178C verification report (111/111 tests passed)
- **aerospace-todo.md**: Updated with completed items
- **README.md**: Updated with new features

---

## Version 0.5.7 (April 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **String-Bibliothek (std.string) v0.5.7**

Erweiterte String-Manipulationsfunktionen:

```lyx
import std.string;

fn main(): int64 {
    // StringBuilder für effizientes Konkatenieren
    var sb: StringBuilder := new StringBuilder();
    sb.Init(64);
    sb.Append("Hello");
    sb.Append(", ");
    sb.Append("World");
    sb.AppendChar(33);     // '!'
    sb.AppendInt(42);
    
    var result: pchar := sb.ToString();
    PrintStr(result);       // Hello, World!42
    StrFree(result);
    
    sb.FreeBuffer();
    dispose sb;
    return 0;
}
```

- **StringBuilder**: Klasse für effizientes String-Building
- **StrTrim**: Entfernt führende/nachfolgende Leerzeichen
- **StrSplit**: Splitst Strings nachDelimiter

#### **Data Library (Pandas-like) v0.5.7**

Umfassende Data-Frame-Bibliothek für Datenanalyse:

```lyx
import std.data.core;
import std.data.io;

fn main(): int64 {
    // CSV einlesen
    var df: DataFrame := ReadCSV("data.csv", true, ",");
    
    // Spalten-Operationen
    var sum: int64 := SeriesSum(df, "sales");
    var avg: f64 := SeriesMeanF64(df, "price");
    
    // Gruppierung
    var grouped: DataFrame := DataFrameGroupBy(df, "category");
    var counts: DataFrame := GroupByCount(grouped, "category");
    
    DataFrameFree(df);
    return 0;
}
```

- **DataFrame**: 2D-Tabellen mit benannten Spalten
- **Series**: 1D-Arrays mit Labels
- **CSV I/O**: ReadCSV, WriteCSV
- **GroupBy**: Gruppierung und Aggregation
- **Filter/Slice**: Daten-Teilmengen
- **Statistik**: Sum, Mean, Min, Max, StdDev, etc.

#### **Validation Library (std.validate) v0.5.7**

Business-Identifier Validierung:

```lyx
import std.validate.ean;
import std.validate.iban;
import std.validate.luhn;
import std.validate.vat;

fn main(): int64 {
    // EAN/ISBN Validation
    var valid: bool := EAN13Validate("4006381333931");
    var isbn: bool := ISBN13Validate("978-3-16-148410-0");
    
    // IBAN Validation
    var ibanValid: bool := IBANValidate("DE89370400440532013000");
    
    // Credit Card
    var cardType: int64 := CreditCardType("4111111111111111");
    var isValid: bool := CreditCardValidate("4111111111111111", 12, 25);
    
    // VAT ID
    var vatValid: bool := VATValidate("DE123456789");
    
    return 0;
}
```

- **EAN/UPC**: EAN-13, EAN-8, EAN-14, ISBN-13/10, UPC-A
- **IBAN**: ISO 13616 Mod 97, 50+ Länder
- **Credit Card**: Luhn-Algorithmus, 8 Kartentypen
- **VAT**: EU 27 Länder mit länderspezifischen Regeln

#### **Statistics Library (std.stats) v0.5.7**

Array-Aggregatfunktionen und Statistik:

```lyx
import std.stats;

fn main(): int64 {
    var arr: array := [3, 1, 4, 1, 5, 9, 2, 6];
    
    var sum: int64 := ArraySum(arr);
    var avg: f64 := ArrayAvg(arr);
    var min: int64 := ArrayMin(arr);
    var max: int64 := ArrayMax(arr);
    var median: f64 := ArrayMedian(arr);
    
    // Sorting
    ArraySort(arr);
    
    // Variance/StdDev
    var variance: f64 := ArrayVariance(arr);
    var stddev: f64 := ArrayStdDev(arr);
    
    return 0;
}
```

- **Aggregates**: Sum, Min, Max, Avg, Median, Count, Product
- **Sorting**: ArraySort, ArrayReverse
- **Filtering**: ArrayFilterGt, ArrayFilterLt, ArrayFilterRange
- **Statistical**: Variance, StdDev, Range, SumSquares

---

## Version 0.5.7 (März 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Enum-Typen (v0.5.7)**

Native Aufzählungstypen mit typsicheren Konstanten:

```lyx
enum Direction { North, South, East, West }
enum Color { Red = 1, Green = 2, Blue = 4 }

fn main(): int64 {
    var d: int64 := Direction::North;
    var c: int64 := Color::Green;
    PrintInt(d);  // 0
    PrintInt(c);  // 2
    return 0;
}
```

- `enum Name { Val, Val = N, ... }` Syntax
- Werte mit optionalem explizitem Integer-Wert
- Zugriff via `EnumName::Wert` (Namespace-Syntax)
- Werden intern als `int64`-Konstanten lowered

#### **Exception Handling: try/catch/throw (v0.5.7)**

Strukturierte Fehlerbehandlung:

```lyx
fn riskyOp(x: int64): int64 {
    if (x < 0) { throw "negative value"; }
    return x * 2;
}

fn main(): int64 {
    try {
        var r: int64 := riskyOp(-1);
    } catch (e) {
        PrintStr("Caught: "); PrintStr(e); PrintStr("\n");
    }
    return 0;
}
```

- `try { ... } catch (varname) { ... }` Syntax
- `throw expr` wirft eine Exception (pchar-Nachricht)
- Nested try/catch vollständig unterstützt
- Implementiert via `irPushHandler`/`irPopHandler`/`irThrow` IR-Opcodes

#### **Multi-Return / Tuple-Rückgabe (v0.5.7)**

Funktionen können mehrere Werte zurückgeben:

```lyx
fn divmod(a: int64, b: int64): (int64, int64) {
    return (a / b, a % b);
}

fn main(): int64 {
    var q, r := divmod(17, 5);
    PrintInt(q);  // 3
    PrintInt(r);  // 2
    return 0;
}
```

- Rückgabetyp `(T1, T2)` Syntax
- `return (expr1, expr2)` Tupel-Literal
- `var a, b := f()` Tupel-Destrukturierung
- Implementierung: RAX/RDX Register-Paar (16-Byte Struct Return)

#### **Generics mit Monomorphisierung (v0.5.7)**

Echte generische Funktionen mit Compile-Time-Spezialisierung:

```lyx
fn max[T](a: T, b: T): T {
    if (a > b) { return a; }
    return b;
}

fn main(): int64 {
    var x: int64 := max[int64](10, 20);  // spezialisiert zu _G_max__int64
    PrintInt(x);  // 20
    return 0;
}
```

- `fn name[T](...)` Syntax für generische Typparameter
- `func[int64](...)` Aufruf-Syntax mit konkreten Typen
- Monomorphisierung: jede Typen-Kombination erzeugt eine eigene Funktion `_G_name__type`
- Mehrere Typparameter möglich: `fn zip[A, B](...)`

#### **Pattern Matching mit match/case (v0.5.7)**

Ausdrucksstärkere Alternative zu `switch`:

```lyx
fn classify(n: int64): int64 {
    match n {
        case 0 => { PrintStr("zero\n"); }
        case 1 | 2 | 3 => { PrintStr("small\n"); }
        case 10 | 20 | 30 => { PrintStr("tens\n"); }
        default => { PrintStr("other\n"); }
    }
    return 0;
}
```

- `match expr { ... }` — kein Klammern um den Ausdruck nötig
- `case val => body` — `=>` statt `:`
- OR-Patterns: `case 1 | 2 | 3 =>` — mehrere Werte pro Case
- `default =>` Fallback
- Bestehender `switch`-Syntax bleibt vollständig kompatibel

#### **Dynamische String-Builtins (v0.5.7)**

7 neue Built-in-Funktionen für mmap-basierte dynamische Strings:

```lyx
var s: pchar := StrNew(64);          // Allokiere String-Buffer
StrSetChar(s, 0, 72);               // s[0] = 'H'
StrSetChar(s, 1, 105);              // s[1] = 'i'
StrSetChar(s, 2, 0);                // Null-Terminator
PrintStr(s);                         // "Hi"

var s2: pchar := StrAppend(s, " World");
PrintStr(s2);                        // "Hi World"

var ns: pchar := StrFromInt(-42);
PrintStr(ns);                        // "-42"

PrintInt(StrLen("Hello"));           // 5  (funktioniert auch auf Literalen)
PrintInt(StrCharAt("ABC", 1));       // 66 ('B')

StrFree(s2);
StrFree(ns);
```

| Funktion | Signatur | Beschreibung |
|----------|----------|-------------|
| `StrNew(cap)` | `(int64) → pchar` | mmap-Allokation mit Header |
| `StrFree(s)` | `(pchar) → void` | munmap via Header |
| `StrLen(s)` | `(pchar) → int64` | Strlen (Null-Scan, kompatibel mit Literalen) |
| `StrCharAt(s, i)` | `(pchar, int64) → int64` | Byte-Zugriff (zero-extended) |
| `StrSetChar(s, i, c)` | `(pchar, int64, int64) → void` | Byte schreiben |
| `StrAppend(dest, src)` | `(pchar, pchar) → pchar` | Konkatenation mit Reallokation |
| `StrFromInt(n)` | `(int64) → pchar` | Integer → Dezimalstring |

**String-Header-Layout:** 16 Byte vor dem Daten-Pointer: `[capacity:8][length:8][data...]`. Der zurückgegebene `pchar` zeigt auf `data` und ist direkt mit `PrintStr` kompatibel.

---

### 🔧 **Bugfixes**

- **Generics arr[i] Regression**: Heuristik für Typarg-Parsing war zu breit — `arr[idx]` wurde fälschlicherweise als generischer Typarg geparst. Fix: `IsKnownTypeIdent()` prüft ob der Token ein bekannter Primitiv-Typ oder deklarierter Typparameter ist.
- **Generics Commit Unvollständig**: `TAstFuncDecl.TypeParams` Feld und `savedTypeParams`/`typeParams` Variablen fehlten im Commit. Der Branch `fix/generics` enthält den Fix.

---

## Version 0.5.1 (März 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Linux ARM64 Backend: VMT Support (v0.5.1)**

Vollständige Virtual Method Table (VMT) Unterstützung für Linux ARM64:

```lyx
// Virtual methods on ARM64
type Animal = class {
    fn virtual speak() {
        PrintStr("?\n");
    }
};

type Dog = class extends Animal {
    fn override speak() {
        PrintStr("Woof!\n");
    }
};

fn main(): int64 {
    var a: Animal := new Dog();
    a.speak();  // Dynamischer Aufruf → "Woof!"
    dispose a;
    return 0;
}
```

**Implementierung:**
- `backend/elf/elf64_arm64_writer.pas`: VMT-Tabelle im .rodata Segment
- `backend/arm64/arm64_emit.pas`: Virtual Call via VMT (LDR + BLR)
- `backend/arm64/arm64_emit.pas`: VMT-Pointer bei `new` gesetzt
- `tests/test_arm64_vmt.pas`: Unit-Tests für ARM64 VMT

#### **ARM64 Backend: 100% IR Opcode Coverage (v0.5.1)**

Alle 93 IR-Opcodes sind jetzt für ARM64 implementiert:

**Neu implementierte Opcodes:**
- `irCast`: Type casting (int↔float)
- `irVarCall`: Indirekte Funktionsaufrufe via BLR
- `irCallStruct`: Struct-by-value calls (AAPCS64 ABI)
- `irReturnStruct`: Struct return mit Memory-Copy
- `irIsType`: VMT-basierte Type-Prüfung
- `irPanic`: Panic/Abort mit stderr + exit
- `irPushHandler/irPopHandler/irThrow`: Exception-Handling
- `irInspect`: Debug Visualizer

**ARM64 SIMD/NEON Operationen:**
- `WriteAddSimd`, `WriteSubSimd`, `WriteMulSimd`
- `WriteAndSimd`, `WriteOrSimd`, `WriteXorSimd`
- `WriteNegSimd`, `WriteNotSimd`
- `WriteCmeqSimd`, `WriteCmhiSimd`, `WriteCmgeSimd`

**ARM64 DynArray Support:**
- `irDynArrayPush`: Element hinzufügen mit auto-growth
- `irDynArrayPop`: Element entfernen
- `irDynArrayLen`: Länge abrufen
- `irDynArrayFree`: Speicher freigeben

#### **IR Bugfix: Float Arithmetic (v0.5.1)**

Korrigierte Float-Operationen im IR-Generator:

```lyx
// Vorher: verwendet irSub/irMul/irDiv (Integer)
var z: f64 := x - y;  // ❌ Falscher Opcode

// Jetzt: verwendet irFSub/irFMul/irFDiv
var z: f64 := x - y;  // ✅ Korrekter Opcode
```

---

## Version 0.4.3 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **IR-Level Inlining (v0.4.3)**

Automatische Inlining-Optimierung auf IR-Ebene für bessere Performance:

```lyx
// Funktionen mit ≤12 IR-Anweisungen werden automatisch inlined
fn add(a: int64, b: int64): int64 {
    return a + b;
}

fn main(): int64 {
    var x: int64 := add(10, 20);  // Wird zu: var x: int64 := 10 + 20;
    return x;
}
```

**Implementierung:**
- `ir_inlining.pas`: Vollständiger Inlining-Pass
- Rekursionserkennung vermeidet selbstreferenzielle Inlinings
- Korrektes Argument-Mapping zwischen Caller/Callee
- Return-Statements werden durch Jumps ersetzt
- Mehrere Pässe für verschachtelte Funktionen

#### **Naming Conventions: PascalCase (v0.4.3)**

Alle stdlib-Funktionen verwenden jetzt PascalCase gemäß AGENTS.md:

```lyx
// Vorher (lowercase/snake_case)
printf("Hello %d\n", 42);
clrscr();
gotoxy(10, 5);

// Jetzt (PascalCase)
Printf("Hello %d\n", 42);
ClrScr();
GoToXY(10, 5);
```

**Umbenannte Funktionen:**
- `std/crt`: `TextColor`, `TextBackground`, `TextAttr`, `ClrScr`, `ClrEol`, `GoToXY`, `HideCursor`, `ShowCursor`, `WriteStrAt`, `ReadChar`
- `std/io`: `Printf`
- `std/env`: `Init`, `Arg`
- `std/string`: `StrCmp`, `StrCpy`
- `std/time`: `Now`

---

## Version 0.2.2 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **SIMD / ParallelArray (v0.2.2)**

SIMD-optimierte Arrays mit element-weisen Operationen:

```lyx
var vec: parallel Array<Int64> := parallel Array<Int64>(1000);
vec[0] := 42;
var first: int64 := vec[0];
var sum: parallel Array<Int64> := vec + vec;  // element-weise Addition
```

**Frontend (Lexer/Parser/AST/Sema):**
- `parallel` und `simd` als Keywords im Lexer
- Parser: `parallel Array<T>(size)` Syntax
- AST: `TAstSIMDNew`, `TAstSIMDBinOp`, `TAstSIMDUnaryOp`, `TAstSIMDIndexAccess`
- Sema: Typprüfung, SIMDKind-Propagierung, Operator-Validierung

**IR-Lowering (vollständig):**
- `nkSIMDNew` → `irAlloc` (Heap-Allokation mit Element-Größe)
- `nkSIMDBinOp` → `irSIMDAdd/Sub/Mul/Div/And/Or/Xor` + Vergleiche
- `nkSIMDUnaryOp` → `irSIMDNeg`
- `nkSIMDIndexAccess` → `irLoadElem` mit korrekter Element-Größe aus SIMDKind
- VarDecl für `atParallelArray`: Heap-Pointer als einzelner Stack-Slot
- Index-Assignment (`vec[i] := value`): Pointer via `irLoadLocal` statt `irLoadLocalAddr`

**Element-Typen:** Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, F32, F64

**SIMD-Operatoren:** `+`, `-`, `*`, `/`, `&&`, `||`, `^`, `==`, `!=`, `<`, `<=`, `>`, `>=`

### ⚠️ **Noch offen (Backend)**
- x86_64 Backend: SSE2/AVX-Instruktionen für `irSIMD*`-Opcodes
- Bounds-Checks bei ParallelArray Index-Zugriff
- Reduce-Operationen (`irSIMDAddReduce`, etc.)

---

## Version 0.4.2 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Regex-Literale und Regex-Funktionen (v0.4.2)**

Native Unterstützung für reguläre Ausdrücke:

```lyx
var email: pchar := r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$";
var phone: pchar := r"\d{3}-\d{4}";

// Regex-Funktionen
if (RegexMatch(r"abc", "abcdef")) {
    IO.PrintStr("Match!\n");
};
var pos: int64 := RegexSearch(r"\d+", "abc123def");
var count: int64 := RegexReplace(r"old", "text", "new");
```

**Syntax:** `r"pattern"` - Präfix `r` gefolgt von Anführungszeichen

**Funktionen:**
- `RegexMatch(pattern, text)` -> bool: Prüft ob Pattern in Text vorkommt
- `RegexSearch(pattern, text)` -> int64: Position oder -1
- `RegexReplace(pattern, text, replacement)` -> int64: Anzahl Ersetzungen

**Namespace:** `Regex.Match`, `Regex.Search`, `Regex.Replace`

**Compile-Time-Validierung:** Der Compiler prüft die Regex-Syntax

#### **Namespaces für Builtins (empfohlen, rückwärtskompatibel)**

Funktionen können jetzt über Namespaces aufgerufen werden:
```lyx
// Direkter Aufruf (Rückwärtskompatibilität)
PrintStr("Hallo");

// Namespace-Aufruf (empfohlen)
IO.PrintStr("Hallo");
OS.exit(0);
Math.Random();
```

**Verfügbare Namespaces:**
- `IO`: PrintStr, PrintInt, open, read, write, close, etc.
- `OS`: exit, getpid
- `Math`: Random, RandomSeed

#### **Panic und Assert - Fehlerbehandlung zur Laufzeit**

- **`panic(message)`**: Bricht das Programm mit einer Fehlermeldung ab
  - Expression, die nie zurückkehrt
  - Argument muss ein String sein
  - Nachricht wird auf stderr ausgegeben
  - Exit-Code: 1

- **`assert(cond, msg)`**: Runtime-Assertion für Invariantenprüfung
  - `cond` muss ein Boolean sein
  - `msg` muss ein String sein
  - Wenn `cond` false ist, wird `panic(msg)` aufgerufen

**Beispiel:**
```lyx
fn divide(a: int64, b: int64) -> int64 {
    if b == 0 {
        panic("Division by zero!");
    };
    return a / b;
}

fn setAge(age: int64) -> void {
    assert(age >= 0 && age < 150, "Age must be between 0 and 149");
}
```

---

## Version 0.4.1 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Access Control (Sichtbarkeit) für Klassen-Member**
Private, Protected und Public Member für Klassen und Structs:

- **`pub`**: Überall zugänglich (Standard)
- **`private`**: Nur innerhalb der eigenen Klasse zugänglich
- **`protected`**: In der eigenen Klasse und in abgeleiteten Klassen zugänglich

**Beispiel:**
```lyx
type MyClass = class {
  pub pubField: int64;           // Überall zugänglich
  private privField: int64;       // Nur in der Klasse
  protected protField: int64;    // In Klasse und Subklassen
  
  pub fn pubMethod() { }
  private fn privMethod() { }
};
```

---

## Version 0.4.0 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Option Types / Nullable Pointer**
Statische Typprüfung für Pointer-Sicherheit zur Kompilierzeit:

- **Nullable Typen**: `pchar?` kann `null` sein
- **Non-nullable Typen**: `pchar` darf nicht `null` sein (Standard)
- **Null-Coalescing**: `??` Operator für sichere Dereferenzierung
- **null Keyword**: Explizite Null-Zuweisung

**Beispiel:**
```lyx
var p: pchar? := null;    // nullable Pointer
var q: pchar;              // non-nullable Pointer (Standard)
var r: pchar := p ?? "default";  // sicherer Zugriff
```

#### **CLI-Argumente im statischen ELF**
Statische ELF-Binaries unterstützen jetzt CLI-Argumente:

- `main(argc: int64, argv: pchar)` wird nach SysV ABI aufgerufen
- argc: Anzahl der Argumente (inkl. Programmname)
- argv: Array der Argument-Strings

---

## Version 0.3.1 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **std.io: Direkte Syscalls (statisches ELF)**
Die I/O-Funktionen werden jetzt als **direkte Linux-Syscalls** generiert:
- Keine libc-Abhängigkeit
- Statisches ELF ohne externe Symbole
- Funktioniert auf x86-64 und ARM64

**Unterstützte Funktionen:**
| Funktion | x86-64 | ARM64 |
|----------|--------|-------|
| `open` | Syscall 2 | Syscall 56 |
| `read` | Syscall 0 | Syscall 63 |
| `write` | Syscall 1 | Syscall 64 |
| `close` | Syscall 3 | Syscall 57 |
| `lseek` | Syscall 8 | Syscall 62 |
| `unlink` | Syscall 87 | Syscall 87 |
| `rename` | Syscall 82 | Syscall 82 |
| `mkdir` | Syscall 83 | Syscall 83 |
| `rmdir` | Syscall 84 | Syscall 84 |
| `chmod` | Syscall 90 | Syscall 90 |

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/io/test_syscall.lyx`: Alle I/O-Tests bestanden
- ✅ Unit-Tests: Alle bestanden

---

## Version 0.3.0 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **std.io: fd-basierte I/O via libc Wrappers**
- `open(path: pchar, flags: int64, mode: int64): int64` – Datei öffnen
- `read(fd: int64, buf: pchar, count: int64): int64` – von File-Descriptor lesen
- `write(fd: int64, buf: pchar, count: int64): int64` – auf File-Descriptor schreiben
- `close(fd: int64): int64` – File-Descriptor schließen

Die Funktionen sind als Builtins registriert und werden als externe libc-Calls
via PLT/GOT generiert (dynamic ELF mit `-rdynamic` Linker-Flag).

### 🔧 **Behobene Bugs**
- Keine neuen Bugs in dieser Version

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/io/test_syscall.lyx`: open/write/read/close funktionieren
- ✅ Unit-Tests: 157+ Tests bestanden

---

## Version 0.1.4 (Februar 2026) 🎉

### 🚀 **Neue Hauptfeatures**

#### **Vollständiges Module System**
- **Import/Export Syntax**: `import std.math;`, `pub fn` Deklarationen
- **Cross-Unit Symbol Resolution**: Importierte Funktionen werden automatisch gefunden
- **Standard Library Support**: `std/math.lyx` mit mathematischen Funktionen
- **Dynamic ELF Generation**: Unterstützung für externe Symbole und Libraries

#### **Robuste Parser-Architektur**
- **Flexible While-Syntax**: `while condition` UND `while (condition)` funktionieren beide
- **Einheitliche If-Syntax**: `if (condition)` - Klammern sind erforderlich für Eindeutigkeit
- **Unary-Expressions**: `return -x` und `var y := -x` funktionieren korrekt
- **Function-In-Function**: If-Statements in Funktionen vollständig unterstützt

### 🔧 **Behobene kritische Bugs**
- **Parser-Rekursion**: Unary-Operator Parsing führte zu unendlicher Rekursion
- **Context-Confusion**: If-Statements wurden fälschlicherweise als Struct-Literale interpretiert
- **Import-Parsing**: Units mit komplexen Control-Flow-Konstrukten parsen korrekt

### 📊 **Getestete Funktionalität**
- ✅ `tests/lyx/control/for_loop.lyx`: While-Schleifen (Output: 15, 15)
- ✅ `tests/lyx/stdlib/use_math.lyx`: Module Import mit dynamischem ELF
- ✅ `std/math.lyx`: Standard Library kompiliert erfolgreich
- ✅ Complex Functions: `Abs64()`, `Min64()`, `Max64()` Implementierungen
- ✅ Cross-File Compilation: Multi-Unit Projekte funktionieren

### 🎯 **Standard Library (std/)**
```lyx
import std.math;

fn main(): int64 {
    let x: int64 := Abs64(-42);      // 42
    let smaller: int64 := Min64(x, 100);  // 42
    PrintInt(times_two(smaller));   // 84
    return 0;
}
```

### ⚠️ **Bekannte Einschränkungen**
- **Cross-Unit Function Calls**: Werden erkannt und gelinkt, aber nicht ausgeführt (Backend-Bug)
- **Verschachtelte Unary-Ops**: `--x` temporär deaktiviert für Parser-Stabilität
- **If-Syntax**: Klammern sind jetzt erforderlich (Breaking Change von flexibler Syntax)

### 📈 **Performance & Stabilität**
- **Compiler-Geschwindigkeit**: ~1.0-1.2s für komplexe Multi-Unit Projekte
- **Memory Management**: Robuste AST/IR Speicherverwaltung ohne Leaks
- **Error Handling**: Präzise Fehlermeldungen mit Zeilen/Spalten-Angaben

### 🔄 **Migration Guide**
```diff
// Alte Syntax (funktioniert nicht mehr)
- if x < 0 { return -x; }
- while i < 10 { i := i + 1; }

// Neue Syntax (erforderlich)
+ if (x < 0) { return -x; }
+ while i < 10 { i := i + 1; }  // oder while (i < 10)
```

---

**Status**: Der Lyx-Compiler ist von *"grundlegend defekt"* zu *"weitgehend produktiv"* geworden und unterstützt nun professionelle Multi-Module Projekte.