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
    procedure InlineFunctionCalls(func: TIRFunction);
    function ShouldInline(funcName: string; instrCount: Integer): Boolean;
    function CloneInstructions(srcFunc: TIRFunction; argMap: array of Integer; destTempOffset: Integer): TIRInstructionList;
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
  FInlineThreshold := 8;
end;

function TIRInlining.ShouldInline(funcName: string; instrCount: Integer): Boolean;
begin
  Result := False;
  if instrCount > FInlineThreshold then Exit;
  if instrCount <= 0 then Exit;
  Result := True;
end;

procedure TIRInlining.InlineFunctionCalls(func: TIRFunction);
var
  i, j: Integer;
  instr: TIRInstr;
  targetFunc: TIRFunction;
  newInstrs: TIRInstructionList;
  argCount: Integer;
begin
  newInstrs := nil;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    if (instr.Op = irCall) or (instr.Op = irVarCall) then
    begin
      if instr.CallMode = cmInternal then
      begin
        targetFunc := FModule.FindFunction(instr.ImmStr);
        if Assigned(targetFunc) and ShouldInline(targetFunc.Name, Length(targetFunc.Instructions)) then
        begin
          argCount := Length(instr.ArgTemps);
          if argCount > 0 then
          begin
            for j := 0 to High(targetFunc.Instructions) do
            begin
              SetLength(newInstrs, Length(newInstrs) + 1);
              newInstrs[High(newInstrs)] := targetFunc.Instructions[j];
            end;
          end;
        end
        else
        begin
          SetLength(newInstrs, Length(newInstrs) + 1);
          newInstrs[High(newInstrs)] := instr;
        end;
      end
      else
      begin
        SetLength(newInstrs, Length(newInstrs) + 1);
        newInstrs[High(newInstrs)] := instr;
      end;
    end
    else
    begin
      SetLength(newInstrs, Length(newInstrs) + 1);
      newInstrs[High(newInstrs)] := instr;
    end;
  end;
  
  if Length(newInstrs) > 0 then
    func.Instructions := newInstrs;
end;

function TIRInlining.CloneInstructions(srcFunc: TIRFunction; argMap: array of Integer; destTempOffset: Integer): TIRInstructionList;
var
  i: Integer;
  instr: TIRInstr;
begin
  Result := nil;
  
  for i := 0 to High(srcFunc.Instructions) do
  begin
    instr := srcFunc.Instructions[i];
    
    if instr.Dest >= 0 then
      instr.Dest := instr.Dest + destTempOffset;
    if instr.Src1 >= 0 then
      instr.Src1 := instr.Src1 + destTempOffset;
    if instr.Src2 >= 0 then
      instr.Src2 := instr.Src2 + destTempOffset;
    if instr.Src3 >= 0 then
      instr.Src3 := instr.Src3 + destTempOffset;
    
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := instr;
  end;
end;

procedure TIRInlining.Optimize;
var
  i: Integer;
  func: TIRFunction;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    func := FModule.Functions[i];
    if Assigned(func) then
      InlineFunctionCalls(func);
  end;
  
  WriteLn('[IR-Inlining] Optimized ', Length(FModule.Functions), ' functions');
end;

end.
