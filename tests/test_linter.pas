{$mode objfpc}{$H+}
program test_linter;

uses
  SysUtils,
  fpcunit, testregistry, consoletestrunner,
  diag, lexer, parser, ast, sema, linter;

type
  TLinterTest = class(TTestCase)
  private
    { Hilfsfunktion: Parst + Sema + Lint und gibt Diagnostik zurück }
    function LintSource(const src: string): TDiagnostics;
    function LintSourceWith(const src: string;
      rules: TLintRuleIdSet): TDiagnostics;
    { Zählt Warnungen mit bestimmtem Regelcode }
    function CountWarningsWithCode(d: TDiagnostics;
      const code: string): Integer;
  published
    { W001: Ungenutzte Variablen }
    procedure TestUnusedVariable;
    procedure TestUsedVariableNoWarning;
    procedure TestUnderscoreIgnored;

    { W002: Ungenutzte Parameter }
    procedure TestUnusedParameter;
    procedure TestUsedParameterNoWarning;

    { W003: Variable Naming (camelCase) }
    procedure TestVariableNamingBad;
    procedure TestVariableNamingGood;

    { W004: Function Naming (PascalCase) }
    procedure TestFunctionNamingBad;
    procedure TestFunctionNamingGood;
    procedure TestMainExempt;

    { W005: Constant Naming }
    procedure TestConstantNamingBad;
    procedure TestConstantNamingGood;

    { W006: Unerreichbarer Code }
    procedure TestUnreachableCode;
    procedure TestNoUnreachableCode;

    { W007: Leere Blöcke }
    procedure TestEmptyBlock;

    { W008: Shadowing }
    procedure TestShadowedVariable;
    procedure TestNoShadowingDifferentNames;

    { W009: var nie mutiert }
    procedure TestMutableNeverMutated;
    procedure TestMutableMutatedNoWarning;
    procedure TestLetNoWarning;

    { Mehrere Regeln zusammen }
    procedure TestMultipleWarnings;
    procedure TestCleanCodeNoWarnings;

    { Regel-Deaktivierung }
    procedure TestDisabledRule;
  end;

{ === Hilfsfunktionen === }

function TLinterTest.LintSource(const src: string): TDiagnostics;
begin
  Result := LintSourceWith(src, DefaultLintRules);
end;

function TLinterTest.LintSourceWith(const src: string;
  rules: TLintRuleIdSet): TDiagnostics;
var
  d: TDiagnostics;
  lx: TLexer;
  p: TParser;
  prog: TAstProgram;
  s: TSema;
  l: TLinter;
begin
  d := TDiagnostics.Create;
  lx := TLexer.Create(src, 'test.lyx', d);
  try
    p := TParser.Create(lx, d);
    try
      prog := p.ParseProgram;
    finally
      p.Free;
    end;
  finally
    lx.Free;
  end;

  { Sema muss vorher laufen (Typ-Auflösung) }
  s := TSema.Create(d);
  try
    s.Analyze(prog);
  finally
    s.Free;
  end;

  { Jetzt Linter }
  l := TLinter.Create(d);
  try
    l.ActiveRules := rules;
    l.Lint(prog);
  finally
    l.Free;
  end;

  prog.Free;
  Result := d;
end;

function TLinterTest.CountWarningsWithCode(d: TDiagnostics;
  const code: string): Integer;
var
  i: Integer;
  e: TDiagEntry;
begin
  Result := 0;
  for i := 0 to d.Count - 1 do
  begin
    e := d.GetEntry(i);
    if (e.Kind = dkWarning) and (Pos(code, e.Msg) > 0) then
      Inc(Result);
  end;
end;

{ === W001: Ungenutzte Variablen === }

procedure TLinterTest.TestUnusedVariable;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 42; return 0; }');
  try
    AssertTrue('should have W001 warning',
      CountWarningsWithCode(d, 'W001') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestUsedVariableNoWarning;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 42; return x; }');
  try
    AssertEquals('should have no W001 warning', 0,
      CountWarningsWithCode(d, 'W001'));
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestUnderscoreIgnored;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var _: int64 := 42; return 0; }');
  try
    AssertEquals('underscore variable should not warn', 0,
      CountWarningsWithCode(d, 'W001'));
  finally
    d.Free;
  end;
end;

{ === W002: Ungenutzte Parameter === }

procedure TLinterTest.TestUnusedParameter;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn Add(a: int64, b: int64): int64 { return a; }' +
    ' fn main(): int64 { return Add(1, 2); }');
  try
    AssertTrue('should have W002 for unused param b',
      CountWarningsWithCode(d, 'W002') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestUsedParameterNoWarning;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn Add(a: int64, b: int64): int64 { return a + b; }' +
    ' fn main(): int64 { return Add(1, 2); }');
  try
    AssertEquals('all params used - no W002', 0,
      CountWarningsWithCode(d, 'W002'));
  finally
    d.Free;
  end;
end;

{ === W003: Variable Naming === }

procedure TLinterTest.TestVariableNamingBad;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var BadName: int64 := 1; return BadName; }');
  try
    AssertTrue('should have W003 for BadName',
      CountWarningsWithCode(d, 'W003') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestVariableNamingGood;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var goodName: int64 := 1; return goodName; }');
  try
    AssertEquals('camelCase should not warn', 0,
      CountWarningsWithCode(d, 'W003'));
  finally
    d.Free;
  end;
end;

{ === W004: Function Naming === }

procedure TLinterTest.TestFunctionNamingBad;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn bad_func(): int64 { return 0; }' +
    ' fn main(): int64 { return bad_func(); }');
  try
    AssertTrue('should have W004 for bad_func',
      CountWarningsWithCode(d, 'W004') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestFunctionNamingGood;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn GoodFunc(): int64 { return 0; }' +
    ' fn main(): int64 { return GoodFunc(); }');
  try
    AssertEquals('PascalCase should not warn', 0,
      CountWarningsWithCode(d, 'W004'));
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestMainExempt;
var
  d: TDiagnostics;
begin
  d := LintSource('fn main(): int64 { return 0; }');
  try
    AssertEquals('main should be exempt from naming', 0,
      CountWarningsWithCode(d, 'W004'));
  finally
    d.Free;
  end;
end;

{ === W005: Constant Naming === }

procedure TLinterTest.TestConstantNamingBad;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'con myConst: int64 := 42;' +
    ' fn main(): int64 { return myConst; }');
  try
    AssertTrue('should have W005 for myConst',
      CountWarningsWithCode(d, 'W005') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestConstantNamingGood;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'con MAX_SIZE: int64 := 42;' +
    ' fn main(): int64 { return MAX_SIZE; }');
  try
    AssertEquals('UPPER_CASE should not warn', 0,
      CountWarningsWithCode(d, 'W005'));
  finally
    d.Free;
  end;
end;

{ === W006: Unerreichbarer Code === }

procedure TLinterTest.TestUnreachableCode;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { return 0; var x: int64 := 1; }');
  try
    AssertTrue('should have W006 unreachable',
      CountWarningsWithCode(d, 'W006') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestNoUnreachableCode;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 1; return x; }');
  try
    AssertEquals('no unreachable code', 0,
      CountWarningsWithCode(d, 'W006'));
  finally
    d.Free;
  end;
end;

{ === W007: Leere Blöcke === }

procedure TLinterTest.TestEmptyBlock;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 1;' +
    ' if (x == 1) { } return x; }');
  try
    AssertTrue('should have W007 empty block',
      CountWarningsWithCode(d, 'W007') >= 1);
  finally
    d.Free;
  end;
end;

{ === W008: Shadowing === }

procedure TLinterTest.TestShadowedVariable;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 1;' +
    ' if (x == 1) { var x: int64 := 2; return x; } return x; }');
  try
    AssertTrue('should have W008 shadow',
      CountWarningsWithCode(d, 'W008') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestNoShadowingDifferentNames;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 1;' +
    ' if (x == 1) { var y: int64 := 2; return y; } return x; }');
  try
    AssertEquals('different names should not shadow', 0,
      CountWarningsWithCode(d, 'W008'));
  finally
    d.Free;
  end;
end;

{ === W009: var nie mutiert === }

procedure TLinterTest.TestMutableNeverMutated;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 42; return x; }');
  try
    AssertTrue('should have W009 mutable-never-mutated',
      CountWarningsWithCode(d, 'W009') >= 1);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestMutableMutatedNoWarning;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { var x: int64 := 0; x := 42; return x; }');
  try
    AssertEquals('mutated var should not warn', 0,
      CountWarningsWithCode(d, 'W009'));
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestLetNoWarning;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn main(): int64 { let x: int64 := 42; return x; }');
  try
    AssertEquals('let should not trigger W009', 0,
      CountWarningsWithCode(d, 'W009'));
  finally
    d.Free;
  end;
end;

{ === Mehrere Regeln === }

procedure TLinterTest.TestMultipleWarnings;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn bad_fn(): int64 {' +       // W004: naming
    ' var Unused: int64 := 1;' +    // W001: unused + W003: naming + W009: mutable
    ' return 0; }' +
    ' fn main(): int64 { return bad_fn(); }');
  try
    AssertTrue('should have multiple warnings',
      d.WarningCount >= 3);
  finally
    d.Free;
  end;
end;

procedure TLinterTest.TestCleanCodeNoWarnings;
var
  d: TDiagnostics;
begin
  d := LintSource(
    'fn Add(a: int64, b: int64): int64 { return a + b; }' +
    ' fn main(): int64 { let result: int64 := Add(1, 2);' +
    ' return result; }');
  try
    AssertEquals('clean code should have no warnings', 0,
      d.WarningCount);
  finally
    d.Free;
  end;
end;

{ === Regel-Deaktivierung === }

procedure TLinterTest.TestDisabledRule;
var
  d: TDiagnostics;
begin
  { Nur W001 aktiv, W009 deaktiviert }
  d := LintSourceWith(
    'fn main(): int64 { var x: int64 := 42; return 0; }',
    [lrUnusedVariable]);
  try
    AssertTrue('should have W001', CountWarningsWithCode(d, 'W001') >= 1);
    AssertEquals('W009 should be disabled', 0,
      CountWarningsWithCode(d, 'W009'));
  finally
    d.Free;
  end;
end;

var
  app: TTestRunner;
begin
  RegisterTest(TLinterTest);
  app := TTestRunner.Create(nil);
  try
    app.Run;
  finally
    app.Free;
  end;
end.
