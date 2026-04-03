{$mode objfpc}{$H+}
program test_debug3;

uses
  SysUtils, lexer, parser, ast, diag;

var
  lex: TLexer;
  p: TParser;
  prog: TAstProgram;
  diags: TDiagnostics;
  i: Integer;
begin
  diags := TDiagnostics.Create;
  // Test mit for-Schleife
  lex := TLexer.Create('fn main(): int64 { for i := 0 to 5 do { PrintInt(i); } return 0; }', 'test.lyx', diags);
  try
    p := TParser.Create(lex, diags);
    try
      prog := p.ParseProgram;
      try
        WriteLn('Number of declarations: ', Length(prog.Decls));
        for i := 0 to High(prog.Decls) do
        begin
          WriteLn('Decl[', i, ']: ', prog.Decls[i].ClassName);
          if prog.Decls[i] is TAstImportDecl then
            WriteLn('  UnitPath: ', TAstImportDecl(prog.Decls[i]).UnitPath);
          if prog.Decls[i] is TAstFuncDecl then
          begin
            WriteLn('  Name: ', TAstFuncDecl(prog.Decls[i]).Name);
            if Assigned(TAstFuncDecl(prog.Decls[i]).Body) then
              WriteLn('  Body Stmts: ', Length(TAstFuncDecl(prog.Decls[i]).Body.Stmts));
          end;
        end;
      finally
        prog.Free;
      end;
    finally
      p.Free;
    end;
  finally
    lex.Free;
    diags.Free;
  end;
end.
