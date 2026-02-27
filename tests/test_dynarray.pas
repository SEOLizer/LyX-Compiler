{$mode objfpc}{$H+}
program test_dynarray;

uses SysUtils, Classes, fpcunit, testregistry, consoletestrunner,
  diag, lexer, parser, ast, sema, ir, lower_ast_to_ir;

type
  TDynArrayTest = class(TTestCase)
  private
    FDiag: TDiagnostics;
    function ParseAndLower(const src, fname: string): TIRModule;
  published
    procedure TestDynArrayDeclEmits3Slots;
    procedure TestDynArrayPushEmitsIR;
    procedure TestDynArrayLenEmitsIR;
    procedure TestDynArrayPopEmitsIR;
    procedure TestDynArrayFreeEmitsIR;
    procedure TestDynArrayIndexAccessEmitsLoadLocal;
    procedure TestDynArrayLiteralInit;
  end;

function TDynArrayTest.ParseAndLower(const src, fname: string): TIRModule;
var
  lex: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  lower: TIRLowering;
  modl: TIRModule;
begin
  FDiag := TDiagnostics.Create;
  lex := TLexer.Create(src, fname, FDiag);
  try
    p := TParser.Create(lex, FDiag);
    try
      prog := p.ParseProgram;
      s := TSema.Create(FDiag, nil);
      try
        s.Analyze(prog);
      finally
        s.Free;
      end;
      modl := TIRModule.Create;
      lower := TIRLowering.Create(modl, FDiag);
      try
        lower.Lower(prog);
        Result := modl;
      finally
        lower.Free;
        prog.Free;
      end;
    finally
      p.Free;
    end;
  finally
    lex.Free;
    FDiag.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayDeclEmits3Slots;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  storeCount: Integer;
begin
  // A dynamic array declaration should allocate 3 slots and initialize to 0
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    // Should have at least 3 irStoreLocal instructions for ptr/len/cap initialization
    storeCount := 0;
    for i := 0 to High(f.Instructions) do
      if f.Instructions[i].Op = irStoreLocal then
        Inc(storeCount);
    AssertTrue('should have at least 3 store instructions for fat-pointer init',
      storeCount >= 3);
  finally
    modl.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayPushEmitsIR;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  foundPush: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  push(a, 42);' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    foundPush := False;
    for i := 0 to High(f.Instructions) do
      if f.Instructions[i].Op = irDynArrayPush then
        foundPush := True;
    AssertTrue('irDynArrayPush expected for push(a, 42)', foundPush);
  finally
    modl.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayLenEmitsIR;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  foundLen: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  return len(a);' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    foundLen := False;
    for i := 0 to High(f.Instructions) do
      if f.Instructions[i].Op = irDynArrayLen then
        foundLen := True;
    AssertTrue('irDynArrayLen expected for len(a)', foundLen);
  finally
    modl.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayPopEmitsIR;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  foundPop: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  push(a, 10);' + LineEnding +
    '  return pop(a);' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    foundPop := False;
    for i := 0 to High(f.Instructions) do
      if f.Instructions[i].Op = irDynArrayPop then
        foundPop := True;
    AssertTrue('irDynArrayPop expected for pop(a)', foundPop);
  finally
    modl.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayFreeEmitsIR;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  foundFree: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  push(a, 10);' + LineEnding +
    '  free(a);' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    foundFree := False;
    for i := 0 to High(f.Instructions) do
      if f.Instructions[i].Op = irDynArrayFree then
        foundFree := True;
    AssertTrue('irDynArrayFree expected for free(a)', foundFree);
  finally
    modl.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayIndexAccessEmitsLoadLocal;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  foundLoadLocal, foundLoadElem: Boolean;
begin
  // For dynamic arrays, index access should use irLoadLocal (to get ptr),
  // NOT irLoadLocalAddr (which is for static arrays)
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  push(a, 10);' + LineEnding +
    '  push(a, 20);' + LineEnding +
    '  return a[0];' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    foundLoadLocal := False;
    foundLoadElem := False;
    for i := 0 to High(f.Instructions) do
    begin
      case f.Instructions[i].Op of
        irLoadLocal: foundLoadLocal := True;
        irLoadElem: foundLoadElem := True;
      end;
    end;
    AssertTrue('irLoadLocal expected for dynamic array ptr access', foundLoadLocal);
    AssertTrue('irLoadElem expected for dynamic array element load', foundLoadElem);
  finally
    modl.Free;
  end;
end;

procedure TDynArrayTest.TestDynArrayLiteralInit;
var
  modl: TIRModule;
  f: TIRFunction;
  i: Integer;
  pushCount: Integer;
begin
  // Dynamic array initialized with non-empty literal should emit push for each element
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [10, 20, 30];' + LineEnding +
    '  return a[1];' + LineEnding +
    '}',
    'test_dyn.lyx'
  );
  try
    f := modl.FindFunction('main');
    AssertNotNull('main function should exist', f);
    pushCount := 0;
    for i := 0 to High(f.Instructions) do
      if f.Instructions[i].Op = irDynArrayPush then
        Inc(pushCount);
    AssertTrue('should have 3 irDynArrayPush instructions for [10, 20, 30]',
      pushCount = 3);
  finally
    modl.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TDynArrayTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
