# Lyx v0.2.0 – Sprachspezifikation

Ziel: Minimaler, nativer Compiler für **Linux x86_64 (ELF64)**, erweiterbar durch saubere Trennung von Frontend/IR/Backend.

---

## 1) Lexikalische Regeln

### Whitespace

* Leerzeichen, Tabs, Zeilenumbrüche trennen Tokens.

### Kommentare

* Zeilenkommentar: `//` bis Zeilenende
* Blockkommentar (optional, empfohlen): `/* ... */` (nicht verschachtelt)

### Identifier

* Regex: `[A-Za-z_][A-Za-z0-9_]*`
* case-sensitive

### Literale

* **Int64**: Dezimal: `0` oder `[1-9][0-9]*` (optional führendes `-` als unary operator)
* **Float64**: `[0-9]+ '.' [0-9]+` (z.B. `3.14159`, `2.718`)
* **Stringliteral**: `" ... "` mit Escapes:

    * `\n`, `\r`, `\t`, `\\`, `\"`, `\0`
    * Ergebnis ist **nullterminiert** im `.rodata`

### Keywords (reserviert)

`fn var let co con if else while for to downto do repeat until switch case break default return true false null extern unit import pub as array struct class extends new dispose super static self Self private protected panic assert where value virtual override abstract enum match try catch throw limit`

### Integer-Literale mit verschiedenen Basen

Lyx unterstützt Integer-Literale in verschiedenen Zahlenbasen:

```
IntLiteral    := DecimalLiteral | HexLiteral | BinaryLiteral | OctalLiteral ;
DecimalLiteral := [0-9] { [0-9_] } ;
HexLiteral     := ( '0x' | '0X' | '$' ) [0-9a-fA-F_] { [0-9a-fA-F_] } ;
BinaryLiteral  := ( '0b' | '0B' | '%' ) [01_] { [01_] } ;
OctalLiteral   := ( '0o' | '&' ) [0-7_] { [0-7_] } ;
```

Unterstriche (`_`) können als Trenner zur Lesbarkeit verwendet werden.

**Beispiele:**
```
42           // Dezimal
0xFF, $FF   // Hexadezimal (255)
0b1010, %1010 // Binär (10)
0o77, &77    // Oktal (63)
1_000_000    // Mit Unterstrich
0b1100_1010  // Binär mit Unterstrich (202)
```

Alle Integer-Literale werden intern als `int64` behandelt.

### Operatoren / Trennzeichen

* Zuweisung: `:=`
* Arithmetik: `+ - * / %`
* **String-Verkettung**: `+` (bei pchar + pchar)
* Vergleich: `== != < <= > >=`
* Logik: `&& || !`
* Bitweise: `& | ^ ~ << >>`
* Null-Safety: `? ?? ?.`
* Pipe: `|>`
* Fat Arrow: `=>` (Pattern-Matching-Zweig)
* Namespace: `::` (Enum-Zugriff: `Color::Red`)
* Sonstiges: `(` `)` `{` `}` `[` `]` `:` `,` `;` `.` `@`

---

## Energy-Aware-Compiling (v0.3.1+ ✅ ABGESCHLOSSEN)

### @energy Pragma

Funktionen können mit einem Energy-Level kompiliert werden:

```
EnergyAttr = "@energy" "(" IntLiteral ")"
FnDecl = [ EnergyAttr ] "fn" Ident "(" [ ParamList ] ")" [ ":" Type ] Block
NestedFnDecl = "fn" Ident "(" [ ParamList ] ")" [ ":" Type ] Block
```

---

## Safety-Pragmas (v0.8.0 ✅ ABGESCHLOSSEN – aerospace-todo P1 #6)

Funktionen können mit Safety-Annotationen für DO-178C-Compliance versehen werden.
Mehrere `@`-Attribute können in beliebiger Reihenfolge vor `fn` stehen.

### EBNF

```ebnf
FuncAttr   = EnergyAttr | DALAttr | CriticalAttr | WCETAttr | StackLimitAttr | IntegrityAttr ;
EnergyAttr = "@energy"      "(" IntLiteral ")" ;   // 1..5
DALAttr    = "@dal"         "(" DALLevel   ")" ;   // A | B | C | D
CriticalAttr = "@critical" ;                        // kein Argument
WCETAttr   = "@wcet"        "(" IntLiteral ")" ;   // μs > 0
StackLimitAttr = "@stack_limit" "(" IntLiteral ")" ; // Bytes > 0
IntegrityAttr  = "@integrity" "(" "mode" ":" IntegrityMode [ "," "interval" ":" IntLiteral ] ")" ;
IntegrityMode  = "software_lockstep" | "scrubbed" | "hardware_ecc" ;

DALLevel   = "A" | "B" | "C" | "D" ;

FnDecl = { FuncAttr } "fn" Ident "(" [ ParamList ] ")" [ ":" Type ] Block ;
```

### Semantik

| Pragma | Bedeutung | Validierung |
|--------|-----------|-------------|
| `@dal(A)` | DO-178C DAL A (höchstes Sicherheitslevel) | `@critical` wird empfohlen (Warning) |
| `@dal(B)` | DO-178C DAL B | — |
| `@dal(C)` | DO-178C DAL C | — |
| `@dal(D)` | DO-178C DAL D (niedrigstes) | — |
| `@critical` | Sicherheitskritische Funktion | Nicht auf `extern fn` erlaubt |
| `@wcet(N)` | WCET-Budget in Mikrosekunden | N > 0; nicht auf `extern fn` erlaubt |
| `@stack_limit(N)` | Maximale Stack-Nutzung in Bytes | N > 0; nicht auf `extern fn` erlaubt |

### Beispiele

```lyx
// Einfache Annotationen
@dal(A) @critical @wcet(100) @stack_limit(512)
fn autopilot_update(): int64 {
  return 0;
}

// DAL-B mit WCET-Budget
@dal(B) @wcet(1000)
fn fuel_monitor(): int64 {
  return 1;
}

// Kombiniert mit @energy
@energy(3) @dal(C)
fn sensor_read(): int64 {
  return 42;
}

// Mehrere Sicherheitslevel in einem Programm
@dal(A) @critical @wcet(50)  fn engine_cutoff():   int64 { return 0; }
@dal(B) @wcet(200)           fn navigation():      int64 { return 1; }
@dal(C)                      fn cabin_pressure():  int64 { return 2; }
@dal(D)                      fn log_event():       int64 { return 3; }
```

### Compiler-Verhalten

- **Parsing**: Alle Attribute werden vor dem `fn`-Keyword gelesen (Reihenfolge beliebig).
- **Sema-Check**: Ungültige Kombinationen werden als Error oder Warning gemeldet.
- **IR-Propagation**: `SafetyPragmas` werden in `TIRFunction` übertragen und stehen für
  zukünftige WCET-Analyse, Stack-Verifizierung und Assembly-Listing-Annotierung zur Verfügung.
- **DAL-A ohne `@critical`**: Warning (kein Fehler) – starke Empfehlung zur Markierung.

## Range-Typen (v0.8.1 ✅ ABGESCHLOSSEN – aerospace-todo P1 #7)

Integer-Typen mit eingeschlossenen Wertebereichen für DO-178C-Compliance.
Compile-Time-Checks für Literale, Runtime-Checks für nicht-konstante Werte.

### EBNF

```ebnf
TypeDecl     = "type" Ident "=" BaseIntType [ RangeClause ] ";" ;
RangeClause  = "range" RangeBound ".." RangeBound ;
RangeBound   = [ "-" ] IntLiteral ;
BaseIntType  = "int8" | "int16" | "int32" | "int64"
             | "uint8" | "uint16" | "uint32" | "uint64"
             | "isize" | "usize" ;
```

### Semantik

| Merkmal | Beschreibung |
|---------|-------------|
| Wertebereich | Inklusive Grenzen: `[Min..Max]` |
| Basistyp | Muss ein Integer-Typ sein |
| Compile-Time-Check | Literale außerhalb des Bereichs → `error: value N is out of range [Min..Max] for type T` |
| Runtime-Check | Nicht-konstante Ausdrücke → IR-Vergleiche + `panic` bei Verletzung |
| Redeclaration | Zweite Deklaration desselben Namens → Fehler |

### Beispiele

```lyx
// Aeronautische Wertebereiche
type Altitude  = int64 range -1000..60000;   // Meter über MSL
type Speed     = int64 range 0..300;          // Knoten
type Percent   = int64 range 0..100;          // Prozentwert

// Compile-Time Fehler (Literal außerhalb Bereich):
var alt: Altitude := 70000;   // error: value 70000 is out of range [-1000..60000] for type Altitude

// Gültige Zuweisung:
var alt: Altitude := 5000;    // OK

// Runtime-Check (nicht-konstanter Wert):
var spd: Speed := get_speed();  // Runtime: panic wenn get_speed() > 300
```

### Kombination mit Safety-Pragmas

```lyx
type Altitude = int64 range -1000..60000;

@dal(A) @critical @wcet(50)
fn set_target_altitude(alt: int64): int64 {
  return 0;
}
```

### Bounded While Loops (aerospace-todo P1 #47)

Für deterministische Echtzeit-Ausführung können While-Schleifen mit einem `limit` versehen werden:

```ebnf
WhileStmt     := 'while' '(' Expr ')' [ 'limit' '(' Expr ')' ] Block ;
```

**Beispiel:**
```lyx
// Unbounded (wie bisher)
while (x < 100) {
  x := x + 1;
}

// Bounded (max. 1000 Iterationen)
while (x < 100) limit(1000) {
  x := x + 1;
}
```

- Das `limit` muss ein Integer-Literal oder ein konstanter Ausdruck sein
- Compiler warnt bei nicht-bounded Loops in @flight_crit Sektionen
- WCET-Analyse kann bounded loops genauer berechnen

### Compiler-Verhalten

- **Lexer**: `..` wird als Token `tkDotDot` erkannt (vor `.` und vor `...`).
- **Parser**: `range Min..Max` wird nach dem Basistyp geparst; `ParseRangeInt` akzeptiert optionales `-` + `IntLit`.
- **Sema (Compile-Time)**: Literale werden beim ersten Compile-Pass mit `RangeMin`/`RangeMax` verglichen.
- **IR (Runtime)**: `EmitRangeCheck` erzeugt `cmpge` + `and` + `brfalse` + `panic`-Sequenz.
- **IR-Optimierung**: Konstante Initialisierungen werden durch Constant Folding ggf. wegeliminiert.

## @integrity – Integritäts-Management (v0.9.0 ✅ ABGESCHLOSSEN – aerospace-todo P0 #43/#44)

Einheit- und Funktions-Level-Annotationen für Strahlungstoleranz und DO-178C-Compliance.
Implementiert aerospace.pdf v2 Sections 2.5.1–2.5.2.

### EBNF

```ebnf
IntegrityAttr  = "@integrity" "(" IntegrityParams ")" ;
IntegrityParams = IntegrityMode [ "," IntegrityInterval ] ;
IntegrityMode   = "mode" ":" ( "software_lockstep" | "scrubbed" | "hardware_ecc" ) ;
IntegrityInterval = "interval" ":" IntLiteral ;        // ms > 0

(* Unit-Level: steht vor dem unit-Keyword, erste Deklaration der Datei *)
UnitDecl = [ IntegrityAttr ] "unit" DotPath ";" { TopDecl } ;

(* Funktion-Level: zusammen mit anderen @-Attributen vor fn *)
FuncAttr = EnergyAttr | DALAttr | CriticalAttr | WCETAttr | StackLimitAttr | IntegrityAttr ;
```

### Semantik

| Merkmal | Beschreibung |
|---------|-------------|
| `mode: software_lockstep` | Redundante Ausführung mit Ergebnisvergleich |
| `mode: scrubbed` | Periodischer Hintergrund-CRC-Memory-Sweep |
| `mode: hardware_ecc` | Vertraut auf Hardware-ECC-Speicherkorrektur |
| `interval: N` | Prüf-/Scrub-Intervall in Millisekunden |
| Auf `extern fn` | Fehler: nicht erlaubt |
| `scrubbed` ohne `interval` | Warnung: Intervall empfohlen |

### Beispiele

```lyx
// Unit-Level (löst .meta_safe ELF-Sektion aus)
@integrity(mode: scrubbed, interval: 100)
unit nav.core;

fn main(): int64 { return 42; }

// Funktion-Level (kein .meta_safe)
@dal(A) @integrity(mode: software_lockstep, interval: 50)
fn autopilot_step(): int64 { return 0; }
```

### .meta_safe ELF-Sektion

Bei Unit-Level `@integrity` erzeugt der Compiler eine `.meta_safe` ELF-Sektion (8232 Bytes):

```
[0..7]    code_start_va   uint64 LE  – Start-VA des Code-Segments
[8..15]   code_end_va     uint64 LE  – End-VA des Code-Segments
[16..19]  mode            uint32 LE  – 1=lockstep, 2=scrubbed, 3=hardware_ecc
[20..23]  interval_ms     uint32 LE  – Intervall in ms
[24..31]  recovery_ptr    uint64 LE  – Recovery-Zeiger (0 = nicht gesetzt)
[32..35]  hash_copy_1     uint32 LE  – CRC32 IEEE 802.3 des Codes
[36..4127]  padding        4092 B    – 4096-Byte-Separation
[4128..4131] hash_copy_2  uint32 LE  – identische CRC32-Kopie 2
[4132..8223] padding       4092 B    – 4096-Byte-Separation
[8224..8227] hash_copy_3  uint32 LE  – identische CRC32-Kopie 3
[8228..8231] padding          4 B    – Abschluss-Padding
```

Drei identische Kopien mit 4096-Byte-Abstand → Single-Event-Upset-Erkennung via Mehrheitsabstimmung.

### Compiler-Verhalten

- **Parser**: `@integrity` vor `unit` oder `fn` – Pending-Feld-Ansatz in `ParseProgram`.
- **Sema**: extern-fn-Fehler + scrubbed-ohne-interval-Warnung in `sema.pas`.
- **IR**: `TIRModule.UnitIntegrity` speichert das Unit-Level-Attribut.
- **Backend**: `lyxc.lpr` wählt `WriteElf64WithMetaSafe`-Variante wenn `UnitIntegrity.Mode ≠ imNone`.
- **Unterstützte Backends**: x86_64, ARM64, RISC-V.

### VerifyIntegrity() Builtin (v0.9.0 ✅ ABGESCHLOSSEN – aerospace-todo P0 #45/#46)

Die `VerifyIntegrity()` Funktion führt zur Laufzeit einen TMR (Triple Modular Redundancy) Mehrheitsentscheid durch:

```ebnf
VerifyIntegrityCall = "VerifyIntegrity" "(" ")" ;
CallExpr            = VerifyIntegrityCall | Ident "(" [ ArgList ] ")" | Ident "::" Ident "(" [ ArgList ] ")" ;
```

**Semantik:**
- Rückgabetyp: `bool` — `true` wenn 2 von 3 CRC32-Hashes übereinstimmen, sonst `false`
- Parameter: keine
- Die 3 CRC32-Hashes werden zur Compile-Zeit berechnet und in den Data-Buffer geschrieben
- Zur Laufzeit liest der generierte Code alle 3 Hashes und führt einen Mehrheitsvergleich durch

**Beispiel:**
```lyx
@integrity(mode: scrubbed, interval: 100)
unit;

fn main(): int64 {
  if (VerifyIntegrity()) {
    return 0;  // Integrity verified
  } else {
    return 1;  // Integrity check failed
  }
}
```

**Compiler-Architektur:**
- **Sema**: `VerifyIntegrity() -> bool` als globales Builtin registriert
- **IR**: Neue Operation `irVerifyIntegrity`
- **Backend x86_64**: Generiert `movabs rdi, data_va` + 3x `mov` + 3x `cmp`/`inc` + `cmp $2`/`jge`
- **Patching**: CRC32 wird NACH Code-Generierung berechnet, dann Data-Adresse gepatcht

### Endianness-Annotationen (v0.9.0 ✅ ABGESCHLOSSEN – aerospace-todo P2 #52)

Structs können mit `@big_endian` oder `@little_endian` annotiert werden für Telemetrie-Daten:

```ebnf
EndianAttr    = "@big_endian" | "@little_endian" ;
StructDecl    = [ EndianAttr ] "struct" "{" { StructField } "}" ;
StructField   = Ident ":" Type ";" ;
```

**Semantik:**
- `@big_endian`: Struct-Felder werden in Big-Endian-Byte-Reihenfolge serialisiert
- `@little_endian`: Struct-Felder werden in Little-Endian-Byte-Reihenfolge serialisiert
- Ohne Annotation: Native Endianness der Zielarchitektur (x86_64 = LE, ARM64 = LE, PowerPC = BE)
- Kombinierbar mit `@packed` für hardwarenahe Register-Strukturen

**Beispiel:**
```lyx
type TelemetryFrame = @big_endian struct {
  timestamp: int64;
  temperature: int16;
  status_flags: int8;
};
```

**Compiler-Architektur:**
- **Lexer**: `tkBigEndian`, `tkLittleEndian` Tokens (erkennt `@big_endian`/`@little_endian` als einzelne Tokens)
- **Backend-Typen**: `TEndianType = (enNative, enBigEndian, enLittleEndian)`
- **AST**: `FEndian: TEndianType` in `TAstStructDecl`
- **Parser**: Endian-Annotation wird in `ParseTypeDecl` vor `struct` geparst

### Verschachtelte Funktionen (Nested Functions)

Seit v0.5.3 können Funktionen innerhalb anderer Funktionen deklariert werden.
Sie werden während des Lowering auf Top-Level gehoben (Lifting). Seit v0.5.3+
unterstützen sie **Closures** — Zugriff auf Variablen des umgebenden Scopes
via Static-Link (Parent-RBP als versteckter Parameter).

```ebnf
Block = "{" { Statement } "}"
Statement = VarDecl | IfStmt | WhileStmt | ReturnStmt | AssignStmt | ExprStmt | Block | NestedFnDecl
```

Beispiel (Closure):
```lyx
fn outer(): int64 {
  var x: int64 := 42;
  fn inner(): int64 {
    return x;  // greift auf x aus outer() zu (Closure)
  }
  return inner();
}
```

Einschränkungen:
- Closures sind read-only — Variablen aus dem äußeren Scope können nicht verändert werden
- Max. Verschachtelungstiefe: beliebig (jede Ebene bekommt einen Static-Link)
- Kein Heap-Allokation — Static-Link nutzt bestehende Stack-Frames

Beispiele:
```lyx
@energy(1)
fn low_power_mode(): int64 {
  // Kompiliert mit Energy-Level 1 (minimal)
  return 0;
}

@energy(5)
fn high_performance(): int64 {
  // Kompiliert mit Energy-Level 5 (extrem)
  return compute();
}
```

### Energy-Levels

| Level | Name | Loop Unroll | Battery | SIMD | FPU |
|-------|------|-------------|---------|------|-----|
| 1 | Minimal | 4× | ✅ | — | — |
| 2 | Low | 2× | ✅ | — | — |
| 3 | Medium | 1× | ✅ | ✅ | — |
| 4 | High | — | ✅ | ✅ | ✅ |
| 5 | Extreme | 8× | ✅ | ✅ | ✅ |

---

## 2) Typen

### Primitive Typen

* `int64`  (signed 64-bit, bestehender Haupttyp)
* `int8`, `int16`, `int32`, `int64`  (signed Integer-Familie, Kurzform: **int**)
* `uint8`, `uint16`, `uint32`, `uint64`  (unsigned Integer-Familie, Kurzform: **uint**)
* `f32`, `f64`  (Floating-Point Typen: 32-bit und 64-bit)
* `bool`   (`true` / `false`)
* `void`   (nur als Funktionsrückgabetyp)
* `pchar`  (Pointer, 64-bit; non-nullable, Standard für Stringliterale)
* `pchar?` (Nullable Pointer, kann `null` sein)
* `array`  (Dynamic Array mit Fat-Pointer: ptr/len/cap, heap-allokiert)
* `parallel Array<T>` (SIMD-optimiertes, heap-allokiertes Array mit Element-Typ T; ✅ v0.2.2)
* `Map<K, V>` (Hash-Map mit Key-Typ K und Value-Typ V; v0.5.0)
* `Set<T>` (Hash-Set mit Element-Typ T; v0.5.0)

### SIMD / ParallelArray (v0.2.2 ✅ ABGESCHLOSSEN)

ParallelArrays sind heap-allokierte, SIMD-optimierte Arrays mit einem festen Element-Typ:

```lyx
var vec: parallel Array<Int64> := parallel Array<Int64>(1000);
var first: int64 := vec[0];       // Skalar-Rückgabe
vec[0] := 42;                      // Element-Zuweisung
var sum: parallel Array<Int64> := vec + vec;  // element-weise SIMD-Op
```

**Element-Typen**: `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `F32`, `F64`

**SIMD-Operatoren** (element-weise): `+`, `-`, `*`, `/`, `&&`, `||`, `^`, `==`, `!=`, `<`, `<=`, `>`, `>=`

**Speichermodell**:
- Heap-allokiert via `irAlloc`/mmap mit 16-Byte-Alignment (SSE2)
- Gespeichert als einzelner Pointer-Slot im Stack-Frame
- Index-Zugriff gibt einen Skalar des Element-Typs zurück

### Nullable Typen (v0.4.0 ✅ ABGESCHLOSSEN)

### Panic und Assert (v0.3.2 ✅ ABGESCHLOSSEN)

### check() Builtin (v0.8.1 ✅ ABGESCHLOSSEN)

```ebnf
CheckExpr := 'check' '(' Expr ')' ;
```

`check(cond)` ist eine runtime-only Assertion ohne Fehlermeldung. Wenn die Bedingung `false` ist, wird `panic` aufgerufen (Exit-Code 1).

```lyx
fn main(): int64 {
  check(x > 0);  // panic wenn x <= 0
  return 0;
}
```

### Enum-Deklarationen (v0.5.7 ✅ ABGESCHLOSSEN)

```ebnf
EnumDecl    := 'enum' Ident '{' EnumBody '}' ';'? ;
EnumBody    := EnumMember { ',' EnumMember } ;
EnumMember  := Ident [ '=' IntLiteral ] ;
EnumAccess  := Ident '::' Ident ;
```

Enum-Werte sind implizit `int64`. Der erste Wert startet bei 0 (sofern nicht explizit angegeben).

```lyx
enum Direction { North, South, East, West }
enum HttpStatus { Ok = 200, NotFound = 404, ServerError = 500 }

var d: int64 := Direction::North;   // 0
var s: int64 := HttpStatus::Ok;     // 200
```

### Generics / Parametrische Polymorphie (v0.5.7 ✅ ABGESCHLOSSEN)

```ebnf
GenericFnDecl  := 'fn' Ident '[' TypeParamList ']' '(' [ ParamList ] ')' [ ':' Type ] Block ;
TypeParamList  := Ident { ',' Ident } ;
GenericCall    := Ident '[' TypeArgList ']' '(' [ ArgList ] ')' ;
TypeArgList    := Type { ',' Type } ;
```

Generics werden über **Monomorphisierung** implementiert: Pro Typ-Argument wird eine spezialisierte Funktion erzeugt (z.B. `max_G_int64`).

```lyx
fn max[T](a: T, b: T): T {
  if (a > b) { return a; }
  return b;
}

fn main(): int64 {
  var m: int64 := max[int64](10, 20);  // spezialisiert zu max_G_int64
  return 0;
}
```

### Pattern Matching (v0.5.7 ✅ ABGESCHLOSSEN)

```ebnf
MatchStmt   := 'match' Expr '{' { CaseClause } [ DefaultClause ] '}' ;
CaseClause  := 'case' CaseValue { '|' CaseValue } '=>' Block ;
CaseValue   := Expr ;
DefaultClause := 'default' '=>' Block ;
```

**Unterschiede zu `switch`:**
- Kein `(` `)` um den Match-Ausdruck
- `=>` statt `:` als Trennzeichen
- `|` für OR-Patterns innerhalb eines `case`
- Kein `break` nötig (kein Fall-Through)

```lyx
fn classify(n: int64): int64 {
  match n {
    case 0 => { return 0; }
    case 1 | 2 | 3 => { return 1; }
    default => { return 2; }
  }
}
```

### Tuple-Rückgaben (v0.5.7 ✅ ABGESCHLOSSEN)

```ebnf
TupleReturnType := '(' Type { ',' Type } ')' ;
TupleReturnExpr := '(' Expr { ',' Expr } ')' ;
TupleUnpack     := 'var' Ident { ',' Ident } ':=' CallExpr ';' ;
FnDeclReturn    := ':' ( Type | TupleReturnType ) ;
```

```lyx
fn divmod(a: int64, b: int64): (int64, int64) {
  return (a / b, a % b);
}

fn main(): int64 {
  var q, r := divmod(17, 5);
  return 0;
}
```

### Ausnahmebehandlung / Exception Handling (v0.5.7 ✅ ABGESCHLOSSEN)

```ebnf
TryStmt    := 'try' Block 'catch' '(' Ident ':' Type ')' Block ;
ThrowStmt  := 'throw' Expr ';' ;
```

```lyx
fn risky(x: int64): int64 {
  if (x < 0) { throw -1; }
  return x * 2;
}

fn main(): int64 {
  try {
    var r: int64 := risky(-5);
  } catch (e: int64) {
    PrintStr("caught\n");
  }
  return 0;
}
```

### Map und Set (v0.5.0 ✅ ABGESCHLOSSEN)

Maps und Sets sind heap-allokierte assoziative Datenstrukturen mit linearer Suche (O(n) Lookup).

**Grammatik:**
```
MapType       := 'Map' '<' Type ',' Type '>' ;
SetType       := 'Set' '<' Type '>' ;
MapLiteral    := '{' [ MapEntry { ',' MapEntry } ] '}' ;
SetLiteral    := '{' Expr { ',' Expr } '}' ;
MapEntry      := Expr ':' Expr ;
InExpr        := Expr 'in' Expr ;
MapIndexExpr  := Expr '[' Expr ']' ;
MapIndexAssign := Expr '[' Expr ']' ':=' Expr ;
```

**Map-Literal (Key-Value-Paare mit Doppelpunkt):**
```lyx
var scores: Map<int64, int64> := {1: 100, 2: 200, 3: 300};
var empty: Map<int64, int64> := {};
```

**Set-Literal (Werte ohne Doppelpunkt):**
```lyx
var ids: Set<int64> := {10, 20, 30};
```

**Implementierte Operationen:**

| Operation | Syntax | Beschreibung |
|-----------|--------|--------------|
| Insert/Update | `map[key] := value` | Setzt oder überschreibt Key |
| Get | `map[key]` | Gibt Value zurück |
| Contains | `key in map` | Prüft Existenz (bool) |
| Size | `len(map)` | Anzahl Einträge |
| Set Add | via Literal | Erstellt Set mit Werten |
| Set Contains | `value in set` | Prüft Mitgliedschaft (bool) |

**Erlaubte Key/Element-Typen:** `int64`, `bool` (aktuell)
**Value-Typen (Map):** `int64` (aktuell)

**Speichermodell:**
- Heap-allokiert via `mmap` syscall
- Layout: `[len:8 bytes][cap:8 bytes][entries:16*cap bytes]`
- Entry-Format: `[key:8 bytes][value:8 bytes]`
- Lineare Suche O(n) — geeignet für kleine Sammlungen (< 100 Einträge)
- Initiale Kapazität: 8 Entries

**IR-Opcodes:**
- `irMapNew`, `irMapSet`, `irMapGet`, `irMapContains`, `irMapLen`
- `irSetNew`, `irSetAdd`, `irSetContains`, `irSetLen`

**Nicht implementiert (geplant):**
- `remove()` — Löschen von Einträgen
- `keys()` / `values()` — Iteratoren
- `for key, value in map` — Iteration
- Hash-basierter O(1) Lookup mit FNV-1a

### Dynamic Arrays (v0.5.7 ✅ ABGESCHLOSSEN)

Dynamic Arrays sind heap-allokierte Arrays mit Fat-Pointer (ptr/len/cap):

| Operation | Syntax | Beschreibung |
|-----------|--------|--------------|
| Create | `var a: array := [];` | Leeres Array erstellen |
| Create with literal | `var a: array := [1, 2, 3];` | Array mit Initialwerten |
| Push | `push(a, value)` | Element am Ende hinzufügen |
| Length | `len(a)` | Anzahl Elemente |
| Pop | `pop(a)` | Letztes Element entfernen und zurückgeben |
| Index | `a[i]` | Element lesen/schreiben |
| Free | `free(a)` | Speicher freigeben |

**Speichermodell:**
- Fat-Pointer (3 × 8 bytes): `[ptr:8][len:8][cap:8]`
- ptr zeigt auf heap-allokierten Speicher (via mmap)
- Automatisches Resizing bei `push` wenn Kapazität erreicht

**IR-Opcodes:**
- `irDynArrayPush`, `irDynArrayLen`, `irDynArrayPop`, `irDynArrayFree`

**Beispiele:**
```lyx
fn main(): int64 {
  var a: array := [];
  push(a, 10);
  push(a, 20);
  push(a, 30);
  
  PrintInt(len(a));  // 3
  
  var x: int64 := pop(a);  // x = 30
  PrintInt(len(a));  // 2
  
  free(a);
  return 0;
}
```

### Regex-Literale (v0.4.2 ✅ ABGESCHLOSSEN)

### Inkrement- und Dekrement-Operatoren (✅ ABGESCHLOSSEN)

Die Operatoren `++` und `--` sind als **Postfix-Statements** verfügbar:

```
IncDecStmt      := LValue ( '++' | '--' ) ';' ;
LValue          := Ident { FieldOrIndexSuffix } ;
FieldOrIndexSuffix
                := '.' Ident
                | '[' Expr ']' ;
```

**Desugaring:**
- `x++` wird zu `x := x + 1`
- `x--` wird zu `x := x - 1`

**Beispiele:**
```lyx
counter++;           // counter := counter + 1
arr[idx]++;          // arr[idx] := arr[idx] + 1
player.health--;     // player.health := player.health - 1
```

**Wichtig:** Dies sind Statements, keine Expressions. Sie können nicht in Ausdrücken verwendet werden.

### Return-Regeln

* Funktion mit Rückgabetyp `int64/bool/pchar/f64` muss auf allen Pfaden `return <expr>;` liefern
* Funktion mit `void` erlaubt `return;` oder gar keinen return (dann implizit `return;`)

### Type-Casting Regeln

* `as`-Casting ist explizit und erlaubt folgende Konvertierungen:
  * `int64 as f64`: Integer zu Float (SSE2 cvtsi2sd)
  * `f64 as int64`: Float zu Integer mit Truncation (SSE2 cvttsd2si)
  * Identity Casts: `int64 as int64`, `f64 as f64` (No-Op)
* Cast-Kompatibilität wird zur Compile-Zeit geprüft
* Ungültige Casts erzeugen Compile-Fehler

### Bool-Regeln

* `if`/`while` verlangen `bool`
* `&&`/`||` short-circuit (Codegen muss Sprünge setzen)

### Builtin-Funktionen Regeln

* Über 30 Builtin-Funktionen sind ohne Import verfügbar
* Builtins werden nicht als externe Symbole behandelt (statische ELF-Generation)
* String-Builtins arbeiten mit null-terminierten pchar
* Math-Builtins nutzen native x86-64 Instruktionen für maximale Performance

---

## 8) Codegen-Anforderungen (Backend v0.1.7)

### Output

* ELF64 Executable, Linux x86_64
* `_start` als Entry
* Automatische Static/Dynamic ELF Auswahl

### Minimaler Instruction-Satz (Backend-Emitter)

* `mov reg, imm64`
* `mov reg, [rbp-off]` / `mov [rbp-off], reg` (locals)
* `lea reg, [rip+disp32]` (globale Variablen, RIP-relative Adressierung)
* `add/sub/imul/idiv` (int64 arith)
* `cmp` + `setcc`/`cmov` oder Sprünge (bool)
* `jmp`, `je/jne/jl/jle/jg/jge` (control flow)
* `call`, `ret` (Funktionen)
* `syscall` (builtins/entry)

### Heap-Speicher (Klassen)

* `new`: `mmap` syscall für Allokation
* `dispose`: `munmap` syscall für Freigabe
* VMT (Virtual Method Table) für virtuelle Methoden ✅ (v0.5.1)

### Runtime-Snippets (eingebettet)

* `PrintStr`: strlen-loop + write
* `PrintInt`: itoa + write
* `Random`: LCG-Implementierung (seed * 1103515245 + 12345) mod 2^31
* `RandomSeed`: Setzt LCG-Seed im Data-Segment

**Dynamic String Builtins** (mmap-basierte Strings, Header `[cap:8][len:8][data...]`):
* `StrNew(cap)` / `StrFree(s)`: Allokation / Freigabe via mmap/munmap
* `StrLen(s)` / `StrCharAt(s,i)` / `StrSetChar(s,i,c)`: Grundoperationen
* `StrAppend(dest,src)`: Immer-reallozierende Konkatenation, gibt neuen Pointer zurück
* `StrAppendStr(dest,src)`: In-place Append, gibt denselben Pointer zurück
* `StrConcat(a,b)` / `StrCopy(s)`: Neue Puffer-Allokation
* `StrFindChar(s,ch,start)` / `StrSub(s,start,len)`: Suche und Extraktion
* `StrStartsWith(s,prefix)` / `StrEndsWith(s,suffix)` / `StrEquals(a,b)`: Vergleiche
* `IntToStr(n)` / `StrFromInt(n)`: Integer-zu-String-Konvertierung
* `FileGetSize(path)`: Dateigröße via open+lseek+close

**HashMap Builtins** (FNV-1a O(1), string→int64):
* `HashNew(cap)` / `HashSet(m,k,v)` / `HashGet(m,k)` / `HashHas(m,k)`

**Argv Builtins**:
* `GetArgC()` / `GetArg(i)`: Zugriff auf Kommandozeilenargumente

---

## 9) Beispiele

### Hello

```lyx
fn main(): int64 {
  PrintStr("Hello Lyx\n");
  return 0;
}
```

### Globale Variablen

```lyx
var counter: int64 := 0;

fn increment() {
  counter := counter + 1;
}

fn main(): int64 {
  PrintInt(counter);  // 0
  increment();
  increment();
  PrintInt(counter);  // 2
  return 0;
}
```

### Klassen mit Vererbung

```lyx
type Animal = class {
  name: pchar;
  
  fn speak() {
    PrintStr("Some sound\n");
  }
};

type Dog = class extends Animal {
  breed: pchar;
  
  fn speak() {
    PrintStr("Woof!\n");
  }
  
  fn Create(n: pchar, b: pchar) {
    self.name := n;
    self.breed := b;
  }
  
  fn Destroy() {
    PrintStr("Dog destroyed\n");
  }
};

fn main(): int64 {
  var d: Dog := new Dog("Buddy", "Labrador");
  d.speak();              // "Woof!"
  dispose d;
  return 0;
}
```

### Virtual Methods und VMT

Virtuelle Methoden ermöglichen Polymorphismus durch eine Virtual Method Table (VMT):

```lyx
type TBase = class {
  val: int64;
  
  // Virtual method - can be overridden
  virtual fn GetValue(): int64 {
    return self.val;
  }
};

type TDerived = class extends TBase {
  extra: int64;
  
  // Override the virtual method from base class
  override fn GetValue(): int64 {
    return self.val + self.extra;
  }
};

fn main(): int64 {
  var base: TBase := new TBase();
  base.val := 10;
  
  var derived: TDerived := new TDerived();
  derived.val := 20;
  derived.extra := 30;
  
  // Polymorphic calls via VMT
  PrintInt(base.GetValue());    // Calls TBase.GetValue() -> 10
  PrintInt(derived.GetValue()); // Calls TDerived.GetValue() -> 50
  
  dispose base;
  dispose derived;
  return 0;
}
```

**Grammatik für virtuelle und abstrakte Methoden:**

```
ClassDecl       := 'type' Ident '=' 'class' [ 'extends' Ident ] '{' { ( FieldDecl | MethodDecl ) } '}' ;
MethodDecl      := [ ( 'virtual' | 'override' | 'abstract' ) ] 'fn' Ident '(' [ ParamList ] ')' [ ':' Type ] ( Block | ';' ) ;
VirtualFlag     := 'virtual' ;
OverrideFlag    := 'override' ;
AbstractFlag    := 'abstract' ;
```

**VMT-Semantik:**
- `virtual fn` deklariert eine Methode als virtuell. Die Methode erhält einen festen Slot in der VMT der Klasse.
- `override fn` überschreibt eine virtuelle Methode der Basisklasse. Der Slot bleibt erhalten.
- `abstract fn` deklariert eine Methode ohne Implementierung. Die Methode muss von einer konkreten Subklasse überschrieben werden.
- `abstract` impliziert automatisch `virtual`.
- Virtuelle Methodenaufrufe werden zur Laufzeit über die VMT dispatcht.
- Ohne `virtual`/`override`/`abstract` wird die Methode statisch gebunden (direkter `call`).

**Abstract-Syntax:**
```
type Animal = class {
  abstract fn Speak(): int64;
};

type Dog = class extends Animal {
  override fn Speak(): int64 { return 1; }
};
```

**Fehler bei Abstrakten Klassen:**
- Eine Klasse mit mindestens einer abstrakten Methode ist abstrakt und kann nicht instanziiert werden.
- Compiler-Fehler: `cannot instantiate abstract class: <ClassName>`

**Beispiel-VMT-Layout:**
```
[type TBase]:
  .data:
    _vmt_TBase:
      dq _L_TBase_GetValue    ; VMT-Index 0

[type TDerived]:
  .data:
    _vmt_TDerived:
      dq _L_TDerived_GetValue  ; überschreibt TBase.GetValue
```

### Random

```lyx
fn main(): int64 {
  RandomSeed(42);
  
  var r1: int64 := Random();
  var r2: int64 := Random();
  
  PrintInt(r1);
  PrintStr("\n");
  PrintInt(r2);
  return 0;
}
```

### Bitweise Operatoren

```lyx
fn main(): int64 {
  var a: int64 := 12;
  var b: int64 := 10;

  PrintInt(a & b);    // AND:  8
  PrintInt(a | b);    // OR:  14
  PrintInt(a ^ b);    // XOR:  6
  PrintInt(1 << 4);   // SHL: 16
  PrintInt(256 >> 3); // SHR: 32
  PrintInt(~0);       // NOT: -1

  // Kombination: Mask-and-Shift
  var flags: int64 := (5 << 4) | 3;  // = 83
  PrintInt(flags);

  return 0;
}
```

**Präzedenz** (niedrig → hoch): `||` → `&&` → `|` → `^` → `&` → Vergleich → `<< >>` → `+ -` → `* / %` → Unär (`! - ~`)

### Variablen + while + Type-Casting

```lyx
con LIMIT: int64 := 5;

fn main(): int64 {
  var i: int64 := 0;
  while (i < LIMIT) {
    PrintInt(i);
    PrintStr("\n");
    
    // Type-Casting Beispiel
    var f: f64 := i as f64;
    var sqrt_val: f64 := sqrt(f);
    var back_to_int: int64 := sqrt_val as int64;
    
    // String-Konvertierung
    var str_val: pchar := int_to_str(i);
    PrintStr("String: ");
    PrintStr(str_val);
    PrintStr("\n");
    
    i := i + 1;
  }
  return 0;
}
```

### Module-System Beispiel

```lyx
unit math.utils;

import std.string;

pub fn factorial(n: int64): int64 {
  if (n <= 1) { return 1; }
  return n * factorial(n - 1);
}

pub fn format_number(x: int64): pchar {
  return int_to_str(abs(x));
}
```

... (rest unchanged)

Diese Erweiterung passt zu Lyxs Pascal-ähnlichem Stil, erweitert um AI/ML-Features aus Sever/A.[web:21][page:0] Der Parser braucht ~10 neue Regeln; Codegen kann LLVM/CUDA-Backend nutzen für GPU (z. B. via FFI zu cuBLAS).[cite:15]

## Implementierungs-Hinweise
- **Tensor-Codegen**: Compiler erzeugt CUDA-Kernels; Fallback zu CPU via OpenBLAS.
- **Probabilistic**: Zero-Cost Abstractions – option/result als Tagged Unions (1 Byte Discriminant).
- **GPU-Setup**: Built-in `@gpu` triggert Linker-Flags (-lcudart); für Linux/RTX3060.[cite:12]
- **Nächster Schritt**: Vollständige EBNF-Datei oder Parser-Test in Rust/Lark generieren?
