{$mode objfpc}{$H+}
unit ir_call_graph;

interface

uses
  SysUtils, Classes,
  ast, diag;

type
  { Static Call Graph - captures all function call relationships }
  TCallGraph = class
  private
    FAllFuncs: TStringList;
    FCallees: array of TStringList;
    FCallers: array of TStringList;
    FRecursive: TStringList;
    FDiag: TDiagnostics;
    FHasRecursion: Boolean;

    function FindFunc(const name: string): Integer;
    procedure AddFunc(const name: string);
    procedure AddEdge(caller, callee: string);
    procedure DetectRecursion;
    procedure WalkAST(node: TAstNode; const currentFunc: string);

  public
    constructor Create(d: TDiagnostics);
    destructor Destroy; override;

    procedure BuildFromAST(programNode: TAstProgram);
    function GetCallers(const funcName: string): string;
    function GetCallees(const funcName: string): string;
    function IsRecursive(const funcName: string): Boolean;
    function GetFunctionCount: Integer;
    function GetAllFunctions: string;
    function HasRecursion: Boolean;
    function ExportText: string;
    
    { Öffentliche Accessoren für Stack-Analyse }
    function GetCalleesList(const funcName: string): TStringList;
    function FindFunction(const name: string): Integer;
  end;

implementation

constructor TCallGraph.Create(d: TDiagnostics);
begin
  inherited Create;
  FDiag := d;
  FAllFuncs := TStringList.Create;
  FAllFuncs.Sorted := True;
  FAllFuncs.Duplicates := dupIgnore;
  FRecursive := TStringList.Create;
  FRecursive.Sorted := True;
  FHasRecursion := False;
end;

destructor TCallGraph.Destroy;
var
  i: Integer;
begin
  for i := 0 to Length(FCallees) - 1 do
    FCallees[i].Free;
  for i := 0 to Length(FCallers) - 1 do
    FCallers[i].Free;
  FAllFuncs.Free;
  FRecursive.Free;
  inherited Destroy;
end;

function TCallGraph.FindFunc(const name: string): Integer;
begin
  if not FAllFuncs.Find(name, Result) then
    Result := -1;
end;

procedure TCallGraph.AddFunc(const name: string);
var
  idx: Integer;
begin
  if name = '' then
    Exit;
  if FindFunc(name) >= 0 then
    Exit;

  idx := FAllFuncs.Count;
  FAllFuncs.Add(name);
  SetLength(FCallees, idx + 1);
  FCallees[idx] := TStringList.Create;
  FCallees[idx].Sorted := True;
  SetLength(FCallers, idx + 1);
  FCallers[idx] := TStringList.Create;
  FCallers[idx].Sorted := True;
end;

procedure TCallGraph.AddEdge(caller, callee: string);
var
  callerIdx, calleeIdx: Integer;
begin
  if (caller = '') or (callee = '') then
    Exit;

  // Ensure both functions exist
  AddFunc(caller);
  AddFunc(callee);

  callerIdx := FindFunc(caller);
  calleeIdx := FindFunc(callee);

  if (callerIdx < 0) or (calleeIdx < 0) then
    Exit;

  if FCallees[callerIdx].IndexOf(callee) < 0 then
    FCallees[callerIdx].Add(callee);

  if FCallers[calleeIdx].IndexOf(caller) < 0 then
    FCallers[calleeIdx].Add(caller);
end;

procedure TCallGraph.WalkAST(node: TAstNode; const currentFunc: string);
var
  i: Integer;
  callNode: TAstCall;
  funcDecl: TAstFuncDecl;
begin
  if node = nil then
    Exit;
  if currentFunc = '' then
    Exit;

  if node is TAstCall then
  begin
    callNode := TAstCall(node);
    if not callNode.IsIndirectCall then
      AddEdge(currentFunc, callNode.Name);
  end
  else if node is TAstFuncDecl then
  begin
    funcDecl := TAstFuncDecl(node);
    AddFunc(funcDecl.Name);
    if Assigned(funcDecl.Body) then
      WalkAST(funcDecl.Body, funcDecl.Name);
  end
  else if node is TAstBlock then
  begin
    for i := 0 to High(TAstBlock(node).Stmts) do
      WalkAST(TAstBlock(node).Stmts[i], currentFunc);
  end
  else if node is TAstIf then
  begin
    if Assigned(TAstIf(node).ThenBranch) then
      WalkAST(TAstIf(node).ThenBranch, currentFunc);
    if Assigned(TAstIf(node).ElseBranch) then
      WalkAST(TAstIf(node).ElseBranch, currentFunc);
  end
  else if node is TAstWhile then
  begin
    if Assigned(TAstWhile(node).Body) then
      WalkAST(TAstWhile(node).Body, currentFunc);
  end
  else if node is TAstFor then
  begin
    if Assigned(TAstFor(node).Body) then
      WalkAST(TAstFor(node).Body, currentFunc);
  end
  else if node is TAstReturn then
  begin
    if Assigned(TAstReturn(node).Value) then
    begin
      if TAstReturn(node).Value is TAstCall then
        AddEdge(currentFunc, TAstCall(TAstReturn(node).Value).Name)
      else
        WalkAST(TAstReturn(node).Value, currentFunc);
    end;
  end
  else if node is TAstAssign then
  begin
    if Assigned(TAstAssign(node).Value) then
      WalkAST(TAstAssign(node).Value, currentFunc);
  end
  else if node is TAstExprStmt then
  begin
    if Assigned(TAstExprStmt(node).Expr) then
      WalkAST(TAstExprStmt(node).Expr, currentFunc);
  end
  else if node is TAstBinOp then
  begin
    if Assigned(TAstBinOp(node).Left) then
      WalkAST(TAstBinOp(node).Left, currentFunc);
    if Assigned(TAstBinOp(node).Right) then
      WalkAST(TAstBinOp(node).Right, currentFunc);
  end
  else if node is TAstUnaryOp then
  begin
    if Assigned(TAstUnaryOp(node).Operand) then
      WalkAST(TAstUnaryOp(node).Operand, currentFunc);
  end;
end;

procedure TCallGraph.DetectRecursion;
var
  visited, inStack: TStringList;

  procedure DFS(fn: string);
  var
    idx, i: Integer;
    callee: string;
  begin
    idx := FindFunc(fn);
    if idx < 0 then
      Exit;

    if inStack.IndexOf(fn) >= 0 then
    begin
      if FRecursive.IndexOf(fn) < 0 then
        FRecursive.Add(fn);
      FHasRecursion := True;
      Exit;
    end;

    if visited.IndexOf(fn) >= 0 then
      Exit;

    visited.Add(fn);
    inStack.Add(fn);

    for i := 0 to FCallees[idx].Count - 1 do
    begin
      callee := FCallees[idx].Strings[i];
      DFS(callee);
    end;

    inStack.Delete(inStack.IndexOf(fn));
  end;

var
  i: Integer;
begin
  visited := TStringList.Create;
  inStack := TStringList.Create;
  try
    for i := 0 to FAllFuncs.Count - 1 do
    begin
      visited.Clear;
      inStack.Clear;
      DFS(FAllFuncs.Strings[i]);
    end;
  finally
    visited.Free;
    inStack.Free;
  end;
end;

procedure TCallGraph.BuildFromAST(programNode: TAstProgram);
var
  i: Integer;
  funcDecl: TAstFuncDecl;
begin
  if programNode = nil then
    Exit;

  // Phase 1: Collect all functions
  for i := 0 to High(programNode.Decls) do
  begin
    if programNode.Decls[i] is TAstFuncDecl then
    begin
      funcDecl := TAstFuncDecl(programNode.Decls[i]);
      if not funcDecl.IsExtern then
        AddFunc(funcDecl.Name);
    end;
  end;

  // Phase 2: Find calls
  for i := 0 to High(programNode.Decls) do
  begin
    if programNode.Decls[i] is TAstFuncDecl then
    begin
      funcDecl := TAstFuncDecl(programNode.Decls[i]);
      if Assigned(funcDecl.Body) then
        WalkAST(funcDecl.Body, funcDecl.Name);
    end;
  end;

  // Phase 3: Detect recursion
  DetectRecursion;
end;

function TCallGraph.GetCallers(const funcName: string): string;
var
  idx, i: Integer;
begin
  Result := '';
  idx := FindFunc(funcName);
  if idx < 0 then
    Exit;
  for i := 0 to FCallers[idx].Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + FCallers[idx].Strings[i];
  end;
end;

function TCallGraph.GetCallees(const funcName: string): string;
var
  idx, i: Integer;
begin
  Result := '';
  idx := FindFunc(funcName);
  if idx < 0 then
    Exit;
  for i := 0 to FCallees[idx].Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + FCallees[idx].Strings[i];
  end;
end;

function TCallGraph.IsRecursive(const funcName: string): Boolean;
begin
  Result := FRecursive.IndexOf(funcName) >= 0;
end;

function TCallGraph.GetFunctionCount: Integer;
begin
  Result := FAllFuncs.Count;
end;

function TCallGraph.GetAllFunctions: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FAllFuncs.Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + FAllFuncs.Strings[i];
  end;
end;

function TCallGraph.HasRecursion: Boolean;
begin
  Result := FHasRecursion;
end;

function TCallGraph.ExportText: string;
var
  i, depth: Integer;
  funcName, callees, callers: string;
begin
  Result := '=== Call Graph ===' + LineEnding + LineEnding;

  if not FHasRecursion then
    Result += 'No recursion detected.' + LineEnding
  else
  begin
    Result += 'WARNING: Recursion detected!' + LineEnding;
    Result += 'Recursive functions: ';
    for i := 0 to FRecursive.Count - 1 do
    begin
      if i > 0 then
        Result += ', ';
      Result += FRecursive.Strings[i];
    end;
    Result += LineEnding;
  end;

  Result += LineEnding;
  Result += 'Functions: ' + IntToStr(FAllFuncs.Count) + LineEnding + LineEnding;

  for i := 0 to FAllFuncs.Count - 1 do
  begin
    funcName := FAllFuncs.Strings[i];
    callees := GetCallees(funcName);
    callers := GetCallers(funcName);

    Result += '=== ' + funcName + ' ===' + LineEnding;
    Result += '  Calls: ';
    if callees = '' then
      Result += '(none)'
    else
      Result += callees;
    Result += LineEnding;
    Result += '  Called by: ';
    if callers = '' then
      Result += '(none)'
    else
      Result += callers;
    Result += LineEnding;

    if IsRecursive(funcName) then
      Result += '  [RECURSIVE]' + LineEnding;
    Result += LineEnding;
  end;
end;

{ Öffentliche Accessoren für Stack-Analyse }
function TCallGraph.GetCalleesList(const funcName: string): TStringList;
var
  idx: Integer;
begin
  Result := nil;
  idx := FindFunc(funcName);
  if idx >= 0 then
    Result := FCallees[idx];
end;

function TCallGraph.FindFunction(const name: string): Integer;
begin
  Result := FindFunc(name);
end;

end.