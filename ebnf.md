# Lyx 1.0.19C — Canonical EBNF Grammar

> Stand 2026-08-14, gegen lyxc 1.0.19C geprueft. Die Keyword-Liste in
> Abschnitt 2.1 wurde Wort fuer Wort gegen den Compiler verifiziert; die
> Typgrammatik in Abschnitt 7 ist um Funktions- und Methodenzeiger ergaenzt,
> und die match-Produktion in Abschnitt 12 entspricht jetzt dem Parser.
> Neu in dieser Fassung: Abschnitt 7 fuehrt die kurze Schreibweise der
> vorzeichenbehafteten Ganzzahltypen (`i8`..`i64`) jetzt auch fuer den
> var-Deklarator, und 20.1 haelt fest, wann Indexzugriffe geprueft werden und
> wo schmale Ganzzahltypen gekuerzt werden.
> Bekannte Abweichungen zwischen Grammatik und Compiler stehen in 20.1.

Status: Normativ — verbindliche Fassung. Massgeblich ist ausschliesslich
`ebnf.md` im Compiler-Repository (aurum); Dateien gleichen Namens in anderen
Projekten sind Abschriften und veralten. Wer eine Abweichung zwischen
Grammatik und Compiler meldet, nennt bitte die Versionszeile der Datei, gegen
die er gemessen hat — fuenf Meldungen einer einzigen Runde (#1350, #1353,
#1354, #1356, #1357) stammten aus einer Abschrift des Standes v0.9.3A.
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

EscapeSequence      = "\\" ( "n" | "r" | "t" | "\\" | '"' | "'" | "0"
                             | "x" HexDigit HexDigit ) ;
HexDigit            = "0".."9" | "a".."f" | "A".."F" ;

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
range wraps defer limit
```

Soft keywords are tokenized as identifiers and interpreted contextually by the parser.

`limit` wird nur unmittelbar hinter der Bedingung eines `while` und vor dem
Block erkannt, gefolgt von "(" -- ueberall sonst bleibt es ein gewoehnlicher
Bezeichner (#1103). Damit stimmen die WhileStmt-Produktion in Abschnitt 12 und
die Feststellung oben, `limit` sei nicht reserviert, wieder ueberein.

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
                      [ "as" Ident ]
                      [ "grant"    "[" CapabilityList "]" ]
                      [ "restrict" "[" CapabilityList "]" ] ;
```

---

# 4. Attributes and Directives

```ebnf
Visibility          = ( "pub" | "public" ) ;

(* #1245: `public` wurde vom Parser schon immer angenommen, war hier aber nicht
   verzeichnet -- bei MemberVisibility stand es bereits. Wer nachschlug, hielt
   `public fn` fuer ungueltig, obwohl es uebersetzt. Kanonisch bleibt `pub`;
   `public` ist die gleichwertige Langform. *)

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

WcetAttr            = "@wcet" "(" IntLiteral ")" ;   (* Iterationen, 1..16777215 *)

StackLimitAttr      = "@stack_limit" "(" IntLiteral ")" ;   (* Bytes, 1..16777215 *)

FlightCritAttr      = "@flight_crit" ;

IntegrityAttr       = "@integrity" "(" IntegrityParams ")" ;

IntegrityParams     = IntegrityMode [ "," IntegrityInterval ] ;

IntegrityMode       = "mode" ":"
                      ( "software_lockstep"
                      | "scrubbed"
                      | "hardware_ecc" ) ;

IntegrityInterval   = "interval" ":" IntLiteral ;

VarAttr             = "@redundant"   (* TMR: drei Kopien + Mehrheitsentscheid, §20.1 *)
                    | "@volatile"
                    | "@align" "(" IntLiteral ")" ;
(* "@align(N) var ..." — Allokations-Alignment (N Bytes) für array/heap-backed Locals.
   LyxOS: über-alloziert + rundet Pointer auf N auf (emitAlloc). Skalare Stack-Locals: n/a. *)

EndianAttr          = "@big_endian"
                    | "@little_endian" ;

ModuleDocAttr       = ( "@description" | "@author" | "@copyright" | "@version" )
                      "(" StringLiteral ")" ;
(* Modulkopf-Angaben vor `unit`/`import`. Rein beschreibend; der Bestand
   benutzt sie durchgaengig (#1099). *)
```

Ein Attributname ausserhalb dieser Mengen ist ein Fehler, ebenso ein
fehlendes, ueberzaehliges oder falsch getipptes Argument (#1099). Welche
Attribute eine Wirkung haben und welche nur vermerkt werden, steht in
Abschnitt 20.1.

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

ExternFnDecl        = [ "@cap" "(" CapabilityPath ")"
                      | CapabilitiesAttr ]
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

   Generische FUNKTIONEN sind seit #1009 nutzbar: `fn Id<T>(x: T): T`, mehrere
   Typparameter (`fn Pair<A, B>(a: A, b: B): A`), Aufrufe mit Struct-Typen
   (`Id<P>(p)`) und -- seit #1117 -- die Weitergabe des eigenen Typparameters
   an einen generischen Aufruf (`fn Twice<T>(x: T): T { return Id<T>(x); }`).
   Ein Typparameter gilt nur INNERHALB seiner Funktion; ausserhalb ist er ein
   unbekannter Typ und wird gemeldet.

   Generische TYPEN (`type P<T> = struct {...}`) werden weiterhin nicht
   angenommen -- TypeParamClause steht daher nur an Funktionen, nicht an
   Typdeklarationen. Siehe 20.1. *)

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
                    | ClassDef
                    | InterfaceDef ;

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
   nicht (`unknown type in var decl`).

   Die kurze Schreibweise der VORZEICHENBEHAFTETEN Typen (`i8`, `i16`, `i32`,
   `i64`) wurde im var-Deklarator bis 1.0.11D abgewiesen -- als Feldtyp und im
   `as`-Cast ging sie durch. Das ist dieselbe Asymmetrie, die #1010 fuer die
   vorzeichenlose Haelfte geschlossen hat; sie ist seit #1151 beseitigt. *)

(* Qualifizierter Zugriff gibt es seit 1.0.18F -- aber nur ueber einen
   Import-Alias, nicht ueber den Modulnamen. `import std.math as m;` legt die
   Unit in einen eigenen Namensraum; ihre Symbole heissen dann `m.Clamp64(...)`
   und sind UNQUALIFIZIERT NICHT mehr sichtbar. Ohne Alias bleibt es beim
   flachen Namensraum.

   `Modul::Name` ist weiterhin ungueltig, und auch `std.math.Clamp64(...)` ist
   es -- ein Punktpfad bezeichnet eine Datei, keinen Namensraum. Bis 1.0.18E
   gab es gar keinen qualifizierten Zugriff; 31 Unit-Paare der eigenen
   Standardbibliothek liessen sich deshalb nicht gemeinsam importieren
   (#1262). Frueher stand hier `QualifiedIdent = Ident "::" Ident`; `::`
   erzeugt einen Parse-Fehler. *)

ArrayType           = "array" "[" Type "]"
                    | "Array" "<" Type ">"
                    | FixedArrayType ;

FixedArrayType      = "[" ConstExpr "]" Type
                    | Type "[" ConstExpr "]" ;

(* Beide Schreibweisen ergeben denselben Typ; die Groesse ist eine Konstante,
   ein Bereich (`int64[0..100]`) wird abgewiesen. GENAU EINE Verschachtelung
   ist umgesetzt: `[N][M]T` liegt FLACH -- N*M Slots hinter einem
   `{cap,len}`-Kopf --, `m[i]` liefert die ADRESSE der Zeile i und `m[i][j]`
   liest von dort mit Schrittweite 8. Beide Indizes werden unter
   `--runtime-checks` geprueft. Eine ganze Zeile zuzuweisen (`m[i] := x`) hat
   keine Bedeutung und wird gemeldet, ebenso eine dritte Dimension: der
   Lesepfad kennt genau eine Zeilenlaenge. Bis 1.0.16G wurde `[N][M]T`
   abgewiesen, davor belegte es nur N Slots und stuerzte bei JEDEM Zugriff ab
   (#1230). *)

ParallelArrayType   = "ParallelArray" "<" Type ">" ;

TupleType           = "(" Type "," Type ")" ;

(* Die eckige Schreibweise `[T, T]` ist gleichbedeutend und bleibt gueltig;
   der Bestand benutzt sie. GENAU ZWEI Elemente: die Aufrufkonvention traegt
   zwei Rueckgabewerte (rax, rdx). Die Produktion liess bis 1.0.13P beliebig
   viele zu, der Compiler wies ab drei ab -- jetzt sagen beide dasselbe.
   (#1088, #1122) *)

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

(* Seit #1152/#1205 ein benutzbarer Typ, nicht nur ein Wort: das Literal
   `{k: v, ...}` legt an, `m[k]` liest, `m[k] := v` schreibt (legt an oder
   aktualisiert), `k in m` prueft, `len(m)` zaehlt. Eine Deklaration OHNE
   Initialisierung ist ebenfalls benutzbar — sie legt eine leere Map an.
   Ein fehlender Schluessel liefert 0.

   SCHLUESSELTYP: nur ganzzahlig (und `bool`). Die Laufzeit vergleicht den
   Schluessel als Zahl; bei `pchar` waere das die ADRESSE, und gleich
   geschriebene Literale haben verschiedene Adressen. `Map<pchar, V>` wird
   deshalb bei der Deklaration abgewiesen — siehe #1291.

   Bis 1.0.15A war nichts davon nutzbar: Lesen lieferte still eine Adresse,
   Schreiben stuerzte ab, `in` war immer falsch. Die falschen WERTE kamen aus
   dem Parser — `{5: 100}` verlor den Doppelpunkt an die Format-Schreibweise
   `expr:breite` (§13) und wurde zur MENGE, deren Zweig jeden Wert auf 1 setzt.
   NICHT umgesetzt sind `delete m[k]` und `for k, v in m` (#1152). *)

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
                      [ "implements" Ident { "," Ident } ]
                      "{"
                      { ClassMember }
                      "}" ;

InterfaceDef        = "interface"
                      "{"
                      { MethodSignature }
                      "}" ;

MethodSignature     = "fn" Ident "(" [ ParamList ] ")" [ ":" ReturnType ] ";" ;

(* Ein Interface deklariert nur Signaturen -- die Methoden sind ohne Rumpf und
   implizit oeffentlich. `implements` sagt zu, dass die Klasse jede genannte
   Methode traegt; die Semantikpruefung weist einen unbekannten Interface-Namen
   ("unknown interface") und eine fehlende Methode ("class missing interface
   method") ab. Der Aufruf ueber den Interface-Typ laeuft ueber die VMT, die
   Methode braucht dafuer KEIN `virtual` -- die Zusage steckt im `implements`.
   Bis 1.0.14C fehlte beides in dieser Grammatik, und der Aufruf lieferte
   still 0 (#1133). *)

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
                    | ( "pub" | "public" ) ;

(* `public` ist eine gleichwertige Schreibweise zu `pub` -- an Funktionen wie
   an Klassenmitgliedern (#1104). *)
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

(* limit(N) begrenzt die Zahl der DURCHLAEUFE des Rumpfes, einschliesslich:
   N sind erlaubt, N+1 bricht mit panic ab. Die Schranke wird durchgesetzt,
   nicht nur vermerkt -- sie ist das Mittel, die Endlichkeit einer Schleife
   zuzusichern, und ein ungeprueftes Versprechen sagt darueber nichts aus.
   N muss zur Uebersetzungszeit feststehen (Literal oder `con`); der Zaehler
   beginnt bei jedem EINTRITT in die Schleife neu. `limit` ist ein weiches
   Schluesselwort, siehe Abschnitt 2.2. RepeatStmt fuehrt es nicht. (#1103) *)

ForStmt             = ForRangeStmt
                    | ForCStyleStmt ;

ForRangeStmt        = "for"
                      Ident
                      ( ":=" Expr ( "to" | "downto" ) Expr
                      | "in" Expr ".." Expr
                      | "in" "range" "(" Expr [ "," Expr ] ")" )
                      [ "do" ]
                      Block ;

(* Drei Schreibweisen, zwei Bedeutungen der oberen Grenze:
   `:= a to b` und `in a..b` laufen EINSCHLIESSLICH bis b, `in range(a, b)`
   AUSSCHLIESSLICH bis b (`range(n)` beginnt bei 0). `in a..b` gab es bis
   1.0.13S nicht -- der Parser wies es ab, obwohl `in` und `..` als Ausdruck
   beide existieren (#1129). Rueckwaerts laeuft nur `downto`. *)

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

SwitchCase          = "case" ConstExpr ":" Block ;

SwitchDefault       = "default" ":" Block ;

(* #1232: Hier stand `{ Statement }`, also eine Anweisungsfolge ohne Klammern.
   Der Parser verlangt einen Block; `case 1: PrintLn("a"); break;` scheitert mit
   "expected {, got IDENT". Der Bestand hatte sich bereits nach dem Compiler
   gerichtet und schrieb ueberall Bloecke -- die Grammatik sagte etwas anderes
   zu, als der Compiler traegt. *)

(* Jeder Zweig muss mit `break` oder `return` enden; ein durchfallender Zweig
   wird gemeldet ("switch case may fall through"). Das kehrt das Verhalten von
   C bewusst um: dort faellt ein Zweig ohne `break` in den naechsten, und die
   haeufigste Fehlerquelle des Konstrukts ist genau das vergessene `break`.
   Die Regel ist eine semantische Pruefung; die Grammatik allein erzwingt sie
   nicht (#1104). *)

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
                      [ "catch" [ "(" Ident [ ":" Type ] ")" ] Block ]
                      [ "finally" Block ] ;
(* - Die Bindung ist seit #1147 lesbar: `catch (e: int64)` legt `e` im
     catch-Block an und traegt den geworfenen Wert. Sie verdeckt eine
     gleichnamige aeussere Variable NUR im Rumpf. Bis 1.0.15A wies der Parser
     die Typangabe ab und band den Bezeichner nicht.
   - Die Typangabe darf fehlen; der geworfene Wert ist dann `int64` (das rohe
     Maschinenwort).
   - Sie WAEHLT NICHT AUS: der Wert traegt keine Typkennung. Mehr als eine
     catch-Klausel wird deshalb gemeldet statt still nacheinander ausgefuehrt.
   - OHNE catch faengt der try-Block nichts: `finally` raeumt auf, danach geht
     die Ausnahme WEITER zum naechsten Handler, und findet sie keinen, endet
     das Programm mit 1. Bis 1.0.16G war sie verschluckt -- das finally lief,
     der Code dahinter ebenfalls, und das Programm meldete rc=0, wo der nackte
     `throw` mit rc=1 abbricht (#1242).
   - Nur der x86-64-Pfad senkt try/catch ab. Fuer lyxos, arm64, riscv, arm-cm4
     und xtensa wird es GEMELDET; eine Uebersetzung waere still falsch, weil
     dort kein Handler installiert wird (#1281). *)

ThrowStmt           = "throw" Expr ";" ;

(* Findet der Wurf keinen Handler, endet das Programm mit 1. Fuer die
   IR-Backends (lyxos, arm64, riscv, arm-cm4) ist das der einzige Fall, denn
   try/catch wird dort gemeldet; bis 1.0.16G erzeugte `throw` fuer diese Ziele
   gar keinen Code und war ein No-op (#1281). Auf xtensa wird `throw` gemeldet:
   dort fehlt eine gepruefte Trap-Kodierung. *)

ReturnStmt          = "return" [ Expr ] ";" ;

BreakStmt           = "break" ";" ;

ContinueStmt        = "continue" ";" ;

DeferStmt           = "defer" Statement ;

(* Die angemeldete Anweisung laeuft beim Verlassen des Rahmens in LIFO-Reihen-
   folge -- auf dem `return`-Weg, bei `break`/`continue` aus einer Schleife und
   seit 1.0.16G auch dann, wenn die Funktion per `throw` verlassen wird. Bis
   dahin uebersprang genau der Ausnahmeweg die Kette: ein `defer CloseFile(fd)`
   leckte still im Fehlerfall, also in dem einzigen Fall, fuer den man es
   schreibt (#1241). NICHT erfasst ist der DURCHLAUFENE Rahmen: wirft eine
   gerufene Funktion, springt die Ausnahme ueber die Zwischenrahmen hinweg zum
   Handler, und deren defers laufen nicht -- die Kette ist zur Uebersetzungszeit
   bekannt, die erreichte Tiefe eines fremden Rahmens dagegen nicht. *)

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
                    | RangePattern
                    | IdentPattern
                    | EnumPattern
                    | WildcardPattern
                    | TuplePattern
                    | StructPattern ;

LiteralPattern      = Literal ;

RangePattern        = RangeBound ".." [ RangeBound ] ;

RangeBound          = [ "-" ] IntLiteral ;

(* #1113: Grenzen sind EINSCHLIESSLICH, wie beim Bereichstyp in Abschnitt 7.
   Die obere Grenze darf fehlen (`case 13001.. =>`), die untere nicht. Bei
   Ueberschneidung gewinnt der ERSTE passende Zweig, wie bei den uebrigen
   Mustern auch; eine Luecke zwischen zwei Baendern faellt an den Wildcard und
   nicht an das naechstliegende Band. Ein Bereich ist auch als Alternative
   eines Or-Musters (`case 0..9 | 20..29`) und mit Guard verwendbar.

   Erzeugt werden zwei Vergleiche je Bereich, keine Sprungtabelle. *)

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

(* Umgesetzt seit 1.0.16I (#1250). Geprueft wird zuerst die LAENGE -- ein
   Muster mit zwei Teilen passt nicht auf ein dreielementiges Tupel --, dann
   Element fuer Element. Teilmuster sind ein Ganzzahlliteral (auch negativ),
   ein `con`- oder Enum-Name oder `_`; ein blanker Name ist auch hier ein
   VERWEIS und keine Bindung, wie im uebrigen Abschnitt. Beliebig viele
   Teilmuster sind zulaessig, weil der Tupel-Ausdruck die Ablage eines
   Array-Literals hat; die Zweierschranke aus TupleType gilt nur fuer
   RUECKGABEwerte. Bis 1.0.16I fehlte das Muster ganz und die Meldung lautete
   `expected =>, got (`. *)

StructPattern       = Ident "{" [ FieldPattern { "," FieldPattern } ] "}" ;

FieldPattern        = Ident ":" ( IntLiteral | Ident | "_" ) ;

(* Struktur-Muster: `case P { t: 1, f: _ }`. Das Muster passt, wenn ALLE
   genannten Felder passen; nicht genannte Felder werden nicht geprueft.
   Der Feldwert ist ein Vergleich (Ganzzahlliteral oder `con`), `_` (Feld
   ungeprueft) oder eine BINDUNG: ein Bezeichner, der nichts benennt, bindet
   den Feldwert an diesen Namen und ist im Fallrumpf sichtbar. Die Lesart
   "Bezeichner = Verweis, wenn er einen kennt" ist dieselbe wie beim
   Enum-Muster.

   Ein unbekannter Typname oder Feldname wird gemeldet. Bis #1104 passte das
   Muster IMMER: der Sprung bei einem nicht passenden Feld ging auf die
   naechste Anweisung statt zum naechsten Fall, und der Vergleich lief
   ohnehin nie an. Ein `match` mit mehreren Struktur-Fallen nahm damit stets
   den ersten -- ohne Meldung.

   Die geschweifte Form ist ein MUSTER, kein Wert: `var p: P := P { t: 1 };`
   gibt es nicht (siehe Abschnitt 20.1). *)
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

(* Der gepipte Wert wird VORANGESTELLT: `50 |> Clamp(0, 30)` heisst
   `Clamp(50, 0, 30)`. Steht ein `?` in der Liste, tritt der Wert an DESSEN
   Stelle und wird nicht zusaetzlich vorangestellt. Bis 1.0.16I fiel er ohne
   Platzhalter ersatzlos weg, und der Aufruf scheiterte an der Argumentzahl --
   benutzbar war `|>` damit nur ohne weitere Argumente oder mit `?` (#1253). *)

NullCoalesceExpr    = LogicalOrExpr
                      { "??" LogicalOrExpr } ;

(* `&&` und `||` werten KURZ: ist das Ergebnis nach der linken Seite bereits
   entschieden, wird die rechte gar nicht ausgewertet. Damit traegt das
   uebliche Null-Guard-Idiom `p != 0 && deref(p)`.

   Bis lyxc 1.0.11A war das nicht so -- beide Seiten wurden ausgewertet und
   danach verknuepft, wodurch genau dieses Idiom segfaultete. Siehe Issue
   #1023. Das Ergebnis ist in beiden Faellen 0 oder 1. *)

LogicalOrExpr       = LogicalAndExpr
                      { ( "||" | "or" ) LogicalAndExpr } ;

LogicalAndExpr      = BitwiseOrExpr
                      { ( "&&" | "and" ) BitwiseOrExpr } ;

(* `and`, `or` und `not` sind gleichwertige Schreibweisen zu `&&`, `||` und
   `!` -- gleiche Praezedenz, gleiche KURZSCHLUSSauswertung: die rechte Seite
   wird nur ausgewertet, wenn die linke sie nicht schon entscheidet (#1104). *)

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

UnaryExpr           = ( "+" | "-" | "!" | "not" | "~" | "@" ) UnaryExpr
                    | CastExpr ;
(* "@" Ident  = Adresse-von (address-of) eines Locals/Params → Slot-Adresse.
   Codegen: ELF lea rax,[rbp+off]; LyxOS IRO_LOAD_LOCAL_ADDR (PR #872). *)

CastExpr            = PostfixExpr [ ( "as" | "as" "?" | "is" ) Type ] ;

(* "is" prueft die Typzugehoerigkeit und liefert bool (#1094).
   Zielt der Test auf eine Klasse MIT Methoden, so wird zur Laufzeit ueber den
   Typzeiger geprueft, und zwar gegen die Zielklasse SAMT ihrer Nachfahren:
   `b is A` ist wahr, wenn B von A abstammt. `null` ist nie ein T.
   In allen uebrigen Faellen steht die Antwort zur Uebersetzungszeit fest;
   der Empfaenger wird dennoch ausgewertet. Siehe Abschnitt 20.1. *)

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
                    | LambdaExpr
                    | TupleExpr
                    | "(" Expr ")" ;

LambdaExpr          = "fn" "(" [ ParamList ] ")" [ ":" Type ] Block ;

(* Bis 1.0.16I fehlte diese Produktion, obwohl der Parser die Form seit jeher
   annimmt und die Doku sie an 35 Stellen nennt.

   EINFANGEN: was der Rumpf aus der umgebenden Funktion liest, wird BEIM
   ANLEGEN kopiert (by value). Eine spaetere Zuweisung an die aeussere Variable
   wirkt nicht mehr -- `var f := fn(x: int64): int64 { return x + n; };` mit
   anschliessendem `n := 1` rechnet weiter mit dem alten `n`.

   DARSTELLUNG: ein Lambda OHNE Einfangen ist eine gewoehnliche Funktion -- der
   Wert ist ihre Adresse, und es passt damit in einen `fn(...)`-Typ, als
   Variable wie als Parameter. Faengt es etwas ein, ist der Wert ein Satz aus
   Adresse und Umgebung; ein `fn(...)`-Typ traegt davon nur die Adresse, und
   der Uebergang wird deshalb GEMELDET. Bis 1.0.16I entschied die Aufrufstelle
   ihre Aufrufkonvention allein nach dem deklarierten Typ, waehrend der Wert
   stets ein Satz war: `var f: fn(int64): int64 := fn(x: int64): int64 {…}`
   sprang mitten in diesen Satz -- SIGSEGV ohne jede Meldung (#1249). *)

SelfExpr            = "self" | "Self" ;

SuperExpr           = "super" ;

TupleExpr           = "(" Expr "," Expr { "," Expr } ")" ;

(* Ein Tupel-AUSDRUCK ist dieselbe Ablage wie ein Array-Literal: `{cap,len}`-Kopf,
   dann die Elemente. `var u := (1, 2);` ist damit indizierbar (`u[0]`, `u[1]`)
   und traegt `len(u)` = 2; der Tupel-TYP einer Variablen wird nicht getrennt
   gefuehrt. Davon unabhaengig ist die Rueckgabe ZWEIER Werte in rax und rdx,
   entnommen mit `var a, b := f();` -- dort gilt die Zweierschranke aus
   TupleType. *)

ArgList             = Arg { "," Arg } ;

Arg                 = NamedArg
                    | Expr ;

NamedArg            = Ident ":" Expr ;

(* Benannte Argumente duerfen in beliebiger Reihenfolge stehen; ein
   POSITIONELLES Argument nach einem benannten wird gemeldet. Ein Parameter
   gilt als versorgt, wenn er positionell oder benannt belegt ist ODER einen
   Vorgabewert hat -- damit laesst sich ein hinterer Parameter einzeln setzen
   und ein mittlerer auf seinem Vorgabewert lassen (`G(1, c: 9)`). Bis 1.0.16I
   schaltete jedes benannte Argument die Vorgabewerte ab: sobald eines im
   Aufruf stand, verlangte die Pruefung jeden Parameter (#1252). Ebenfalls bis
   1.0.16I setzte der Pfad fuer SIEBEN und mehr Argumente Vorgabewerte gar
   nicht ein -- die Werte lagen dann verschoben. *)

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
BuiltinCall         = PanicExpr
                    | AssertExpr ;

(* #1234: Hier standen zusaetzlich CheckExpr (`check(...)`) und
   VerifyIntegrityCall (`VerifyIntegrity()`). Beide gibt es nicht -- der
   Compiler meldet "undefined function 'check'" bzw.
   "undefined function 'VerifyIntegrity'". `panic` und `assert` sind dagegen
   vorhanden und verhalten sich wie unten beschrieben. *)

PanicExpr           = "panic" "(" [ Expr ] ")" ;
(* panic ist KEIN Ausnahmemechanismus: die Meldung geht nach stderr, dann
   endet der Prozess mit 1. Ein umschliessendes `try` faengt ihn NICHT, und
   `finally` laeuft nicht mehr an — der Abbruch ist die Zusicherung des
   Konstrukts. Bis 1.0.15A sprang er in einen installierten Handler und war
   damit fangbar; das Programm lief mit gebrochener Invariante weiter (#1149).
   Dasselbe gilt fuer `assert`, die Bereichs- und die Grenzpruefung. Fangbar
   ist allein `throw`. *)

AssertExpr          = "assert" "(" Expr ")" ;

NewExpr             = "new" Type "(" [ ArgList ] ")"
                    | "new" Type "[" Expr "]" ;

(* Die zweite Form belegt ein Array, dessen Laenge erst zur LAUFZEIT feststeht:
   `16 + n*8` Byte, also `{cap,len}`-Kopf und n Slots, wie ein `[N]T`. `len(a)`
   liest denselben Kopf, und die dynamische Bereichspruefung haelt den Index
   dagegen. Eine Laenge <= 0 bricht mit `panic` ab. Bis 1.0.16G gab es die Form
   nicht -- eine gerechnete Groesse zwang zu alloc/poke64 (#1255). *)

DisposeExpr         = "dispose" Expr ;
```

---

# 17. Constant Expression Grammar

Constant expressions use the same precedence model as runtime expressions, but with a restricted primary set.

```ebnf
ConstExpr                 = ConstNullCoalesceExpr ;

(* #1232: Hier standen ConstPipeExpr, ConstPipeTarget und ConstPipeArgList.
   Der Pipe-Operator ist im Konstantenausdruck nicht umgesetzt und wird
   ausdruecklich abgewiesen ("pipe-forward not allowed in const expression").
   Das ist auch stimmig: `|>` reicht einen Wert an eine FUNKTION weiter, und
   ein Funktionsaufruf steht zur Uebersetzungszeit nicht zur Verfuegung --
   dieselbe Grenze, an der auch WP-1.2 Aufrufe im Konstantenausdruck sperrt.
   Zur Laufzeit gibt es den Operator unveraendert. *)

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
|     3 | `\|\|`, `or`                                               | Left          |
|     4 | `&&`, `and`                                                | Left          |
|     5 | `\|`, `\|~`                                                | Left          |
|     6 | `^`                                                        | Left          |
|     7 | `&`                                                        | Left          |
|     8 | `==`, `!=`                                                 | Left          |
|     9 | `<`, `<=`, `>`, `>=`, `in`                                 | Left          |
|    10 | `<<`, `>>`                                                 | Left          |
|    11 | `+`, `-`                                                   | Left          |
|    12 | `*`, `/`, `%`                                              | Left          |
|    13 | unary `+`, unary `-`, `!`, `not`, `~`                      | Right         |
|    14 | `as`, `is`                                                 | Left          |
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
| `Map<K,V>` | 14 | Benutzbar seit 1.0.15A (#1152/#1205): Literal, `m[k]` lesen und schreiben, `k in m`, `len(m)`, Deklaration ohne Initialisierung. Schluessel nur ganzzahlig — ein `pchar`-Schluessel wuerde ueber die Adresse verglichen und wird abgewiesen (#1291). Ein fehlender Schluessel liefert 0. `delete m[k]` und `for k, v in m` gibt es nicht. |
| `&x` (Adress-Operator) | 15 | Gibt es nicht. Ein Ausgabeparameter wird als Zelle uebergeben (`alloc(8)`, danach `peek64`). (#1061) |
| Aufruf ueber indizierten Ausdruck | 15 | `handlers[0](a)` ist kein Aufruf -- ein Aufruf haengt am NAMEN. Wird abgewiesen; ein Funktionszeiger wird zuerst einer Variablen zugewiesen. (#1053) |
| Nullable-Suffix, Pruefung | 7 | `T?` wird geparst und am Typknoten vermerkt, loest aber KEINE zusaetzliche Pruefung aus: ein nicht-nullbarer Typ nimmt weiterhin `null` an, und ein nullbarer wird ohne `?.` ungeprueft dereferenziert. Das Suffix dokumentiert die Absicht, es erzwingt sie nicht. `?.` dagegen prueft zur Laufzeit. (#1092) |
| Struktur-Literal als Wert | 15 | `P { t: 1, f: 0 }` gibt es nur als MUSTER (§14, StructPattern), nicht als Ausdruck: `var p: P := P { t: 1 };` wird mit "expected expression" abgewiesen. Ein struct-Local wird ohne Initialisierer angelegt und feldweise gefuellt. Die Asymmetrie ist festgehalten, nicht behoben. (#1104) |
| Attribute ohne Nachweis | 4 | `@integrity`, `@dal` und `@critical` werden geparst, in ihrer Argumentform geprueft und am Knoten vermerkt -- der Compiler weist die Zusicherung aber **nicht** nach. Keine TMR-Verifikation. `@stack_limit` (seit 1.0.14K, #1138), `@wcet` (seit 1.0.14L, #1139) und `@flight_crit` (seit 1.0.14M, #1140) sind NICHT mehr darunter. Sie sind seit #1099 nicht mehr stumm: jedes Vorkommen meldet den fehlenden Nachweis. Wer die Annotation setzt, bekommt sie also als Vermerk, nicht als Beweis. Unbekannte Attributnamen und falsche Argumentformen werden abgewiesen. |
| Typtest `is`, Reichweite | 15 | Zur LAUFZEIT geprueft wird nur gegen eine Klasse MIT Methoden -- nur die traegt einen Typzeiger. Eine Klasse OHNE Methode bekommt struct-Layout und damit keine VMT; dort ist die Antwort der statisch bekannte Vererbungsweg (plus `null`-Probe), und ein zur Laufzeit eingelagerter anderer Typ waere nicht zu sehen. Wo der statische Typ des Empfaengers nicht bestimmbar ist oder der genannte Typ weder Klasse noch eingebauter Typ ist (Alias, Generik), MELDET der Compiler das, statt `false` zu liefern. (#1094) |
| `static` an Feldern | 9 | `static fn` gibt es (Aufruf ueber den Typnamen, `self` darin abgewiesen). `static` an einem FELD wird abgewiesen: der Zugriff hiesse `A.v`, und diese Schreibweise bezeichnet in Lyx bereits den Byte-OFFSET des Feldes -- std/string.lyx nutzt sie so (`StringBuilder.capacity`). Welche Bedeutung gelten soll, ist eine Sprachentscheidung. Eine Klassenkonstante wird als `con` auf Modulebene geschrieben. (#1090) |
| Default-Werte, Auswertung | 15.1 | Ein weggelassenes Argument wird durch den Default ersetzt, solange die uebersprungenen Parameter am ENDE stehen. Steht hinter einem Default noch ein Parameter OHNE, laesst sich der Default nicht ueberspringen. Der Ausdruck muss zur Uebersetzungszeit feststehen -- er wird an jeder Aufrufstelle eingesetzt, ein nicht-konstanter liefe sonst je Aufruf erneut. Die Kombination aus benannten Argumenten und uebersprungenen Defaults gibt es nicht. (#1089) |
| Tupel-Entpacken, geklammerte Form | 12 | `var (q, r) := f();` gibt es nicht -- §12 (TupleUnpackStmt) schreibt die Form OHNE Klammern vor: `var q, r := f();`. Die DokuWiki fuehrt faelschlich die geklammerte. (#1088) |
| Tupel, Stelligkeit und Elementtypen | 7 | Ein Tupel hat GENAU ZWEI Elemente -- die Aufrufkonvention traegt zwei Rueckgabewerte (`rax`, `rdx`). Mehr wird beim Parsen abgewiesen; die Grammatik in §7 nannte bis 1.0.13P faelschlich `{ "," Type }`. Als Element sind auch Struct- und Klassentypen zugelassen: der Slot haelt den ZEIGER, wie bei jeder Struct-Variablen sonst. Bis 1.0.13P trug der entpackte Name keinen Typ -- der Zeiger kam an, aber `a.v` fand kein Feld und lieferte still `0` (#1122). Der Typ wird jetzt aus dem deklarierten Rueckgabetyp des Aufgerufenen uebernommen, bei freien Funktionen wie bei Methoden (auch geerbten). Ist der Aufgerufene dem Codegen unbekannt (importiert, Builtin), bleibt der Name typlos wie bisher. |
| Rechtsshift, Vorzeichen | 15 | `>>` zieht auf einem vorzeichenBEHAFTETEN Typ das Vorzeichenbit nach (arithmetisch, `SAR`) und fuellt auf einem vorzeichenLOSEN mit Nullen auf (`SHR`) -- massgeblich ist der LINKE Operand. Erkannt wird der Typ, wo er ohne Aufwand feststeht: eine Variable mit deklariertem Typ (lokal oder global) und der `as`-Cast; alles andere gilt als vorzeichenbehaftet. `(x as uint64) >> n` ist damit der ausdrueckliche Weg zum logischen Shift, den Rotationen und Konstante-Zeit-Idiome brauchen. Bis 1.0.13R fuellte `>>` IMMER mit Nullen auf: `-8 >> 1` ergab 9223372036854775804 statt -4, und weil das Ergebnis riesig positiv ist, folgte meist ein Speicher- oder Indexfehler statt einer Meldung (#1125). Der Shift-BETRAG wird wie in der Hardware auf 6 Bit maskiert -- `1 << 64` ergibt `1`, nicht `0`. |
| `in` als Operator | 15 | `x in a..b` prueft die Zugehoerigkeit zu einem Bereich, Grenzen EINSCHLIESSLICH wie beim Bereichsmuster in `match` und beim Bereichstyp; ein offenes Ende (`a..`) ist nach oben unbeschraenkt. Steht rechts kein Bereich, gilt weiterhin die Woerterbuch-Zugehoerigkeit (`schluessel in map`). Bis 1.0.13S lief JEDES `in` in den Woerterbuch-Zweig: `_lyx_map_has` bekam als "Map" das, was der Bereichsknoten hinterliess -- kein Zeiger, sondern die obere Grenze, waehrend die untere unbalanciert auf dem Stack blieb. Der Ausdruck uebersetzte und stuerzte zur Laufzeit ab (#1129). |
| Enum-Werte | 10 | Ein Mitglied ohne eigenen Wert zaehlt vom vorigen weiter, beginnend bei 0; ein ausdruecklicher Wert setzt den Zaehler neu (`A = 5, B, C` ergibt 5, 6, 7 — wie in C). Der Wert muss zur UEBERSETZUNGSZEIT feststehen (Literal, `con`, konstanter Ausdruck) und im Bereich 0..4294967295 liegen: Wert und Nutzlastgroesse teilen sich intern eine int64 (Wert unten, Groesse oben), ein negativer oder groesserer Wert liefe in die obere Haelfte. Beides wird gemeldet. Bis 1.0.14A wurde der angegebene Wert VERWORFEN: der Wertausdruck haengt am Mitglied als Kind und wurde als Nutzlast gezaehlt, womit `E.A` bei `A = 10` den Wert 2^32 + 0 lieferte -- auch dann, wenn der angegebene Wert der impliziten Zaehlung entsprach (#1131, #1157). Eine Nutzlast gibt es in der Deklaration nicht; die Musterform `Ok(wert)` wird beim `match` aufgeloest. |
| Speicherklassen, Schreibschutz | 11 | Eine Zuweisung an `let`, `co`, einen `con`-PARAMETER und seit 1.0.14C auch an eine `con`-Deklaration wird abgewiesen -- in jeder Form (`:=`, `+=`, `++`, `--`) und in beiden Geltungsbereichen. Bis 1.0.14B fiel die con-Deklaration durch, und das Ergebnis hing vom Ort ab: eine LOKALE `con` liess sich tatsaechlich aendern, bei einer GLOBALEN verpuffte die Zuweisung, weil der Wert als Immediate im Code steht. Derselbe Quelltext tat also je nach Geltungsbereich etwas anderes, gemeldet wurde nichts (#1132). |
| Interfaces, Dispatch | 9 | Ein Aufruf ueber eine Variable vom Interface-Typ laeuft ueber die VMT und trifft die Methode der WIRKLICHEN Klasse; die implementierende Methode braucht kein `virtual`. Umgesetzt ueber Selektoren: die Namen aller in Interfaces deklarierten Methoden bekommen je einen festen Slot, den JEDE Klasse an derselben Stelle fuehrt -- nur so trifft der Aufruf, der bloss das Interface kennt, dieselbe Stelle. Mehrere Interfaces an einer Klasse, Vererbung und die Mischung mit `virtual`/`override` sind damit abgedeckt. Bis 1.0.14C wurde das Interface als gewoehnliche Klasse registriert und fuer jede seiner Methoden ein LEERER Rumpf erzeugt, der 0 zurueckgab -- genau den rief der Aufruf ueber die Schnittstelle (#1133). Was ein Interface NICHT hat: Felder, Standardimplementierungen und einen Typtest `is` gegen den Interface-Namen. |
| Statische Pruefungen, Reichweite | 20 | Geprueft werden Namen, Stelligkeit und -- seit 1.0.14F/G -- Typen bei Initialisierung, Zuweisung, `return` und Argumenten, dazu die fehlende Rueckgabe, der doppelt vergebene Name im selben Block und die doppelt deklarierte Funktion im selben Modul. Die Typableitung kennt Literale, Variablen mit deklariertem Typ, den `as`-Cast und den Rueckgabetyp einer im selben Lauf deklarierten Funktion; alles andere (Builtins, Importiertes, Feld- und Indexzugriffe, Methodenaufrufe) gilt als unbestimmt und wird NICHT gemeldet. Zwei Muster bleiben ausdruecklich zugelassen: der `as`-Cast (er IST die Umwandlung) und die Null in einem `pchar`-Ziel (Nullzeiger). Eine Zeichenkette in einem GANZZAHL-Ziel war bis 1.0.14H ebenfalls zugelassen, weil `int64` in der stdlib durchgehend als Zeigertyp diente; das ist mit #1221 aufgeraeumt (470 Stellen in 16 Dateien tragen jetzt `pchar`), und seit 1.0.14I wird auch diese Richtung gemeldet. Arithmetik auf `pchar` bleibt ebenfalls zulaessig: `pchar` IST ein Zeiger, `peek8(src + i)` ist die uebliche zeichenweise Iteration. Die return-Pruefung ist KEINE Flussanalyse -- sie meldet nur, wenn im Rumpf gar kein Ausgang (`return`, `throw`, `panic`, `exit`) vorkommt. (#1135) |
| `@stack_limit`, Nachweis | 4 | Die Schranke wird in BYTES angegeben und in zwei Teilen geprueft: der Codegen haelt die RAHMENGROESSE der Funktion dagegen (er kennt sie, wenn er `sub rsp, imm32` patcht), und eine Funktion mit dem Attribut darf nicht rekursiv sein -- ohne nachweisbare Aufruftiefe ist der Gesamtverbrauch unbeschraenkt. Der Aufrufgraph erkennt auch INDIREKTE Zyklen. Beides sind harte Fehler. Nicht erfasst: der Verbrauch der AUFGERUFENEN Funktionen (Summe entlang der Aufrufkette) und dynamisch angeforderter Speicher. Zu beachten: ein `int64[N]` liegt NICHT im Rahmen -- Arrays bekommen einen Heap-Block, der Slot haelt den Zeiger, der Rahmen waechst also nur um 8 Byte je Variable. Bis 1.0.14J war das Attribut ein blosser Vermerk (#1099, #1138). |
| `@wcet`, Nachweis | 4 | Die Schranke zaehlt ITERATIONEN, nicht Zyklen: eine Zyklenzahl braeuchte ein Mikroarchitekturmodell, jede Zahl in einer Kostentabelle waere erfunden und damit ein Beweisanschein. Gezaehlt wird kumulativ -- eine Schleife mit Schranke B, in deren Rumpf I Iterationen stecken, traegt B * (1 + I) bei; zwei geschachtelte Zehnerschleifen ergeben 110. Abzaehlbar sind `for ... to`/`downto` und `for i in a..b` mit literalen Grenzen, `for i in range(A, B)`, `while (c) limit(N)` (§12) und `while (i < C)` mit literalem Startwert des Zaehlers, konstanter Grenze und GENAU EINER Fortschaltung `i := i + K`, K > 0. Alles andere ist in einer `@wcet`-Funktion ein harter FEHLER, kein stiller Durchlass: berechnete Schleifengrenzen, `repeat/until`, das C-artige `for`, Rekursion (auch indirekt, ueber den Aufrufgraphen) und der Aufruf einer Funktion ohne eigene Schranke. Traegt der Gerufene selbst ein `@wcet`, geht dessen N in die Summe ein. Kostenfrei sind allein die Speicher-Builtins `peek8/16/32/64`, `poke8/16/32/64` und `exit` -- sie erzeugen geradlinigen Code; die Liste steht in `src/frontend/wcet.lyx`. Importierte Funktionen liegen nicht vor und sind damit nicht nachweisbar, `PrintLn` eingeschlossen. Gilt auch fuer METHODEN. Bis 1.0.14K war das Attribut ein blosser Vermerk (#1099, #1139). |
| `@flight_crit`, Wirkung | 4 | Schaltet die SSE-Ausnahmen fuer *invalid* (MXCSR-Bit 7) und *divide-by-zero* (Bit 9) frei: der Prolog der annotierten Funktion sichert MXCSR und loescht die beiden Masken, der Epilog schreibt den alten Wert zurueck. Eine entstehende NaN oder Inf loest damit SIGFPE aus statt still weiterzulaufen; der Compiler gibt den passenden Handler mit (`__lyx_fc_handler`, eingehaengt in `main`), der `panic: FPU-Ausnahme (NaN/Inf oder Division durch 0) unter @flight_crit in \`NAME\`` meldet und mit 134 endet. **Reichweite: dynamisch.** MXCSR ist THREAD-Zustand -- ab dem Eintritt gilt der Trap auch fuer alles, was die Funktion RUFT, bis sie zurueckkehrt; ein Maskieren vor jedem Aufruf wuerde die Zusage an der ersten Funktionsgrenze enden lassen. Gilt auch fuer METHODEN. Nicht erfasst: Ueberlauf (Bit 10), Unterlauf (Bit 11) und Ungenauigkeit (Bit 12) bleiben maskiert -- zugesagt sind NaN und Inf, nicht jede IEEE-Ausnahme. Ganzzahlige Division durch 0 (#DE) loest denselben SIGFPE aus und wird vom Handler mitgemeldet; deshalb nennt der Text beide Anlaesse. Bis 1.0.14L war das Attribut ein blosser Vermerk (#1099, #1140). |
| `@redundant`, Reichweite und Pruefung | 4 | Die Variable wird DREIFACH abgelegt (TMR): drei Zellen hintereinander, Lesen ueber die Mehrheitsentscheidung, Schreiben in alle drei. Der Voter HEILT dabei die Minderheit -- eine verfaelschte Kopie wird ueberstimmt und korrigiert. Gilt seit 1.0.15A auch fuer GLOBALE Variablen (drei Datenzellen, Anfangswert in allen dreien); bis dahin wirkte das Attribut auf Modulebene gar nicht: acht Byte, kein Voter, kein Hinweis (#1141). Die Adresse-von-Form `@x` liefert die Adresse EINER Kopie und umgeht damit den Voter; ein Schreibzugriff darueber geht beim naechsten Mehrheitsentscheid verloren. Das wird gemeldet -- unter `--verify-tmr` als Fehler, sonst als Warnung. `--verify-tmr` druckt ausserdem die Bilanz (Variablen, gevotete Lesezugriffe, dreifache Schreibzugriffe, Umgehungen) und schlaegt mit Exit 1 fehl, sobald ein Zugriff am Voter vorbeigeht; eine Bilanz ohne Fehlschlag waere nur ein Bericht. |
| Binaere Operatoren, Typen | 15 | Die Operanden von `+ - * / %` und `^ & \| << >>` werden auf ihre Typen geprueft: `bool` ist dort keine Ganzzahl (`true + 1` ergab 2) und `pchar` kein Rechenwert (`"abc" * 2`). Die Meldung nennt den Operator und beide Typen. ZUGELASSEN bleibt, was die Sprache umgesetzt hat: die VERKETTUNG `pchar + pchar` (der Codegen emittiert dafuer StrConcat), die ZEIGERARITHMETIK `pchar + int64` und `pchar - int64` (auch `int64 + pchar`; `peek8(src + i)` steht im Bestand an 807 Stellen) und die BOOLESCHE ALGEBRA `^`, `&`, `\|` auf zwei Wahrheitswerten. Geurteilt wird nur, wenn BEIDE Typen bestimmt sind. Vergleiche bleiben unberuehrt. NICHT geprueft wird gemischte int/f64-Arithmetik -- `10 - 2.5` rechnet falsch, das ist ein eigener Punkt (#1212). (#1143) |
| `Print`/`PrintLn`, Typbestimmung | 15 | Der Drucker waehlt die Ausgaberoutine zur UEBERSETZUNGSZEIT (`cg_inferPrintType`): Zeichenkette, Gleitkomma, Wahrheitswert, sonst Ganzzahl. Eine VERKETTUNG als Argument fiel bis 1.0.15A durch und wurde als Zahl ausgegeben -- `PrintLn("Wert: " + IntToStr(7))` druckte die Adresse. Die Verkettung selbst war dabei immer richtig; nur ihre Einstufung fehlte (#1143). Ein Aufruf wird seit #1058 ueber den deklarierten Rueckgabetyp beziehungsweise die Liste der Zeichenketten-Builtins eingestuft. |
| Benannte Argumente, Auswertungsreihenfolge | 15.1 | `F(b: 2, a: 1)` ordnet richtig zu, wertet die Argumente aber in PARAMETERREIHENFOLGE aus, nicht in der geschriebenen. Bei Seiteneffekten in den Argumenten ist das sichtbar. Wo die Deklaration nicht herangezogen werden kann (importiert, extern, variadisch, generisch, Builtin), werden benannte Argumente ABGEWIESEN statt stillschweigend positionell genommen. (#1087) |
| Einheitentypen, Semantik | 11 | `utype N: Dim = Faktor` wirkt: bei Zuweisung zwischen Einheiten DERSELBEN Dimension rechnet der Compiler mit dem Faktorverhaeltnis um — erst multiplizieren, dann ganzzahlig teilen, `Km` nach `M` also exakt, `M` nach `Km` abschneidend wie die Ganzzahldivision sonst. Die DIMENSION wird geprueft: Zuweisung ueber Dimensionsgrenzen, Addition zweier Dimensionen und das Verrechnen mit einer dimensionslosen Zahl werden abgewiesen. Erlaubt bleiben ein Literal als Wert (`var a: Km := 2`), die Skalierung mit einer Zahl (`a * 3` behaelt die Einheit) und der `as`-Cast als bewusster Fluchtweg. `range LO..HI` bricht ausserhalb mit `panic` ab, `wraps LO..HI` rechnet in den Bereich zurueck; Grenzen einschliesslich, konstante Werte meldet der Compiler sofort. Bis 1.0.13D war `utype` ein Typalias mit dekorativem Faktor, und `range`/`wraps` parsten gar nicht (#1110). NICHT gerechnet werden abgeleitete Dimensionen: `dim Speed = Meter / Second` wird angenommen, aber `laenge / zeit` ergibt keine `Speed` — das Ergebnis gilt als dimensionslos, und `utype`-Werte sind ganzzahlig. |
| Array als Funktionsparameter | 6 | `fn F(a: int64[4])` uebergibt den ZEIGER auf die Ablage: der Callee liest und schreibt denselben Speicher, eine Zuweisung darin ist beim Aufrufer sichtbar. Die deklarierte Groesse wird mitgenommen, `len(a)` liefert sie, und die Bereichspruefung unter `--runtime-checks` (#1156) greift auch hier. Gilt fuer alle Uebergabewege: Register, Stack (ab dem siebten Argument) und Methodenparameter. Bis 1.0.13F fehlte im Callee die Merkung "das ist ein Array" — der Indexzugriff fiel in den Zweig fuer einen rohen Zeiger, lieferte lesend eine Adresse und schrieb ins Leere (#1115). Die Schreibweise `array[T]` ist als Parametertyp weiterhin nicht zugelassen. |
| Array mit Struct-/Klassen-Elementtyp | 7 | `T[N]` haelt ZEIGER-Slots: `arr[i] := s` teilt das Objekt mit `s`, wie die Struct-Zuweisung sonst auch, und `arr[i].feld := x` wirkt auf beide. Die Slots werden bei der Deklaration mit frischen Objekten belegt — ein `arr[0].v := 42` braucht also kein vorheriges `new`, genau wie ein `var s: S;` seit WP-10d angelegt wird. Belegt werden `16 + N*8` Byte: die 16 sind der `{cap,len}`-Kopf, den der Indexzugriff ueberspringt. Bis 1.0.13C wurde der Elementtyp am Local nicht vermerkt, `arr[0].v` bekam Feldoffset -1 und lieferte still `0`; ausserdem wurden nur `N*8` Byte angefordert, die Zugriffe lagen also um einen Kopf verschoben dahinter (#1109). Ein `array[T]`, `Array<T>` oder `T[]` OHNE Initialisierung wird seit 1.0.13H ebenfalls belegt: leer, mit `{cap,len}`-Kopf (`len` = 0). `len(a)` liefert damit 0 statt auf eine Null zu treffen, und ein Schreibzugriff kommt an; `push` findet den Zeiger gesetzt vor und legt nicht erneut an. Bis 1.0.13G war die Variable null, und nur `push` legte an — beim ERSTEN Aufruf (#1177). |
| Aggregate auf Modulebene | 10 | Ein globales `[N]T` oder ein globales Struct passt nicht in den 8-Byte-Slot der Variablen. Es bekommt seit 1.0.16G einen eigenen Block im Datenbereich -- `{cap,len}`-Kopf plus `N*8` Byte beim Array, die Feldgroesse beim Struct --, der Slot traegt einen ZEIGER darauf; das ist dieselbe Form, die ein Local zur Laufzeit per mmap anlegt, nur schon zur Uebersetzungszeit. Damit wirken `q[0] := 3`, `s.x := 3`, `len(q)` und ein Array-Literal als Startwert auch auf Modulebene, und der Typ darf UNTER der Variablen deklariert stehen (das Layout wird vorgezogen). Bis 1.0.16G blieb der Slot 0: `q[0] := 3` schrieb nach Adresse 16 und stuerzte ab, `s.x := 3` verpuffte still, und ein Array-Literal als Startwert fiel ersatzlos weg -- der zugehoerige Test druckte 0/0/0 und galt trotzdem als gruen (#1256, #1299). Nicht umgesetzt und deshalb GEMELDET: Struct-Elemente in einem globalen Array (jedes Element braeuchte ein eigenes Objekt, das es zur Uebersetzungszeit nicht gibt), `@redundant` auf einem Aggregat und eine Elementzahl, die keine Konstante zwischen 1 und 33554431 ist. |
| Capability-Argumente, Wirkung | 22 | Der Capability-NAME wird geprueft, der ARGUMENTNAME seit 1.0.13C ebenfalls: ein unbekannter Schluessel (`fs.read(pfad: …)`) und ein Argument an einer Capability, die keine nimmt, werden abgewiesen. Gueltige Schluessel: `path` (fs.*, process.exec), `host`/`port` (network.*), `pin` (hardware.gpio), `bus` (i2c/spi), `cs` (spi), `vendor`/`product` (usb). Der WERT wird jedoch **nicht durchgesetzt** — die Sandbox wirkt als Ja/Nein (seccomp-Syscallfilter plus EINE Landlock-Regel fuer `/`), nicht als Beschraenkung auf den genannten Pfad, Rechner oder Port. Der Compiler meldet das an jedem Argument, statt eine Sicherheitszusage vorzutaeuschen, die es nicht gibt (#1108); die Durchsetzung ist als #1173 geführt. Die PortSpec-Bereichsform (`"host":8000-9000`) parst seit 1.0.13C und wird auf Start <= Ende geprueft. |
| Schmale Ganzzahltypen, Breite | 7 | `intN`/`uintN` mit N < 64 belegen einen vollen 64-Bit-Slot; gekuerzt wird beim SPEICHERN, vorzeichenbehaftet bei `intN`, vorzeichenlos bei `uintN`. Erfasst sind Initialisierung, Zuweisung, Parameter, Rueckgabe, globale Variablen und der `as`-Cast; Strukturfelder liegen ohnehin in ihrer eigenen Breite. Bis 1.0.11D fand die Kuerzung an KEINER dieser Stellen statt (`var a: int8 := 130` ergab 130 statt -126), und `as int8`/`as int16` kuerzten nur in der kurzen Schreibweise (`as i8`) -- #1151. Ein konstanter Wert, der nicht in die Breite passt, wird gekuerzt und nicht gemeldet. Eine globale Variable mit BERECHNETER Initialisierung bleibt weiterhin still 0 (#1164). |
| Indexzugriff, Bereichspruefung | 15 | Ein konstanter Index auf eine Variable mit fester Groesse (`int64[N]` oder ein Array-Literal als Initialisierung) wird zur UEBERSETZUNGSZEIT geprueft und ausserhalb der Grenzen abgewiesen -- ohne Schalter. Berechnete Indizes prueft der erzeugte Code nur unter `--runtime-checks`; dann bricht ein Zugriff ausserhalb mit `panic` ab ("index out of bounds"). Der Vergleich ist vorzeichenLOS, ein negativer Index faellt also in denselben Zweig. `@bounds_check(true)` fordert sie umgekehrt AN und wirkt damit auch OHNE `--runtime-checks`; `@bounds_check(false)` schaltet sie im Geltungsbereich ab, auch WENN die Option gesetzt ist -- die Direktive steht naeher am Code. Bis 1.0.13Q war die Direktive nur in der Richtung `false` wirksam: der Vorgabewert stand auf "an", "angefordert" und "nicht gesetzt" waren nicht zu unterscheiden, und `@bounds_check(true)` erzeugte dieselbe Binary wie gar keine Angabe (#1124). NICHT geprueft wird, wo es keine Laenge gibt: roher Zeiger, `pchar`, Array-Parameter und inline liegende Struct-Felder. Bis 1.0.11D emittierte `--runtime-checks` fuer Indizes gar nichts -- der Zugriff las still den Speicher dahinter (#1156). Nur das x86-64-Backend traegt diese Pruefung; die uebrigen Backends kennen `--runtime-checks` insgesamt nicht. |
| Bereichstyp, Pruefzeitpunkt | 7 | `type X = int64 range LO..HI;` wird geprueft, wo ein Wert den Typ ANNIMMT: Initialisierung, Zuweisung (lokal wie global), Parameter, Rueckgabe und Strukturfeld -- bei Funktionen wie bei Methoden. Steht der Wert zur UEBERSETZUNGSZEIT fest (Literal, `con`, konstanter Ausdruck), meldet der Compiler ihn dort (#1082); sonst prueft der erzeugte Code zur Laufzeit und bricht mit `panic` ab (#1097). Die Laufzeitpruefung haengt NICHT an `--runtime-checks`: der Bereich ist der einzige Inhalt dieses Typs. Grenzen sind einschliesslich, der Vergleich vorzeichenbehaftet. Nicht erfasst: ein Wert, der ueber einen `as`-Cast oder einen Zeiger am Typ vorbei geschrieben wird. |

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

CapabilityPath    = CapSegment { "." CapSegment } ;

(* Ein Segment ist ein NAME, keine Ausdrucksform: auch reservierte Woerter
   sind zulaessig. `process.signal` ist der gaengige Fall — `signal` ist ein
   Schluesselwort und war bis 1.0.17F nicht schreibbar, obwohl die Capability
   in der Registry steht (#1198, #1347). Der Parser prueft die Schreibweise
   des Tokens, nicht seine Art. *)
CapSegment        = Ident | Keyword ;

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

(* Gueltige Argumentnamen je Capability: `path` fuer `fs.*` und
   `process.exec`; `host` und `port` fuer `network.*`; `pin` fuer
   `hardware.gpio`; `bus` fuer `hardware.i2c` und `hardware.spi`; `cs` fuer
   `hardware.spi`; `vendor` und `product` fuer `hardware.usb`. Alle uebrigen
   Capabilities nehmen keine Argumente. Ein anderer Name wird abgewiesen.

   Der WERT wird nicht durchgesetzt — siehe 20.1. *)

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

