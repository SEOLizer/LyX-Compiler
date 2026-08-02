# Lyx 1.0.11C — Canonical EBNF Grammar

> Stand 2026-08-01, gegen lyxc 1.0.11C geprueft. Die Keyword-Liste in
> Abschnitt 2.1 wurde Wort fuer Wort gegen den Compiler verifiziert; die
> Typgrammatik in Abschnitt 7 ist um Funktions- und Methodenzeiger ergaenzt,
> und die match-Produktion in Abschnitt 12 entspricht jetzt dem Parser.
> Bekannte Abweichungen zwischen Grammatik und Compiler stehen in 20.1.

Status: Draft
Target parser: Recursive Descent + Pratt Expression Parser
Scope: Concrete syntax only.

---

# 1. Lexical Grammar

```ebnf
Letter              = "A"…"Z" | "a"…"z" | "_" ;
Digit               = "0"…"9" ;
HexDigit            = Digit | "A"…"F" | "a"…"f" ;
BinaryDigit         = "0" | "1" ;
OctalDigit          = "0"…"7" ;

Ident               = ( Letter | "_" ) { Letter | Digit | "_" } ;

(* Der Unterstrich fehlte hier, obwohl er ueberall verwendet wird -- auch
   fuehrend (`_thrCtl`, `cg_genCall`). Geprueft: `my_var`, `_x` und `x1` sind
   gueltig, `1x` nicht. *)

DecimalLiteral      = Digit { Digit | "_" } ;

HexLiteral          = ( "0x" | "0X" | "$" )
                      HexDigit { HexDigit | "_" } ;

BinaryLiteral       = ( "0b" | "0B" | "%" )
                      BinaryDigit { BinaryDigit | "_" } ;

OctalLiteral        = ( "0o" | "0O" | "&" )
                      OctalDigit { OctalDigit | "_" } ;

IntLiteral          = DecimalLiteral
                    | HexLiteral
                    | BinaryLiteral
                    | OctalLiteral ;

FloatLiteral        = Digit { Digit | "_" }
                      "."
                      Digit { Digit | "_" } ;

StringLiteral       = '"'
                      { StringChar | EscapeSequence }
                      '"' ;

StringChar          = ? any Unicode scalar value except '"', '\', CR, LF ? ;

EscapeSequence      = "\\" ( "n" | "r" | "t" | "\\" | '"' | "0" ) ;

BoolLiteral         = "true" | "false" ;
NullLiteral         = "null" ;

Literal             = IntLiteral
                    | FloatLiteral
                    | StringLiteral
                    | BoolLiteral
                    | NullLiteral ;
```

## 1.1 Lexer Disambiguation Rules

```text
The lexer SHALL use longest-match tokenization.

The token "??" SHALL be recognized before "?".

The token "?." SHALL be recognized before "?".

The token "|>" SHALL be recognized before "|".

The token "|~" SHALL be recognized before "|".

The token "..." SHALL be recognized before "..".
The token ".." SHALL be recognized before ".".

A "." following an integer literal begins a FloatLiteral only if the next character is Digit.
Otherwise "." SHALL be emitted as a Dot token.

Examples:
42.0        => FloatLiteral
42.toStr()  => IntLiteral "." Ident "(" ")"
42.member   => IntLiteral "." Ident
```

---

# 2. Keywords

## 2.1 Reserved Keywords

Diese 70 Woerter sind reserviert und koennen nicht als Bezeichner
verwendet werden. Die Liste ist gegen den Compiler geprueft: jedes Wort wurde
als Variablenname eingesetzt und muss einen Fehler ausloesen.

```text
abstract and array as assert
break case catch class co
con continue default dim dispose
do downto else enum extends
extern false finally fn for
if implements import in interface
is layout let Map match
new not null or override
panic parallel pool private protected
pub public repeat return RingBuffer
self Set signal static struct
super switch throw to true
try type unit until utype
var virtual where while widget
```

Zwei Sonderfaelle:

- `self` steht nicht in der Keyword-Tabelle des Lexers, sondern wird im Parser
  gesondert behandelt (`src/parser.lyx`) — reserviert ist es dennoch.
- `char` steht umgekehrt in der Keyword-Tabelle, laesst sich aber als Bezeichner
  verwenden: es ist ein Typname, kein reserviertes Wort.

Fruehere Fassungen dieses Dokuments fuehrten ausserdem `Self`, `flat`, `packed`,
`check` und `limit` als reserviert. Das trifft nicht zu; alle fuenf sind als
Bezeichner verwendbar.

## 2.2 Soft Keywords

```text
range wraps defer
```

Soft keywords are tokenized as identifiers and interpreted contextually by the parser.

Hinweis zur Geschichte: `defer` lief in einem inneren Block lange am
Funktionsende statt am Blockende (#1006, samt Argument-Zeitpunkt #1030), und
`range(N)` erzeugte gar keinen Code (#1007). Beides ist behoben.

```text
"defer" is recognized as DeferStmt only when an identifier token with text "defer"
appears in statement position and is followed by a token sequence that can start a Statement.

Otherwise, "defer" remains a normal identifier.
```

---

# 3. Program Structure

```ebnf
Program             = [ UnitDecl ] { TopDecl } EOF ;

UnitDecl            = [ IntegrityAttr ] "unit" [ DotPath ] ";" ;

DotPath             = Ident { "." Ident } ;

TopDecl             = ImportDecl
                    | ConstDecl
                    | VarDecl
                    | FnDecl
                    | ExternFnDecl
                    | ExternDataDecl
                    | TypeDecl
                    | EnumDecl
                    | DimDecl
                    | UtypeDecl
                    | Directive ;

ImportDecl          = "import" ImportItem { "," ImportItem } ";" ;

ImportItem          = DotPath
                      [ "grant"    "[" CapabilityList "]" ]
                      [ "restrict" "[" CapabilityList "]" ] ;
```

---

# 4. Attributes and Directives

```ebnf
Visibility          = "pub" ;

Directive           = IoCheckDirective
                    | OverflowCheckDirective
                    | BoundsCheckDirective
                    | DebugInfoDirective
                    | OptimizationLevelDirective ;

IoCheckDirective            = "@io_check" "(" BoolLiteral ")" ";" ;
OverflowCheckDirective      = "@overflow_check" "(" BoolLiteral ")" ";" ;
BoundsCheckDirective        = "@bounds_check" "(" BoolLiteral ")" ";" ;
DebugInfoDirective          = "@debug_info" "(" BoolLiteral ")" ";" ;
OptimizationLevelDirective  = "@optimization_level" "(" IntLiteral ")" ";" ;

FuncAttr            = EnergyAttr
                    | DalAttr
                    | CriticalAttr
                    | WcetAttr
                    | StackLimitAttr
                    | IntegrityAttr
                    | FlightCritAttr
                    | CapabilityAttr
                    | UsesCallerCap ;

EnergyAttr          = "@energy" "(" IntLiteral ")" ;

DalAttr             = "@dal" "(" DalLevel ")" ;
DalLevel            = "A" | "B" | "C" | "D" ;

CriticalAttr        = "@critical" ;

WcetAttr            = "@wcet" "(" IntLiteral ")" ;

StackLimitAttr      = "@stack_limit" "(" IntLiteral ")" ;

FlightCritAttr      = "@flight_crit" ;

IntegrityAttr       = "@integrity" "(" IntegrityParams ")" ;

IntegrityParams     = IntegrityMode [ "," IntegrityInterval ] ;

IntegrityMode       = "mode" ":"
                      ( "software_lockstep"
                      | "scrubbed"
                      | "hardware_ecc" ) ;

IntegrityInterval   = "interval" ":" IntLiteral ;

VarAttr             = "@redundant"
                    | "@volatile"
                    | "@align" "(" IntLiteral ")" ;
(* "@align(N) var ..." — Allokations-Alignment (N Bytes) für array/heap-backed Locals.
   LyxOS: über-alloziert + rundet Pointer auf N auf (emitAlloc). Skalare Stack-Locals: n/a. *)

EndianAttr          = "@big_endian"
                    | "@little_endian" ;
```

---

# 5. Declarations

```ebnf
ConstDecl           = [ Visibility ]
                      "con"
                      Ident
                      ":"
                      Type
                      ":="
                      ConstExpr
                      ";" ;

VarDecl             = [ Visibility ]
                      { VarAttr }
                      VarKind
                      IdentList
                      ":"
                      Type
                      [ ":=" Expr ]
                      ";" ;

VarKind             = "var" | "let" | "co" ;

(* `let` und `co` binden einmal: eine Zuweisung nach der Initialisierung
   wird abgewiesen. `var` bleibt beschreibbar. Bis 1.0.11D trug `let` den
   Schutz nur im Namen und `co` wurde vom Parser gar nicht angenommen --
   siehe #1083. *)

IdentList           = Ident { "," Ident } ;
```

---

# 6. Functions

```ebnf
FnDecl              = { FuncAttr }
                      [ Visibility ]
                      "fn"
                      Ident
                      [ TypeParamClause ]
                      "(" [ ParamList ] ")"
                      [ ":" ReturnType ]
                      Block ;

NestedFnDecl        = "fn"
                      Ident
                      [ TypeParamClause ]
                      "(" [ ParamList ] ")"
                      [ ":" ReturnType ]
                      Block ;

ExternFnDecl        = [ "@cap" "(" CapabilityPath ")" ]
                      "extern"
                      "fn"
                      Ident
                      "(" [ ParamList ] ")"
                      [ ":" Type ]
                      "link"
                      StringLiteral
                      ";" ;

(* WSP-07: externes Daten-Symbol. Der Linkage-String steht DIREKT nach `extern`
   (Unterscheidung von ExternFnDecl, wo `fn` folgt). Der Bezeichner liefert an
   jeder Nutzung die ADRESSE des Symbols; sie wird zur Link-Zeit von `ld` aufgelöst
   (z.B. Linker-Skript-Symbole __kernel_start/__kernel_end). Erfordert Ausgabe als
   relocatable Objekt (`--emit=obj`); ohne Objektmodus ist es ein Compile-Fehler. *)
ExternDataDecl      = "extern" StringLiteral Ident ":" Type ";" ;

TypeParamClause     = "<" TypeParamList ">" ;

TypeParamList       = Ident { "," Ident } ;

(* Die eckige Form `[T]` stand hier frueher und war nie gueltig -- der Parser
   erwartet spitze Klammern. `tests/generics_monomorph_test.lyx` folgte der
   alten Angabe und scheiterte deshalb.

   Auch mit `<T>` ist das Feature nicht nutzbar: die Deklaration parst, die
   Semantikpruefung loest den Typparameter aber nicht auf
   ("unknown param type"). Generische TYPEN (`type P<T> = struct {...}`)
   werden ueberhaupt nicht angenommen -- TypeParamClause steht daher nur an
   Funktionen, nicht an Typdeklarationen. Siehe 20.1 und Issue #1009. *)

ParamList           = Param { "," Param } ;

Param               = [ "con" ] Ident ":" Type [ "=" Expr ] ;

ReturnType          = Type | TupleType ;
```

---

# 7. Type Grammar

```ebnf
TypeDecl            = [ Visibility ] "type" Ident "=" TypeDef ";" ;

TypeDef             = Type
                    | RangeTypeDef
                    | StructDef
                    | FlatStructDef
                    | PackedStructDef
                    | ClassDef ;

RangeTypeDef        = BaseIntType RangeClause ;

RangeClause         = "range" RangeBound ".." RangeBound ;

RangeBound          = [ "-" ] IntLiteral ;

Type                = PrimaryType [ "?" ] ;

PrimaryType         = BuiltinType
                    | Ident
                    | ArrayType
                    | ParallelArrayType
                    | TupleType
                    | MapType
                    | FnPtrType
                    | MethodPtrType ;

BuiltinType         = "bool"
                    | BaseIntType
                    | "f32"
                    | "f64"
                    | "pchar"
                    | "void" ;

BaseIntType         = "int8"  | "i8"
                    | "int16" | "i16"
                    | "int32" | "i32"
                    | "int64" | "i64"
                    | "uint8"  | "u8"
                    | "uint16" | "u16"
                    | "uint32" | "u32"
                    | "uint64" | "u64" ;

(* Beide Schreibweisen sind gueltig und bezeichnen denselben Typ; die kurze
   (`u8`) ist im Bestand die haeufigere. Bis 1.0.11B kannte der Compiler die
   kurze Form im var-Deklarator und die lange nur als Feldtyp -- `var x: uint8`
   wurde abgewiesen, `feld: uint8` stillschweigend angenommen (#1010).

   `isize` und `usize` standen hier frueher ebenfalls; der Compiler kennt sie
   nicht (`unknown type in var decl`). *)

(* Es gibt in Lyx KEINEN qualifizierten Zugriff. Weder `Modul::Name` noch
   `Modul.Name` ist gueltig -- Symbole importierter Units liegen in einem
   flachen Namensraum und werden unqualifiziert angesprochen. Frueher stand
   hier `QualifiedIdent = Ident "::" Ident`; `::` erzeugt einen Parse-Fehler. *)

ArrayType           = "array" "[" Type "]"
                    | "Array" "<" Type ">" ;

ParallelArrayType   = "ParallelArray" "<" Type ">" ;

TupleType           = "(" Type "," Type { "," Type } ")" ;

(* Funktions- und Methodenzeiger (seit 1.0.4A). In der Praxis ueber einen
   Typalias verwendet:

       type Cb = fn(int64): int64;
       var f: Cb := dbl;          (* Funktionsname als Wert *)
       f(21)

   Ein Methodenzeiger fuehrt den Empfaenger als ersten Parameter und bindet
   beim Zuweisen die Instanz; intern ist er ein 16-Byte-Paar {Code, Daten}:

       type TM = method(TC): int64;
       btn.on_click := form.Handle;   (* bindet form als self *)
       btn.on_click(rcv)

   Der Typ darf inline geschrieben werden (`var f: fn(int64): int64 := g;`) --
   als lokale Variable, als Parameter und als Feld. Bis 1.0.11B stuerzte der
   AUFRUF eines inline geschriebenen fn-Zeigers ab, weil der Aufrufpfad ihn nur
   am Namen eines Typalias erkannte (#1003); der Typalias war deshalb die
   einzige verlaessliche Form. *)

FnPtrType           = "fn" "(" [ FnPtrParams ] ")" [ ":" Type ] ;

MethodPtrType       = "method" "(" [ FnPtrParams ] ")" [ ":" Type ] ;

FnPtrParams         = FnPtrParam { "," FnPtrParam } ;

FnPtrParam          = [ Ident ":" ] Type ;   (* Parametername optional *)

MapType             = "Map" "<" Type "," Type ">" ;

(* `Set` ist als Wort reserviert, `Set<T>` wird von der Semantikpruefung aber
   nicht aufgeloest ("unknown type in var decl"). Die Form ist fuer spaeter
   vorgesehen und hier bewusst nicht als gueltige Produktion gefuehrt. *)
```

---

# 8. Structs

```ebnf
StructDef           = [ EndianAttr ]
                      "struct"
                      "{"
                      { StructField }
                      "}" ;

FlatStructDef       = "flat"
                      "struct"
                      "{"
                      { StructField }
                      "}" ;

PackedStructDef     = "packed"
                      "struct"
                      "{"
                      { PackedField }
                      "}" ;

StructField         = Ident ":" Type ";" ;

PackedField         = Ident ":" Type [ "at" "(" IntLiteral ")" ] ";" ;
```

`flat` und `packed` sind WEICHE Schluesselwoerter und werden nur unmittelbar
vor `struct` als solche gelesen (§2.1 haelt fest, dass sie nicht reserviert
sind); ueberall sonst bleiben sie gewoehnliche Bezeichner. Beide Formen legen
die Felder ohne Auffuellung hintereinander, jedes so breit wie sein Typ --
dasselbe, was die Annotation `@packed` bewirkt. `at(N)` ist ein **Byte**-Offset
vom Anfang des Structs, kein Bit-Offset. (#1084)

---

# 9. Classes

```ebnf
ClassDef            = [ "abstract" ]
                      "class"
                      [ "extends" Type ]
                      "{"
                      { ClassMember }
                      "}" ;

ClassMember         = FieldDecl
                    | MethodDecl ;

FieldDecl           = [ MemberVisibility ]
                      [ "static" ]
                      Ident
                      ":"
                      Type
                      ";" ;

MethodDecl          = { FuncAttr }
                      [ MemberVisibility ]
                      [ MethodModifier ]
                      "fn"
                      Ident
                      [ TypeParamClause ]
                      "(" [ ParamList ] ")"
                      [ ":" ReturnType ]
                      ( Block | ";" ) ;

MethodModifier      = "static"
                    | "virtual"
                    | "override"
                    | "abstract" ;

MemberVisibility    = "private"
                    | "protected"
                    | "pub" ;
```

---

# 10. Enums

```ebnf
EnumDecl            = [ Visibility ]
                      "enum"
                      Ident
                      "{"
                      EnumBody
                      "}"
                      [ ";" ] ;

EnumBody            = EnumMember { "," EnumMember } [ "," ] ;

EnumMember          = Ident [ "=" IntLiteral ] ;
```

---

# 11. Dimensions and Unit Types

```ebnf
DimDecl             = [ Visibility ]
                      "dim"
                      Ident
                      [ "=" DimExpr ]
                      ";" ;

DimExpr             = DimTerm { ( "*" | "/" ) DimTerm } ;

DimTerm             = Ident ;

UtypeDecl           = [ Visibility ]
                      "utype"
                      Ident
                      ":"
                      Ident
                      "="
                      NumericFactor
                      [ UtypeRangeModifier ]
                      ";" ;

NumericFactor       = IntLiteral | FloatLiteral ;

UtypeRangeModifier  = "range" NumericFactor ".." NumericFactor
                    | "wraps" NumericFactor ".." NumericFactor ;
```

---

# 12. Statements

```ebnf
Block               = "{" { Statement } "}" ;

Statement           = Block
                    | Directive
                    | ConstDecl
                    | VarDecl
                    | TupleUnpackStmt
                    | NestedFnDecl
                    | AssignStmt
                    | IncDecStmt
                    | CompoundAssignStmt
                    | IfStmt
                    | WhileStmt
                    | ForStmt
                    | RepeatStmt
                    | SwitchStmt
                    | MatchStmt
                    | TryStmt
                    | ThrowStmt
                    | ReturnStmt
                    | BreakStmt
                    | ContinueStmt
                    | DeferStmt
                    | AsmStmt
                    | ExprStmt ;

TupleUnpackStmt     = "var"
                      Ident
                      ","
                      Ident
                      { "," Ident }
                      ":="
                      Expr
                      ";" ;

AssignStmt          = LValue ":=" Expr ";" ;

IncDecStmt          = LValue ( "++" | "--" ) ";" ;

(* Compound assignment: `x += y` desugars to `x := x + y` (likewise -= *= /= %=). *)
CompoundAssignStmt  = LValue ( "+=" | "-=" | "*=" | "/=" | "%=" ) Expr ";" ;

IfStmt              = "if"
                      "(" Expr ")"
                      Block
                      [ "else" ElseBranch ] ;

ElseBranch          = IfStmt | Block ;

WhileStmt           = "while"
                      "(" Expr ")"
                      [ "limit" "(" ConstExpr ")" ]
                      Block ;

ForStmt             = ForRangeStmt
                    | ForCStyleStmt ;

ForRangeStmt        = "for"
                      Ident
                      ":="
                      Expr
                      ( "to" | "downto" )
                      Expr
                      [ "do" ]
                      Block ;

ForCStyleStmt       = "for"
                      Ident
                      ":="
                      Expr
                      ";"
                      [ Expr ]
                      ";"
                      [ ForStep ]
                      [ "do" ]
                      Block ;

ForStep             = LValue ( "++" | "--" | ":=" Expr ) ;

RepeatStmt          = "repeat"
                      Block
                      "until"
                      "(" Expr ")"
                      ";" ;

SwitchStmt          = "switch"
                      "(" Expr ")"
                      "{"
                      { SwitchCase }
                      [ SwitchDefault ]
                      "}" ;

SwitchCase          = "case" ConstExpr ":" { Statement } ;

SwitchDefault       = "default" ":" { Statement } ;

MatchStmt           = "match"
                      [ "(" ] Expr [ ")" ]
                      "{"
                      { MatchCase }
                      "}" ;

MatchCase           = "case"
                      Pattern
                      { "|" Pattern }
                      [ "if" Expr ]          (* Guard *)
                      "=>"
                      ( Expr | Block )
                      [ ";" ] ;

(* Dieselbe Form ist auch als Ausdruck verwendbar (Abschnitt 15,
   PrimaryExpr -> MatchExpr) und liefert dann den Wert des getroffenen
   Fallrumpfes; trifft kein Fall, ist das Ergebnis 0.

   Ein BLOCK als Fallrumpf traegt eine Anweisungsfolge -- das ist der Weg zu
   mehreren Schritten je Zweig, denn eine Zuweisung ist in Lyx kein Ausdruck.
   Als Ausdruck benutzt liefert ein Block den Wert seiner LETZTEN Anweisung,
   sofern das ein Ausdruck ist; sonst 0. *)

MatchExpr           = MatchStmt ;

(* Korrekturen gegenueber frueheren Fassungen dieses Dokuments:
   - Der Guard (`case p if cond => ...`) fehlte hier ganz, existiert aber.
   - Ein `MatchDefault` mit dem Wort `default` gibt es NICHT -- der Parser
     erwartet `case`. Der Auffangfall wird als `case _ =>` geschrieben.
   - Der Fallrumpf durfte bis 1.0.11C nur ein AUSDRUCK sein; seit #1024 ist
     auch ein Block zugelassen. *)

TryStmt             = "try"
                      Block
                      "catch"
                      "(" Ident ":" Type ")"
                      Block ;

ThrowStmt           = "throw" Expr ";" ;

ReturnStmt          = "return" [ Expr ] ";" ;

BreakStmt           = "break" ";" ;

ContinueStmt        = "continue" ";" ;

DeferStmt           = "defer" Statement ;

AsmStmt             = "asm" "{" { StringLiteral } "}" ;

ExprStmt            = Expr ";" ;
```

## 12.2 Inline-Assembly Rule (WSP-05)

```text
"asm" is a soft keyword: it is recognized as AsmStmt only when an identifier
token with text "asm" appears in statement position and is immediately followed
by "{". Otherwise "asm" remains a normal identifier.

Each StringLiteral in the block is one instruction mnemonic. The accepted
mnemonic set is ARCHITECTURE-SPECIFIC (chosen by the compilation --target):

    x86-64 / lyxos : cli sti hlt nop pause cpuid iretq wbinvd invd sfence
                     lfence mfence rdtsc ud2 int3 leave ret
                     "lgdt [rdi]" "lidt [rdi]" "invlpg [rdi]"
    arm64          : nop wfi wfe sev sevl yield isb dsb dmb svc brk hlt ret eret
    arm-cm4 (Thumb): nop wfi wfe sev yield isb dsb dmb svc bkpt "cpsid i" "cpsie i"
    riscv (linux)  : nop wfi fence fence.i ecall ebreak mret sret
    xtensa (esp32) : nop

A mnemonic not in the target's set is a hard compile error (no silent NOP).
Mnemonics from a different architecture are therefore rejected. The block is
never removed by optimization (each instruction has a side effect).
```

## 12.1 If/Else Binding Rule

```text
The then-branch of an IfStmt SHALL always be a Block.

An "else" branch binds to the nearest preceding IfStmt that does not already have an else branch.

Because the then-branch requires a Block, the classic dangling-else example

    if (a) if (b) { f(); } else { g(); }

is syntactically invalid in Lyx.

The valid form is:

    if (a) {
        if (b) { f(); } else { g(); }
    }
```

---

# 13. LValues

```ebnf
LValue              = Ident { LValueSuffix } ;

LValueSuffix        = "." Ident
                    | "[" Expr "]" ;
```

---

# 14. Patterns

```ebnf
Pattern             = LiteralPattern
                    | IdentPattern
                    | EnumPattern
                    | WildcardPattern
                    | TuplePattern ;

LiteralPattern      = Literal ;

IdentPattern        = Ident ;

EnumPattern         = Ident "." Ident ;   (* z. B. Color.Green *)

(* Erreichbar sind: LiteralPattern, WildcardPattern, IdentPattern (aufgeloest
   ueber Konstanten und Enum-Mitglieder), EnumPattern in qualifizierter Form
   (`Color.Green`), Guards und Or-Muster -- letztere auch mit Bezeichnern auf
   beiden Seiten.

   NICHT umgesetzt: BINDENDE Bezeichner-Muster. Ein blanker Bezeichner ist ein
   VERWEIS auf eine Konstante, ein Enum-Mitglied oder eine lokale Variable --
   nicht ein Name, an den der Wert gebunden wird. Beide Lesarten zugleich gehen
   nicht, und die Verweis-Lesart ist die, auf der Enum-Muster beruhen. Benennt
   der Bezeichner nichts, wird das gemeldet. Wer jeden Wert annehmen will,
   schreibt `case _`.

   Ein qualifiziertes Enum-Muster wird ueber den MITGLIEDSnamen aufgeloest --
   Enum-Mitglieder liegen in einer flachen Konstantentabelle. Der Typname davor
   dient der Lesbarkeit; zwei Enums mit gleichnamigen Mitgliedern kollidieren
   deshalb weiterhin.

   `match` ist Anweisung UND Ausdruck. Als Ausdruck liefert es den Wert des
   getroffenen Fallrumpfes; trifft kein Fall und gibt es keinen Default, ist
   das Ergebnis 0. *)

WildcardPattern     = "_" ;

TuplePattern        = "(" Pattern "," Pattern { "," Pattern } ")" ;
```

---

# 15. Runtime Expression Grammar

The runtime expression grammar is precedence-ordered. The lowest precedence is defined first.

```ebnf
Expr                = PipeExpr ;

PipeExpr            = NullCoalesceExpr
                      { "|>" PipeTarget } ;

PipeTarget          = Ident [ "(" [ PipeArgList ] ")" ]
                    | FieldPipelineTarget ;

FieldPipelineTarget = Ident "." Ident [ "(" [ PipeArgList ] ")" ] ;

PipeArgList         = "?" { "," Expr }
                    | Expr { "," Expr } ;

NullCoalesceExpr    = LogicalOrExpr
                      { "??" LogicalOrExpr } ;

(* `&&` und `||` werten KURZ: ist das Ergebnis nach der linken Seite bereits
   entschieden, wird die rechte gar nicht ausgewertet. Damit traegt das
   uebliche Null-Guard-Idiom `p != 0 && deref(p)`.

   Bis lyxc 1.0.11A war das nicht so -- beide Seiten wurden ausgewertet und
   danach verknuepft, wodurch genau dieses Idiom segfaultete. Siehe Issue
   #1023. Das Ergebnis ist in beiden Faellen 0 oder 1. *)

LogicalOrExpr       = LogicalAndExpr
                      { "||" LogicalAndExpr } ;

LogicalAndExpr      = BitwiseOrExpr
                      { "&&" BitwiseOrExpr } ;

BitwiseOrExpr       = BitwiseXorExpr
                      { ( "|" | "|~" ) BitwiseXorExpr } ;

BitwiseXorExpr      = BitwiseAndExpr
                      { "^" BitwiseAndExpr } ;

BitwiseAndExpr      = EqualityExpr
                      { "&" EqualityExpr } ;

EqualityExpr        = RelationalExpr
                      { ( "==" | "!=" ) RelationalExpr } ;

RelationalExpr      = ShiftExpr
                      { ( "<" | "<=" | ">" | ">=" | "in" ) ShiftExpr } ;

ShiftExpr           = AdditiveExpr
                      { ( "<<" | ">>" ) AdditiveExpr } ;

AdditiveExpr        = MultiplicativeExpr
                      { ( "+" | "-" ) MultiplicativeExpr } ;

MultiplicativeExpr  = UnaryExpr
                      { ( "*" | "/" | "%" ) UnaryExpr } ;

UnaryExpr           = ( "+" | "-" | "!" | "~" | "@" ) UnaryExpr
                    | CastExpr ;
(* "@" Ident  = Adresse-von (address-of) eines Locals/Params → Slot-Adresse.
   Codegen: ELF lea rax,[rbp+off]; LyxOS IRO_LOAD_LOCAL_ADDR (PR #872). *)

CastExpr            = PostfixExpr [ "as" Type ] ;

PostfixExpr         = PrimaryExpr { PostfixSuffix } ;

PostfixSuffix       = IndexSuffix
                    | FieldSuffix
                    | SafeFieldSuffix ;

(* Ein Aufruf haengt am NAMEN, nicht an einem beliebigen Ausdruck: `f(a, b)`
   und `f<T>(a, b)` sind Primaerausdruecke. Ein Aufruf ueber einen indizierten
   Ausdruck -- `handlers[0](a, b)` -- ist NICHT vorgesehen und wird abgewiesen;
   ein Funktionszeiger wird zuerst einer Variablen zugewiesen und ueber diese
   aufgerufen. Der Methodenaufruf `obj.m(a, b)` steht bei FieldSuffix. *)

CallExpr            = Ident "(" [ ArgList ] ")" ;

GenericCallExpr     = Ident "<" TypeArgList ">" "(" [ ArgList ] ")" ;

IndexSuffix         = "[" Expr "]" ;

FieldSuffix         = "." Ident ;

SafeFieldSuffix     = "?." Ident ;

PrimaryExpr         = Literal
                    | SelfExpr
                    | SuperExpr
                    | CallExpr
                    | GenericCallExpr
                    | Ident
                    | MatchExpr
                    | BuiltinCall
                    | NewExpr
                    | DisposeExpr
                    | TupleExpr
                    | "(" Expr ")" ;

SelfExpr            = "self" | "Self" ;

SuperExpr           = "super" ;

TupleExpr           = "(" Expr "," Expr { "," Expr } ")" ;

ArgList             = Arg { "," Arg } ;

Arg                 = NamedArg
                    | Expr ;

NamedArg            = Ident ":" Expr ;

TypeArgList         = Type { "," Type } ;
```

## 15.1 Named Arguments and Default Parameters

```text
A NamedArg "name : Expr" in a call passes the argument by name.
The parser disambiguates NamedArg from a bare Expr by two-token lookahead:
if the current token is Ident and the next token is ":" (not ":="),
the sequence is treated as NamedArg.

A Param may carry an optional default value "= Expr".
Default values MUST be compile-time evaluable (constants or literals).
A call may omit trailing arguments that have defaults; the compiler
fills them in during code generation.
Named arguments may be used to pass a non-first parameter by name
when all omitted leading parameters have defaults.
```

## 15.2 Chained Postfix Access

```text
PostfixSuffix may be chained arbitrarily, enabling patterns such as

    self.arr[i].field       — array element then struct field
    obj.method()[j].prop    — call result indexed then field
    a[i][j]                 — multi-dimensional index

The grammar captures this through the { PostfixSuffix } repetition on
PostfixExpr; no additional production is needed.
LValue follows the same rule via the { LValueSuffix } repetition.
```

---

## 15.3 Operator Overloading

```text
Operator overloading adds NO syntax — the productions AdditiveExpr,
MultiplicativeExpr, EqualityExpr, RelationalExpr and the index PostfixSuffix
are used unchanged. It is a semantic (overload-resolution) rule, which by the
disclaimer in Section 19 is otherwise outside this EBNF; documented here for
discoverability.

When the left operand of an operator has a static type that is a `class`
defining the corresponding method, the operator desugars to a method call on
that operand:

    +  -> .Add(rhs)      -  -> .Sub(rhs)      *  -> .Mul(rhs)
    /  -> .Div(rhs)      %  -> .Mod(rhs)
    == -> .Eq(rhs)       != -> .Ne(rhs)   (falls back to !(.Eq(rhs)))
    <  -> .Lt(rhs)       <= -> .Le(rhs)   >  -> .Gt(rhs)   >= -> .Ge(rhs)
    a[i] -> a.Get(i)

Resolution rules:
  - The left operand must resolve to a class type: an identifier of class type,
    another arithmetic operator overload (its result class is the left
    operand's class), or a call to a free function with a class return type.
  - The class must define the operator's method (a defined ClassName_Method
    label); otherwise the operator keeps its normal built-in meaning. So
    int/f64/pchar operators and normal array/pchar indexing are unaffected.
  - `!=` additionally falls back to negating `.Eq` when no `.Ne` is defined.

A method call is also a valid left operand and a valid receiver: its class is
resolved through the receiver's class plus the declared return type, so
`a.M() + b`, `a.M() == b`, `a.M()[i]` and chains like `t.Trim().ByteLength()`
work. Chains resolve recursively, so the receiver may itself be a method call
or a free function returning a class.

An operand whose class cannot be determined statically keeps the operator's
built-in meaning; there is no runtime fallback.
```

---

# 16. Built-in and Special Expressions

```ebnf
BuiltinCall         = CheckExpr
                    | PanicExpr
                    | AssertExpr
                    | VerifyIntegrityCall ;

CheckExpr           = "check" "(" Expr ")" ;

PanicExpr           = "panic" "(" [ Expr ] ")" ;

AssertExpr          = "assert" "(" Expr ")" ;

VerifyIntegrityCall = "VerifyIntegrity" "(" ")" ;

NewExpr             = "new" Type "(" [ ArgList ] ")" ;

DisposeExpr         = "dispose" Expr ;
```

---

# 17. Constant Expression Grammar

Constant expressions use the same precedence model as runtime expressions, but with a restricted primary set.

```ebnf
ConstExpr                 = ConstPipeExpr ;

ConstPipeExpr             = ConstNullCoalesceExpr
                            { "|>" ConstPipeTarget } ;

ConstPipeTarget           = Ident [ "(" [ ConstPipeArgList ] ")" ] ;

ConstPipeArgList          = "?" { "," ConstExpr }
                          | ConstExpr { "," ConstExpr } ;

ConstNullCoalesceExpr     = ConstLogicalOrExpr
                            { "??" ConstLogicalOrExpr } ;

ConstLogicalOrExpr        = ConstLogicalAndExpr
                            { "||" ConstLogicalAndExpr } ;

ConstLogicalAndExpr       = ConstBitwiseOrExpr
                            { "&&" ConstBitwiseOrExpr } ;

ConstBitwiseOrExpr        = ConstBitwiseXorExpr
                            { ( "|" | "|~" ) ConstBitwiseXorExpr } ;

ConstBitwiseXorExpr       = ConstBitwiseAndExpr
                            { "^" ConstBitwiseAndExpr } ;

ConstBitwiseAndExpr       = ConstEqualityExpr
                            { "&" ConstEqualityExpr } ;

ConstEqualityExpr         = ConstRelationalExpr
                            { ( "==" | "!=" ) ConstRelationalExpr } ;

ConstRelationalExpr       = ConstShiftExpr
                            { ( "<" | "<=" | ">" | ">=" | "in" ) ConstShiftExpr } ;

ConstShiftExpr            = ConstAdditiveExpr
                            { ( "<<" | ">>" ) ConstAdditiveExpr } ;

ConstAdditiveExpr         = ConstMultiplicativeExpr
                            { ( "+" | "-" ) ConstMultiplicativeExpr } ;

ConstMultiplicativeExpr   = ConstUnaryExpr
                            { ( "*" | "/" | "%" ) ConstUnaryExpr } ;

ConstUnaryExpr            = ( "+" | "-" | "!" | "~" ) ConstUnaryExpr
                          | ConstCastExpr ;

ConstCastExpr             = ConstPostfixExpr [ "as" Type ] ;

ConstPostfixExpr          = ConstPrimaryExpr { ConstPostfixSuffix } ;

ConstPostfixSuffix        = ConstCallSuffix
                          | ConstIndexSuffix
                          | ConstFieldSuffix
                          | ConstSafeFieldSuffix ;

ConstCallSuffix           = "(" [ ConstArgList ] ")" ;

ConstIndexSuffix          = "[" ConstExpr "]" ;

ConstFieldSuffix          = "." Ident ;

ConstSafeFieldSuffix      = "?." Ident ;

ConstPrimaryExpr          = Literal
                          | Ident
                          | ConstTupleExpr
                          | "(" ConstExpr ")" ;

ConstTupleExpr            = "(" ConstExpr "," ConstExpr { "," ConstExpr } ")" ;

ConstArgList              = ConstArg { "," ConstArg } ;

ConstArg                  = Ident ":" ConstExpr
                          | ConstExpr ;
```

## 17.1 Constant Expression Parsing Rule

```text
ConstExpr SHALL be parsed with the same precedence and associativity rules as Expr.

Parenthesized constant expressions SHALL restart parsing at ConstExpr.

Therefore, the following expression is syntactically valid:

    (5 + 3)

The grammar defines syntax only.
Whether a construct is compile-time evaluable is a semantic decision.
```

---

# 18. Operator Precedence

| Level | Operators                                                  | Associativity |
| ----: | ---------------------------------------------------------- | ------------- |
|     1 | `\|>`                                                      | Left          |
|     2 | `??`                                                       | Left          |
|     3 | `\|\|`                                                     | Left          |
|     4 | `&&`                                                       | Left          |
|     5 | `\|`, `\|~`                                                | Left          |
|     6 | `^`                                                        | Left          |
|     7 | `&`                                                        | Left          |
|     8 | `==`, `!=`                                                 | Left          |
|     9 | `<`, `<=`, `>`, `>=`, `in`                                 | Left          |
|    10 | `<<`, `>>`                                                 | Left          |
|    11 | `+`, `-`                                                   | Left          |
|    12 | `*`, `/`, `%`                                              | Left          |
|    13 | unary `+`, unary `-`, `!`, `~`                             | Right         |
|    14 | `as`                                                       | Left          |
|    15 | call, generic call, index, field access, safe field access | Left          |

---

# 19. Parser Requirements

```text
The grammar SHALL be free of left recursion.

The grammar SHALL be compatible with recursive descent parsing.

Expression parsing SHOULD be implemented using a Pratt parser or an equivalent precedence parser.

ConstExpr parsing SHOULD use the same precedence parser infrastructure as Expr with a restricted primary-expression set.

Every referenced nonterminal SHALL be defined exactly once.

The lexer SHALL apply longest-match tokenization.

Syntax and semantics SHALL remain separated.

Semantic restrictions such as type compatibility, name resolution, overload resolution, visibility, constness, ownership, lifetime, range checks, and ABI behavior are not part of this EBNF.

Soft keywords SHALL require contextual parsing predicates.
```

---

# 20. Known Semantic Decisions Not Defined by EBNF

```text
switch fallthrough behavior
pattern matching exhaustiveness
generic specialization rules
method dispatch rules
self/Self/super binding rules
ownership and disposal semantics
runtime behavior of defer
ABI layout rules
packed and flat struct memory layout
range-type runtime checking
unit-type conversion semantics
overflow behavior
nullability type rules
visibility and module export rules
default parameter value evaluation order and scoping
named argument resolution when callee is an imported or builtin function
```

## 20.1 Bekannte Abweichungen zwischen Grammatik und Compiler

Stellen, an denen der Parser mehr annimmt, als der Rest der Werkzeugkette
tragen kann. Sie sind hier festgehalten, damit die Grammatik nicht mehr
verspricht, als eingeloest wird.

Der Stand ist aus der Testinventur zu Issue #1004 hervorgegangen; die
Einzelbefunde sind dort verlinkt.

| Konstrukt | Abschnitt | Verhalten |
|---|---|---|
| Bindendes Muster | 14 | `case x =>` (jeden Wert annehmen und an den Namen binden) ist **nicht umgesetzt und auch nicht vorgesehen**. Ein blanker Bezeichner ist ein VERWEIS auf eine Konstante, ein Enum-Mitglied oder eine lokale Variable; beide Lesarten zugleich gehen nicht, und auf der Verweis-Lesart beruhen die Enum-Muster. Wer jeden Wert annehmen will, schreibt `case _`. (#1024) |
| `Set<T>` | 7 | Als Wort reserviert, von der Semantikpruefung nicht aufgeloest (`unknown type in var decl`). |
| `&x` (Adress-Operator) | 15 | Gibt es nicht. Ein Ausgabeparameter wird als Zelle uebergeben (`alloc(8)`, danach `peek64`). (#1061) |
| Aufruf ueber indizierten Ausdruck | 15 | `handlers[0](a)` ist kein Aufruf -- ein Aufruf haengt am NAMEN. Wird abgewiesen; ein Funktionszeiger wird zuerst einer Variablen zugewiesen. (#1053) |
| Bereichstyp, Laufzeitpruefung | 7 | `type X = int64 range LO..HI;` parst und wird geprueft, solange der zugewiesene Wert zur UEBERSETZUNGSZEIT feststeht (Literal, `con`, konstanter Ausdruck) -- bei Initialisierung und bei Zuweisung. **Berechnete** Werte werden nicht geprueft, ebenso wenig Parameter, Rueckgaben und Strukturfelder. Der Typ sichert also weniger zu, als sein Name nahelegt. (#1082) |

Behoben seit der letzten Fassung dieses Abschnitts und daher hier entfallen:
Fallrumpf als Block und qualifizierte Enum-Muster (#1024), `fn f<T>(...)`
(#1009), `range(N)` (#1007), `defer` im inneren Block (#1006) samt
Argument-Zeitpunkt (#1030).

Nicht mehr betroffen: die Bindung von Methodenzeigern (`feld := obj.Method`)
war bis PR #1005 abgewiesen, weil die Existenzpruefung fuer Feldnamen nur die
Felder einer Klasse durchsuchte und nicht ihre Methoden. Sie funktioniert
wieder und ist durch `tests/method_ptr_test.sh` abgedeckt.

Ebenfalls nicht mehr betroffen: der Ziffern-Trenner im Float-Literal
(`3.14_159`, `1_000.5`). Bis 1.0.11B kuerzten die Literal-Umwandlungen den Wert
stillschweigend am ersten `_`; seither ueberspringen sie ihn in allen
Ziffernschleifen. Abgedeckt durch `tests/lexer_float_dot_test.lyx`. (#1011)

Ebenfalls nicht mehr betroffen: der inline geschriebene Funktionszeigertyp
(`var f: fn(int64): int64 := g;`) als lokale Variable und als Parameter. Der
Aufrufpfad erkannte einen fn-Zeiger bis 1.0.11B nur am Namen eines Typalias;
inline geschrieben lief der Aufruf ueber den Closure-Pfad und stuerzte ab.
Abgedeckt durch `tests/inline_fnptr_test.sh`. (#1003)

---

# 21. Grammar Completeness Checklist

```text
All referenced lexical nonterminals are defined.

All referenced declaration nonterminals are defined.

All referenced type nonterminals are defined.

All referenced statement nonterminals are defined.

All referenced expression nonterminals are defined.

All referenced constant-expression nonterminals are defined.

All referenced attribute and directive nonterminals are defined.

The grammar contains no direct left recursion.

The expression grammar is precedence ordered.

The constant-expression grammar mirrors runtime expression precedence.

The nullable type suffix is limited to one "?".

The lexer disambiguates ".", "..", "...", "?", "??", "?.", "|", "|>", and "|~".

The IfStmt grammar requires a Block for the then-branch, avoiding the classic dangling-else ambiguity.

Param supports an optional default value "= Expr" (WP-MEM-05).

ArgList entries may be positional Expr or named Ident ":" Expr (WP-MEM-05).

NamedArg disambiguation: Ident ":" is a NamedArg only when the next token is ":" (not ":=").

Chained PostfixSuffix enables struct-array element field access: arr[i].field (WP-POKE-09).
```

End of canonical grammar.

---

# 22. LCBS Capability Grammar (WP-L1 … WP-T15)

> Vollständige Dokumentation: [capabilities.md](capabilities.md)

```ebnf
(* Capability annotation for functions, modules and classes *)
CapabilityAttr    = "@capabilities" "(" ( "[" CapabilityList "]" | "dynamic" ) ")" ;

UsesCallerCap     = "@uses_caller_cap" "(" "[" CapabilityList "]" ")" ;

CapabilityList    = CapabilityDecl { "," CapabilityDecl } ;

CapabilityDecl    = CapabilityPath
                    [ "(" CapabilityArgList ")" ]
                    [ "@fastpath" ] ;

CapabilityPath    = Ident { "." Ident } ;

CapabilityArgList = CapabilityArg { "," CapabilityArg } ;

CapabilityArg     = Ident ":" CapabilityArgValue ;

CapabilityArgValue = StringLiteral
                   | IntLiteral
                   | Ident
                   | NetworkTarget
                   | "dynamic" ;

(* Network address with optional CIDR and port *)
NetworkTarget     = StringLiteral ":" PortSpec ;

PortSpec          = "*"
                  | IntLiteral
                  | IntLiteral "-" IntLiteral ;
```

## 22.1 ImportItem with grant/restrict (amended from Section 3)

`grant` and `restrict` are soft keywords (tokenised as identifiers, interpreted contextually).

```text
Effective capabilities rule:
  Without grant:  C(M) = C(M_declared) ∩ C(parent)
  With grant:     C(M) = grant_set ∩ C(parent)
  With restrict:  C(M) = C(M_declared) ∩ C(parent) ∩ restrict_set
  Invariant:      C(M) ⊆ C(parent)
```

## 22.1b ExternFnDecl mit @cap (WP-L5)

```ebnf
ExternFnDecl = [ "@cap" "(" CapabilityPath ")" ]
               "extern" "fn" Ident "(" [ ParamList ] ")" [ ":" Type ]
               "link" StringLiteral ";" ;
```

## 22.1c UsesCallerCap (WP-L7)

Vor einer Funktionsdeklaration (verkettet über `next`-Zeiger im AST):

```ebnf
UsesCallerCap = "@uses_caller_cap" "(" "[" CapabilityList "]" ")" ;
```

Der Compiler prüft an jedem Aufruf-Site, ob `C(Aufrufer) ⊇ uses_caller_cap_set`.

## 22.1d Implizite Capabilities

Folgende Capabilities sind immer aktiv und erscheinen im Audit-Output:

```text
system.exit         → exit_group (ID 0)
system.memory.heap  → brk, mmap(MAP_ANON), munmap (ID 1)
system.memory.stack → mmap(MAP_STACK) (ID 2)
```

## 22.1e CLI-Flags (WP-T13/T14/T15)

| Flag | Beschreibung |
|------|-------------|
| *(kein Flag)* | Audit-Report immer auf stderr; seccomp+Landlock wenn @capabilities vorhanden |
| `--migrate-capabilities` | Analysiert Programm; gibt @capabilities-Manifest auf stdout aus |
| `--capabilities=compat` | Kein seccomp/Landlock trotz @capabilities (für Migration) |
| `--self-test` | Führt LCBS-Integrationstest aus |

## 22.2 AST Node Mapping

| Syntax | AST Node | Fields |
|--------|----------|--------|
| `@capabilities([...])` | `NK_CAPABILITY_ATTR` | c0=first NK_CAPABILITY_DECL; iVal=0 |
| `@capabilities(dynamic)` | `NK_CAPABILITY_ATTR` | c0=-1; iVal=1 |
| `fs.read(path: "/etc")` | `NK_CAPABILITY_DECL` | sOff/sLen=path; c0=first NK_CAPABILITY_ARG; iVal: bit0=@fastpath |
| `path: "/etc"` | `NK_CAPABILITY_ARG` | sOff/sLen=key; c0=value node |
| `"192.168.1.0/24":5000` | `NK_NETWORK_TARGET` | sOff/sLen=addr; iVal=port (0=wildcard) |
| `grant [...]` on import | `NK_GRANT_CLAUSE` | c0=first NK_CAPABILITY_DECL |
| `restrict [...]` on import | `NK_RESTRICT_CLAUSE` | c0=first NK_CAPABILITY_DECL |
| `@uses_caller_cap([...])` | `NK_USES_CALLER_CAP` | c0=first NK_CAPABILITY_DECL |
| `NK_IMPORT` with grant | `NK_IMPORT` | sOff/sLen=path; c1=NK_GRANT_CLAUSE; c2=NK_RESTRICT_CLAUSE |
| `@cap(path) extern fn` | `NK_FUNC_DECL` (extern) | c2=NK_CAPABILITY_ATTR; c3=link-target |

