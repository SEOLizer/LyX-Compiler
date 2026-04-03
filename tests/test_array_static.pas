{$mode objfpc}{$H+}
program test_array_static;

uses SysUtils, Classes, fpcunit, testregistry, consoletestrunner, diag, lexer, parser, ast, sema, ir, lower_ast_to_ir, unit_manager;

type
  TArrayStaticTest = class(TTestCase)
  private
    FDiag: TDiagnostics;
    function ParseAndLower(const src, fname: string): TIRModule;
  published
    procedure TestStaticArrayInitAndIndex;
  end;

function TArrayStaticTest.ParseAndLower(const src, fname: string): TIRModule;
var
  lex: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  um: TUnitManager;
  lower: TIRLowering;
  modl: TIRModule;
begin
  FDiag := TDiagnostics.Create;
  lex := TLexer.Create(src, fname, FDiag);
  try
    p := TParser.Create(lex, FDiag);
    try
      prog := p.ParseProgram;
      
      um := TUnitManager.Create(FDiag);
      try
        um.AddSearchPath('..');
        um.AddSearchPath('../std');
        um.AddSearchPath('std');
        um.LoadAllImports(prog, '');
        
        s := TSema.Create(FDiag, um);
        try
          s.Analyze(prog);
        finally
          s.Free;
        end;
      finally
        um.Free;
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

procedure TArrayStaticTest.TestStaticArrayInitAndIndex;
var
  modl: TIRModule;
  f: TIRFunction;
  i, j: Integer;
  foundLoadLocal, foundLoadElem, foundDynArrayPush: Boolean;
begin
  // 'array' keyword creates a dynamic array (fat-pointer: ptr, len, cap)
  // With explicit push calls, irDynArrayPush is emitted
  modl := ParseAndLower(
    'fn main(): int64 {' + LineEnding +
    '  var a: array := [];' + LineEnding +
    '  push(a, 2);' + LineEnding +
    '  push(a, 3);' + LineEnding +
    '  push(a, 5);' + LineEnding +
    '  return a[1];' + LineEnding +
    '}',
    'test_array.au'
  );
  try
    foundLoadLocal := False; foundLoadElem := False; foundDynArrayPush := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        case f.Instructions[j].Op of
          irDynArrayPush:
            foundDynArrayPush := True;
          irLoadLocal:
            begin
              // For dynamic array a[1] access, we load the heap pointer
              foundLoadLocal := True;
            end;
          irLoadElem:
            begin
              // Element load from heap pointer + index
              foundLoadElem := True;
            end;
        end;
      end;
    end;
    AssertTrue('irDynArrayPush expected for push() calls', foundDynArrayPush);
    AssertTrue('irLoadLocal expected for dynamic array access', foundLoadLocal);
    AssertTrue('irLoadElem expected for array access', foundLoadElem);
  finally
    modl.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TArrayStaticTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
