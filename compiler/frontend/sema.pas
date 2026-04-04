{$mode objfpc}{$H+}
unit sema;

interface

uses
  SysUtils, Classes, ast, diag, lexer, unit_manager, bytes, tobject, backend_types;

type
  TSymbolKind = (symVar, symLet, symCon, symFunc);

  TSymbol = class
  public
    Name: string;
    Kind: TSymbolKind;
    DeclType: TAurumType;
    TypeName: string; // for named types (structs/classes)
    StructDecl: TAstStructDecl; // if this symbol refers to an instance of a struct type
    ClassDecl: TAstClassDecl; // if this symbol refers to an instance of a class type
    ReturnTypeName: string; // for functions: name of return type if struct
    ReturnStructDecl: TAstStructDecl; // for functions: struct decl if returns struct
    ArrayLen: Integer; // 0 = not array, >0 = static length, -1 = dynamic
    // for functions
    ParamTypes: array of TAurumType;
    ParamCount: Integer;
    IsVarArgs: Boolean; // true for variadic functions like printf
    IsExtern: Boolean;  // true for extern fn declarations (libc etc.)
    IsImported: Boolean; // true for functions imported from another unit
    // for global variables
    IsGlobal: Boolean; // true if this is a global variable
    // Generic function type parameters, e.g., ['T'] for fn max[T](...)
    GenericTypeParams: TStringArray;
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

  TSema = class
  private
    FDiag: TDiagnostics;
    FScopes: array of TStringList; // each contains name -> TSymbol as object
    FCurrentReturn: TAurumType;
    FUnitManager: TUnitManager;
    FImportedUnits: TStringList; // Alias -> UnitPath for resolving qualified names
    FStructTypes: TStringList; // name -> TAstStructDecl as object
    FClassTypes: TStringList;  // name -> TAstClassDecl as object
    FEnumTypes: TStringList;   // name -> nil (enum type names, backed by int64)
    FRangeTypes: TStringList;  // name -> TAstTypeDecl (range types, aerospace-todo P1 #7)
    FCurrentClass: TAstClassDecl; // current class being analyzed (for super resolution)
    // Closure support
    FFuncScopeDepth: Integer; // scope depth of current function boundary
    FCurrentNestedFunc: TAstFuncDecl; // nested function currently being analyzed
    procedure PushScope;
    procedure PopScope;
    procedure AddSymbolToCurrent(sym: TSymbol; span: TSourceSpan);
    function ResolveSymbol(const name: string): TSymbol;
    function ResolveSymbolLevel(const name: string): Integer; // returns scope depth or -1
    function ResolveQualifiedName(const qualifier, name: string; span: TSourceSpan): TSymbol;
    procedure DeclareBuiltinFunctions;
    procedure RegisterTObject;
    procedure ProcessImports(prog: TAstProgram);
    procedure ImportUnit(imp: TAstImportDecl);
    function TypeEqual(a, b: TAurumType): Boolean;
    function CompileRegex(const pattern: string; span: TSourceSpan;
      out compiled: string; out captureSlots: Integer): Boolean;
    function CheckExpr(expr: TAstExpr): TAurumType;
    function CheckStructLit(sl: TAstStructLit): TAurumType;
    procedure CheckStmt(stmt: TAstStmt);
  public
    constructor Create(d: TDiagnostics; um: TUnitManager = nil);
    destructor Destroy; override;
    procedure Analyze(prog: TAstProgram);
    procedure AnalyzeWithUnits(prog: TAstProgram; um: TUnitManager);
    // Struct layout
    procedure ComputeStructLayouts;
    // Class layout
    procedure ComputeClassLayouts;
    // VMT (Virtual Method Table)
    procedure ResolveVMTForClasses;
    procedure RegisterInheritedMethods;
    // Member access control
    procedure CheckMemberAccess(const memberName: string; memberClass: TAstClassDecl; visibility: TVisibility; span: TSourceSpan);
    // AST rewrite helpers
    function RewriteExpr(expr: TAstExpr): TAstExpr;
    function RewriteStmt(stmt: TAstStmt): TAstStmt;
    procedure RewriteAST(prog: TAstProgram);
  end;

implementation

const
  MaxRegexCaptureSlots = 32;

type
  TRegexRange = record
    StartChar: Integer;
    EndChar: Integer;
  end;

  TRegexCharClass = record
    Negated: Boolean;
    Ranges: array of TRegexRange;
  end;

  TRegexNodeKind = (
    rnEmpty, rnLiteral, rnAny, rnClass, rnConcat, rnAlt, rnRepeat, rnGroup, rnBol, rnEol
  );

  TRegexNode = class
  public
    Kind: TRegexNodeKind;
    Ch: Integer;
    CharClass: TRegexCharClass;
    Children: array of TRegexNode;
    MinCount: Integer;
    MaxCount: Integer;
    GroupIndex: Integer;
    constructor Create(aKind: TRegexNodeKind);
    destructor Destroy; override;
  end;

  TRegexParser = class
  private
    FPattern: string;
    FIndex: Integer;
    FDiag: TDiagnostics;
    FSpan: TSourceSpan;
    FGroupCount: Integer;
    FFailed: Boolean;
    function AtEnd: Boolean;
    function PeekChar: Char;
    function NextChar: Char;
    procedure Error(const msg: string);
    function ParseRegex: TRegexNode;
    function ParseAlt: TRegexNode;
    function ParseConcat: TRegexNode;
    function ParseRepeat: TRegexNode;
    function ParseAtom: TRegexNode;
    function ParseCharClass: TRegexNode;
    function ParseNumber(out value: Integer): Boolean;
    function ParseEscape(out ch: Integer; out classNode: TRegexNode): Boolean;
  public
    constructor Create(const pattern: string; diag: TDiagnostics; span: TSourceSpan);
    function Parse(out root: TRegexNode; out groupCount: Integer): Boolean;
  end;

  TRegexInstrKind = (riChar, riAny, riClass, riSplit, riJmp, riMatch, riSave, riBol, riEol);

  TRegexInstr = record
    Kind: TRegexInstrKind;
    CharVal: Integer;
    ClassIndex: Integer;
    X: Integer;
    Y: Integer;
    Slot: Integer;
  end;

  TRegexOutRef = record
    InstrIndex: Integer;
    Field: Integer;
  end;

  TRegexOutList = array of TRegexOutRef;

  TRegexClass = record
    Negated: Boolean;
    Ranges: array of TRegexRange;
  end;

  TRegexFrag = record
    Start: Integer;
    Outs: TRegexOutList;
  end;

  TRegexCompiler = class
  private
    FInstrs: array of TRegexInstr;
    FClasses: array of TRegexClass;
    function EmitInstr(kind: TRegexInstrKind): Integer;
    function EmitChar(ch: Integer): Integer;
    function EmitClass(const cls: TRegexCharClass): Integer;
    function EmitSave(slot: Integer): Integer;
    function EmitJmp: Integer;
    function EmitSplit: Integer;
    function EmitBol: Integer;
    function EmitEol: Integer;
    function EmitAny: Integer;
    function EmitMatch: Integer;
    function EmitEmpty: TRegexFrag;
    function MakeOut(idx, field: Integer): TRegexOutRef;
    function SingleOut(idx, field: Integer): TRegexOutList;
    function AppendOuts(const a, b: TRegexOutList): TRegexOutList;
    procedure Patch(const outs: TRegexOutList; target: Integer);
    function MakeFrag(start: Integer; const outs: TRegexOutList): TRegexFrag;
    function Concat(const a, b: TRegexFrag): TRegexFrag;
    function CompileNode(node: TRegexNode): TRegexFrag;
    function InstrSize(const instr: TRegexInstr): Integer;
  public
    function Compile(root: TRegexNode; captureSlots: Integer): string;
  end;

{ TSymbol }

constructor TSymbol.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Kind := symVar;
  DeclType := atUnresolved;
  TypeName := '';
  StructDecl := nil;
  ClassDecl := nil;
  ReturnTypeName := '';
  ReturnStructDecl := nil;
  ArrayLen := 0;
  ParamCount := 0;
  IsVarArgs := False;
  IsGlobal := False;
  SetLength(ParamTypes, 0);
end;

destructor TSymbol.Destroy;
begin
  SetLength(ParamTypes, 0);
  inherited Destroy;
end;

const
  RX_OP_CHAR = 1;
  RX_OP_ANY = 2;
  RX_OP_CLASS = 3;
  RX_OP_SPLIT = 4;
  RX_OP_JMP = 5;
  RX_OP_MATCH = 6;
  RX_OP_SAVE = 7;
  RX_OP_BOL = 8;
  RX_OP_EOL = 9;

{ TRegexNode }

constructor TRegexNode.Create(aKind: TRegexNodeKind);
begin
  inherited Create;
  Kind := aKind;
  Ch := 0;
  CharClass.Negated := False;
  SetLength(CharClass.Ranges, 0);
  SetLength(Children, 0);
  MinCount := 0;
  MaxCount := 0;
  GroupIndex := 0;
end;

destructor TRegexNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Children) do
    if Assigned(Children[i]) then
      Children[i].Free;
  SetLength(Children, 0);
  SetLength(CharClass.Ranges, 0);
  inherited Destroy;
end;

{ TRegexParser }

constructor TRegexParser.Create(const pattern: string; diag: TDiagnostics; span: TSourceSpan);
begin
  inherited Create;
  FPattern := pattern;
  FIndex := 1;
  FDiag := diag;
  FSpan := span;
  FGroupCount := 0;
  FFailed := False;
end;

function TRegexParser.AtEnd: Boolean;
begin
  Result := FIndex > Length(FPattern);
end;

function TRegexParser.PeekChar: Char;
begin
  if AtEnd then
    Result := #0
  else
    Result := FPattern[FIndex];
end;

function TRegexParser.NextChar: Char;
begin
  Result := PeekChar;
  Inc(FIndex);
end;

procedure TRegexParser.Error(const msg: string);
begin
  if FFailed then
    Exit;
  FFailed := True;
  FDiag.Error('regex parse error at position ' + IntToStr(FIndex) + ': ' + msg, FSpan);
end;

function TRegexParser.ParseNumber(out value: Integer): Boolean;
var
  start: Integer;
begin
  start := FIndex;
  value := 0;
  while (not AtEnd) and (PeekChar in ['0'..'9']) do
  begin
    value := (value * 10) + (Ord(NextChar) - Ord('0'));
  end;
  Result := FIndex > start;
end;

function TRegexParser.ParseEscape(out ch: Integer; out classNode: TRegexNode): Boolean;
var
  esc: Char;
  range: TRegexRange;
  cls: TRegexNode;
begin
  Result := False;
  classNode := nil;
  if AtEnd then
  begin
    Error('unerwartetes Ende nach \\');
    Exit;
  end;
  esc := NextChar;
  case esc of
    'd':
      begin
        cls := TRegexNode.Create(rnClass);
        range.StartChar := Ord('0');
        range.EndChar := Ord('9');
        SetLength(cls.CharClass.Ranges, 1);
        cls.CharClass.Ranges[0] := range;
        classNode := cls;
        Result := True;
        Exit;
      end;
    'w':
      begin
        cls := TRegexNode.Create(rnClass);
        SetLength(cls.CharClass.Ranges, 3);
        cls.CharClass.Ranges[0].StartChar := Ord('0');
        cls.CharClass.Ranges[0].EndChar := Ord('9');
        cls.CharClass.Ranges[1].StartChar := Ord('A');
        cls.CharClass.Ranges[1].EndChar := Ord('Z');
        cls.CharClass.Ranges[2].StartChar := Ord('a');
        cls.CharClass.Ranges[2].EndChar := Ord('z');
        range.StartChar := Ord('_');
        range.EndChar := Ord('_');
        SetLength(cls.CharClass.Ranges, 4);
        cls.CharClass.Ranges[3] := range;
        classNode := cls;
        Result := True;
        Exit;
      end;
    's':
      begin
        cls := TRegexNode.Create(rnClass);
        SetLength(cls.CharClass.Ranges, 4);
        cls.CharClass.Ranges[0].StartChar := 9;
        cls.CharClass.Ranges[0].EndChar := 9;
        cls.CharClass.Ranges[1].StartChar := 10;
        cls.CharClass.Ranges[1].EndChar := 10;
        cls.CharClass.Ranges[2].StartChar := 13;
        cls.CharClass.Ranges[2].EndChar := 13;
        cls.CharClass.Ranges[3].StartChar := Ord(' ');
        cls.CharClass.Ranges[3].EndChar := Ord(' ');
        classNode := cls;
        Result := True;
        Exit;
      end;
    'n': ch := 10;
    'r': ch := 13;
    't': ch := 9;
  else
    ch := Ord(esc);
  end;
  Result := True;
end;

function TRegexParser.ParseCharClass: TRegexNode;
var
  node: TRegexNode;
  havePrev: Boolean;
  prev: Integer;
  ch: Integer;
  nextCh: Integer;
  classNode: TRegexNode;
  procedure AddRange(aStart, aEnd: Integer);
  var
    idx: Integer;
  begin
    idx := Length(node.CharClass.Ranges);
    SetLength(node.CharClass.Ranges, idx + 1);
    node.CharClass.Ranges[idx].StartChar := aStart;
    node.CharClass.Ranges[idx].EndChar := aEnd;
  end;
begin
  node := TRegexNode.Create(rnClass);
  NextChar; // '['
  if AtEnd then
  begin
    Error('unclosed character class');
    Result := node;
    Exit;
  end;
  if PeekChar = '^' then
  begin
    node.CharClass.Negated := True;
    NextChar;
  end;
  havePrev := False;
  prev := 0;
  while not AtEnd do
  begin
    if PeekChar = ']' then
    begin
      NextChar;
      Break;
    end;
    if PeekChar = '\\' then
    begin
      NextChar;
      if not ParseEscape(ch, classNode) then
        Break;
      if Assigned(classNode) then
      begin
        if havePrev then
        begin
          AddRange(prev, prev);
          havePrev := False;
        end;
        for nextCh := 0 to High(classNode.CharClass.Ranges) do
          AddRange(classNode.CharClass.Ranges[nextCh].StartChar,
            classNode.CharClass.Ranges[nextCh].EndChar);
        classNode.Free;
        Continue;
      end;
    end
    else
      ch := Ord(NextChar);
    if (ch = Ord('-')) and havePrev and (not AtEnd) and (PeekChar <> ']') then
    begin
      if PeekChar = '\\' then
      begin
        NextChar;
        if not ParseEscape(nextCh, classNode) then
          Break;
        if Assigned(classNode) then
        begin
          Error('character class range cannot use class escape');
          classNode.Free;
          Break;
        end;
      end
      else
        nextCh := Ord(NextChar);
      AddRange(prev, nextCh);
      havePrev := False;
      Continue;
    end;
    if havePrev then
      AddRange(prev, prev);
    prev := ch;
    havePrev := True;
  end;
  if havePrev then
    AddRange(prev, prev);
  Result := node;
end;

function TRegexParser.ParseAtom: TRegexNode;
var
  node: TRegexNode;
  child: TRegexNode;
  ch: Integer;
  classNode: TRegexNode;
begin
  if AtEnd then
  begin
    Result := nil;
    Exit;
  end;
  case PeekChar of
    '(':
      begin
        NextChar;
        child := ParseAlt;
        if PeekChar <> ')' then
          Error('missing )')
        else
          NextChar;
        Inc(FGroupCount);
        node := TRegexNode.Create(rnGroup);
        node.GroupIndex := FGroupCount;
        SetLength(node.Children, 1);
        node.Children[0] := child;
        Result := node;
      end;
    '.':
      begin
        NextChar;
        Result := TRegexNode.Create(rnAny);
      end;
    '^':
      begin
        NextChar;
        Result := TRegexNode.Create(rnBol);
      end;
    '$':
      begin
        NextChar;
        Result := TRegexNode.Create(rnEol);
      end;
    '[':
      Result := ParseCharClass;
    '\':
      begin
        NextChar;
        if not ParseEscape(ch, classNode) then
        begin
          Result := nil;
          Exit;
        end;
        if Assigned(classNode) then
        begin
          Result := classNode;
          Exit;
        end;
        node := TRegexNode.Create(rnLiteral);
        node.Ch := ch;
        Result := node;
      end;
  else
    begin
      ch := Ord(NextChar);
      node := TRegexNode.Create(rnLiteral);
      node.Ch := ch;
      Result := node;
    end;
  end;
end;

function TRegexParser.ParseRepeat: TRegexNode;
var
  atom: TRegexNode;
  node: TRegexNode;
  minCount: Integer;
  maxCount: Integer;
  value: Integer;
  hasNumber: Boolean;
begin
  atom := ParseAtom;
  if atom = nil then
  begin
    Result := nil;
    Exit;
  end;
  if AtEnd then
  begin
    Result := atom;
    Exit;
  end;
  case PeekChar of
    '*':
      begin
        NextChar;
        node := TRegexNode.Create(rnRepeat);
        node.MinCount := 0;
        node.MaxCount := -1;
      end;
    '+':
      begin
        NextChar;
        node := TRegexNode.Create(rnRepeat);
        node.MinCount := 1;
        node.MaxCount := -1;
      end;
    '?':
      begin
        NextChar;
        node := TRegexNode.Create(rnRepeat);
        node.MinCount := 0;
        node.MaxCount := 1;
      end;
    '{':
      begin
        NextChar;
        if not ParseNumber(value) then
        begin
          Error('expected number in quantifier');
          Result := atom;
          Exit;
        end;
        minCount := value;
        maxCount := value;
        if PeekChar = ',' then
        begin
          NextChar;
          hasNumber := ParseNumber(value);
          if hasNumber then
            maxCount := value
          else
            maxCount := -1;
        end;
        if PeekChar <> '}' then
          Error('unterminated quantifier')
        else
          NextChar;
        if (maxCount >= 0) and (maxCount < minCount) then
          Error('quantifier max < min');
        node := TRegexNode.Create(rnRepeat);
        node.MinCount := minCount;
        node.MaxCount := maxCount;
      end;
  else
    begin
      Result := atom;
      Exit;
    end;
  end;
  SetLength(node.Children, 1);
  node.Children[0] := atom;
  Result := node;
end;

function TRegexParser.ParseConcat: TRegexNode;
var
  parts: array of TRegexNode;
  node: TRegexNode;
  idx: Integer;
begin
  SetLength(parts, 0);
  while (not AtEnd) and (PeekChar <> ')') and (PeekChar <> '|') do
  begin
    node := ParseRepeat;
    if node = nil then
      Break;
    idx := Length(parts);
    SetLength(parts, idx + 1);
    parts[idx] := node;
  end;
  if Length(parts) = 0 then
  begin
    Result := TRegexNode.Create(rnEmpty);
    Exit;
  end;
  if Length(parts) = 1 then
  begin
    Result := parts[0];
    Exit;
  end;
  node := TRegexNode.Create(rnConcat);
  node.Children := parts;
  Result := node;
end;

function TRegexParser.ParseAlt: TRegexNode;
var
  parts: array of TRegexNode;
  node: TRegexNode;
  idx: Integer;
begin
  SetLength(parts, 0);
  node := ParseConcat;
  idx := Length(parts);
  SetLength(parts, idx + 1);
  parts[idx] := node;
  while (not AtEnd) and (PeekChar = '|') do
  begin
    NextChar;
    node := ParseConcat;
    idx := Length(parts);
    SetLength(parts, idx + 1);
    parts[idx] := node;
  end;
  if Length(parts) = 1 then
  begin
    Result := parts[0];
    Exit;
  end;
  node := TRegexNode.Create(rnAlt);
  node.Children := parts;
  Result := node;
end;

function TRegexParser.ParseRegex: TRegexNode;
begin
  Result := ParseAlt;
end;

function TRegexParser.Parse(out root: TRegexNode; out groupCount: Integer): Boolean;
begin
  root := ParseRegex;
  if not AtEnd then
    Error('unexpected trailing characters');
  groupCount := FGroupCount;
  Result := not FFailed;
end;

{ TRegexCompiler }

function TRegexCompiler.EmitInstr(kind: TRegexInstrKind): Integer;
begin
  SetLength(FInstrs, Length(FInstrs) + 1);
  Result := High(FInstrs);
  FInstrs[Result].Kind := kind;
  FInstrs[Result].CharVal := 0;
  FInstrs[Result].ClassIndex := -1;
  FInstrs[Result].X := -1;
  FInstrs[Result].Y := -1;
  FInstrs[Result].Slot := -1;
end;

function TRegexCompiler.EmitChar(ch: Integer): Integer;
begin
  Result := EmitInstr(riChar);
  FInstrs[Result].CharVal := ch;
end;

function TRegexCompiler.EmitClass(const cls: TRegexCharClass): Integer;
var
  idx: Integer;
  i: Integer;
begin
  idx := Length(FClasses);
  SetLength(FClasses, idx + 1);
  FClasses[idx].Negated := cls.Negated;
  SetLength(FClasses[idx].Ranges, Length(cls.Ranges));
  for i := 0 to High(cls.Ranges) do
    FClasses[idx].Ranges[i] := cls.Ranges[i];
  Result := EmitInstr(riClass);
  FInstrs[Result].ClassIndex := idx;
end;

function TRegexCompiler.EmitSave(slot: Integer): Integer;
begin
  Result := EmitInstr(riSave);
  FInstrs[Result].Slot := slot;
end;

function TRegexCompiler.EmitJmp: Integer;
begin
  Result := EmitInstr(riJmp);
end;

function TRegexCompiler.EmitSplit: Integer;
begin
  Result := EmitInstr(riSplit);
end;

function TRegexCompiler.EmitBol: Integer;
begin
  Result := EmitInstr(riBol);
end;

function TRegexCompiler.EmitEol: Integer;
begin
  Result := EmitInstr(riEol);
end;

function TRegexCompiler.EmitAny: Integer;
begin
  Result := EmitInstr(riAny);
end;

function TRegexCompiler.EmitMatch: Integer;
begin
  Result := EmitInstr(riMatch);
end;

function TRegexCompiler.MakeOut(idx, field: Integer): TRegexOutRef;
begin
  Result.InstrIndex := idx;
  Result.Field := field;
end;

function TRegexCompiler.SingleOut(idx, field: Integer): TRegexOutList;
begin
  SetLength(Result, 1);
  Result[0] := MakeOut(idx, field);
end;

function TRegexCompiler.AppendOuts(const a, b: TRegexOutList): TRegexOutList;
var
  i: Integer;
  base: Integer;
begin
  SetLength(Result, Length(a) + Length(b));
  for i := 0 to High(a) do
    Result[i] := a[i];
  base := Length(a);
  for i := 0 to High(b) do
    Result[base + i] := b[i];
end;

procedure TRegexCompiler.Patch(const outs: TRegexOutList; target: Integer);
var
  i: Integer;
  ref: TRegexOutRef;
begin
  for i := 0 to High(outs) do
  begin
    ref := outs[i];
    if ref.Field = 1 then
      FInstrs[ref.InstrIndex].X := target
    else
      FInstrs[ref.InstrIndex].Y := target;
  end;
end;

function TRegexCompiler.MakeFrag(start: Integer; const outs: TRegexOutList): TRegexFrag;
begin
  Result.Start := start;
  Result.Outs := outs;
end;

function TRegexCompiler.Concat(const a, b: TRegexFrag): TRegexFrag;
begin
  Patch(a.Outs, b.Start);
  Result.Start := a.Start;
  Result.Outs := b.Outs;
end;

function TRegexCompiler.EmitEmpty: TRegexFrag;
var
  idx: Integer;
begin
  idx := EmitJmp;
  Result.Start := idx;
  Result.Outs := SingleOut(idx, 1);
end;

function TRegexCompiler.CompileNode(node: TRegexNode): TRegexFrag;
var
  frag: TRegexFrag;
  nextFrag: TRegexFrag;
  i: Integer;
  splitIdx: Integer;
  baseFrag: TRegexFrag;
  optFrag: TRegexFrag;
  minCount: Integer;
  maxCount: Integer;
  repeats: Integer;
  saveStart: Integer;
  saveEnd: Integer;
  tempFrag: TRegexFrag;
begin
  case node.Kind of
    rnEmpty:
      Result := EmitEmpty;
    rnLiteral:
      Result := MakeFrag(EmitChar(node.Ch), SingleOut(High(FInstrs), 1));
    rnAny:
      Result := MakeFrag(EmitAny, SingleOut(High(FInstrs), 1));
    rnClass:
      Result := MakeFrag(EmitClass(node.CharClass), SingleOut(High(FInstrs), 1));
    rnBol:
      Result := MakeFrag(EmitBol, SingleOut(High(FInstrs), 1));
    rnEol:
      Result := MakeFrag(EmitEol, SingleOut(High(FInstrs), 1));
    rnConcat:
      begin
        frag := CompileNode(node.Children[0]);
        for i := 1 to High(node.Children) do
        begin
          nextFrag := CompileNode(node.Children[i]);
          frag := Concat(frag, nextFrag);
        end;
        Result := frag;
      end;
    rnAlt:
      begin
        frag := CompileNode(node.Children[0]);
        for i := 1 to High(node.Children) do
        begin
          nextFrag := CompileNode(node.Children[i]);
          splitIdx := EmitSplit;
          FInstrs[splitIdx].X := frag.Start;
          FInstrs[splitIdx].Y := nextFrag.Start;
          frag := MakeFrag(splitIdx, AppendOuts(frag.Outs, nextFrag.Outs));
        end;
        Result := frag;
      end;
    rnRepeat:
      begin
        minCount := node.MinCount;
        maxCount := node.MaxCount;
        if (minCount = 0) and (maxCount = 0) then
        begin
          Result := EmitEmpty;
          Exit;
        end;
        if (minCount = 0) and (maxCount = 1) then
        begin
          frag := CompileNode(node.Children[0]);
          splitIdx := EmitSplit;
          FInstrs[splitIdx].X := frag.Start;
          Result := MakeFrag(splitIdx, AppendOuts(frag.Outs, SingleOut(splitIdx, 2)));
          Exit;
        end;
        if (minCount = 0) and (maxCount < 0) then
        begin
          frag := CompileNode(node.Children[0]);
          splitIdx := EmitSplit;
          FInstrs[splitIdx].X := frag.Start;
          Patch(frag.Outs, splitIdx);
          Result := MakeFrag(splitIdx, SingleOut(splitIdx, 2));
          Exit;
        end;
        if (minCount = 1) and (maxCount < 0) then
        begin
          frag := CompileNode(node.Children[0]);
          splitIdx := EmitSplit;
          FInstrs[splitIdx].X := frag.Start;
          Patch(frag.Outs, splitIdx);
          Result := MakeFrag(frag.Start, SingleOut(splitIdx, 2));
          Exit;
        end;
        baseFrag := EmitEmpty;
        for repeats := 1 to minCount do
        begin
          tempFrag := CompileNode(node.Children[0]);
          baseFrag := Concat(baseFrag, tempFrag);
        end;
        if maxCount < 0 then
        begin
          frag := CompileNode(node.Children[0]);
          splitIdx := EmitSplit;
          FInstrs[splitIdx].X := frag.Start;
          Patch(frag.Outs, splitIdx);
          optFrag := MakeFrag(splitIdx, SingleOut(splitIdx, 2));
          Result := Concat(baseFrag, optFrag);
          Exit;
        end;
        for repeats := 1 to (maxCount - minCount) do
        begin
          frag := CompileNode(node.Children[0]);
          splitIdx := EmitSplit;
          FInstrs[splitIdx].X := frag.Start;
          optFrag := MakeFrag(splitIdx, AppendOuts(frag.Outs, SingleOut(splitIdx, 2)));
          baseFrag := Concat(baseFrag, optFrag);
        end;
        Result := baseFrag;
      end;
    rnGroup:
      begin
        saveStart := EmitSave(node.GroupIndex * 2);
        frag := MakeFrag(saveStart, SingleOut(saveStart, 1));
        nextFrag := CompileNode(node.Children[0]);
        frag := Concat(frag, nextFrag);
        saveEnd := EmitSave(node.GroupIndex * 2 + 1);
        tempFrag := MakeFrag(saveEnd, SingleOut(saveEnd, 1));
        frag := Concat(frag, tempFrag);
        Result := frag;
      end;
  else
    Result := EmitEmpty;
  end;
end;

function TRegexCompiler.InstrSize(const instr: TRegexInstr): Integer;
begin
  case instr.Kind of
    riChar: Result := 1 + 4;
    riAny: Result := 1;
    riClass: Result := 1 + 4;
    riSplit: Result := 1 + 4 + 4;
    riJmp: Result := 1 + 4;
    riMatch: Result := 1;
    riSave: Result := 1 + 4;
    riBol: Result := 1;
    riEol: Result := 1;
  else
    Result := 1;
  end;
end;

function TRegexCompiler.Compile(root: TRegexNode; captureSlots: Integer): string;
var
  frag: TRegexFrag;
  matchIdx: Integer;
  buf: TByteBuffer;
  offsets: array of Integer;
  i: Integer;
  cur: Integer;
  instr: TRegexInstr;
  cls: TRegexClass;
  r: TRegexRange;
  base: Integer;
  p: PByte;
begin
  SetLength(FInstrs, 0);
  SetLength(FClasses, 0);
  frag := CompileNode(root);
  matchIdx := EmitMatch;
  Patch(frag.Outs, matchIdx);
  buf := TByteBuffer.Create;
  try
    buf.WriteU8(Ord('R'));
    buf.WriteU8(Ord('X'));
    buf.WriteU8(Ord('1'));
    buf.WriteU8(0);
    buf.WriteU32LE(Cardinal(captureSlots));
    buf.WriteU32LE(Cardinal(Length(FClasses)));
    buf.WriteU32LE(Cardinal(Length(FInstrs)));
    for i := 0 to High(FClasses) do
    begin
      cls := FClasses[i];
      if cls.Negated then
        buf.WriteU8(1)
      else
        buf.WriteU8(0);
      buf.WriteU32LE(Cardinal(Length(cls.Ranges)));
      for base := 0 to High(cls.Ranges) do
      begin
        r := cls.Ranges[base];
        buf.WriteU32LE(Cardinal(r.StartChar));
        buf.WriteU32LE(Cardinal(r.EndChar));
      end;
    end;
    SetLength(offsets, Length(FInstrs));
    cur := 0;
    for i := 0 to High(FInstrs) do
    begin
      offsets[i] := cur;
      cur := cur + InstrSize(FInstrs[i]);
    end;
    for i := 0 to High(FInstrs) do
    begin
      instr := FInstrs[i];
      case instr.Kind of
        riChar:
          begin
            buf.WriteU8(RX_OP_CHAR);
            buf.WriteU32LE(Cardinal(instr.CharVal));
          end;
        riAny:
          buf.WriteU8(RX_OP_ANY);
        riClass:
          begin
            buf.WriteU8(RX_OP_CLASS);
            buf.WriteU32LE(Cardinal(instr.ClassIndex));
          end;
        riSplit:
          begin
            buf.WriteU8(RX_OP_SPLIT);
            buf.WriteU32LE(Cardinal(offsets[instr.X]));
            buf.WriteU32LE(Cardinal(offsets[instr.Y]));
          end;
        riJmp:
          begin
            buf.WriteU8(RX_OP_JMP);
            buf.WriteU32LE(Cardinal(offsets[instr.X]));
          end;
        riMatch:
          buf.WriteU8(RX_OP_MATCH);
        riSave:
          begin
            buf.WriteU8(RX_OP_SAVE);
            buf.WriteU32LE(Cardinal(instr.Slot));
          end;
        riBol:
          buf.WriteU8(RX_OP_BOL);
        riEol:
          buf.WriteU8(RX_OP_EOL);
      end;
    end;
    SetLength(Result, buf.Size);
    p := buf.GetBuffer;
    if buf.Size > 0 then
      Move(p^, Result[1], buf.Size);
  finally
    buf.Free;
  end;
end;

{ TSema }

procedure TSema.PushScope;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  sl.Sorted := False;
  SetLength(FScopes, Length(FScopes) + 1);
  FScopes[High(FScopes)] := sl;
end;

procedure TSema.PopScope;
var
  sl: TStringList;
  i: Integer;
begin
  if Length(FScopes) = 0 then Exit;
  sl := FScopes[High(FScopes)];
  // free symbols
  for i := 0 to sl.Count - 1 do
    System.TObject(sl.Objects[i]).Free;
  sl.Free;
  SetLength(FScopes, Length(FScopes) - 1);
end;

procedure TSema.AddSymbolToCurrent(sym: TSymbol; span: TSourceSpan);
var
  cur: TStringList;
begin
  if Length(FScopes) = 0 then
  begin
    FDiag.Error('internal sema error: no scope', span);
    Exit;
  end;
  cur := FScopes[High(FScopes)];
  if cur.IndexOf(sym.Name) >= 0 then
  begin
    FDiag.Error('redeclaration of symbol: ' + sym.Name, span);
    sym.Free;
    Exit;
  end;
  cur.AddObject(sym.Name, System.TObject(sym));
end;

function TSema.ResolveSymbol(const name: string): TSymbol;
var
  i, idx: Integer;
  sl: TStringList;
begin
  Result := nil;
  for i := High(FScopes) downto 0 do
  begin
    sl := FScopes[i];
    idx := sl.IndexOf(name);
    if idx >= 0 then
    begin
      Result := TSymbol(sl.Objects[idx]);
      Exit;
    end;
  end;
end;

function TSema.ResolveSymbolLevel(const name: string): Integer;
var
  i, idx: Integer;
  sl: TStringList;
begin
  Result := -1;
  for i := High(FScopes) downto 0 do
  begin
    sl := FScopes[i];
    idx := sl.IndexOf(name);
    if idx >= 0 then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

procedure TSema.DeclareBuiltinFunctions;
var
  s: TSymbol;
begin
  // PrintStr(pchar) -> void
  s := TSymbol.Create('PrintStr');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // PrintInt(int64) -> void
  s := TSymbol.Create('PrintInt');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // PrintFloat(f64) -> void
  s := TSymbol.Create('PrintFloat');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atF64;
  AddSymbolToCurrent(s, NullSpan);

  // printf(pchar, ...) -> void (varargs) - libc function, keep lowercase
  s := TSymbol.Create('printf');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;  // at least 1 required (format string)
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  s.IsVarArgs := True;
  AddSymbolToCurrent(s, NullSpan);

  // exit(int64) -> void - libc function, keep lowercase
  s := TSymbol.Create('exit');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // === std.io: fd-basierte I/O via libc wrappers (v0.3.0) ===
  // open(path: pchar, flags: int32, mode: int32) -> int64 (fd or -1)
  s := TSymbol.Create('open');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // read(fd: int64, buf: pchar, len: int64) -> int64 (bytes read or -1)
  s := TSymbol.Create('read');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atInt64;
  s.ParamTypes[1] := atPChar;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);
  
  // read_raw(fd: int64, buf: int64, len: int64) -> int64 (bytes read or -1)
  // Same as read but accepts int64 for buffer address (for mmap'd buffers)
  s := TSymbol.Create('read_raw');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atInt64;
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // write(fd: int64, buf: pchar, len: int64) -> int64 (bytes written or -1)
  s := TSymbol.Create('write');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atInt64;
  s.ParamTypes[1] := atPChar;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // close(fd: int64) -> int32 (0 or -1)
  s := TSymbol.Create('close');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // === std.io: Weitere fd-basierte I/O (v0.3.1) ===
  // lseek(fd: int64, offset: int64, whence: int64) -> int64 (new position or -1)
  // whence: SEEK_SET=0, SEEK_CUR=1, SEEK_END=2
  s := TSymbol.Create('lseek');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atInt64;
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // unlink(path: pchar) -> int64 (0 or -1)
  s := TSymbol.Create('unlink');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // rename(oldpath: pchar, newpath: pchar) -> int64 (0 or -1)
  s := TSymbol.Create('rename');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // mkdir(path: pchar, mode: int64) -> int64 (0 or -1)
  s := TSymbol.Create('mkdir');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // rmdir(path: pchar) -> int64 (0 or -1)
  s := TSymbol.Create('rmdir');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

   // chmod(path: pchar, mode: int64) -> int64 (0 or -1)
   s := TSymbol.Create('chmod');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 2;
   SetLength(s.ParamTypes, 2);
   s.ParamTypes[0] := atPChar;
   s.ParamTypes[1] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // === Socket System Calls (for std.net) ===
   // sys_socket(domain: int64, type: int64, protocol: int64) -> int64
   s := TSymbol.Create('sys_socket');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 3;
   SetLength(s.ParamTypes, 3);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;
   s.ParamTypes[2] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // sys_bind(sockfd: int64, addr: Pointer, addrlen: int64) -> int64
   s := TSymbol.Create('sys_bind');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 3;
   SetLength(s.ParamTypes, 3);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;  // Pointer as int64
   s.ParamTypes[2] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // sys_listen(sockfd: int64, backlog: int64) -> int64
   s := TSymbol.Create('sys_listen');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 2;
   SetLength(s.ParamTypes, 2);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // sys_accept(sockfd: int64, addr: Pointer, addrlen: Pointer) -> int64
   s := TSymbol.Create('sys_accept');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 3;
   SetLength(s.ParamTypes, 3);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;  // Pointer as int64
   s.ParamTypes[2] := atInt64;  // Pointer as int64
   AddSymbolToCurrent(s, NullSpan);

   // sys_connect(sockfd: int64, addr: Pointer, addrlen: int64) -> int64
   s := TSymbol.Create('sys_connect');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 3;
   SetLength(s.ParamTypes, 3);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;  // Pointer as int64
   s.ParamTypes[2] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // sys_recvfrom(sockfd, buf, len, flags, src_addr, addrlen) -> int64
   s := TSymbol.Create('sys_recvfrom');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 6;
   SetLength(s.ParamTypes, 6);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;  // Pointer
   s.ParamTypes[2] := atInt64;
   s.ParamTypes[3] := atInt64;
   s.ParamTypes[4] := atInt64;  // Pointer
   s.ParamTypes[5] := atInt64;  // Pointer
   AddSymbolToCurrent(s, NullSpan);

   // sys_sendto(sockfd, buf, len, flags, dest_addr, addrlen) -> int64
   s := TSymbol.Create('sys_sendto');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 6;
   SetLength(s.ParamTypes, 6);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;  // Pointer
   s.ParamTypes[2] := atInt64;
   s.ParamTypes[3] := atInt64;
   s.ParamTypes[4] := atInt64;  // Pointer
   s.ParamTypes[5] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // sys_setsockopt(sockfd, level, optname, optval, optlen) -> int64
   s := TSymbol.Create('sys_setsockopt');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 5;
   SetLength(s.ParamTypes, 5);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;
   s.ParamTypes[2] := atInt64;
   s.ParamTypes[3] := atInt64;  // Pointer
   s.ParamTypes[4] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

   // sys_getsockopt(sockfd, level, optname, optval, optlen) -> int64
   s := TSymbol.Create('sys_getsockopt');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 5;
   SetLength(s.ParamTypes, 5);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;
   s.ParamTypes[2] := atInt64;
   s.ParamTypes[3] := atInt64;  // Pointer
   s.ParamTypes[4] := atInt64;  // Pointer
   AddSymbolToCurrent(s, NullSpan);

   // sys_fcntl(fd, cmd, arg) -> int64
   s := TSymbol.Create('sys_fcntl');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 3;
   SetLength(s.ParamTypes, 3);
   s.ParamTypes[0] := atInt64;
   s.ParamTypes[1] := atInt64;
   s.ParamTypes[2] := atInt64;
   AddSymbolToCurrent(s, NullSpan);

    // sys_shutdown(sockfd, how) -> int64
    s := TSymbol.Create('sys_shutdown');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 2;
    SetLength(s.ParamTypes, 2);
    s.ParamTypes[0] := atInt64;
    s.ParamTypes[1] := atInt64;
    AddSymbolToCurrent(s, NullSpan);

    // sys_read(fd, buf, count) -> int64
    s := TSymbol.Create('sys_read');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 3;
    SetLength(s.ParamTypes, 3);
    s.ParamTypes[0] := atInt64;
    s.ParamTypes[1] := atInt64;  // Pointer as int64
    s.ParamTypes[2] := atInt64;
    AddSymbolToCurrent(s, NullSpan);

    // sys_write(fd, buf, count) -> int64
    s := TSymbol.Create('sys_write');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 3;
    SetLength(s.ParamTypes, 3);
    s.ParamTypes[0] := atInt64;
    s.ParamTypes[1] := atInt64;  // Pointer as int64
    s.ParamTypes[2] := atInt64;
    AddSymbolToCurrent(s, NullSpan);

    // sys_close(fd) -> int64
    s := TSymbol.Create('sys_close');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 1;
    SetLength(s.ParamTypes, 1);
    s.ParamTypes[0] := atInt64;
    AddSymbolToCurrent(s, NullSpan);

    // mmap(addr, length, prot, flags, fd, offset) -> int64 (pointer)
   s := TSymbol.Create('mmap');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 6;
   SetLength(s.ParamTypes, 6);
   s.ParamTypes[0] := atInt64;  // addr (0 for let kernel choose)
   s.ParamTypes[1] := atInt64;  // length
   s.ParamTypes[2] := atInt64;  // prot
   s.ParamTypes[3] := atInt64;  // flags
   s.ParamTypes[4] := atInt64;  // fd (-1 for anonymous)
   s.ParamTypes[5] := atInt64;  // offset
   AddSymbolToCurrent(s, NullSpan);

   // munmap(addr, length) -> int64
   s := TSymbol.Create('munmap');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 2;
   SetLength(s.ParamTypes, 2);
   s.ParamTypes[0] := atInt64;  // addr
   s.ParamTypes[1] := atInt64;  // length
   AddSymbolToCurrent(s, NullSpan);

   // poke8(addr, value) - write byte to memory
   s := TSymbol.Create('poke8');
   s.Kind := symFunc;
   s.DeclType := atVoid;
   s.ParamCount := 2;
   SetLength(s.ParamTypes, 2);
   s.ParamTypes[0] := atInt64;  // addr
   s.ParamTypes[1] := atInt64;  // value (only low 8 bits used)
   AddSymbolToCurrent(s, NullSpan);

   // peek8(addr) -> int64 - read byte from memory
   s := TSymbol.Create('peek8');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 1;
   SetLength(s.ParamTypes, 1);
    s.ParamTypes[0] := atInt64;  // addr
    AddSymbolToCurrent(s, NullSpan);

    // poke16(addr, value) - write 16-bit word to memory
    s := TSymbol.Create('poke16');
    s.Kind := symFunc;
    s.DeclType := atVoid;
    s.ParamCount := 2;
    SetLength(s.ParamTypes, 2);
    s.ParamTypes[0] := atInt64;  // addr
    s.ParamTypes[1] := atInt64;  // value (only low 16 bits used)
    AddSymbolToCurrent(s, NullSpan);

    // peek16(addr) -> int64 - read 16-bit word from memory
    s := TSymbol.Create('peek16');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 1;
    SetLength(s.ParamTypes, 1);
    s.ParamTypes[0] := atInt64;  // addr
    AddSymbolToCurrent(s, NullSpan);

    // poke32(addr, value) - write 32-bit dword to memory
    s := TSymbol.Create('poke32');
    s.Kind := symFunc;
    s.DeclType := atVoid;
    s.ParamCount := 2;
    SetLength(s.ParamTypes, 2);
    s.ParamTypes[0] := atInt64;  // addr
    s.ParamTypes[1] := atInt64;  // value (only low 32 bits used)
    AddSymbolToCurrent(s, NullSpan);

    // peek32(addr) -> int64 - read 32-bit dword from memory
    s := TSymbol.Create('peek32');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 1;
    SetLength(s.ParamTypes, 1);
    s.ParamTypes[0] := atInt64;  // addr
    AddSymbolToCurrent(s, NullSpan);

    // poke64(addr, value) - write 64-bit qword to memory
    s := TSymbol.Create('poke64');
    s.Kind := symFunc;
    s.DeclType := atVoid;
    s.ParamCount := 2;
    SetLength(s.ParamTypes, 2);
    s.ParamTypes[0] := atInt64;  // addr
    s.ParamTypes[1] := atInt64;  // value (64-bit)
    AddSymbolToCurrent(s, NullSpan);

    // peek64(addr) -> int64 - read 64-bit qword from memory
    s := TSymbol.Create('peek64');
    s.Kind := symFunc;
    s.DeclType := atInt64;
    s.ParamCount := 1;
    SetLength(s.ParamTypes, 1);
    s.ParamTypes[0] := atInt64;  // addr
    AddSymbolToCurrent(s, NullSpan);

    // write_raw(fd, buf, len) -> int64 - write with int64 buffer address
   s := TSymbol.Create('write_raw');
   s.Kind := symFunc;
   s.DeclType := atInt64;
   s.ParamCount := 3;
   SetLength(s.ParamTypes, 3);
   s.ParamTypes[0] := atInt64;  // fd
   s.ParamTypes[1] := atInt64;  // buf (pointer as int64)
   s.ParamTypes[2] := atInt64;  // len
   AddSymbolToCurrent(s, NullSpan);

   // Buffer/runtime primitives for time formatter
  // buf_put_byte(buf: int64, idx: int64, b: int64) -> int64
  // buf kann entweder pchar oder int64 (Pointer) sein
  s := TSymbol.Create('buf_put_byte');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atInt64;  // Pointer als int64 oder pchar
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // buf_get_byte(buf: int64, idx: int64) -> int64
  // Liest ein Byte aus einem Speicherbereich (Pointer als int64)
  s := TSymbol.Create('buf_get_byte');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atInt64;  // Pointer als int64
  s.ParamTypes[1] := atInt64;  // Index
  AddSymbolToCurrent(s, NullSpan);

  // itoa_to_buf(val: int64, buf: pchar, idx: int64, buflen: int64, minWidth: int64, padZero: int64) -> int64
  s := TSymbol.Create('itoa_to_buf');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 6;
  SetLength(s.ParamTypes, 6);
  s.ParamTypes[0] := atInt64; // val
  s.ParamTypes[1] := atPChar; // buf
  s.ParamTypes[2] := atInt64; // idx
  s.ParamTypes[3] := atInt64; // buflen
  s.ParamTypes[4] := atInt64; // minWidth
  s.ParamTypes[5] := atInt64; // padZero
  AddSymbolToCurrent(s, NullSpan);

  // Dynamic array builtins
  // append(arrVar: array, val: int64) -> void  (alias: push)
  s := TSymbol.Create('append');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atDynArray; // dynamic array type
  s.ParamTypes[1] := atInt64; // value
  AddSymbolToCurrent(s, NullSpan);

  // push(arrVar: array, val: int64) -> void  (legacy name)
  s := TSymbol.Create('push');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atDynArray;
  s.ParamTypes[1] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // pop(arrVar: array) -> int64
  s := TSymbol.Create('pop');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atDynArray;
  AddSymbolToCurrent(s, NullSpan);

  // len(arrVar: array) -> int64
  s := TSymbol.Create('len');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atDynArray;
  AddSymbolToCurrent(s, NullSpan);

  // free(arrVar: array) -> void
  s := TSymbol.Create('free');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atDynArray;
  AddSymbolToCurrent(s, NullSpan);

  // Random() -> int64 (returns pseudo-random number 0..2^31-1)
  s := TSymbol.Create('Random');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 0;
  SetLength(s.ParamTypes, 0);
  AddSymbolToCurrent(s, NullSpan);

  // RandomSeed(seed: int64) -> void (sets the random seed)
  s := TSymbol.Create('RandomSeed');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // VerifyIntegrity() -> bool (aerospace-todo P0 #45)
  // Returns true if code integrity is verified (CRC32 match with .meta_safe section)
  s := TSymbol.Create('VerifyIntegrity');
  s.Kind := symFunc;
  s.DeclType := atBool;
  s.ParamCount := 0;
  AddSymbolToCurrent(s, NullSpan);

  // === std.regex: Regex support (v0.4.2) ===
  // RegexMatch(pattern: pchar, text: pchar) -> bool
  s := TSymbol.Create('RegexMatch');
  s.Kind := symFunc;
  s.DeclType := atBool;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;  // pattern
  s.ParamTypes[1] := atPChar;  // text
  AddSymbolToCurrent(s, NullSpan);

  // RegexSearch(pattern: pchar, text: pchar) -> int64 (position or -1)
  s := TSymbol.Create('RegexSearch');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;  // pattern
  s.ParamTypes[1] := atPChar;  // text
  AddSymbolToCurrent(s, NullSpan);

  // RegexReplace(pattern: pchar, text: pchar, replacement: pchar) -> int64 (count)
  s := TSymbol.Create('RegexReplace');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atPChar;  // pattern
  s.ParamTypes[1] := atPChar;  // text
  s.ParamTypes[2] := atPChar;  // replacement
  AddSymbolToCurrent(s, NullSpan);

  // === Debug: In-Situ Data Visualizer (Debugging 2.0) ===
  // Inspect(any) -> void
  // Gibt formatierte Debug-Informationen über eine Variable aus
  // Akzeptiert jeden Typ - spezielle Behandlung in CheckExpr
  s := TSymbol.Create('Inspect');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atUnresolved;  // Akzeptiert jeden Typ
  AddSymbolToCurrent(s, NullSpan);

  // === Dynamic growable strings (F2) ===
  // StrLen(s: pchar): int64 — null-scan strlen, works on literals
  s := TSymbol.Create('StrLen');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrCharAt(s: pchar, i: int64): int64 — byte at index (zero-extended)
  s := TSymbol.Create('StrCharAt');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // StrSetChar(s: pchar, i: int64, c: int64) — write byte at index
  s := TSymbol.Create('StrSetChar');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // StrNew(capacity: int64): pchar — mmap-alloc with 16-byte header, return data ptr
  s := TSymbol.Create('StrNew');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // StrFree(s: pchar) — munmap(s-16, *(s-16)+16)
  s := TSymbol.Create('StrFree');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrAppend(dest: pchar, src: pchar): pchar — append src to dest, return new ptr
  s := TSymbol.Create('StrAppend');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrFromInt(n: int64): pchar — int to decimal string
  s := TSymbol.Create('StrFromInt');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // === S1: String split primitives ===
  // StrFindChar(s: string, c: int64, from: int64): int64 — scan for char from offset; -1 if not found
  s := TSymbol.Create('StrFindChar');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // StrSub(s: string, start: int64, len: int64): string — extract substring (mmap'd)
  s := TSymbol.Create('StrSub');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atInt64;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // === S2: StringBuilder / concat ===
  // StrAppendStr(s: string, other: string): string — append another string
  s := TSymbol.Create('StrAppendStr');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrConcat(a: string, b: string): string — new string = a+b
  s := TSymbol.Create('StrConcat');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrCopy(s: string): string — deep copy
  s := TSymbol.Create('StrCopy');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // === S3: IntToStr alias ===
  s := TSymbol.Create('IntToStr');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // === S4: FileGetSize ===
  // FileGetSize(path: string): int64 — file size via open+lseek+close; -1 on error
  s := TSymbol.Create('FileGetSize');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // === S5: O(1) HashMap (string -> int64) via FNV-1a + open addressing ===
  // HashNew(cap: int64): string — allocate map with initial capacity cap (rounded to power-of-2)
  s := TSymbol.Create('HashNew');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // HashSet(map: string, key: string, val: int64)
  s := TSymbol.Create('HashSet');
  s.Kind := symFunc;
  s.DeclType := atVoid;
  s.ParamCount := 3;
  SetLength(s.ParamTypes, 3);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  s.ParamTypes[2] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // HashGet(map: string, key: string): int64 — returns 0 if not found
  s := TSymbol.Create('HashGet');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // HashHas(map: string, key: string): bool
  s := TSymbol.Create('HashHas');
  s.Kind := symFunc;
  s.DeclType := atBool;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // === S6: Argv access ===
  // GetArgC(): int64 — number of command-line arguments
  s := TSymbol.Create('GetArgC');
  s.Kind := symFunc;
  s.DeclType := atInt64;
  s.ParamCount := 0;
  SetLength(s.ParamTypes, 0);
  AddSymbolToCurrent(s, NullSpan);

  // GetArg(idx: int64): string — argv[idx] as pchar (static, no alloc)
  s := TSymbol.Create('GetArg');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 1;
  SetLength(s.ParamTypes, 1);
  s.ParamTypes[0] := atInt64;
  AddSymbolToCurrent(s, NullSpan);

  // GetArgV(): pchar — raw pointer to argv[0] (C argv array base)
  s := TSymbol.Create('GetArgV');
  s.Kind := symFunc;
  s.DeclType := atPChar;
  s.ParamCount := 0;
  SetLength(s.ParamTypes, 0);
  AddSymbolToCurrent(s, NullSpan);

  // === S7: String comparison ===
  // StrStartsWith(s: string, prefix: string): bool
  s := TSymbol.Create('StrStartsWith');
  s.Kind := symFunc;
  s.DeclType := atBool;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrEndsWith(s: string, suffix: string): bool
  s := TSymbol.Create('StrEndsWith');
  s.Kind := symFunc;
  s.DeclType := atBool;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

  // StrEquals(a: string, b: string): bool
  s := TSymbol.Create('StrEquals');
  s.Kind := symFunc;
  s.DeclType := atBool;
  s.ParamCount := 2;
  SetLength(s.ParamTypes, 2);
  s.ParamTypes[0] := atPChar;
  s.ParamTypes[1] := atPChar;
  AddSymbolToCurrent(s, NullSpan);

end;

procedure TSema.RegisterTObject;
{ Registriert TObject als implizite Basisklasse für alle Klassen.
  Wird vor der AST-Analyse aufgerufen, damit 'extends TObject' funktioniert. }
var
  tobj: TAstClassDecl;
  m: TAstFuncDecl;
  sym: TSymbol;
  j, k: Integer;
begin
  // TObject aus tobject.pas erstellen
  tobj := CreateTObjectClassDecl();
  
  // In FClassTypes registrieren
  if not Assigned(FClassTypes) then
  begin
    FClassTypes := TStringList.Create;
    FClassTypes.Sorted := False;
  end;
  FClassTypes.AddObject(TOBJECT_CLASSNAME, System.TObject(tobj));
  
  // Auch in FStructTypes registrieren (für einheitliche Lookup-Logik)
  if not Assigned(FStructTypes) then
  begin
    FStructTypes := TStringList.Create;
    FStructTypes.Sorted := False;
  end;
  FStructTypes.AddObject(TOBJECT_CLASSNAME, System.TObject(tobj));
  
  // Methoden als Symbole registrieren (wie bei normalen Klassen)
  for j := 0 to High(tobj.Methods) do
  begin
    m := tobj.Methods[j];
    
    sym := TSymbol.Create('_L_' + TOBJECT_CLASSNAME + '_' + m.Name);
    sym.Kind := symFunc;
    sym.DeclType := m.ReturnType;
    sym.ReturnTypeName := m.ReturnTypeName;
    
    // Instance method: first param is implicit self (pointer)
    sym.ParamCount := Length(m.Params) + 1;
    SetLength(sym.ParamTypes, sym.ParamCount);
    sym.ParamTypes[0] := atUnresolved; // self is a class pointer
    for k := 0 to High(m.Params) do
      sym.ParamTypes[k+1] := m.Params[k].ParamType;
    
    AddSymbolToCurrent(sym, NullSpan);
  end;
end;

function IsIntegerType(t: TAurumType): Boolean;
begin
  case t of
    atInt8, atInt16, atInt32, atInt64,
    atUInt8, atUInt16, atUInt32, atUInt64,
    atISize, atUSize: Result := True;
  else
    Result := False;
  end;
end;

function IsBoolType(t: TAurumType): Boolean;
begin
  Result := (t = atBool);
end;

function IsStringType(t: TAurumType): Boolean;
begin
  Result := (t = atPChar);
end;

function IsStructType(t: TAurumType): Boolean;
begin
  // Struct types are represented differently - check for user-defined types
  // For now, allow any non-primitive type (except void/bool)
  Result := (t = atTuple) or (t = atDynArray) or (t = atMap) or (t = atSet);
end;

function IsNumericType(t: TAurumType): Boolean;
begin
  Result := IsIntegerType(t) or (t in [atF32, atF64]);
end;

function TSema.TypeEqual(a, b: TAurumType): Boolean;
begin
  // exact match
  if a = b then Exit(True);
  // treat any integer widths as compatible for now
  if IsIntegerType(a) and IsIntegerType(b) then Exit(True);
  Result := False;
end;

function TSema.CheckExpr(expr: TAstExpr): TAurumType;
var
  ident: TAstIdent;
  bin: TAstBinOp;
  un: TAstUnaryOp;
  call: TAstCall;
  s: TSymbol;
  sSym: TSymbol;
  i, j, fi, baseIdx, fldOffset, idx, symLvl: Integer;
  lt, rt, ot, atype, srcType: TAurumType;
  qualifier: string;
  identName: string;
  fName: string;
  found: Boolean;
  fldType: TAurumType;
  fldVisibility: TVisibility;
  fldOwnerClass: TAstClassDecl;
  recv: TAstExpr;
  mName: string;
  mangledName: string;
  args: TAstExprList;
  cd: TAstClassDecl;
  newExpr: TAstNewExpr;
  castTypeName: string;
  targetClassName: string;
  compiledRegex: string;
  captureSlots: Integer;
  typeName: string;
  structIdx: Integer;
  sd: TAstStructDecl;
  nestedIdx, fj, nestedOffset: Integer;
  nestedSd: TAstStructDecl;
begin
  if expr = nil then
  begin
    Result := atUnresolved;
    Exit;
  end;
  case expr.Kind of
    nkIntLit: Result := atInt64;
    nkFloatLit: Result := atF64;
    nkStrLit: Result := atPChar;
    nkBoolLit: Result := atBool;
    nkCharLit: Result := atChar;
    nkRegexLit:
      begin
        // Compile-Time Regex-Parsing + Bytecode-Generierung
        Result := atPChar;
        if not CompileRegex(TAstRegexLit(expr).Pattern, expr.Span,
          compiledRegex, captureSlots) then
          Result := atUnresolved
        else
          TAstRegexLit(expr).SetCompiled(compiledRegex, captureSlots);
      end;
    nkFieldAccess:
      begin
        // resolve object expression first
        recv := TAstFieldAccess(expr).Obj;
        recv := RewriteExpr(recv);
        CheckExpr(recv);
        // Attempt to resolve field type statically for simple cases
        if recv is TAstIdent then
        begin
          ident := TAstIdent(recv);
          sSym := ResolveSymbol(ident.Name);
          if Assigned(sSym) then
          begin
            // Check for struct type
            if Assigned(sSym.StructDecl) then
            begin
              // lookup field in struct decl
              fName := TAstFieldAccess(expr).Field;
              found := False;
              fldType := atUnresolved;
              fldVisibility := visPublic; // Struct fields are always public
              fldOwnerClass := nil; // No class for structs
              for fi := 0 to High(sSym.StructDecl.Fields) do
              begin
                if sSym.StructDecl.Fields[fi].Name = fName then
                begin
                  found := True;
                  fldType := sSym.StructDecl.Fields[fi].FieldType;
                  Break;
                end;
              end;
               if not found then
                 FDiag.Error('unknown field ' + fName + ' in type ' + sSym.StructDecl.Name, expr.Span)
               else
               begin
                 // Struct fields are always accessible
                 Result := fldType;
                 // annotate AST node with offset + owner + type
                 if expr is TAstFieldAccess then
                 begin
                   TAstFieldAccess(expr).SetFieldOffset(sSym.StructDecl.FieldOffsets[fi]);
                   TAstFieldAccess(expr).SetOwnerName(sSym.StructDecl.Name);
                   TAstFieldAccess(expr).SetFieldType(fldType);
                 end;
               end;
               expr.ResolvedType := Result;
               Exit;
            end
            // Check for class type
            else if Assigned(sSym.ClassDecl) then
            begin
              // lookup field in class decl (and base classes)
              fName := TAstFieldAccess(expr).Field;
              found := False;
              fldType := atUnresolved;
              fldVisibility := visPublic;
              fldOwnerClass := sSym.ClassDecl;
              
              // Walk up the class hierarchy
              cd := sSym.ClassDecl;
              while Assigned(cd) do
              begin
                for fi := 0 to High(cd.Fields) do
                begin
                  if cd.Fields[fi].Name = fName then
                  begin
                    found := True;
                    fldType := cd.Fields[fi].FieldType;
                    fldVisibility := cd.Fields[fi].Visibility;
                    fldOwnerClass := cd;
                    // Calculate absolute field offset (base class size + local offset)
                    if cd = sSym.ClassDecl then
                      fldOffset := cd.FieldOffsets[fi]
                    else
                    begin
                      // Field from base class - offset is relative to base, no adjustment needed
                      fldOffset := cd.FieldOffsets[fi];
                    end;
                    Break;
                  end;
                end;
                if found then Break;
                
                // Check base class
                if cd.BaseClassName <> '' then
                begin
                  baseIdx := FClassTypes.IndexOf(cd.BaseClassName);
                  if baseIdx >= 0 then
                    cd := TAstClassDecl(FClassTypes.Objects[baseIdx])
                  else
                    cd := nil;
                end
                else
                  cd := nil;
              end;
              
              if not found then
                FDiag.Error('unknown field ' + fName + ' in class ' + sSym.ClassDecl.Name, expr.Span)
              else
              begin
                // Check visibility before allowing access
                CheckMemberAccess(fName, fldOwnerClass, fldVisibility, expr.Span);
                
                 Result := fldType;
                 // annotate AST node with offset + owner + type
                 if expr is TAstFieldAccess then
                 begin
                   TAstFieldAccess(expr).SetFieldOffset(fldOffset);
                   TAstFieldAccess(expr).SetOwnerName(sSym.ClassDecl.Name);
                   TAstFieldAccess(expr).SetFieldType(fldType);
                 end;
              end;
              expr.ResolvedType := Result;
              Exit;
            end;

            // Check if the resolved type of the expression is a struct (for parameters)
            // Use the symbol's DeclType - if it's atUnresolved, look up the type name from the symbol's name
            if Assigned(sSym) and (sSym.Kind = symVar) then
            begin
              // This is a variable/parameter - check if its DeclType is unresolved (struct)
              if sSym.DeclType = atUnresolved then
              begin
                // Try to look up the struct by the variable's type name
                if (sSym.TypeName <> '') and Assigned(FStructTypes) then
                begin
                  idx := FStructTypes.IndexOf(sSym.TypeName);
                  if idx >= 0 then
                  begin
                    // Found the struct - now look up the field
                    sd := TAstStructDecl(FStructTypes.Objects[idx]);
                    fName := TAstFieldAccess(expr).Field;
                    found := False;
                    for fi := 0 to High(sd.Fields) do
                    begin
                      if sd.Fields[fi].Name = fName then
                      begin
                        found := True;
                        fldType := sd.Fields[fi].FieldType;
                        Break;
                      end;
                    end;
                    if found then
                     begin
                       Result := fldType;
                       // annotate AST node with offset + owner + type
                       if expr is TAstFieldAccess then
                       begin
                         TAstFieldAccess(expr).SetFieldOffset(sd.FieldOffsets[fi]);
                         TAstFieldAccess(expr).SetOwnerName(sd.Name);
                         TAstFieldAccess(expr).SetFieldType(fldType);
                       end;
                      expr.ResolvedType := Result;
                      Exit;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
        
        // Handle nested field access: when recv is itself a field access or other expression
        // that resolves to a struct type
        if recv.ResolvedType = atUnresolved then
        begin
          // Try to find the struct type from the field access's OwnerName
          if (recv is TAstFieldAccess) and (TAstFieldAccess(recv).OwnerName <> '') then
          begin
            // recv is a field access - get its field type's struct name
            // The field itself might be a struct type
            // We need to look up what struct type the field 'x' in 'o.x' is
            idx := FStructTypes.IndexOf(TAstFieldAccess(recv).OwnerName);
            if idx >= 0 then
            begin
              sd := TAstStructDecl(FStructTypes.Objects[idx]);
              // Find the field that recv refers to
              for fi := 0 to High(sd.Fields) do
              begin
                if sd.Fields[fi].Name = TAstFieldAccess(recv).Field then
                begin
                  // Found the field - now check if it's a struct type
                  if sd.Fields[fi].FieldTypeName <> '' then
                  begin
                    // Look up the nested struct
                    nestedIdx := FStructTypes.IndexOf(sd.Fields[fi].FieldTypeName);
                    if nestedIdx >= 0 then
                    begin
                      nestedSd := TAstStructDecl(FStructTypes.Objects[nestedIdx]);
                      // Now look up our field in the nested struct
                      fName := TAstFieldAccess(expr).Field;
                      for fj := 0 to High(nestedSd.Fields) do
                      begin
                        if nestedSd.Fields[fj].Name = fName then
                        begin
                          fldType := nestedSd.Fields[fj].FieldType;
                          Result := fldType;
                          // Calculate nested offset: parent field offset + nested field offset
                          nestedOffset := sd.FieldOffsets[fi] + nestedSd.FieldOffsets[fj];
                          TAstFieldAccess(expr).SetFieldOffset(nestedOffset);
                          TAstFieldAccess(expr).SetOwnerName(nestedSd.Name);
                          TAstFieldAccess(expr).SetFieldType(fldType);
                          // Also update the parent field access to have correct type info
                          TAstFieldAccess(recv).SetFieldType(atUnresolved); // It's a struct, not primitive
                          expr.ResolvedType := Result;
                          Exit;
                        end;
                      end;
                      // Field not found in nested struct
                      FDiag.Error('unknown field ' + TAstFieldAccess(expr).Field + ' in type ' + nestedSd.Name, expr.Span);
                      Result := atUnresolved;
                      Exit;
                    end;
                  end;
                  Break;
                end;
              end;
            end;
          end;
        end;
        
        // fallback: unresolved
        Result := atUnresolved;
      end;
    nkIndexAccess:
      begin
        // resolve object and index
        ot := CheckExpr(TAstIndexAccess(expr).Obj);
        lt := CheckExpr(TAstIndexAccess(expr).Index);
        
        // Check if this is a Map access
        if ot = atMap then
        begin
          // Map access: map[key] -> value_type
          // Key must be hashable (integer, pchar, bool)
          if not (lt in [atInt64, atInt32, atInt16, atInt8,
                         atUInt64, atUInt32, atUInt16, atUInt8,
                         atPChar, atBool]) then
            FDiag.Error('Map key must be hashable type', TAstIndexAccess(expr).Index.Span);
          
          // For now, return int64 as default value type (no full generics yet)
          // In future: extract value type from the Map's generic parameters
          Result := atInt64;
          expr.ResolvedType := Result;
          Exit;
        end;
        
        // Check if this is a Set access (not allowed)
        if ot = atSet then
        begin
          FDiag.Error('Sets are not indexable, use "in" operator', expr.Span);
          Result := atUnresolved;
          Exit;
        end;
        
        // Array access
        if not IsIntegerType(lt) then
          FDiag.Error('array index must be integer', TAstIndexAccess(expr).Index.Span);
        
        // Check for pchar indexing (string character access)
        if (ot = atPChar) or (ot = atPCharNullable) then
        begin
          // pchar[index] returns int64 (character code)
          Result := atInt64;
          expr.ResolvedType := Result;
          Exit;
        end;
        
        // if indexing an identifier with array metadata, return element type
        if TAstIndexAccess(expr).Obj is TAstIdent then
        begin
          s := ResolveSymbol(TAstIdent(TAstIndexAccess(expr).Obj).Name);
          if Assigned(s) and ((s.ArrayLen <> 0) or (s.DeclType = atDynArray) or (s.DeclType = atArray)) then
          begin
            // For dynamic arrays, return atInt64 (default element type)
            if (s.ArrayLen = -1) or (s.DeclType = atDynArray) then
              Result := atInt64
            else if s.DeclType = atArray then
              Result := atInt64  // For static arrays, return int64 as element type
            else
              Result := s.DeclType;
            expr.ResolvedType := Result;
            Exit;
          end;
          // Check if the symbol is pchar type
          if Assigned(s) and ((s.DeclType = atPChar) or (s.DeclType = atPCharNullable)) then
          begin
            Result := atInt64;
            expr.ResolvedType := Result;
            Exit;
          end;
        end;
        // fallback: unresolved
        Result := atUnresolved;
      end;
    nkCast:
      begin
        // Type cast: expr as Type
        // Check the expression first
        CheckExpr(TAstCast(expr).Expr);
        srcType := TAstCast(expr).Expr.ResolvedType;

        // Resolve the target type from the type name
        castTypeName := TAstCast(expr).CastTypeName;
        
        // Special case: function to int64 cast (for function pointers)
        // This returns the function address, not the return value
        if (srcType = atFnPtr) and (castTypeName = 'int64') then
        begin
          TAstCast(expr).CastType := atInt64;
          TAstCast(expr).IsFunctionToPointer := True;  // Mark as function address cast
          Result := atInt64;
          expr.ResolvedType := Result;
          Exit;
        end;
        
        // Also check if we're casting a function identifier to int64
        if (castTypeName = 'int64') and Assigned(TAstCast(expr).Expr) and 
           (TAstCast(expr).Expr is TAstIdent) then
        begin
          // Check if the identifier refers to a function
          s := ResolveSymbol(TAstIdent(TAstCast(expr).Expr).Name);
          if Assigned(s) and (s.Kind = symFunc) then
          begin
            TAstCast(expr).CastType := atInt64;
            TAstCast(expr).IsFunctionToPointer := True;  // Mark as function address cast
            Result := atInt64;
            expr.ResolvedType := Result;
            Exit;
          end;
        end;
        
        if castTypeName <> '' then
        begin
          // Look up the type - support all integer and float types
          if castTypeName = 'int64' then
            TAstCast(expr).CastType := atInt64
          else if castTypeName = 'int32' then
            TAstCast(expr).CastType := atInt32
          else if castTypeName = 'int16' then
            TAstCast(expr).CastType := atInt16
          else if castTypeName = 'int8' then
            TAstCast(expr).CastType := atInt8
          else if castTypeName = 'uint64' then
            TAstCast(expr).CastType := atUInt64
          else if castTypeName = 'uint32' then
            TAstCast(expr).CastType := atUInt32
          else if castTypeName = 'uint16' then
            TAstCast(expr).CastType := atUInt16
          else if castTypeName = 'uint8' then
            TAstCast(expr).CastType := atUInt8
          else if castTypeName = 'f64' then
            TAstCast(expr).CastType := atF64
          else if castTypeName = 'f32' then
            TAstCast(expr).CastType := atF32
          else if castTypeName = 'bool' then
            TAstCast(expr).CastType := atBool
          else if castTypeName = 'char' then
            TAstCast(expr).CastType := atChar
          else if (castTypeName = 'pchar') or (castTypeName = 'string') then
            TAstCast(expr).CastType := atPChar
          else if FClassTypes.IndexOf(castTypeName) >= 0 then
          begin
            // Class cast - mark as class type
            // The actual runtime check will be done in IR/Backend
            TAstCast(expr).CastType := atUnresolved; // Will be resolved later
          end
          else
            FDiag.Error('unsupported cast type: ' + castTypeName, expr.Span);
        end;

        Result := TAstCast(expr).CastType;
        expr.ResolvedType := Result;
        Exit;
      end;
    nkIdent:
      begin
        ident := TAstIdent(expr);
        s := ResolveSymbol(ident.Name);
        if s = nil then
        begin
          FDiag.Error('use of undeclared identifier: ' + ident.Name, ident.Span);
          Result := atUnresolved;
        end
        else
        begin
          Result := s.DeclType;
          // Closure capture detection: if we're in a nested function and
          // the symbol comes from an outer scope, mark it as captured
          if Assigned(FCurrentNestedFunc) and (s.Kind in [symVar, symLet, symCon]) then
          begin
            symLvl := ResolveSymbolLevel(ident.Name);
            if (symLvl >= 0) and (symLvl < FFuncScopeDepth) then
            begin
              // Variable is from outer scope — add to captured vars
              FCurrentNestedFunc.AddCapturedVar(ident.Name, s.DeclType, symLvl);
            end;
          end;
        end;
      end;
    nkArrayLit:
      begin
        if Length(TAstArrayLit(expr).Items) = 0 then
        begin
          // empty array literal: treat as atDynArray for now
          TAstArrayLit(expr).ElemType := atUnresolved;
          Result := atDynArray;
        end
        else
        begin
          // Infer element type from first item
          TAstArrayLit(expr).ElemType := CheckExpr(TAstArrayLit(expr).Items[0]);
          
          // Check remaining elements for type consistency
          for i := 1 to High(TAstArrayLit(expr).Items) do
          begin
            ot := CheckExpr(TAstArrayLit(expr).Items[i]);
            if not TypeEqual(ot, TAstArrayLit(expr).ElemType) then
              FDiag.Error('array literal items must have same type', TAstArrayLit(expr).Items[i].Span);
          end;
          
          // Return atArray for static array literals
          Result := atArray;
        end;
      end;
    nkStructLit:
      begin
        // Struct literal: TypeName { field: value, ... }
        Result := CheckStructLit(TAstStructLit(expr));
      end;
    nkBinOp:
      begin
        bin := TAstBinOp(expr);
        // compute child types
        lt := CheckExpr(bin.Left);
        rt := CheckExpr(bin.Right);
        case bin.Op of
           tkPlus, tkMinus, tkStar, tkSlash, tkPercent:
             begin
               // String concatenation: pchar + pchar
               if (bin.Op = tkPlus) and TypeEqual(lt, atPChar) and TypeEqual(rt, atPChar) then
               begin
                 Result := atPChar;
               end
               // Pointer arithmetic: pchar + int64 = pchar
               else if (bin.Op = tkPlus) and TypeEqual(lt, atPChar) and IsIntegerType(rt) then
               begin
                 Result := atPChar;
               end
               // Pointer arithmetic: int64 + pchar = pchar
               else if (bin.Op = tkPlus) and IsIntegerType(lt) and TypeEqual(rt, atPChar) then
               begin
                 Result := atPChar;
               end
               // Check for float operands
               else if TypeEqual(lt, atF64) and TypeEqual(rt, atF64) then
               begin
                 // Float arithmetic
                 Result := atF64;
               end
               else if not IsIntegerType(lt) or not IsIntegerType(rt) then
               begin
                 FDiag.Error('type error: arithmetic requires numeric (integer or float) operands', bin.Span);
                 Result := atInt64;
               end
               else
               begin
                 // Integer arithmetic
                 // promote to 64-bit for now
                 Result := atInt64;
               end;
             end;
            tkEq, tkNeq, tkLt, tkLe, tkGt, tkGe:
              begin
                if (IsIntegerType(lt) and IsIntegerType(rt)) then
                begin
                  Result := atBool;
                end
                else if TypeEqual(lt, atF64) and TypeEqual(rt, atF64) then
                begin
                  // Float comparison
                  Result := atBool;
                end
                else if (TypeEqual(lt, atPChar) and TypeEqual(rt, atPChar)) then
                begin
                  // pointer/string comparison
                  Result := atBool;
                end
                else
                begin
                  FDiag.Error('type error: comparison requires numeric or pchar operands', bin.Span);
                  Result := atUnresolved;
                end;
              end;

           tkAnd, tkOr:
             begin
               if not TypeEqual(lt, atBool) or not TypeEqual(rt, atBool) then
                 FDiag.Error('type error: logical operators require bool operands', bin.Span);
               Result := atBool;
             end;
            tkBitAnd, tkBitOr, tkBitXor, tkShiftLeft, tkShiftRight:
              begin
                if not IsIntegerType(lt) or not IsIntegerType(rt) then
                begin
                  FDiag.Error('type error: bitwise operators require integer operands', bin.Span);
                  Result := atUnresolved;
                end
                else
                begin
                  // For now, result type is always int64 for bitwise ops
                  Result := atInt64;
                end;
              end;
           tkNullCoalesce:
             begin
               // x ?? y: if x is null, use y. Result type is the non-nullable version of left
               // Left must be nullable, right must be compatible
               if not IsNullableType(lt) then
                 FDiag.Error('type error: left operand of ?? must be nullable', bin.Span);
               // Das Ergebnis ist der non-nullable Typ
               Result := NonNullableVersion(lt);
             end;
         else
           begin
             FDiag.Error('unsupported binary operator in sema', bin.Span);
             Result := atUnresolved;
           end;
         end;
       end;
     nkUnaryOp:
       begin
         un := TAstUnaryOp(expr);
         ot := CheckExpr(un.Operand);
         if un.Op = tkMinus then
         begin
           if not IsIntegerType(ot) then
             FDiag.Error('type error: unary - requires integer', un.Span);
           Result := atInt64;
         end
         else if un.Op = tkNot then
         begin
           if not TypeEqual(ot, atBool) then
             FDiag.Error('type error: unary ! requires bool', un.Span);
           Result := atBool;
         end
         else if un.Op = tkBitNot then
         begin
           if not IsIntegerType(ot) then
             FDiag.Error('type error: bitwise NOT requires integer', un.Span);
           Result := atInt64;
         end
         else
           begin
             FDiag.Error('unsupported unary operator in sema', un.Span);
             Result := atUnresolved;
           end;
         end;
     nkCall:
      begin
        call := TAstCall(expr);
        s := nil; // Initialize to nil
        // rewrite nested args first (non-method calls too)
        for i := 0 to High(call.Args) do
          call.Args[i] := RewriteExpr(call.Args[i]);
        
        // Special-case: Inspect() - In-Situ Data Visualizer (Debugging 2.0)
        // Inspect akzeptiert jeden Typ und gibt void zurück
        if (call.Name = 'Inspect') or 
           ((call.Namespace = 'Debug') and (call.Name = 'Inspect')) then
        begin
          if Length(call.Args) <> 1 then
          begin
            FDiag.Error('Inspect() expects exactly 1 argument', call.Span);
            Result := atUnresolved;
            Exit;
          end;
          // Prüfe den Typ des Arguments - akzeptiere JEDEN Typ
          atype := CheckExpr(call.Args[0]);
          // Inspect gibt void zurück
          expr.ResolvedType := atVoid;
          Result := atVoid;
          Exit;
        end;
        
        // Special-case: method call desugared by parser to name '_METHOD_<method>'
        if (Length(call.Name) > 8) and (Copy(call.Name,1,8) = '_METHOD_') then
        begin
          mName := Copy(call.Name, 9, MaxInt);
          // receiver must be first arg
          if Length(call.Args) = 0 then
          begin
            FDiag.Error('method call without receiver', call.Span);
            Result := atUnresolved;
            Exit;
          end;
          recv := call.Args[0];
          sSym := nil;
          
          // Check if receiver is a type name (static method call)
          if recv is TAstIdent then
          begin
            sSym := ResolveSymbol(TAstIdent(recv).Name);
            // If not found as symbol, check if it's a struct type name
            if (sSym = nil) and Assigned(FStructTypes) then
            begin
              fi := FStructTypes.IndexOf(TAstIdent(recv).Name);
              if fi >= 0 then
              begin
                // Static method call: Type.method(args)
                mangledName := '_L_' + TAstIdent(recv).Name + '_' + mName;
                s := ResolveSymbol(mangledName);
                if s = nil then
                begin
                  FDiag.Error('call to undeclared static method: ' + mangledName, call.Span);
                  Result := atUnresolved;
                  Exit;
                end;
                // Rewrite call: remove the type name from args, just use the mangled name
                call.SetName(mangledName);
                // Remove the first argument (the type name identifier)
                if Length(call.Args) > 0 then
                begin
                  // Free the type name identifier (first arg)
                  call.Args[0].Free;
                  // Shift remaining args down
                  SetLength(args, Length(call.Args) - 1);
                  for i := 1 to High(call.Args) do
                    args[i-1] := call.Args[i];
                  // Replace args without freeing (we already freed the type name)
                  call.ReplaceArgs(args);
                end;
                // Continue with normal function call checking
                // s is already set to the static method symbol
              end;
            end;
            // Also check if it's a class type name (static method on class)
            if (sSym = nil) and (s = nil) and Assigned(FClassTypes) then
            begin
              fi := FClassTypes.IndexOf(TAstIdent(recv).Name);
              if fi >= 0 then
              begin
                // Static method call on class: ClassName.method(args)
                mangledName := '_L_' + TAstIdent(recv).Name + '_' + mName;
                s := ResolveSymbol(mangledName);
                if s = nil then
                begin
                  FDiag.Error('call to undeclared static method: ' + mangledName, call.Span);
                  Result := atUnresolved;
                  Exit;
                end;
                // Rewrite call: remove the type name from args, just use the mangled name
                call.SetName(mangledName);
                // Remove the first argument (the type name identifier)
                if Length(call.Args) > 0 then
                begin
                  // Free the type name identifier (first arg)
                  call.Args[0].Free;
                  // Shift remaining args down
                  SetLength(args, Length(call.Args) - 1);
                  for i := 1 to High(call.Args) do
                    args[i-1] := call.Args[i];
                  // Replace args without freeing (we already freed the type name)
                  call.ReplaceArgs(args);
                end;
              end;
            end;
          end;
          
          // Instance method call (receiver is a variable with struct type)
          if (s = nil) and Assigned(sSym) and Assigned(sSym.StructDecl) then
          begin
            mangledName := '_L_' + sSym.StructDecl.Name + '_' + mName;
            s := ResolveSymbol(mangledName);
            if s = nil then
            begin
              FDiag.Error('call to undeclared method: ' + mangledName, call.Span);
              Result := atUnresolved;
              Exit;
            end;
            // perform in-place rewrite of call node to point to mangled function
            call.SetName(mangledName);
            // no change to args (receiver stays as first param)
          end
          // Instance method call (receiver is a variable with class type)
          else if (s = nil) and Assigned(sSym) and Assigned(sSym.ClassDecl) then
          begin
            // Search the class hierarchy for the method definition
            cd := sSym.ClassDecl;
            mangledName := '';
            while Assigned(cd) do
            begin
              mangledName := '_L_' + cd.Name + '_' + mName;
              s := ResolveSymbol(mangledName);
              if s <> nil then Break;
              // Method not in this class, check base class
              if cd.BaseClassName = '' then Break;
              baseIdx := FClassTypes.IndexOf(cd.BaseClassName);
              if baseIdx < 0 then Break;
              cd := TAstClassDecl(FClassTypes.Objects[baseIdx]);
            end;
            if s = nil then
            begin
              FDiag.Error('call to undeclared method: ' + mName + ' in class ' + sSym.ClassDecl.Name, call.Span);
              Result := atUnresolved;
              Exit;
            end;
            // perform in-place rewrite of call node to point to mangled function
            call.SetName(mangledName);
            // no change to args (receiver stays as first param)
          end
          else if (s = nil) and Assigned(sSym) and (not Assigned(sSym.StructDecl)) and (not Assigned(sSym.ClassDecl)) then
          begin
            // sSym found but no type decl - this might be a class variable without ClassDecl set
            // Try to resolve using TypeName
            if (sSym.TypeName <> '') and Assigned(FClassTypes) then
            begin
              fi := FClassTypes.IndexOf(sSym.TypeName);
              if fi >= 0 then
              begin
                // Search the class hierarchy for the method definition
                cd := TAstClassDecl(FClassTypes.Objects[fi]);
                mangledName := '';
                while Assigned(cd) do
                begin
                  mangledName := '_L_' + cd.Name + '_' + mName;
                  s := ResolveSymbol(mangledName);
                  if s <> nil then Break;
                  // Method not in this class, check base class
                  if cd.BaseClassName = '' then Break;
                  baseIdx := FClassTypes.IndexOf(cd.BaseClassName);
                  if baseIdx < 0 then Break;
                  cd := TAstClassDecl(FClassTypes.Objects[baseIdx]);
                end;
                if s <> nil then
                begin
                  call.SetName(mangledName);
                  // Continue with normal function call checking
                end
                else
                begin
                  FDiag.Error('call to undeclared method: ' + mName + ' in class ' + sSym.TypeName, call.Span);
                  Result := atUnresolved;
                  Exit;
                end;
              end;
            end;
            
            if s = nil then
              FDiag.Error('internal error: variable ' + TAstIdent(recv).Name + ' has no type declaration', call.Span);
          end;
          
          if s = nil then
          begin
            FDiag.Error('cannot resolve method receiver type for ' + mName, call.Span);
            Result := atUnresolved;
            Exit;
          end;
        end
        else
        begin
          // Handle namespace-qualified calls (e.g., IO.PrintStr) or method calls (e.g., obj.Method)
          if call.Namespace <> '' then
          begin
            // Check if namespace is actually a variable (method call case)
            sSym := ResolveSymbol(call.Namespace);
            if Assigned(sSym) and (sSym.Kind in [symVar, symLet, symCon]) then
            begin
              // This is a method call: namespace is a variable, rewrite to _METHOD_ call
              mName := call.Name;
              // Create receiver expression
              recv := TAstIdent.Create(call.Namespace, call.Span);
              // Prepend receiver to args
              SetLength(args, Length(call.Args) + 1);
              args[0] := recv;
              for i := 0 to High(call.Args) do
                args[i + 1] := call.Args[i];
              // Rewrite call
              call.SetName('_METHOD_' + mName);
              call.Namespace := '';  // Clear namespace
              call.ReplaceArgs(args);
              // Now process as _METHOD_ call - recursive call
              Result := CheckExpr(call);
              Exit;
            end
            else
            begin
              // Qualified call: namespace.function
              s := ResolveQualifiedName(call.Namespace, call.Name, call.Span);
            end;
          end
          else
          begin
            // Regular call: try simple name first
            s := ResolveSymbol(call.Name);
            // Then try qualified name (for compatibility)
            if (s = nil) and (Pos('.', call.Name) > 0) then
            begin
              // Handle qualified name (e.g., 'module.function')
              qualifier := Copy(call.Name, 1, Pos('.', call.Name) - 1);
              identName := Copy(call.Name, Pos('.', call.Name) + 1, MaxInt);
              s := ResolveQualifiedName(qualifier, identName, call.Span);
            end;
          end;
        end;

        if s = nil then
        begin
          FDiag.Error('call to undeclared function: ' + call.Name, call.Span);
          Result := atUnresolved;
        end
        else if s.Kind <> symFunc then
        begin
          // Check if this is a function pointer call (variable with function type)
          // Function pointers are stored as atFnPtr or atInt64 (for compatibility)
          // Also handle the case where DeclType is unresolved but TypeName is set (type alias)
          if (s.Kind in [symVar, symLet]) and 
             ((s.DeclType = atFnPtr) or (s.DeclType = atInt64) or 
              ((s.DeclType = atUnresolved) and (s.TypeName <> ''))) then
          begin
            // This is a function pointer call - mark as indirect
            call.IsIndirectCall := True;
            
            // For now, function pointer calls return int64 as placeholder
            // TODO: Extract actual return type from function pointer type
            Result := atInt64;
            
            // We still need to check arguments - use param info from the function pointer type
            // For now, just check that args are valid expressions
            for i := 0 to High(call.Args) do
              CheckExpr(call.Args[i]);
          end
          else
          begin
            FDiag.Error('attempt to call non-function: ' + call.Name, call.Span);
            Result := atUnresolved;
          end;
        end
        else
        begin
          // Check argument count
          if s.IsVarArgs then
          begin
            // Varargs: require at least ParamCount arguments
            if Length(call.Args) < s.ParamCount then
              FDiag.Error(Format('wrong argument count for %s: expected at least %d, got %d', [call.Name, s.ParamCount, Length(call.Args)]), call.Span)
            else
            begin
              // For varargs, only check the fixed parameters
              for i := 0 to s.ParamCount - 1 do
              begin
                atype := CheckExpr(call.Args[i]);
                if (s.ParamTypes[i] <> atUnresolved) and (not TypeEqual(atype, s.ParamTypes[i])) then
                begin
                  // Spezifischere Fehlermeldung für nullable Typen
                  if IsNullableType(atype) and not IsNullableType(s.ParamTypes[i]) then
                    FDiag.Error(Format('argument %d of %s: nullable type %s cannot be used here, use ?? for null-coalescing', [i, call.Name, AurumTypeToStr(atype)]), call.Args[i].Span)
                  else
                    FDiag.Error(Format('argument %d of %s: expected %s but got %s', [i, call.Name, AurumTypeToStr(s.ParamTypes[i]), AurumTypeToStr(atype)]), call.Args[i].Span);
                end;
              end;
              // Check remaining args (varargs)
              for i := s.ParamCount to High(call.Args) do
                CheckExpr(call.Args[i]);
            end;
          end
          else
          begin
            // Non-varargs: exact match required
            if Length(call.Args) <> s.ParamCount then
              FDiag.Error(Format('wrong argument count for %s: expected %d, got %d', [call.Name, s.ParamCount, Length(call.Args)]), call.Span);
            for i := 0 to High(call.Args) do
            begin
              atype := CheckExpr(call.Args[i]);
              if (i < s.ParamCount) and (s.ParamTypes[i] <> atUnresolved) and (not TypeEqual(atype, s.ParamTypes[i])) then
              begin
                // Spezifischere Fehlermeldung für nullable Typen
                if IsNullableType(atype) and not IsNullableType(s.ParamTypes[i]) then
                  FDiag.Error(Format('argument %d of %s: nullable type %s cannot be used here, use ?? for null-coalescing', [i, call.Name, AurumTypeToStr(atype)]), call.Args[i].Span)
                else
                  FDiag.Error(Format('argument %d of %s: expected %s but got %s', [i, call.Name, AurumTypeToStr(s.ParamTypes[i]), AurumTypeToStr(atype)]), call.Args[i].Span);
              end;
            end;
          end;
          // For generic functions with TypeArgs, resolve the return type via substitution
          if (Length(call.TypeArgs) > 0) and (Length(s.GenericTypeParams) > 0) and
             (s.DeclType = atUnresolved) and (s.ReturnTypeName <> '') then
          begin
            // Find which type param corresponds to the return type name
            for j := 0 to High(s.GenericTypeParams) do
              if s.GenericTypeParams[j] = s.ReturnTypeName then
              begin
                if j < Length(call.TypeArgs) then
                begin
                  Result := call.TypeArgs[j];
                  Break;
                end;
              end;
          end
          else
            Result := s.DeclType;
        end;
      end;
    nkNewExpr:
      begin
        // new ClassName() or new ClassName(args) - returns a pointer to the class instance
        if not Assigned(FClassTypes) or (FClassTypes.IndexOf(TAstNewExpr(expr).ClassName) < 0) then
        begin
          FDiag.Error('unknown class type: ' + TAstNewExpr(expr).ClassName, expr.Span);
          Result := atUnresolved;
        end
        else
        begin
          // Check if trying to instantiate an abstract class
          idx := FClassTypes.IndexOf(TAstNewExpr(expr).ClassName);
          if idx >= 0 then
          begin
            cd := TAstClassDecl(FClassTypes.Objects[idx]);
            if cd.IsAbstract then
            begin
              FDiag.Error('cannot instantiate abstract class: ' + TAstNewExpr(expr).ClassName, expr.Span);
              Result := atUnresolved;
              Exit;
            end;
          end;
          // Check constructor arguments if any
          newExpr := TAstNewExpr(expr);
          if Length(newExpr.Args) > 0 then
          begin
            // Look for constructor method with matching arguments
            // Constructor is named 'new' or 'Create' in Lyx
            // Mangled as _L_<ClassName>_new or _L_<ClassName>_Create
            mangledName := '_L_' + newExpr.ClassName + '_new';
            s := ResolveSymbol(mangledName);
            if s = nil then
            begin
              // Try 'Create' variant
              mangledName := '_L_' + newExpr.ClassName + '_Create';
              s := ResolveSymbol(mangledName);
              if s <> nil then
                newExpr.ConstructorName := 'Create';
            end
            else
            begin
              newExpr.ConstructorName := 'new';
            end;
            if s = nil then
            begin
              FDiag.Error('class ' + newExpr.ClassName + ' has no constructor for new with arguments', expr.Span);
              Result := atUnresolved;
              Exit;
            end;
            // Check argument count (constructor has self as first param, so ParamCount - 1)
            if Length(newExpr.Args) <> s.ParamCount - 1 then
            begin
              FDiag.Error(Format('wrong argument count for %s constructor: expected %d, got %d', 
                [newExpr.ClassName, s.ParamCount - 1, Length(newExpr.Args)]), expr.Span);
            end;
            // Check argument types
            for i := 0 to High(newExpr.Args) do
            begin
              atype := CheckExpr(newExpr.Args[i]);
              if (i + 1 < s.ParamCount) and (s.ParamTypes[i + 1] <> atUnresolved) and (not TypeEqual(atype, s.ParamTypes[i + 1])) then
                FDiag.Error(Format('constructor argument %d: expected %s but got %s', 
                  [i + 1, AurumTypeToStr(s.ParamTypes[i + 1]), AurumTypeToStr(atype)]), newExpr.Args[i].Span);
            end;
          end;
          // Classes are reference types (pointers)
          Result := atUnresolved; // Named class type, resolved as pointer
        end;
      end;
    nkSuperCall:
      begin
        // super.method(args) - call to base class method
        // Requires FCurrentClass to be set
        if not Assigned(FCurrentClass) or (FCurrentClass.BaseClassName = '') then
        begin
          FDiag.Error('super call outside of derived class method', expr.Span);
          Result := atUnresolved;
        end
        else
        begin
          // Find base class and look up method
          i := FClassTypes.IndexOf(FCurrentClass.BaseClassName);
          if i < 0 then
          begin
            FDiag.Error('unknown base class: ' + FCurrentClass.BaseClassName, expr.Span);
            Result := atUnresolved;
          end
          else
          begin
            // Look up the method in base class and get its return type
            s := ResolveSymbol('_L_' + FCurrentClass.BaseClassName + '_' + TAstSuperCall(expr).MethodName);
            if s = nil then
            begin
              FDiag.Error('unknown super method: ' + TAstSuperCall(expr).MethodName, expr.Span);
              Result := atUnresolved;
            end
            else
            begin
              // Check arguments (first arg is self)
              for i := 0 to High(TAstSuperCall(expr).Args) do
                CheckExpr(TAstSuperCall(expr).Args[i]);
              Result := s.DeclType;
            end;
          end;
        end;
      end;
    nkPanic:
      begin
        // panic(message) - expression that never returns
        CheckExpr(TAstPanicExpr(expr).Message);
        // message must be pchar or string
        if not IsStringType(TAstPanicExpr(expr).Message.ResolvedType) then
          FDiag.Error('panic message must be a string', TAstPanicExpr(expr).Message.Span);
        // panic never returns, so we can assign any type
        Result := atVoid;
      end;
    nkCheck:
      begin
        // check(condition) - runtime-only assertion, panics if false
        CheckExpr(TAstCheckExpr(expr).Condition);
        // condition must be bool
        if not IsBoolType(TAstCheckExpr(expr).Condition.ResolvedType) then
          FDiag.Error('check condition must be boolean', TAstCheckExpr(expr).Condition.Span);
        // check never returns on false, so we can assign any type
        Result := atVoid;
      end;
    nkMapLit:
      begin
        // Map literal: {key: value, ...}
        // Check all key-value pairs and infer types
        if Length(TAstMapLit(expr).Entries) = 0 then
        begin
          // Empty map - type inference will be deferred to context
          TAstMapLit(expr).KeyType := atUnresolved;
          TAstMapLit(expr).ValueType := atUnresolved;
          Result := atMap;
        end
        else
        begin
          // Infer types from first entry
          TAstMapLit(expr).KeyType := CheckExpr(TAstMapLit(expr).Entries[0].Key);
          TAstMapLit(expr).ValueType := CheckExpr(TAstMapLit(expr).Entries[0].Value);
          
          // Validate key type (must be hashable: int64, pchar, bool)
          if not (TAstMapLit(expr).KeyType in [atInt64, atInt32, atInt16, atInt8,
                              atUInt64, atUInt32, atUInt16, atUInt8,
                              atPChar, atBool]) then
            FDiag.Error('Map key type must be hashable (integer, pchar, or bool)', TAstMapLit(expr).Entries[0].Key.Span);
          
          // Check remaining entries for type consistency
          for i := 1 to High(TAstMapLit(expr).Entries) do
          begin
            lt := CheckExpr(TAstMapLit(expr).Entries[i].Key);
            rt := CheckExpr(TAstMapLit(expr).Entries[i].Value);
            
            if not TypeEqual(lt, TAstMapLit(expr).KeyType) then
              FDiag.Error(Format('Map key type mismatch: expected %s but got %s',
                [AurumTypeToStr(TAstMapLit(expr).KeyType), AurumTypeToStr(lt)]), TAstMapLit(expr).Entries[i].Key.Span);
            
            if not TypeEqual(rt, TAstMapLit(expr).ValueType) then
              FDiag.Error(Format('Map value type mismatch: expected %s but got %s',
                [AurumTypeToStr(TAstMapLit(expr).ValueType), AurumTypeToStr(rt)]), TAstMapLit(expr).Entries[i].Value.Span);
          end;
          Result := atMap;
        end;
      end;
    nkSetLit:
      begin
        // Set literal: {value, value, ...}
        // Check all values and infer element type
        if Length(TAstSetLit(expr).Items) = 0 then
        begin
          // Empty set - type inference will be deferred to context
          TAstSetLit(expr).ElemType := atUnresolved;
          Result := atSet;
        end
        else
        begin
          // Infer type from first element
          TAstSetLit(expr).ElemType := CheckExpr(TAstSetLit(expr).Items[0]);
          
          // Validate element type (must be hashable: int64, pchar, bool)
          if not (TAstSetLit(expr).ElemType in [atInt64, atInt32, atInt16, atInt8,
                               atUInt64, atUInt32, atUInt16, atUInt8,
                               atPChar, atBool]) then
            FDiag.Error('Set element type must be hashable (integer, pchar, or bool)', TAstSetLit(expr).Items[0].Span);
          
          // Check remaining elements for type consistency
          for i := 1 to High(TAstSetLit(expr).Items) do
          begin
            lt := CheckExpr(TAstSetLit(expr).Items[i]);
            if not TypeEqual(lt, TAstSetLit(expr).ElemType) then
              FDiag.Error(Format('Set element type mismatch: expected %s but got %s',
                [AurumTypeToStr(TAstSetLit(expr).ElemType), AurumTypeToStr(lt)]), TAstSetLit(expr).Items[i].Span);
          end;
          Result := atSet;
        end;
      end;
    nkInExpr:
      begin
        // 'in' operator: key in container (Map or Set)
        // Returns bool
        lt := CheckExpr(TAstInExpr(expr).Key);
        rt := CheckExpr(TAstInExpr(expr).Container);
        
        // Container must be Map or Set
        if not (rt in [atMap, atSet]) then
        begin
          FDiag.Error('Right operand of ''in'' must be a Map or Set', TAstInExpr(expr).Container.Span);
          Result := atBool;
        end
        else
        begin
          // Type check key against container element/key type
          if rt = atMap then
          begin
            if TAstInExpr(expr).Container is TAstMapLit then
            begin
              ot := TAstMapLit(TAstInExpr(expr).Container).KeyType;
              if (ot <> atUnresolved) and not TypeEqual(lt, ot) then
                FDiag.Error(Format('Map contains key mismatch: expected %s but got %s',
                  [AurumTypeToStr(ot), AurumTypeToStr(lt)]), TAstInExpr(expr).Key.Span);
            end;
          end
          else // atSet
          begin
            if TAstInExpr(expr).Container is TAstSetLit then
            begin
              ot := TAstSetLit(TAstInExpr(expr).Container).ElemType;
              if (ot <> atUnresolved) and not TypeEqual(lt, ot) then
                FDiag.Error(Format('Set element mismatch: expected %s but got %s',
                  [AurumTypeToStr(ot), AurumTypeToStr(lt)]), TAstInExpr(expr).Key.Span);
            end;
          end;
          Result := atBool;
        end;
      end;
    nkIsExpr:
      begin
        // 'is' operator: expr is ClassName
        // Returns bool
        lt := CheckExpr(TAstIsExpr(expr).Expr);

        // The target class must be a known class
        targetClassName := TAstIsExpr(expr).ClassName;
        if FClassTypes.IndexOf(targetClassName) < 0 then
        begin
          FDiag.Error('Unknown class: ' + targetClassName, TAstIsExpr(expr).Span);
        end;
        Result := atBool;
      end;
    nkFormatExpr:
      begin
        lt := CheckExpr(TAstFormatExpr(expr).Expr);
        if not (TypeEqual(lt, atF64) or TypeEqual(lt, atF32)) then
          FDiag.Error('format specifier :width:decimals only valid for f32/f64', expr.Span);
        expr.ResolvedType := atPChar;
        Result := atPChar;
      end;
    nkTupleLit:
      begin
        // Tuple literal: (a, b) — check each element, return atTuple
        for i := 0 to High(TAstTupleLit(expr).Elems) do
          CheckExpr(TAstTupleLit(expr).Elems[i]);
        Result := atTuple;
      end;
  else
    begin
      FDiag.Error('sema: unsupported expr kind', expr.Span);
      Result := atUnresolved;
    end;
  end;
  expr.ResolvedType := Result;
end;

function TSema.CheckStructLit(sl: TAstStructLit): TAurumType;
var
  idx, i, fi: Integer;
  sd: TAstStructDecl;
  fieldName: string;
  fieldFound: Boolean;
  fieldType, valType: TAurumType;
  usedFields: array of Boolean;
begin
  Result := atUnresolved;
  
  // Lookup struct type by name
  if not Assigned(FStructTypes) then
  begin
    FDiag.Error('no struct types defined', sl.Span);
    Exit;
  end;
  
  idx := FStructTypes.IndexOf(sl.TypeName);
  if idx < 0 then
  begin
    FDiag.Error('unknown struct type: ' + sl.TypeName, sl.Span);
    Exit;
  end;
  
  sd := TAstStructDecl(FStructTypes.Objects[idx]);
  sl.SetStructDecl(sd);
  
  // Track which fields have been initialized
  SetLength(usedFields, Length(sd.Fields));
  for i := 0 to High(usedFields) do
    usedFields[i] := False;
  
  // Check each field initializer
  for i := 0 to High(sl.Fields) do
  begin
    fieldName := sl.Fields[i].Name;
    fieldFound := False;
    
    // Find field in struct
    for fi := 0 to High(sd.Fields) do
    begin
      if sd.Fields[fi].Name = fieldName then
      begin
        fieldFound := True;
        
        // Check for duplicate initialization
        if usedFields[fi] then
        begin
          FDiag.Error('duplicate field initializer: ' + fieldName, sl.Span);
          Continue;
        end;
        usedFields[fi] := True;
        
        // Check value type
        fieldType := sd.Fields[fi].FieldType;
        valType := CheckExpr(sl.Fields[i].Value);
        
        if (fieldType <> atUnresolved) and (not TypeEqual(valType, fieldType)) then
          FDiag.Error(Format('field %s: expected %s but got %s',
            [fieldName, AurumTypeToStr(fieldType), AurumTypeToStr(valType)]), sl.Fields[i].Value.Span);
        
        Break;
      end;
    end;
    
    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;
  
  // Note: We don't require all fields to be initialized - missing fields are zero-initialized
  
  Result := atUnresolved; // struct types use atUnresolved + TypeName
end;

procedure TSema.CheckStmt(stmt: TAstStmt);
var
  vd: TAstVarDecl;
  asg: TAstAssign;
  ifn: TAstIf;
  wh: TAstWhile;
  ret: TAstReturn;
  bs: TAstBlock;
  i, j: Integer;
  s: TSymbol;
  sym: TSymbol;
  fn: TAstFuncDecl;
  savedNestedFunc: TAstFuncDecl;
  savedScopeDepth: Integer;
  vtype, ctype, rtype, otype: TAurumType;
  sw: TAstSwitch;
  caseVal: TAstExpr;
  cvtype: TAurumType;
  // additional variables for pattern matching
  callExpr: TAstCall;
  bindName: string;
  bindType: TAurumType;
  // range type helpers (aerospace-todo P1 #7)
  rtIdx: Integer;
  rtDecl: TAstTypeDecl;
  litVal: Int64;
begin
  if stmt = nil then Exit;

  case stmt.Kind of
    nkVarDecl:
      begin
        vd := TAstVarDecl(stmt);
        // check init expr type (if present)
        if Assigned(vd.InitExpr) then
          vtype := CheckExpr(vd.InitExpr)
        else
          vtype := vd.DeclType;  // Use declared type if no initializer
        
        // Range type: compile-time bounds check for literal initializers (aerospace-todo P1 #7)
        if (vd.DeclType = atUnresolved) and (vd.DeclTypeName <> '') and
           Assigned(FRangeTypes) then
        begin
          rtIdx := FRangeTypes.IndexOf(vd.DeclTypeName);
          if rtIdx >= 0 then
          begin
            rtDecl := TAstTypeDecl(FRangeTypes.Objects[rtIdx]);
            // Accept the base integer type
            if not IsIntegerType(vtype) and (vtype <> atUnresolved) then
              FDiag.Error(Format('type mismatch in declaration of %s: expected integer (range %s), got %s',
                [vd.Name, vd.DeclTypeName, AurumTypeToStr(vtype)]), vd.Span);
            // Compile-time check for integer literals
            if Assigned(vd.InitExpr) and (vd.InitExpr is TAstIntLit) then
            begin
              litVal := TAstIntLit(vd.InitExpr).Value;
              if (litVal < rtDecl.RangeMin) or (litVal > rtDecl.RangeMax) then
                FDiag.Error(Format('value %d is out of range [%d..%d] for type %s',
                  [litVal, rtDecl.RangeMin, rtDecl.RangeMax, vd.DeclTypeName]), vd.Span);
            end;
            vtype := atInt64;
          end;
        end;
        // Resolve enum type names: var x: TokenKind := ... → treat as int64
        if (vd.DeclType = atUnresolved) and (vd.DeclTypeName <> '') and
           Assigned(FEnumTypes) and (FEnumTypes.IndexOf(vd.DeclTypeName) >= 0) then
        begin
          // Enum type: accept int64 values (enum values are int64 constants)
          if not (vtype in [atInt64, atUnresolved]) then
            FDiag.Error(Format('type mismatch in declaration of %s: expected enum %s (int64), got %s',
              [vd.Name, vd.DeclTypeName, AurumTypeToStr(vtype)]), vd.Span);
          vtype := atInt64;
        end
        // Special case: treat fn(...) types as int64 internally (opaque function pointer)
        // Also handle the case where DeclType is unresolved but DeclTypeName is set (type alias)
        else if (vd.DeclType = atFnPtr) or
           ((vd.DeclType = atUnresolved) and (vd.DeclTypeName <> '') and
            Assigned(vd.InitExpr) and (vd.InitExpr is TAstIdent)) then
        begin
          // Function pointer - keep as fn pointer type for proper resolution
          // Allow int64 as well for compatibility
          if (vtype = atInt64) then
            vtype := atInt64  // Keep int64 for int64 variables
          else if (vtype = atFnPtr) then
            vtype := atFnPtr  // Keep function pointer type
          else if (vd.DeclType <> atUnresolved) and TypeEqual(vtype, vd.DeclType) then
            vtype := atFnPtr  // Same fn type, use fn pointer
          else if Assigned(vd.InitExpr) and (vd.InitExpr is TAstIdent) then
          begin
            // Check if the initializer is a function name
            s := ResolveSymbol(TAstIdent(vd.InitExpr).Name);
            if Assigned(s) and (s.Kind = symFunc) then
              vtype := atFnPtr  // Function name as initializer -> function pointer
            else
              FDiag.Error(Format('type mismatch in declaration of %s: expected fn pointer but got %s', [vd.Name, AurumTypeToStr(vtype)]), vd.Span);
          end
          else
            FDiag.Error(Format('type mismatch in declaration of %s: expected fn pointer but got %s', [vd.Name, AurumTypeToStr(vtype)]), vd.Span);
        end
        else if (vd.DeclType <> atUnresolved) and (not TypeEqual(vtype, vd.DeclType)) then
        begin
          // Allow integer literal 0 to be assigned to nullable pointer types
          if (vtype = atInt64) and (vd.DeclType = atPCharNullable) and 
             Assigned(vd.InitExpr) and (vd.InitExpr is TAstIntLit) and 
             (TAstIntLit(vd.InitExpr).Value = 0) then
            vtype := atPCharNullable  // Treat 0 as null for nullable pointers
          // Special case: dynamic array (atDynArray) with empty literal or atDynArray init
          else if (vd.ArrayLen = -1) and ((vtype = atDynArray) or (vtype = atUnresolved)) then
            vtype := vd.DeclType  // Accept dynamic array type
          // Special case: dynamic array with array literal initializer
          else if (vd.ArrayLen = -1) and (vd.DeclType = atDynArray) and Assigned(vd.InitExpr) and (vd.InitExpr is TAstArrayLit) then
            vtype := vd.DeclType  // Accept array literal as dynamic array initializer
          // Special case: static array with array literal initializer
          // var arr: array := [10, 20, 30] where both DeclType and vtype are atArray
          else if (vd.DeclType = atArray) and (vtype = atArray) then
            vtype := atArray  // Accept array literal for unannotated array type
          else
            FDiag.Error(Format('type mismatch in declaration of %s: expected %s but got %s', [vd.Name, AurumTypeToStr(vd.DeclType), AurumTypeToStr(vtype)]), vd.Span);
        end;
        sym := TSymbol.Create(vd.Name);
        case vd.Storage of
          skVar: sym.Kind := symVar;
          skLet: sym.Kind := symLet;
          skCo:  sym.Kind := symCon;
          skCon: sym.Kind := symCon;
        else
          sym.Kind := symVar;
        end;
        if vd.DeclType = atUnresolved then
          sym.DeclType := vtype
        else
          sym.DeclType := vd.DeclType;
        // record named type if present
        sym.TypeName := vd.DeclTypeName;
        if (sym.TypeName <> '') then
        begin
          // Check for struct type
          if Assigned(FStructTypes) then
          begin
            i := FStructTypes.IndexOf(sym.TypeName);
            if i >= 0 then
            begin
              // Check if it's actually a class (stored in same map)
              if FStructTypes.Objects[i] is TAstClassDecl then
                sym.ClassDecl := TAstClassDecl(FStructTypes.Objects[i])
              else
                sym.StructDecl := TAstStructDecl(FStructTypes.Objects[i]);
            end;
          end;
          // Also check FClassTypes directly
          if (sym.ClassDecl = nil) and Assigned(FClassTypes) then
          begin
            i := FClassTypes.IndexOf(sym.TypeName);
            if i >= 0 then
              sym.ClassDecl := TAstClassDecl(FClassTypes.Objects[i]);
          end;
        end;
        // array length metadata - also check array literal initializer
        if vd.InitExpr is TAstArrayLit then
          sym.ArrayLen := Length(TAstArrayLit(vd.InitExpr).Items)
        else
          sym.ArrayLen := vd.ArrayLen;
        AddSymbolToCurrent(sym, vd.Span);
      end;
    nkAssign:
      begin
        asg := TAstAssign(stmt);
        s := ResolveSymbol(asg.Name);
        if s = nil then
        begin
          FDiag.Error('assignment to undeclared variable: ' + asg.Name, stmt.Span);
          Exit;
        end;
        if s.Kind = symLet then
        begin
          FDiag.Error('assignment to immutable variable: ' + asg.Name, stmt.Span);
        end;
        vtype := CheckExpr(asg.Value);
        if not TypeEqual(vtype, s.DeclType) then
          FDiag.Error(Format('assignment type mismatch: %s := %s', [AurumTypeToStr(s.DeclType), AurumTypeToStr(vtype)]), stmt.Span);
      end;
    nkFieldAssign:
      begin
        // field assignment: obj.field := value
        // CheckExpr on the target annotates FieldOffset etc.
        CheckExpr(TAstFieldAssign(stmt).Target);
        vtype := CheckExpr(TAstFieldAssign(stmt).Value);
        // type check: target field type vs value type (when available)
        // for now, just accept - full type inference will come later
      end;
    nkIndexAssign:
      begin
        // index assignment: arr[idx] := value
        // validate target (array/index access)
        CheckExpr(TAstIndexAssign(stmt).Target);
        // validate index is integer
        if not IsIntegerType(CheckExpr(TAstIndexAssign(stmt).Target.Index)) then
          FDiag.Error('array index must be integer', TAstIndexAssign(stmt).Target.Index.Span);
        // validate value
        vtype := CheckExpr(TAstIndexAssign(stmt).Value);
        // type check: element type vs value type
        // for now, just validate types are compatible
        if TAstIndexAssign(stmt).Target.Obj is TAstIdent then
        begin
          s := ResolveSymbol(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
          if Assigned(s) and ((s.ArrayLen <> 0) or (s.DeclType = atDynArray) or (s.DeclType = atArray)) then
          begin
            // Determine element type for the assignment
            if (s.ArrayLen = -1) or (s.DeclType = atDynArray) then
              otype := atInt64  // dynamic array: element type is int64
            else if s.DeclType = atArray then
              otype := atInt64  // static array: element type is int64 for now
            else
              otype := s.DeclType;
            if not TypeEqual(vtype, otype) then
              FDiag.Error(Format('index assignment type mismatch: expected %s but got %s',
                [AurumTypeToStr(otype), AurumTypeToStr(vtype)]), stmt.Span);
          end;
        end;
      end;
    nkExprStmt:
      begin
        CheckExpr(TAstExprStmt(stmt).Expr);
      end;
    nkIf:
      begin
        ifn := TAstIf(stmt);
        ctype := CheckExpr(ifn.Cond);
        if not TypeEqual(ctype, atBool) then
          FDiag.Error('if condition must be bool', ifn.Cond.Span);
        // then
        PushScope;
        CheckStmt(ifn.ThenBranch);
        PopScope;
        // else
        if Assigned(ifn.ElseBranch) then
        begin
          PushScope;
          CheckStmt(ifn.ElseBranch);
          PopScope;
        end;
      end;
    nkWhile:
      begin
        wh := TAstWhile(stmt);
        ctype := CheckExpr(wh.Cond);
        if not TypeEqual(ctype, atBool) then
          FDiag.Error('while condition must be bool', wh.Cond.Span);
        // Check limit expression if bounded
        if Assigned(wh.Limit) then
        begin
          vtype := CheckExpr(wh.Limit);
          if not IsIntegerType(vtype) then
            FDiag.Error('while limit must be integer', wh.Limit.Span);
        end;
        PushScope;
        CheckStmt(wh.Body);
        PopScope;
      end;
    nkFor:
      begin
        // for varName := startExpr to/downto endExpr do body
        with TAstFor(stmt) do
        begin
          vtype := CheckExpr(StartExpr);
          if not IsIntegerType(vtype) then
            FDiag.Error('for loop start must be integer', StartExpr.Span);
          ctype := CheckExpr(EndExpr);
          if not IsIntegerType(ctype) then
            FDiag.Error('for loop end must be integer', EndExpr.Span);
          // declare loop variable
          PushScope;
          sym := TSymbol.Create(VarName);
          sym.Kind := symVar;
          sym.DeclType := atInt64;
          AddSymbolToCurrent(sym, Span);
          CheckStmt(Body);
          PopScope;
        end;
      end;
    nkRepeatUntil:
      begin
        PushScope;
        CheckStmt(TAstRepeatUntil(stmt).Body);
        PopScope;
        ctype := CheckExpr(TAstRepeatUntil(stmt).Cond);
        if not TypeEqual(ctype, atBool) then
          FDiag.Error('repeat-until condition must be bool', TAstRepeatUntil(stmt).Cond.Span);
      end;
    nkPool:
      begin
        // pool { ... } - Memory Pool Block
        // Check that body is valid, no special semantics needed at parse time
        CheckStmt(TAstPoolStmt(stmt).Body);
      end;
    nkReturn:
      begin
        ret := TAstReturn(stmt);
        if Assigned(ret.Value) then
        begin
          rtype := CheckExpr(ret.Value);
          if not TypeEqual(rtype, FCurrentReturn) then
            FDiag.Error(Format('return type mismatch: expected %s but got %s', [AurumTypeToStr(FCurrentReturn), AurumTypeToStr(rtype)]), ret.Span);
        end
        else
        begin
          if not TypeEqual(FCurrentReturn, atVoid) then
            FDiag.Error('missing return value for non-void function', ret.Span);
        end;
      end;
    nkBreak:
      begin
        // break allowed in switch/while; semantic check for presence of enclosing loop/switch omitted for simplicity
        Exit;
      end;
    nkSwitch:
      begin
        // switch statement - also supports pattern matching for Result/Option
        sw := TAstSwitch(stmt);
        ctype := CheckExpr(sw.Expr);
        // Allow struct types when using pattern matching (Ok(v), Err(e))
        // Otherwise require integer type
        if not (IsIntegerType(ctype) or IsStructType(ctype)) then
          FDiag.Error('switch/match expression must be integer or struct type', sw.Expr.Span);
        // check cases
        for i := 0 to High(sw.Cases) do
        begin
          // case value - can be constant int OR pattern binding (Ok(v), Err(e))
          caseVal := sw.Cases[i].Value;
          // Check if this is a pattern binding
          if (caseVal is TAstCall) and TAstCall(caseVal).IsPatternBinding then
          begin
            // Pattern matching: Ok(v), Err(e), Some(x), None
            // Add pattern bindings to scope
            callExpr := TAstCall(caseVal);
            if Length(callExpr.Args) > 0 then
            begin
              // First arg should be identifier (the bound variable name)
              if callExpr.Args[0] is TAstIdent then
              begin
                bindName := TAstIdent(callExpr.Args[0]).Name;
                // Determine type based on pattern constructor
                if callExpr.Name = 'Ok' then
                  bindType := ctype  // Result type - will refine later
                else if callExpr.Name = 'Err' then
                  bindType := atInt64  // Error code
                else if callExpr.Name = 'Some' then
                  bindType := ctype
                else if callExpr.Name = 'None' then
                  bindType := atVoid
                else
                begin
                  // Unknown pattern, use the matched type
                  bindType := ctype;
                end;
                // Add binding to case object for later processing
                s := TSymbol.Create(bindName);
                s.Kind := symVar;
                s.DeclType := bindType;
                sw.Cases[i].AddBinding(bindName, TAstIdent.Create(bindName, callExpr.Span));
              end;
            end;
          end
          else
          begin
            // Traditional case: must be integer
            cvtype := CheckExpr(caseVal);
            if not IsIntegerType(cvtype) then
              FDiag.Error('case label must be integer', caseVal.Span);
            // Also check OR pattern extra values
            for j := 0 to High(sw.Cases[i].ExtraValues) do
            begin
              cvtype := CheckExpr(sw.Cases[i].ExtraValues[j]);
              if not IsIntegerType(cvtype) then
                FDiag.Error('case label must be integer', sw.Cases[i].ExtraValues[j].Span);
            end;
          end;
          // Push scope and register pattern bindings
          PushScope;
          for j := 0 to High(sw.Cases[i].Bindings) do
          begin
            s := TSymbol.Create(sw.Cases[i].Bindings[j]);
            s.Kind := symVar;
            s.DeclType := atInt64;  // Default to int64, will be refined
            AddSymbolToCurrent(s, sw.Cases[i].BindingExprs[j].Span);
          end;
          CheckStmt(sw.Cases[i].Body);
          PopScope;
        end;
        if Assigned(sw.Default) then
        begin
          PushScope;
          CheckStmt(sw.Default);
          PopScope;
        end;
      end;
    nkBlock:
      begin
        bs := TAstBlock(stmt);
        // block: introduce new scope
        PushScope;
        for i := 0 to High(bs.Stmts) do
          CheckStmt(bs.Stmts[i]);
        PopScope;
      end;
    nkDispose:
      begin
        // dispose expr; - free heap-allocated class instance
        // Just check the expression
        CheckExpr(TAstDispose(stmt).Expr);
      end;
    nkAssert:
      begin
        // assert(cond, msg); - runtime assertion
        CheckExpr(TAstAssert(stmt).Condition);
        CheckExpr(TAstAssert(stmt).Message);
        // condition must be bool
        if not IsBoolType(TAstAssert(stmt).Condition.ResolvedType) then
          FDiag.Error('assert condition must be boolean', TAstAssert(stmt).Condition.Span);
        // message must be pchar or string
        if not IsStringType(TAstAssert(stmt).Message.ResolvedType) then
          FDiag.Error('assert message must be a string', TAstAssert(stmt).Message.Span);
      end;
    nkFuncDecl:
      begin
        // Nested function — register name and analyze body for captures
        if stmt is TAstFuncStmt then
        begin
          fn := TAstFuncStmt(stmt).FuncDecl;
          // Set parent function name
          if Assigned(FCurrentNestedFunc) then
            fn.ParentFuncName := FCurrentNestedFunc.Name;
          // Register function name in current scope
          if ResolveSymbol(fn.Name) = nil then
          begin
            s := TSymbol.Create(fn.Name);
            s.Kind := symFunc;
            s.ParamCount := Length(fn.Params);
            SetLength(s.ParamTypes, s.ParamCount);
            for i := 0 to High(fn.Params) do
              s.ParamTypes[i] := fn.Params[i].ParamType;
            s.ReturnTypeName := fn.ReturnTypeName;
            s.DeclType := atInt64;
            AddSymbolToCurrent(s, stmt.Span);
          end;
          // Save nested func context and analyze body for captures
          savedNestedFunc := FCurrentNestedFunc;
          savedScopeDepth := FFuncScopeDepth;
          FCurrentNestedFunc := fn;
          FFuncScopeDepth := Length(FScopes);
          // Push scope for parameters
          PushScope;
          for i := 0 to High(fn.Params) do
          begin
            s := TSymbol.Create(fn.Params[i].Name);
            s.Kind := symVar;
            s.DeclType := fn.Params[i].ParamType;
            AddSymbolToCurrent(s, fn.Params[i].Span);
          end;
          // Analyze body (triggers capture detection in CheckExpr)
          if Assigned(fn.Body) then
            for i := 0 to High(fn.Body.Stmts) do
              CheckStmt(fn.Body.Stmts[i]);
          PopScope;
          // Restore context
          FCurrentNestedFunc := savedNestedFunc;
          FFuncScopeDepth := savedScopeDepth;
        end;
      end;
    nkTry:
      begin
        // try { body } catch (e: int64) { handler }
        with TAstTry(stmt) do
        begin
          PushScope;
          CheckStmt(TryBody);
          PopScope;
          // introduce catch variable as int64
          PushScope;
          sym := TSymbol.Create(CatchVar);
          sym.Kind := symVar;
          sym.DeclType := atInt64;
          AddSymbolToCurrent(sym, stmt.Span);
          CheckStmt(CatchBody);
          PopScope;
        end;
      end;
    nkThrow:
      begin
        // throw expr; — expr must be int64
        vtype := CheckExpr(TAstThrow(stmt).Value);
        if not IsIntegerType(vtype) then
          FDiag.Error('throw expression must be integer', TAstThrow(stmt).Value.Span);
      end;
    nkTupleVarDecl:
      begin
        // var a, b := f() — multi-return destructuring
        vtype := CheckExpr(TAstTupleVarDecl(stmt).InitExpr);
        // Register each name as int64 in scope
        for i := 0 to High(TAstTupleVarDecl(stmt).Names) do
        begin
          sym := TSymbol.Create(TAstTupleVarDecl(stmt).Names[i]);
          sym.Kind := symVar;
          sym.DeclType := atInt64;
          AddSymbolToCurrent(sym, stmt.Span);
        end;
      end;
    else
      FDiag.Error('sema: unsupported statement kind', stmt.Span);
  end;
end;

constructor TSema.Create(d: TDiagnostics; um: TUnitManager = nil);
begin
  inherited Create;
  FDiag := d;
  FUnitManager := um;
  FImportedUnits := TStringList.Create;
  FImportedUnits.Sorted := False;
  FStructTypes := TStringList.Create;
  FStructTypes.Sorted := False;
  FClassTypes := TStringList.Create;
  FClassTypes.Sorted := False;
  FEnumTypes := TStringList.Create;
  FEnumTypes.Sorted := False;
  FRangeTypes := TStringList.Create;
  FRangeTypes.Sorted := False;
  FCurrentClass := nil;
  FCurrentNestedFunc := nil;
  FFuncScopeDepth := 0;
  SetLength(FScopes, 0);
  // create global scope
  PushScope;
  DeclareBuiltinFunctions;
  // Register TObject as the implicit base class
  RegisterTObject;
  FCurrentReturn := atVoid;
end;

destructor TSema.Destroy;
var
  i: Integer;
begin
  // Nur das StringList freigeben, nicht die referenzierten Units
  // (die gehören dem UnitManager)
  if Assigned(FImportedUnits) then
    FImportedUnits.Free;
  
  // FClassTypes, FStructTypes, FEnumTypes nicht freigeben (sie halten AST-Referenzen)
  if Assigned(FClassTypes) then
    FClassTypes.Free;
  if Assigned(FStructTypes) then
    FStructTypes.Free;
  if Assigned(FEnumTypes) then
    FEnumTypes.Free;
  if Assigned(FRangeTypes) then
    FRangeTypes.Free;

  // Freigabe aller verbleibenden Scopes (insbesondere globaler Scope)
  while Length(FScopes) > 0 do
    PopScope;

  inherited Destroy;
end;

procedure TSema.ProcessImports(prog: TAstProgram);
{ Verarbeitet alle Import-Deklarationen im Programm }
var
  i: Integer;
  decl: TAstNode;
begin
  if not Assigned(prog) then Exit;
  
  for i := 0 to High(prog.Decls) do
  begin
    decl := prog.Decls[i];
    if decl is TAstImportDecl then
      ImportUnit(TAstImportDecl(decl));
  end;
end;

procedure TSema.ComputeStructLayouts;
var
  i, pass, changed, fldIdx: Integer;
  sd: TAstStructDecl;
  totalSize, maxAlign, off, fsize, falign: Integer;
  f: TStructField;
  ok: Boolean;
  idx: Integer;
  other: TAstStructDecl;
  nestedIdx: Integer;
  nestedField: TStructField;
  // helper
  function TypeSizeAndAlign(t: TAurumType; out asz, aalign: Integer): Boolean;
  begin
    case t of
      atInt8, atUInt8, atChar, atBool: asz := 1;
      atInt16, atUInt16: asz := 2;
      atInt32, atUInt32, atF32: asz := 4;
      atInt64, atUInt64, atISize, atUSize, atF64, atPChar: asz := 8;
      else
        begin
          asz := 0;
          aalign := 0;
          Exit(False);
        end;
    end;
    aalign := asz;
    Result := True;
  end;
begin
  if not Assigned(FStructTypes) then Exit;
  // iterative fixed-point: try to compute until no change
  pass := 0;
  repeat
    changed := 0;
    Inc(pass);
    for i := 0 to FStructTypes.Count - 1 do
    begin
      sd := TAstStructDecl(FStructTypes.Objects[i]);
      // skip if already computed
      if sd.Size <> 0 then Continue;
      // attempt compute
      totalSize := 0; maxAlign := 1;
      off := 0;
        ok := True;

      for fldIdx := 0 to High(sd.Fields) do
      begin
        f := sd.Fields[fldIdx];
        // Flat struct validation: no pointer fields allowed (aerospace-todo P2 #57)
        if sd.IsFlat and (f.FieldType <> atUnresolved) then
        begin
          if IsPointerType(f.FieldType) then
            FDiag.Error('flat struct ''' + sd.Name + ''' cannot have pointer field: ' + f.Name, sd.Span);
        end;
        // Bit-Level Mapping validation: at(N) requires @packed struct (aerospace-todo P2 #50)
        if f.BitOffset >= 0 then
        begin
          if not sd.IsPacked then
            FDiag.Error('bit-level mapping at(' + IntToStr(f.BitOffset) + ') requires @packed struct: ' + f.Name, sd.Span);
        end;
        // determine field size/alignment
        if f.FieldType <> atUnresolved then
        begin
          if not TypeSizeAndAlign(f.FieldType, fsize, falign) then begin ok := False; Break; end;
        end
        else if f.FieldTypeName <> '' then
        begin
            idx := FStructTypes.IndexOf(f.FieldTypeName);
            if idx >= 0 then
            begin
              other := TAstStructDecl(FStructTypes.Objects[idx]);
              if other.Size = 0 then begin ok := False; Break; end;
              fsize := other.Size;
              falign := other.Align;
              // Flat struct: nested struct must also be flat (aerospace-todo P2 #57)
              if sd.IsFlat and other.IsFlat then
              begin
                // Nested flat struct is OK — it has its own pointer check
              end
              else if sd.IsFlat and not other.IsFlat then
              begin
                // Check if nested struct has pointer fields
                for nestedIdx := 0 to High(other.Fields) do
                begin
                  nestedField := other.Fields[nestedIdx];
                  if IsPointerType(nestedField.FieldType) then
                    FDiag.Error('flat struct ''' + sd.Name + ''' cannot have non-flat nested struct field: ' + f.Name, sd.Span);
                end;
              end;
            end
            else if Assigned(FClassTypes) and (FClassTypes.IndexOf(f.FieldTypeName) >= 0) then
            begin
              // Class-typed field stored as pointer
              fsize  := 8;
              falign := 8;
            end
            else
            begin
              ok := False; Break;
            end;
        end
        else
        begin
          ok := False; Break;
        end;
        // align current offset
        if falign > maxAlign then maxAlign := falign;
        if (off mod falign) <> 0 then
          off := ((off + falign - 1) div falign) * falign;
        sd.FieldOffsets[fldIdx] := off;
        off := off + fsize;
      end;
        if ok then
        begin
          // final struct align = maxAlign, size rounded up
          sd.SetLayout(off, maxAlign);
          if (off mod sd.Align) <> 0 then
            off := ((off + sd.Align - 1) div sd.Align) * off;
          sd.SetLayout(off, sd.Align);
          Inc(changed);
        end;

    end;
  until (changed = 0) or (pass > 100);
  // if after iterations some structs remain with Size=0, report error
  for i := 0 to FStructTypes.Count - 1 do
  begin
    sd := TAstStructDecl(FStructTypes.Objects[i]);
    if sd.Size = 0 then
      FDiag.Error('cannot compute layout for struct: ' + sd.Name, sd.Span);
  end;
end;

{ --- Member Access Control --- }

procedure TSema.CheckMemberAccess(const memberName: string; memberClass: TAstClassDecl; visibility: TVisibility; span: TSourceSpan);
var
  currentClassName: string;
  inSubclass: Boolean;
  baseIdx: Integer;
  baseClass: TAstClassDecl;
begin
  // Public is always accessible
  if visibility = visPublic then
    Exit;
    
  // If no current class context, private/protected are not accessible
  if not Assigned(FCurrentClass) then
  begin
    case visibility of
      visPrivate:
        FDiag.Error(Format('private member %s cannot be accessed from outside the class', [memberName]), span);
      visProtected:
        FDiag.Error(Format('protected member %s cannot be accessed from outside the class or a subclass', [memberName]), span);
    end;
    Exit;
  end;
  
  currentClassName := FCurrentClass.Name;
  
  // Check access from same class
  if currentClassName = memberClass.Name then
    Exit; // Same class - all access allowed
    
  // For protected: check if current class is a subclass of member's class
  if visibility = visProtected then
  begin
    inSubclass := False;
    baseClass := FCurrentClass;
    while Assigned(baseClass) do
    begin
      if baseClass.Name = memberClass.Name then
      begin
        inSubclass := True;
        Break;
      end;
      if baseClass.BaseClassName <> '' then
      begin
        baseIdx := FClassTypes.IndexOf(baseClass.BaseClassName);
        if baseIdx >= 0 then
          baseClass := TAstClassDecl(FClassTypes.Objects[baseIdx])
        else
          baseClass := nil;
      end
      else
        baseClass := nil;
    end;
    
    if inSubclass then
      Exit; // Protected access allowed from subclass
  end;
  
  // All other cases: access denied
  case visibility of
    visPrivate:
      FDiag.Error(Format('private member %s of class %s cannot be accessed from class %s', 
        [memberName, memberClass.Name, currentClassName]), span);
    visProtected:
      FDiag.Error(Format('protected member %s of class %s cannot be accessed from class %s (not a subclass)', 
        [memberName, memberClass.Name, currentClassName]), span);
  end;
end;

procedure TSema.ComputeClassLayouts;
var
  i, pass, changed, fldIdx: Integer;
  cd: TAstClassDecl;
  baseCd: TAstClassDecl;
  baseIdx: Integer;
  totalSize, maxAlign, off, fsize, falign, baseSize: Integer;
  f: TStructField;
  ok: Boolean;
  // helper function
  function TypeSizeAndAlign(t: TAurumType; out asz, aalign: Integer): Boolean;
  begin
    case t of
      atInt8, atUInt8, atChar, atBool: asz := 1;
      atInt16, atUInt16: asz := 2;
      atInt32, atUInt32, atF32: asz := 4;
      atInt64, atUInt64, atISize, atUSize, atF64, atPChar: asz := 8;
    else
      begin
        asz := 0;
        aalign := 0;
        Exit(False);
      end;
    end;
    aalign := asz;
    Result := True;
  end;
begin
  if not Assigned(FClassTypes) then Exit;
  
  // Iterative fixed-point: compute layouts in dependency order
  pass := 0;
  repeat
    changed := 0;
    Inc(pass);
    for i := 0 to FClassTypes.Count - 1 do
    begin
      cd := TAstClassDecl(FClassTypes.Objects[i]);
      // Skip if already computed
      if cd.Size <> 0 then Continue;
      
      // Check base class
      baseSize := 8; // VMT pointer at offset 0 (all classes have VMT due to TObject)
      maxAlign := 8; // Pointer alignment for classes
      if cd.BaseClassName <> '' then
      begin
        baseIdx := FClassTypes.IndexOf(cd.BaseClassName);
        if baseIdx < 0 then
        begin
          FDiag.Error('unknown base class: ' + cd.BaseClassName, cd.Span);
          Continue;
        end;
        baseCd := TAstClassDecl(FClassTypes.Objects[baseIdx]);
        if baseCd.Size = 0 then
        begin
          // Base class not yet computed, try again later
          Continue;
        end;
        baseSize := baseCd.Size;  // Already includes VMT pointer
        if baseCd.Align > maxAlign then
          maxAlign := baseCd.Align;
      end;
      
      // Compute field offsets starting at baseSize (after VMT and inherited fields)
      off := baseSize;
      ok := True;
      
      for fldIdx := 0 to High(cd.Fields) do
      begin
        f := cd.Fields[fldIdx];
        // Determine field size/alignment
        if f.FieldType <> atUnresolved then
        begin
          if not TypeSizeAndAlign(f.FieldType, fsize, falign) then
          begin
            ok := False;
            Break;
          end;
        end
        else if f.FieldTypeName <> '' then
        begin
          // Look up named type (struct or class)
          baseIdx := FStructTypes.IndexOf(f.FieldTypeName);
          if baseIdx >= 0 then
          begin
            fsize := TAstStructDecl(FStructTypes.Objects[baseIdx]).Size;
            falign := TAstStructDecl(FStructTypes.Objects[baseIdx]).Align;
          end
          else if Assigned(FClassTypes) and (FClassTypes.IndexOf(f.FieldTypeName) >= 0) then
          begin
            // Class-typed field: stored as pointer (8 bytes)
            fsize  := 8;
            falign := 8;
          end
          else
          begin
            // Unknown type
            ok := False;
            Break;
          end;
        end
        else
        begin
          ok := False;
          Break;
        end;
        
        // Align current offset
        if falign > maxAlign then maxAlign := falign;
        if (off mod falign) <> 0 then
          off := ((off + falign - 1) div falign) * falign;
        cd.FieldOffsets[fldIdx] := off;
        off := off + fsize;
      end;
      
      if ok then
      begin
        // Classes are always pointer-sized (8 bytes) as values
        // But we track the full object size for allocation
        totalSize := off;
        // Minimum size of 8 bytes for empty classes (allows static-only classes)
        if totalSize = 0 then
        begin
          totalSize := 8;
          maxAlign := 8;
        end;
        if (totalSize mod maxAlign) <> 0 then
          totalSize := ((totalSize + maxAlign - 1) div maxAlign) * maxAlign;
        cd.SetLayout(totalSize, maxAlign, baseSize);
        Inc(changed);
      end;
    end;
  until (changed = 0) or (pass > 100);
  
  // Report errors for uncomputed classes (only if they have fields that couldn't be resolved)
  for i := 0 to FClassTypes.Count - 1 do
  begin
    cd := TAstClassDecl(FClassTypes.Objects[i]);
    // Size = 0 only happens if field types couldn't be resolved
    // Empty classes now get Size = 8 above
    if (cd.Size = 0) and (Length(cd.Fields) > 0) then
      FDiag.Error('cannot compute layout for class: ' + cd.Name, cd.Span);
  end;
end;

{ ResolveVMTForClasses - Build Virtual Method Tables for all classes }
procedure TSema.ResolveVMTForClasses;
var
  i, j, idx, vmtIdx: Integer;
  cd, baseCd: TAstClassDecl;
  method, baseMethod: TAstFuncDecl;
begin
  if not Assigned(FClassTypes) then Exit;

  // Process each class
  for i := 0 to FClassTypes.Count - 1 do
  begin
    cd := TAstClassDecl(FClassTypes.Objects[i]);

    // Validate virtual/override usage
    for j := 0 to High(cd.Methods) do
    begin
      method := cd.Methods[j];

      // Rule: static + virtual is not allowed
      if method.IsStatic and method.IsVirtual then
      begin
        FDiag.Error('static method cannot be virtual: ' + method.Name, method.Span);
        Continue;
      end;

      // Rule: override without base class is an error
      if method.IsOverride and (cd.BaseClassName = '') then
      begin
        FDiag.Error('override requires a base class: ' + method.Name, method.Span);
        Continue;
      end;

      // If override, check signature matches base class method
      if method.IsOverride and (cd.BaseClassName <> '') then
      begin
        idx := FClassTypes.IndexOf(cd.BaseClassName);
        if idx >= 0 then
        begin
          baseCd := TAstClassDecl(FClassTypes.Objects[idx]);
          baseMethod := nil;
          // Find matching method in base class
          for vmtIdx := 0 to High(baseCd.Methods) do
          begin
            if baseCd.Methods[vmtIdx].Name = method.Name then
            begin
              baseMethod := baseCd.Methods[vmtIdx];
              Break;
            end;
          end;

          if Assigned(baseMethod) then
          begin
            // Check parameter count
            if Length(method.Params) <> Length(baseMethod.Params) then
            begin
              FDiag.Error('override method has wrong parameter count: ' + method.Name, method.Span);
              Continue;
            end;

            // Check return type
            if method.ReturnType <> baseMethod.ReturnType then
            begin
              FDiag.Error('override method has wrong return type: ' + method.Name, method.Span);
              Continue;
            end;
          end
          else
          begin
            FDiag.Error('override method not found in base class: ' + method.Name, method.Span);
          end;
        end;
      end;

      // Validate constructor/destructor
      if method.IsConstructor then
      begin
        // Constructor must have void return type
        if method.ReturnType <> atVoid then
        begin
          FDiag.Error('constructor must not have a return type', method.Span);
        end;
        // Constructor cannot be virtual
        if method.IsVirtual then
        begin
          FDiag.Error('constructor cannot be virtual', method.Span);
        end;
        // Constructor cannot be static
        if method.IsStatic then
        begin
          FDiag.Error('constructor cannot be static', method.Span);
        end;
      end;

      if method.IsDestructor then
      begin
        // Destructor must have void return type
        if method.ReturnType <> atVoid then
        begin
          FDiag.Error('destructor must not have a return type', method.Span);
        end;
        // Destructor cannot be virtual
        if method.IsVirtual then
        begin
          FDiag.Error('destructor cannot be virtual', method.Span);
        end;
        // Destructor cannot be static
        if method.IsStatic then
        begin
          FDiag.Error('destructor cannot be static', method.Span);
        end;
      end;
    end;

    // Build VMT: collect virtual methods
    // For TObject (no base class) or classes with pre-set VirtualMethods, keep existing VMT
    // For other classes, build VMT from scratch
    if (cd.BaseClassName = '') and (Length(cd.VirtualMethods) > 0) then
    begin
      // TObject or similar: already has VirtualMethods set from CreateTObjectClassDecl
      // Just add any additional virtual methods from this class
      for j := 0 to High(cd.Methods) do
      begin
        method := cd.Methods[j];
        if method.IsVirtual and (method.VirtualTableIndex < 0) then
        begin
          vmtIdx := Length(cd.VirtualMethods);
          method.VirtualTableIndex := vmtIdx;
          cd.AddVirtualMethod(method);
        end;
      end;
      Continue;  // Skip the rest of VMT building for this class
    end;
    
    cd.VirtualMethods := nil;  // Reset using property for non-TObject classes

    // If there's a base class, inherit its VMT first
    if cd.BaseClassName <> '' then
    begin
      idx := FClassTypes.IndexOf(cd.BaseClassName);
      if idx >= 0 then
      begin
        baseCd := TAstClassDecl(FClassTypes.Objects[idx]);
        // Copy base VMT (inherited methods keep their indices)
        for vmtIdx := 0 to High(baseCd.VirtualMethods) do
        begin
          baseMethod := baseCd.VirtualMethods[vmtIdx];
          
          // Handle nil entries (abstract methods not yet implemented)
          if not Assigned(baseMethod) then
          begin
            // Keep nil in derived VMT - will be caught at runtime
            while Length(cd.VirtualMethods) <= vmtIdx do
              cd.AddVirtualMethod(nil);
            cd.VirtualMethods[vmtIdx] := nil;
            Continue;
          end;
          
          // Look for override in derived class
          method := nil;
          for j := 0 to High(cd.Methods) do
          begin
            if cd.Methods[j].Name = baseMethod.Name then
            begin
              method := cd.Methods[j];
              Break;
            end;
          end;

          // Check if we should override:
          // 1. method is explicitly marked as override, OR
          // 2. method exists in derived class and base is abstract (implementing abstract), OR
          // 3. method exists in derived class and is NOT virtual (shadows base)
          if Assigned(method) and 
             (method.IsOverride or (not method.IsVirtual) or baseMethod.IsAbstract) then
          begin
            // Check if signature matches
            if (method.ReturnType = baseMethod.ReturnType) and
               (Length(method.Params) = Length(baseMethod.Params)) then
            begin
              // Override: use derived class method, keep same VMT index
              method.VirtualTableIndex := vmtIdx;
              // Ensure VMT array is large enough
              while Length(cd.VirtualMethods) <= vmtIdx do
                cd.AddVirtualMethod(nil);
              cd.VirtualMethods[vmtIdx] := method;
            end
            else
            begin
              // Signature mismatch - error will be reported elsewhere
              // Inherit base method (may still be abstract)
              while Length(cd.VirtualMethods) <= vmtIdx do
                cd.AddVirtualMethod(nil);
              cd.VirtualMethods[vmtIdx] := baseMethod;
            end;
          end
          else
          begin
            // No override: inherit base method (keeps abstract status)
            while Length(cd.VirtualMethods) <= vmtIdx do
              cd.AddVirtualMethod(nil);
            cd.VirtualMethods[vmtIdx] := baseMethod;
          end;
        end;
      end;
    end;

    // Add new virtual methods from this class
    for j := 0 to High(cd.Methods) do
    begin
      method := cd.Methods[j];

      // Only add if virtual (or override) and not already in VMT
      if method.IsVirtual and (method.VirtualTableIndex < 0) then
      begin
        vmtIdx := Length(cd.VirtualMethods);
        method.VirtualTableIndex := vmtIdx;
        cd.AddVirtualMethod(method);
      end;
    end;

    // VMT pointer is already included in class size by ComputeClassLayouts
    // (all classes inherit from TObject which has virtual methods)
  end;
end;

procedure TSema.RegisterInheritedMethods;
{ Diese Prozedur ist jetzt leer - Methodensuche erfolgt dynamisch in CheckExpr.
  Die Vererbungskette wird bei Methodenaufrufen durchsucht, um die definierende 
  Klasse zu finden (z.B. _L_TMyClass_SetVal statt _L_TDerivedClass_SetVal). }
begin
  // Nichts zu tun - Methodenauflösung erfolgt dynamisch
end;

procedure TSema.ImportUnit(imp: TAstImportDecl);
{ Importiert eine Unit und registriert ihre Symbole }
var
  upath: string;
  loadedUnit: TLoadedUnit;
  alias: string;
  i, j, k: Integer;
  decl: TAstNode;
  fn: TAstFuncDecl;
  m: TAstFuncDecl;
  con: TAstConDecl;
  vd: TAstVarDecl;
  sym: TSymbol;
begin
  upath := imp.UnitPath;
  alias := imp.Alias;

  // Unit muss bereits vom UnitManager geladen sein
  if not Assigned(FUnitManager) then
  begin
    FDiag.Error('internal error: no unit manager', imp.Span);
    Exit;
  end;

  loadedUnit := FUnitManager.FindUnit(upath);
  if not Assigned(loadedUnit) then
  begin
    FDiag.Error('unit not loaded: ' + upath, imp.Span);
    Exit;
  end;

  // Registriere Alias für qualifizierte Zugriffe
  if alias = '' then
    alias := ExtractFileName(StringReplace(upath, '.', '/', [rfReplaceAll]));
  if not Assigned(FImportedUnits) then
    FImportedUnits := TStringList.Create;
  FImportedUnits.AddObject(alias, System.TObject(loadedUnit));
  
  // Importiere öffentliche Symbole (pub) in den globalen Scope
  if Assigned(loadedUnit.AST) then
  begin
    for i := 0 to High(loadedUnit.AST.Decls) do
    begin
      decl := loadedUnit.AST.Decls[i];
      
      // Öffentliche Funktionen importieren
      if decl is TAstFuncDecl then
      begin
        fn := TAstFuncDecl(decl);
        if not fn.IsPublic then
          Continue;

        // Prüfe auf Konflikte
        if ResolveSymbol(fn.Name) <> nil then
        begin
          FDiag.Error('import conflicts with existing symbol: ' + fn.Name, imp.Span);
          Continue;
        end;

        sym := TSymbol.Create(fn.Name);
        sym.Kind := symFunc;
        sym.DeclType := fn.ReturnType;
        sym.ReturnTypeName := fn.ReturnTypeName;
        sym.IsImported := True;
        sym.ParamCount := Length(fn.Params);
        SetLength(sym.ParamTypes, sym.ParamCount);
        for j := 0 to sym.ParamCount - 1 do
          sym.ParamTypes[j] := fn.Params[j].ParamType;
        AddSymbolToCurrent(sym, fn.Span);
      end
      // Öffentliche Konstanten importieren
      else if decl is TAstConDecl then
      begin
        con := TAstConDecl(decl);
        if not con.IsPublic then
          Continue;

        // Prüfe auf Konflikte
        if ResolveSymbol(con.Name) <> nil then
        begin
          FDiag.Error('import conflicts with existing symbol: ' + con.Name, imp.Span);
          Continue;
        end;

        sym := TSymbol.Create(con.Name);
        sym.Kind := symCon;
        sym.DeclType := con.DeclType;
        sym.IsImported := True;
        AddSymbolToCurrent(sym, con.Span);
      end
      // Öffentliche Enum-Typen importieren
      else if decl is TAstEnumDecl then
      begin
        if not TAstEnumDecl(decl).IsPublic then
          Continue;
        // Register the enum type name so it can be used as a variable type
        if TAstEnumDecl(decl).Name <> '<anon>' then
          if FEnumTypes.IndexOf(TAstEnumDecl(decl).Name) < 0 then
            FEnumTypes.Add(TAstEnumDecl(decl).Name);
        for j := 0 to High(TAstEnumDecl(decl).Values) do
        begin
          if ResolveSymbol(TAstEnumDecl(decl).Values[j].Name) <> nil then
            Continue;
          sym := TSymbol.Create(TAstEnumDecl(decl).Values[j].Name);
          sym.Kind := symCon;
          sym.DeclType := atInt64;
          sym.IsImported := True;
          AddSymbolToCurrent(sym, decl.Span);
        end;
      end
      // Öffentliche globale Variablen importieren (pub var / pub let)
      else if decl is TAstVarDecl then
      begin
        vd := TAstVarDecl(decl);
        if not vd.IsPublic then
          Continue;

        // Prüfe auf Konflikte
        if ResolveSymbol(vd.Name) <> nil then
        begin
          FDiag.Error('import conflicts with existing symbol: ' + vd.Name, imp.Span);
          Continue;
        end;

        sym := TSymbol.Create(vd.Name);
        case vd.Storage of
          skVar: sym.Kind := symVar;
          skLet: sym.Kind := symLet;
        else
          sym.Kind := symVar;
        end;
        sym.DeclType := vd.DeclType;
        sym.TypeName := vd.DeclTypeName;
        sym.ArrayLen := vd.ArrayLen;
        sym.IsImported := True;
        sym.IsGlobal := True;
        AddSymbolToCurrent(sym, vd.Span);
      end
      // Also import public struct types
      else if decl is TAstStructDecl then
      begin
        // Import struct type into FStructTypes for field resolution
        // But avoid duplicates - only import if not already present
        if not Assigned(FStructTypes) then
        begin
          FStructTypes := TStringList.Create;
          FStructTypes.Sorted := False;
        end;
        if FStructTypes.IndexOf(TAstStructDecl(decl).Name) < 0 then
        begin
          FStructTypes.AddObject(TAstStructDecl(decl).Name, System.TObject(decl));
        end;
      end
      // Also import public class types
      else if decl is TAstClassDecl then
      begin
        // Import class type into FClassTypes for field resolution
        if not Assigned(FClassTypes) then
        begin
          FClassTypes := TStringList.Create;
          FClassTypes.Sorted := False;
        end;
        if FClassTypes.IndexOf(TAstClassDecl(decl).Name) < 0 then
        begin
          FClassTypes.AddObject(TAstClassDecl(decl).Name, System.TObject(decl));
        end;
        // Also register mangled method symbols so calls like sb.Init() resolve
        for j := 0 to High(TAstClassDecl(decl).Methods) do
        begin
          m := TAstClassDecl(decl).Methods[j];
          sym := TSymbol.Create('_L_' + TAstClassDecl(decl).Name + '_' + m.Name);
          if ResolveSymbol(sym.Name) <> nil then
          begin
            sym.Free;
            Continue;
          end;
          sym.Kind := symFunc;
          sym.DeclType := m.ReturnType;
          sym.ReturnTypeName := m.ReturnTypeName;
          sym.IsImported := True;
          sym.ParamCount := Length(m.Params) + 1; // +1 for implicit self
          SetLength(sym.ParamTypes, sym.ParamCount);
          sym.ParamTypes[0] := atUnresolved; // self pointer
          for k := 0 to High(m.Params) do
            sym.ParamTypes[k+1] := m.Params[k].ParamType;
          AddSymbolToCurrent(sym, m.Span);
        end;
      end;
    end;
  end;
end;

function TSema.ResolveQualifiedName(const qualifier, name: string; span: TSourceSpan): TSymbol;
{ Löst einen qualifizierten Namen (z.B. "io.print") auf }
var
  idx: Integer;
  loadedUnit: TLoadedUnit;
  i, j: Integer;
  decl: TAstNode;
  fn: TAstFuncDecl;
  existingSymbol: TSymbol;
begin
  Result := nil;
  
  // First check if symbol already exists in current scope to avoid
  // creating duplicate symbols and Use-After-Free bugs
  existingSymbol := ResolveSymbol(name);
  if existingSymbol <> nil then
  begin
    Result := existingSymbol;
    Exit;
  end;
  
  // === Builtin Namespaces ===
  // Handle builtin namespaces like IO, OS, etc.
  if qualifier = 'IO' then
  begin
    // IO.* functions
    if name = 'PrintStr' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atVoid;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'PrintInt' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atVoid;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'Println' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atVoid;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'printf' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atVoid;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atPChar;
      Result.IsVarArgs := True;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'open' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atInt64;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'read' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atInt64;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'write' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atInt64;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'close' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'lseek' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atInt64;
      Result.ParamTypes[1] := atInt64;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'unlink' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'rename' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 2;
      SetLength(Result.ParamTypes, 2);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'mkdir' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 2;
      SetLength(Result.ParamTypes, 2);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'rmdir' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'chmod' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 2;
      SetLength(Result.ParamTypes, 2);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'ioctl' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atInt64;  // fd
      Result.ParamTypes[1] := atInt64;  // request
      Result.ParamTypes[2] := atInt64;  // argp (pointer as int64)
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'mmap' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;  // returns pointer as int64
      Result.ParamCount := 6;
      SetLength(Result.ParamTypes, 6);
      Result.ParamTypes[0] := atInt64;  // addr
      Result.ParamTypes[1] := atInt64;  // length
      Result.ParamTypes[2] := atInt64;  // prot
      Result.ParamTypes[3] := atInt64;  // flags
      Result.ParamTypes[4] := atInt64;  // fd
      Result.ParamTypes[5] := atInt64;  // offset
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'munmap' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 2;
      SetLength(Result.ParamTypes, 2);
      Result.ParamTypes[0] := atInt64;  // addr
      Result.ParamTypes[1] := atInt64;  // length
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else
    begin
      FDiag.Error('unknown builtin in IO: ' + name, span);
      Exit;
    end;
  end
  else if qualifier = 'OS' then
  begin
    // OS.* functions
    if name = 'exit' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atVoid;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'getpid' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 0;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else
    begin
      FDiag.Error('unknown builtin in OS: ' + name, span);
      Exit;
    end;
  end
  else if qualifier = 'Math' then
  begin
    // Math.* functions
    if name = 'Random' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 0;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'RandomSeed' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atVoid;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else
    begin
      FDiag.Error('unknown builtin in Math: ' + name, span);
      Exit;
    end;
  end
  else if qualifier = 'Integrity' then
  begin
    // Integrity.* functions (aerospace-todo P0 #45)
    if name = 'VerifyIntegrity' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atBool;
      Result.ParamCount := 0;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else
    begin
      FDiag.Error('unknown builtin in Integrity: ' + name, span);
      Exit;
    end;
  end
  else if qualifier = 'Regex' then
  begin
    // Regex.* functions
    if name = 'Match' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atBool;
      Result.ParamCount := 2;
      SetLength(Result.ParamTypes, 2);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'Search' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 2;
      SetLength(Result.ParamTypes, 2);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'Replace' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atPChar;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'MatchEx' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atBool;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'SearchEx' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'ReplaceEx' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 4;
      SetLength(Result.ParamTypes, 4);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atPChar;
      Result.ParamTypes[3] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'CaptureCount' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 0;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'CaptureStart' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'CaptureEnd' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atInt64;
      Result.ParamCount := 1;
      SetLength(Result.ParamTypes, 1);
      Result.ParamTypes[0] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else if name = 'CaptureText' then
    begin
      Result := TSymbol.Create(name);
      Result.Kind := symFunc;
      Result.DeclType := atPChar;
      Result.ParamCount := 3;
      SetLength(Result.ParamTypes, 3);
      Result.ParamTypes[0] := atPChar;
      Result.ParamTypes[1] := atPChar;
      Result.ParamTypes[2] := atInt64;
      AddSymbolToCurrent(Result, span);
      Exit;
    end
    else
    begin
      FDiag.Error('unknown builtin in Regex: ' + name, span);
      Exit;
    end;
  end
  else if qualifier = 'String' then
  begin
    // String.* functions (placeholder for future)
    FDiag.Error('String module not yet implemented', span);
    Exit;
  end;
  
  // === Imported Units ===
  
  // Finde Unit mit diesem Alias
  idx := FImportedUnits.IndexOf(qualifier);
  if idx < 0 then
  begin
    FDiag.Error('unknown module alias: ' + qualifier, span);
    Exit;
  end;
  
  loadedUnit := TLoadedUnit(FImportedUnits.Objects[idx]);
  if not Assigned(loadedUnit.AST) then
  begin
    FDiag.Error('unit has no AST: ' + qualifier, span);
    Exit;
  end;
  
  // Suche Symbol in der Unit
  for i := 0 to High(loadedUnit.AST.Decls) do
  begin
    decl := loadedUnit.AST.Decls[i];
    if decl is TAstFuncDecl then
    begin
      fn := TAstFuncDecl(decl);
      if fn.Name = name then
      begin
        Result := TSymbol.Create(name);
        Result.Kind := symFunc;
        Result.DeclType := fn.ReturnType;
        Result.ParamCount := Length(fn.Params);
        SetLength(Result.ParamTypes, Result.ParamCount);
        for j := 0 to Result.ParamCount - 1 do
          Result.ParamTypes[j] := fn.Params[j].ParamType;
        AddSymbolToCurrent(Result, span);
        Exit;
      end;
    end;
  end;
  
  if Result = nil then
    FDiag.Error('symbol not found in module ' + qualifier + ': ' + name, span);
end;

function TSema.CompileRegex(const pattern: string; span: TSourceSpan;
  out compiled: string; out captureSlots: Integer): Boolean;
var
  parser: TRegexParser;
  root: TRegexNode;
  groupCount: Integer;
  compiler: TRegexCompiler;
  rootGroup: TRegexNode;
begin
  compiled := '';
  captureSlots := 0;
  parser := TRegexParser.Create(pattern, FDiag, span);
  try
    if not parser.Parse(root, groupCount) then
    begin
      if Assigned(root) then
        root.Free;
      Result := False;
      Exit;
    end;
  finally
    parser.Free;
  end;
  captureSlots := (groupCount + 1) * 2;
  if captureSlots > MaxRegexCaptureSlots then
  begin
    FDiag.Error('too many regex capture groups (max ' +
      IntToStr(MaxRegexCaptureSlots div 2) + ')', span);
    root.Free;
    Result := False;
    Exit;
  end;
  rootGroup := TRegexNode.Create(rnGroup);
  rootGroup.GroupIndex := 0;
  SetLength(rootGroup.Children, 1);
  rootGroup.Children[0] := root;
  compiler := TRegexCompiler.Create;
  try
    compiled := compiler.Compile(rootGroup, captureSlots);
  finally
    compiler.Free;
    rootGroup.Free;
  end;
  Result := True;
end;

procedure TSema.Analyze(prog: TAstProgram);
var
  i, j, k, fi: Integer;
  structIdx: Integer;
  node: TAstNode;
  fn: TAstFuncDecl;
  con: TAstConDecl;
  m: TAstFuncDecl;
  p: TAstParam;
  s: TSymbol;
  sym: TSymbol;
  itype: TAurumType;
begin
  // Phase 0: Verarbeite Imports
  ProcessImports(prog);
  
  // First pass: register top-level functions, constants and struct types
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
  if node is TAstFuncDecl then
     begin
       fn := TAstFuncDecl(node);
       // check duplicates
       if ResolveSymbol(fn.Name) <> nil then
       begin
         FDiag.Error('redeclaration of function: ' + fn.Name, fn.Span);
         Continue;
       end;
       sym := TSymbol.Create(fn.Name);
       sym.Kind := symFunc;
       sym.DeclType := fn.ReturnType;
       sym.ReturnTypeName := fn.ReturnTypeName;
       sym.IsExtern := fn.IsExtern;
       sym.IsVarArgs := fn.IsVarArgs;
       // If return type is a struct, look up and store the struct decl
       if (fn.ReturnTypeName <> '') and Assigned(FStructTypes) then
       begin
         fi := FStructTypes.IndexOf(fn.ReturnTypeName);
         if fi >= 0 then
           sym.ReturnStructDecl := TAstStructDecl(FStructTypes.Objects[fi]);
       end;
       sym.ParamCount := Length(fn.Params);
       SetLength(sym.ParamTypes, sym.ParamCount);
       for j := 0 to sym.ParamCount - 1 do
         sym.ParamTypes[j] := fn.Params[j].ParamType;
       // Store generic type params for monomorphization
       sym.GenericTypeParams := fn.TypeParams;
       AddSymbolToCurrent(sym, fn.Span);
     end
     else if node is TAstStructDecl then
     begin
       // register struct type and its methods as top-level functions (mangled)
       if not Assigned(FStructTypes) then
       begin
         FStructTypes := TStringList.Create;
         FStructTypes.Sorted := False;
       end;
       if FStructTypes.IndexOf(TAstStructDecl(node).Name) >= 0 then
       begin
         FDiag.Error('redeclaration of type: ' + TAstStructDecl(node).Name, node.Span);
         Continue;
       end;
       FStructTypes.AddObject(TAstStructDecl(node).Name, System.TObject(node));
       // register methods as functions with mangled names
       for j := 0 to High(TAstStructDecl(node).Methods) do
       begin
         m := TAstStructDecl(node).Methods[j];
          
          sym := TSymbol.Create('_L_' + TAstStructDecl(node).Name + '_' + m.Name);
          sym.Kind := symFunc;
          sym.DeclType := m.ReturnType;
          sym.ReturnTypeName := m.ReturnTypeName;
          // Handle 'Self' return type
          if (m.ReturnTypeName = 'Self') or (m.ReturnTypeName = 'self') then
          begin
            sym.ReturnTypeName := TAstStructDecl(node).Name;
            sym.ReturnStructDecl := TAstStructDecl(node);
          end
          else if (m.ReturnTypeName <> '') and Assigned(FStructTypes) then
          begin
            fi := FStructTypes.IndexOf(m.ReturnTypeName);
            if fi >= 0 then
              sym.ReturnStructDecl := TAstStructDecl(FStructTypes.Objects[fi]);
          end;
         
         if m.IsStatic then
         begin
           // Static method: no implicit self parameter
           sym.ParamCount := Length(m.Params);
           SetLength(sym.ParamTypes, sym.ParamCount);
           for k := 0 to High(m.Params) do
             sym.ParamTypes[k] := m.Params[k].ParamType;
         end
         else
         begin
           // Instance method: first param is implicit self
           sym.ParamCount := Length(m.Params) + 1;
           SetLength(sym.ParamTypes, sym.ParamCount);
           sym.ParamTypes[0] := atUnresolved;
           for k := 0 to High(m.Params) do
             sym.ParamTypes[k+1] := m.Params[k].ParamType;
         end;

          AddSymbolToCurrent(sym, m.Span);
        end;
      end
      else if node is TAstClassDecl then
      begin
        // Register class type and its methods as top-level functions (mangled)
        if not Assigned(FClassTypes) then
        begin
          FClassTypes := TStringList.Create;
          FClassTypes.Sorted := False;
        end;
        if FClassTypes.IndexOf(TAstClassDecl(node).Name) >= 0 then
        begin
          FDiag.Error('redeclaration of class: ' + TAstClassDecl(node).Name, node.Span);
          Continue;
        end;
        FClassTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
        
        // Check if class has abstract methods - if so, mark class as abstract
        if not TAstClassDecl(node).IsAbstract then
        begin
          for j := 0 to High(TAstClassDecl(node).Methods) do
          begin
            if TAstClassDecl(node).Methods[j].IsAbstract then
            begin
              TAstClassDecl(node).IsAbstract := True;
              Break;
            end;
          end;
        end;
        
        // Register methods as functions with mangled names
        for j := 0 to High(TAstClassDecl(node).Methods) do
        begin
          m := TAstClassDecl(node).Methods[j];
          
          sym := TSymbol.Create('_L_' + TAstClassDecl(node).Name + '_' + m.Name);
          sym.Kind := symFunc;
          sym.DeclType := m.ReturnType;
          sym.ReturnTypeName := m.ReturnTypeName;
          // Handle 'Self' return type
          if (m.ReturnTypeName = 'Self') or (m.ReturnTypeName = 'self') then
          begin
            sym.ReturnTypeName := TAstClassDecl(node).Name;
            // Classes are reference types, so no StructDecl needed
          end;
          
          if m.IsStatic then
          begin
            // Static method: no implicit self parameter
            sym.ParamCount := Length(m.Params);
            SetLength(sym.ParamTypes, sym.ParamCount);
            for k := 0 to High(m.Params) do
              sym.ParamTypes[k] := m.Params[k].ParamType;
          end
          else
          begin
            // Instance method: first param is implicit self (pointer)
            sym.ParamCount := Length(m.Params) + 1;
            SetLength(sym.ParamTypes, sym.ParamCount);
            sym.ParamTypes[0] := atUnresolved; // self is a class pointer
            for k := 0 to High(m.Params) do
              sym.ParamTypes[k+1] := m.Params[k].ParamType;
          end;
          
          AddSymbolToCurrent(sym, m.Span);
        end;
      end
      else if node is TAstTypeDecl then
      begin
        // Register range types (aerospace-todo P1 #7)
        if TAstTypeDecl(node).HasRange then
        begin
          if FRangeTypes.IndexOf(TAstTypeDecl(node).Name) < 0 then
            FRangeTypes.AddObject(TAstTypeDecl(node).Name, System.TObject(node))
          else
            FDiag.Error('redeclaration of range type: ' + TAstTypeDecl(node).Name, node.Span);
        end;
      end
      else if node is TAstConDecl then
    begin
      con := TAstConDecl(node);
      if ResolveSymbol(con.Name) <> nil then
      begin
        FDiag.Error('redeclaration of constant: ' + con.Name, con.Span);
        Continue;
      end;
      // typecheck init expr
      itype := CheckExpr(con.InitExpr);
      if not TypeEqual(itype, con.DeclType) then
        FDiag.Error(Format('constant %s: expected type %s but got %s', [con.Name, AurumTypeToStr(con.DeclType), AurumTypeToStr(itype)]), con.Span);
      sym := TSymbol.Create(con.Name);
      sym.Kind := symCon;
      sym.DeclType := con.DeclType;
      AddSymbolToCurrent(sym, con.Span);
    end
    else if node is TAstEnumDecl then
    begin
      // Register the enum type name so it can be used in variable declarations
      if TAstEnumDecl(node).Name <> '<anon>' then
      begin
        if FEnumTypes.IndexOf(TAstEnumDecl(node).Name) < 0 then
          FEnumTypes.Add(TAstEnumDecl(node).Name);
      end;
      // Register each enum value as a compile-time integer constant
      for j := 0 to High(TAstEnumDecl(node).Values) do
      begin
        if ResolveSymbol(TAstEnumDecl(node).Values[j].Name) <> nil then
        begin
          FDiag.Error('redeclaration of enum value: ' + TAstEnumDecl(node).Values[j].Name, node.Span);
          Continue;
        end;
        sym := TSymbol.Create(TAstEnumDecl(node).Values[j].Name);
        sym.Kind := symCon;
        sym.DeclType := atInt64;
        AddSymbolToCurrent(sym, node.Span);
      end;
    end
    else if node is TAstVarDecl then
    begin
      // Global variable declaration
      if TAstVarDecl(node).IsGlobal then
      begin
        if ResolveSymbol(TAstVarDecl(node).Name) <> nil then
        begin
          FDiag.Error('redeclaration of global variable: ' + TAstVarDecl(node).Name, node.Span);
          Continue;
        end;
        // typecheck init expr (if present)
        if Assigned(TAstVarDecl(node).InitExpr) then
          itype := CheckExpr(TAstVarDecl(node).InitExpr)
        else
          itype := TAstVarDecl(node).DeclType;  // Use declared type if no initializer
        
        // Check type compatibility
        // Special case: both are atArray (unannotated array) - accept array literals
        if TypeEqual(itype, TAstVarDecl(node).DeclType) then
        begin
          // Types are compatible
        end
        else if (TAstVarDecl(node).DeclType = atArray) and (itype = atArray) then
        begin
          // Both are unannotated arrays - compatible (type will be inferred from literal)
        end
        else if (TAstVarDecl(node).DeclType = atDynArray) and (itype = atArray) then
        begin
          // Declared as 'array' (atDynArray), assigned an array literal (atArray)
          // Compatible - array literals can initialize dynamic arrays
        end
        else if (TAstVarDecl(node).DeclType <> atUnresolved) then
          FDiag.Error(Format('global %s: expected type %s but got %s', 
            [TAstVarDecl(node).Name, AurumTypeToStr(TAstVarDecl(node).DeclType), AurumTypeToStr(itype)]), node.Span);
        sym := TSymbol.Create(TAstVarDecl(node).Name);
        case TAstVarDecl(node).Storage of
          skVar: sym.Kind := symVar;
          skLet: sym.Kind := symLet;
        else
          sym.Kind := symVar;
        end;
        if TAstVarDecl(node).DeclType = atUnresolved then
          sym.DeclType := itype
        else
          sym.DeclType := TAstVarDecl(node).DeclType;
        sym.TypeName := TAstVarDecl(node).DeclTypeName;
        // If initializer is an array literal, record its length as ArrayLen
        if TAstVarDecl(node).InitExpr is TAstArrayLit then
          sym.ArrayLen := Length(TAstArrayLit(TAstVarDecl(node).InitExpr).Items)
        else
          sym.ArrayLen := TAstVarDecl(node).ArrayLen;
        sym.IsGlobal := True;
        AddSymbolToCurrent(sym, node.Span);
      end;
    end;
  end;

  // After registration pass, compute struct layouts before checking bodies
  ComputeStructLayouts;
  ComputeClassLayouts;
  ResolveVMTForClasses;
  RegisterInheritedMethods;

  // Safety-pragma validation pass (aerospace-todo P1 #6, P0 #43)
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    // @integrity unit-level validation
    if node is TAstUnitDecl then
    begin
      if (TAstUnitDecl(node).IntegrityAttr.Mode = imScrubbed) and
         (TAstUnitDecl(node).IntegrityAttr.Interval <= 0) then
        FDiag.Warning('unit ''' + TAstUnitDecl(node).UnitPath +
          ''' has @integrity(mode: scrubbed) without interval; scrubbing requires a check interval (ms)',
          node.Span);
    end
    else if node is TAstFuncDecl then
    begin
      fn := TAstFuncDecl(node);
      // @critical on extern function makes no sense
      if fn.IsExtern and fn.SafetyPragmas.IsCritical then
        FDiag.Error('@critical pragma on extern function ''' + fn.Name + ''' is not meaningful', fn.Span);
      // @wcet on extern function: cannot verify WCET
      if fn.IsExtern and (fn.SafetyPragmas.WCETBudget > 0) then
        FDiag.Error('@wcet pragma on extern function ''' + fn.Name + ''' cannot be verified', fn.Span);
      // @stack_limit on extern function: cannot verify stack usage
      if fn.IsExtern and (fn.SafetyPragmas.StackLimit > 0) then
        FDiag.Error('@stack_limit pragma on extern function ''' + fn.Name + ''' cannot be verified', fn.Span);
      // @dal(A) without @critical: note that critical flag is recommended
      if (fn.SafetyPragmas.DALLevel = dalA) and not fn.SafetyPragmas.IsCritical then
        FDiag.Warning('DAL-A function ''' + fn.Name + ''' should be marked @critical', fn.Span);
      // @integrity on extern function cannot be enforced
      if fn.IsExtern and (fn.SafetyPragmas.Integrity.Mode <> imNone) then
        FDiag.Error('@integrity pragma on extern function ''' + fn.Name + ''' cannot be enforced', fn.Span);
      // @integrity(mode: scrubbed) requires a positive interval
      if (fn.SafetyPragmas.Integrity.Mode = imScrubbed) and
         (fn.SafetyPragmas.Integrity.Interval <= 0) then
        FDiag.Warning('@integrity(mode: scrubbed) on ''' + fn.Name +
          ''' has no interval set; scrubbing requires a check interval (ms)', fn.Span);
    end;
  end;

  // Second pass: check function bodies
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstFuncDecl then
    begin
      fn := TAstFuncDecl(node);
      // Skip body checking for generic functions — bodies are checked at monomorphization time
      if Length(fn.TypeParams) > 0 then
        Continue;
      // enter function scope
      PushScope;
      // declare parameters as vars in local scope
      for j := 0 to High(fn.Params) do
      begin
        sym := TSymbol.Create(fn.Params[j].Name);
        sym.Kind := symVar;
        sym.DeclType := fn.Params[j].ParamType;
        sym.TypeName := fn.Params[j].TypeName;  // for struct types
        // If it's a struct type (atUnresolved with TypeName), also set StructDecl
        if (sym.DeclType = atUnresolved) and (sym.TypeName <> '') then
        begin
          structIdx := FStructTypes.IndexOf(sym.TypeName);
          if structIdx >= 0 then
            sym.StructDecl := TAstStructDecl(FStructTypes.Objects[structIdx])
          // If it's an enum type, resolve to int64
          else if Assigned(FEnumTypes) and (FEnumTypes.IndexOf(sym.TypeName) >= 0) then
            sym.DeclType := atInt64;
        end;
        AddSymbolToCurrent(sym, fn.Params[j].Span);
      end;
      // set current return type
      FCurrentReturn := fn.ReturnType;
      // check body
      CheckStmt(fn.Body);
      // leave function scope
      PopScope;
    end;
  end;

  // Also process methods defined inside structs
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstStructDecl then
    begin
      for j := 0 to High(TAstStructDecl(node).Methods) do
      begin
        m := TAstStructDecl(node).Methods[j];
        
        // Resolve 'Self' return type to the owning struct type
        if (m.ReturnTypeName = 'Self') or (m.ReturnTypeName = 'self') then
        begin
          m.ReturnTypeName := TAstStructDecl(node).Name;
          // ReturnType stays atUnresolved since it's a named struct type
        end;
        
        // enter method scope
        PushScope;
        
        // For non-static methods, add implicit self parameter
        if not m.IsStatic then
        begin
          sym := TSymbol.Create('self');
          sym.Kind := symVar;
          sym.DeclType := atUnresolved; // primitive type is unresolved
          sym.TypeName := TAstStructDecl(node).Name; // but we know the struct name
          sym.StructDecl := TAstStructDecl(node); // and the struct declaration
          AddSymbolToCurrent(sym, m.Span);
        end;
        
        // declare method params
        for k := 0 to High(m.Params) do
        begin
          p := m.Params[k];
          sym := TSymbol.Create(p.Name);
          sym.Kind := symVar;
          sym.DeclType := p.ParamType;
          AddSymbolToCurrent(sym, p.Span);
        end;
        // set return type
        FCurrentReturn := m.ReturnType;
        // check body
        CheckStmt(m.Body);
        PopScope;
      end;
    end;
  end;

  // Also process methods defined inside classes
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstClassDecl then
    begin
      FCurrentClass := TAstClassDecl(node);
      for j := 0 to High(TAstClassDecl(node).Methods) do
      begin
        m := TAstClassDecl(node).Methods[j];
        
        // Resolve 'Self' return type to the owning class type
        if (m.ReturnTypeName = 'Self') or (m.ReturnTypeName = 'self') then
        begin
          m.ReturnTypeName := TAstClassDecl(node).Name;
        end;
        
        // enter method scope
        PushScope;
        
        // For non-static methods, add implicit self parameter
        if not m.IsStatic then
        begin
          sym := TSymbol.Create('self');
          sym.Kind := symVar;
          sym.DeclType := atUnresolved; // self is a class pointer
          sym.TypeName := TAstClassDecl(node).Name; // class name
          sym.ClassDecl := TAstClassDecl(node); // class declaration for field resolution
          AddSymbolToCurrent(sym, m.Span);
        end;
        
        // declare method params
        for k := 0 to High(m.Params) do
        begin
          p := m.Params[k];
          sym := TSymbol.Create(p.Name);
          sym.Kind := symVar;
          sym.DeclType := p.ParamType;
          sym.TypeName := p.TypeName;
          // Set ClassDecl/StructDecl so that method calls and field accesses on
          // class-typed params (e.g. fn Init(p: Parser)) resolve correctly.
          if p.TypeName <> '' then
          begin
            if Assigned(FClassTypes) then
            begin
              fi := FClassTypes.IndexOf(p.TypeName);
              if fi >= 0 then
                sym.ClassDecl := TAstClassDecl(FClassTypes.Objects[fi]);
            end;
            if (sym.ClassDecl = nil) and Assigned(FStructTypes) then
            begin
              fi := FStructTypes.IndexOf(p.TypeName);
              if fi >= 0 then
              begin
                if FStructTypes.Objects[fi] is TAstClassDecl then
                  sym.ClassDecl := TAstClassDecl(FStructTypes.Objects[fi])
                else
                  sym.StructDecl := TAstStructDecl(FStructTypes.Objects[fi]);
              end;
            end;
          end;
          AddSymbolToCurrent(sym, p.Span);
        end;
        // set return type
        FCurrentReturn := m.ReturnType;
        // check body
        CheckStmt(m.Body);
        PopScope;
      end;
      FCurrentClass := nil;
    end;
  end;
end;

procedure TSema.AnalyzeWithUnits(prog: TAstProgram; um: TUnitManager);
begin
  FUnitManager := um;
  Analyze(prog);
end;

// ---------------------------------------------------------------
// AST rewrite helpers
// ---------------------------------------------------------------

function TSema.RewriteExpr(expr: TAstExpr): TAstExpr;
var call: TAstCall; i: Integer;
begin
  if expr = nil then Exit(nil);
  // Only handle call-args rewriting for now
  if expr is TAstCall then
  begin
    call := TAstCall(expr);
    for i := 0 to High(call.Args) do
      call.Args[i] := RewriteExpr(call.Args[i]);
  end;
  Result := expr;
end;

function TSema.RewriteStmt(stmt: TAstStmt): TAstStmt;
var newExpr: TAstExpr; newStmt: TAstExprStmt;
begin
  // For now, only rewrite expression statements
  if stmt = nil then Exit(nil);
  if stmt is TAstExprStmt then
  begin
    newExpr := RewriteExpr(TAstExprStmt(stmt).Expr);
    if newExpr <> TAstExprStmt(stmt).Expr then
    begin
      newStmt := TAstExprStmt.Create(newExpr, stmt.Span);
      stmt.Free;
      Exit(newStmt);
    end;
  end;
  Result := stmt;
end;

procedure TSema.RewriteAST(prog: TAstProgram);
var i, j: Integer; fn: TAstFuncDecl;
begin
  if not Assigned(prog) then Exit;
  for i := 0 to High(prog.Decls) do
  begin
    if prog.Decls[i] is TAstFuncDecl then
    begin
      // rewrite statements in function body
      // naive approach: iterate statements and call RewriteStmt
      fn := TAstFuncDecl(prog.Decls[i]);
      if Assigned(fn.Body) then
      begin
        for j := 0 to High(fn.Body.Stmts) do
          fn.Body.Stmts[j] := RewriteStmt(fn.Body.Stmts[j]);
      end;
    end;
  end;
end;

end.
