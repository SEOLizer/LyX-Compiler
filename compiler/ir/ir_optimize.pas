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
    irFAdd, irFSub, irFMul, irFDiv, irFNeg, irFSqrt,
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
        // FP Constant Folding deaktiviert für Determinismus (aerospace-todo P2 #58)
        // Compiler-Rundung kann von Runtime-Rundung abweichen (z.B. x86 80-bit FPU vs SSE2)
        // Für @flight_crit-Funktionen muss FP-Berechnung deterministisch sein
        Exit;
        {
        if (instr.Src1 < 0) or (instr.Src2 < 0) then Exit;
        folded.Op := irConstFloat;
        folded.Dest := instr.Dest;
        // Für Float brauchen wir die tatsächlichen Werte - hier vereinfacht
        folded.ImmFloat := EvaluateConstFloat(instr.Op, instr.Src1, instr.Src2);
        Result := True;
        }
      end;
  end;
end;

function TIROptimizer.FoldConstantsInFunc(func: TIRFunction): Boolean;
var
  i: Integer;
  instr: TIRInstr;
  tempMap: array of Int64;
  tempIsConst: array of Boolean;
  src1Val, src2Val, foldedVal: Int64;
  canFold: Boolean;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;
  
  // Temporary map: temp index -> constant value (if known)
  SetLength(tempMap, func.LocalCount + 2048);  // Reserve space for temps
  SetLength(tempIsConst, Length(tempMap));
  for i := 0 to High(tempMap) do
    tempIsConst[i] := False;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    case instr.Op of
      irConstInt:
        begin
          // Track constant assignment
          if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
          begin
            tempMap[instr.Dest] := instr.ImmInt;
            tempIsConst[instr.Dest] := True;
          end;
        end;
        
      irConstFloat:
        begin
          // Track constant float (store as truncated int for now)
          if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
          begin
            tempMap[instr.Dest] := Trunc(instr.ImmFloat);
            tempIsConst[instr.Dest] := True;
          end;
        end;
        
      irLoadLocal, irLoadGlobal, irLoadElem, irCall, irCallBuiltin, irCallStruct:
        begin
          // Non-constant operations - mark dest as non-constant
          if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
            tempIsConst[instr.Dest] := False;
        end;
        
      irAdd, irSub, irMul, irDiv, irMod,
      irAnd, irOr, irXor, irNor,
      irShl, irShr,
      irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe:
        begin
          // Binary operation: check if BOTH operands are known constants
          canFold := False;
          src1Val := 0;
          src2Val := 0;
          
          if (instr.Src1 >= 0) and (instr.Src1 < Length(tempIsConst)) and tempIsConst[instr.Src1] then
          begin
            src1Val := tempMap[instr.Src1];
            if (instr.Src2 >= 0) and (instr.Src2 < Length(tempIsConst)) and tempIsConst[instr.Src2] then
            begin
              src2Val := tempMap[instr.Src2];
              canFold := True;
            end;
          end;
          
          if canFold then
          begin
            // Both operands are constants - fold the operation
            foldedVal := EvaluateConstExpr(instr.Op, src1Val, src2Val, instr.ImmInt);
            
            // Replace instruction with constant
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := foldedVal;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            
            // Track the result as constant
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := foldedVal;
              tempIsConst[instr.Dest] := True;
            end;
            
            Result := True;
            SetChanged;
          end
          else
          begin
            // Cannot fold - mark dest as non-constant
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irNeg, irNot, irBitNot:
        begin
          // Unary operation: check if operand is constant
          canFold := False;
          src1Val := 0;
          
          if (instr.Src1 >= 0) and (instr.Src1 < Length(tempIsConst)) and tempIsConst[instr.Src1] then
          begin
            src1Val := tempMap[instr.Src1];
            canFold := True;
          end;
          
          if canFold then
          begin
            foldedVal := EvaluateConstExpr(instr.Op, src1Val, 0, instr.ImmInt);
            
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := foldedVal;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := foldedVal;
              tempIsConst[instr.Dest] := True;
            end;
            
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
    else
      begin
        // Any other operation that produces a result - mark as non-constant
        if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
          tempIsConst[instr.Dest] := False;
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
       (instr.Op <> irBrFalse) and (instr.Op <> irFuncExit) then
    begin
      if (instr.Dest < Length(liveDest)) and (not liveDest[instr.Dest]) then
      begin
        // DON'T remove constants - they might be needed for correct code generation
        // even if liveness analysis doesn't detect it (e.g., branch conditions)
        // This is a conservative fix to ensure correctness
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
    // NOTE: irLoadLocal and irLoadGlobal are NOT included for CSE because
    // the underlying memory location can change between loads (e.g., dynamic
    // arrays have their ptr modified by push operations). Eliminating
    // redundant loads would be incorrect if a store or side-effect occurs
    // between them.
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
      irLabel, irJmp, irBrTrue, irBrFalse, irFuncExit:
        Break;
    end;
  end;
end;

function TIROptimizer.EliminateCommonSubexpr(func: TIRFunction): Boolean;
var
  i, j, k: Integer;
  instr: TIRInstr;
  sig: string;
  redundantIdx: Integer;
  prevDest, curDest: Integer;
  newLen: Integer;
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
        prevDest := func.Instructions[redundantIdx].Dest;
        curDest  := func.Instructions[i].Dest;

        // Rewrite all forward uses of curDest to prevDest in-place
        for j := i + 1 to High(func.Instructions) do
        begin
          if func.Instructions[j].Src1 = curDest then
            func.Instructions[j].Src1 := prevDest;
          if func.Instructions[j].Src2 = curDest then
            func.Instructions[j].Src2 := prevDest;
          if func.Instructions[j].Src3 = curDest then
            func.Instructions[j].Src3 := prevDest;
          for k := 0 to High(func.Instructions[j].ArgTemps) do
            if func.Instructions[j].ArgTemps[k] = curDest then
              func.Instructions[j].ArgTemps[k] := prevDest;
        end;

        // NOP the now-redundant instruction; DCE will compact
        func.Instructions[i].Op := irInvalid;
        Result := True;
        SetChanged;
      end;
    end;
  end;

  // Compact: remove all irInvalid instructions produced above
  if Result then
  begin
    newLen := 0;
    for i := 0 to High(func.Instructions) do
      if func.Instructions[i].Op <> irInvalid then
      begin
        func.Instructions[newLen] := func.Instructions[i];
        Inc(newLen);
      end;
    SetLength(func.Instructions, newLen);
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
    
    // Alle Definitionen brechen die Kopiekette für dieses Dest
    if instr.Dest >= 0 then
    begin
      if instr.Dest < Length(copySrc) then
        copySrc[instr.Dest] := -1;
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
  tempMap: array of Int64;
  tempIsConst: array of Boolean;
  src1Val, src2Val: Int64;
  src1IsConst, src2IsConst: Boolean;
  shiftAmt: Integer;
begin
  Result := False;
  if not Assigned(func) or not Assigned(func.Instructions) then Exit;
  
  // Track constant values in temps
  SetLength(tempMap, func.LocalCount + 2048);
  SetLength(tempIsConst, Length(tempMap));
  for i := 0 to High(tempMap) do
    tempIsConst[i] := False;
  
  for i := 0 to High(func.Instructions) do
  begin
    instr := func.Instructions[i];
    
    // Update constant tracking
    case instr.Op of
      irConstInt:
        if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
        begin
          tempMap[instr.Dest] := instr.ImmInt;
          tempIsConst[instr.Dest] := True;
        end;
      irConstFloat:
        if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
        begin
          tempMap[instr.Dest] := Trunc(instr.ImmFloat);
          tempIsConst[instr.Dest] := True;
        end;
    end;
    
    // Get constant status of operands
    src1IsConst := (instr.Src1 >= 0) and (instr.Src1 < Length(tempIsConst)) and tempIsConst[instr.Src1];
    src2IsConst := (instr.Src2 >= 0) and (instr.Src2 < Length(tempIsConst)) and tempIsConst[instr.Src2];
    if src1IsConst then src1Val := tempMap[instr.Src1] else src1Val := 0;
    if src2IsConst then src2Val := tempMap[instr.Src2] else src2Val := 0;
    
    // Apply strength reductions
    case instr.Op of
      irMul:
        begin
          // x * 0 -> 0
          if src2IsConst and (src2Val = 0) then
          begin
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := 0;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := 0;
              tempIsConst[instr.Dest] := True;
            end;
            Result := True;
            SetChanged;
          end
          // 0 * x -> 0
          else if src1IsConst and (src1Val = 0) then
          begin
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := 0;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := 0;
              tempIsConst[instr.Dest] := True;
            end;
            Result := True;
            SetChanged;
          end
          // x * 1 -> x (identity)
          else if src2IsConst and (src2Val = 1) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy: dest := src1
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // 1 * x -> x (identity)
          else if src1IsConst and (src1Val = 1) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src1 := instr.Src2;
            func.Instructions[i].Src2 := -1;  // Mark as copy: dest := src2
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // x * 2 -> x + x (or x << 1)
          else if src2IsConst and (src2Val = 2) then
          begin
            func.Instructions[i].Op := irShl;
            // Create a temp for constant 1
            func.Instructions[i].Src2 := -1;  // Will use ImmInt
            func.Instructions[i].ImmInt := 1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // x * power-of-2 -> x << log2(val)
          else if src2IsConst and (src2Val > 2) and ((src2Val and (src2Val - 1)) = 0) then
          begin
            // Calculate log2
            shiftAmt := 0;
            while (Int64(1) shl shiftAmt) < src2Val do
              Inc(shiftAmt);
            func.Instructions[i].Op := irShl;
            func.Instructions[i].Src2 := -1;
            func.Instructions[i].ImmInt := shiftAmt;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          else
          begin
            // Non-optimizable mul - mark dest as non-constant
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irDiv:
        begin
          // x / 1 -> x
          if src2IsConst and (src2Val = 1) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // x / power-of-2 -> x >> log2(val) (only for unsigned or known positive)
          // NOTE: For signed division, this is only correct for non-negative values
          // We skip this optimization for now to be safe
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irAdd:
        begin
          // x + 0 -> x
          if src2IsConst and (src2Val = 0) then
          begin
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // 0 + x -> x
          else if src1IsConst and (src1Val = 0) then
          begin
            func.Instructions[i].Src1 := instr.Src2;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irSub:
        begin
          // x - 0 -> x
          if src2IsConst and (src2Val = 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // x - x -> 0 (same temp)
          else if (instr.Src1 = instr.Src2) and (instr.Src1 >= 0) then
          begin
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := 0;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := 0;
              tempIsConst[instr.Dest] := True;
            end;
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irShl, irShr:
        begin
          // x << 0 -> x, x >> 0 -> x
          if src2IsConst and (src2Val = 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // 0 << x -> 0, 0 >> x -> 0
          else if src1IsConst and (src1Val = 0) then
          begin
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := 0;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := 0;
              tempIsConst[instr.Dest] := True;
            end;
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irAnd:
        begin
          // x & 0 -> 0
          if (src1IsConst and (src1Val = 0)) or (src2IsConst and (src2Val = 0)) then
          begin
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := 0;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := 0;
              tempIsConst[instr.Dest] := True;
            end;
            Result := True;
            SetChanged;
          end
          // x & x -> x (same temp)
          else if (instr.Src1 = instr.Src2) and (instr.Src1 >= 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irOr:
        begin
          // x | 0 -> x
          if src2IsConst and (src2Val = 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // 0 | x -> x
          else if src1IsConst and (src1Val = 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src1 := instr.Src2;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // x | x -> x (same temp)
          else if (instr.Src1 = instr.Src2) and (instr.Src1 >= 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irXor:
        begin
          // x ^ 0 -> x
          if src2IsConst and (src2Val = 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // 0 ^ x -> x
          else if src1IsConst and (src1Val = 0) then
          begin
            func.Instructions[i].Op := irAdd;
            func.Instructions[i].Src1 := instr.Src2;
            func.Instructions[i].Src2 := -1;  // Mark as copy
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
            Result := True;
            SetChanged;
          end
          // x ^ x -> 0 (same temp)
          else if (instr.Src1 = instr.Src2) and (instr.Src1 >= 0) then
          begin
            func.Instructions[i].Op := irConstInt;
            func.Instructions[i].ImmInt := 0;
            func.Instructions[i].Src1 := -1;
            func.Instructions[i].Src2 := -1;
            if (instr.Dest >= 0) and (instr.Dest < Length(tempMap)) then
            begin
              tempMap[instr.Dest] := 0;
              tempIsConst[instr.Dest] := True;
            end;
            Result := True;
            SetChanged;
          end
          else
          begin
            if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
              tempIsConst[instr.Dest] := False;
          end;
        end;
        
      irStoreLocal, irStoreGlobal, irStoreElem, irStoreElemDyn, irStoreField:
        begin
          // Store operations don't define temps, they store to memory
          // Don't modify tempIsConst for these
        end;
        
      irLoadLocal, irLoadGlobal, irLoadElem, irLoadField, irLoadLocalAddr, irLoadGlobalAddr:
        begin
          // Load operations define temps with unknown values
          if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
            tempIsConst[instr.Dest] := False;
        end;
        
      irCall, irCallBuiltin, irCallStruct, irDynArrayPush, irDynArrayPop, 
      irDynArrayLen, irDynArrayFree, irAlloc, irFree:
        begin
          // Call operations and special ops - mark dest as non-constant
          if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
            tempIsConst[instr.Dest] := False;
        end;
        
      irLabel, irJmp, irBrTrue, irBrFalse, irFuncExit:
        begin
          // Control flow - no temp modifications
        end;
        
      irConstInt, irConstFloat, irConstStr:
        begin
          // Constants are already handled at the beginning of the loop
          // Don't modify tempIsConst here
        end;
        
    else
      begin
        // Other operations - mark dest as non-constant only if Dest is a valid temp
        // (not a local variable index which would be used by Store operations)
        if (instr.Dest >= 0) and (instr.Dest < Length(tempIsConst)) then
          tempIsConst[instr.Dest] := False;
      end;
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
