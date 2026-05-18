{$mode objfpc}{$H+}
unit regex_engine;

// NFA-to-bytecode regex compiler extracted from sema.pas.
// Public surface: a single CompileRegex() function.
// Bytecode format: RX1 header + class table + instruction stream (see TRegexCompiler.Compile).

interface

uses
  SysUtils, Classes, diag, bytes;

function CompileRegex(const pattern: string; diag: TDiagnostics; span: TSourceSpan;
  out compiled: string; out captureSlots: Integer): Boolean;

implementation

const
  MaxRegexCaptureSlots = 32;

  RX_OP_CHAR  = 1;
  RX_OP_ANY   = 2;
  RX_OP_CLASS = 3;
  RX_OP_SPLIT = 4;
  RX_OP_JMP   = 5;
  RX_OP_MATCH = 6;
  RX_OP_SAVE  = 7;
  RX_OP_BOL   = 8;
  RX_OP_EOL   = 9;

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

{ CompileRegex — public entry point }

function CompileRegex(const pattern: string; diag: TDiagnostics; span: TSourceSpan;
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
  parser := TRegexParser.Create(pattern, diag, span);
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
    diag.Error('too many regex capture groups (max ' +
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

end.
