{$mode objfpc}{$H+}
program test_reference_interpreter;

{
  Reference Interpreter für Lyx
  DO-178C Section 1.2: Compiler-Verifikation
  
  Dieser Interpreter führt Lyx-IR direkt aus und dient als Referenz-Implementierung
  zur Verifikation der Codegenerierung. Der generierte Maschinencode muss die gleiche
  Semantik wie der Reference Interpreter haben (Bisimulation).
}

uses
  SysUtils, Classes;

type
  TIROpKind = (
    irInvalid, irConstInt, irConstStr, irConstFloat,
    irLoadLocal, irStoreLocal, irLoadLocalAddr,
    irLoadGlobal, irStoreGlobal, irLoadGlobalAddr, irLoadStructAddr,
    irAdd, irSub, irMul, irDiv, irMod, irNeg, irNot,
    irAnd, irOr, irXor, irNor,
    irBitAnd, irBitOr, irBitXor, irBitNot,
    irShl, irShr,
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe,
    irFAdd, irFSub, irFMul, irFDiv, irFNeg,
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe,
    irSExt, irZExt, irTrunc, irFToI, irIToF, irCast,
    irJmp, irBrTrue, irBrFalse, irLabel, irFuncExit, irReturnStruct,
    irCall, irCallBuiltin, irCallStruct, irVarCall,
    irStackAlloc, irStoreElem, irLoadElem, irStoreElemDyn,
    irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree,
    irLoadField, irStoreField, irLoadFieldHeap, irStoreFieldHeap,
    irAlloc, irFree, irLoadCaptured, irPoolAlloc, irPoolFree,
    irPushHandler, irPopHandler, irLoadHandlerExn, irThrow,
    irPanic,
    irSIMDAdd, irSIMDSub, irSIMDMul, irSIMDDiv,
    irSIMDAnd, irSIMDOr, irSIMDXor, irSIMDNeg,
    irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe,
    irSIMDLoadElem, irSIMDStoreElem,
    irMapNew, irMapGet, irMapSet, irMapContains, irMapRemove, irMapLen, irMapFree,
    irSetNew, irSetAdd, irSetContains, irSetRemove, irSetLen, irSetFree,
    irIsType, irInspect
  );

  TIRInstr = record
    Op: TIROpKind;
    Dest, Src1, Src2, Src3: Integer;
    ImmInt: Int64;
    ImmStr: string;
    VMTIndex: Integer;
  end;

  TIRFunction = record
    Name: string;
    LocalCount: Integer;
    ParamCount: Integer;
    Instructions: array of TIRInstr;
  end;

var
  TotalTests, PassedTests, FailedTests: Integer;

type
  TReferenceMemory = class
  private
    FStack: array of Int64;
    FGlobals: array of Int64;
    FStrings: TStringList;
    FHeapPtr: UInt64;
    FMaps: array of record
      Addr: UInt64;
      Len, Cap: Int64;
      Keys, Values: array of Int64;
    end;
    FSets: array of record
      Addr: UInt64;
      Len, Cap: Int64;
      Values: array of Int64;
    end;
    
  public
    constructor Create;
    destructor Destroy; override;
    
    procedure StoreGlobal(idx: Integer; value: Int64);
    function LoadGlobal(idx: Integer): Int64;
    function AllocString(const s: string): Int64;
    function GetString(idx: Int64): string;
    function HeapAlloc(size: Int64): Int64;
    procedure HeapFree(addr: Int64);
    function MapNew: Int64;
    procedure MapSet(mapAddr: Int64; key, value: Int64);
    function MapGet(mapAddr: Int64; key: Int64; out found: Boolean): Int64;
    function MapContains(mapAddr: Int64; key: Int64): Boolean;
    function MapLen(mapAddr: Int64): Int64;
    procedure MapFree(mapAddr: Int64);
    function SetNew: Int64;
    procedure SetAdd(setAddr: Int64; value: Int64);
    function SetContains(setAddr: Int64; value: Int64): Boolean;
    function SetLen(setAddr: Int64): Int64;
    procedure SetFree(setAddr: Int64);
  end;

constructor TReferenceMemory.Create;
begin
  inherited Create;
  SetLength(FStack, 1024 * 64);
  SetLength(FGlobals, 256);
  FStrings := TStringList.Create;
  FHeapPtr := $10000000;
end;

destructor TReferenceMemory.Destroy;
begin
  FStrings.Free;
  inherited Destroy;
end;

procedure TReferenceMemory.StoreGlobal(idx: Integer; value: Int64);
begin
  if (idx >= 0) and (idx < Length(FGlobals)) then FGlobals[idx] := value;
end;

function TReferenceMemory.LoadGlobal(idx: Integer): Int64;
begin
  if (idx >= 0) and (idx < Length(FGlobals)) then Result := FGlobals[idx] else Result := 0;
end;

function TReferenceMemory.AllocString(const s: string): Int64;
begin
  Result := FStrings.Add(s);
end;

function TReferenceMemory.GetString(idx: Int64): string;
begin
  if (idx >= 0) and (idx < FStrings.Count) then Result := FStrings[idx] else Result := '';
end;

function TReferenceMemory.HeapAlloc(size: Int64): Int64;
begin
  Result := FHeapPtr;
  Inc(FHeapPtr, size);
end;

procedure TReferenceMemory.HeapFree(addr: Int64);
begin
end;

function TReferenceMemory.MapNew: Int64;
var
  i: Integer;
begin
  Result := FHeapPtr;
  Inc(FHeapPtr, 64);
  i := Length(FMaps);
  SetLength(FMaps, i + 1);
  FMaps[i].Addr := Result;
  FMaps[i].Len := 0;
  FMaps[i].Cap := 8;
  SetLength(FMaps[i].Keys, 8);
  SetLength(FMaps[i].Values, 8);
end;

procedure TReferenceMemory.MapSet(mapAddr: Int64; key, value: Int64);
var
  i, j: Integer;
begin
  for i := 0 to High(FMaps) do
  begin
    if FMaps[i].Addr = mapAddr then
    begin
      for j := 0 to FMaps[i].Len - 1 do
      begin
        if FMaps[i].Keys[j] = key then
        begin
          FMaps[i].Values[j] := value;
          Exit;
        end;
      end;
      if FMaps[i].Len < FMaps[i].Cap then
      begin
        FMaps[i].Keys[FMaps[i].Len] := key;
        FMaps[i].Values[FMaps[i].Len] := value;
        Inc(FMaps[i].Len);
      end;
      Exit;
    end;
  end;
end;

function TReferenceMemory.MapGet(mapAddr: Int64; key: Int64; out found: Boolean): Int64;
var
  i, j: Integer;
begin
  found := False;
  Result := 0;
  for i := 0 to High(FMaps) do
  begin
    if FMaps[i].Addr = mapAddr then
    begin
      for j := 0 to FMaps[i].Len - 1 do
      begin
        if FMaps[i].Keys[j] = key then
        begin
          Result := FMaps[i].Values[j];
          found := True;
          Exit;
        end;
      end;
      Exit;
    end;
  end;
end;

function TReferenceMemory.MapContains(mapAddr: Int64; key: Int64): Boolean;
var
  dummy: Boolean;
  tmp: Int64;
begin
  dummy := False;
  tmp := MapGet(mapAddr, key, dummy);
  Result := dummy;
end;

function TReferenceMemory.MapLen(mapAddr: Int64): Int64;
var
  i: Integer;
begin
  for i := 0 to High(FMaps) do
    if FMaps[i].Addr = mapAddr then begin Result := FMaps[i].Len; Exit; end;
  Result := 0;
end;

procedure TReferenceMemory.MapFree(mapAddr: Int64);
begin
end;

function TReferenceMemory.SetNew: Int64;
var
  i: Integer;
begin
  Result := FHeapPtr;
  Inc(FHeapPtr, 64);
  i := Length(FSets);
  SetLength(FSets, i + 1);
  FSets[i].Addr := Result;
  FSets[i].Len := 0;
  FSets[i].Cap := 8;
  SetLength(FSets[i].Values, 8);
end;

procedure TReferenceMemory.SetAdd(setAddr: Int64; value: Int64);
var
  i: Integer;
begin
  for i := 0 to High(FSets) do
    if FSets[i].Addr = setAddr then
    begin
      if FSets[i].Len < FSets[i].Cap then
      begin
        FSets[i].Values[FSets[i].Len] := value;
        Inc(FSets[i].Len);
      end;
      Exit;
    end;
end;

function TReferenceMemory.SetContains(setAddr: Int64; value: Int64): Boolean;
var
  i, j: Integer;
begin
  for i := 0 to High(FSets) do
    if FSets[i].Addr = setAddr then
    begin
      for j := 0 to FSets[i].Len - 1 do
        if FSets[i].Values[j] = value then begin Result := True; Exit; end;
      Result := False;
      Exit;
    end;
  Result := False;
end;

function TReferenceMemory.SetLen(setAddr: Int64): Int64;
var
  i: Integer;
begin
  for i := 0 to High(FSets) do
    if FSets[i].Addr = setAddr then begin Result := FSets[i].Len; Exit; end;
  Result := 0;
end;

procedure TReferenceMemory.SetFree(setAddr: Int64);
begin
end;

{ ============================================================================ }
{ Reference IR Interpreter                                                    }
{ ============================================================================ }

type
  TReferenceInterpreter = class
  private
    FMem: TReferenceMemory;
    FLocals: array of Int64;
    FLocalCount: Integer;
    FFound: Boolean;
    
    function GetSlot(idx: Integer): Int64;
    procedure SetSlot(idx: Integer; value: Int64);
    
  public
    constructor Create;
    destructor Destroy; override;
    function ExecuteFunction(var fn: TIRFunction): Int64;
    procedure ExecuteInstruction(const instr: TIRInstr);
  end;

constructor TReferenceInterpreter.Create;
begin
  inherited Create;
  FMem := TReferenceMemory.Create;
end;

destructor TReferenceInterpreter.Destroy;
begin
  FMem.Free;
  inherited Destroy;
end;

function TReferenceInterpreter.GetSlot(idx: Integer): Int64;
begin
  if (idx >= 0) and (idx < Length(FLocals)) then Result := FLocals[idx] else Result := 0;
end;

procedure TReferenceInterpreter.SetSlot(idx: Integer; value: Int64);
begin
  if (idx >= 0) and (idx < Length(FLocals)) then FLocals[idx] := value;
end;

function TReferenceInterpreter.ExecuteFunction(var fn: TIRFunction): Int64;
var
  i, maxTemp: Integer;
begin
  FLocalCount := fn.LocalCount;
  maxTemp := 0;
  for i := 0 to High(fn.Instructions) do
  begin
    if fn.Instructions[i].Dest > maxTemp then maxTemp := fn.Instructions[i].Dest;
    if fn.Instructions[i].Src1 > maxTemp then maxTemp := fn.Instructions[i].Src1;
    if fn.Instructions[i].Src2 > maxTemp then maxTemp := fn.Instructions[i].Src2;
  end;
  SetLength(FLocals, FLocalCount + maxTemp + 1);
  
  for i := 0 to High(fn.Instructions) do
    ExecuteInstruction(fn.Instructions[i]);
  
  Result := GetSlot(FLocalCount);
end;

procedure TReferenceInterpreter.ExecuteInstruction(const instr: TIRInstr);
var
  slotIdx: Integer;
  v0, v1: Int64;
  found: Boolean;
begin
  case instr.Op of
    irConstInt:
      SetSlot(FLocalCount + instr.Dest, instr.ImmInt);
      
    irConstStr:
      SetSlot(FLocalCount + instr.Dest, FMem.AllocString(instr.ImmStr));
      
    irConstFloat:
      SetSlot(FLocalCount + instr.Dest, 0);
      
    irLoadLocal:
      SetSlot(FLocalCount + instr.Dest, GetSlot(instr.Src1));
      
    irStoreLocal:
      SetSlot(instr.Dest, GetSlot(FLocalCount + instr.Src1));
      
    irLoadGlobal:
      SetSlot(FLocalCount + instr.Dest, FMem.LoadGlobal(instr.Src1));
      
    irStoreGlobal:
      FMem.StoreGlobal(instr.Dest, GetSlot(FLocalCount + instr.Src1));
      
    irLoadLocalAddr:
      SetSlot(FLocalCount + instr.Dest, instr.Src1);
      
    irLoadGlobalAddr:
      SetSlot(FLocalCount + instr.Dest, 0);
      
    irAdd:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) + GetSlot(FLocalCount + instr.Src2));
      
    irSub:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) - GetSlot(FLocalCount + instr.Src2));
      
    irMul:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) * GetSlot(FLocalCount + instr.Src2));
      
    irDiv:
      begin
        v1 := GetSlot(FLocalCount + instr.Src2);
        if v1 <> 0 then
          SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) div v1)
        else
          SetSlot(FLocalCount + instr.Dest, 0);
      end;
      
    irMod:
      begin
        v1 := GetSlot(FLocalCount + instr.Src2);
        if v1 <> 0 then
          SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) mod v1)
        else
          SetSlot(FLocalCount + instr.Dest, 0);
      end;
      
    irNeg:
      SetSlot(FLocalCount + instr.Dest, -GetSlot(FLocalCount + instr.Src1));
      
    irNot:
      SetSlot(FLocalCount + instr.Dest, not GetSlot(FLocalCount + instr.Src1));
      
    irAnd:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) and GetSlot(FLocalCount + instr.Src2));
      
    irOr:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) or GetSlot(FLocalCount + instr.Src2));
      
    irXor:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) xor GetSlot(FLocalCount + instr.Src2));
      
    irNor:
      SetSlot(FLocalCount + instr.Dest, not (GetSlot(FLocalCount + instr.Src1) or GetSlot(FLocalCount + instr.Src2)));
      
    irBitAnd:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) and GetSlot(FLocalCount + instr.Src2));
      
    irBitOr:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) or GetSlot(FLocalCount + instr.Src2));
      
    irBitXor:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) xor GetSlot(FLocalCount + instr.Src2));
      
    irBitNot:
      SetSlot(FLocalCount + instr.Dest, not GetSlot(FLocalCount + instr.Src1));
      
    irShl:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) shl GetSlot(FLocalCount + instr.Src2));
      
    irShr:
      SetSlot(FLocalCount + instr.Dest, GetSlot(FLocalCount + instr.Src1) shr GetSlot(FLocalCount + instr.Src2));
      
    irCmpEq:
      if GetSlot(FLocalCount + instr.Src1) = GetSlot(FLocalCount + instr.Src2) then
        SetSlot(FLocalCount + instr.Dest, 1)
      else
        SetSlot(FLocalCount + instr.Dest, 0);
      
    irCmpNeq:
      if GetSlot(FLocalCount + instr.Src1) <> GetSlot(FLocalCount + instr.Src2) then
        SetSlot(FLocalCount + instr.Dest, 1)
      else
        SetSlot(FLocalCount + instr.Dest, 0);
      
    irCmpLt:
      if GetSlot(FLocalCount + instr.Src1) < GetSlot(FLocalCount + instr.Src2) then
        SetSlot(FLocalCount + instr.Dest, 1)
      else
        SetSlot(FLocalCount + instr.Dest, 0);
      
    irCmpLe:
      if GetSlot(FLocalCount + instr.Src1) <= GetSlot(FLocalCount + instr.Src2) then
        SetSlot(FLocalCount + instr.Dest, 1)
      else
        SetSlot(FLocalCount + instr.Dest, 0);
      
    irCmpGt:
      if GetSlot(FLocalCount + instr.Src1) > GetSlot(FLocalCount + instr.Src2) then
        SetSlot(FLocalCount + instr.Dest, 1)
      else
        SetSlot(FLocalCount + instr.Dest, 0);
      
    irCmpGe:
      if GetSlot(FLocalCount + instr.Src1) >= GetSlot(FLocalCount + instr.Src2) then
        SetSlot(FLocalCount + instr.Dest, 1)
      else
        SetSlot(FLocalCount + instr.Dest, 0);
      
    irMapNew:
      SetSlot(FLocalCount + instr.Dest, FMem.MapNew);
      
    irSetNew:
      SetSlot(FLocalCount + instr.Dest, FMem.SetNew);
      
    irMapSet:
      FMem.MapSet(GetSlot(FLocalCount + instr.Src1),
                  GetSlot(FLocalCount + instr.Src2),
                  GetSlot(FLocalCount + instr.Src3));
      
    irMapGet:
      begin
        FFound := False;
        SetSlot(FLocalCount + instr.Dest, FMem.MapGet(GetSlot(FLocalCount + instr.Src1),
                                 GetSlot(FLocalCount + instr.Src2), FFound));
      end;
      
    irMapContains:
      SetSlot(FLocalCount + instr.Dest, Ord(FMem.MapContains(GetSlot(FLocalCount + instr.Src1),
                              GetSlot(FLocalCount + instr.Src2))));
      
    irSetContains:
      SetSlot(FLocalCount + instr.Dest, Ord(FMem.SetContains(GetSlot(FLocalCount + instr.Src1),
                              GetSlot(FLocalCount + instr.Src2))));
      
    irMapLen:
      SetSlot(FLocalCount + instr.Dest, FMem.MapLen(GetSlot(FLocalCount + instr.Src1)));
      
    irSetLen:
      SetSlot(FLocalCount + instr.Dest, FMem.SetLen(GetSlot(FLocalCount + instr.Src1)));
      
    irSetAdd:
      FMem.SetAdd(GetSlot(FLocalCount + instr.Src1), GetSlot(FLocalCount + instr.Src2));
      
    irFuncExit:
      if instr.Src1 >= 0 then
        SetSlot(FLocalCount, GetSlot(FLocalCount + instr.Src1));
      
    irPanic:
      begin
        WriteLn('PANIC: ', FMem.GetString(GetSlot(FLocalCount + instr.Src1)));
        Halt(1);
      end;
      
    // Stubs
    irSExt, irZExt, irTrunc, irFToI, irIToF, irCast,
    irFAdd, irFSub, irFMul, irFDiv, irFNeg,
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe,
    irLoadStructAddr, irCallStruct, irVarCall, irReturnStruct,
    irStackAlloc, irStoreElem, irLoadElem, irStoreElemDyn,
    irLoadField, irStoreField, irLoadFieldHeap, irStoreFieldHeap,
    irAlloc, irFree, irLoadCaptured, irPoolAlloc, irPoolFree,
    irPushHandler, irPopHandler, irLoadHandlerExn, irThrow,
    irSIMDAdd, irSIMDSub, irSIMDMul, irSIMDDiv,
    irSIMDAnd, irSIMDOr, irSIMDXor, irSIMDNeg,
    irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe,
    irSIMDLoadElem, irSIMDStoreElem,
    irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree,
    irMapFree, irSetFree, irMapRemove, irSetRemove,
    irIsType, irInspect:
      if instr.Dest >= 0 then
        SetSlot(FLocalCount + instr.Dest, 0);
  end;
end;

{ ============================================================================ }
{ Tests                                                                       }
{ ============================================================================ }

procedure AssertEqual(const testName: string; expected, actual: Int64);
begin
  Inc(TotalTests);
  if expected = actual then
  begin
    Inc(PassedTests);
    WriteLn('[PASS] ', testName);
  end
  else
  begin
    Inc(FailedTests);
    WriteLn('[FAIL] ', testName, ' - Expected: ', expected, ', Got: ', actual);
  end;
end;

procedure MakeInstr(var fn: TIRFunction; idx: Integer; op: TIROpKind; dest, src1, src2: Integer; imm: Int64);
begin
  fn.Instructions[idx].Op := op;
  fn.Instructions[idx].Dest := dest;
  fn.Instructions[idx].Src1 := src1;
  fn.Instructions[idx].Src2 := src2;
  fn.Instructions[idx].ImmInt := imm;
end;

procedure TestArithmetic;
var
  interp: TReferenceInterpreter;
  fn: TIRFunction;
begin
  WriteLn;
  WriteLn('=== Arithmetic Tests ===');
  
  interp := TReferenceInterpreter.Create;
  try
    // Test irAdd: 10 + 20 = 30
    SetLength(fn.Instructions, 4);
    fn.LocalCount := 0;
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 10);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 20);
    MakeInstr(fn, 2, irAdd, 2, 0, 1, 0);
    fn.Instructions[3].Op := irFuncExit;
    fn.Instructions[3].Src1 := 2;
    AssertEqual('irAdd: 10 + 20', 30, interp.ExecuteFunction(fn));
    
    // Test irSub: 50 - 15 = 35
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 50);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 15);
    MakeInstr(fn, 2, irSub, 2, 0, 1, 0);
    AssertEqual('irSub: 50 - 15', 35, interp.ExecuteFunction(fn));
    
    // Test irMul: 6 * 7 = 42
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 6);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 7);
    MakeInstr(fn, 2, irMul, 2, 0, 1, 0);
    AssertEqual('irMul: 6 * 7', 42, interp.ExecuteFunction(fn));
    
    // Test irDiv: 100 / 4 = 25
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 100);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 4);
    MakeInstr(fn, 2, irDiv, 2, 0, 1, 0);
    AssertEqual('irDiv: 100 / 4', 25, interp.ExecuteFunction(fn));
    
    // Test irMod: 17 % 5 = 2
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 17);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 5);
    MakeInstr(fn, 2, irMod, 2, 0, 1, 0);
    AssertEqual('irMod: 17 % 5', 2, interp.ExecuteFunction(fn));
    
    // Test irNeg: -42
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 42);
    MakeInstr(fn, 1, irNeg, 2, 0, 0, 0);
    MakeInstr(fn, 2, irFuncExit, 0, 0, 0, 0);
    fn.Instructions[2].Src1 := 2;
    SetLength(fn.Instructions, 3);
    AssertEqual('irNeg: -42', -42, interp.ExecuteFunction(fn));
  finally
    interp.Free;
  end;
end;

procedure TestBitOps;
var
  interp: TReferenceInterpreter;
  fn: TIRFunction;
begin
  WriteLn;
  WriteLn('=== Bit Operations Tests ===');
  
  interp := TReferenceInterpreter.Create;
  try
    SetLength(fn.Instructions, 4);
    fn.LocalCount := 0;
    fn.Instructions[3].Op := irFuncExit;
    fn.Instructions[3].Src1 := 2;
    
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, $F0);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, $0F);
    
    MakeInstr(fn, 2, irAnd, 2, 0, 1, 0);
    AssertEqual('irAnd: 0xF0 & 0x0F', 0, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 2, irOr, 2, 0, 1, 0);
    AssertEqual('irOr: 0xF0 | 0x0F', $FF, interp.ExecuteFunction(fn));
    
    // irXor: need to reset constants
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, $FF);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, $0F);
    MakeInstr(fn, 2, irXor, 2, 0, 1, 0);
    AssertEqual('irXor: 0xFF ^ 0x0F', $F0, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 1);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 8);
    MakeInstr(fn, 2, irShl, 2, 0, 1, 0);
    AssertEqual('irShl: 1 << 8', 256, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 1024);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 4);
    MakeInstr(fn, 2, irShr, 2, 0, 1, 0);
    AssertEqual('irShr: 1024 >> 4', 64, interp.ExecuteFunction(fn));
    
    // irNot: ~0 = -1
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 0);
    MakeInstr(fn, 1, irNot, 2, 0, 0, 0);
    MakeInstr(fn, 2, irFuncExit, 0, 0, 0, 0);
    fn.Instructions[2].Src1 := 2;
    SetLength(fn.Instructions, 3);
    AssertEqual('irNot: ~0', -1, interp.ExecuteFunction(fn));
    
    // irNor: ~(0 | 0) = -1
    SetLength(fn.Instructions, 4);
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 0);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 0);
    MakeInstr(fn, 2, irNor, 2, 0, 1, 0);
    fn.Instructions[3].Op := irFuncExit;
    fn.Instructions[3].Src1 := 2;
    AssertEqual('irNor: ~(0 | 0)', -1, interp.ExecuteFunction(fn));
  finally
    interp.Free;
  end;
end;

procedure TestComparisons;
var
  interp: TReferenceInterpreter;
  fn: TIRFunction;
begin
  WriteLn;
  WriteLn('=== Comparison Tests ===');
  
  interp := TReferenceInterpreter.Create;
  try
    SetLength(fn.Instructions, 4);
    fn.LocalCount := 0;
    fn.Instructions[3].Op := irFuncExit;
    fn.Instructions[3].Src1 := 2;
    
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 10);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 20);
    
    MakeInstr(fn, 2, irCmpEq, 2, 0, 1, 0);
    AssertEqual('irCmpEq: 10 == 20', 0, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 2, irCmpNeq, 2, 0, 1, 0);
    AssertEqual('irCmpNeq: 10 != 20', 1, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 2, irCmpLt, 2, 0, 1, 0);
    AssertEqual('irCmpLt: 10 < 20', 1, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 2, irCmpGt, 2, 0, 1, 0);
    AssertEqual('irCmpGt: 10 > 20', 0, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 10);
    MakeInstr(fn, 2, irCmpLe, 2, 0, 1, 0);
    AssertEqual('irCmpLe: 10 <= 10', 1, interp.ExecuteFunction(fn));
    
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 20);
    MakeInstr(fn, 2, irCmpGe, 2, 0, 1, 0);
    AssertEqual('irCmpGe: 10 >= 20', 0, interp.ExecuteFunction(fn));
  finally
    interp.Free;
  end;
end;

procedure TestMapSet;
var
  interp: TReferenceInterpreter;
  fn: TIRFunction;
begin
  WriteLn;
  WriteLn('=== Map/Set Tests ===');
  
  interp := TReferenceInterpreter.Create;
  try
    SetLength(fn.Instructions, 8);
    fn.LocalCount := 0;
    
    MakeInstr(fn, 0, irMapNew, 0, 0, 0, 0);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 1);
    MakeInstr(fn, 2, irConstInt, 2, 0, 0, 100);
    fn.Instructions[3].Op := irMapSet;
    fn.Instructions[3].Src1 := 0;
    fn.Instructions[3].Src2 := 1;
    fn.Instructions[3].Src3 := 2;
    fn.Instructions[4].Op := irMapGet;
    fn.Instructions[4].Src1 := 0;
    fn.Instructions[4].Src2 := 1;
    fn.Instructions[4].Dest := 3;
    fn.Instructions[5].Op := irMapLen;
    fn.Instructions[5].Src1 := 0;
    fn.Instructions[5].Dest := 4;
    fn.Instructions[6].Op := irMapContains;
    fn.Instructions[6].Src1 := 0;
    fn.Instructions[6].Src2 := 1;
    fn.Instructions[6].Dest := 5;
    fn.Instructions[7].Op := irFuncExit;
    fn.Instructions[7].Src1 := 3;
    
    AssertEqual('irMapGet: value=100', 100, interp.ExecuteFunction(fn));
    
    // Test set
    SetLength(fn.Instructions, 6);
    MakeInstr(fn, 0, irSetNew, 0, 0, 0, 0);
    MakeInstr(fn, 1, irConstInt, 1, 0, 0, 42);
    fn.Instructions[2].Op := irSetAdd;
    fn.Instructions[2].Src1 := 0;
    fn.Instructions[2].Src2 := 1;
    fn.Instructions[3].Op := irSetContains;
    fn.Instructions[3].Src1 := 0;
    fn.Instructions[3].Src2 := 1;
    fn.Instructions[3].Dest := 2;
    fn.Instructions[4].Op := irSetLen;
    fn.Instructions[4].Src1 := 0;
    fn.Instructions[4].Dest := 3;
    fn.Instructions[5].Op := irFuncExit;
    fn.Instructions[5].Src1 := 2;
    
    AssertEqual('irSetContains: 42 in set', 1, interp.ExecuteFunction(fn));
  finally
    interp.Free;
  end;
end;

procedure TestGlobals;
var
  interp: TReferenceInterpreter;
  fn: TIRFunction;
begin
  WriteLn;
  WriteLn('=== Global Variable Tests ===');
  
  interp := TReferenceInterpreter.Create;
  try
    SetLength(fn.Instructions, 4);
    fn.LocalCount := 0;
    fn.Instructions[3].Op := irFuncExit;
    fn.Instructions[3].Src1 := 2;
    
    MakeInstr(fn, 0, irConstInt, 0, 0, 0, 999);
    fn.Instructions[1].Op := irStoreGlobal;
    fn.Instructions[1].Dest := 5;
    fn.Instructions[1].Src1 := 0;
    fn.Instructions[2].Op := irLoadGlobal;
    fn.Instructions[2].Src1 := 5;
    fn.Instructions[2].Dest := 2;
    
    AssertEqual('irStoreGlobal/irLoadGlobal: 999', 999, interp.ExecuteFunction(fn));
  finally
    interp.Free;
  end;
end;

begin
  TotalTests := 0;
  PassedTests := 0;
  FailedTests := 0;

  WriteLn('========================================');
  WriteLn('Reference Interpreter - Verification Suite');
  WriteLn('DO-178C Section 1.2: Compiler Verification');
  WriteLn('========================================');

  TestArithmetic;
  TestBitOps;
  TestComparisons;
  TestMapSet;
  TestGlobals;

  WriteLn;
  WriteLn('========================================');
  WriteLn('Reference Interpreter Results');
  WriteLn('========================================');
  WriteLn('Total:  ', TotalTests);
  WriteLn('Passed: ', PassedTests);
  WriteLn('Failed: ', FailedTests);
  WriteLn;

  if FailedTests > 0 then
  begin
    WriteLn('REFERENCE INTERPRETER: FAILED');
    Halt(1);
  end
  else
  begin
    WriteLn('REFERENCE INTERPRETER: PASSED');
    Halt(0);
  end;
end.
