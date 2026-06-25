# Lyx v0.9.5B — Canonical EBNF Grammar

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

Ident               = Letter { Letter | Digit } ;

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

```text
fn var let co con
if else while for do downto to repeat until
switch case break continue default return
true false null
extern unit import pub as
array struct flat packed class extends
new dispose super static self Self
private protected
panic assert check
enum match try catch throw limit
virtual override abstract
dim utype
```

## 2.2 Soft Keywords

```text
range wraps defer
```

Soft keywords are tokenized as identifiers and interpreted contextually by the parser.

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
                    | "@volatile" ;

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

TypeParamClause     = "[" TypeParamList "]" ;

TypeParamList       = Ident { "," Ident } ;

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
                    | QualifiedIdent
                    | ArrayType
                    | ParallelArrayType
                    | TupleType
                    | MapType
                    | SetType ;

BuiltinType         = "bool"
                    | BaseIntType
                    | "f32"
                    | "f64"
                    | "pchar"
                    | "void" ;

BaseIntType         = "int8"
                    | "int16"
                    | "int32"
                    | "int64"
                    | "uint8"
                    | "uint16"
                    | "uint32"
                    | "uint64"
                    | "isize"
                    | "usize" ;

QualifiedIdent      = Ident "::" Ident ;

ArrayType           = "array" "[" Type "]"
                    | "Array" "<" Type ">" ;

ParallelArrayType   = "ParallelArray" "<" Type ">" ;

TupleType           = "(" Type "," Type { "," Type } ")" ;

MapType             = "Map" "<" Type "," Type ">" ;

SetType             = "Set" "<" Type ">" ;
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
                      Expr
                      "{"
                      { MatchCase }
                      [ MatchDefault ]
                      "}" ;

MatchCase           = "case"
                      Pattern
                      { "|" Pattern }
                      "=>"
                      Block ;

MatchDefault        = "default" "=>" Block ;

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

ExprStmt            = Expr ";" ;
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

EnumPattern         = QualifiedIdent ;

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
                    | QualifiedIdent [ "(" [ PipeArgList ] ")" ]
                    | FieldPipelineTarget ;

FieldPipelineTarget = Ident "." Ident [ "(" [ PipeArgList ] ")" ] ;

PipeArgList         = "?" { "," Expr }
                    | Expr { "," Expr } ;

NullCoalesceExpr    = LogicalOrExpr
                      { "??" LogicalOrExpr } ;

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

PostfixSuffix       = CallSuffix
                    | GenericCallSuffix
                    | IndexSuffix
                    | FieldSuffix
                    | SafeFieldSuffix ;

CallSuffix          = "(" [ ArgList ] ")" ;

GenericCallSuffix   = "[" TypeArgList "]" "(" [ ArgList ] ")" ;

IndexSuffix         = "[" Expr "]" ;

FieldSuffix         = "." Ident ;

SafeFieldSuffix     = "?." Ident ;

PrimaryExpr         = Literal
                    | SelfExpr
                    | SuperExpr
                    | Ident
                    | QualifiedIdent
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

ConstPipeTarget           = Ident [ "(" [ ConstPipeArgList ] ")" ]
                          | QualifiedIdent [ "(" [ ConstPipeArgList ] ")" ] ;

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
                          | QualifiedIdent
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

