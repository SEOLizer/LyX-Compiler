{$mode objfpc}{$H+}
program test_dyn_debug;

uses
  SysUtils, diag, lexer, parser, ast, sema, ir, lower_ast_to_ir, unit_manager;

var
  d: TDiagnostics;
  l: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  um: TUnitManager;
  modl: TIRModule;
  lower: TIRLowering;
  fn: TIRFunction;
  i: Integer;
begin
  d := TDiagnostics.Create;
  // Test 1: Array declaration with push
  WriteLn('=== Test: push ===');
  l := TLexer.Create('fn main(): int64 { var a: array := []; push(a, 42); return 0; }', 'test.lyx', d);
  p := TParser.Create(l, d);
  prog := p.ParseProgram;
  
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
  
  fn := modl.FindFunction('main');
  if Assigned(fn) then
  begin
    WriteLn('Instructions in main:');
    for i := 0 to High(fn.Instructions) do
    begin
      WriteLn('  [', i, ']: Op=', Ord(fn.Instructions[i].Op));
    end;
  end;
  
  modl.Free;
  prog.Free;
  p.Free;
  l.Free;
  d.Free;
end.
