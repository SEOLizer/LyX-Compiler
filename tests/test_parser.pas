{$mode objfpc}{$H+}
program test_parser;

uses
  SysUtils,
  fpcunit, testregistry, consoletestrunner,
  diag, lexer, parser, ast;

type
  TParserTest = class(TTestCase)
  private
    FDiag: TDiagnostics;
    function ParseProgramFromSource(const src: string): TAstProgram;
  published
    procedure TestParseFunctionSimple;
    procedure TestParseVarLetCoAndAssignPrecedence;
    procedure TestParseConTopLevel;
    // Neue Tests (Phase 2)
    procedure TestParseUnitDecl;
    procedure TestParseImportDecl;
    procedure TestParsePubFn;
    procedure TestParseForLoopTo;
    procedure TestParseForLoopDownto;
    procedure TestParseRepeatUntil;
    procedure TestParseCharLiteral;
    procedure TestParseFieldAccess;
    procedure TestParseIndexAccess;
    procedure TestParseExternDecl; // new
    procedure TestParseVarargsDecl; // varargs support
    // Unary operator tests
    procedure TestParseNestedUnary_LiteralFolding;
    procedure TestParseNestedUnary_NonLiteral;
  private
    function FindMainFunc(const prog: TAstProgram): TAstFuncDecl;
  end;

function TParserTest.FindMainFunc(const prog: TAstProgram): TAstFuncDecl;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(prog.Decls) do
  begin
    if prog.Decls[i] is TAstFuncDecl then
    begin
      if TAstFuncDecl(prog.Decls[i]).Name = 'main' then
      begin
        Result := TAstFuncDecl(prog.Decls[i]);
        Exit;
      end;
    end;
  end;
  if Result = nil then
    raise Exception.Create('main function not found');
end;

function TParserTest.ParseProgramFromSource(const src: string): TAstProgram;
var
  lex: TLexer;
  p: TParser;
begin
  FDiag := TDiagnostics.Create;
  lex := TLexer.Create(src, 'test.lyx', FDiag);
  try
    p := TParser.Create(lex, FDiag);
    try
      Result := p.ParseProgram;
    finally
      p.Free;
    end;
  finally
    lex.Free;
    FDiag.Free;
  end;
end;

procedure TParserTest.TestParseFunctionSimple;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  blk: TAstBlock;
  stmt: TAstStmt;
  exprStmt: TAstExprStmt;
  call: TAstCall;
begin
  prog := ParseProgramFromSource('fn main(): int64 { PrintStr("Hello"); return 0; }');
  try
    // Parser fügt automatisch 'import std.system' hinzu, daher 2 Declarations
    AssertEquals(2, Length(prog.Decls));
    // main ist die zweite Declaration (Index 1)
    AssertTrue(prog.Decls[1] is TAstFuncDecl);
    f := TAstFuncDecl(prog.Decls[1]);
    AssertEquals('main', f.Name);
    AssertTrue(f.ReturnType = atInt64);
    blk := f.Body;
    AssertTrue(Assigned(blk));
    AssertTrue(Length(blk.Stmts) >= 2);
    stmt := blk.Stmts[0];
    AssertTrue(stmt is TAstExprStmt);
    exprStmt := TAstExprStmt(stmt);
    AssertTrue(exprStmt.Expr is TAstCall);
    call := TAstCall(exprStmt.Expr);
    AssertEquals('PrintStr', call.Name);
    AssertEquals(1, Length(call.Args));
    AssertTrue(call.Args[0] is TAstStrLit);
    AssertEquals('Hello', TAstStrLit(call.Args[0]).Value);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseExternDecl;
var
  prog: TAstProgram;
  d: TAstNode;
  f: TAstFuncDecl;
begin
  prog := ParseProgramFromSource('extern fn puts(s: pchar): void; fn main(): int64 { puts("hi"); return 0; }');
  try
    // Expect two declarations: extern puts, and main
    AssertTrue(Length(prog.Decls) >= 2);
    // first decl should be extern func or second depending on ordering
    d := prog.Decls[0];
    if d is TAstFuncDecl then
    begin
      f := TAstFuncDecl(d);
      // ensure extern flag possibly set
      // find any func named 'puts'
      if f.Name <> 'puts' then
      begin
        // scan for puts
        for d in prog.Decls do
          if (d is TAstFuncDecl) and (TAstFuncDecl(d).Name = 'puts') then
          begin
            f := TAstFuncDecl(d); Break;
          end;
      end;
      AssertEquals('puts', f.Name);
      AssertTrue(f.IsExtern);
      AssertTrue(f.Body = nil);
    end;
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseVarLetCoAndAssignPrecedence;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  blk: TAstBlock;
  decl: TAstVarDecl;
  assignStmt: TAstAssign;
  bin: TAstBinOp;
begin
  prog := ParseProgramFromSource('fn main(): int64 { var i: int64 := 0; i := 1 + 2 * 3; return i; }');
  try
    AssertEquals(2, Length(prog.Decls));
    f := FindMainFunc(prog);
    blk := f.Body;
    // first stmt is var decl
    AssertTrue(blk.Stmts[0] is TAstVarDecl);
    decl := TAstVarDecl(blk.Stmts[0]);
    AssertEquals('i', decl.Name);
    // second stmt is assign
    AssertTrue(blk.Stmts[1] is TAstAssign);
    assignStmt := TAstAssign(blk.Stmts[1]);
    // RHS should be BinOp + with nested Mul on right
    AssertTrue(assignStmt.Value is TAstBinOp);
    bin := TAstBinOp(assignStmt.Value);
    AssertTrue(bin.Op = tkPlus);
    AssertTrue(bin.Right is TAstBinOp);
    AssertTrue(TAstBinOp(bin.Right).Op = tkStar);
  finally
    prog.Free;
  end;
end;


procedure TParserTest.TestParseConTopLevel;
var
  prog: TAstProgram;
  c: TAstConDecl;
begin
  prog := ParseProgramFromSource('con X: int64 = 42; fn main(): int64 { return X; }');
  try
    // 3 Declarations: import std.system, con X, fn main
    AssertEquals(3, Length(prog.Decls));
    AssertTrue(prog.Decls[1] is TAstConDecl);
    c := TAstConDecl(prog.Decls[1]);
    AssertEquals('X', c.Name);
  finally
    prog.Free;
  end;
end;

// --- Neue Tests (Phase 2) ---

procedure TParserTest.TestParseUnitDecl;
var
  prog: TAstProgram;
  u: TAstUnitDecl;
begin
  prog := ParseProgramFromSource('unit foo; fn main(): int64 { return 0; }');
  try
    // 3 Declarations: import std.system, unit foo, fn main
    AssertEquals(3, Length(prog.Decls));
    AssertTrue(prog.Decls[1] is TAstUnitDecl);
    u := TAstUnitDecl(prog.Decls[1]);
    AssertEquals('foo', u.UnitPath);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseImportDecl;
var
  prog: TAstProgram;
  imp: TAstImportDecl;
begin
  // Import uses identifier paths (not string literals)
  prog := ParseProgramFromSource('import std.io; fn main(): int64 { return 0; }');
  try
    // 3 Declarations: import std.system, import std.io, fn main
    AssertEquals(3, Length(prog.Decls));
    AssertTrue(prog.Decls[1] is TAstImportDecl);
    imp := TAstImportDecl(prog.Decls[1]);
    AssertEquals('std.io', imp.UnitPath);
    AssertEquals('', imp.Alias);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParsePubFn;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
begin
  // Test that pub fn parses (IsPublic not stored in AST yet)
  prog := ParseProgramFromSource('pub fn main(): int64 { return 0; }');
  try
    // 2 Declarations: import std.system, pub fn main
    AssertEquals(2, Length(prog.Decls));
    AssertTrue(prog.Decls[1] is TAstFuncDecl);
    f := TAstFuncDecl(prog.Decls[1]);
    AssertEquals('main', f.Name);
    // Note: IsPublic is parsed but not stored in AST yet
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseForLoopTo;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  forStmt: TAstFor;
  blk: TAstBlock;
begin
  prog := ParseProgramFromSource('fn main(): int64 { for i := 0 to 5 do { PrintInt(i); } return 0; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstFor);
    forStmt := TAstFor(blk.Stmts[0]);
    AssertEquals('i', forStmt.VarName);
    AssertFalse(forStmt.IsDownto);
    AssertTrue(forStmt.StartExpr is TAstIntLit);
    AssertTrue(forStmt.EndExpr is TAstIntLit);
    AssertTrue(forStmt.Body is TAstBlock);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseForLoopDownto;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  forStmt: TAstFor;
  blk: TAstBlock;
begin
  prog := ParseProgramFromSource('fn main(): int64 { for i := 10 downto 1 do PrintInt(i); return 0; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstFor);
    forStmt := TAstFor(blk.Stmts[0]);
    AssertEquals('i', forStmt.VarName);
    AssertTrue(forStmt.IsDownto);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseRepeatUntil;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  repeatStmt: TAstRepeatUntil;
  blk: TAstBlock;
begin
  prog := ParseProgramFromSource('fn main(): int64 { var x: int64 := 0; repeat { x := x + 1; } until x > 5; return x; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[1] is TAstRepeatUntil);
    repeatStmt := TAstRepeatUntil(blk.Stmts[1]);
    AssertTrue(repeatStmt.Body is TAstBlock);
    AssertTrue(repeatStmt.Cond is TAstBinOp);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseCharLiteral;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  ret: TAstReturn;
  charLit: TAstCharLit;
  blk: TAstBlock;
begin
  prog := ParseProgramFromSource('fn main(): int64 { return ''A''; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstReturn);
    ret := TAstReturn(blk.Stmts[0]);
    AssertTrue(ret.Value is TAstCharLit);
    charLit := TAstCharLit(ret.Value);
    AssertEquals('A', charLit.Value);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseFieldAccess;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  exprStmt: TAstExprStmt;
  fieldAcc: TAstFieldAccess;
  blk: TAstBlock;
  ident: TAstIdent;
begin
  prog := ParseProgramFromSource('fn main(): int64 { PrintInt(obj.field); return 0; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstExprStmt);
    exprStmt := TAstExprStmt(blk.Stmts[0]);
    AssertTrue(exprStmt.Expr is TAstCall);
    // first arg is field access
    AssertTrue(TAstCall(exprStmt.Expr).Args[0] is TAstFieldAccess);
    fieldAcc := TAstFieldAccess(TAstCall(exprStmt.Expr).Args[0]);
    AssertTrue(fieldAcc.Obj is TAstIdent);
    ident := TAstIdent(fieldAcc.Obj);
    AssertEquals('obj', ident.Name);
    AssertEquals('field', fieldAcc.Field);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseIndexAccess;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  exprStmt: TAstExprStmt;
  idxAcc: TAstIndexAccess;
  blk: TAstBlock;
  ident: TAstIdent;
begin
  prog := ParseProgramFromSource('fn main(): int64 { PrintInt(arr[0]); return 0; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstExprStmt);
    exprStmt := TAstExprStmt(blk.Stmts[0]);
    AssertTrue(exprStmt.Expr is TAstCall);
    // first arg is index access
    AssertTrue(TAstCall(exprStmt.Expr).Args[0] is TAstIndexAccess);
    idxAcc := TAstIndexAccess(TAstCall(exprStmt.Expr).Args[0]);
    AssertTrue(idxAcc.Obj is TAstIdent);
    ident := TAstIdent(idxAcc.Obj);
    AssertEquals('arr', ident.Name);
    AssertTrue(idxAcc.Index is TAstIntLit);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseVarargsDecl;
var
  prog: TAstProgram;
  d: TAstNode;
  f: TAstFuncDecl;
begin
  // Test parsing varargs extern function (like printf)
  prog := ParseProgramFromSource('extern fn printf(fmt: pchar, ...): int64; fn main(): int64 { return 0; }');
  try
    // 3 Declarations: import std.system, extern printf, fn main
    AssertTrue('Should have at least one declaration', Length(prog.Decls) >= 1);
    // Find printf function
    f := nil;
    for d in prog.Decls do
      if (d is TAstFuncDecl) and (TAstFuncDecl(d).Name = 'printf') then
      begin
        f := TAstFuncDecl(d);
        Break;
      end;
    AssertTrue('First declaration should be a function', Assigned(f));
    
    AssertEquals('Function name should be printf', 'printf', f.Name);
    AssertTrue('Function should be extern', f.IsExtern);
    AssertTrue('Function should be varargs', f.IsVarArgs);
    AssertTrue('Extern function should have no body', f.Body = nil);
    
    // Check that it has at least one parameter (fmt)
    AssertTrue('Should have at least one parameter', Length(f.Params) >= 1);
    AssertEquals('First parameter should be fmt', 'fmt', f.Params[0].Name);
  finally
    prog.Free;
  end;
end;

// --- New unary operator tests ---

procedure TParserTest.TestParseNestedUnary_LiteralFolding;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  blk: TAstBlock;
begin
  prog := ParseProgramFromSource('fn main(): int64 { return --5; }');
  try
    f := FindMainFunc(prog);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstReturn);
    AssertTrue(TAstReturn(blk.Stmts[0]).Value is TAstIntLit);
    AssertEquals(5, TAstIntLit(TAstReturn(blk.Stmts[0]).Value).Value);
  finally
    prog.Free;
  end;

  prog := ParseProgramFromSource('fn main(): int64 { return !!true; }');
  try
    f := FindMainFunc(prog);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstReturn);
    AssertTrue(TAstReturn(blk.Stmts[0]).Value is TAstBoolLit);
    AssertEquals(True, TAstBoolLit(TAstReturn(blk.Stmts[0]).Value).Value);
  finally
    prog.Free;
  end;
end;

procedure TParserTest.TestParseNestedUnary_NonLiteral;
var
  prog: TAstProgram;
  f: TAstFuncDecl;
  blk: TAstBlock;
  retExpr: TAstExpr;
begin
  prog := ParseProgramFromSource('fn main(): int64 { var x: int64 := 1; return --x; }');
  try
    f := TAstFuncDecl(prog.Decls[0]);
    blk := f.Body;
    AssertTrue(blk.Stmts[0] is TAstVarDecl);
    AssertTrue(blk.Stmts[1] is TAstReturn);
    retExpr := TAstReturn(blk.Stmts[1]).Value;
    AssertTrue(retExpr is TAstUnaryOp);
    AssertTrue(TAstUnaryOp(retExpr).Operand is TAstUnaryOp);
    AssertTrue(TAstUnaryOp(retExpr).Op = tkMinus);
    AssertTrue(TAstUnaryOp(TAstUnaryOp(retExpr).Operand).Op = tkMinus);
    AssertTrue(TAstUnaryOp(TAstUnaryOp(retExpr).Operand).Operand is TAstIdent);
  finally
    prog.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TParserTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
