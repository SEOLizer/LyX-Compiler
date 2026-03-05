{$mode objfpc}{$H+}
unit ir_optimize;

interface

uses
  SysUtils, Classes, ir;

type
  TBoolArray = array of Boolean;

  { IR-Optimierungspipeline }
  TIROptimizer = class
  private
    FModule: TIRModule;
    FChanged: Boolean;
    FPassCount: Integer;
    FMaxPasses: Integer;
    
    { Constant Folding }
    function FoldConstantsInFunc(func: TIRFunction): Boolean;
    function TryFoldInstruction(instr: TIRInstr; out folded: TIRInstr): Boolean;
    function EvaluateConstExpr(op: TIROpKind; src1, src2: Int64; immInt: Int64): Int64;
    function EvaluateConstFloat(op: TIROpKind; src1, src2: Double): Double;
    function IsConstExpr(instr: TIRInstr): Boolean;
    function GetConstValue(instr: TIRInstr): Int64;
    function GetConstFloat(instr: TIRInstr): Double;
    
  { Dead Code Elimination }
  function EliminateDeadCode(func: TIRFunction): Boolean;
  function ComputeLiveness(func: TIRFunction; out liveDest: TBoolArray): Boolean;

    
    { Common Subexpression Elimination }
    function EliminateCommonSubexpr(func: TIRFunction): Boolean;
    function GetInstructionSignature(instr: TIRInstr): string;
    function FindRedundantInstruction(func: TIRFunction; sig: string; startIdx: Integer): Integer;
    
    { Copy Propagation }
    function PropagateCopies(func: TIRFunction): Boolean;
    
    { Strength Reduction }
    function ReduceStrength(func: TIRFunction): Boolean;
    
    { Helper }
    function NewTemp: Integer;
    procedure SetChanged;
  public
    constructor Create(module: TIRModule);
    destructor Destroy; override;
    
    { Führt alle Optimierungspässe aus }
    procedure Optimize;
    
    { Einzelne Pässe }
    procedure FoldConstants;
    procedure EliminateDead;
    procedure EliminateCSE;
    procedure PropagateCopies;
    procedure ReduceStrengths;
    
    { Statistik }
    property Changed: Boolean read FChanged;
    property PassCount: Integer read FPassCount;
  end;

implementation

{ TIROptimizer }

constructor TIROptimizer.Create(module: TIRModule);
begin
  inherited Create;
  FModule := module;
  FChanged := False;
  FPassCount := 0;
  FMaxPasses := 10;  // Maximum number of optimization passes
end;

destructor TIROptimizer.Destroy;
begin
  inherited Destroy;
end;

procedure TIROptimizer.SetChanged;
begin
  FChanged := True;
end;

function TIROptimizer.NewTemp: Integer;
begin
  // Wird für temporäre Konstanten verwendet
  Result := -1;
end;

{ ===== CONSTANT FOLDING ===== }

function TIROptimizer.IsConstExpr(instr: TIRInstr): Boolean;
begin
  // Eine Instruktion ist ein Konstantenausdruck wenn alle Operanden Konstanten sind
  Result := False;
  case instr.Op of
    irConstInt, irConstStr, irConstFloat:
      Result := True;
    irNeg, irNot, irBitNot:
      Result := (instr.Src1 >= 0);
    irAdd, irSub, irMul, irDiv, irMod,
    irAnd, irOr, irXor, irNor,
    irShl, irShr,
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe,
    irFAdd, irFSub, irFMul, irFDiv, irFNeg,
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
      Result := (instr.Src1 >= 0) and (instr.Src2 >= 0);
  end;
end;

function TIROptimizer.GetConstValue(instr: TIRInstr): Int64;
begin
  Result := instr.ImmInt;
end;

function TIROptimizer.GetConstFloat(instr: TIRInstr): Double;
begin
  Result := instr.ImmFloat;
end;

function TIROptimizer.EvaluateConstExpr(op: TIROpKind; src1, src2: Int64; immInt: Int64): Int64;
begin
  Result := 0;
  case op of
    irNeg:       Result := -src1;
    irNot:       Result := Ord(src1 = 0);  // Logical not: !x -> (x == 0)
    irBitNot:    Result := not src1;
    irAdd:       Result := src1 + src2;
    irSub:       Result := src1 - src2;
    irMul:       Result := src1 * src2;
    irDiv:
      if src2 <> 0 then Result := src1 div src2;
    irMod:
      if src2 <> 0 then Result := src1 mod src2;
    irAnd:       Result := Ord((src1 <> 0) and (src2 <> 0));
    irOr:        Result := Ord((src1 <> 0) or (src2 <> 0));
    irXor:       Result := Ord(((src1 <> 0) xor (src2 <> 0)));
    irNor:       Result := Ord(not (src1 or src2));
    irShl:       Result := src1 shl src2;
    irShr:       Result := src1 shr src2;
    irCmpEq:     Result := Ord(src1 = src2);
    irCmpNeq:    Result := Ord(src1 <> src2);
    irCmpLt:     Result := Ord(src1 < src2);
    irCmpLe:     Result := Ord(src1 <= src2);
    irCmpGt:     Result := Ord(src1 > src2);
    irCmpGe:     Result := Ord(src1 >= src2);
  end;
end;

function TIROptimizer.EvaluateConstFloat(op: TIROpKind; src1, src2: Double): Double;
begin
  Result := 0.0;
  case op of
    irFNeg:      Result := -src1;
    irFAdd:      Result := src1 + src2;
    irFSub:      Result := src1 - src2;
    irFMul:      Result := src1 * src2;
    irFDiv:
      if src2 <> 0.0 then Result := src1 / src2;
    irFCmpEq:    Result := Ord(src1 = src2);
    irFCmpNeq:   Result := Ord(src1 <> src2);
    irFCmpLt:    Result := Ord(src1 < src2);
    irFCmpLe:    Result := Ord(src1 <= src2);
    irFCmpGt:    Result := Ord(src1 > src2);
    irFCmpGe:    Result := Ord(src1 >= src2);
  end;
end;

function TIROptimizer.TryFoldInstruction(instr: TIRInstr; out folded: TIRInstr): Boolean;
var
  src1Val, src2Val: Int64;
  src1Float, src2Float: Double;
begin
  Result := False;
  folded := Default(TIRInstr);
  
  // Nur bestimmte Opcodes können gefaltet werden
  case instr.Op of
    irNeg, irNot, irBitNot:
      begin
        if instr.Src1 < 0 then Exit;
        folded.Op := irConstInt;
        folded.Dest := instr.Dest;
        if instr.Op = irFNeg then
        begin
          // Float negation
          folded.Op := irConstFloat;
          folded.ImmFloat := -instr.ImmFloat;
        end
        else
        begin
          folded.ImmInt := EvaluateConstExpr(instr.Op, instr.Src1, 0, instr.ImmInt);
        end;
        Result := True;
      end;
      
    irAdd, irSub, irMul, irDiv, irMod,
    irAnd, irOr, irXor, irNor,
    irShl, irShr,
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe:
      begin
        if (instr.Src1 < 0) or (instr.Src2 < 0) then Exit;
        folded.Op := irConstInt;
        folded.Dest := instr.Dest;
        folded.ImmInt := EvaluateConstExpr(instr.Op, instr.Src1, instr.Src2, instr.ImmInt);
        Result := True;
      end;
      
    irFAdd, irFSub, irFMul, irFDiv,
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
      begin
        if (instr.Src1 < 0) or (instr.Src2 < 0) then Exit;
        folded.Op := irConstFloat;
        folded.Dest := instr.Dest;
        // Für Float brauchen wir die tatsächlichen Werte - hier vereinfacht
        folded.ImmFloat := EvaluateConstFloat(instr.Op, instr.Src1, instr.Src2);
        Result := True;
      end;
  end;
end;

function TIROptimizer.FoldConstantsInFunc(func: TIRFunction): Boolean;
var
  i, j: Integer;
  instr, folded: TIRInstr;
  tempMap: array of Int64;
  tempIsConst: array of Boolean;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;
  
  // Temporary map: temp index -> constant value (if known)
  SetLength(tempMap, func.LocalCount + 1024);  // Reserve space for temps
  SetLength(tempIsConst, Length(tempMap));
  for i := 0 to High(tempMap) do
    tempIsConst[i] := False;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    // Versuche Konstante zu falten
    if TryFoldInstruction(instr, folded) then
    begin
      // Prüfe ob Operanden tatsächlich Konstanten sind
      if folded.Op in [irConstInt, irConstFloat] then
      begin
        // Ersetze mit gefalteter Konstanten
        func.Instructions[i] := folded;
        // Merke Konstantenwert für nachfolgende Verwendung
        if folded.Dest >= 0 then
        begin
          if folded.Dest < Length(tempMap) then
          begin
            if folded.Op = irConstInt then
              tempMap[folded.Dest] := folded.ImmInt
            else
              tempMap[folded.Dest] := Trunc(folded.ImmFloat);
            tempIsConst[folded.Dest] := True;
          end;
        end;
        Result := True;
        SetChanged;
      end;
    end
    else
    begin
      // Update constant tracking: load from local?
      case instr.Op of
        irConstInt:
          if instr.Dest >= 0 then
          begin
            if instr.Dest < Length(tempMap) then
            begin
              tempMap[instr.Dest] := instr.ImmInt;
              tempIsConst[instr.Dest] := True;
            end;
          end;
        irLoadLocal:
          if instr.Src1 >= 0 then
          begin
            // Load von lokaler Variable - Konstantenstatus aufheben
            if instr.Dest < Length(tempMap) then
              tempIsConst[instr.Dest] := False;
          end;
        else
          begin
            // Andere Operationen entfernen Konstantenstatus
            if instr.Dest >= 0 then
            begin
              if instr.Dest < Length(tempIsConst) then
                tempIsConst[instr.Dest] := False;
            end;
          end;
      end;
    end;
  end;
end;

procedure TIROptimizer.FoldConstants;
var
  i: Integer;
  func: TIRFunction;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    func := FModule.Functions[i];
    if Assigned(func) then
      FoldConstantsInFunc(func);
  end;
  
  WriteLn('[IR-Optimize] Constant Folding abgeschlossen.');
end;

{ ===== DEAD CODE ELIMINATION ===== }

function TIROptimizer.ComputeLiveness(func: TIRFunction; out liveDest: TBoolArray): Boolean;
var
  i, j: Integer;
  instr: TIRInstr;
  used: array of Boolean;
  maxLen: Integer;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;

  maxLen := func.LocalCount + Length(func.Instructions);
  SetLength(used, maxLen);
  for i := 0 to High(used) do
    used[i] := False;

  // Markiere alle Temps die gelesen werden
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];

    // Check all source operands
    if (instr.Src1 >= 0) and (instr.Src1 < Length(used)) then
      used[instr.Src1] := True;
    if (instr.Src2 >= 0) and (instr.Src2 < Length(used)) then
      used[instr.Src2] := True;
    if (instr.Src3 >= 0) and (instr.Src3 < Length(used)) then
      used[instr.Src3] := True;

    // Check argument temps for calls
    for j := 0 to High(instr.ArgTemps) do
      if (instr.ArgTemps[j] >= 0) and (instr.ArgTemps[j] < Length(used)) then
        used[instr.ArgTemps[j]] := True;
  end;

  // Export liveness info per Dest, without mutating ImmInt
  SetLength(liveDest, maxLen);
  for i := 0 to High(liveDest) do
    liveDest[i] := False;

  for i := 0 to High(func.Instructions) do
  begin
    if (func.Instructions[i].Dest >= 0) and (func.Instructions[i].Dest < Length(used)) then
      liveDest[func.Instructions[i].Dest] := used[func.Instructions[i].Dest];
  end;

  Result := True;
end;

function TIROptimizer.EliminateDeadCode(func: TIRFunction): Boolean;
var
  i: Integer;
  instr: TIRInstr;
  liveDest: TBoolArray;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;

  // Compute liveness
  if not ComputeLiveness(func, liveDest) then Exit;

  // Remove dead instructions (simple version: remove stores to unused temps)
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];

    // Store instructions whose dest is never used
    if (instr.Op = irStoreLocal) and (instr.Dest >= 0) then
    begin
      if (instr.Dest < Length(liveDest)) and (not liveDest[instr.Dest]) then
      begin
        // This store is dead
        func.Instructions[i].Op := irInvalid;
        Result := True;
        SetChanged;
      end;
    end;

    // Other operations that write to unused temps
    if (instr.Dest >= 0) and (instr.Op <> irLabel) and
       (instr.Op <> irJmp) and (instr.Op <> irBrTrue) and
       (instr.Op <> irBrFalse) and (instr.Op <> irReturn) then
    begin
      if (instr.Dest < Length(liveDest)) and (not liveDest[instr.Dest]) then
      begin
        // Check if it's a side-effect free operation
        case instr.Op of
          irConstInt, irConstStr, irConstFloat:
            begin
              // Constants without side effects can be removed if dest is dead
              func.Instructions[i].Op := irInvalid;
              Result := True;
              SetChanged;
            end;
        end;
      end;
    end;
  end;
  
  // Clean up invalid instructions
  if Result then
  begin
    for i := High(func.Instructions) downto 0 do
    begin
      if func.Instructions[i].Op = irInvalid then
      begin
        // Remove from array
        if i < Length(func.Instructions) - 1 then
          System.Move(func.Instructions[i+1], func.Instructions[i], 
                      (Length(func.Instructions) - i - 1) * SizeOf(TIRInstr));
        SetLength(func.Instructions, Length(func.Instructions) - 1);
      end;
    end;
  end;
end;

procedure TIROptimizer.EliminateDead;
var
  i: Integer;
  func: TIRFunction;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    func := FModule.Functions[i];
    if Assigned(func) then
      EliminateDeadCode(func);
  end;
  
  WriteLn('[IR-Optimize] Dead Code Elimination abgeschlossen.');
end;

{ ===== COMMON SUBEXPRESSION ELIMINATION ===== }

function TIROptimizer.GetInstructionSignature(instr: TIRInstr): string;
begin
  Result := '';
  case instr.Op of
    irAdd, irSub, irMul, irDiv, irMod,
    irAnd, irOr, irXor, irNor,
    irShl, irShr,
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe,
    irFAdd, irFSub, irFMul, irFDiv,
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe:
      Result := Format('%d:%d:%d', [Ord(instr.Op), instr.Src1, instr.Src2]);
    irLoadLocal:
      Result := Format('%d:%d', [Ord(instr.Op), instr.Src1]);
    irLoadGlobal:
      Result := Format('%d:%s', [Ord(instr.Op), instr.ImmStr]);
  else
    Result := '';
  end;
end;

function TIROptimizer.FindRedundantInstruction(func: TIRFunction; sig: string; startIdx: Integer): Integer;
var
  i: Integer;
  instr: TIRInstr;
begin
  Result := -1;
  for i := startIdx - 1 downto 0 do
  begin
    instr := func.Instructions[i];
    if GetInstructionSignature(instr) = sig then
    begin
      // Found a redundant instruction
      Result := i;
      Exit;
    end;
    
    // Stop at control flow boundaries
    case instr.Op of
      irLabel, irJmp, irBrTrue, irBrFalse, irReturn:
        Break;
    end;
  end;
end;

function TIROptimizer.EliminateCommonSubexpr(func: TIRFunction): Boolean;
var
  i: Integer;
  instr: TIRInstr;
  sig: string;
  redundantIdx: Integer;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    sig := GetInstructionSignature(instr);
    
    if sig <> '' then
    begin
      redundantIdx := FindRedundantInstruction(func, sig, i);
      if redundantIdx >= 0 then
      begin
        // Replace with move from redundant instruction's dest
        func.Instructions[i].Op := irAdd;  // Will be replaced
        func.Instructions[i].Src2 := -1;   // Mark as copy
        // Use the result from redundant instruction
        func.Instructions[i].Src1 := func.Instructions[redundantIdx].Dest;
        Result := True;
        SetChanged;
      end;
    end;
  end;
end;

procedure TIROptimizer.EliminateCSE;
var
  i: Integer;
  func: TIRFunction;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    func := FModule.Functions[i];
    if Assigned(func) then
      EliminateCommonSubexpr(func);
  end;
  
  WriteLn('[IR-Optimize] CSE abgeschlossen.');
end;

{ ===== COPY PROPAGATION ===== }

function TIROptimizer.PropagateCopies(func: TIRFunction): Boolean;
var
  i: Integer;
  instr: TIRInstr;
  copySrc: array of Integer;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;
  
  SetLength(copySrc, func.LocalCount + 1024);
  for i := 0 to High(copySrc) do
    copySrc[i] := -1;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    // Erkenne Kopien: add dest, src1, 0 (oder ähnlich)
    if (instr.Op = irAdd) and (instr.Src2 < 0) then
    begin
      // src2 ist -1, also ist das eine Kopie: dest := src1
      if (instr.Src1 >= 0) and (instr.Dest >= 0) then
      begin
        if instr.Dest < Length(copySrc) then
          copySrc[instr.Dest] := instr.Src1;
      end;
    end
    else
    begin
      // Andere Operationen brechen die Kopiekette
      if instr.Dest >= 0 then
      begin
        if instr.Dest < Length(copySrc) then
          copySrc[instr.Dest] := -1;
      end;
    end;
    
    // Propagiere Kopien in nachfolgenden Instruktionen
    if (instr.Src1 >= 0) and (instr.Src1 < Length(copySrc)) and (copySrc[instr.Src1] >= 0) then
    begin
      func.Instructions[i].Src1 := copySrc[instr.Src1];
      Result := True;
      SetChanged;
    end;
    if (instr.Src2 >= 0) and (instr.Src2 < Length(copySrc)) and (copySrc[instr.Src2] >= 0) then
    begin
      func.Instructions[i].Src2 := copySrc[instr.Src2];
      Result := True;
      SetChanged;
    end;
  end;
end;

procedure TIROptimizer.PropagateCopies;
var
  i: Integer;
  func: TIRFunction;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    func := FModule.Functions[i];
    if Assigned(func) then
      PropagateCopies(func);
  end;
  
  WriteLn('[IR-Optimize] Copy Propagation abgeschlossen.');
end;

{ ===== STRENGTH REDUCTION ===== }

function TIROptimizer.ReduceStrength(func: TIRFunction): Boolean;
var
  i: Integer;
  instr: TIRInstr;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    // Ersetze Multiplikation durch 2 mit Shift
    if (instr.Op = irMul) and (instr.Src2 >= 0) then
    begin
      if instr.Src2 = 2 then
      begin
        // x * 2 -> x + x (oder x << 1)
        func.Instructions[i].Op := irAdd;
        func.Instructions[i].Src2 := instr.Src1;
        Result := True;
        SetChanged;
      end
      else if instr.Src2 = 1 then
      begin
        // x * 1 -> x (Identität)
        func.Instructions[i].Op := irAdd;
        func.Instructions[i].Src2 := -1;  // Mark as copy
        Result := True;
        SetChanged;
      end
      else if instr.Src2 = 0 then
      begin
        // x * 0 -> 0
        func.Instructions[i].Op := irConstInt;
        func.Instructions[i].ImmInt := 0;
        func.Instructions[i].Src1 := -1;
        func.Instructions[i].Src2 := -1;
        Result := True;
        SetChanged;
      end;
    end;
    
    // Ersetze Division durch 2 mit Shift (nur für positive Zahlen)
    if (instr.Op = irDiv) and (instr.Src2 >= 0) then
    begin
      if instr.Src2 = 2 then
      begin
        // x / 2 -> x >> 1 (für positive Zahlen)
        func.Instructions[i].Op := irShr;
        func.Instructions[i].Src2 := 1;
        Result := True;
        SetChanged;
      end
      else if instr.Src2 = 1 then
      begin
        // x / 1 -> x
        func.Instructions[i].Op := irAdd;
        func.Instructions[i].Src2 := -1;
        Result := True;
        SetChanged;
      end;
    end;
    
    // Ersetze x + 0 mit x
    if instr.Op = irAdd then
    begin
      if (instr.Src1 >= 0) and (instr.Src1 = 0) then
      begin
        // 0 + x -> x
        func.Instructions[i].Op := irAdd;
        func.Instructions[i].Src1 := instr.Src2;
        func.Instructions[i].Src2 := -1;
        Result := True;
        SetChanged;
      end
      else if (instr.Src2 >= 0) and (instr.Src2 = 0) then
      begin
        // x + 0 -> x
        func.Instructions[i].Op := irAdd;
        func.Instructions[i].Src2 := -1;
        Result := True;
        SetChanged;
      end;
    end;
    
    // Ersetze x - 0 mit x
    if (instr.Op = irSub) and (instr.Src2 >= 0) and (instr.Src2 = 0) then
    begin
      func.Instructions[i].Op := irAdd;
      func.Instructions[i].Src2 := -1;
      Result := True;
      SetChanged;
    end;
  end;
end;

procedure TIROptimizer.ReduceStrengths;
var
  i: Integer;
  func: TIRFunction;
begin
  if not Assigned(FModule) then Exit;
  
  for i := 0 to High(FModule.Functions) do
  begin
    func := FModule.Functions[i];
    if Assigned(func) then
      ReduceStrength(func);
  end;
  
  WriteLn('[IR-Optimize] Strength Reduction abgeschlossen.');
end;

{ ===== MAIN OPTIMIZATION LOOP ===== }

procedure TIROptimizer.Optimize;
begin
  if not Assigned(FModule) then Exit;
  
  WriteLn('[IR-Optimize] Starte Optimierungspipeline...');
  
  FPassCount := 0;
  repeat
    FChanged := False;
    Inc(FPassCount);
    
    WriteLn('[IR-Optimize] Pass ', FPassCount);
    
    // 1. Constant Folding
    FoldConstants;
    
    // 2. Copy Propagation
    PropagateCopies;
    
    // 3. Strength Reduction
    ReduceStrengths;
    
    // 4. Common Subexpression Elimination
    EliminateCSE;
    
    // 5. Dead Code Elimination
    EliminateDead;
    
  until (not FChanged) or (FPassCount >= FMaxPasses);
  
  WriteLn('[IR-Optimize] Optimierung abgeschlossen nach ', FPassCount, ' Pässen.');
end;

end.
