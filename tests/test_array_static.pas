{$mode objfpc}{$H+}
program test_array_static;

uses SysUtils, Classes, fpcunit, testregistry, consoletestrunner, diag, lexer, parser, ast, sema, ir, lower_ast_to_ir;

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
    foundLoadLocalAddr := False; foundLoadElem := False;
    for i := 0 to High(modl.Functions) do
    begin
      f := modl.Functions[i];
      if f.Name <> 'main' then Continue;
      for j := 0 to High(f.Instructions) do
      begin
        case f.Instructions[j].Op of
          irLoadLocalAddr:
            begin
              // For a[1] access, we load address of array
              foundLoadLocalAddr := True;
            end;
          irLoadElem:
            begin
              // Element load from array base + index
              foundLoadElem := True;
            end;
        end;
      end;
    end;
    AssertTrue('irLoadLocalAddr expected for array access', foundLoadLocalAddr);
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
