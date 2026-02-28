{$mode objfpc}{$H+}
unit ir_peephole;

interface

uses
  SysUtils, Classes, ir;

type
  TIRPeepholeOptimizer = class
  private
    FModule: TIRModule;
    FStats: record
      FoldedConsts: Integer;
      RemovedRedundant: Integer;
      SimplifiedOps: Integer;
      ImprovedRegAlloc: Integer;
    end;
    
    procedure OptimizeFunction(func: TIRFunction);
    function FoldConstants(instrs: TIRInstructionList; idx: Integer): Boolean;
    function RemoveRedundantMoves(instrs: TIRInstructionList; idx: Integer): Boolean;
    function SimplifyIdentityOps(instrs: TIRInstructionList; idx: Integer): Boolean;
    function SimplifyZeroOperations(instrs: TIRInstructionList; idx: Integer): Boolean;
    function OptimizeCompareWithZero(instrs: TIRInstructionList; idx: Integer): Boolean;
    function GetInstructionCount(func: TIRFunction): Integer;
    
    function GetConstValue(instrs: TIRInstructionList; temp: Integer; out value: Int64): Boolean;
    function FindInstructionForTemp(instrs: TIRInstructionList; temp: Integer; startIdx: Integer): Integer;
    function IsTempUsedLater(instrs: TIRInstructionList; temp: Integer; afterIdx: Integer): Boolean;
    
  public
    constructor Create(module: TIRModule);
    procedure Optimize;
    procedure PrintStats;
  end;

implementation

{ TIRPeepholeOptimizer }

constructor TIRPeepholeOptimizer.Create(module: TIRModule);
begin
  inherited Create;
  FModule := module;
  FStats.FoldedConsts := 0;
  FStats.RemovedRedundant := 0;
  FStats.SimplifiedOps := 0;
  FStats.ImprovedRegAlloc := 0;
end;

function TIRPeepholeOptimizer.GetInstructionCount(func: TIRFunction): Integer;
var
  i: Integer;
begin
  Result := Length(func.Instructions);
  for i := 0 to High(func.Instructions) do
    if func.Instructions[i].Op = irLabel then
      Dec(Result);
end;

function TIRPeepholeOptimizer.GetConstValue(instrs: TIRInstructionList; temp: Integer; out value: Int64): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := High(instrs) downto 0 do
  begin
    if (instrs[i].Dest = temp) and (instrs[i].Op = irConstInt) then
    begin
      value := instrs[i].ImmInt;
      Exit(True);
    end;
  end;
end;

function TIRPeepholeOptimizer.FindInstructionForTemp(instrs: TIRInstructionList; temp: Integer; startIdx: Integer): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := startIdx - 1 downto 0 do
  begin
    if instrs[i].Dest = temp then
      Exit(i);
  end;
end;

function TIRPeepholeOptimizer.IsTempUsedLater(instrs: TIRInstructionList; temp: Integer; afterIdx: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  if temp < 0 then Exit(False);
  
  for i := afterIdx + 1 to High(instrs) do
  begin
    if instrs[i].Src1 = temp then Exit(True);
    if instrs[i].Src2 = temp then Exit(True);
    if instrs[i].Src3 = temp then Exit(True);
  end;
end;

function TIRPeepholeOptimizer.FoldConstants(instrs: TIRInstructionList; idx: Integer): Boolean;
var
  instr: TIRInstr;
  val1, val2, res: Int64;
begin
  Result := False;
  instr := instrs[idx];
  
  if (instr.Src1 < 0) or (instr.Src2 < 0) then Exit;
  
  if not GetConstValue(instrs, instr.Src1, val1) then Exit;
  if not GetConstValue(instrs, instr.Src2, val2) then Exit;
  
  case instr.Op of
    irAdd:
      begin
        res := val1 + val2;
        instrs[idx].Op := irConstInt;
        instrs[idx].ImmInt := res;
        instrs[idx].Src1 := -1;
        instrs[idx].Src2 := -1;
        Inc(FStats.FoldedConsts);
        Exit(True);
      end;
    irSub:
      begin
        res := val1 - val2;
        instrs[idx].Op := irConstInt;
        instrs[idx].ImmInt := res;
        instrs[idx].Src1 := -1;
        instrs[idx].Src2 := -1;
        Inc(FStats.FoldedConsts);
        Exit(True);
      end;
    irMul:
      begin
        res := val1 * val2;
        instrs[idx].Op := irConstInt;
        instrs[idx].ImmInt := res;
        instrs[idx].Src1 := -1;
        instrs[idx].Src2 := -1;
        Inc(FStats.FoldedConsts);
        Exit(True);
      end;
    irDiv:
      begin
        if val2 <> 0 then
        begin
          res := val1 div val2;
          instrs[idx].Op := irConstInt;
          instrs[idx].ImmInt := res;
          instrs[idx].Src1 := -1;
          instrs[idx].Src2 := -1;
          Inc(FStats.FoldedConsts);
          Exit(True);
        end;
      end;
    irMod:
      begin
        if val2 <> 0 then
        begin
          res := val1 mod val2;
          instrs[idx].Op := irConstInt;
          instrs[idx].ImmInt := res;
          instrs[idx].Src1 := -1;
          instrs[idx].Src2 := -1;
          Inc(FStats.FoldedConsts);
          Exit(True);
        end;
      end;
    irAnd:
      begin
        res := val1 and val2;
        instrs[idx].Op := irConstInt;
        instrs[idx].ImmInt := res;
        instrs[idx].Src1 := -1;
        instrs[idx].Src2 := -1;
        Inc(FStats.FoldedConsts);
        Exit(True);
      end;
    irOr:
      begin
        res := val1 or val2;
        instrs[idx].Op := irConstInt;
        instrs[idx].ImmInt := res;
        instrs[idx].Src1 := -1;
        instrs[idx].Src2 := -1;
        Inc(FStats.FoldedConsts);
        Exit(True);
      end;
    irXor:
      begin
        res := val1 xor val2;
        instrs[idx].Op := irConstInt;
        instrs[idx].ImmInt := res;
        instrs[idx].Src1 := -1;
        instrs[idx].Src2 := -1;
        Inc(FStats.FoldedConsts);
        Exit(True);
      end;
  end;
end;

function TIRPeepholeOptimizer.RemoveRedundantMoves(instrs: TIRInstructionList; idx: Integer): Boolean;
var
  currInstr, prevIdx: TIRInstr;
  prevIdxNum: Integer;
  src1Val, testVal: Int64;
begin
  Result := False;
  if idx = 0 then Exit;
  
  currInstr := instrs[idx];
  
  if (currInstr.Op = irLoadLocal) and (currInstr.Src1 >= 0) then
  begin
    prevIdxNum := FindInstructionForTemp(instrs, currInstr.Src1, idx);
    if prevIdxNum >= 0 then
    begin
      prevIdx := instrs[prevIdxNum];
      
      if prevIdx.Op = irStoreLocal then
      begin
        if (prevIdx.Src1 = currInstr.Dest) and (prevIdx.Src2 = currInstr.Src1) then
        begin
          if not IsTempUsedLater(instrs, currInstr.Dest, idx) then
          begin
            instrs[idx].Op := irInvalid;
            Inc(FStats.RemovedRedundant);
            Exit(True);
          end;
        end;
      end;
      
      if prevIdx.Op = irConstInt then
      begin
        if GetConstValue(instrs, currInstr.Src1, src1Val) and (src1Val = prevIdx.ImmInt) then
        begin
          if not IsTempUsedLater(instrs, currInstr.Src1, idx) then
          begin
            instrs[idx].Op := irConstInt;
            instrs[idx].ImmInt := prevIdx.ImmInt;
            instrs[idx].Src1 := -1;
            Inc(FStats.RemovedRedundant);
            Exit(True);
          end;
        end;
      end;
    end;
  end;
end;

function TIRPeepholeOptimizer.SimplifyIdentityOps(instrs: TIRInstructionList; idx: Integer): Boolean;
var
  instr: TIRInstr;
  val: Int64;
begin
  Result := False;
  instr := instrs[idx];
  
  case instr.Op of
    irAdd:
      begin
        if instr.Src2 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src2, val) and (val = 0) then
          begin
            if instr.Src1 = instr.Dest then
            begin
              instrs[idx].Op := irInvalid;
              Inc(FStats.SimplifiedOps);
              Exit(True);
            end;
          end;
        end;
        if instr.Src1 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src1, val) and (val = 0) then
          begin
            instrs[idx].Op := irLoadLocal;
            instrs[idx].Src1 := instr.Src2;
            instrs[idx].Src2 := -1;
            Inc(FStats.SimplifiedOps);
            Exit(True);
          end;
        end;
      end;
    irSub:
      begin
        if instr.Src2 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src2, val) and (val = 0) then
          begin
            if instr.Src1 = instr.Dest then
            begin
              instrs[idx].Op := irInvalid;
              Inc(FStats.SimplifiedOps);
              Exit(True);
            end;
          end;
        end;
      end;
    irMul:
      begin
        if instr.Src2 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src2, val) and (val = 1) then
          begin
            if instr.Src1 = instr.Dest then
            begin
              instrs[idx].Op := irInvalid;
              Inc(FStats.SimplifiedOps);
              Exit(True);
            end;
          end;
          if GetConstValue(instrs, instr.Src2, val) and (val = 0) then
          begin
            instrs[idx].Op := irConstInt;
            instrs[idx].ImmInt := 0;
            instrs[idx].Src1 := -1;
            instrs[idx].Src2 := -1;
            Inc(FStats.SimplifiedOps);
            Exit(True);
          end;
        end;
      end;
    irAnd:
      begin
        if instr.Src2 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src2, val) and (val = -1) then
          begin
            if instr.Src1 = instr.Dest then
            begin
              instrs[idx].Op := irInvalid;
              Inc(FStats.SimplifiedOps);
              Exit(True);
            end;
          end;
        end;
      end;
    irOr:
      begin
        if instr.Src2 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src2, val) and (val = 0) then
          begin
            if instr.Src1 = instr.Dest then
            begin
              instrs[idx].Op := irInvalid;
              Inc(FStats.SimplifiedOps);
              Exit(True);
            end;
          end;
        end;
      end;
  end;
end;

function TIRPeepholeOptimizer.SimplifyZeroOperations(instrs: TIRInstructionList; idx: Integer): Boolean;
var
  instr: TIRInstr;
  val: Int64;
begin
  Result := False;
  instr := instrs[idx];
  
  case instr.Op of
    irNeg:
      begin
        if instr.Src1 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src1, val) then
          begin
            instrs[idx].Op := irConstInt;
            instrs[idx].ImmInt := -val;
            instrs[idx].Src1 := -1;
            Inc(FStats.SimplifiedOps);
            Exit(True);
          end;
        end;
      end;
    irNot:
      begin
        if instr.Src1 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src1, val) then
          begin
            instrs[idx].Op := irConstInt;
            if val = 0 then
              instrs[idx].ImmInt := 1
            else
              instrs[idx].ImmInt := 0;
            instrs[idx].Src1 := -1;
            Inc(FStats.SimplifiedOps);
            Exit(True);
          end;
        end;
      end;
  end;
end;

function TIRPeepholeOptimizer.OptimizeCompareWithZero(instrs: TIRInstructionList; idx: Integer): Boolean;
var
  instr: TIRInstr;
  val: Int64;
begin
  Result := False;
  if idx = 0 then Exit;
  
  instr := instrs[idx];
  
  case instr.Op of
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe:
      begin
        if instr.Src2 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src2, val) and (val = 0) then
          begin
            instrs[idx].Src2 := -1;
            Inc(FStats.SimplifiedOps);
            Exit(True);
          end;
        end;
        if instr.Src1 >= 0 then
        begin
          if GetConstValue(instrs, instr.Src1, val) and (val = 0) then
          begin
            instrs[idx].Src1 := instr.Src2;
            instrs[idx].Src2 := -1;
            
            case instr.Op of
              irCmpEq: instr.Op := irCmpNeq;
              irCmpNeq: instr.Op := irCmpEq;
              irCmpLt: instr.Op := irCmpGt;
              irCmpGt: instr.Op := irCmpLt;
              irCmpLe: instr.Op := irCmpGe;
              irCmpGe: instr.Op := irCmpLe;
            end;
            
            Inc(FStats.SimplifiedOps);
            Exit(True);
          end;
        end;
      end;
  end;
end;

procedure TIRPeepholeOptimizer.OptimizeFunction(func: TIRFunction);
var
  i, j: Integer;
  modified: Boolean;
  instrs: TIRInstructionList;
  validCount, invalidCount: Integer;
begin
  if Length(func.Instructions) = 0 then Exit;
  
  instrs := func.Instructions;
  
  repeat
    modified := False;
    i := 0;
    while i < Length(instrs) do
    begin
      if FoldConstants(instrs, i) then
      begin
        modified := True;
        Inc(i);
        Continue;
      end;
      
      if RemoveRedundantMoves(instrs, i) then
      begin
        modified := True;
        Inc(i);
        Continue;
      end;
      
      if SimplifyIdentityOps(instrs, i) then
      begin
        modified := True;
        Inc(i);
        Continue;
      end;
      
      if SimplifyZeroOperations(instrs, i) then
      begin
        modified := True;
        Inc(i);
        Continue;
      end;
      
      if OptimizeCompareWithZero(instrs, i) then
      begin
        modified := True;
        Inc(i);
        Continue;
      end;
      
      Inc(i);
    end;
  until not modified;
  
  invalidCount := 0;
  for i := 0 to High(instrs) do
    if instrs[i].Op = irInvalid then
      Inc(invalidCount);
  
  if invalidCount > 0 then
  begin
    validCount := Length(instrs) - invalidCount;
    SetLength(instrs, validCount);
    j := 0;
    for i := 0 to High(func.Instructions) do
    begin
      if func.Instructions[i].Op <> irInvalid then
      begin
        instrs[j] := func.Instructions[i];
        Inc(j);
      end;
    end;
    func.Instructions := instrs;
  end;
end;

procedure TIRPeepholeOptimizer.Optimize;
var
  i: Integer;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    if Assigned(FModule.Functions[i]) then
      OptimizeFunction(FModule.Functions[i]);
  end;
end;

procedure TIRPeepholeOptimizer.PrintStats;
begin
  WriteLn('  Peephole Optimizer Statistics:');
  WriteLn('    - Constant folding:     ', FStats.FoldedConsts);
  WriteLn('    - Redundant moves:     ', FStats.RemovedRedundant);
  WriteLn('    - Simplified ops:      ', FStats.SimplifiedOps);
  WriteLn('    - Total optimizations:  ', FStats.FoldedConsts + FStats.RemovedRedundant + FStats.SimplifiedOps);
end;

end.
