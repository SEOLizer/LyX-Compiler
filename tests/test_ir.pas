{$mode objfpc}{$H+}
program test_ir;

uses
  SysUtils,
  fpcunit, testregistry, consoletestrunner,
  diag, lexer, parser, ast, sema, ir, lower_ast_to_ir, unit_manager;

type
  TIRTest = class(TTestCase)
  published
    procedure TestLowerSimpleFunction;
    procedure TestLowerVarargsCall;
  end;

procedure BuildIRModule(const src: string; out modl: TIRModule; d: TDiagnostics);
var
  l: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  um: TUnitManager;
  lower: TIRLowering;
begin
  l := TLexer.Create(src, 'test.lyx', d);
  p := TParser.Create(l, d);
  prog := p.ParseProgram;
  p.Free;
  l.Free;

  um := TUnitManager.Create(d);
  try
    um.AddSearchPath('..');
    um.AddSearchPath('../std');
    um.AddSearchPath('std');
    um.LoadAllImports(prog, '');

    s := TSema.Create(d, um);
    try
      s.Analyze(prog);
    finally
      s.Free;
    end;
  finally
    um.Free;
  end;

  modl := TIRModule.Create;
  lower := TIRLowering.Create(modl, d);
  try
    lower.Lower(prog);
  finally
    lower.Free;
  end;
  prog.Free;
end;

procedure TIRTest.TestLowerSimpleFunction;
var
  d: TDiagnostics;
  modl: TIRModule;
  fn: TIRFunction;
  found: Boolean;
  i: Integer;
begin
  d := TDiagnostics.Create;
  try
    BuildIRModule('fn main(): int64 { var i: int64 := 0; i := 1 + 2 * 3; PrintStr("hi\n"); return 0; }', modl, d);
    try
      AssertTrue(Length(modl.Functions) >= 1);
      fn := modl.Functions[0];
      AssertTrue(Length(fn.Instructions) > 0);
      // basic check: there should be a store to local for initial var
      // find any irStoreLocal
      found := False;
      for i := 0 to High(fn.Instructions) do
        if fn.Instructions[i].Op = irStoreLocal then found := True;
      AssertTrue(found);
    finally
      modl.Free;
    end;
  finally
    d.Free;
  end;
end;

procedure TIRTest.TestLowerVarargsCall;
var
  d: TDiagnostics;
  modl: TIRModule;
  fn: TIRFunction;
  found: Boolean;
  i: Integer;
  hasCallWithMultipleArgs: Boolean;
begin
  d := TDiagnostics.Create;
  try
    BuildIRModule('fn main(): int64 { printf("hello"); printf("num: %d", 42); return 0; }', modl, d);
    try
      AssertEquals('Semantic analysis should pass for varargs calls', 0, d.ErrorCount);
      
      // Find main function in IR
      found := False;
      for i := 0 to High(modl.Functions) do
      begin
        if modl.Functions[i].Name = 'main' then
        begin
          fn := modl.Functions[i];
          found := True;
          Break;
        end;
      end;
      AssertTrue('Should find main function in IR', found);
       
      // Check that there are call instructions with different argument counts
      hasCallWithMultipleArgs := False;
      for i := 0 to High(fn.Instructions) do
      begin
        // Check both irCall and irCallBuiltin
        if (fn.Instructions[i].Op = irCall) or (fn.Instructions[i].Op = irCallBuiltin) then
        begin
          if fn.Instructions[i].ImmInt > 1 then // more than 1 argument
            hasCallWithMultipleArgs := True;
        end;
      end;
      AssertTrue('Should have varargs calls with multiple arguments', hasCallWithMultipleArgs);
    finally
      modl.Free;
    end;
  finally
    d.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TIRTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
