{$mode objfpc}{$H+}
unit ir_inlining;

interface

uses
  SysUtils, Classes, ir;

type
  TIRInlining = class
  private
    FModule: TIRModule;
    FInlineThreshold: Integer;
    FInlinedFuncs: array of string;
    FMaxInliningDepth: Integer;
    
    procedure InlineFunctionCalls(func: TIRFunction);
    function ShouldInline(callerFunc, targetFunc: TIRFunction): Boolean;
    function IsRecursiveCall(callerName, targetName: string): Boolean;
    function HasReturn(const instrs: TIRInstructionList): Boolean;
    procedure InlineCall(callerFunc: TIRFunction; callInstr: TIRInstr; targetFunc: TIRFunction; 
                        var newInstrs: TIRInstructionList; var inlined: Boolean);
    procedure CloneAndMapInstructions(srcFunc: TIRFunction; argTemps: array of Integer; 
                                    callDest: Integer; var newInstrs: TIRInstructionList);
    function GetReturnTemp(instrs: TIRInstructionList): Integer;
    function FindReturnJmpLabel(const instrs: TIRInstructionList; returnTemp: Integer): Integer;
    function GetArgCount(func: TIRFunction): Integer;
    procedure AddInlinedFunc(funcName: string);
    function WasInlined(funcName: string): Boolean;
    function CountNonLabelInstructions(const instrs: TIRInstructionList): Integer;
  public
    constructor Create(module: TIRModule);
    procedure Optimize;
  end;

implementation

{ TIRInlining }

constructor TIRInlining.Create(module: TIRModule);
begin
  inherited Create;
  FModule := module;
  FInlineThreshold := 12;
  FMaxInliningDepth := 3;
  FInlinedFuncs := nil;
end;

procedure TIRInlining.AddInlinedFunc(funcName: string);
var
  i: Integer;
begin
  for i := 0 to High(FInlinedFuncs) do
    if FInlinedFuncs[i] = funcName then Exit;
  SetLength(FInlinedFuncs, Length(FInlinedFuncs) + 1);
  FInlinedFuncs[High(FInlinedFuncs)] := funcName;
end;

function TIRInlining.WasInlined(funcName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FInlinedFuncs) do
    if FInlinedFuncs[i] = funcName then Exit(True);
  Result := False;
end;

function TIRInlining.CountNonLabelInstructions(const instrs: TIRInstructionList): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(instrs) do
    if instrs[i].Op <> irLabel then
      Inc(Result);
end;

function TIRInlining.GetArgCount(func: TIRFunction): Integer;
begin
  Result := func.ParamCount;
end;

function TIRInlining.HasReturn(const instrs: TIRInstructionList): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(instrs) do
    if instrs[i].Op = irReturn then
      Exit(True);
  Result := False;
end;

function TIRInlining.GetReturnTemp(instrs: TIRInstructionList): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(instrs) do
    if instrs[i].Op = irReturn then
    begin
      Result := instrs[i].Src1;
      Exit;
    end;
end;

function TIRInlining.FindReturnJmpLabel(const instrs: TIRInstructionList; returnTemp: Integer): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(instrs) do
  begin
    if (instrs[i].Op = irReturn) and (instrs[i].Src1 = returnTemp) then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

function TIRInlining.IsRecursiveCall(callerName, targetName: string): Boolean;
begin
  Result := (callerName = targetName);
end;

function TIRInlining.ShouldInline(callerFunc, targetFunc: TIRFunction): Boolean;
var
  instrCount: Integer;
begin
  Result := False;
  
  if not Assigned(targetFunc) then Exit;
  if not Assigned(targetFunc.Instructions) then Exit;
  if Length(targetFunc.Instructions) = 0 then Exit;
  
  if IsRecursiveCall(callerFunc.Name, targetFunc.Name) then Exit;
  
  if WasInlined(targetFunc.Name) then Exit;
  
  instrCount := CountNonLabelInstructions(targetFunc.Instructions);
  if instrCount > FInlineThreshold then Exit;
  if instrCount <= 0 then Exit;
  
  if GetArgCount(targetFunc) > 6 then Exit;
  
  Result := True;
end;

procedure TIRInlining.CloneAndMapInstructions(srcFunc: TIRFunction; argTemps: array of Integer; 
                                              callDest: Integer; var newInstrs: TIRInstructionList);
var
  i, j: Integer;
  instr, newInstr: TIRInstr;
  returnTemp: Integer;
  labelIdx: Integer;
  maxTemp: Integer;
begin
  returnTemp := GetReturnTemp(srcFunc.Instructions);
  maxTemp := 0;
  
  for i := 0 to High(srcFunc.Instructions) do
  begin
    instr := srcFunc.Instructions[i];
    newInstr := instr;
    
    if instr.Op = irLabel then
    begin
      newInstr.LabelName := instr.LabelName + '_inline_' + IntToStr(Length(newInstrs));
    end
    else if instr.Op = irReturn then
    begin
      if returnTemp >= 0 then
      begin
        newInstr.Op := irJmp;
        newInstr.Src1 := -1;
        newInstr.Src2 := -1;
        newInstr.LabelName := 'inlined_return_' + IntToStr(Length(newInstrs));
      end;
    end
    else
    begin
      for j := 0 to High(argTemps) do
      begin
        if instr.Src1 = j then newInstr.Src1 := argTemps[j];
        if instr.Src2 = j then newInstr.Src2 := argTemps[j];
        if instr.Src3 = j then newInstr.Src3 := argTemps[j];
        if instr.Dest = j then newInstr.Dest := argTemps[j];
      end;
    end;
    
    SetLength(newInstrs, Length(newInstrs) + 1);
    newInstrs[High(newInstrs)] := newInstr;
  end;
  
  if returnTemp >= 0 then
  begin
    SetLength(newInstrs, Length(newInstrs) + 1);
    newInstrs[High(newInstrs)].Op := irLabel;
    newInstrs[High(newInstrs)].LabelName := 'inlined_return_' + IntToStr(Length(newInstrs));
    newInstrs[High(newInstrs)].Dest := -1;
    newInstrs[High(newInstrs)].Src1 := -1;
    newInstrs[High(newInstrs)].Src2 := -1;
  end;
end;

procedure TIRInlining.InlineCall(callerFunc: TIRFunction; callInstr: TIRInstr; targetFunc: TIRFunction; 
                                 var newInstrs: TIRInstructionList; var inlined: Boolean);
var
  argTemps: array of Integer;
  argMap: array of Integer;
  argMapIdx: Integer;
begin
  inlined := False;
  
  argTemps := callInstr.ArgTemps;
  if Length(argTemps) = 0 then
  begin
    SetLength(newInstrs, Length(newInstrs) + 1);
    newInstrs[High(newInstrs)] := callInstr;
    Exit;
  end;
  
  // Build arg map inline
  SetLength(argMap, Length(argTemps) + 1);
  for argMapIdx := 0 to High(argTemps) do
    argMap[argMapIdx] := argTemps[argMapIdx];
  if callInstr.Dest >= 0 then
    argMap[Length(argTemps)] := callInstr.Dest;
  
  CloneAndMapInstructions(targetFunc, argMap, callInstr.Dest, newInstrs);
  
  AddInlinedFunc(targetFunc.Name);
  inlined := True;
end;

procedure TIRInlining.InlineFunctionCalls(func: TIRFunction);
var
  i: Integer;
  instr: TIRInstr;
  targetFunc: TIRFunction;
  newInstrs: TIRInstructionList;
  inlined: Boolean;
begin
  newInstrs := nil;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    if (instr.Op = irCall) or (instr.Op = irVarCall) then
    begin
      // Never inline virtual method calls - they need runtime dispatch
      if instr.IsVirtualCall then
      begin
        SetLength(newInstrs, Length(newInstrs) + 1);
        newInstrs[High(newInstrs)] := instr;
        Continue;
      end;
      
      // Never inline method calls (mangled names starting with _L_)
      // These can be called via super or as base class methods and inlining breaks control flow
      if (Length(instr.ImmStr) >= 3) and (Copy(instr.ImmStr, 1, 3) = '_L_') then
      begin
        SetLength(newInstrs, Length(newInstrs) + 1);
        newInstrs[High(newInstrs)] := instr;
        Continue;
      end;
      
      if instr.CallMode = cmInternal then
      begin
        targetFunc := FModule.FindFunction(instr.ImmStr);
        if Assigned(targetFunc) and ShouldInline(func, targetFunc) then
        begin
          InlineCall(func, instr, targetFunc, newInstrs, inlined);
          if inlined then Continue;
        end;
      end;
    end;
    
    SetLength(newInstrs, Length(newInstrs) + 1);
    newInstrs[High(newInstrs)] := instr;
  end;
  
  if Length(newInstrs) > 0 then
    func.Instructions := newInstrs;
end;

procedure TIRInlining.Optimize;
var
  i, pass: Integer;
  func: TIRFunction;
  changed: Boolean;
begin
  if not Assigned(FModule) then Exit;
  
  FInlinedFuncs := nil;
  
  for pass := 1 to FMaxInliningDepth do
  begin
    changed := False;
    
    for i := 0 to High(FModule.Functions) do
    begin
      func := FModule.Functions[i];
      if Assigned(func) and (func.Name <> 'main') then
      begin
        InlineFunctionCalls(func);
      end;
    end;
    
    if not changed then Break;
  end;
  
  WriteLn('[IR-Inlining] Completed. Inlined functions: ', Length(FInlinedFuncs));
  for i := 0 to High(FInlinedFuncs) do
    WriteLn('  - ', FInlinedFuncs[i]);
end;

end.
