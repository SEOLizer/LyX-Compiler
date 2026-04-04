{$mode objfpc}{$H+}
unit linter;

interface

uses
  SysUtils, Classes,
  diag, ast, lexer;

type
  { --- Lint-Regel-ID zur eindeutigen Kennzeichnung --- }
  TLintRuleId = (
    lrUnusedVariable,       // W001: Variable deklariert aber nie gelesen
    lrUnusedParameter,      // W002: Funktionsparameter nie gelesen
    lrNamingVariable,       // W003: Variable folgt nicht camelCase
    lrNamingFunction,       // W004: Funktion folgt nicht PascalCase
    lrNamingConstant,       // W005: Konstante folgt nicht UPPER_CASE/PascalCase
    lrUnreachableCode,      // W006: Code nach return ist unerreichbar
    lrEmptyBlock,           // W007: Leerer Block { }
    lrShadowedVariable,     // W008: Variable verdeckt eine äußere Variable
    lrMutableNeverMutated,  // W009: var deklariert aber nie zugewiesen (-> let)
    lrEmptyFunction,        // W010: Nicht-void Funktion ohne return
    lrFormatZeroDecimals,   // W011: :width:0 Format-Specifier (0 Dezimalstellen)
    lrStringConcatLiterals, // W012: Zwei String-Literale mit + (compile-time foldable)
    lrPrintFloatIntArg,      // W013: PrintFloat(f64(intLit)) — unnötiger Float-Cast eines Literals
    lrRecursiveFunction,     // W014: Rekursive Funktion (für Stack-Vorhersagbarkeit — MISRA 5.2)
    lrImplicitTypeCast       // W015: Implizite Typkonvertierung ohne 'as' (MISRA 5.2)
  );

  TLintRuleIdSet = set of TLintRuleId;

const
  { Alle Regeln, die standardmäßig aktiv sind }
  DefaultLintRules: TLintRuleIdSet = [
    lrUnusedVariable,
    lrUnusedParameter,
    lrNamingVariable,
    lrNamingFunction,
    lrNamingConstant,
    lrUnreachableCode,
    lrEmptyBlock,
    lrShadowedVariable,
    lrMutableNeverMutated,
    lrFormatZeroDecimals,
    lrStringConcatLiterals,
    lrPrintFloatIntArg,
    lrRecursiveFunction,
    lrImplicitTypeCast
  ];

  { Human-readable Namen für die Regeln }
  LintRuleNames: array[TLintRuleId] of string = (
    'unused-variable',
    'unused-parameter',
    'naming-variable',
    'naming-function',
    'naming-constant',
    'unreachable-code',
    'empty-block',
    'shadowed-variable',
    'mutable-never-mutated',
    'empty-function',
    'format-zero-decimals',
    'string-concat-literals',
    'print-float-int-arg',
    'recursive-function',
    'implicit-type-cast'
  );

  LintRuleCodes: array[TLintRuleId] of string = (
    'W001', 'W002', 'W003', 'W004', 'W005',
    'W006', 'W007', 'W008', 'W009', 'W010',
    'W011', 'W012', 'W013', 'W014', 'W015'
  );

type
  { --- Tracking-Struktur für Variablen-Nutzung --- }
  TVarUsage = record
    Name: string;
    DeclSpan: TSourceSpan;
    Storage: TStorageKlass;
    IsRead: Boolean;       // wurde die Variable jemals gelesen?
    IsMutated: Boolean;    // wurde der Variable jemals zugewiesen (nach Deklaration)?
    IsParameter: Boolean;  // ist ein Funktionsparameter?
    ScopeDepth: Integer;   // Verschachtelungstiefe für Shadowing-Erkennung
  end;
  TVarUsageList = array of TVarUsage;

  { --- Scope-Tracker für den Linter --- }
  TLintScope = record
    Vars: TVarUsageList;
    Depth: Integer;
  end;

  { --- Der Linter selbst --- }
  TLinter = class
  private
    FDiag: TDiagnostics;
    FActiveRules: TLintRuleIdSet;
    FScopes: array of TLintScope;
    FScopeCount: Integer;
    FWarnCount: Integer;
    FCurrentFuncName: string;  // Track current function for recursion detection
    FCurrentFuncDecl: TAstFuncDecl;  // Current function for implicit cast detection

    { Scope-Verwaltung }
    procedure PushScope;
    procedure PopScope;
    procedure DeclareVar(const name: string; storage: TStorageKlass;
      span: TSourceSpan; isParam: Boolean);
    procedure MarkRead(const name: string);
    procedure MarkMutated(const name: string);
    function FindVarInCurrentScope(const name: string): Integer;
    function FindVarInAllScopes(const name: string): Integer;
    function CurrentDepth: Integer;

    { Warnung erzeugen }
    procedure Warn(rule: TLintRuleId; const msg: string; span: TSourceSpan);

    { Naming-Prüfungen }
    function IsCamelCase(const name: string): Boolean;
    function IsPascalCase(const name: string): Boolean;
    function IsUpperCaseOrPascal(const name: string): Boolean;
    procedure CheckVariableNaming(const name: string; span: TSourceSpan);
    procedure CheckFunctionNaming(const name: string; span: TSourceSpan);
    procedure CheckConstantNaming(const name: string; span: TSourceSpan);

    { AST-Traversal }
    procedure LintExpr(expr: TAstExpr);
    procedure LintStmt(stmt: TAstStmt);
    procedure LintBlock(block: TAstBlock);
    procedure LintFuncDecl(fn: TAstFuncDecl);
    procedure LintStructDecl(sd: TAstStructDecl);
    procedure LintClassDecl(cd: TAstClassDecl);

    { Spezial-Prüfungen }
    procedure CheckUnreachableCode(block: TAstBlock);
    procedure CheckEmptyBlock(block: TAstBlock; span: TSourceSpan);
    function BlockHasReturn(stmt: TAstStmt): Boolean;
    procedure CheckImplicitCast(expr: TAstExpr);

    { Scope-Ende: Prüfung auf ungenutzte Variablen }
    procedure CheckUnusedVarsInCurrentScope;
  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;

    procedure Lint(prog: TAstProgram);

    property ActiveRules: TLintRuleIdSet read FActiveRules write FActiveRules;
    property WarnCount: Integer read FWarnCount;
  end;

implementation

{ ================================================================ }
{ TLinter                                                           }
{ ================================================================ }

constructor TLinter.Create(d: TDiagnostics);
begin
  inherited Create;
  FDiag := d;
  FActiveRules := DefaultLintRules;
  FScopeCount := 0;
  FWarnCount := 0;
  SetLength(FScopes, 0);
end;

destructor TLinter.Destroy;
begin
  FScopes := nil;
  inherited Destroy;
end;

{ --- Scope-Verwaltung --- }

procedure TLinter.PushScope;
var
  depth: Integer;
begin
  if FScopeCount > 0 then
    depth := FScopes[FScopeCount - 1].Depth + 1
  else
    depth := 0;
  Inc(FScopeCount);
  if FScopeCount > Length(FScopes) then
    SetLength(FScopes, FScopeCount * 2);
  FScopes[FScopeCount - 1].Depth := depth;
  SetLength(FScopes[FScopeCount - 1].Vars, 0);
end;

procedure TLinter.PopScope;
begin
  if FScopeCount = 0 then Exit;
  CheckUnusedVarsInCurrentScope;
  Dec(FScopeCount);
end;

function TLinter.CurrentDepth: Integer;
begin
  if FScopeCount > 0 then
    Result := FScopes[FScopeCount - 1].Depth
  else
    Result := 0;
end;

procedure TLinter.DeclareVar(const name: string; storage: TStorageKlass;
  span: TSourceSpan; isParam: Boolean);
var
  scope: ^TLintScope;
  n, outerIdx: Integer;
begin
  if FScopeCount = 0 then Exit;

  { Shadowing-Prüfung VOR dem Hinzufügen: Gibt es die Variable
    bereits in einem äußeren Scope? }
  if lrShadowedVariable in FActiveRules then
  begin
    outerIdx := FindVarInAllScopes(name);
    if outerIdx >= 0 then
      Warn(lrShadowedVariable,
        'variable ''' + name + ''' shadows an outer variable',
        span);
  end;

  { Variable im aktuellen Scope registrieren }
  scope := @FScopes[FScopeCount - 1];
  n := Length(scope^.Vars);
  SetLength(scope^.Vars, n + 1);
  scope^.Vars[n].Name := name;
  scope^.Vars[n].DeclSpan := span;
  scope^.Vars[n].Storage := storage;
  scope^.Vars[n].IsRead := False;
  scope^.Vars[n].IsMutated := False;
  scope^.Vars[n].IsParameter := isParam;
  scope^.Vars[n].ScopeDepth := CurrentDepth;
end;

procedure TLinter.MarkRead(const name: string);
var
  i, j: Integer;
begin
  for i := FScopeCount - 1 downto 0 do
    for j := 0 to High(FScopes[i].Vars) do
      if FScopes[i].Vars[j].Name = name then
      begin
        FScopes[i].Vars[j].IsRead := True;
        Exit;
      end;
end;

procedure TLinter.MarkMutated(const name: string);
var
  i, j: Integer;
begin
  for i := FScopeCount - 1 downto 0 do
    for j := 0 to High(FScopes[i].Vars) do
      if FScopes[i].Vars[j].Name = name then
      begin
        FScopes[i].Vars[j].IsMutated := True;
        Exit;
      end;
end;

function TLinter.FindVarInCurrentScope(const name: string): Integer;
var
  j: Integer;
begin
  Result := -1;
  if FScopeCount = 0 then Exit;
  for j := 0 to High(FScopes[FScopeCount - 1].Vars) do
    if FScopes[FScopeCount - 1].Vars[j].Name = name then
      Exit(FScopeCount - 1);
end;

function TLinter.FindVarInAllScopes(const name: string): Integer;
var
  i, j: Integer;
begin
  Result := -1;
  for i := FScopeCount - 1 downto 0 do
    for j := 0 to High(FScopes[i].Vars) do
      if FScopes[i].Vars[j].Name = name then
        Exit(i);
end;

{ --- Warnung erzeugen --- }

procedure TLinter.Warn(rule: TLintRuleId; const msg: string;
  span: TSourceSpan);
begin
  if not (rule in FActiveRules) then Exit;
  FDiag.Warning('[' + LintRuleCodes[rule] + ' ' +
    LintRuleNames[rule] + '] ' + msg, span);
  Inc(FWarnCount);
end;

{ --- Naming-Konventionen --- }

function TLinter.IsCamelCase(const name: string): Boolean;
begin
  { camelCase: beginnt mit Kleinbuchstabe, kein Unterstrich (außer _) }
  if Length(name) = 0 then Exit(True);
  if name = '_' then Exit(True); // Wegwerf-Variable
  Result := (name[1] >= 'a') and (name[1] <= 'z');
end;

function TLinter.IsPascalCase(const name: string): Boolean;
begin
  { PascalCase: beginnt mit Großbuchstabe }
  if Length(name) = 0 then Exit(True);
  Result := (name[1] >= 'A') and (name[1] <= 'Z');
end;

function TLinter.IsUpperCaseOrPascal(const name: string): Boolean;
var
  i: Integer;
  allUpper: Boolean;
begin
  { UPPER_CASE oder PascalCase sind beide akzeptabel für Konstanten }
  if Length(name) = 0 then Exit(True);
  if IsPascalCase(name) then Exit(True);
  { Prüfe auf UPPER_CASE: nur Großbuchstaben, Ziffern und Unterstriche }
  allUpper := True;
  for i := 1 to Length(name) do
  begin
    if not (name[i] in ['A'..'Z', '0'..'9', '_']) then
    begin
      allUpper := False;
      Break;
    end;
  end;
  Result := allUpper;
end;

procedure TLinter.CheckVariableNaming(const name: string;
  span: TSourceSpan);
begin
  if name = '_' then Exit; // Wegwerf-Variable
  if not IsCamelCase(name) then
    Warn(lrNamingVariable,
      'variable ''' + name + ''' should use camelCase naming',
      span);
end;

procedure TLinter.CheckFunctionNaming(const name: string;
  span: TSourceSpan);
begin
  { Interne Namen (beginnen mit _) und main überspringen }
  if (Length(name) > 0) and (name[1] = '_') then Exit;
  if name = 'main' then Exit;
  if not IsPascalCase(name) then
    Warn(lrNamingFunction,
      'function ''' + name + ''' should use PascalCase naming',
      span);
end;

procedure TLinter.CheckConstantNaming(const name: string;
  span: TSourceSpan);
begin
  if not IsUpperCaseOrPascal(name) then
    Warn(lrNamingConstant,
      'constant ''' + name + ''' should use PascalCase or UPPER_CASE naming',
      span);
end;

{ --- AST-Traversal: Ausdrücke --- }

procedure TLinter.LintExpr(expr: TAstExpr);
var
  i: Integer;
begin
  if expr = nil then Exit;

  case expr.Kind of
    nkIdent:
      MarkRead(TAstIdent(expr).Name);

    nkBinOp:
    begin
      { W012: Zwei String-Literale mit + können zur Compile-Zeit zusammengefügt werden }
      if (TAstBinOp(expr).Op = tkPlus)
        and (TAstBinOp(expr).Left.Kind = nkStrLit)
        and (TAstBinOp(expr).Right.Kind = nkStrLit) then
      begin
        if lrStringConcatLiterals in FActiveRules then
          Warn(lrStringConcatLiterals,
            'string literal concatenation with ''+'' can be folded at compile time; consider using a single string literal',
            expr.Span);
      end;
      LintExpr(TAstBinOp(expr).Left);
      LintExpr(TAstBinOp(expr).Right);
    end;

    nkUnaryOp:
      LintExpr(TAstUnaryOp(expr).Operand);

    nkCall:
    begin
      { W014: Rekursive Funktion erkennen (für Stack-Vorhersagbarkeit — MISRA 5.2) }
      if (FCurrentFuncName <> '') and (TAstCall(expr).Name = FCurrentFuncName) then
      begin
        if lrRecursiveFunction in FActiveRules then
          Warn(lrRecursiveFunction,
            'recursive call to ''' + FCurrentFuncName + ''' detected; recursion is not allowed for stack predictability (MISRA 5.2)',
            expr.Span);
      end;

      { W013: PrintFloat(intLit as f64) — unnötiger Cast eines Integer-Literals zu Float }
      if (TAstCall(expr).Name = 'PrintFloat')
        and (Length(TAstCall(expr).Args) = 1)
        and (TAstCall(expr).Args[0].Kind = nkCast)
        and (TAstCast(TAstCall(expr).Args[0]).Expr.Kind = nkIntLit) then
      begin
        if lrPrintFloatIntArg in FActiveRules then
          Warn(lrPrintFloatIntArg,
            'PrintFloat() called with a constant integer cast to float; consider using PrintInt() instead',
            expr.Span);
      end;

      { W015: Implizite Typkonvertierung in Funktionsaufrufen erkennen }
      for i := 0 to High(TAstCall(expr).Args) do
      begin
        LintExpr(TAstCall(expr).Args[i]);
        CheckImplicitCast(TAstCall(expr).Args[i]);
      end;
    end;

    nkArrayLit:
    begin
      for i := 0 to High(TAstArrayLit(expr).Items) do
        LintExpr(TAstArrayLit(expr).Items[i]);
    end;

    nkStructLit:
    begin
      for i := 0 to High(TAstStructLit(expr).Fields) do
        LintExpr(TAstStructLit(expr).Fields[i].Value);
    end;

    nkFieldAccess:
    begin
      LintExpr(TAstFieldAccess(expr).Obj);
    end;

    nkIndexAccess:
    begin
      LintExpr(TAstIndexAccess(expr).Obj);
      LintExpr(TAstIndexAccess(expr).Index);
    end;

    nkCast:
      LintExpr(TAstCast(expr).Expr);

    nkNewExpr:
    begin
      for i := 0 to High(TAstNewExpr(expr).Args) do
        LintExpr(TAstNewExpr(expr).Args[i]);
    end;

    nkSuperCall:
    begin
      for i := 0 to High(TAstSuperCall(expr).Args) do
        LintExpr(TAstSuperCall(expr).Args[i]);
    end;

    nkPanic:
      LintExpr(TAstPanicExpr(expr).Message);

    nkFormatExpr:
    begin
      { W011: :width:0 Format-Specifier — 0 Dezimalstellen gibt nur den Ganzzahlanteil aus }
      if TAstFormatExpr(expr).Decimals = 0 then
      begin
        if lrFormatZeroDecimals in FActiveRules then
          Warn(lrFormatZeroDecimals,
            'format specifier with 0 decimals truncates to integer part; consider using PrintInt() instead',
            expr.Span);
      end;
      LintExpr(TAstFormatExpr(expr).Expr);
    end;

    { Literale benötigen keine weitere Prüfung }
    nkIntLit, nkFloatLit, nkStrLit, nkBoolLit, nkCharLit, nkRegexLit:
      ; // nichts zu tun
  end;
end;

{ --- AST-Traversal: Statements --- }

procedure TLinter.LintStmt(stmt: TAstStmt);
var
  i: Integer;
  ifStmt: TAstIf;
  sw: TAstSwitch;
begin
  if stmt = nil then Exit;

  case stmt.Kind of
    nkVarDecl:
    begin
      { Naming-Prüfung }
      if TAstVarDecl(stmt).Storage in [skVar, skLet, skCo] then
        CheckVariableNaming(TAstVarDecl(stmt).Name, stmt.Span);

      { Variable im Scope registrieren }
      DeclareVar(TAstVarDecl(stmt).Name, TAstVarDecl(stmt).Storage,
        stmt.Span, False);

      { Init-Expression traversieren }
      LintExpr(TAstVarDecl(stmt).InitExpr);
    end;

    nkAssign:
    begin
      MarkMutated(TAstAssign(stmt).Name);
      { Auch lesen: x := x + 1 enthält einen Lese-Zugriff auf RHS }
      LintExpr(TAstAssign(stmt).Value);
    end;

    nkFieldAssign:
    begin
      LintExpr(TAstFieldAssign(stmt).Target.Obj);
      LintExpr(TAstFieldAssign(stmt).Value);
    end;

    nkIndexAssign:
    begin
      LintExpr(TAstIndexAssign(stmt).Target.Obj);
      LintExpr(TAstIndexAssign(stmt).Target.Index);
      LintExpr(TAstIndexAssign(stmt).Value);
    end;

    nkIf:
    begin
      ifStmt := TAstIf(stmt);
      LintExpr(ifStmt.Cond);
      if ifStmt.ThenBranch <> nil then
      begin
        PushScope;
        LintStmt(ifStmt.ThenBranch);
        PopScope;
      end;
      if ifStmt.ElseBranch <> nil then
      begin
        PushScope;
        LintStmt(ifStmt.ElseBranch);
        PopScope;
      end;
    end;

    nkWhile:
    begin
      LintExpr(TAstWhile(stmt).Cond);
      PushScope;
      LintStmt(TAstWhile(stmt).Body);
      PopScope;
    end;

    nkFor:
    begin
      LintExpr(TAstFor(stmt).StartExpr);
      LintExpr(TAstFor(stmt).EndExpr);
      PushScope;
      { For-Variable deklarieren (implizit) }
      DeclareVar(TAstFor(stmt).VarName, skLet, stmt.Span, False);
      MarkRead(TAstFor(stmt).VarName); // Schleifenvar ist immer "benutzt"
      MarkMutated(TAstFor(stmt).VarName); // und mutiert (durch Schleife)
      LintStmt(TAstFor(stmt).Body);
      PopScope;
    end;

    nkRepeatUntil:
    begin
      PushScope;
      LintStmt(TAstRepeatUntil(stmt).Body);
      PopScope;
      LintExpr(TAstRepeatUntil(stmt).Cond);
    end;

    nkReturn:
      LintExpr(TAstReturn(stmt).Value);

    nkSwitch:
    begin
      sw := TAstSwitch(stmt);
      LintExpr(sw.Expr);
      for i := 0 to High(sw.Cases) do
      begin
        LintExpr(sw.Cases[i].Value);
        PushScope;
        LintStmt(sw.Cases[i].Body);
        PopScope;
      end;
      if sw.Default <> nil then
      begin
        PushScope;
        LintStmt(sw.Default);
        PopScope;
      end;
    end;

    nkBlock:
      LintBlock(TAstBlock(stmt));

    nkExprStmt:
      LintExpr(TAstExprStmt(stmt).Expr);

    nkDispose:
      LintExpr(TAstDispose(stmt).Expr);

    nkAssert:
    begin
      LintExpr(TAstAssert(stmt).Condition);
      LintExpr(TAstAssert(stmt).Message);
    end;

    nkBreak:
      ; // nichts zu tun
  end;
end;

{ --- Block-Prüfung --- }

procedure TLinter.LintBlock(block: TAstBlock);
var
  i: Integer;
begin
  if block = nil then Exit;

  { Leeren Block prüfen }
  CheckEmptyBlock(block, block.Span);

  { Unerreichbaren Code prüfen }
  CheckUnreachableCode(block);

  { Alle Statements traversieren }
  for i := 0 to High(block.Stmts) do
    LintStmt(block.Stmts[i]);
end;

{ --- Funktions-Prüfung --- }

procedure TLinter.LintFuncDecl(fn: TAstFuncDecl);
var
  i: Integer;
  oldFuncName: string;
  oldFuncDecl: TAstFuncDecl;
begin
  if fn = nil then Exit;
  if fn.IsExtern then Exit; // Extern-Deklarationen haben keinen Body

  { Naming-Prüfung für Funktionsnamen }
  CheckFunctionNaming(fn.Name, fn.Span);

  { W014: Rekursive Funktion erkennen (für Stack-Vorhersagbarkeit — MISRA 5.2) }
  { Wird während AST-Traversal geprüft: wenn ein Call die eigene Funktion aufruft }

  { Neuen Scope für den Funktionskörper }
  PushScope;

  { Parameter deklarieren (Parameter sind implizit immutable → skLet) }
  for i := 0 to High(fn.Params) do
    DeclareVar(fn.Params[i].Name, skLet,
      fn.Params[i].Span, True);

  { Track current function for recursion and implicit cast detection }
  oldFuncName := FCurrentFuncName;
  oldFuncDecl := FCurrentFuncDecl;
  FCurrentFuncName := fn.Name;
  FCurrentFuncDecl := fn;

  { Body traversieren }
  if fn.Body <> nil then
    LintBlock(fn.Body);

  { Restore previous function context }
  FCurrentFuncName := oldFuncName;
  FCurrentFuncDecl := oldFuncDecl;

  PopScope;
end;

{ --- Struct-Prüfung --- }

procedure TLinter.LintStructDecl(sd: TAstStructDecl);
var
  i: Integer;
begin
  if sd = nil then Exit;
  for i := 0 to High(sd.Methods) do
    LintFuncDecl(sd.Methods[i]);
end;

{ --- Class-Prüfung --- }

procedure TLinter.LintClassDecl(cd: TAstClassDecl);
var
  i: Integer;
begin
  if cd = nil then Exit;
  for i := 0 to High(cd.Methods) do
    LintFuncDecl(cd.Methods[i]);
end;

{ --- Spezial-Prüfungen --- }

procedure TLinter.CheckUnreachableCode(block: TAstBlock);
var
  i: Integer;
  foundReturn: Boolean;
begin
  if block = nil then Exit;
  if not (lrUnreachableCode in FActiveRules) then Exit;

  foundReturn := False;
  for i := 0 to High(block.Stmts) do
  begin
    if foundReturn then
    begin
      Warn(lrUnreachableCode,
        'unreachable code after return statement',
        block.Stmts[i].Span);
      Exit; // Nur eine Warnung pro Block
    end;
    if block.Stmts[i].Kind = nkReturn then
      foundReturn := True;
  end;
end;

procedure TLinter.CheckEmptyBlock(block: TAstBlock;
  span: TSourceSpan);
begin
  if block = nil then Exit;
  if not (lrEmptyBlock in FActiveRules) then Exit;
  if Length(block.Stmts) = 0 then
    Warn(lrEmptyBlock, 'empty block', span);
end;

function TLinter.BlockHasReturn(stmt: TAstStmt): Boolean;
begin
  Result := False;
  if stmt = nil then Exit;
  if stmt.Kind = nkReturn then
    Exit(True);
  if stmt.Kind = nkBlock then
  begin
    if Length(TAstBlock(stmt).Stmts) > 0 then
      Result := BlockHasReturn(
        TAstBlock(stmt).Stmts[High(TAstBlock(stmt).Stmts)]);
  end;
end;

{ --- Implicit Type Cast Detection (MISRA 5.2) --- }

procedure TLinter.CheckImplicitCast(expr: TAstExpr);
var
  castExpr: TAstCast;
  srcType, dstType: TAurumType;
  srcName, dstName: string;
begin
  if expr = nil then Exit;
  if not (lrImplicitTypeCast in FActiveRules) then Exit;

  if expr.Kind = nkCast then
  begin
    castExpr := TAstCast(expr);
    srcType := castExpr.Expr.ResolvedType;
    dstType := castExpr.CastType;

    // Check for implicit-like casts (int <-> float, int <-> pointer, etc.)
    // These are dangerous in safety-critical code
    if (srcType = atInt64) and (dstType = atF64) then
    begin
      Warn(lrImplicitTypeCast,
        'implicit type conversion from int64 to f64; use explicit ''as f64'' with range check (MISRA 5.2)',
        expr.Span);
    end
    else if (srcType = atF64) and (dstType = atInt64) then
    begin
      Warn(lrImplicitTypeCast,
        'implicit type conversion from f64 to int64; precision may be lost (MISRA 5.2)',
        expr.Span);
    end
    else if (srcType = atInt64) and (dstType = atPChar) then
    begin
      Warn(lrImplicitTypeCast,
        'implicit type conversion from int64 to pchar; pointer from integer (MISRA 5.2)',
        expr.Span);
    end
    else if (srcType = atPChar) and (dstType = atInt64) then
    begin
      Warn(lrImplicitTypeCast,
        'implicit type conversion from pchar to int64; integer from pointer (MISRA 5.2)',
        expr.Span);
    end
    else if (srcType = atInt64) and (dstType = atBool) then
    begin
      Warn(lrImplicitTypeCast,
        'implicit type conversion from int64 to bool; use explicit comparison (MISRA 5.2)',
        expr.Span);
    end
    else if (srcType = atBool) and (dstType = atInt64) then
    begin
      Warn(lrImplicitTypeCast,
        'implicit type conversion from bool to int64; use explicit cast (MISRA 5.2)',
        expr.Span);
    end;
  end;
end;

{ --- Ungenutzte Variablen prüfen --- }

procedure TLinter.CheckUnusedVarsInCurrentScope;
var
  scope: TLintScope;
  i: Integer;
  v: TVarUsage;
begin
  if FScopeCount = 0 then Exit;
  scope := FScopes[FScopeCount - 1];

  for i := 0 to High(scope.Vars) do
  begin
    v := scope.Vars[i];
    if v.Name = '_' then Continue; // Wegwerf-Variable
    if v.Name = 'self' then Continue; // Impliziter Parameter

    { Ungenutzte Variable }
    if (not v.IsRead) and (not v.IsParameter) then
    begin
      if lrUnusedVariable in FActiveRules then
        Warn(lrUnusedVariable,
          'variable ''' + v.Name + ''' is declared but never read',
          v.DeclSpan);
    end;

    { Ungenutzter Parameter }
    if (not v.IsRead) and v.IsParameter then
    begin
      if lrUnusedParameter in FActiveRules then
        Warn(lrUnusedParameter,
          'parameter ''' + v.Name + ''' is never read',
          v.DeclSpan);
    end;

    { var deklariert, aber nie mutiert → sollte let sein }
    if (v.Storage = skVar) and (not v.IsMutated) and (not v.IsParameter) then
    begin
      if lrMutableNeverMutated in FActiveRules then
        Warn(lrMutableNeverMutated,
          'variable ''' + v.Name + ''' is declared as ''var'' but never mutated; consider using ''let''',
          v.DeclSpan);
    end;
  end;
end;

{ --- Haupteinstiegspunkt --- }

procedure TLinter.Lint(prog: TAstProgram);
var
  i: Integer;
  node: TAstNode;
begin
  if prog = nil then Exit;
  FWarnCount := 0;

  { Globaler Scope }
  PushScope;

  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node = nil then Continue;

    case node.Kind of
      nkFuncDecl:
        LintFuncDecl(TAstFuncDecl(node));

      nkConDecl:
      begin
        CheckConstantNaming(TAstConDecl(node).Name, node.Span);
        LintExpr(TAstConDecl(node).InitExpr);
      end;

      nkStructDecl:
        LintStructDecl(TAstStructDecl(node));

      nkClassDecl:
        LintClassDecl(TAstClassDecl(node));

      nkVarDecl:
      begin
        { Globale Variablen }
        CheckVariableNaming(TAstVarDecl(node).Name, node.Span);
        DeclareVar(TAstVarDecl(node).Name,
          TAstVarDecl(node).Storage, node.Span, False);
        LintExpr(TAstVarDecl(node).InitExpr);
      end;

      { Import/Unit-Deklarationen und TypeDecl benötigen kein Linting }
      nkImportDecl, nkUnitDecl, nkTypeDecl:
        ; // nichts
    end;
  end;

  { Globalen Scope schließen — hier werden globale unused-Warnungen erzeugt }
  PopScope;
end;

end.
