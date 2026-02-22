{$mode objfpc}{$H+}
unit ir;

interface

uses
  SysUtils, Classes, ast; // für TAurumType

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
     irLoadLocal, irStoreLocal, irLoadLocalAddr,
     irLoadStructAddr,  // load base address of struct local (needs StructSize for correct calculation)
     // global variable operations
     irLoadGlobal,   // load global: Dest = globals[ImmStr]
     irStoreGlobal,  // store global: globals[ImmStr] = Src1
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
     // struct field operations (stack-based, negative offsets)
     irLoadField,   // load field: Dest = *(Src1 - ImmInt)
    irStoreField,   // store field: *(Src1 - ImmInt) = Src2
     // heap object field operations (positive offsets from pointer)
     irLoadFieldHeap,  // load field from heap: Dest = *(Src1 + ImmInt)
     irStoreFieldHeap, // store field to heap: *(Src1 + ImmInt) = Src2
    // heap memory management
    irAlloc,          // heap allocate: Dest = alloc(ImmInt bytes) -> pointer
    irFree,           // heap free: free(Src1 pointer)
    // exception handler ops
    irPushHandler,  // push handler frame: Src1 = handler_addr, LabelName = catch_label
    irPopHandler,   // pop handler frame: Src1 = handler_addr
    irLoadHandlerExn, // load exception value from handler into Dest: Src1=handler_addr
    irThrow         // perform throw: Src1 = exception temp
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
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure Emit(const instr: TIRInstr);
  end;

  TGlobalVar = record
    Name: string;
    InitValue: Int64;
    HasInitValue: Boolean;
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
  end;

implementation

{ TIRFunction }

constructor TIRFunction.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Instructions := nil;
  LocalCount := 0;
  ParamCount := 0;
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
  // Add new
  Result := Length(GlobalVars);
  SetLength(GlobalVars, Result + 1);
  GlobalVars[Result].Name := name;
  GlobalVars[Result].InitValue := initVal;
  GlobalVars[Result].HasInitValue := hasInit;
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
