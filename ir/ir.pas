{$mode objfpc}{$H+}
unit ir;

interface

uses
  SysUtils, Classes, ast, backend_types; // für TAurumType und TEnergyLevel

type
  TIRCallMode = (
    cmInternal,   // Call to function defined in current module
    cmImported,   // Call to function imported from another unit
    cmExternal    // Call to external library (libc, etc.)
  );

  TIROpKind = (
    irInvalid,
    irConstInt,
    irConstStr,
    irConstFloat,  // new: float constant
    irAdd, irSub, irMul, irDiv, irMod, irNeg,
    // float arithmetic
    irFAdd, irFSub, irFMul, irFDiv, irFNeg,
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe,
    // float comparisons
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe,
     irNot, irAnd, irOr, irNor, irXor,
     irBitAnd, irBitOr, irBitXor, irBitNot,
     irShl, irShr,
     irLoadLocal, irStoreLocal, irLoadLocalAddr,
     irLoadStructAddr,  // load base address of struct local (needs StructSize for correct calculation)
     // global variable operations
     irLoadGlobal,      // load global: Dest = globals[ImmStr]
     irStoreGlobal,     // store global: globals[ImmStr] = Src1
     irLoadGlobalAddr,  // load address of global: Dest = &globals[ImmStr]
    // width/sign helpers
    irSExt,    // sign-extend Src1 to ImmInt bits -> Dest
    irZExt,    // zero-extend Src1 to ImmInt bits -> Dest
    irTrunc,   // truncate Src1 to ImmInt bits -> Dest
     // float conversion
     irFToI,    // float to int conversion
     irIToF,    // int to float conversion
     // type casting
     irCast,    // type cast: Dest = cast(Src1, CastFromType, CastToType)
     irCallBuiltin, irCall, irCallStruct, irVarCall,
    irJmp, irBrTrue, irBrFalse,
    irLabel,
    irReturn,
    irReturnStruct,  // return struct by value (uses StructSize for ABI decision)
     // array operations
      irStackAlloc,  // allocate space on stack for array
      irStoreElem,   // store element at array[index] (static index in ImmInt)
      irLoadElem,    // load element from array[index] (dynamic index in Src2)
      irStoreElemDyn,// store element at array[index] (dynamic index, uses 3 sources)
      // dynamic array operations (fat-pointer: 3 slots = ptr, len, cap)
      irDynArrayPush,  // push element: Src1 = base local (ptr slot), Src2 = value temp
      irDynArrayPop,   // pop element:  Src1 = base local (ptr slot), Dest = popped value
      irDynArrayLen,   // get length:   Src1 = base local (ptr slot), Dest = length
      irDynArrayFree,  // free array:   Src1 = base local (ptr slot)
     // struct field operations (stack-based, negative offsets)
     irLoadField,   // load field: Dest = *(Src1 - ImmInt)
    irStoreField,   // store field: *(Src1 - ImmInt) = Src2
     // heap object field operations (positive offsets from pointer)
     irLoadFieldHeap,  // load field from heap: Dest = *(Src1 + ImmInt)
     irStoreFieldHeap, // store field to heap: *(Src1 + ImmInt) = Src2
    // heap memory management
    irAlloc,          // heap allocate: Dest = alloc(ImmInt bytes) -> pointer
    irFree,           // heap free: free(Src1 pointer)
    // memory pool operations
    irPoolAlloc,      // pool allocate: Dest = pool_alloc(ImmInt bytes) -> pointer from pool
    irPoolFree,       // pool free all: free entire pool (Src1 = pool base pointer)
    // exception handler ops
    irPushHandler,  // push handler frame: Src1 = handler_addr, LabelName = catch_label
    irPopHandler,   // pop handler frame: Src1 = handler_addr
    irLoadHandlerExn, // load exception value from handler into Dest: Src1=handler_addr
    irThrow,        // perform throw: Src1 = exception temp
    // panic / abort
    irPanic,
    // SIMD operations (ParallelArray)
    irSIMDAdd, irSIMDSub, irSIMDMul, irSIMDDiv,
    irSIMDAnd, irSIMDOr, irSIMDXor, irSIMDNeg,
    irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe,
    irSIMDLoadElem, irSIMDStoreElem,
    // Map/Set operations (v0.5.0)
    irMapNew,       // create new map: Dest = map_new(ImmInt=initial_capacity)
    irMapGet,       // get value: Dest = map_get(Src1=map, Src2=key) - panics if not found
    irMapSet,       // set/update: map_set(Src1=map, Src2=key, Src3=value)
    irMapContains,  // check key: Dest = map_contains(Src1=map, Src2=key) -> bool
    irMapRemove,    // remove key: map_remove(Src1=map, Src2=key)
    irMapLen,       // get size: Dest = map_len(Src1=map)
    irMapFree,      // free map: map_free(Src1=map)
    irSetNew,       // create new set: Dest = set_new(ImmInt=initial_capacity)
    irSetAdd,       // add element: set_add(Src1=set, Src2=value)
    irSetContains,  // check element: Dest = set_contains(Src1=set, Src2=value) -> bool
    irSetRemove,    // remove element: set_remove(Src1=set, Src2=value)
    irSetLen,       // get size: Dest = set_len(Src1=set)
    irSetFree       // free set: set_free(Src1=set)
   );

  TIRInstr = record
    Op: TIROpKind;
    Dest: Integer; // destination temp / local index
    Src1: Integer;
    Src2: Integer;
    Src3: Integer; // for 3-operand instructions like irStoreElemDyn
    ImmInt: Int64; // usage depends on Op: e.g., const int or width bits for ext/trunc
    ImmFloat: Double; // for irConstFloat - stores actual float value
    ImmStr: string;
    LabelName: string;
    // Energy-Tracking: geschätzter Energieverbrauch dieser Instruktion
    EnergyCostHint: UInt64;
    // Cast-specific fields
    CastFromType: TAurumType;  // source type for cast operations
    CastToType: TAurumType;    // target type for cast operations
    // Call-specific fields
    CallMode: TIRCallMode;   // mode for irCall/irVarCall
    ArgTemps: array of Integer; // argument temp indices for calls (replaces CSV in LabelName)
    // Struct return fields (for irReturnStruct)
    StructSize: Integer;   // size of struct in bytes (determines ABI: RAX, RAX+RDX, or hidden ptr)
    StructAlign: Integer;  // alignment of struct
  end;

   TIRInstructionList = array of TIRInstr;

  TIRFunction = class
  public
    Name: string;
    Instructions: TIRInstructionList;
    LocalCount: Integer; // number of local slots
    ParamCount: Integer;
    EnergyLevel: TEnergyLevel; // Energy-Aware-Compiling level (0 = use global)
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure Emit(const instr: TIRInstr);
  end;

  TGlobalVar = record
    Name: string;
    InitValue: Int64;          // scalar init value
    HasInitValue: Boolean;
    IsArray: Boolean;         // true if this global is an array
    ArrayLen: Integer;        // number of elements if IsArray
    InitValues: array of Int64; // initial values for array (if any)
  end;
  TGlobalVarArray = array of TGlobalVar;

  TIRModule = class
  public
    Functions: array of TIRFunction;
    Strings: TStringList; // deduplicated strings
    GlobalVars: TGlobalVarArray; // global variables with init values
    constructor Create;
    destructor Destroy; override;
    function AddFunction(const name: string): TIRFunction;
    function FindFunction(const name: string): TIRFunction;
    function InternString(const s: string): Integer;
    function AddGlobalVar(const name: string; initVal: Int64; hasInit: Boolean): Integer;
    function AddGlobalArray(const name: string; const values: array of Int64): Integer;
  end;

{ Berechnet die geschätzten Energiekosten für einen IR-OpCode }
function GetIROpEnergyCost(op: TIROpKind): UInt64;
{ Setzt die Energiekosten-Hinweis für eine IR-Instruktion basierend auf ihrem OpCode }
procedure SetEnergyCostHint(var instr: TIRInstr);

implementation

{ TIRFunction }

constructor TIRFunction.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Instructions := nil;
  LocalCount := 0;
  ParamCount := 0;
  EnergyLevel := eelNone; // eelNone = use global level
end;

destructor TIRFunction.Destroy;
begin
  // Clear instruction list (no heap objects inside, but release array memory)
  Instructions := nil;
  inherited Destroy;
end;

procedure TIRFunction.Emit(const instr: TIRInstr);
begin
  SetLength(Instructions, Length(Instructions) + 1);
  Instructions[High(Instructions)] := instr;
end;

{ TIRModule }

constructor TIRModule.Create;
begin
  inherited Create;
  Functions := nil;
  Strings := TStringList.Create;
  Strings.Sorted := False;
  Strings.Duplicates := dupIgnore;
  GlobalVars := nil;
end;

destructor TIRModule.Destroy;
var
  i: Integer;
begin
  // free owned functions
  for i := 0 to High(Functions) do
    if Assigned(Functions[i]) then
      Functions[i].Free;
  SetLength(Functions, 0);
  Strings.Free;
  inherited Destroy;
end;

function TIRModule.AddFunction(const name: string): TIRFunction;
begin
  SetLength(Functions, Length(Functions) + 1);
  Functions[High(Functions)] := TIRFunction.Create(name);
  Result := Functions[High(Functions)];
end;

function TIRModule.FindFunction(const name: string): TIRFunction;
var
  i: Integer;
begin
  for i := 0 to High(Functions) do
    if Functions[i].Name = name then
      Exit(Functions[i]);
  Result := nil;
end;

function TIRModule.InternString(const s: string): Integer;
begin
  Result := Strings.IndexOf(s);
  if Result >= 0 then Exit;
  Strings.Add(s);
  Result := Strings.Count - 1;
end;

function TIRModule.AddGlobalVar(const name: string; initVal: Int64; hasInit: Boolean): Integer;
var
  i: Integer;
begin
  // Check if already exists
  for i := 0 to High(GlobalVars) do
    if GlobalVars[i].Name = name then
      Exit(i);
  // Add new scalar global
  Result := Length(GlobalVars);
  SetLength(GlobalVars, Result + 1);
  GlobalVars[Result].Name := name;
  GlobalVars[Result].InitValue := initVal;
  GlobalVars[Result].HasInitValue := hasInit;
  GlobalVars[Result].IsArray := False;
  GlobalVars[Result].ArrayLen := 0;
  SetLength(GlobalVars[Result].InitValues, 0);
end;

function TIRModule.AddGlobalArray(const name: string; const values: array of Int64): Integer;
var
  i: Integer;
begin
  // Check if already exists
  for i := 0 to High(GlobalVars) do
    if GlobalVars[i].Name = name then
      Exit(i);
  // Add new array global
  Result := Length(GlobalVars);
  SetLength(GlobalVars, Result + 1);
  GlobalVars[Result].Name := name;
  GlobalVars[Result].HasInitValue := True;
  GlobalVars[Result].IsArray := True;
  GlobalVars[Result].ArrayLen := Length(values);
  SetLength(GlobalVars[Result].InitValues, Length(values));
  for i := 0 to High(values) do
    GlobalVars[Result].InitValues[i] := values[i];
  // scalar InitValue unused
  GlobalVars[Result].InitValue := 0;
end;

{ Berechnet die geschätzten Energiekosten für einen IR-OpCode }
function GetIROpEnergyCost(op: TIROpKind): UInt64;
begin
  Result := 0;
  case op of
    // ALU-Operationen (niedrige Kosten)
    irAdd, irSub, irMul, irDiv, irMod, irNeg, irNot,
    irAnd, irOr, irNor, irXor,
    irCmpEq, irCmpNeq, irCmpLt, irCmpLe, irCmpGt, irCmpGe,
    irSExt, irZExt, irTrunc:
      Result := 1;
    // FPU-Operationen (mittlere Kosten)
    irFAdd, irFSub, irFMul, irFDiv, irFNeg,
    irFCmpEq, irFCmpNeq, irFCmpLt, irFCmpLe, irFCmpGt, irFCmpGe,
    irFToI, irIToF:
      Result := 3;
    // Speicher-Operationen (hohe Kosten)
    irLoadLocal, irStoreLocal, irLoadLocalAddr,
    irLoadGlobal, irStoreGlobal, irLoadGlobalAddr,
    irLoadStructAddr, irStackAlloc,
    irStoreElem, irLoadElem, irStoreElemDyn,
    irLoadField, irStoreField, irLoadFieldHeap, irStoreFieldHeap,
    irAlloc, irFree,
    irDynArrayPush, irDynArrayPop, irDynArrayLen, irDynArrayFree:
      Result := 100;
    // Branch-Operationen (mittlere Kosten)
    irJmp, irBrTrue, irBrFalse, irCall, irCallStruct,
    irReturn, irReturnStruct, irVarCall:
      Result := 50;
    // Builtin-Calls (können Syscalls sein)
    irCallBuiltin:
      Result := 10; // Wird zur Laufzeit genauer aufgelöst
    // Konstanten (sehr niedrige Kosten)
    irConstInt, irConstStr, irConstFloat:
      Result := 0;
    // Andere
    irLabel:
      Result := 0;
    irCast:
      Result := 1;
    irPanic:
      Result := 5000;
    // SIMD operations (mittlere bis hohe Kosten - vectorized ops)
    irSIMDAdd, irSIMDSub, irSIMDMul, irSIMDDiv,
    irSIMDAnd, irSIMDOr, irSIMDXor, irSIMDNeg,
    irSIMDCmpEq, irSIMDCmpNe, irSIMDCmpLt, irSIMDCmpLe, irSIMDCmpGt, irSIMDCmpGe,
    irSIMDLoadElem, irSIMDStoreElem:
      Result := 2;
    // Map/Set operations (hohe Kosten - Heap + Hash-Berechnung)
    irMapNew, irSetNew:
      Result := 500;  // Allokation
    irMapGet, irMapSet, irMapContains, irMapRemove,
    irSetAdd, irSetContains, irSetRemove:
      Result := 150;  // Hash-Lookup + evtl. Resize
    irMapLen, irSetLen:
      Result := 5;    // Einfaches Feld-Zugriff
    irMapFree, irSetFree:
      Result := 200;  // Deallokation
    else
      Result := 1;
  end;
end;

{ Setzt die Energiekosten-Hinweis für eine IR-Instruktion basierend auf ihrem OpCode }
procedure SetEnergyCostHint(var instr: TIRInstr);
begin
  instr.EnergyCostHint := GetIROpEnergyCost(instr.Op);
end;

{ Initialize a TIRInstr with safe default values }
procedure InitInstr(out instr: TIRInstr);
begin
  instr.Op := irInvalid;
  instr.Dest := -1;
  instr.Src1 := -1;
  instr.Src2 := -1;
  instr.Src3 := -1;
  instr.ImmInt := 0;
  instr.ImmFloat := 0.0;
  instr.ImmStr := '';
  instr.LabelName := '';
  instr.EnergyCostHint := 0;
  instr.CastFromType := atVoid;
  instr.CastToType := atVoid;
  instr.CallMode := cmInternal;
  SetLength(instr.ArgTemps, 0);
  instr.StructSize := 0;
  instr.StructAlign := 0;
end;

function EmptyInstr: TIRInstr;
begin
  InitInstr(Result);
end;

end.
