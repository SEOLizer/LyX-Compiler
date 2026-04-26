{$mode objfpc}{$H+}
unit ir;

interface

uses
  SysUtils, Classes, ast, backend_types; // für TAurumType und TEnergyLevel

type
  TIRCallMode = (
    cmInternal,   // Call to function defined in current module
    cmImported,   // Call to function imported from another unit
    cmExternal,   // Call to external library (libc, etc.)
    cmStaticLink  // Call to nested function (needs parent RBP as hidden param)
  );

  TIROpKind = (
    irInvalid,
    irConstInt,
    irConstStr,
    irConstFloat,  // new: float constant
    irAdd, irSub, irMul, irDiv, irMod, irNeg,
    // float arithmetic
    irFAdd, irFSub, irFMul, irFDiv, irFNeg, irFSqrt,
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
     irFuncExit,
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
    // closure support
     irLoadCaptured,   // load captured var from parent frame: Dest = *(Src1 + ImmInt)
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
    // Runtime assertions (DO-178C for Level A)
    irAssertBounds,    // bounds check: assert(Src1 >= 0 && Src1 < ImmInt) - panics if fail
    irAssertNotNull,   // null check: assert(Src1 != 0) - panics if null
    irAssertNotZero,  // zero check: assert(Src1 != 0) - panics if zero
    irAssertTrue,    // boolean check: assert(Src1 != 0) - panics if false
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
    irSetFree,      // free set: set_free(Src1=set)
    // Type checking (is/as operators)
    irIsType,       // type check: Dest = is_type(Src1=object, ImmStr=targetClassName) -> bool
    // Integrity verification (aerospace-todo P0 #45)
    irVerifyIntegrity, // verify code integrity: Dest = verify_integrity() -> bool
    // In-Situ Data Visualizer (Debugging 2.0)
    irInspect       // debug inspect: Src1=value, ImmStr=varname, ImmInt=format, InspectType=type
   );

  TIRInstr = record
    Op: TIROpKind;
    // Core operands
    Dest: Integer; // destination temp / local index
    Src1: Integer;
    Src2: Integer;
    Src3: Integer; // for 3-operand instructions like irStoreElemDyn
    ImmInt: Int64; // usage depends on Op: e.g., const int or width bits for ext/trunc
    ImmFloat: Double; // for irConstFloat
    ImmStr: string;
    LabelName: string;
    // Provenance (debug/listing only — lightweight: line + file)
    SourceASTID:  Integer; // AST node ID this instruction came from
    SourceASTKind: Integer; // AST node kind (from TAstNodeKind)
    SourceLine: Integer;   // source line number
    SourceFile: string;    // source file name
    // Cast-specific (irCast only)
    CastFromType: TAurumType;
    CastToType: TAurumType;
    // Call-specific (irCall / irVarCall / irCallStruct)
    CallMode: TIRCallMode;
    ArgTemps: array of Integer; // argument temp indices
    VMTIndex: Integer;          // VMT slot for virtual calls
    IsVirtualCall: Boolean;
    SelfSlot: Integer;          // self pointer slot for virtual calls
    // Struct return (irReturnStruct)
    StructSize: Integer;
    StructAlign: Integer;
    // Field access (irLoadField / irStoreField / irLoadFieldHeap / irStoreFieldHeap)
    FieldSize: Integer; // 1, 2, 4, or 8 bytes
  end;

   TIRInstructionList = array of TIRInstr;

  TBasicBlock = record
    StartIdx: Integer;             // first instruction index (inclusive)
    EndIdx: Integer;               // last instruction index (inclusive)
    Successors: array of Integer;  // block indices that follow this block
    Predecessors: array of Integer;// block indices that precede this block
  end;
  TBasicBlockList = array of TBasicBlock;

  TIRFunction = class
  public
    Name: string;
    Instructions: TIRInstructionList;
    BasicBlocks: TBasicBlockList;  // CFG metadata; rebuilt by BuildCFG
    LocalCount: Integer; // number of local slots
    ParamCount: Integer;
    EnergyLevel: TEnergyLevel; // Energy-Aware-Compiling level (0 = use global)
    SafetyPragmas: TSafetyPragmas; // Safety pragmas: @dal, @critical, @wcet, @stack_limit
    ReturnStructSize: Integer; // size in bytes if function returns struct, 0 otherwise
    // Closure support
    ParentFuncName: string; // enclosing function name (if nested)
    NeedsStaticLink: Boolean; // true if captures variables from outer scope
    CapturedVars: array of record
      Name: string;
      OuterSlot: Integer; // slot in parent function
      InnerSlot: Integer; // slot in this function
    end;
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure Emit(const instr: TIRInstr);
    procedure BuildCFG; // splits Instructions into BasicBlocks with successor/predecessor links
    function GetProvenanceInfo(irIdx: Integer): string; // returns formatted provenance for IR#irIdx
  end;

  TGlobalVar = record
    Name: string;
    InitValue: Int64;          // scalar init value
    HasInitValue: Boolean;
    IsArray: Boolean;         // true if this global is an array
    ArrayLen: Integer;        // number of elements if IsArray
    InitValues: array of Int64; // initial values for array (if any)
    IsStringPtr: Boolean;     // true if this is a pchar initialized with a string literal
    StringIdx: Integer;       // index into Strings list if IsStringPtr is true
  end;
  TGlobalVarArray = array of TGlobalVar;

  TIRModule = class
  public
    Functions: array of TIRFunction;
    FuncIndex: TStringList; // sorted name→TIRFunction for O(log n) FindFunction
    Strings: TStringList; // deduplicated strings
    GlobalVars: TGlobalVarArray; // global variables with init values
    // VMT: class declarations for VMT table emission
    ClassDecls: array of TAstClassDecl; // stored class declarations
    // C FFI: maps extern function name → library name (e.g. 'sqlite3' → 'libsqlite3.so')
    ExternLibraries: TStringList; // Name=library pairs
    // AST: Reference to program node for static analysis
    ProgramNode: TAstProgram;
    // Integrity management: from @integrity before unit declaration (aerospace-todo P0 #43)
    UnitIntegrity: TIntegrityAttr;
    constructor Create;
    destructor Destroy; override;
    function AddFunction(const name: string): TIRFunction;
    function FindFunction(const name: string): TIRFunction;
    procedure RemoveFunction(const name: string);
    function InternString(const s: string): Integer;
    function AddGlobalVar(const name: string; initVal: Int64; hasInit: Boolean): Integer;
    function AddGlobalStringPtr(const name: string; strIdx: Integer): Integer;
    function AddGlobalArray(const name: string; const values: array of Int64): Integer;
    procedure AddClassDecl(cd: TAstClassDecl);
    procedure RegisterExternLibrary(const funcName, libName: string);
    function GetExternLibrary(const funcName: string): string;
  end;

{ Berechnet die geschätzten Energiekosten für einen IR-OpCode }
function GetIROpEnergyCost(op: TIROpKind): UInt64;

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
  SafetyPragmas.DALLevel          := dalNone;
  SafetyPragmas.IsCritical        := False;
  SafetyPragmas.WCETBudget        := 0;
  SafetyPragmas.StackLimit        := 0;
  SafetyPragmas.Integrity.Mode     := imNone;
  SafetyPragmas.Integrity.Interval := 0;
  SafetyPragmas.FPDeterministic    := False;  // FIX: initialize to avoid uninitialized garbage
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

function TIRFunction.GetProvenanceInfo(irIdx: Integer): string;
begin
  Result := '';
  if (irIdx < 0) or (irIdx >= Length(Instructions)) then Exit;
  Result := Format('IR#%d', [irIdx]);
  if Instructions[irIdx].SourceFile <> '' then
    Result := Result + Format(' at %s:%d',
      [Instructions[irIdx].SourceFile, Instructions[irIdx].SourceLine]);
  if Instructions[irIdx].SourceASTID > 0 then
    Result := Result + Format(' from AST#%d', [Instructions[irIdx].SourceASTID]);
end;

procedure TIRFunction.BuildCFG;
var
  n, i, j, bb, bbCount, targetBB, idx: Integer;
  isLeader: array of Boolean;
  instrBlock: array of Integer;
  labelNames: TStringList;
  instr: TIRInstr;

  procedure AddPred(block, pred: Integer);
  var
    k: Integer;
  begin
    for k := 0 to High(BasicBlocks[block].Predecessors) do
      if BasicBlocks[block].Predecessors[k] = pred then Exit;
    SetLength(BasicBlocks[block].Predecessors, Length(BasicBlocks[block].Predecessors) + 1);
    BasicBlocks[block].Predecessors[High(BasicBlocks[block].Predecessors)] := pred;
  end;

  procedure AddSucc(block, succ: Integer);
  var
    k: Integer;
  begin
    for k := 0 to High(BasicBlocks[block].Successors) do
      if BasicBlocks[block].Successors[k] = succ then Exit;
    SetLength(BasicBlocks[block].Successors, Length(BasicBlocks[block].Successors) + 1);
    BasicBlocks[block].Successors[High(BasicBlocks[block].Successors)] := succ;
  end;

  function LabelToBlock(const lbl: string): Integer;
  var
    k: Integer;
  begin
    k := labelNames.IndexOf(lbl);
    if k >= 0 then
      Result := PtrInt(labelNames.Objects[k])
    else
      Result := -1;
  end;

begin
  BasicBlocks := nil;
  n := Length(Instructions);
  if n = 0 then Exit;

  // Step 1: identify leaders — first instructions of every basic block
  SetLength(isLeader, n);
  for i := 0 to n-1 do isLeader[i] := False;
  isLeader[0] := True;

  for i := 0 to n-1 do
  begin
    case Instructions[i].Op of
      irJmp, irBrTrue, irBrFalse, irFuncExit:
        if i+1 < n then isLeader[i+1] := True;
    end;
    if Instructions[i].Op = irLabel then
      isLeader[i] := True;
  end;

  // Step 2: create basic blocks and map each instruction to its block
  bbCount := 0;
  for i := 0 to n-1 do
    if isLeader[i] then Inc(bbCount);

  SetLength(BasicBlocks, bbCount);
  SetLength(instrBlock, n);

  bb := -1;
  for i := 0 to n-1 do
  begin
    if isLeader[i] then
    begin
      Inc(bb);
      BasicBlocks[bb].StartIdx := i;
      BasicBlocks[bb].EndIdx   := i;
      BasicBlocks[bb].Successors   := nil;
      BasicBlocks[bb].Predecessors := nil;
    end;
    instrBlock[i] := bb;
    BasicBlocks[bb].EndIdx := i;
  end;

  // Step 3: map label names to block indices
  labelNames := TStringList.Create;
  labelNames.Sorted := False;
  try
    for i := 0 to bbCount-1 do
    begin
      j := BasicBlocks[i].StartIdx;
      if Instructions[j].Op = irLabel then
        labelNames.AddObject(Instructions[j].LabelName, TObject(PtrInt(i)));
    end;

    // Step 4: wire up successors and predecessors from block terminators
    for i := 0 to bbCount-1 do
    begin
      j := BasicBlocks[i].EndIdx;
      instr := Instructions[j];
      case instr.Op of
        irJmp:
        begin
          targetBB := LabelToBlock(instr.LabelName);
          if targetBB >= 0 then
          begin
            AddSucc(i, targetBB);
            AddPred(targetBB, i);
          end;
        end;
        irBrTrue, irBrFalse:
        begin
          // branch target
          targetBB := LabelToBlock(instr.LabelName);
          if targetBB >= 0 then
          begin
            AddSucc(i, targetBB);
            AddPred(targetBB, i);
          end;
          // fall-through to next block
          if i+1 < bbCount then
          begin
            AddSucc(i, i+1);
            AddPred(i+1, i);
          end;
        end;
        irFuncExit:
          ; // no successors — function exit
      else
        // non-terminator: falls through to next block
        if i+1 < bbCount then
        begin
          AddSucc(i, i+1);
          AddPred(i+1, i);
        end;
      end;
    end;
  finally
    labelNames.Free;
  end;
end;

{ TIRModule }

constructor TIRModule.Create;
begin
  inherited Create;
  Functions := nil;
  FuncIndex := TStringList.Create;
  FuncIndex.Sorted := True;
  FuncIndex.CaseSensitive := True;
  FuncIndex.Duplicates := dupIgnore; // AddFunction updates Objects on collision
  Strings := TStringList.Create;
  Strings.Sorted := False;
  Strings.CaseSensitive := True;
  Strings.Duplicates := dupIgnore;
  GlobalVars := nil;
  ExternLibraries := TStringList.Create;
  ExternLibraries.Sorted := False;
  UnitIntegrity.Mode     := imNone;
  UnitIntegrity.Interval := 0;
end;

destructor TIRModule.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Functions) do
    if Assigned(Functions[i]) then
      Functions[i].Free;
  SetLength(Functions, 0);
  FuncIndex.Free; // does NOT own TIRFunction objects — Functions[] does
  Strings.Free;
  ExternLibraries.Free;
  SetLength(ClassDecls, 0);
  inherited Destroy;
end;

function TIRModule.AddFunction(const name: string): TIRFunction;
var
  newFunc: TIRFunction;
  idx: Integer;
begin
  newFunc := TIRFunction.Create(name);
  SetLength(Functions, Length(Functions) + 1);
  Functions[High(Functions)] := newFunc;
  // Keep index in sync; if name was already present (stale from a prior
  // RemoveFunction that missed the index), update the pointer in place.
  idx := FuncIndex.IndexOf(name);
  if idx >= 0 then
    FuncIndex.Objects[idx] := TObject(newFunc)
  else
    FuncIndex.AddObject(name, TObject(newFunc));
  Result := newFunc;
end;

procedure TIRModule.RemoveFunction(const name: string);
var
  i, j, idx: Integer;
begin
  for i := 0 to High(Functions) do
    if Functions[i].Name = name then
    begin
      Functions[i].Free;
      for j := i to High(Functions) - 1 do
        Functions[j] := Functions[j+1];
      SetLength(Functions, Length(Functions) - 1);
      idx := FuncIndex.IndexOf(name);
      if idx >= 0 then FuncIndex.Delete(idx);
      Exit;
    end;
end;

{ O(log n) lookup via sorted FuncIndex. }
function TIRModule.FindFunction(const name: string): TIRFunction;
var
  idx: Integer;
begin
  idx := FuncIndex.IndexOf(name);
  if idx >= 0 then
    Result := TIRFunction(FuncIndex.Objects[idx])
  else
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
  GlobalVars[Result].IsStringPtr := False;
  GlobalVars[Result].StringIdx := -1;
  SetLength(GlobalVars[Result].InitValues, 0);
end;

function TIRModule.AddGlobalStringPtr(const name: string; strIdx: Integer): Integer;
var
  i: Integer;
begin
  // Check if already exists
  for i := 0 to High(GlobalVars) do
    if GlobalVars[i].Name = name then
      Exit(i);
  // Add new string pointer global
  Result := Length(GlobalVars);
  SetLength(GlobalVars, Result + 1);
  GlobalVars[Result].Name := name;
  GlobalVars[Result].InitValue := 0;  // Will be patched by backend
  GlobalVars[Result].HasInitValue := True;
  GlobalVars[Result].IsArray := False;
  GlobalVars[Result].ArrayLen := 0;
  GlobalVars[Result].IsStringPtr := True;
  GlobalVars[Result].StringIdx := strIdx;
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

procedure TIRModule.AddClassDecl(cd: TAstClassDecl);
begin
  SetLength(ClassDecls, Length(ClassDecls) + 1);
  ClassDecls[High(ClassDecls)] := cd;
end;

procedure TIRModule.RegisterExternLibrary(const funcName, libName: string);
begin
  ExternLibraries.Values[funcName] := libName;
end;

function TIRModule.GetExternLibrary(const funcName: string): string;
begin
  Result := ExternLibraries.Values[funcName];
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
    irFuncExit, irReturnStruct, irVarCall:
      Result := 50; // Direkte und indirekte Aufrufe

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
    // Runtime assertions (geringe Kosten - compare + je nach Ausführung)
    irAssertBounds, irAssertNotNull, irAssertNotZero, irAssertTrue:
      Result := 2;
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
