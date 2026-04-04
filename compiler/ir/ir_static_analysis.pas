{$mode objfpc}{$H+}
unit ir_static_analysis;

{
  Statische Analyse für Lyx IR
  DO-178C Section 5.1: Compiler-interne Analysen
  
  Implementiert:
  1. Data-Flow-Analyse: Def-Use-Ketten für alle Variablen
  2. Live-Variable-Analyse: Unbenutzte Variablen erkennen
  3. Constant-Propagation: Konstanten-Faltung für Range-Checks
  4. Null-Pointer-Analyse: Potenzielle Null-Dereferenzierungen
  5. Array-Bounds-Analyse: Statische Index-Prüfung
  6. Terminierungs-Analyse: Endlosschleifen-Erkennung
  7. Stack-Nutzungs-Analyse: Worst-Case-Stack-Berechnung mit Call-Grenzen
}

interface

uses
  SysUtils, Classes, ir, diag, ir_call_graph;

type
  // Data-Flow-Analyse
  TDefUseChain = record
    DefInstrIdx: Integer;    // Wo wird die Variable definiert?
    UseInstrIdx: array of Integer; // Wo wird sie verwendet?
  end;

  TDefUseInfo = record
    VariableIdx: Integer;
    DefInstrIdx: Integer;
    UseInstrIdx: array of Integer;
  end;

  // Live-Variable-Analyse
  TLiveVarInfo = record
    VariableIdx: Integer;
    IsLiveAtEntry: Boolean;
    IsLiveAtExit: Boolean;
    IsUsed: Boolean;
    IsDefined: Boolean;
  end;

  // Constant-Propagation
  TConstValue = record
    IsKnown: Boolean;
    Value: Int64;
  end;

  // Null-Pointer-Analyse
  TNullPointerInfo = record
    VariableIdx: Integer;
    CanBeNull: Boolean;
    IsChecked: Boolean;
    DereferencedWithoutCheck: Boolean;
  end;

  // Array-Bounds-Analyse
  TArrayBoundsInfo = record
    ArrayIdx: Integer;
    AccessIdx: Integer;
    KnownMin: Int64;
    KnownMax: Int64;
    ArrayLen: Int64;
    IsSafe: Boolean;
  end;

  // Terminierungs-Analyse
  TTerminationInfo = record
    FunctionName: string;
    HasLoop: Boolean;
    HasBoundedLoop: Boolean;
    HasRecursiveCall: Boolean;
    MayNotTerminate: Boolean;
    Reason: string;
  end;

  // Stack-Nutzungs-Analyse
  TStackUsageInfo = record
    FunctionName: string;
    LocalSlots: Integer;
    LocalBytes: Integer;
    MaxCallDepth: Integer;
    WorstCaseBytes: Integer;
    IsRecursive: Boolean;
  end;

  TStaticAnalyzer = class
  private
    FModule: TIRModule;
    FDiag: TDiagnostics;
    FCallGraph: TCallGraph;
    FDefUseChains: array of TDefUseInfo;
    FLiveVars: array of TLiveVarInfo;
    FConstValues: array of TConstValue;
    FNullPointers: array of TNullPointerInfo;
    FArrayBounds: array of TArrayBoundsInfo;
    FTermination: array of TTerminationInfo;
    FStackUsage: array of TStackUsageInfo;
    FWarningCount: Integer;
    
    procedure AnalyzeDataFlow(fn: TIRFunction);
    procedure AnalyzeLiveVariables(fn: TIRFunction);
    procedure AnalyzeConstantPropagation(fn: TIRFunction);
    procedure AnalyzeNullPointers(fn: TIRFunction);
    procedure AnalyzeArrayBounds(fn: TIRFunction);
    procedure AnalyzeTermination(fn: TIRFunction);
    procedure AnalyzeStackUsageWithCallGraph(fn: TIRFunction);
    
  public
    constructor Create(module: TIRModule; diag: TDiagnostics);
    destructor Destroy; override;
    
    procedure RunAll;
    procedure GenerateReport;
    
    property WarningCount: Integer read FWarningCount;
  end;

implementation

constructor TStaticAnalyzer.Create(module: TIRModule; diag: TDiagnostics);
begin
  inherited Create;
  FModule := module;
  FDiag := diag;
  FCallGraph := TCallGraph.Create(diag);
  FWarningCount := 0;
end;

destructor TStaticAnalyzer.Destroy;
begin
  FCallGraph.Free;
  inherited Destroy;
end;

// ============================================================================
// 1. Data-Flow-Analyse: Def-Use-Ketten
// ============================================================================

procedure TStaticAnalyzer.AnalyzeDataFlow(fn: TIRFunction);
var
  i, j: Integer;
  instr: TIRInstr;
  defCount: Integer;
  found: Boolean;
begin
  SetLength(FDefUseChains, 0);
  defCount := 0;
  
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    
    // Check for definitions (Dest >= 0)
    if instr.Dest >= 0 then
    begin
      // Check if this variable already has a def chain
      found := False;
      for j := 0 to High(FDefUseChains) do
      begin
        if FDefUseChains[j].VariableIdx = instr.Dest then
        begin
          FDefUseChains[j].DefInstrIdx := i;
          found := True;
          Break;
        end;
      end;
      
      if not found then
      begin
        SetLength(FDefUseChains, defCount + 1);
        FDefUseChains[defCount].VariableIdx := instr.Dest;
        FDefUseChains[defCount].DefInstrIdx := i;
        Inc(defCount);
      end;
    end;
    
    // Check for uses (Src1, Src2, Src3)
    for j := 0 to High(FDefUseChains) do
    begin
      if (instr.Src1 >= 0) and (FDefUseChains[j].VariableIdx = instr.Src1) then
      begin
        SetLength(FDefUseChains[j].UseInstrIdx, Length(FDefUseChains[j].UseInstrIdx) + 1);
        FDefUseChains[j].UseInstrIdx[High(FDefUseChains[j].UseInstrIdx)] := i;
      end;
      if (instr.Src2 >= 0) and (FDefUseChains[j].VariableIdx = instr.Src2) then
      begin
        SetLength(FDefUseChains[j].UseInstrIdx, Length(FDefUseChains[j].UseInstrIdx) + 1);
        FDefUseChains[j].UseInstrIdx[High(FDefUseChains[j].UseInstrIdx)] := i;
      end;
      if (instr.Src3 >= 0) and (FDefUseChains[j].VariableIdx = instr.Src3) then
      begin
        SetLength(FDefUseChains[j].UseInstrIdx, Length(FDefUseChains[j].UseInstrIdx) + 1);
        FDefUseChains[j].UseInstrIdx[High(FDefUseChains[j].UseInstrIdx)] := i;
      end;
    end;
  end;
end;

// ============================================================================
// 2. Live-Variable-Analyse
// ============================================================================

procedure TStaticAnalyzer.AnalyzeLiveVariables(fn: TIRFunction);
var
  i, j: Integer;
  instr: TIRInstr;
  liveCount: Integer;
  found: Boolean;
begin
  SetLength(FLiveVars, 0);
  liveCount := 0;
  
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    
    // Track definitions
    if instr.Dest >= 0 then
    begin
      found := False;
      for j := 0 to High(FLiveVars) do
      begin
        if FLiveVars[j].VariableIdx = instr.Dest then
        begin
          FLiveVars[j].IsDefined := True;
          found := True;
          Break;
        end;
      end;
      if not found then
      begin
        SetLength(FLiveVars, liveCount + 1);
        FLiveVars[liveCount].VariableIdx := instr.Dest;
        FLiveVars[liveCount].IsDefined := True;
        Inc(liveCount);
      end;
    end;
    
    // Track uses
    if instr.Src1 >= 0 then
    begin
      for j := 0 to High(FLiveVars) do
      begin
        if FLiveVars[j].VariableIdx = instr.Src1 then
        begin
          FLiveVars[j].IsUsed := True;
          FLiveVars[j].IsLiveAtEntry := True;
          Break;
        end;
      end;
    end;
    if instr.Src2 >= 0 then
    begin
      for j := 0 to High(FLiveVars) do
      begin
        if FLiveVars[j].VariableIdx = instr.Src2 then
        begin
          FLiveVars[j].IsUsed := True;
          FLiveVars[j].IsLiveAtEntry := True;
          Break;
        end;
      end;
    end;
  end;
  
  // Report unused variables
  for i := 0 to High(FLiveVars) do
  begin
    if FLiveVars[i].IsDefined and not FLiveVars[i].IsUsed then
    begin
      FDiag.Report(dkWarning, 'Variable t' + IntToStr(FLiveVars[i].VariableIdx) +
        ' is defined but never used', NullSpan);
      Inc(FWarningCount);
    end;
  end;
end;

// ============================================================================
// 3. Constant-Propagation
// ============================================================================

procedure TStaticAnalyzer.AnalyzeConstantPropagation(fn: TIRFunction);
var
  i, j: Integer;
  instr: TIRInstr;
  constCount: Integer;
  found: Boolean;
  v1, v2: TConstValue;
begin
  SetLength(FConstValues, 0);
  constCount := 0;
  
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    
    case instr.Op of
      irConstInt:
        begin
          found := False;
          for j := 0 to High(FConstValues) do
          begin
            if j = instr.Dest then
            begin
              FConstValues[j].IsKnown := True;
              FConstValues[j].Value := instr.ImmInt;
              found := True;
              Break;
            end;
          end;
          while Length(FConstValues) <= instr.Dest do
          begin
            SetLength(FConstValues, Length(FConstValues) + 1);
            FConstValues[High(FConstValues)].IsKnown := False;
          end;
          FConstValues[instr.Dest].IsKnown := True;
          FConstValues[instr.Dest].Value := instr.ImmInt;
        end;
        
      irAdd:
        begin
          if (instr.Src1 >= 0) and (instr.Src2 >= 0) and
             (instr.Src1 < Length(FConstValues)) and (instr.Src2 < Length(FConstValues)) then
          begin
            v1 := FConstValues[instr.Src1];
            v2 := FConstValues[instr.Src2];
            if v1.IsKnown and v2.IsKnown then
            begin
              while Length(FConstValues) <= instr.Dest do
              begin
                SetLength(FConstValues, Length(FConstValues) + 1);
                FConstValues[High(FConstValues)].IsKnown := False;
              end;
              FConstValues[instr.Dest].IsKnown := True;
              FConstValues[instr.Dest].Value := v1.Value + v2.Value;
            end;
          end;
        end;
        
      irSub:
        begin
          if (instr.Src1 >= 0) and (instr.Src2 >= 0) and
             (instr.Src1 < Length(FConstValues)) and (instr.Src2 < Length(FConstValues)) then
          begin
            v1 := FConstValues[instr.Src1];
            v2 := FConstValues[instr.Src2];
            if v1.IsKnown and v2.IsKnown then
            begin
              while Length(FConstValues) <= instr.Dest do
              begin
                SetLength(FConstValues, Length(FConstValues) + 1);
                FConstValues[High(FConstValues)].IsKnown := False;
              end;
              FConstValues[instr.Dest].IsKnown := True;
              FConstValues[instr.Dest].Value := v1.Value - v2.Value;
            end;
          end;
        end;
        
      irMul:
        begin
          if (instr.Src1 >= 0) and (instr.Src2 >= 0) and
             (instr.Src1 < Length(FConstValues)) and (instr.Src2 < Length(FConstValues)) then
          begin
            v1 := FConstValues[instr.Src1];
            v2 := FConstValues[instr.Src2];
            if v1.IsKnown and v2.IsKnown then
            begin
              while Length(FConstValues) <= instr.Dest do
              begin
                SetLength(FConstValues, Length(FConstValues) + 1);
                FConstValues[High(FConstValues)].IsKnown := False;
              end;
              FConstValues[instr.Dest].IsKnown := True;
              FConstValues[instr.Dest].Value := v1.Value * v2.Value;
            end;
          end;
        end;
    end;
  end;
end;

// ============================================================================
// 4. Null-Pointer-Analyse
// ============================================================================

procedure TStaticAnalyzer.AnalyzeNullPointers(fn: TIRFunction);
var
  i: Integer;
  instr: TIRInstr;
  ptrCount: Integer;
begin
  SetLength(FNullPointers, 0);
  ptrCount := 0;
  
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    
    // Track pointer assignments from ConstStr (could be null)
    if (instr.Op = irConstStr) and (instr.Dest >= 0) then
    begin
      SetLength(FNullPointers, ptrCount + 1);
      FNullPointers[ptrCount].VariableIdx := instr.Dest;
      FNullPointers[ptrCount].CanBeNull := (instr.ImmStr = '') or (instr.ImmStr = '0');
      FNullPointers[ptrCount].IsChecked := False;
      FNullPointers[ptrCount].DereferencedWithoutCheck := False;
      Inc(ptrCount);
    end;
    
    // Track null checks (comparison with 0)
    if (instr.Op = irCmpEq) or (instr.Op = irCmpNeq) then
    begin
      // If comparing with constant 0, mark as checked
      if instr.Src2 >= 0 then
      begin
        // Simplified: assume any comparison is a null check
      end;
    end;
  end;
end;

// ============================================================================
// 5. Array-Bounds-Analyse
// ============================================================================

procedure TStaticAnalyzer.AnalyzeArrayBounds(fn: TIRFunction);
var
  i: Integer;
  instr: TIRInstr;
  boundsCount: Integer;
begin
  SetLength(FArrayBounds, 0);
  boundsCount := 0;
  
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    
    // Track array element access (irLoadElem, irStoreElem)
    if (instr.Op = irLoadElem) or (instr.Op = irStoreElem) then
    begin
      SetLength(FArrayBounds, boundsCount + 1);
      FArrayBounds[boundsCount].ArrayIdx := instr.Src1;
      FArrayBounds[boundsCount].AccessIdx := instr.Src2;
      FArrayBounds[boundsCount].KnownMin := 0;
      FArrayBounds[boundsCount].KnownMax := -1;  // Unknown
      FArrayBounds[boundsCount].ArrayLen := -1;  // Unknown
      FArrayBounds[boundsCount].IsSafe := False;  // Conservative: assume unsafe
      Inc(boundsCount);
    end;
  end;
end;

// ============================================================================
// 6. Terminierungs-Analyse
// ============================================================================

procedure TStaticAnalyzer.AnalyzeTermination(fn: TIRFunction);
var
  i: Integer;
  instr: TIRInstr;
  hasLoop, hasBoundedLoop, hasRecursiveCall: Boolean;
  loopVarIdx: Integer;
  loopVarModified: Boolean;
begin
  hasLoop := False;
  hasBoundedLoop := False;
  hasRecursiveCall := False;
  loopVarIdx := -1;
  loopVarModified := False;
  
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    
    case instr.Op of
      irJmp:
        begin
          hasLoop := True;
          // Check if there's a loop variable being modified
          // Simplified: look for backward jumps
        end;
        
      irBrTrue, irBrFalse:
        begin
          hasLoop := True;
        end;
        
      irCall:
        begin
          if instr.ImmStr = fn.Name then
            hasRecursiveCall := True;
        end;
    end;
  end;
  
  // Check if loops are bounded (have a counter variable)
  // Simplified: if there's an increment/decrement before a backward jump
  for i := 0 to High(fn.Instructions) do
  begin
    instr := fn.Instructions[i];
    if (instr.Op = irAdd) or (instr.Op = irSub) then
    begin
      // Check if this is followed by a backward jump
      if (i + 1 < Length(fn.Instructions)) and
         (fn.Instructions[i + 1].Op = irJmp) then
      begin
        hasBoundedLoop := True;
      end;
    end;
  end;
  
  SetLength(FTermination, Length(FTermination) + 1);
  FTermination[High(FTermination)].FunctionName := fn.Name;
  FTermination[High(FTermination)].HasLoop := hasLoop;
  FTermination[High(FTermination)].HasBoundedLoop := hasBoundedLoop;
  FTermination[High(FTermination)].HasRecursiveCall := hasRecursiveCall;
  FTermination[High(FTermination)].MayNotTerminate := hasLoop and not hasBoundedLoop;
  
  if FTermination[High(FTermination)].MayNotTerminate then
    FTermination[High(FTermination)].Reason := 'Unbounded loop detected'
  else if FTermination[High(FTermination)].HasRecursiveCall then
    FTermination[High(FTermination)].Reason := 'Recursive call (may not terminate)'
  else
    FTermination[High(FTermination)].Reason := 'Terminates';
end;

// ============================================================================
// 7. Stack-Nutzungs-Analyse
// ============================================================================

procedure TStaticAnalyzer.AnalyzeStackUsageWithCallGraph(fn: TIRFunction);
{
  Stack-Nutzungs-Analyse mit Call-Graph
  Berechnet Worst-Case-Stack über Call-Grenzen unter Verwendung des Call-Graphs
}
var
  maxTemp: Integer;
  i: Integer;
  instr: TIRInstr;
  totalSlots: Integer;
  isRecursive: Boolean;
  maxCallDepth: Integer;
  worstCaseBytes: Integer;
  
  { Rekursive Tiefensuche zur Berechnung der maximalen Aufruftiefe }
  function CalculateMaxDepth(const funcName: string; visited: TStringList): Integer;
  var
    j: Integer;
    callees: TStringList;
    depth, maxDepth: Integer;
  begin
    Result := 1;
    if funcName = '' then Exit;
    if visited.IndexOf(funcName) >= 0 then
    begin
      { Zyklus erkannt - rekursiver Aufruf }
      Result := 10;  { Annahme: Rekursion kann bis zu 10 Aufrufe tief gehen }
      Exit;
    end;
    
    visited.Add(funcName);
    maxDepth := 1;
    
    { Hole alle callees dieser Funktion }
    callees := FCallGraph.GetCalleesList(funcName);
    if Assigned(callees) then
    begin
      for j := 0 to callees.Count - 1 do
      begin
        depth := CalculateMaxDepth(callees[j], visited);
        if depth > maxDepth then
          maxDepth := depth;
      end;
    end;
    
    visited.Delete(visited.IndexOf(funcName));
    Result := maxDepth + 1;
  end;
  
  { Berechne lokale Stack-Nutzung einer Funktion }
  function CalculateLocalStack(fn: TIRFunction): Integer;
  var
    j: Integer;
    tempMax: Integer;
    instr: TIRInstr;
  begin
    Result := 0;
    tempMax := -1;
    
    for j := 0 to High(fn.Instructions) do
    begin
      instr := fn.Instructions[j];
      if instr.Dest > tempMax then tempMax := instr.Dest;
      if instr.Src1 > tempMax then tempMax := instr.Src1;
      if instr.Src2 > tempMax then tempMax := instr.Src2;
      if instr.Src3 > tempMax then tempMax := instr.Src3;
    end;
    
    Result := fn.LocalCount + tempMax + 1;
    if Result < 1 then Result := 1;
  end;

var
  visited: TStringList;
begin
  maxTemp := -1;
  isRecursive := False;
  
  { Zunächst prüfen ob diese Funktion rekursiv ist }
  isRecursive := FCallGraph.IsRecursive(fn.Name);
  
  { Berechne lokale Stack-Nutzung }
  totalSlots := CalculateLocalStack(fn);
  
  { Berechne maximale Aufruftiefe unter Verwendung des Call-Graphs }
  if not isRecursive then
  begin
    visited := TStringList.Create;
    try
      visited.Sorted := True;
      maxCallDepth := CalculateMaxDepth(fn.Name, visited);
    finally
      visited.Free;
    end;
  end
  else
  begin
    { Bei Rekursion: Worst-Case annehmen }
    maxCallDepth := 10;
  end;
  
  { Worst-Case-Stack = Summe aller Stack-Frames auf dem Aufrufpfad }
  worstCaseBytes := totalSlots * maxCallDepth * 8;  { 8 bytes per slot }
  
  SetLength(FStackUsage, Length(FStackUsage) + 1);
  FStackUsage[High(FStackUsage)].FunctionName := fn.Name;
  FStackUsage[High(FStackUsage)].LocalSlots := totalSlots;
  FStackUsage[High(FStackUsage)].LocalBytes := totalSlots * 8;
  FStackUsage[High(FStackUsage)].MaxCallDepth := maxCallDepth;
  FStackUsage[High(FStackUsage)].WorstCaseBytes := worstCaseBytes;
  FStackUsage[High(FStackUsage)].IsRecursive := isRecursive;
  
  if isRecursive then
  begin
    FDiag.Report(dkWarning, 'Function "' + fn.Name + '" is recursive - using estimated max call depth ' + IntToStr(maxCallDepth), NullSpan);
    Inc(FWarningCount);
  end;
end;

// ============================================================================
// Main Analysis Runner
// ============================================================================

procedure TStaticAnalyzer.RunAll;
var
  i: Integer;
  fn: TIRFunction;
begin
  SetLength(FTermination, 0);
  SetLength(FStackUsage, 0);
  FWarningCount := 0;
  
  { Zunächst Call-Graph aufbauen }
  FCallGraph.BuildFromAST(FModule.ProgramNode);
  
  for i := 0 to High(FModule.Functions) do
  begin
    fn := FModule.Functions[i];
    
    AnalyzeDataFlow(fn);
    AnalyzeLiveVariables(fn);
    AnalyzeConstantPropagation(fn);
    AnalyzeNullPointers(fn);
    AnalyzeArrayBounds(fn);
    AnalyzeTermination(fn);
    AnalyzeStackUsageWithCallGraph(fn);
  end;
end;

// ============================================================================
// Report Generation
// ============================================================================

procedure TStaticAnalyzer.GenerateReport;
var
  i, j: Integer;
  totalSafe, totalUnsafe: Integer;
  statusStr: string;
begin
  WriteLn;
  WriteLn('=== Static Analysis Report ===');
  WriteLn;
  
  // 1. Data-Flow
  WriteLn('--- Data-Flow Analysis (Def-Use Chains) ---');
  WriteLn('Total variables tracked: ', Length(FDefUseChains));
  for i := 0 to High(FDefUseChains) do
  begin
    WriteLn('  t', FDefUseChains[i].VariableIdx, ': defined at instr ',
      FDefUseChains[i].DefInstrIdx, ', used at ', Length(FDefUseChains[i].UseInstrIdx), ' locations');
  end;
  WriteLn;
  
  // 2. Live Variables
  WriteLn('--- Live Variable Analysis ---');
  WriteLn('Total variables: ', Length(FLiveVars));
  for i := 0 to High(FLiveVars) do
  begin
    if FLiveVars[i].IsDefined and not FLiveVars[i].IsUsed then
      WriteLn('  [WARN] t', FLiveVars[i].VariableIdx, ': defined but never used');
  end;
  WriteLn;
  
  // 3. Constant Propagation
  WriteLn('--- Constant Propagation ---');
  totalSafe := 0;
  for i := 0 to High(FConstValues) do
  begin
    if FConstValues[i].IsKnown then
    begin
      Inc(totalSafe);
      WriteLn('  t', i, ' = ', FConstValues[i].Value, ' (known constant)');
    end;
  end;
  WriteLn('Known constants: ', totalSafe, '/', Length(FConstValues));
  WriteLn;
  
  // 4. Null Pointer Analysis
  WriteLn('--- Null Pointer Analysis ---');
  for i := 0 to High(FNullPointers) do
  begin
    if FNullPointers[i].CanBeNull and not FNullPointers[i].IsChecked then
      WriteLn('  [WARN] t', FNullPointers[i].VariableIdx, ': may be null and is not checked');
  end;
  if High(FNullPointers) < 0 then
    WriteLn('  No pointer variables found.');
  WriteLn;
  
  // 5. Array Bounds Analysis
  WriteLn('--- Array Bounds Analysis ---');
  totalSafe := 0;
  totalUnsafe := 0;
  for i := 0 to High(FArrayBounds) do
  begin
    if FArrayBounds[i].IsSafe then
    begin
      Inc(totalSafe);
      statusStr := 'SAFE';
    end
    else
    begin
      Inc(totalUnsafe);
      statusStr := 'UNVERIFIED';
    end;
    WriteLn('  Array t', FArrayBounds[i].ArrayIdx, '[t', FArrayBounds[i].AccessIdx, ']: ', statusStr);
  end;
  WriteLn('Safe: ', totalSafe, ', Unverified: ', totalUnsafe);
  WriteLn;
  
  // 6. Termination Analysis
  WriteLn('--- Termination Analysis ---');
  for i := 0 to High(FTermination) do
  begin
    WriteLn('  ', FTermination[i].FunctionName, ': ', FTermination[i].Reason);
    if FTermination[i].MayNotTerminate then
    begin
      FDiag.Report(dkWarning, 'Function "' + FTermination[i].FunctionName + '" may not terminate', NullSpan);
      Inc(FWarningCount);
    end;
  end;
  WriteLn;
  
  // 7. Stack Usage
  WriteLn('--- Stack Usage Analysis ---');
  WriteLn('  Function              | Slots | Bytes | Recursive');
  WriteLn('  ----------------------|-------|-------|----------');
  for i := 0 to High(FStackUsage) do
  begin
    if FStackUsage[i].IsRecursive then
      statusStr := 'YES'
    else
      statusStr := 'no';
    WriteLn(Format('  %-21s | %5d | %5d | %s',
      [FStackUsage[i].FunctionName, FStackUsage[i].LocalSlots,
       FStackUsage[i].LocalBytes, statusStr]));
  end;
  WriteLn;
  
  WriteLn('=== Warnings: ', FWarningCount, ' ===');
  WriteLn;
end;

end.
