{$mode objfpc}{$H+}
program test_arm64_float;

uses SysUtils, Classes, fpcunit, testregistry, consoletestrunner,
  diag, lexer, parser, ast, sema, ir, lower_ast_to_ir,
  bytes, arm64_emit, elf64_arm64_writer;

type
  TARM64FloatTest = class(TTestCase)
  private
    FDiag: TDiagnostics;
    function ParseAndLower(const src, fname: string): TIRModule;
    procedure CheckEmittedCode(const modl: TIRModule);
  published
    procedure TestFloatAdd;
    procedure TestFloatSub;
    procedure TestFloatMul;
    procedure TestFloatDiv;
    procedure TestFloatCmp;
    procedure TestFloatToInt;
    procedure TestIntToFloat;
  end;

function TARM64FloatTest.ParseAndLower(const src, fname: string): TIRModule;
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
        prog.Free;  // AST wird nach dem Lowering nicht mehr benötigt
      end;
    finally
      p.Free;
    end;
  finally
    lex.Free;
    FDiag.Free;
  end;
end;

procedure TARM64FloatTest.CheckEmittedCode(const modl: TIRModule);
var
  emit: TARM64Emitter;
  codeBuf, dataBuf: TByteBuffer;
begin
  emit := TARM64Emitter.Create;
  try
    emit.EmitFromIR(modl);
    codeBuf := emit.GetCodeBuffer;
    dataBuf := emit.GetDataBuffer;
    
    // Basic sanity checks
    AssertTrue('Code buffer should not be empty', codeBuf.Size > 0);
    AssertTrue('Code buffer should be 4-byte aligned', (codeBuf.Size mod 4) = 0);
    
  finally
    emit.Free;
  end;
end;

procedure TARM64FloatTest.TestFloatAdd;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundFAdd: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: f64 := 3.14;' + LineEnding +
    '  var y: f64 := 2.0;' + LineEnding +
    '  var z: f64 := x + y;' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_float_add.au'
  );
  try
    foundFAdd := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        if f.Instructions[j].Op = irFAdd then
        begin
          foundFAdd := True;
          Break;
        end;
      end;
    end;
    AssertTrue('irFAdd expected', foundFAdd);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

procedure TARM64FloatTest.TestFloatSub;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundFSub: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: f64 := 5.0;' + LineEnding +
    '  var y: f64 := 2.5;' + LineEnding +
    '  var z: f64 := x - y;' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_float_sub.au'
  );
  try
    foundFSub := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        if f.Instructions[j].Op = irFSub then
        begin
          foundFSub := True;
          Break;
        end;
      end;
    end;
    AssertTrue('irFSub expected', foundFSub);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

procedure TARM64FloatTest.TestFloatMul;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundFMul: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: f64 := 3.0;' + LineEnding +
    '  var y: f64 := 4.0;' + LineEnding +
    '  var z: f64 := x * y;' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_float_mul.au'
  );
  try
    foundFMul := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        if f.Instructions[j].Op = irFMul then
        begin
          foundFMul := True;
          Break;
        end;
      end;
    end;
    AssertTrue('irFMul expected', foundFMul);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

procedure TARM64FloatTest.TestFloatDiv;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundFDiv: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: f64 := 10.0;' + LineEnding +
    '  var y: f64 := 2.0;' + LineEnding +
    '  var z: f64 := x / y;' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_float_div.au'
  );
  try
    foundFDiv := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        if f.Instructions[j].Op = irFDiv then
        begin
          foundFDiv := True;
          Break;
        end;
      end;
    end;
    AssertTrue('irFDiv expected', foundFDiv);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

procedure TARM64FloatTest.TestFloatCmp;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundFCmp: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: f64 := 5.0;' + LineEnding +
    '  var y: f64 := 3.0;' + LineEnding +
    '  var b: bool := x > y;' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_float_cmp.au'
  );
  try
    foundFCmp := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        case f.Instructions[j].Op of
          irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
          begin
            foundFCmp := True;
            Break;
          end;
        end;
      end;
    end;
    AssertTrue('irFCmp* expected', foundFCmp);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

procedure TARM64FloatTest.TestFloatToInt;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundFToI: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: f64 := 3.14;' + LineEnding +
    '  var y: int64 := x as int64;' + LineEnding +
    '  return y;' + LineEnding +
    '}',
    'test_float_to_int.au'
  );
  try
    foundFToI := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        if f.Instructions[j].Op = irFToI then
        begin
          foundFToI := True;
          Break;
        end;
      end;
    end;
    AssertTrue('irFToI expected', foundFToI);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

procedure TARM64FloatTest.TestIntToFloat;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundIToF: Boolean;
begin
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var x: int64 := 42;' + LineEnding +
    '  var y: f64 := x as f64;' + LineEnding +
    '  return 0;' + LineEnding +
    '}',
    'test_int_to_float.au'
  );
  try
    foundIToF := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        if f.Instructions[j].Op = irIToF then
        begin
          foundIToF := True;
          Break;
        end;
      end;
    end;
    AssertTrue('irIToF expected', foundIToF);
    CheckEmittedCode(modl);
  finally
    modl.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TARM64FloatTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
