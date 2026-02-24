{$mode objfpc}{$H+}
program test_arm64_array;

uses SysUtils, Classes, fpcunit, testregistry, consoletestrunner,
  diag, lexer, parser, ast, sema, ir, lower_ast_to_ir,
  bytes, arm64_emit, elf64_arm64_writer;

type
  TARM64ArrayTest = class(TTestCase)
  private
    FDiag: TDiagnostics;
    function ParseAndLower(const src, fname: string): TIRModule;
    procedure CheckEmittedCode(const modl: TIRModule);
  published
    procedure TestStaticArrayInitAndIndex;
    procedure TestArrayDynamicIndex;
    procedure TestArrayStoreAndLoad;
  end;

function TARM64ArrayTest.ParseAndLower(const src, fname: string): TIRModule;
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

procedure TARM64ArrayTest.CheckEmittedCode(const modl: TIRModule);
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
    
    // Write to files for debugging if needed
    // codeBuf.SaveToFile('/tmp/arm64_array_code.bin');
    // dataBuf.SaveToFile('/tmp/arm64_array_data.bin');
    
  finally
    emit.Free;
  end;
end;

procedure TARM64ArrayTest.TestStaticArrayInitAndIndex;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundLoadLocalAddr, foundLoadElem: Boolean;
begin
  // Use correct array syntax: "var a: array := [2,3,5];"
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [2,3,5];' + LineEnding +
    '  return a[1];' + LineEnding +
    '}',
    'test_array.au'
  );
  try
    // Check IR contains expected instructions
    foundLoadLocalAddr := False;
    foundLoadElem := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        case f.Instructions[j].Op of
          irLoadLocalAddr:
            begin
              foundLoadLocalAddr := True;
            end;
          irLoadElem:
            begin
              foundLoadElem := True;
            end;
        end;
      end;
    end;
    AssertTrue('irLoadLocalAddr expected for array access', foundLoadLocalAddr);
    AssertTrue('irLoadElem expected for array access', foundLoadElem);
    
    // Now test ARM64 code generation
    CheckEmittedCode(modl);
    
  finally
    modl.Free;
  end;
end;

procedure TARM64ArrayTest.TestArrayDynamicIndex;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundLoadLocalAddr, foundLoadElem: Boolean;
begin
  // Use correct array syntax: "var a: array := [10,20,30];"
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [10,20,30];' + LineEnding +
    '  var i: int64 := 2;' + LineEnding +
    '  return a[i];' + LineEnding +
    '}',
    'test_array_dyn.au'
  );
  try
    // Check IR for dynamic array operations
    foundLoadLocalAddr := False;
    foundLoadElem := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        case f.Instructions[j].Op of
          irLoadLocalAddr:
            begin
              foundLoadLocalAddr := True;
            end;
          irLoadElem:
            begin
              foundLoadElem := True;
            end;
        end;
      end;
    end;
    AssertTrue('irLoadLocalAddr expected for array access', foundLoadLocalAddr);
    AssertTrue('irLoadElem expected for array load', foundLoadElem);
    
    // Test ARM64 code generation
    CheckEmittedCode(modl);
    
  finally
    modl.Free;
  end;
end;

procedure TARM64ArrayTest.TestArrayStoreAndLoad;
var
  modl: TIRModule;
  i, j: Integer;
  f: TIRFunction;
  foundStoreElem, foundLoadElem: Boolean;
begin
  // Use correct array syntax: "var a: array;"
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array;' + LineEnding +
    '  a[0] := 100;' + LineEnding +
    '  a[4] := 500;' + LineEnding +
    '  return a[0] + a[4];' + LineEnding +
    '}',
    'test_array_store.au'
  );
  try
    // Check IR for array operations
    foundStoreElem := False;
    foundLoadElem := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        case f.Instructions[j].Op of
          irStoreElem:
            begin
              foundStoreElem := True;
            end;
          irLoadElem:
            begin
              foundLoadElem := True;
            end;
        end;
      end;
    end;
    AssertTrue('irStoreElem expected for array store', foundStoreElem);
    AssertTrue('irLoadElem expected for array load', foundLoadElem);
    
    // Test ARM64 code generation
    CheckEmittedCode(modl);
    
  finally
    modl.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TARM64ArrayTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
