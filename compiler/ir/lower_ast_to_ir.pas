{$mode objfpc}{$H+}
unit lower_ast_to_ir;

interface

uses
  SysUtils, Classes,
  ast, ir, diag, lexer, unit_manager, tobject, backend_types;

type
  TConstValue = class
  public
    IsStr: Boolean;
    IntVal: Int64;
    StrVal: string;
  end;

  TIRLowering = class
  private
    FModule: TIRModule;
    FCurrentFunc: TIRFunction;
    FCurrentFuncDecl: TAstFuncDecl;  // current AST function being lowered (for return type info)
    FCurrentClassDecl: TAstClassDecl; // current class being lowered (for super calls)
    FDiag: TDiagnostics;
    FTempCounter: Integer;
    FLabelCounter: Integer;
    FLocalMap: TStringList; // name -> local index (as object integer)
    FLocalTypes: array of TAurumType; // index -> declared local type
    FLocalElemSize: array of Integer; // index -> element size in bytes for dynamic array locals (0 if not array)
    FLocalIsStruct: array of Boolean; // index -> true if this local is a struct (need address, not value)
    FLocalSlotCount: array of Integer; // index -> number of slots this variable occupies (for structs)
    FLocalArrayLen: array of Integer; // index -> array length (0 if not a static array)
    FLocalIsDynArray: array of Boolean; // index -> true if this local is a dynamic array (fat-pointer)
    FLocalTypeNames: array of string; // index -> type name for classes (for destructor lookup)
    FConstMap: TStringList; // name -> TConstValue (compile-time constants)
    FLocalConst: array of TConstValue; // per-function local constant values (or nil)
    FBreakStack: TStringList; // stack of break labels
    FContinueStack: TStringList; // stack of continue labels (loop start)
    FStructTypes: TStringList; // struct name -> TAstStructDecl (as object)
    FClassTypes: TStringList; // class name -> TAstClassDecl (as object)
    FRangeTypes: TStringList; // range type name -> TAstTypeDecl (aerospace-todo P1 #7)
    FGlobalVars: TStringList; // global variable name -> TAstVarDecl (as object)
    FExternFuncs: TStringList; // names of extern fn declarations
    FImportedFuncs: TStringList; // names of functions from imported units
    // Generics: monomorphization support
    FGenericFuncs: TStringList;          // name -> TAstFuncDecl
    FGenericSpecializations: TStringList; // mangled name -> already lowered
    FTypeSubstParams: TStringArray;      // type param names for current specialization
    FTypeSubstTypes: array of TAurumType; // concrete types for current specialization
    // Source location tracking for assembly listing (aerospace-todo 6.1)
    FCurrentSourceLine: Integer;
    FCurrentSourceFile: string;
    // Provenance Tracking (WP-F): current AST node being lowered
    FCurrentASTNode: TAstNode;  // current AST node for provenance

    function NewTemp: Integer;
    function IsGlobalVar(const name: string): Boolean;
    function GetGlobalVarDecl(const name: string): TAstVarDecl;
    function NewLabel(const prefix: string): string;
    function AllocLocal(const name: string; aType: TAurumType): Integer;
    function AllocLocalMany(const name: string; aType: TAurumType; count: Integer; isStruct: Boolean = False): Integer;
    function GetLocalType(idx: Integer): TAurumType;
    function GetLocalArrayLen(idx: Integer): Integer;
    function ResolveLocal(const name: string): Integer;
    procedure Emit(instr: TIRInstr);

    function SubstType(t: TAurumType; const n: string): TAurumType;
    procedure LowerGenericSpecialization(decl: TAstFuncDecl; const mangledName: string;
      const typeArgs: array of TAurumType);

    { Emits IR range-check for value in temp tVal against [rMin..rMax] (aerospace-todo P1 #7) }
    procedure EmitRangeCheck(tVal: Integer; rMin, rMax: Int64; const typeName: string; span: TSourceSpan);

    function LowerStmt(stmt: TAstStmt): Boolean;
    function LowerExpr(expr: TAstExpr): Integer; // returns temp index
    function LowerStructLit(sl: TAstStructLit): Integer; // returns temp with struct address
    function LowerArrayLit(al: TAstArrayLit): Integer; // returns temp with array base address
    procedure LowerNestedFunc(funcDecl: TAstFuncDecl); // lift nested function to top-level
    procedure LowerStructLitIntoLocal(sl: TAstStructLit; baseLoc: Integer; sd: TAstStructDecl);
    function GetReturnStructDecl: TAstStructDecl; // get struct decl for current func's return type
    procedure EnsureClassLayout(cd: TAstClassDecl); // compute field offsets if not yet done
  public
    constructor Create(modul: TIRModule; diag: TDiagnostics);
    destructor Destroy; override;

    function Lower(prog: TAstProgram): TIRModule;
    procedure LowerImportedUnits(um: TUnitManager);
  end;

implementation

{ Helpers }

function IntToObj(i: Integer): System.TObject;
begin
  Result := System.TObject(Pointer(i));
end;

function ObjToInt(o: System.TObject): Integer;
begin
  Result := Integer(Pointer(o));
end;

// Returns the size in bytes for a given type (for field access width)
function TypeSizeBytes(t: TAurumType): Integer;
begin
  case t of
    atInt8, atUInt8, atBool, atChar: Result := 1;
    atInt16, atUInt16: Result := 2;
    atInt32, atUInt32, atF32: Result := 4;
    atInt64, atUInt64, atISize, atUSize, atF64, atPChar, atPCharNullable,
    atDynArray, atArray, atMap, atSet, atParallelArray: Result := 8;
  else
    Result := 8; // Default to 8 bytes (full register width) - includes atUnresolved, atVoid
  end;
end;

{ TIRLowering }

constructor TIRLowering.Create(modul: TIRModule; diag: TDiagnostics);
  begin
    inherited Create;
    FModule := modul;
    FDiag := diag;
    FCurrentFuncDecl := nil;
    FCurrentClassDecl := nil;
    FTempCounter := 0;
    FLabelCounter := 0;
    FLocalMap := TStringList.Create;
    FLocalMap.Sorted := False;
    FLocalMap.CaseSensitive := True;
    FConstMap := TStringList.Create;
    FConstMap.Sorted := False;
    FBreakStack := TStringList.Create;
    FBreakStack.Sorted := False;
    FContinueStack := TStringList.Create;
    FContinueStack.Sorted := False;
    FStructTypes := TStringList.Create;
    FStructTypes.Sorted := False;
    FClassTypes := TStringList.Create;
    FClassTypes.Sorted := False;
    FRangeTypes := TStringList.Create;
    FRangeTypes.Sorted := False;
    FGlobalVars := TStringList.Create;
    FGlobalVars.Sorted := False;
    FExternFuncs := TStringList.Create;
    FExternFuncs.Sorted := True;
    FExternFuncs.Duplicates := dupIgnore;
    FImportedFuncs := TStringList.Create;
    FImportedFuncs.Sorted := True;
    FImportedFuncs.Duplicates := dupIgnore;
    FGenericFuncs := TStringList.Create;
    FGenericFuncs.Sorted := False;
    FGenericSpecializations := TStringList.Create;
    FGenericSpecializations.Sorted := True;
    FGenericSpecializations.Duplicates := dupIgnore;
    SetLength(FTypeSubstParams, 0);
    SetLength(FTypeSubstTypes, 0);
    SetLength(FLocalTypes, 0);
    SetLength(FLocalElemSize, 0);
    SetLength(FLocalIsStruct, 0);
    SetLength(FLocalSlotCount, 0);
    SetLength(FLocalConst, 0);
    SetLength(FLocalTypeNames, 0);
  end;


destructor TIRLowering.Destroy;
var
  i: Integer;
begin
  FLocalMap.Free;
  for i := 0 to FConstMap.Count - 1 do
    System.TObject(FConstMap.Objects[i]).Free;
  FConstMap.Free;
  for i := 0 to Length(FLocalConst)-1 do
    if Assigned(FLocalConst[i]) then FLocalConst[i].Free;
  SetLength(FLocalConst, 0);
  SetLength(FLocalIsStruct, 0);
  SetLength(FLocalTypeNames, 0);
  FBreakStack.Free;
  FContinueStack.Free;
  // Don't free objects in FStructTypes/FClassTypes/FGlobalVars - they belong to the AST
  FStructTypes.Free;
  FClassTypes.Free;
  // Don't free objects in FRangeTypes — they belong to the AST
  FRangeTypes.Free;
  FGlobalVars.Free;
  FExternFuncs.Free;
  FImportedFuncs.Free;
  // Don't free objects in FGenericFuncs — they belong to the AST
  FGenericFuncs.Free;
  FGenericSpecializations.Free;
  inherited Destroy;
end;

function TIRLowering.IsGlobalVar(const name: string): Boolean;
begin
  Result := FGlobalVars.IndexOf(name) >= 0;
end;

function TIRLowering.GetGlobalVarDecl(const name: string): TAstVarDecl;
var
  idx: Integer;
begin
  idx := FGlobalVars.IndexOf(name);
  if idx >= 0 then
    Result := TAstVarDecl(FGlobalVars.Objects[idx])
  else
    Result := nil;
end;


{ Emits runtime bounds-check IR: panics if tVal not in [rMin..rMax] (aerospace-todo P1 #7) }
procedure TIRLowering.EmitRangeCheck(tVal: Integer; rMin, rMax: Int64;
  const typeName: string; span: TSourceSpan);
var
  instr: TIRInstr;
  tMin, tMax, tGeMin, tLeMax, tOk, tMsg: Integer;
  failLbl, okLbl, msgStr: string;
begin
  instr := Default(TIRInstr);
  instr.SourceLine := span.Line;
  instr.SourceFile := span.FileName;

  // Load constants for min and max
  tMin := NewTemp;
  instr.Op := irConstInt; instr.Dest := tMin; instr.ImmInt := rMin; Emit(instr);
  tMax := NewTemp;
  instr.Op := irConstInt; instr.Dest := tMax; instr.ImmInt := rMax; Emit(instr);

  // tGeMin = tVal >= rMin
  tGeMin := NewTemp;
  instr.Op := irCmpGe; instr.Dest := tGeMin; instr.Src1 := tVal; instr.Src2 := tMin; Emit(instr);
  // tLeMax = tVal <= rMax  (implemented as rMax >= tVal)
  tLeMax := NewTemp;
  instr.Op := irCmpGe; instr.Dest := tLeMax; instr.Src1 := tMax; instr.Src2 := tVal; Emit(instr);
  // tOk = tGeMin && tLeMax
  tOk := NewTemp;
  instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGeMin; instr.Src2 := tLeMax; Emit(instr);

  // Branch to fail-label if not ok
  failLbl := NewLabel('Lrange_fail');
  okLbl   := NewLabel('Lrange_ok');
  instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := failLbl; Emit(instr);
  // skip to ok
  instr.Op := irJmp; instr.LabelName := okLbl; Emit(instr);

  // Fail block: panic message
  instr.Op := irLabel; instr.LabelName := failLbl; Emit(instr);
  msgStr := 'Range check failed: value out of [' +
            IntToStr(rMin) + '..' + IntToStr(rMax) + '] for type ' + typeName;
  tMsg := NewTemp;
  instr.Op := irConstStr; instr.Dest := tMsg;
  instr.ImmStr := IntToStr(FModule.InternString(msgStr));
  instr.ImmInt := Length(msgStr); Emit(instr);
  instr.Op := irPanic; instr.Src1 := tMsg; instr.ImmInt := Length(msgStr); Emit(instr);

  instr.Op := irLabel; instr.LabelName := okLbl; Emit(instr);
end;

function TIRLowering.NewTemp: Integer;
begin
  Result := FTempCounter;
  Inc(FTempCounter);
end;

function TIRLowering.NewLabel(const prefix: string): string;
begin
  Result := Format('%s_%d', [prefix, FLabelCounter]);
  Inc(FLabelCounter);
end;

function TIRLowering.AllocLocal(const name: string; aType: TAurumType): Integer;
var
  idx: Integer;
begin
  idx := FLocalMap.IndexOf(name);
  if idx >= 0 then
  begin
    Result := ObjToInt(FLocalMap.Objects[idx]);
    Exit;
  end;
  Result := FCurrentFunc.LocalCount;
  FCurrentFunc.LocalCount := FCurrentFunc.LocalCount + 1;
  FLocalMap.AddObject(name, IntToObj(Result));
  // ensure FLocalTypes has same length
  SetLength(FLocalTypes, FCurrentFunc.LocalCount);
  FLocalTypes[Result] := aType;
  // ensure FLocalElemSize has same length and initialize to 0
  SetLength(FLocalElemSize, FCurrentFunc.LocalCount);
  FLocalElemSize[Result] := 0;
  // ensure FLocalIsStruct has same length and initialize to false
  SetLength(FLocalIsStruct, FCurrentFunc.LocalCount);
  FLocalIsStruct[Result] := False;
  // ensure FLocalTypeNames has same length and initialize to empty
  SetLength(FLocalTypeNames, FCurrentFunc.LocalCount);
  FLocalTypeNames[Result] := '';
end;

function TIRLowering.AllocLocalMany(const name: string; aType: TAurumType; count: Integer; isStruct: Boolean = False): Integer;
var
  idx, i, base: Integer;
begin
  idx := FLocalMap.IndexOf(name);
  if idx >= 0 then
  begin
    Result := ObjToInt(FLocalMap.Objects[idx]);
    Exit;
  end;
  if count <= 0 then
    count := 1; // minimum 1 slot for empty/dynamic arrays
  base := FCurrentFunc.LocalCount;
  FCurrentFunc.LocalCount := FCurrentFunc.LocalCount + count;
  FLocalMap.AddObject(name, IntToObj(base));
  // ensure FLocalTypes has same length
  SetLength(FLocalTypes, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalTypes[base + i] := aType;
  // ensure FLocalElemSize has same length and initialize entries to 0
  SetLength(FLocalElemSize, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalElemSize[base + i] := 0;
  // ensure FLocalIsStruct has same length
  SetLength(FLocalIsStruct, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalIsStruct[base + i] := isStruct and (i = 0); // only mark first slot as struct
  // ensure FLocalSlotCount has same length
  SetLength(FLocalSlotCount, FCurrentFunc.LocalCount);
  FLocalSlotCount[base] := count; // store slot count on first slot
  for i := 1 to count - 1 do
    FLocalSlotCount[base + i] := 0; // other slots don't need count
  // ensure FLocalTypeNames has same length
  SetLength(FLocalTypeNames, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalTypeNames[base + i] := '';
  // ensure FLocalArrayLen has same length - store array length on first slot
  SetLength(FLocalArrayLen, FCurrentFunc.LocalCount);
  if (not isStruct) and (count > 1) then
    FLocalArrayLen[base] := count  // this is an array
  else
    FLocalArrayLen[base] := 0;     // not an array
  for i := 1 to count - 1 do
    FLocalArrayLen[base + i] := 0;
  // ensure FLocalIsDynArray has same length - initialize to false
  SetLength(FLocalIsDynArray, FCurrentFunc.LocalCount);
  for i := 0 to count - 1 do
    FLocalIsDynArray[base + i] := False;
  Result := base;
end;

function TIRLowering.GetLocalType(idx: Integer): TAurumType;
begin
  if (idx >= 0) and (idx < Length(FLocalTypes)) then
    Result := FLocalTypes[idx]
  else
    Result := atUnresolved;
end;

function TIRLowering.GetLocalArrayLen(idx: Integer): Integer;
begin
  if (idx >= 0) and (idx < Length(FLocalArrayLen)) then
    Result := FLocalArrayLen[idx]
  else
    Result := 0;
end;

procedure TIRLowering.Emit(instr: TIRInstr);
begin
  if not Assigned(FCurrentFunc) then
    Exit;
  // Attach source location to IR instruction (aerospace-todo 6.1)
  instr.SourceLine := FCurrentSourceLine;
  instr.SourceFile := FCurrentSourceFile;
  // Provenance Tracking (WP-F): attach AST node reference
  if Assigned(FCurrentASTNode) then
  begin
    instr.SourceASTID := FCurrentASTNode.ID;
    instr.SourceASTKind := Ord(FCurrentASTNode.Kind);
  end
  else
  begin
    instr.SourceASTID := -1;
    instr.SourceASTKind := -1;
  end;
  FCurrentFunc.Emit(instr);
end;

{ Lowering main entry }

function TIRLowering.Lower(prog: TAstProgram): TIRModule;
var
  i: Integer;
  fn: TIRFunction;
  node: TAstNode;
  j: Integer;
  k: Integer;
  m: TAstFuncDecl;
  mangled: string;
  cv: TConstValue;
  instr: TIRInstr;
  items: TAstExprList;
  vals: array of Int64;
  strIdx: Integer;
  structIdx: Integer;
  sd: TAstStructDecl;
begin
  instr := Default(TIRInstr);
  // First pass: collect all struct, class, and global variable declarations
  // Note: FStructTypes, FClassTypes, FGlobalVars are NOT cleared here
  // because LowerImportedUnits may have already populated them with imported symbols
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstUnitDecl then
    begin
      // Propagate @integrity attribute from unit declaration to IR module
      if TAstUnitDecl(node).IntegrityAttr.Mode <> imNone then
        FModule.UnitIntegrity := TAstUnitDecl(node).IntegrityAttr;
    end
    else if node is TAstStructDecl then
      FStructTypes.AddObject(TAstStructDecl(node).Name, System.TObject(node))
    else if node is TAstClassDecl then
    begin
      // Classes are stored in both maps - they have the same field layout logic
      FStructTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
      FClassTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
      // Also store in IR module for VMT emission
      FModule.AddClassDecl(TAstClassDecl(node));
    end
    else if node is TAstVarDecl then
    begin
      // Global variable declaration
      if TAstVarDecl(node).IsGlobal then
      begin
        FGlobalVars.AddObject(TAstVarDecl(node).Name, System.TObject(node));
        // Register in module with init value
        if TAstVarDecl(node).InitExpr is TAstIntLit then
        begin
          FModule.AddGlobalVar(TAstVarDecl(node).Name, TAstIntLit(TAstVarDecl(node).InitExpr).Value, True);
        end
        else if TAstVarDecl(node).InitExpr is TAstStrLit then
        begin
          // String literal initializer: use special function to mark as string pointer
          strIdx := FModule.InternString(TAstStrLit(TAstVarDecl(node).InitExpr).Value);
          FModule.AddGlobalStringPtr(TAstVarDecl(node).Name, strIdx);
        end
        else if TAstVarDecl(node).InitExpr is TAstArrayLit then
        begin
          // collect integer items if possible
          items := TAstArrayLit(TAstVarDecl(node).InitExpr).Items;
          SetLength(vals, 0);
          for k := 0 to High(items) do
          begin
            if items[k] is TAstIntLit then
            begin
              SetLength(vals, Length(vals) + 1);
              vals[High(vals)] := TAstIntLit(items[k]).Value;
            end
            else
            begin
              // non-integer array initializers not supported for global arrays yet
              SetLength(vals, 0);
              Break;
            end;
          end;
          if (Length(vals) > 0) then
            FModule.AddGlobalArray(TAstVarDecl(node).Name, vals)
          else
            FModule.AddGlobalVar(TAstVarDecl(node).Name, 0, False);
        end
        else
          FModule.AddGlobalVar(TAstVarDecl(node).Name, 0, False);
      end;
    end;
  end;
  
  // Add TObject to class types if not already present
  // TObject is the implicit base class for all classes without explicit base
  if FClassTypes.IndexOf(TOBJECT_CLASSNAME) < 0 then
  begin
    // Create TObject class declaration and add to module
    node := CreateTObjectClassDecl;
    FStructTypes.AddObject(TOBJECT_CLASSNAME, System.TObject(node));
    FClassTypes.AddObject(TOBJECT_CLASSNAME, System.TObject(node));
    FModule.AddClassDecl(TAstClassDecl(node));
  end;
  
  // iterate top-level decls, create functions
  for i := 0 to High(prog.Decls) do
  begin
    node := prog.Decls[i];
    if node is TAstFuncDecl then
    begin
       // Skip extern function declarations (no body to lower)
        if TAstFuncDecl(node).IsExtern then
        begin
          FExternFuncs.Add(TAstFuncDecl(node).Name);
          // Register library name if provided via link "..."
          if TAstFuncDecl(node).LibraryName <> '' then
            FModule.RegisterExternLibrary(TAstFuncDecl(node).Name,
              TAstFuncDecl(node).LibraryName);
          Continue;
        end;
       // Skip abstract methods (no body to lower)
       if TAstFuncDecl(node).IsAbstract then
       begin
         Continue;
       end;
       // Store generic functions for monomorphization; skip normal lowering
       if Length(TAstFuncDecl(node).TypeParams) > 0 then
       begin
         FGenericFuncs.AddObject(TAstFuncDecl(node).Name, System.TObject(node));
         Continue;
       end;
       // Remove any imported function with the same name (main prog wins)
       if FModule.FindFunction(TAstFuncDecl(node).Name) <> nil then
         FModule.RemoveFunction(TAstFuncDecl(node).Name);
       fn := FModule.AddFunction(TAstFuncDecl(node).Name);
       // Lower function body
       FCurrentFunc := fn;
       FCurrentFuncDecl := TAstFuncDecl(node);
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for j := 0 to Length(FLocalConst) - 1 do
          if Assigned(FLocalConst[j]) then
            FLocalConst[j].Free;
        SetLength(FLocalConst, 0);
        FTempCounter := 0;
       fn.ParamCount := Length(TAstFuncDecl(node).Params);
       fn.LocalCount := fn.ParamCount;
       // Copy safety pragmas from AST to IR
       fn.SafetyPragmas := TAstFuncDecl(node).SafetyPragmas;

       // Calculate ReturnStructSize for struct-returning functions
       fn.ReturnStructSize := 0;
       if TAstFuncDecl(node).ReturnTypeName <> '' then
       begin
         structIdx := FStructTypes.IndexOf(TAstFuncDecl(node).ReturnTypeName);
         if structIdx >= 0 then
         begin
           sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
           fn.ReturnStructSize := sd.Size;
         end;
       end;
        SetLength(FLocalTypes, fn.LocalCount);
        SetLength(FLocalConst, fn.LocalCount);
        SetLength(FLocalIsStruct, fn.LocalCount);
        SetLength(FLocalElemSize, fn.LocalCount);
        SetLength(FLocalTypeNames, fn.LocalCount);
        for j := 0 to fn.ParamCount - 1 do
        begin
          FLocalMap.AddObject(TAstFuncDecl(node).Params[j].Name, IntToObj(j));
          FLocalTypes[j] := TAstFuncDecl(node).Params[j].ParamType;
          FLocalConst[j] := nil;
          FLocalIsStruct[j] := False;
          FLocalElemSize[j] := 0;
          // Record type name for struct parameter field resolution
          if TAstFuncDecl(node).Params[j].TypeName <> '' then
            FLocalTypeNames[j] := TAstFuncDecl(node).Params[j].TypeName
          else
            FLocalTypeNames[j] := '';
        end;

       // lower statements sequentially
       for j := 0 to High(TAstFuncDecl(node).Body.Stmts) do
       begin
         LowerStmt(TAstFuncDecl(node).Body.Stmts[j]);
       end;
       
       // Emit implicit return for void functions if last statement wasn't a return
       if (Length(FCurrentFunc.Instructions) = 0) or
          (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
       begin
         instr := Default(TIRInstr);
         instr.Op := irFuncExit;
         instr.Src1 := -1;
         Emit(instr);
       end;
       
       FCurrentFunc := nil;
       FCurrentFuncDecl := nil;
    end
    else if node is TAstStructDecl then
    begin
      // Lower each method as a top-level mangled function: _L_<Struct>_<Method>
      for j := 0 to High(TAstStructDecl(node).Methods) do
      begin
        m := TAstStructDecl(node).Methods[j];
        mangled := '_L_' + TAstStructDecl(node).Name + '_' + m.Name;
        // create function
        fn := FModule.AddFunction(mangled);
        FCurrentFunc := fn;
        FCurrentFuncDecl := m;  // set current func decl for return type info
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for k := 0 to Length(FLocalConst) - 1 do
          if Assigned(FLocalConst[k]) then
            FLocalConst[k].Free;
        SetLength(FLocalConst, 0);
        FTempCounter := 0;
        
        if m.IsStatic then
        begin
          // Static method: no implicit self parameter
          fn.ParamCount := Length(m.Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // method parameters (no self)
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
            FLocalTypes[k] := m.Params[k].ParamType;
            FLocalConst[k] := nil;
            FLocalIsStruct[k] := False;
            FLocalElemSize[k] := 0;
          end;
        end
        else
        begin
          // Instance method: first param = self
          fn.ParamCount := Length(m.Params) + 1;
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // implicit self param at index 0
          // Note: self is a pointer to struct passed by caller, NOT a struct on stack
          // So we should NOT mark it as FLocalIsStruct - it's already an address
          FLocalMap.AddObject('self', IntToObj(0));
          FLocalTypes[0] := atUnresolved;
          FLocalConst[0] := nil;
          FLocalIsStruct[0] := False; // self holds address, don't use LEA
          FLocalElemSize[0] := 0;
          // method parameters follow
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
            FLocalTypes[k+1] := m.Params[k].ParamType;
            FLocalConst[k+1] := nil;
            FLocalIsStruct[k+1] := False;
            FLocalElemSize[k+1] := 0;
          end;
        end;
        
        // lower body
        for k := 0 to High(m.Body.Stmts) do
          LowerStmt(m.Body.Stmts[k]);
        
        // Emit implicit return for void methods if last statement wasn't a return
        if (Length(FCurrentFunc.Instructions) = 0) or 
           (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
        begin
          instr := Default(TIRInstr);
          instr.Op := irFuncExit;
          instr.Src1 := -1;
          Emit(instr);
        end;
        
        FCurrentFunc := nil;
        FCurrentFuncDecl := nil;
      end;
    end
    else if node is TAstClassDecl then
    begin
      // Lower each class method as a top-level mangled function: _L_<Class>_<Method>
      FCurrentClassDecl := TAstClassDecl(node); // set for super calls
      for j := 0 to High(TAstClassDecl(node).Methods) do
      begin
        m := TAstClassDecl(node).Methods[j];
        mangled := '_L_' + TAstClassDecl(node).Name + '_' + m.Name;
        // create function
        fn := FModule.AddFunction(mangled);
        FCurrentFunc := fn;
        FCurrentFuncDecl := m;  // set current func decl for return type info
        FLocalMap.Clear;
        // Free old FLocalConst entries before resetting
        for k := 0 to Length(FLocalConst) - 1 do
          if Assigned(FLocalConst[k]) then
            FLocalConst[k].Free;
        SetLength(FLocalConst, 0);
        FTempCounter := 0;
        
        if m.IsStatic then
        begin
          // Static method: no implicit self parameter
          fn.ParamCount := Length(m.Params);
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // method parameters (no self)
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
            FLocalTypes[k] := m.Params[k].ParamType;
            FLocalConst[k] := nil;
            FLocalIsStruct[k] := False;
            FLocalElemSize[k] := 0;
          end;
        end
        else
        begin
          // Instance method: first param = self (pointer to class instance)
          fn.ParamCount := Length(m.Params) + 1;
          fn.LocalCount := fn.ParamCount;
          SetLength(FLocalTypes, fn.LocalCount);
          SetLength(FLocalConst, fn.LocalCount);
          SetLength(FLocalIsStruct, fn.LocalCount);
          SetLength(FLocalElemSize, fn.LocalCount);
          // implicit self param at index 0
          // For classes, self is a pointer (8 bytes), not a struct on stack
          FLocalMap.AddObject('self', IntToObj(0));
          FLocalTypes[0] := atUnresolved;
          FLocalConst[0] := nil;
          FLocalIsStruct[0] := False; // self holds pointer address
          FLocalElemSize[0] := 0;
          // method parameters follow
          for k := 0 to High(m.Params) do
          begin
            FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
            FLocalTypes[k+1] := m.Params[k].ParamType;
            FLocalConst[k+1] := nil;
            FLocalIsStruct[k+1] := False;
            FLocalElemSize[k+1] := 0;
          end;
        end;

        // Skip abstract methods (no body to lower)
        if m.IsAbstract then
        begin
          FCurrentFunc := nil;
          FCurrentFuncDecl := nil;
          Continue;
        end;

        // lower body
        for k := 0 to High(m.Body.Stmts) do
          LowerStmt(m.Body.Stmts[k]);
        
        // Emit implicit return for void methods if last statement wasn't a return
        if (Length(FCurrentFunc.Instructions) = 0) or 
           (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
        begin
          instr := Default(TIRInstr);
          instr.Op := irFuncExit;
          instr.Src1 := -1;
          Emit(instr);
        end;
        
        FCurrentFunc := nil;
        FCurrentFuncDecl := nil;
      end;
      FCurrentClassDecl := nil; // clear after processing all methods of this class
    end
    else if node is TAstEnumDecl then
    begin
      // Register each enum value as a compile-time integer constant
      for j := 0 to High(TAstEnumDecl(node).Values) do
      begin
        cv := TConstValue.Create;
        cv.IsStr  := False;
        cv.IntVal := TAstEnumDecl(node).Values[j].Value;
        FConstMap.AddObject(TAstEnumDecl(node).Values[j].Name, System.TObject(cv));
      end;
    end
    else if node is TAstTypeDecl then
    begin
      // Register range types for runtime bounds-check emission (aerospace-todo P1 #7)
      if TAstTypeDecl(node).HasRange then
      begin
        if FRangeTypes.IndexOf(TAstTypeDecl(node).Name) < 0 then
          FRangeTypes.AddObject(TAstTypeDecl(node).Name, System.TObject(node));
      end;
    end
    else if node is TAstConDecl then
    begin
      // register compile-time constant for inline substitution
      cv := TConstValue.Create;
      if TAstConDecl(node).InitExpr is TAstIntLit then
      begin
        cv.IsStr := False;
        cv.IntVal := TAstIntLit(TAstConDecl(node).InitExpr).Value;
      end
      else if TAstConDecl(node).InitExpr is TAstStrLit then
      begin
        cv.IsStr := True;
        cv.StrVal := TAstStrLit(TAstConDecl(node).InitExpr).Value;
      end
      else if TAstConDecl(node).InitExpr is TAstBoolLit then
      begin
        cv.IsStr := False;
        if TAstBoolLit(TAstConDecl(node).InitExpr).Value then
          cv.IntVal := 1
        else
          cv.IntVal := 0;
      end
      else
      begin
        FDiag.Error('con initializer must be a literal', TAstConDecl(node).Span);
        cv.Free;
        Continue;
      end;
      FConstMap.AddObject(TAstConDecl(node).Name, System.TObject(cv));
    end;
  end;
  Result := FModule;
end;

procedure TIRLowering.EnsureClassLayout(cd: TAstClassDecl);
{ Compute field offsets for an imported class if not yet done by sema.
  Classes imported transitively (e.g., lexer.lyx imported by parser.lyx) may
  not have been processed by ComputeClassLayouts in sema because they were not
  directly visible to sema's FClassTypes.  We recompute the layout here so
  that the fallback field-access code in LowerStmt/LowerExpr uses correct offsets. }
var
  fldIdx: Integer;
  f: TStructField;
  off, fsize, falign: Integer;
  baseSize: Integer;
  baseIdx: Integer;
  baseCd: TAstClassDecl;
begin
  if not Assigned(cd) then Exit;
  if cd.Size <> 0 then Exit;  // already computed

  // Ensure base class layout first
  baseSize := 8;  // VMT pointer slot for all classes (even without virtual methods)
  if cd.BaseClassName <> '' then
  begin
    baseIdx := FClassTypes.IndexOf(cd.BaseClassName);
    if baseIdx >= 0 then
    begin
      baseCd := TAstClassDecl(FClassTypes.Objects[baseIdx]);
      EnsureClassLayout(baseCd);
      if baseCd.Size > 0 then
        baseSize := baseCd.Size;
    end;
  end;

  off := baseSize;
  for fldIdx := 0 to High(cd.Fields) do
  begin
    f := cd.Fields[fldIdx];
    fsize := 8; falign := 8;  // default: 8-byte pointer/int
    case f.FieldType of
      atInt8, atUInt8, atChar, atBool: begin fsize := 1; falign := 1; end;
      atInt16, atUInt16:               begin fsize := 2; falign := 2; end;
      atInt32, atUInt32, atF32:        begin fsize := 4; falign := 4; end;
      atInt64, atUInt64, atISize, atUSize, atF64, atPChar: begin fsize := 8; falign := 8; end;
      atUnresolved:
        begin
          // Named type — assume pointer (8 bytes)
          fsize := 8; falign := 8;
        end;
    else
      fsize := 8; falign := 8;
    end;
    // align offset
    if (off mod falign) <> 0 then
      off := ((off + falign - 1) div falign) * falign;
    cd.FieldOffsets[fldIdx] := off;
    off := off + fsize;
  end;
  // align total size to 8
  if (off mod 8) <> 0 then
    off := ((off + 7) div 8) * 8;
  cd.SetLayout(off, 8, baseSize);
end;

procedure TIRLowering.LowerImportedUnits(um: TUnitManager);
{ Lower all functions, constants and global variables from imported units
  Uses two-phase approach:
  Phase 1: Import all structs, classes, and constants
  Phase 2: Import all functions and global variables
  This ensures constants are available when function bodies are lowered }
var
  i, j, k, mi: Integer;
  loadedUnit: TLoadedUnit;
  node: TAstNode;
  fn: TIRFunction;
  m: TAstFuncDecl;
  mangled: string;
  unitAST: TAstProgram;
  cv: TConstValue;
  con: TAstConDecl;
  vd: TAstVarDecl;
  items: TAstExprList;
  vals: array of Int64;
  phase: Integer;
  instr: TIRInstr;
  structIdx: Integer;
  sd: TAstStructDecl;
begin
  if not Assigned(um) then Exit;

  { Three-phase approach:
    Phase 0: Pre-register ALL types (structs, classes) and constants/enums.
             Class method bodies are NOT lowered yet. This ensures that when
             Phase 1 lowers class method bodies, every imported constant (e.g.
             PARSER_NODE_SIZE from bootstrap.parser) is already in FConstMap
             and every imported class type is already in FClassTypes — regardless
             of which unit appears first in the reverse-order traversal.
    Phase 1: Lower class method bodies (all types/constants already available).
    Phase 2: Functions and global variables.
    Units are processed in REVERSE order so leaf units are handled first;
    duplicates are skipped via the existing IndexOf() checks. }
  for phase := 0 to 2 do
  begin
    for i := um.Units.Count - 1 downto 0 do
    begin
      loadedUnit := TLoadedUnit(um.Units.Objects[i]);
      if not Assigned(loadedUnit) or not Assigned(loadedUnit.AST) then
        Continue;

      unitAST := loadedUnit.AST;

      // Lower all declarations from this unit
      for j := 0 to High(unitAST.Decls) do
      begin
        node := unitAST.Decls[j];

          // PHASE 0: Register all types and constants (NO method body lowering).
          // By registering everything in a dedicated first pass, Phase 1 can lower
          // class method bodies knowing that all imported constants and class types
          // are already available — independent of unit processing order.
          if phase = 0 then
          begin
            if node is TAstStructDecl then
            begin
              if not TAstStructDecl(node).IsPublic then
                Continue;
              if FStructTypes.IndexOf(TAstStructDecl(node).Name) >= 0 then
                Continue;
              FStructTypes.AddObject(TAstStructDecl(node).Name, System.TObject(node));
            end
            else if node is TAstClassDecl then
            begin
              if not TAstClassDecl(node).IsPublic then
                Continue;
              if FClassTypes.IndexOf(TAstClassDecl(node).Name) >= 0 then
                Continue;
              FStructTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
              FClassTypes.AddObject(TAstClassDecl(node).Name, System.TObject(node));
              EnsureClassLayout(TAstClassDecl(node));
              FModule.AddClassDecl(TAstClassDecl(node));
              // Method bodies are NOT lowered here; that happens in Phase 1.
            end
            else if node is TAstConDecl then
            begin
              con := TAstConDecl(node);
              if FConstMap.IndexOf(con.Name) >= 0 then
                Continue;
              cv := TConstValue.Create;
              if con.InitExpr is TAstIntLit then
              begin
                cv.IsStr := False;
                cv.IntVal := TAstIntLit(con.InitExpr).Value;
              end
              else if con.InitExpr is TAstStrLit then
              begin
                cv.IsStr := True;
                cv.StrVal := TAstStrLit(con.InitExpr).Value;
              end
              else if con.InitExpr is TAstBoolLit then
              begin
                cv.IsStr := False;
                if TAstBoolLit(con.InitExpr).Value then
                  cv.IntVal := 1
                else
                  cv.IntVal := 0;
              end
              else
              begin
                FDiag.Error('imported con initializer must be a literal', con.Span);
                cv.Free;
                Continue;
              end;
              FConstMap.AddObject(con.Name, System.TObject(cv));
            end
            else if node is TAstEnumDecl then
            begin
              for k := 0 to High(TAstEnumDecl(node).Values) do
              begin
                if FConstMap.IndexOf(TAstEnumDecl(node).Values[k].Name) >= 0 then
                  Continue;
                cv := TConstValue.Create;
                cv.IsStr  := False;
                cv.IntVal := TAstEnumDecl(node).Values[k].Value;
                FConstMap.AddObject(TAstEnumDecl(node).Values[k].Name, System.TObject(cv));
              end;
            end;
          end
          // PHASE 1: Lower class method bodies.
          // All types and constants are already registered (Phase 0), so
          // imported constants and class types are available during lowering.
          else if phase = 1 then
          begin
            if node is TAstClassDecl then
            begin
              if not TAstClassDecl(node).IsPublic then
                Continue;
              // Class was already registered in Phase 0; just lower the method bodies.
              FCurrentClassDecl := TAstClassDecl(node);
              for mi := 0 to High(TAstClassDecl(node).Methods) do
              begin
                m := TAstClassDecl(node).Methods[mi];
                mangled := '_L_' + TAstClassDecl(node).Name + '_' + m.Name;
                fn := FModule.AddFunction(mangled);
                FCurrentFunc := fn;
                FCurrentFuncDecl := m;
                FLocalMap.Clear;
                for k := 0 to Length(FLocalConst) - 1 do
                  if Assigned(FLocalConst[k]) then
                    FLocalConst[k].Free;
                SetLength(FLocalConst, 0);
                FTempCounter := 0;
                if m.IsStatic then
                begin
                  fn.ParamCount := Length(m.Params);
                  fn.LocalCount := fn.ParamCount;
                  SetLength(FLocalTypes, fn.LocalCount);
                  SetLength(FLocalConst, fn.LocalCount);
                  SetLength(FLocalIsStruct, fn.LocalCount);
                  SetLength(FLocalElemSize, fn.LocalCount);
                  SetLength(FLocalTypeNames, fn.LocalCount);
                  for k := 0 to High(m.Params) do
                  begin
                    FLocalMap.AddObject(m.Params[k].Name, IntToObj(k));
                    FLocalTypes[k] := m.Params[k].ParamType;
                    FLocalConst[k] := nil;
                    FLocalIsStruct[k] := False;
                    FLocalElemSize[k] := 0;
                    if m.Params[k].TypeName <> '' then
                      FLocalTypeNames[k] := m.Params[k].TypeName
                    else
                      FLocalTypeNames[k] := '';
                  end;
                end
                else
                begin
                  fn.ParamCount := Length(m.Params) + 1;
                  fn.LocalCount := fn.ParamCount;
                  SetLength(FLocalTypes, fn.LocalCount);
                  SetLength(FLocalConst, fn.LocalCount);
                  SetLength(FLocalIsStruct, fn.LocalCount);
                  SetLength(FLocalElemSize, fn.LocalCount);
                  SetLength(FLocalTypeNames, fn.LocalCount);
                  FLocalMap.AddObject('self', IntToObj(0));
                  FLocalTypes[0] := atUnresolved;
                  FLocalConst[0] := nil;
                  FLocalIsStruct[0] := False;
                  FLocalElemSize[0] := 0;
                  FLocalTypeNames[0] := TAstClassDecl(node).Name;  // 'self' = current class
                  for k := 0 to High(m.Params) do
                  begin
                    FLocalMap.AddObject(m.Params[k].Name, IntToObj(k+1));
                    FLocalTypes[k+1] := m.Params[k].ParamType;
                    FLocalConst[k+1] := nil;
                    FLocalIsStruct[k+1] := False;
                    FLocalElemSize[k+1] := 0;
                    if m.Params[k].TypeName <> '' then
                      FLocalTypeNames[k+1] := m.Params[k].TypeName
                    else
                      FLocalTypeNames[k+1] := '';
                  end;
                end;
                if m.IsAbstract then
                begin
                  FCurrentFunc := nil;
                  FCurrentFuncDecl := nil;
                  Continue;
                end;
                for k := 0 to High(m.Body.Stmts) do
                  LowerStmt(m.Body.Stmts[k]);
                if (Length(FCurrentFunc.Instructions) = 0) or
                   (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
                begin
                  instr := Default(TIRInstr);
                  instr.Op := irFuncExit;
                  instr.Src1 := -1;
                  Emit(instr);
                end;
                FCurrentFunc := nil;
                FCurrentFuncDecl := nil;
              end;
              FCurrentClassDecl := nil;
            end;
            // Structs, constants, and enums are handled in Phase 0; nothing to do here.
          end
          // PHASE 2: Functions and Global Variables
          else
        begin
          // Process global variable declarations (var / let / pub var / pub let)
          if node is TAstVarDecl then
          begin
            vd := TAstVarDecl(node);
            // Check if variable already exists (avoid duplicates)
            if FGlobalVars.IndexOf(vd.Name) >= 0 then
              Continue;

            // Register global variable (import all, not just public ones)
            FGlobalVars.AddObject(vd.Name, System.TObject(node));

            // Register in module with init value
            if vd.InitExpr is TAstIntLit then
              FModule.AddGlobalVar(vd.Name, TAstIntLit(vd.InitExpr).Value, True)
            else if vd.InitExpr is TAstArrayLit then
            begin
              // Collect integer items if possible
              items := TAstArrayLit(vd.InitExpr).Items;
              SetLength(vals, 0);
              for k := 0 to High(items) do
              begin
                if items[k] is TAstIntLit then
                begin
                  SetLength(vals, Length(vals) + 1);
                  vals[High(vals)] := TAstIntLit(items[k]).Value;
                end
                else
                begin
                  SetLength(vals, 0);
                  Break;
                end;
              end;
              if Length(vals) > 0 then
                FModule.AddGlobalArray(vd.Name, vals)
              else
                FModule.AddGlobalVar(vd.Name, 0, False);
            end
            else
              FModule.AddGlobalVar(vd.Name, 0, False);
          end
          // Process function declarations
          else if node is TAstFuncDecl then
          begin
            // Note: We must include ALL functions (including private ones) from imported units,
            // because public functions may call private helper functions.
            // The visibility check (IsPublic) is only relevant for name resolution in the
            // importing module - it should not affect code generation.

            // Skip if function already imported (avoid duplicate names from different units)
            // This can happen when wrapper functions in one unit call functions with the same name in another unit
            // Process units in reverse order so implementations come before wrappers
            if FImportedFuncs.IndexOf(TAstFuncDecl(node).Name) >= 0 then
              Continue;

            // Track as imported function for CallMode resolution.
            // Extern fn from imported units must go into FExternFuncs (not FImportedFuncs)
            // so that callers inside the same unit get cmExternal, generating PLT stubs.
            if TAstFuncDecl(node).IsExtern then
            begin
              // Known Linux syscall wrappers must NOT go into FExternFuncs — they are
              // dispatched as irCallBuiltin by name in the call-lowering chain below.
              // Adding them here would route callers to a PLT stub that does not exist.
              if (TAstFuncDecl(node).Name = 'sys_socket')    or
                 (TAstFuncDecl(node).Name = 'sys_bind')      or
                 (TAstFuncDecl(node).Name = 'sys_listen')    or
                 (TAstFuncDecl(node).Name = 'sys_accept')    or
                 (TAstFuncDecl(node).Name = 'sys_connect')   or
                 (TAstFuncDecl(node).Name = 'sys_recvfrom')  or
                 (TAstFuncDecl(node).Name = 'sys_sendto')    or
                 (TAstFuncDecl(node).Name = 'sys_setsockopt') or
                 (TAstFuncDecl(node).Name = 'sys_getsockopt') or
                 (TAstFuncDecl(node).Name = 'sys_fcntl')     or
                 (TAstFuncDecl(node).Name = 'sys_shutdown')  or
                 (TAstFuncDecl(node).Name = 'sys_close')     or
                 (TAstFuncDecl(node).Name = 'sys_read')      or
                 (TAstFuncDecl(node).Name = 'sys_write')     or
                 (TAstFuncDecl(node).Name = 'sys_select')    or
                 (TAstFuncDecl(node).Name = 'sys_poll')      then
              begin
                Continue;  // Handled as irCallBuiltin by the call-lowering name dispatch
              end;
              FExternFuncs.Add(TAstFuncDecl(node).Name);
              if TAstFuncDecl(node).LibraryName <> '' then
                FModule.RegisterExternLibrary(TAstFuncDecl(node).Name,
                  TAstFuncDecl(node).LibraryName);
              Continue;  // No body to lower for extern fn
            end;
            FImportedFuncs.Add(TAstFuncDecl(node).Name);
            // Check if function already exists (avoid duplicates)
            fn := FModule.FindFunction(TAstFuncDecl(node).Name);
            if not Assigned(fn) then
            begin
              fn := FModule.AddFunction(TAstFuncDecl(node).Name);
              FCurrentFunc := fn;
              FCurrentFuncDecl := TAstFuncDecl(node);
              FLocalMap.Clear;
              // Free old FLocalConst entries before resetting
              for k := 0 to Length(FLocalConst) - 1 do
                if Assigned(FLocalConst[k]) then
                  FLocalConst[k].Free;
              SetLength(FLocalConst, 0);
              FTempCounter := 0;
              fn.ParamCount := Length(TAstFuncDecl(node).Params);
              fn.LocalCount := fn.ParamCount;
              SetLength(FLocalTypes, fn.LocalCount);
              SetLength(FLocalConst, fn.LocalCount);
              SetLength(FLocalIsStruct, fn.LocalCount);
              SetLength(FLocalElemSize, fn.LocalCount);
              SetLength(FLocalTypeNames, fn.LocalCount);

              for k := 0 to fn.ParamCount - 1 do
              begin
                FLocalMap.AddObject(TAstFuncDecl(node).Params[k].Name, IntToObj(k));
                FLocalTypes[k] := TAstFuncDecl(node).Params[k].ParamType;
                FLocalConst[k] := nil;
                FLocalIsStruct[k] := False;
                FLocalElemSize[k] := 0;
                // Record class type name for method-call resolution on class-typed params
                if TAstFuncDecl(node).Params[k].TypeName <> '' then
                  FLocalTypeNames[k] := TAstFuncDecl(node).Params[k].TypeName
                else
                  FLocalTypeNames[k] := '';
              end;

              // Calculate ReturnStructSize so the backend generates correct sret prologue
              fn.ReturnStructSize := 0;
              if TAstFuncDecl(node).ReturnTypeName <> '' then
              begin
                structIdx := FStructTypes.IndexOf(TAstFuncDecl(node).ReturnTypeName);
                if structIdx >= 0 then
                begin
                  sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
                  fn.ReturnStructSize := sd.Size;
                end;
              end;

              // Lower statements
              if Assigned(TAstFuncDecl(node).Body) then
                for k := 0 to High(TAstFuncDecl(node).Body.Stmts) do
                  LowerStmt(TAstFuncDecl(node).Body.Stmts[k]);

              // Emit implicit return for void functions if last statement wasn't a return
              if (Length(FCurrentFunc.Instructions) = 0) or
                 (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
              begin
                // Initialize instr locally for this scope
                instr := Default(TIRInstr);
                instr.Op := irFuncExit;
                instr.Src1 := -1;
                Emit(instr);
              end;

              FCurrentFunc := nil;
              FCurrentFuncDecl := nil;
            end;
          end;
        end;
      end;
    end;
  end;
end;

{ Lowering helpers }

// Returns struct decl for current function's return type, or nil if not a struct
function TIRLowering.GetReturnStructDecl: TAstStructDecl;
var
  idx: Integer;
  typeName: string;
begin
  Result := nil;
  if not Assigned(FCurrentFuncDecl) then
    Exit;
  
  typeName := FCurrentFuncDecl.ReturnTypeName;
  if typeName = '' then
    Exit;
  
  // Handle 'Self' (should already be resolved in sema, but just in case)
  if (typeName = 'Self') or (typeName = 'self') then
    Exit; // Can't resolve without struct context here
  
  idx := FStructTypes.IndexOf(typeName);
  if idx >= 0 then
    Result := TAstStructDecl(FStructTypes.Objects[idx]);
end;

function TIRLowering.ResolveLocal(const name: string): Integer;
var
  idx: Integer;
begin
  idx := FLocalMap.IndexOf(name);
  if idx >= 0 then
    Result := ObjToInt(FLocalMap.Objects[idx])
  else
    Result := -1;
end;

// Substitute type param 'n' with its concrete type if a substitution is active
function TIRLowering.SubstType(t: TAurumType; const n: string): TAurumType;
var
  i: Integer;
begin
  if (t = atUnresolved) and (n <> '') then
    for i := 0 to High(FTypeSubstParams) do
      if FTypeSubstParams[i] = n then
        Exit(FTypeSubstTypes[i]);
  Result := t;
end;

// Monomorphize a generic function: lower its body with type substitution active
procedure TIRLowering.LowerGenericSpecialization(decl: TAstFuncDecl;
  const mangledName: string; const typeArgs: array of TAurumType);
var
  fn: TIRFunction;
  j: Integer;
  savedFunc: TIRFunction;
  savedDecl: TAstFuncDecl;
  savedLocalMap: TStringList;
  savedTempCounter: Integer;
  savedSubstParams: TStringArray;
  savedSubstTypes: array of TAurumType;
  paramType: TAurumType;
  instr: TIRInstr;
begin
  instr := Default(TIRInstr);

  // Mark as already specialized (before lowering, to handle recursion)
  FGenericSpecializations.Add(mangledName);

  // Save current function context
  savedFunc := FCurrentFunc;
  savedDecl := FCurrentFuncDecl;
  savedLocalMap := TStringList.Create;
  for j := 0 to FLocalMap.Count - 1 do
    savedLocalMap.AddObject(FLocalMap[j], FLocalMap.Objects[j]);
  savedTempCounter := FTempCounter;
  savedSubstParams := FTypeSubstParams;
  savedSubstTypes := FTypeSubstTypes;

  try
    // Install substitution: decl.TypeParams[i] -> typeArgs[i]
    SetLength(FTypeSubstParams, Length(decl.TypeParams));
    SetLength(FTypeSubstTypes, Length(decl.TypeParams));
    for j := 0 to High(decl.TypeParams) do
    begin
      FTypeSubstParams[j] := decl.TypeParams[j];
      if j < Length(typeArgs) then
        FTypeSubstTypes[j] := typeArgs[j]
      else
        FTypeSubstTypes[j] := atInt64; // fallback
    end;

    // Create new function in module
    fn := FModule.AddFunction(mangledName);
    FCurrentFunc := fn;
    FCurrentFuncDecl := decl;
    FLocalMap.Clear;
    for j := 0 to Length(FLocalConst) - 1 do
      if Assigned(FLocalConst[j]) then
        FLocalConst[j].Free;
    SetLength(FLocalConst, 0);
    FTempCounter := 0;

    // Set up parameters with type substitution applied
    fn.ParamCount := Length(decl.Params);
    fn.LocalCount := fn.ParamCount;
    SetLength(FLocalTypes, fn.LocalCount);
    SetLength(FLocalConst, fn.LocalCount);
    for j := 0 to fn.ParamCount - 1 do
    begin
      FLocalMap.AddObject(decl.Params[j].Name, IntToObj(j));
      paramType := SubstType(decl.Params[j].ParamType, decl.Params[j].TypeName);
      FLocalTypes[j] := paramType;
      FLocalConst[j] := nil;
    end;

    // Lower the function body
    for j := 0 to High(decl.Body.Stmts) do
      LowerStmt(decl.Body.Stmts[j]);

    // Emit implicit return for void functions
    if (Length(FCurrentFunc.Instructions) = 0) or
       (FCurrentFunc.Instructions[High(FCurrentFunc.Instructions)].Op <> irFuncExit) then
    begin
      instr := Default(TIRInstr);
      instr.Op := irFuncExit;
      instr.Src1 := -1;
      Emit(instr);
    end;

  finally
    // Restore parent function context
    FCurrentFunc := savedFunc;
    FCurrentFuncDecl := savedDecl;
    FLocalMap.Clear;
    for j := 0 to savedLocalMap.Count - 1 do
      FLocalMap.AddObject(savedLocalMap[j], savedLocalMap.Objects[j]);
    savedLocalMap.Free;
    FTempCounter := savedTempCounter;
    FTypeSubstParams := savedSubstParams;
    FTypeSubstTypes := savedSubstTypes;
  end;
end;


function TIRLowering.LowerExpr(expr: TAstExpr): Integer;
  var
    instr: TIRInstr;
    loc: Integer;
    tmp: Integer;
    condTmp: Integer;
    t0, t1, t2, tResult, tVec, tIdx: Integer;
    i, k: Integer;
    strIdx: Integer;
    cv: TConstValue;
    argCount: Integer;
    argTemps: array of Integer;
    callTemps: array of Integer;
    callName: string;
    regexLit: TAstRegexLit;
    useCompiled: Boolean;
    compiledTemp: Integer;
    lenTemp: Integer;
    fn: TIRFunction;
    ltype, rType: TAurumType;
    width: Integer;
    w: Integer;
    captureIdx: Integer;
    lit: Int64;
    mask64: UInt64;
    truncated: UInt64;
    half: UInt64;
    signedVal: Int64;
    cvLocal: TConstValue;
    vd: TAstVarDecl;
    castTypeName: string;
    items: TAstExprList;
    elemSize: Integer;
    fa: TAstFieldAssign;
    fldOffset: Integer;
    fldType: TAurumType;
    ownerName: string;
    slotCount: Integer;
    baseIdx: Integer;
    isFloatArith: Boolean;
    isFloatCmp: Boolean;
    isStringConcat: Boolean;
    mangled: string;
    // Map/Set lowering (v0.5.0)
    entryCount: Integer;
    elemCount: Integer;
    containerType: TAurumType;
    // Call handling
    call: TAstCall;
    // Virtual call handling
    classIdx: Integer;
    cd: TAstClassDecl;
    methodIdx: Integer;
    vmtIdx: Integer;
    vmtClassName: string;
    vmtMethodName: string;
    posIdx: Integer;
    hasVMT: Boolean;
    // Null-Coalesce Phase 2
    zeroSlot: Integer;
    resultSlot: Integer;
    cmpSlot: Integer;
    xSlot: Integer;
    ySlot: Integer;
    useRightLabel: string;
    endLabel: string;
    arrLen: Integer;
    baseSlot: Integer;
    // bounds-check temporaries
    gv: TAstVarDecl;
    tZero, tLen, tGe0, tLtLen, tOk, tLtZero, tGeLen: Integer;
    msgTmp, codeTmp: Integer;
    staticIdx: Integer;
    errLbl, skipLbl: string;
    // Nested field access
    baseExpr: TAstExpr;
    // Method call type lookup
    recvExpr: TAstExpr;
    // Format expr lowering
    instr2: TIRInstr;
    tWidth, tDecimals: Integer;
    // Generic call monomorphization
    mangledName: string;
    idx: Integer;
    // Struct field resolution in imported function bodies
    structIdx: Integer;
    sd: TAstStructDecl;
    fi: Integer;
  begin
  Result := -1;
  if not Assigned(expr) then
    Exit;

  // Provenance Tracking (WP-F): set current AST node for IR provenance
  FCurrentASTNode := expr;

  // Initialize instruction
  instr := Default(TIRInstr);

  case expr.Kind of
    nkIntLit:
      begin
        // Emit integer constant
        t0 := NewTemp;
        instr.Op := irConstInt;
        instr.Dest := t0;
        instr.ImmInt := TAstIntLit(expr).Value;
        Emit(instr);
        Result := t0;
      end;

    nkStrLit:
      begin
        // Intern string and emit reference
        strIdx := FModule.InternString(TAstStrLit(expr).Value);
        t0 := NewTemp;
        instr.Op := irConstStr;
        instr.Dest := t0;
        instr.ImmStr := IntToStr(strIdx);
        Emit(instr);
        Result := t0;
      end;

    nkRegexLit:
      begin
        // Regex-Literal: like string, store pattern in data section
        // Syntax validation happens in Sema already
        strIdx := FModule.InternString(TAstRegexLit(expr).Pattern);
        t0 := NewTemp;
        instr.Op := irConstStr;
        instr.Dest := t0;
        instr.ImmStr := IntToStr(strIdx);
        Emit(instr);
        Result := t0;
      end;

    nkBoolLit:
      begin
        // Emit boolean as 0 or 1
        t0 := NewTemp;
        instr.Op := irConstInt;
        instr.Dest := t0;
        if TAstBoolLit(expr).Value then
          instr.ImmInt := 1
        else
          instr.ImmInt := 0;
        Emit(instr);
        Result := t0;
      end;

    nkFloatLit:
      begin
        // Emit float constant
        t0 := NewTemp;
        instr.Op := irConstFloat;
        instr.Dest := t0;
        instr.ImmFloat := TAstFloatLit(expr).Value;
        Emit(instr);
        Result := t0;
      end;

    nkCharLit:
      begin
        // Emit char as integer constant
        t0 := NewTemp;
        instr.Op := irConstInt;
        instr.Dest := t0;
        instr.ImmInt := Ord(TAstCharLit(expr).Value);
        Emit(instr);
        Result := t0;
      end;

    nkIdent:
      begin
        // Check if it's a global variable first
        if IsGlobalVar(TAstIdent(expr).Name) then
        begin
          // Load global variable
          t0 := NewTemp;
          instr.Op := irLoadGlobal;
          instr.Dest := t0;
          instr.ImmStr := TAstIdent(expr).Name;
          Emit(instr);
          Result := t0;
          Exit;
        end;
        
        // Look up local variable
        loc := ResolveLocal(TAstIdent(expr).Name);
        if loc < -1 then
        begin
          // Captured variable: load from parent frame via static link
          // loc = -100 - captureIndex
          captureIdx := -100 - loc;
          if Assigned(FCurrentFuncDecl) and (captureIdx <= High(FCurrentFuncDecl.CapturedVars)) then
          begin
            // The OuterSlot in CapturedVars needs to be looked up in parent's FLocalMap
            // But we cleared FLocalMap when we entered this function.
            // For now, use the captured var index as a hint — the actual slot is determined
            // by the parent function's local map at the time of the call.
            // We'll load from static_link + SlotOffset(outerSlot) where outerSlot is 
            // the index in the parent's locals.
            // Since we don't have the parent's FLocalMap here, we use a convention:
            // The captured var's OuterSlot is stored as the slot index in the parent function.
            // This was set by the Sema, but the Sema doesn't know slot indices.
            // WORKAROUND: Use the captured var index as outerSlot (0-based).
            // This works because the parent's captured vars are allocated in order.
            t0 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irLoadCaptured;
            instr.Dest := t0;
            instr.Src1 := 0; // static link is in slot 0
            instr.ImmInt := captureIdx; // use capture index as outer slot (patched later)
            Emit(instr);
            Result := t0;
            Exit;
          end;
        end;
        if loc < 0 then
        begin
          // Check if it's a compile-time constant
          i := FConstMap.IndexOf(TAstIdent(expr).Name);
          if i >= 0 then
          begin
            cv := TConstValue(FConstMap.Objects[i]);
            t0 := NewTemp;
            if cv.IsStr then
            begin
              strIdx := FModule.InternString(cv.StrVal);
              instr.Op := irConstStr;
              instr.Dest := t0;
              instr.ImmStr := IntToStr(strIdx);
            end
            else
            begin
              instr.Op := irConstInt;
              instr.Dest := t0;
              instr.ImmInt := cv.IntVal;
            end;
            Emit(instr);
            Result := t0;
          end
          else
          begin
            FDiag.Error('undefined identifier: ' + TAstIdent(expr).Name, expr.Span);
            Exit;
          end;
        end
        else
        begin
          // Check for const-folded local
          if (loc < Length(FLocalConst)) and Assigned(FLocalConst[loc]) then
          begin
            cv := FLocalConst[loc];
            t0 := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := t0;
            instr.ImmInt := cv.IntVal;
            Emit(instr);
            Result := t0;
          end
          else
          begin
            // Check if this local is a struct - if so, load address instead of value
            if (loc < Length(FLocalIsStruct)) and FLocalIsStruct[loc] then
            begin
              // Struct local: load base address for field access
              // Need to know struct size to calculate correct base address
              slotCount := 1;
              if loc < Length(FLocalSlotCount) then
                slotCount := FLocalSlotCount[loc];
              if slotCount < 1 then slotCount := 1;
              
              t0 := NewTemp;
              instr.Op := irLoadStructAddr;
              instr.Dest := t0;
              instr.Src1 := loc;
              instr.StructSize := slotCount * 8; // size in bytes
              Emit(instr);
              Result := t0;
            end
            else
            begin
              // Load local into temp
              t0 := NewTemp;
              instr.Op := irLoadLocal;
              instr.Dest := t0;
              instr.Src1 := loc;
              Emit(instr);
              // If local type is narrower than 64 bits, emit sign- or zero-extend
              ltype := GetLocalType(loc);
              if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64) then
              begin
                width := 64;
                case ltype of
                  atInt8, atUInt8: width := 8;
                  atInt16, atUInt16: width := 16;
                  atInt32, atUInt32: width := 32;
                end;
                if ltype in [atInt8, atInt16, atInt32] then
                begin
                  instr.Op := irSExt; instr.Dest := NewTemp; instr.Src1 := t0; instr.ImmInt := width; Emit(instr);
                  Result := instr.Dest;
                end
                else if ltype in [atUInt8, atUInt16, atUInt32] then
                begin
                  instr.Op := irZExt; instr.Dest := NewTemp; instr.Src1 := t0; instr.ImmInt := width; Emit(instr);
                  Result := instr.Dest;
                end
                else
                  Result := t0;
              end
              else
                Result := t0;
            end; // end else (non-struct local)
          end; // end else (non-const-folded)
        end; // end else (local found)
      end;

    nkBinOp:
      begin
        // Lower left and right operands
        t1 := LowerExpr(TAstBinOp(expr).Left);
        t2 := LowerExpr(TAstBinOp(expr).Right);
        if (t1 < 0) or (t2 < 0) then
          Exit;

        // Determine result type based on operand types
        // Get types from AST
        lType := TAstBinOp(expr).Left.ResolvedType;
        rType := TAstBinOp(expr).Right.ResolvedType;

        // Check if both operands are float
        isFloatArith := (lType = atF64) and (rType = atF64);
        isFloatCmp := isFloatArith and (TAstBinOp(expr).Op in [tkEq, tkNeq, tkLt, tkLe, tkGt, tkGe]);

        // Check for string concatenation (pchar + pchar)
        isStringConcat := (lType = atPChar) and (rType = atPChar) and (TAstBinOp(expr).Op = tkPlus);

        t0 := NewTemp;
        case TAstBinOp(expr).Op of
          tkPlus:
            begin
              if isFloatArith then
                instr.Op := irFAdd
              else if isStringConcat then
              begin
                // String concatenation: call str_concat builtin
                instr.Op := irCallBuiltin;
                instr.Dest := t0;
                instr.ImmStr := 'str_concat';
                instr.ImmInt := 2;
                SetLength(instr.ArgTemps, 2);
                instr.ArgTemps[0] := t1;
                instr.ArgTemps[1] := t2;
                Emit(instr);
                Result := t0;
                Exit;
              end
              else
                instr.Op := irAdd;
            end;
            tkMinus:
              if isFloatArith then
                instr.Op := irFSub
              else
                instr.Op := irSub;
            tkStar:
              if isFloatArith then
                instr.Op := irFMul
              else
                instr.Op := irMul;
            tkSlash:
              if isFloatArith then
                instr.Op := irFDiv
              else
                instr.Op := irDiv;
            tkPercent:
              instr.Op := irMod;

            // Bitwise operators
            tkBitAnd:   instr.Op := irBitAnd;
            tkBitOr:    instr.Op := irBitOr;
            tkBitXor:   instr.Op := irBitXor;
            tkShiftLeft: instr.Op := irShl;
            tkShiftRight: instr.Op := irShr;

            tkEq:
              if isFloatCmp then instr.Op := irFCmpEq else instr.Op := irCmpEq;
            tkNeq:
              if isFloatCmp then instr.Op := irFCmpNeq else instr.Op := irCmpNeq;
            tkLt:
              if isFloatCmp then instr.Op := irFCmpLt else instr.Op := irCmpLt;
            tkLe:
              if isFloatCmp then instr.Op := irFCmpLe else instr.Op := irCmpLe;
            tkGt:
              if isFloatCmp then instr.Op := irFCmpGt else instr.Op := irCmpGt;
            tkGe:
              if isFloatCmp then instr.Op := irFCmpGe else instr.Op := irCmpGe;
            tkAnd:
              instr.Op := irAnd;
            tkOr:
              instr.Op := irOr;
          else
            FDiag.Error('unsupported binary operator ' + TokenKindToStr(TAstBinOp(expr).Op), expr.Span);
            Exit;
          end;

        // Set Dest, Src1, Src2 for binary operation
        instr.Dest := t0;
        instr.Src1 := t1;
        instr.Src2 := t2;
        Emit(instr);
        Result := t0;
      end;

    nkUnaryOp:
      begin
        t1 := LowerExpr(TAstUnaryOp(expr).Operand);
        if t1 < 0 then Exit;

        t0 := NewTemp;
        instr.Dest := t0;
        instr.Src1 := t1;
        case TAstUnaryOp(expr).Op of
          tkMinus:
            instr.Op := irNeg;
          tkNot:
            instr.Op := irNot; // Logical NOT (for boolean)
          tkBitNot:
            instr.Op := irBitNot; // Bitwise NOT (for integers)
        else
          FDiag.Error('unsupported unary operator ' + TokenKindToStr(TAstUnaryOp(expr).Op), expr.Span);
          Exit;
        end;
        Emit(instr);
        Result := t0;
      end;

    nkCall:
      begin
        call := TAstCall(expr);
        argCount := Length(call.Args);

        // Bootstrap compat: sizeof(TypeName) is a compile-time constant.
        // Handle before argument evaluation since the arg is a type name, not a variable.
        if call.Name = 'sizeof' then
        begin
          if (argCount = 1) and (call.Args[0] is TAstIdent) then
          begin
            vmtClassName := TAstIdent(call.Args[0]).Name;
            classIdx := FClassTypes.IndexOf(vmtClassName);
            if classIdx >= 0 then
            begin
              cd := TAstClassDecl(FClassTypes.Objects[classIdx]);
              EnsureClassLayout(cd);
              t0 := NewTemp;
              instr.Op := irConstInt;
              instr.Dest := t0;
              instr.ImmInt := cd.Size;
              Emit(instr);
              Result := t0;
              Exit;
            end;
          end;
          // Unknown type — emit 8 as conservative default
          t0 := NewTemp;
          instr.Op := irConstInt;
          instr.Dest := t0;
          instr.ImmInt := 8;
          Emit(instr);
          Result := t0;
          Exit;
        end;

        SetLength(argTemps, argCount);
        for i := 0 to High(call.Args) do
          argTemps[i] := LowerExpr(call.Args[i]);

        // Generic function call: monomorphize on demand
        if Length(call.TypeArgs) > 0 then
        begin
          // Build mangled name: _G_funcname__type1__type2__...
          mangledName := '_G_' + call.Name;
          for i := 0 to High(call.TypeArgs) do
            mangledName := mangledName + '__' + AurumTypeToStr(call.TypeArgs[i]);
          // Generate specialization if not already done
          if FGenericSpecializations.IndexOf(mangledName) < 0 then
          begin
            idx := FGenericFuncs.IndexOf(call.Name);
            if idx >= 0 then
              LowerGenericSpecialization(TAstFuncDecl(FGenericFuncs.Objects[idx]),
                mangledName, call.TypeArgs)
            else
              FDiag.Error('unknown generic function: ' + call.Name, expr.Span);
          end;
          // Emit call to specialized version
          t0 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := mangledName;
          instr.ImmInt := argCount;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := t0;
          Exit;
        end;

        // === In-Situ Data Visualizer (Debugging 2.0) ===
        // Inspect(expr) - gibt formatierte Debug-Ausgabe im Terminal aus
        if (call.Name = 'Inspect') or 
           ((call.Namespace = 'Debug') and (call.Name = 'Inspect')) then
        begin
          // irInspect: Src1=value temp, ImmStr=varname, InspectType=type
          instr.Op := irInspect;
          instr.Dest := -1; // void return
          if argCount >= 1 then
          begin
            instr.Src1 := argTemps[0];
            // Versuche den Variablennamen zu extrahieren
            if (call.Args[0] is TAstIdent) then
              instr.ImmStr := TAstIdent(call.Args[0]).Name
            else
              instr.ImmStr := '<expr>';
            // Typinfo aus dem AST-Knoten
            instr.InspectType := call.Args[0].ResolvedType;
            // Für Structs: Name und Felder extrahieren
            if call.Args[0] is TAstIdent then
            begin
              loc := ResolveLocal(TAstIdent(call.Args[0]).Name);
              if loc >= 0 then
              begin
                if (loc < Length(FLocalTypeNames)) and (FLocalTypeNames[loc] <> '') then
                  instr.InspectStructName := FLocalTypeNames[loc];
              end;
            end;
          end
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          Emit(instr);
          Result := -1;
        end
        // Builtin calls
        else if (call.Name = 'PrintStr') or ((call.Namespace = 'IO') and (call.Name = 'PrintStr')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1; // no return value
          instr.ImmStr := 'PrintStr';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (call.Name = 'PrintLn') or 
                ((call.Namespace = 'IO') and (call.Name = 'PrintLn')) then
        begin
          // PrintLn: like PrintStr but adds newline
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintLn';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (call.Name = 'PrintInt') or
                ((call.Namespace = 'IO') and (call.Name = 'PrintInt')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintInt';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (call.Name = 'PrintFloat') or
                ((call.Namespace = 'IO') and (call.Name = 'PrintFloat')) then
        begin
          instr.Op := irCallBuiltin;
          instr.Dest := -1;
          instr.ImmStr := 'PrintFloat';
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Result := -1;
        end
        else if (call.Name = 'printf') or
                ((call.Namespace = 'IO') and (call.Name = 'printf')) then
        begin
          // printf is varargs - emit as generic external call
          instr.Op := irCall;
          instr.Dest := -1;
          instr.ImmStr := 'printf';
          instr.ImmInt := argCount;
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then
            instr.Src1 := argTemps[0]
          else
            instr.Src1 := -1;
          Emit(instr);
          Result := -1;
        end
        else if (call.Name = 'getpid') or
                ((call.Namespace = 'OS') and (call.Name = 'getpid')) then
        begin
          // getpid() -> int64: returns process ID
          // Use generic external call (like user-defined extern functions)
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := 'getpid';
          instr.ImmInt := 0; // argCount
          instr.CallMode := cmExternal;
          SetLength(instr.ArgTemps, 0);
          Emit(instr);
          Result := t0;
        end
        // === std.io: fd-basierte I/O Syscalls (v0.3.1) ===
        else if (call.Name = 'open') or
                ((call.Namespace = 'IO') and (call.Name = 'open')) then
        begin
          // open(path: pchar, flags: int64, mode: int64) -> int64 (fd or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'open';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'read') or (call.Name = 'read_raw') or
                ((call.Namespace = 'IO') and ((call.Name = 'read') or (call.Name = 'read_raw'))) then
        begin
          // read/read_raw(fd: int64, buf: pchar/int64, count: int64) -> int64 (bytes read or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'read';  // Both use the same syscall
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'write') or
                ((call.Namespace = 'IO') and (call.Name = 'write')) then
        begin
          // write(fd: int64, buf: pchar, count: int64) -> int64 (bytes written or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'write';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'close') or
                ((call.Namespace = 'IO') and (call.Name = 'close')) then
        begin
          // close(fd: int64) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'close';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'lseek') or
                ((call.Namespace = 'IO') and (call.Name = 'lseek')) then
        begin
          // lseek(fd: int64, offset: int64, whence: int64) -> int64
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'lseek';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'unlink') or
                ((call.Namespace = 'IO') and (call.Name = 'unlink')) then
        begin
          // unlink(path: pchar) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'unlink';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
          else if (call.Name = 'rename') or
                  ((call.Namespace = 'IO') and (call.Name = 'rename')) then
          begin
            // rename(oldpath: pchar, newpath: pchar) -> int64 (0 or -1)
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'rename';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: syscall_sys_open(path, len, flags, mode) -> fd
          // Map to open(path, flags, mode) ignoring the length argument
          else if call.Name = 'syscall_sys_open' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'open';
            // Pass 3 args: path (arg0), flags (arg2), mode (arg3), skip len (arg1)
            SetLength(instr.ArgTemps, 3);
            if argCount >= 1 then instr.ArgTemps[0] := argTemps[0] else instr.ArgTemps[0] := -1;  // path
            if argCount >= 3 then instr.ArgTemps[1] := argTemps[2] else instr.ArgTemps[1] := -1;  // flags
            if argCount >= 4 then instr.ArgTemps[2] := argTemps[3] else instr.ArgTemps[2] := -1;  // mode
            instr.ImmInt := 3;
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 3 then instr.Src2 := argTemps[2] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: syscall_sys_write(fd, buf, len) -> bytes written
          else if call.Name = 'syscall_sys_write' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'write';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: syscall_sys_close(fd)
          else if call.Name = 'syscall_sys_close' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'close';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_close(fd: int64) -> int64 (direct syscall, not external)
          else if call.Name = 'sys_close' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'close';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_read(fd: int64, buf: Pointer, count: int64) -> int64 (direct syscall)
          else if call.Name = 'sys_read' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'read';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_write(fd: int64, buf: Pointer, count: int64) -> int64 (direct syscall)
          else if call.Name = 'sys_write' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'write';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_fork() -> int64
          else if call.Name = 'sys_fork' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'fork';
            instr.ImmInt := 0;
            SetLength(instr.ArgTemps, 0);
            Emit(instr);
            Result := t0;
          end
          // sys_execve(path: pchar, argv: int64, envp: int64) -> int64
          else if call.Name = 'sys_execve' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'execve';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_wait4(pid: int64, status: int64, options: int64) -> int64
          else if call.Name = 'sys_wait4' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'wait4';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_select/nfds: int64, readfds: Pointer, writefds: Pointer, exceptfds: Pointer, timeout: Pointer) -> int64 (direct syscall)
          else if call.Name = 'sys_select' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'sys_select';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // sys_poll(fds: Pointer, nfds: int64, timeout: int64) -> int64 (direct syscall)
          else if call.Name = 'sys_poll' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'sys_poll';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'peek8') then
          begin
            // peek8(addr: int64) -> int64 (byte value)
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek8';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke8') then
          begin
            // poke8(addr: int64, value: int64) -> void
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke8';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peek16') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek16';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke16') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke16';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peek32') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek32';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke32') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke32';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
          else if (call.Name = 'peek64') then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'peek64';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if (call.Name = 'poke64') then
          begin
            instr.Op := irCallBuiltin;
            instr.Dest := -1;
            instr.ImmStr := 'poke64';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := -1;
          end
        else if (call.Name = 'mkdir') or
                ((call.Namespace = 'IO') and (call.Name = 'mkdir')) then
        begin
          // mkdir(path: pchar, mode: int64) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'mkdir';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if (call.Name = 'rmdir') or
                ((call.Namespace = 'IO') and (call.Name = 'rmdir')) then
        begin
          // rmdir(path: pchar) -> int64 (0 or -1)
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'rmdir';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
         else if (call.Name = 'chmod') or
                 ((call.Namespace = 'IO') and (call.Name = 'chmod')) then
         begin
           // chmod(path: pchar, mode: int64) -> int64 (0 or -1)
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'chmod';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         // === Socket System Calls (for std.net) ===
         else if call.Name = 'sys_socket' then
         begin
           // sys_socket(domain: int64, type: int64, protocol: int64) -> int64
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_socket';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_bind' then
         begin
           // sys_bind(sockfd, addr, addrlen) -> int64
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_bind';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_listen' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_listen';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_accept' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_accept';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_connect' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_connect';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_recvfrom' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_recvfrom';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_sendto' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_sendto';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_setsockopt' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_setsockopt';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_getsockopt' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_getsockopt';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_fcntl' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_fcntl';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
           Emit(instr);
           Result := t0;
         end
         else if call.Name = 'sys_shutdown' then
         begin
           t0 := NewTemp;
           instr.Op := irCallBuiltin;
           instr.Dest := t0;
           instr.ImmStr := 'sys_shutdown';
           instr.ImmInt := argCount;
           SetLength(instr.ArgTemps, argCount);
           for i := 0 to argCount - 1 do
             instr.ArgTemps[i] := argTemps[i];
           if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: alloc(size) = mmap(0, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
          else if call.Name = 'alloc' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'alloc';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // Bootstrap compat: ArgvGet(argv, i) = *(argv + i*8)
          else if call.Name = 'ArgvGet' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'ArgvGet';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // === mmap/munmap for memory allocation ===
          else if call.Name = 'mmap' then
          begin
            // mmap(addr, length, prot, flags, fd, offset) -> int64 (pointer)
            // Bootstrap compat: mmap(size, prot) mit 2 Argumenten
            // - mmap(size, prot) -> mmap(0, size, prot, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'mmap';
            instr.ImmInt := argCount;
            // Expand to 6 arguments for the backend
            SetLength(instr.ArgTemps, 6);
            
            if argCount = 2 then
            begin
              // Bootstrap 2-arg mode: mmap(size, prot)
              // Der Bootstrap verwendet: mmap(size, prot)
              // Map to full 6-arg: mmap(0, size, prot, 34, -1, 0)
              // WICHTIG: argTemps[0] = erstes Argument (size), argTemps[1] = zweites Argument (prot)
              // WIR MÜSSEN SIE TAUSCHEN: size ist length, prot ist prot
              instr.ArgTemps[0] := 0;                       // addr = NULL
              instr.ArgTemps[1] := argTemps[0];             // length = size (erstes Argument)
              instr.ArgTemps[2] := argTemps[1];             // prot (zweites Argument)
              instr.ArgTemps[3] := 34;                      // flags = MAP_PRIVATE | MAP_ANONYMOUS
              instr.ArgTemps[4] := -1;                      // fd = -1
              instr.ArgTemps[5] := 0;                       // offset = 0
            end
            else if argCount >= 3 then
            begin
              // Full 3+ arg mode - use provided values
              // arg[0]=addr, arg[1]=length, arg[2]=prot, arg[3]=flags, arg[4]=fd, arg[5]=offset
              for i := 0 to argCount - 1 do
              begin
                if i < 6 then instr.ArgTemps[i] := argTemps[i];
              end;
              // Fill remaining with defaults
              for i := argCount to 5 do
                instr.ArgTemps[i] := 0;
            end
            else if argCount = 1 then
            begin
              // mmap(size) -> mmap(0, size, 3, 34, -1, 0)
              instr.ArgTemps[0] := 0;                      // addr
              instr.ArgTemps[1] := argTemps[0];            // length = size
              instr.ArgTemps[2] := 3;                     // prot = READ|WRITE
              instr.ArgTemps[3] := 34;                     // flags
              instr.ArgTemps[4] := -1;                     // fd
              instr.ArgTemps[5] := 0;                      // offset
            end
            else
            begin
              // No arguments - all zeros
              for i := 0 to 5 do
                instr.ArgTemps[i] := 0;
            end;
            if Length(instr.ArgTemps) >= 1 then instr.Src1 := instr.ArgTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          else if call.Name = 'munmap' then
          begin
            // munmap(addr, length) -> int64
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'munmap';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            Emit(instr);
            Result := t0;
          end
          // write_raw(fd, buf, len) -> int64
          else if call.Name = 'write_raw' then
          begin
            t0 := NewTemp;
            instr.Op := irCallBuiltin;
            instr.Dest := t0;
            instr.ImmStr := 'write_raw';
            instr.ImmInt := argCount;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
            if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
            Emit(instr);
            Result := t0;
          end
          // Buffer/primitive calls
          else if call.Name = 'buf_put_byte' then
        begin
          // buf_put_byte(buf: int64, idx: int64, b: int64) -> int64
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'buf_put_byte';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          // 3. Argument via LabelName übergeben
          if argCount >= 3 then
            instr.LabelName := IntToStr(argTemps[2]);
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'buf_get_byte' then
        begin
          // buf_get_byte(buf: int64, idx: int64) -> int64
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'buf_get_byte';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        // === Dynamic growable strings (F2) ===
        else if call.Name = 'StrLen' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrLen';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrCharAt' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrCharAt';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrSetChar' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrSetChar';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrNew' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrNew';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrFree' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrFree';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrAppend' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrAppend';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          if argCount >= 2 then instr.Src2 := argTemps[1] else instr.Src2 := -1;
          Emit(instr);
          Result := t0;
        end
        else if call.Name = 'StrFromInt' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin;
          instr.Dest := t0;
          instr.ImmStr := 'StrFromInt';
          instr.ImmInt := argCount;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr);
          Result := t0;
        end
        // S1: String split primitives
        else if call.Name = 'StrFindChar' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrFindChar';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrSub' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrSub';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S2: StringBuilder
        else if call.Name = 'StrAppendStr' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrAppendStr';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrConcat' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrConcat';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrCopy' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrCopy';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S3: IntToStr alias
        else if call.Name = 'IntToStr' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrFromInt';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S4: FileGetSize
        else if call.Name = 'FileGetSize' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'FileGetSize';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S5: HashMap
        else if call.Name = 'HashNew' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'HashNew';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'HashSet' then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'HashSet';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        else if call.Name = 'HashGet' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'HashGet';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'HashHas' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'HashHas';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S6: Argv access
        else if call.Name = 'GetArgC' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'GetArgC';
          instr.ImmInt := 0; SetLength(instr.ArgTemps, 0);
          instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'GetArg' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'GetArg';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'GetArgV' then
        begin
          // GetArgV(): pchar — returns pointer to argv[0] (raw C argv array)
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'GetArgV';
          instr.ImmInt := 0; SetLength(instr.ArgTemps, 0);
          instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // S7: String comparison
        else if call.Name = 'StrStartsWith' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrStartsWith';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrEndsWith' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrEndsWith';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        else if call.Name = 'StrEquals' then
        begin
          t0 := NewTemp;
          instr.Op := irCallBuiltin; instr.Dest := t0; instr.ImmStr := 'StrEquals';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := t0;
        end
        // profile_enter(fn_name) - Profiler function entry (WP-3)
        else if ((call.Namespace = 'Profile') and (call.Name = 'enter')) or
              (call.Name = 'profile_enter') then
        begin
          // If using global name, handle same as Profile.enter
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'profile_enter';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // profile_leave(fn_name) - Profiler function leave (WP-3)
        else if ((call.Namespace = 'Profile') and (call.Name = 'leave')) or
              (call.Name = 'profile_leave') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'profile_leave';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // profile_report() - Print profile report (WP-3)
        else if ((call.Namespace = 'Profile') and (call.Name = 'report')) or
              (call.Name = 'profile_report') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'profile_report';
          instr.ImmInt := 0;
          Emit(instr); Result := -1;
        end
        // trace(msg: pchar) - Trace output (WP-4)
        else if (call.Name = 'trace') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'trace';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // trace_int(val: int64) - Trace integer (WP-4)
        else if (call.Name = 'trace_int') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'trace_int';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // trace_str(label: pchar, val: pchar) - Trace string (WP-4)
        else if (call.Name = 'trace_str') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'trace_str';
          instr.ImmInt := argCount; SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do instr.ArgTemps[i] := argTemps[i];
          if argCount >= 1 then instr.Src1 := argTemps[0] else instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        // breakpoint() - Debugger breakpoint (WP-5)
        else if (call.Name = 'breakpoint') then
        begin
          instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'breakpoint';
          instr.ImmInt := 0; SetLength(instr.ArgTemps, 0);
          instr.Src1 := -1;
          Emit(instr); Result := -1;
        end
        else if ((call.Name = 'VerifyIntegrity') or
                 ((call.Namespace = 'Integrity') and (call.Name = 'VerifyIntegrity'))) then
        begin
          // Integrity.VerifyIntegrity() -> bool (aerospace-todo P0 #45)
          // Returns true if code integrity is verified (CRC32 match with .meta_safe section)
          t0 := NewTemp;
          instr.Op := irVerifyIntegrity;
          instr.Dest := t0;
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'RegexMatch') or
                 ((call.Namespace = 'Regex') and (call.Name = 'Match'))) then
        begin
          useCompiled := (argCount >= 2) and (call.Args[0] is TAstRegexLit) and
            TAstRegexLit(call.Args[0]).HasCompiled;
          if useCompiled then
          begin
            regexLit := TAstRegexLit(call.Args[0]);
            strIdx := FModule.InternString(regexLit.CompiledProgram);
            compiledTemp := NewTemp;
            instr.Op := irConstStr;
            instr.Dest := compiledTemp;
            instr.ImmStr := IntToStr(strIdx);
            Emit(instr);
            lenTemp := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := lenTemp;
            instr.ImmInt := regexLit.CompiledLen;
            Emit(instr);
            callName := 'RegexMatchCompiled';
            SetLength(callTemps, 3);
            callTemps[0] := compiledTemp;
            callTemps[1] := lenTemp;
            callTemps[2] := argTemps[1];
          end
          else
          begin
            callName := 'RegexMatch';
            callTemps := argTemps;
          end;
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := callName;
          instr.ImmInt := Length(callTemps);
          // Determine call mode
          // cmExternal has highest priority, then cmImported (must check before
          // FModule.FindFunction because imported functions get added to FModule
          // when compiled, and we must not treat them as cmInternal).
          if FExternFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmImported
          else
          begin
            fn := FModule.FindFunction(callName);
            if Assigned(fn) then
            begin
              if fn.NeedsStaticLink then
                instr.CallMode := cmStaticLink
              else
                instr.CallMode := cmInternal;
            end
            else
              instr.CallMode := cmInternal;
          end;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'RegexSearch') or
                 ((call.Namespace = 'Regex') and (call.Name = 'Search'))) then
        begin
          useCompiled := (argCount >= 2) and (call.Args[0] is TAstRegexLit) and
            TAstRegexLit(call.Args[0]).HasCompiled;
          if useCompiled then
          begin
            regexLit := TAstRegexLit(call.Args[0]);
            strIdx := FModule.InternString(regexLit.CompiledProgram);
            compiledTemp := NewTemp;
            instr.Op := irConstStr;
            instr.Dest := compiledTemp;
            instr.ImmStr := IntToStr(strIdx);
            Emit(instr);
            lenTemp := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := lenTemp;
            instr.ImmInt := regexLit.CompiledLen;
            Emit(instr);
            callName := 'RegexSearchCompiled';
            SetLength(callTemps, 3);
            callTemps[0] := compiledTemp;
            callTemps[1] := lenTemp;
            callTemps[2] := argTemps[1];
          end
          else
          begin
            callName := 'RegexSearch';
            callTemps := argTemps;
          end;
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := callName;
          instr.ImmInt := Length(callTemps);
          // Determine call mode: check if function is defined locally first
          fn := FModule.FindFunction(callName);
          if Assigned(fn) then
            instr.CallMode := cmInternal
          else if FExternFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmImported
          else
            instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
        end
        else if ((call.Name = 'RegexReplace') or
                 ((call.Namespace = 'Regex') and (call.Name = 'Replace'))) then
        begin
          useCompiled := (argCount >= 3) and (call.Args[0] is TAstRegexLit) and
            TAstRegexLit(call.Args[0]).HasCompiled;
          if useCompiled then
          begin
            regexLit := TAstRegexLit(call.Args[0]);
            strIdx := FModule.InternString(regexLit.CompiledProgram);
            compiledTemp := NewTemp;
            instr.Op := irConstStr;
            instr.Dest := compiledTemp;
            instr.ImmStr := IntToStr(strIdx);
            Emit(instr);
            lenTemp := NewTemp;
            instr.Op := irConstInt;
            instr.Dest := lenTemp;
            instr.ImmInt := regexLit.CompiledLen;
            Emit(instr);
            callName := 'RegexReplaceCompiled';
            SetLength(callTemps, 4);
            callTemps[0] := compiledTemp;
            callTemps[1] := lenTemp;
            callTemps[2] := argTemps[1];
            callTemps[3] := argTemps[2];
          end
          else
          begin
            callName := 'RegexReplace';
            callTemps := argTemps;
          end;
          t0 := NewTemp;
          instr.Op := irCall;
          instr.Dest := t0;
          instr.ImmStr := callName;
          instr.ImmInt := Length(callTemps);
          // Determine call mode: check if function is defined locally first
          fn := FModule.FindFunction(callName);
          if Assigned(fn) then
            instr.CallMode := cmInternal
          else if FExternFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(callName) >= 0 then
            instr.CallMode := cmImported
          else
            instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
        end
        else
        begin
          // Handle unprocessed namespace method calls: obj.method(args)
          // This occurs in imported class method bodies where sema didn't run.
          // The parser generates call.Namespace = "self" (or another var), call.Name = "method".
          if call.Namespace <> '' then
          begin
            loc := ResolveLocal(call.Namespace);
            if loc >= 0 then
            begin
              // Determine class type of the receiver
              mangled := '';
              if (call.Namespace = 'self') and Assigned(FCurrentClassDecl) then
                mangled := '_L_' + FCurrentClassDecl.Name + '_' + call.Name
              else if (loc < Length(FLocalTypeNames)) and (FLocalTypeNames[loc] <> '') then
                mangled := '_L_' + FLocalTypeNames[loc] + '_' + call.Name;
              if mangled <> '' then
              begin
                // Load receiver
                t1 := NewTemp;
                instr.Op := irLoadLocal;
                instr.Dest := t1;
                instr.Src1 := loc;
                Emit(instr);
                // Emit: _L_ClassName_MethodName(receiver, arg1, arg2, ...)
                t0 := NewTemp;
                instr.Op := irCall;
                instr.Dest := t0;
                instr.ImmStr := mangled;
                instr.ImmInt := argCount + 1;
                instr.IsVirtualCall := False;
                instr.VMTIndex := -1;
                instr.SelfSlot := -1;
                instr.CallMode := cmInternal;
                SetLength(instr.ArgTemps, argCount + 1);
                instr.ArgTemps[0] := t1;
                for i := 0 to argCount - 1 do
                  instr.ArgTemps[i + 1] := argTemps[i];
                Emit(instr);
                Result := t0;
                Exit;
              end;
            end;
          end;

          // === Dynamic Array Operations (push, len, pop, free) ===
          // These must come BEFORE the regular function call handling
          if call.Name = 'push' then
          begin
            // push(array, value) - adds element to dynamic array
            // argTemps[0] = array local slot, argTemps[1] = value
            instr := Default(TIRInstr);
            instr.Op := irDynArrayPush;
            instr.Src1 := argTemps[0];  // array local slot (fat pointer)
            instr.Src2 := argTemps[1];  // value to push
            instr.Dest := -1;
            Emit(instr);
            Result := -1;
            Exit;
          end
          else if call.Name = 'len' then
          begin
            // len(array) - returns length of dynamic array
            // argTemps[0] = array local slot
            t0 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irDynArrayLen;
            instr.Src1 := argTemps[0];  // array local slot (fat pointer)
            instr.Dest := t0;
            Emit(instr);
            Result := t0;
            Exit;
          end
          else if call.Name = 'pop' then
          begin
            // pop(array) - removes and returns last element
            // argTemps[0] = array local slot
            t0 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irDynArrayPop;
            instr.Src1 := argTemps[0];  // array local slot (fat pointer)
            instr.Dest := t0;
            Emit(instr);
            Result := t0;
            Exit;
          end
          else if call.Name = 'free' then
          begin
            // free(array) - frees the dynamic array memory
            // argTemps[0] = array local slot
            instr := Default(TIRInstr);
            instr.Op := irDynArrayFree;
            instr.Src1 := argTemps[0];  // array local slot (fat pointer)
            instr.Dest := -1;
            Emit(instr);
            Result := -1;
            Exit;
          end;

          // Regular function call (or function pointer call)
          t0 := NewTemp;

          // Check if this is a function pointer call (indirect call)
          if call.IsIndirectCall then
          begin
            // This is an indirect call via function pointer
            // First, load the function pointer value (the variable name is in call.Name)
            // We need to resolve the variable and load its value
            
            // Load the function pointer value from the variable
            // call.Name contains the variable name (e.g., "cb")
            instr := Default(TIRInstr);
            instr.Op := irLoadLocal;  // Load the function pointer value
            instr.Dest := t0;
            instr.Src1 := ResolveLocal(call.Name);  // local slot index
            if instr.Src1 < 0 then
            begin
              // Try as global variable
              instr.Op := irLoadGlobal;
              instr.Src1 := -1;
              instr.ImmStr := call.Name;
            end;
            Emit(instr);
            
            // Now emit indirect call using the loaded function pointer
            instr := Default(TIRInstr);
            instr.Op := irVarCall;
            instr.Dest := t0;
            instr.Src1 := t0;  // Use the loaded function pointer as the call target
            instr.ImmInt := argCount;
            instr.IsVirtualCall := False;
            instr.VMTIndex := -1;
            instr.SelfSlot := -1;
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            Emit(instr);
            Result := t0;
          end
          else
          begin
            // Regular direct function call
            instr.Op := irCall;
            instr.Dest := t0;
            instr.ImmStr := call.Name;
            instr.ImmInt := argCount;
            callName := call.Name; // for call mode determination
            instr.IsVirtualCall := False;
            instr.VMTIndex := -1;
            instr.SelfSlot := -1;
           
            // Check if this is a method call (mangled name starts with _L_ or _METHOD_)
            if (Length(call.Name) > 3) and ((Copy(call.Name, 1, 3) = '_L_') or (Copy(call.Name, 1, 8) = '_METHOD_')) then
            begin
              // For _METHOD_<methodname>: extract method name and look up class from first argument's type
              // For _L_<ClassName>_<MethodName>: extract class name and method name from mangled name
              if Copy(call.Name, 1, 8) = '_METHOD_' then
              begin
                // Format: _METHOD_<methodname>
                // Need to look up class from receiver type (call.Args[0])
                vmtMethodName := Copy(call.Name, 9, MaxInt);
                vmtClassName := '';
                
                // Get receiver's type from semantic analysis
                if (argCount >= 1) and Assigned(call.Args) and Assigned(call.Args[0]) then
                begin
                  recvExpr := call.Args[0];

                  // Try to get the variable name from Ident node
                  if recvExpr is TAstIdent then
                  begin
                    // Look up the local slot by name
                    loc := ResolveLocal(TAstIdent(recvExpr).Name);
                    if loc >= 0 then
                    begin
                      // Check FLocalTypeNames for class types
                      if (loc < Length(FLocalTypeNames)) and (FLocalTypeNames[loc] <> '') then
                        vmtClassName := FLocalTypeNames[loc];
                    end;
                  end;
                end;
              end
              else
              begin
                // Format: _L_ClassName_methodName
                posIdx := Pos('_', Copy(call.Name, 4, MaxInt));
                if posIdx > 0 then
                begin
                  vmtClassName := Copy(call.Name, 4, posIdx - 1);
                  vmtMethodName := Copy(call.Name, 4 + posIdx, MaxInt);
                  
                  // Also need to find the receiver's slot for SelfSlot
                  // The receiver is in call.Args[0]
                  if (argCount >= 1) and Assigned(call.Args) and Assigned(call.Args[0]) then
                  begin
                    recvExpr := call.Args[0];
                    if recvExpr is TAstIdent then
                    begin
                      loc := ResolveLocal(TAstIdent(recvExpr).Name);
                    end;
                  end;
                end;
              end;
              
              // Look up class in FClassTypes if we have a class name
              if vmtClassName <> '' then
              begin
                classIdx := FClassTypes.IndexOf(vmtClassName);
                if classIdx >= 0 then
                begin
                  cd := TAstClassDecl(FClassTypes.Objects[classIdx]);
                  // First check if class has virtual methods (VMT exists)
                  if Length(cd.VirtualMethods) > 0 then
                  begin
                    // Look for method in VirtualMethods list (has correct VMT indices)
                    for vmtIdx := 0 to High(cd.VirtualMethods) do
                    begin
                      if Assigned(cd.VirtualMethods[vmtIdx]) and
                         (cd.VirtualMethods[vmtIdx].Name = vmtMethodName) then
                      begin
                        // This is a virtual call - method is in VMT
                        instr.IsVirtualCall := True;
                        instr.VMTIndex := vmtIdx;
                        // Store the local slot for self
                        instr.SelfSlot := loc;
                        Break;
                      end;
                    end;
                  end;

                  // Fallback: also check in Methods list (for non-virtual methods)
                  if not instr.IsVirtualCall then
                  begin
                    for methodIdx := 0 to High(cd.Methods) do
                    begin
                      if cd.Methods[methodIdx].Name = vmtMethodName then
                      begin
                        // Check if method is explicitly virtual
                        if cd.Methods[methodIdx].IsVirtual then
                        begin
                          instr.IsVirtualCall := True;
                          instr.VMTIndex := cd.Methods[methodIdx].VirtualTableIndex;
                          // Store the local slot for self
                          instr.SelfSlot := loc;
                        end;
                        Break;
                      end;
                    end;
                  end;
                end;
              end;
            end;
          
          // Bootstrap compat: for _METHOD_ calls that are NOT virtual, translate the call
          // name to _L_ClassName_MethodName so the jump patcher can resolve it.
          if (Copy(call.Name, 1, 8) = '_METHOD_') and (not instr.IsVirtualCall) and (vmtClassName <> '') then
            instr.ImmStr := '_L_' + vmtClassName + '_' + vmtMethodName;

          // Determine call mode based on function origin
          // cmExternal has highest priority, then cmImported (must check before
          // FModule.FindFunction because imported functions get added to FModule
          // when compiled, and we must not treat them as cmInternal).
          if FExternFuncs.IndexOf(call.Name) >= 0 then
            instr.CallMode := cmExternal
          else if FImportedFuncs.IndexOf(call.Name) >= 0 then
            instr.CallMode := cmImported
          else
          begin
            fn := FModule.FindFunction(call.Name);
            if Assigned(fn) then
            begin
              if fn.NeedsStaticLink then
                instr.CallMode := cmStaticLink
              else
                instr.CallMode := cmInternal;
            end
            else
              instr.CallMode := cmInternal;
          end;
          // For regular calls, callTemps is never set above — use argTemps directly
          if Length(callTemps) = 0 then
            callTemps := argTemps;
          SetLength(instr.ArgTemps, Length(callTemps));
          for i := 0 to High(callTemps) do
            instr.ArgTemps[i] := callTemps[i];
          Emit(instr);
          Result := t0;
          end;
        end;
      end;

    nkIndexAccess:
      begin
        // Check if this is a Map access (map[key])
        if TAstIndexAccess(expr).Obj.ResolvedType = atMap then
        begin
          // Map access: map[key] -> irMapGet(map, key)
          // Lower the map (object)
          t1 := LowerExpr(TAstIndexAccess(expr).Obj);
          if t1 < 0 then Exit;

          // Lower the key
          t2 := LowerExpr(TAstIndexAccess(expr).Index);
          if t2 < 0 then Exit;

          // Emit map_get
          t0 := NewTemp;
          instr.Op := irMapGet;
          instr.Dest := t0;
          instr.Src1 := t1;  // map
          instr.Src2 := t2;  // key
          Emit(instr);
          Result := t0;
          Exit;
        end;

        // Check if this is a Set access (not supported - sets are not indexable)
        if TAstIndexAccess(expr).Obj.ResolvedType = atSet then
        begin
          FDiag.Error('sets are not indexable, use "in" operator to check membership', expr.Span);
          Exit;
        end;

        // Regular array access
        // Check if accessing a global array
        if (TAstIndexAccess(expr).Obj is TAstIdent) and
           IsGlobalVar(TAstIdent(TAstIndexAccess(expr).Obj).Name) then
        begin
          // For global arrays: load the ADDRESS, not the value
          // This is needed because irLoadElem expects a base address
          t0 := NewTemp;
          instr.Op := irLoadGlobalAddr;
          instr.Dest := t0;
          instr.ImmStr := TAstIdent(TAstIndexAccess(expr).Obj).Name;
          Emit(instr);
          t1 := t0;  // t1 now holds the base address

           // Lower index
           t2 := LowerExpr(TAstIndexAccess(expr).Index);
           if t2 < 0 then
             Exit;

           // If global array has known static length, emit bounds check
           gv := GetGlobalVarDecl(TAstIdent(TAstIndexAccess(expr).Obj).Name);
           if Assigned(gv) and (gv.ArrayLen > 0) then
           begin
             tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
             tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := gv.ArrayLen; Emit(instr);
             tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
             tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
             tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
             errLbl := NewLabel('Larr_oob');
             instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);
           end;

            // Load element at index
            t0 := NewTemp;
            instr.Op := irLoadElem;
            instr.Dest := t0;
            instr.Src1 := t1;  // array base address
            instr.Src2 := t2;  // index
            Emit(instr);
            Result := t0;

            // Emit error handler if needed
            if Assigned(gv) and (gv.ArrayLen > 0) then
            begin
              // Skip over error handler after successful load
              skipLbl := NewLabel('Larr_ok');
              instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
              instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
              msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
              instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
              codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
              instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
              instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
           end;
        end
        else
        begin
          // Local array: need to load ADDRESS of array base, not value
          if TAstIndexAccess(expr).Obj is TAstIdent then
          begin
            loc := ResolveLocal(TAstIdent(TAstIndexAccess(expr).Obj).Name);
            if loc >= 0 then
            begin
              // Check if this is a dynamic array (fat-pointer)
              arrLen := GetLocalArrayLen(loc);
              if (loc < Length(FLocalIsDynArray)) and FLocalIsDynArray[loc] then
              begin
                // Dynamic array: ptr is stored in slot loc, load it as base address
                t1 := NewTemp;
                instr.Op := irLoadLocal;
                instr.Dest := t1;
                instr.Src1 := loc;  // load ptr from fat-pointer slot 0
                Emit(instr);

                // Lower index
                t2 := LowerExpr(TAstIndexAccess(expr).Index);
                if t2 < 0 then
                  Exit;

                // Runtime bounds check against len (slot loc+1)
                tLen := NewTemp;
                instr.Op := irLoadLocal; instr.Dest := tLen; instr.Src1 := loc + 1; Emit(instr);
                tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
                tGe0 := NewTemp; instr.Op := irCmpGe; instr.Dest := tGe0; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
                tLtLen := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
                tOk := NewTemp; instr.Op := irAnd; instr.Dest := tOk; instr.Src1 := tGe0; instr.Src2 := tLtLen; Emit(instr);
                errLbl := NewLabel('Larr_oob');
                instr.Op := irBrFalse; instr.Src1 := tOk; instr.LabelName := errLbl; Emit(instr);

                t0 := NewTemp;
                instr.Op := irLoadElem;
                instr.Dest := t0;
                instr.Src1 := t1;  // heap pointer (array data)
                instr.Src2 := t2;  // index
                Emit(instr);
                Result := t0;

                // Skip over error handler
                skipLbl := NewLabel('Larr_ok');
                instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);

                // Error handler
                instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
                msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
                instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
                codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
                instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
                instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
                Exit;
              end;

              // For local arrays, elements are stored in REVERSE order:
              // arr[0] at slot loc + arrLen - 1, arr[1] at slot loc + arrLen - 2, etc.
              // This is because stack grows downward and we want arr[index] = base + index*8
              arrLen := GetLocalArrayLen(loc);
              if arrLen > 0 then
                baseSlot := loc + arrLen - 1  // arr[0] at highest slot
              else
                baseSlot := loc;  // fallback for non-array locals
              
              t1 := NewTemp;
              instr.Op := irLoadLocalAddr;
              instr.Dest := t1;
              instr.Src1 := baseSlot;
              Emit(instr);
              
                // Lower index
                t2 := LowerExpr(TAstIndexAccess(expr).Index);
                if t2 < 0 then
                  Exit;

                // If local array has known static length, emit bounds check
                // Using CmpGe: if index >= length, jump to error
                // CmpGe gives 1 when index >= length (invalid), 0 when index < length (valid)
                // BrTrue jumps when value is 1 (invalid), so BrTrue CmpGe jumps on invalid index
                if arrLen > 0 then
                begin
                  errLbl := NewLabel('Larr_oob');
                  // tLen = length (constant)
                  tLen := NewTemp;
                  instr.Op := irConstInt;
                  instr.Dest := tLen;
                  instr.ImmInt := arrLen;
                  Emit(instr);
                  
                  // tOk = (index >= tLen) ? 1 : 0
                  tOk := NewTemp;
                  instr.Op := irCmpGe;
                  instr.Dest := tOk;
                  instr.Src1 := t2;  // index
                  instr.Src2 := tLen;  // length
                  Emit(instr);
                  
                // If tOk == 1 (index >= length, invalid), jump to error
                   instr.Op := irBrTrue;
                   instr.Src1 := tOk;
                   instr.LabelName := errLbl;
                   Emit(instr);
                end;

                t0 := NewTemp;
                instr.Op := irLoadElem;
                instr.Dest := t0;
                instr.Src1 := t1;  // array base address
                instr.Src2 := t2;  // index
                instr.LabelName := '';  // Clear any residual label
                Emit(instr);
                Result := t0;

                if arrLen > 0 then
                begin
                  skipLbl := NewLabel('Larr_ok');
                  instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
                  instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
                  msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
                  instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
                  codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
                  instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
                  instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
                end;
               Exit;
            end;
          end;
          
          // Fallback: use normal LowerExpr for base (for other expression types)
          t1 := LowerExpr(TAstIndexAccess(expr).Obj);
          t2 := LowerExpr(TAstIndexAccess(expr).Index);
          if (t1 < 0) or (t2 < 0) then
            Exit;

          t0 := NewTemp;
          instr.Op := irLoadElem;
          instr.Dest := t0;
          instr.Src1 := t1;  // array base
          instr.Src2 := t2;  // index
          // Check if this is pchar indexing (byte access)
          if (TAstIndexAccess(expr).Obj.ResolvedType = atPChar) or
             (TAstIndexAccess(expr).Obj.ResolvedType = atPCharNullable) then
            instr.ImmInt := 1  // element size = 1 byte for pchar
          else
            instr.ImmInt := 8;  // element size = 8 bytes for int64 arrays
          Emit(instr);
          Result := t0;
        end;
      end;

    nkCast:
      begin
        // Type cast: expr as Type
        // First lower the expression
        t1 := LowerExpr(TAstCast(expr).Expr);
        if t1 < 0 then
          Exit;

        // Get source and target types
        ltype := TAstCast(expr).Expr.ResolvedType;
        rType := TAstCast(expr).CastType;
        castTypeName := TAstCast(expr).CastTypeName;

        t0 := NewTemp;

        // Check for class cast (target is a class name)
        if (castTypeName <> '') and (FClassTypes.IndexOf(castTypeName) >= 0) then
        begin
          // Class cast is a no-op in IR (just a type annotation / pointer reinterpret).
          Result := t1;
          Exit;
        end
        // Check for int64 -> float conversion
        else if (ltype = atInt64) and (rType = atF64) then
        begin
          instr.Op := irIToF;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        // Check for float -> int64 conversion
        else if (ltype = atF64) and (rType = atInt64) then
        begin
          instr.Op := irFToI;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        // Check for function pointer to int64 (function address cast)
        else if TAstCast(expr).IsFunctionToPointer then
        begin
          // This is a cast from function to int64 - return the function address
          // The expression could be a function call or a function name (identifier)
          
          // Check if the source expression is a function identifier (not a call)
          if TAstCast(expr).Expr is TAstIdent then
          begin
            // Function name cast to int64 - load the function address
            // Use irLoadGlobalAddr to get the function address
            instr := Default(TIRInstr);
            instr.Op := irLoadGlobalAddr;
            instr.Dest := t0;
            instr.ImmStr := TAstIdent(TAstCast(expr).Expr).Name;
            Emit(instr);
          end
          else
          begin
            // For other expressions (like function calls), just copy the value
            // This is a workaround - proper handling would require more changes
            instr.Op := irLoadLocal;
            instr.Dest := t0;
            instr.Src1 := t1;
            Emit(instr);
          end;
        end
        // Check for int64 -> uint8 (truncate to 8 bits)
        else if (ltype = atInt64) and (rType = atUInt8) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 8;  // Truncate to 8 bits
          Emit(instr);
        end
        // Check for int64 -> uint16 (truncate to 16 bits)
        else if (ltype = atInt64) and (rType = atUInt16) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 16;  // Truncate to 16 bits
          Emit(instr);
        end
        // Check for int64 -> uint32 (truncate to 32 bits)
        else if (ltype = atInt64) and (rType = atUInt32) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 32;  // Truncate to 32 bits
          Emit(instr);
        end
        // Check for int64 -> int8 (truncate to 8 bits with sign extension)
        else if (ltype = atInt64) and (rType = atInt8) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 8;  // Truncate to 8 bits
          Emit(instr);
          // Sign-extend from 8 bits to 64 bits (t0 = sign-extended result)
          instr.Op := irSExt;
          instr.Dest := t0;  // Reuse t0 for sign-extended result
          instr.Src1 := t0;  // Sign-extend the truncated value
          instr.ImmInt := 64;  // Extend to full 64-bit
          Emit(instr);
        end
        // Check for int64 -> int16 (truncate to 16 bits with sign extension)
        else if (ltype = atInt64) and (rType = atInt16) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 16;  // Truncate to 16 bits
          Emit(instr);
          // Sign-extend from 16 bits to 64 bits
          instr.Op := irSExt;
          instr.Dest := t0;
          instr.Src1 := t0;
          instr.ImmInt := 64;
          Emit(instr);
        end
        // Check for int64 -> int32 (truncate to 32 bits with sign extension)
        else if (ltype = atInt64) and (rType = atInt32) then
        begin
          instr.Op := irTrunc;
          instr.Dest := t0;
          instr.Src1 := t1;
          instr.ImmInt := 32;  // Truncate to 32 bits
          Emit(instr);
          // Sign-extend from 32 bits to 64 bits
          instr.Op := irSExt;
          instr.Dest := t0;
          instr.Src1 := t0;
          instr.ImmInt := 64;
          Emit(instr);
        end
        // Check for unsigned -> int64 (no conversion needed, just zero-extend conceptually)
        else if (rType = atInt64) and (ltype in [atUInt8, atUInt16, atUInt32, atUInt64]) then
        begin
          // No conversion needed for unsigned -> signed int64
          instr.Op := irLoadLocal;
          instr.Dest := t0;
          instr.Src1 := t1;
          Emit(instr);
        end
        else
        begin
          // No conversion needed - just use the source temp directly
          // (No need to emit a copy instruction)
          Result := t1;
          Exit;
        end;

        Result := t0;
      end;

    nkFieldAccess:
       begin
         // For nested field access like o.x.a, we need to find the root struct
         // and use the combined offset. The Sema has already calculated the
         // combined offset in FieldOffset.
         
         // Walk up the chain of field accesses to find the root (non-field) expression
         baseExpr := TAstFieldAccess(expr).Obj;
         while (baseExpr is TAstFieldAccess) do
           baseExpr := TAstFieldAccess(baseExpr).Obj;
         
         // Now lower the root expression (e.g., 'o' in 'o.x.a')
         t1 := LowerExpr(baseExpr);
         if t1 < 0 then
           Exit;

         // If sema annotated the field offset on the AST node, use it
         fldOffset := TAstFieldAccess(expr).FieldOffset;
         ownerName := TAstFieldAccess(expr).OwnerName;
         fldType := TAstFieldAccess(expr).FieldType; // Get the field type for proper extension

         t0 := NewTemp;
         if fldOffset >= 0 then
         begin
           // Check if owner is a class (heap) or struct (stack)
            if (ownerName <> '') and (FClassTypes.IndexOf(ownerName) >= 0) then
            begin
              // Class: use positive offset (heap access)
              instr.Op := irLoadFieldHeap;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.ImmInt := fldOffset; // positive offset for heap
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end
            else
            begin
              // Struct: use negative offset (stack access)
              instr.Op := irLoadField;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.ImmInt := fldOffset; // will be negated in backend
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end;
          end
          else
          begin
            // FieldOffset not set by sema (e.g., imported class methods not fully sema'd).
            // Try to resolve the field by name.
            // First determine which class the receiver belongs to:
            //   - If receiver is 'self' → FCurrentClassDecl
            //   - If receiver is a local variable → look up FLocalTypeNames
            fldOffset := -1;
            ownerName := '';
            cd := nil;
            // Try to determine receiver class:
            //   - Named local variable → look up FLocalTypeNames (works in any function)
            //   - 'self' → FCurrentClassDecl (only in class methods)
            if (baseExpr is TAstIdent) and (TAstIdent(baseExpr).Name <> 'self') then
            begin
              // Named local variable: look up its class type
              i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
              if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocalTypeNames)) and
                 (FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])] <> '') then
              begin
                idx := FClassTypes.IndexOf(FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])]);
                if idx >= 0 then
                  cd := TAstClassDecl(FClassTypes.Objects[idx]);
              end;
            end;
            // Also try struct types (for struct parameters/locals passed by pointer
            // in imported function bodies where sema doesn't annotate FieldOffset)
            if (cd = nil) and (baseExpr is TAstIdent) then
            begin
              i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
              if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocalTypeNames)) and
                 (FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])] <> '') then
              begin
                structIdx := FStructTypes.IndexOf(FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])]);
                if structIdx >= 0 then
                begin
                  sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
                  if Length(sd.FieldOffsets) = Length(sd.Fields) then
                    for fi := 0 to High(sd.Fields) do
                    begin
                      if sd.Fields[fi].Name = TAstFieldAccess(expr).Field then
                      begin
                        fldOffset := sd.FieldOffsets[fi];
                        fldType := sd.Fields[fi].FieldType;
                        Break;
                      end;
                    end;
                end;
              end;
            end;
            if (cd = nil) and Assigned(FCurrentClassDecl) then
              cd := FCurrentClassDecl;
            if Assigned(cd) then
            begin
              // Walk the class and base classes to find the field
              // ownerName set to root class name for irLoadFieldHeap dispatch
              ownerName := cd.Name;
              while Assigned(cd) do
              begin
                for k := 0 to High(cd.Fields) do
                begin
                  if cd.Fields[k].Name = TAstFieldAccess(expr).Field then
                  begin
                    fldOffset := cd.FieldOffsets[k];
                    fldType := cd.Fields[k].FieldType;
                    Break;
                  end;
                end;
                if fldOffset >= 0 then Break;
                if cd.BaseClassName <> '' then
                begin
                  i := FClassTypes.IndexOf(cd.BaseClassName);
                  if i >= 0 then
                    cd := TAstClassDecl(FClassTypes.Objects[i])
                  else
                    cd := nil;
                end
                else
                  cd := nil;
              end;
            end;
            if fldOffset >= 0 then
            begin
              // Emit heap access for the class field (or struct param passed by pointer)
              instr.Op := irLoadFieldHeap;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.ImmInt := fldOffset;
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end
            else
            begin
              // Last resort: name-based fallback (likely wrong for heap objects, but best effort)
              instr.Op := irLoadField;
              instr.Dest := t0;
              instr.Src1 := t1;
              instr.LabelName := TAstFieldAccess(expr).Field;
              instr.FieldSize := TypeSizeBytes(fldType);
              Emit(instr);
            end;
          end;
         
         // Sign/zero-extend the loaded value to full register width based on field type
         if (fldType <> atUnresolved) and (fldType <> atInt64) and (fldType <> atUInt64) then
         begin
           t2 := NewTemp; // temp for extended value
           case fldType of
             atInt8, atUInt8:   // 8-bit types
               begin
                 if fldType = atInt8 then
                   instr.Op := irSExt // sign-extend for signed
                 else
                   instr.Op := irZExt; // zero-extend for unsigned
                 instr.Dest := t2;
                 instr.Src1 := t0;
                 instr.ImmInt := 8;
                 Emit(instr);
                 t0 := t2; // use extended value
               end;
             atInt16, atUInt16: // 16-bit types
               begin
                 if fldType = atInt16 then
                   instr.Op := irSExt // sign-extend for signed
                 else
                   instr.Op := irZExt; // zero-extend for unsigned
                 instr.Dest := t2;
                 instr.Src1 := t0;
                 instr.ImmInt := 16;
                 Emit(instr);
                 t0 := t2; // use extended value
               end;
             atInt32, atUInt32: // 32-bit types
               begin
                 if fldType = atInt32 then
                   instr.Op := irSExt // sign-extend for signed
                 else
                   instr.Op := irZExt; // zero-extend for unsigned
                 instr.Dest := t2;
                 instr.Src1 := t0;
                 instr.ImmInt := 32;
                 Emit(instr);
                 t0 := t2; // use extended value
               end;
           end;
         end;
         
         Result := t0;
       end;

    nkArrayLit:
      begin
        Result := LowerArrayLit(TAstArrayLit(expr));
      end;

    nkStructLit:
      begin
        // Struct literal: TypeName { field1: val1, field2: val2, ... }
        // Allocate stack space for the struct, initialize fields, return address
        Result := LowerStructLit(TAstStructLit(expr));
      end;

    // Map/Set expressions (v0.5.0)
    nkMapLit:
      begin
        // Map literal: {key1: val1, key2: val2, ...}
        // Emit: map_new(initial_capacity) + map_set(key, val) for each entry

        // Determine initial capacity (round up to power of 2)
        entryCount := Length(TAstMapLit(expr).Entries);
        if entryCount < 4 then
          entryCount := 4
        else
        begin
          // Round up to next power of 2
          while (entryCount and (entryCount - 1)) <> 0 do
            entryCount := entryCount and (entryCount - 1);
          entryCount := entryCount shl 1;
        end;

        // Allocate new map
        t0 := NewTemp;
        instr.Op := irMapNew;
        instr.Dest := t0;
        instr.ImmInt := entryCount;
        Emit(instr);

        // Add each entry: map_set(map, key, value)
        for i := 0 to High(TAstMapLit(expr).Entries) do
        begin
          // Lower key
          t1 := LowerExpr(TAstMapLit(expr).Entries[i].Key);
          if t1 < 0 then Exit;

          // Lower value
          t2 := LowerExpr(TAstMapLit(expr).Entries[i].Value);
          if t2 < 0 then Exit;

          // Emit map_set
          instr := Default(TIRInstr);
          instr.Op := irMapSet;
          instr.Src1 := t0;  // map
          instr.Src2 := t1;  // key
          instr.Src3 := t2;  // value
          Emit(instr);
        end;

        Result := t0;
      end;

    nkSetLit:
      begin
        // Set literal: {val1, val2, val3, ...}
        // Emit: set_new(initial_capacity) + set_add(set, value) for each element

        // Determine initial capacity (round up to power of 2)
        elemCount := Length(TAstSetLit(expr).Items);
        if elemCount < 4 then
          elemCount := 4
        else
        begin
          // Round up to next power of 2
          while (elemCount and (elemCount - 1)) <> 0 do
            elemCount := elemCount and (elemCount - 1);
          elemCount := elemCount shl 1;
        end;

        // Allocate new set
        t0 := NewTemp;
        instr.Op := irSetNew;
        instr.Dest := t0;
        instr.ImmInt := elemCount;
        Emit(instr);

        // Add each element: set_add(set, value)
        for i := 0 to High(TAstSetLit(expr).Items) do
        begin
          // Lower value
          t1 := LowerExpr(TAstSetLit(expr).Items[i]);
          if t1 < 0 then Exit;

          // Emit set_add
          instr := Default(TIRInstr);
          instr.Op := irSetAdd;
          instr.Src1 := t0;  // set
          instr.Src2 := t1;  // value
          Emit(instr);
        end;

        Result := t0;
      end;

    nkInExpr:
      begin
        // In expression: key in map/set
        // Emit: map_contains(map, key) or set_contains(set, value)

        // Lower the key and container
        t1 := LowerExpr(TAstInExpr(expr).Key);
        if t1 < 0 then Exit;

        t2 := LowerExpr(TAstInExpr(expr).Container);
        if t2 < 0 then Exit;

        // Determine which operation to use based on container type
        t0 := NewTemp;
        containerType := TAstInExpr(expr).Container.ResolvedType;

        if containerType = atMap then
        begin
          // map contains: irMapContains(map, key) -> bool
          instr.Op := irMapContains;
          instr.Dest := t0;
          instr.Src1 := t2;  // map
          instr.Src2 := t1;  // key
        end
        else if containerType = atSet then
        begin
          // set contains: irSetContains(set, value) -> bool
          instr.Op := irSetContains;
          instr.Dest := t0;
          instr.Src1 := t2;  // set
          instr.Src2 := t1;  // value
        end
        else
        begin
          FDiag.Error('invalid container type for "in" operator', expr.Span);
          Exit;
        end;

        Emit(instr);
        Result := t0;
      end;

    nkIsExpr:
      begin
        // Is expression: expr is ClassName
        // Returns true if expr is an instance of ClassName or a derived class
        // We implement this by checking the class name in the VMT
        
        t1 := LowerExpr(TAstIsExpr(expr).Expr);
        if t1 < 0 then Exit;
        
        // Call the ClassName method and compare with target class name
        // For now, we emit a call to a runtime helper that does the check
        
        // Load object pointer into RDI (first arg)
        // Emit: mov rdi, [rbp - slot]
        
        // For simplicity, we emit a call to a builtin that checks the type
        // Format: irIsType(object, targetClassName) -> bool
        
        t0 := NewTemp;
        instr.Op := irIsType;
        instr.Dest := t0;
        instr.Src1 := t1;  // object pointer
        instr.ImmStr := TAstIsExpr(expr).ClassName;  // target class name
        Emit(instr);
        Result := t0;
      end;

    nkNewExpr:
      begin
        // new ClassName() or new ClassName(args) - allocate heap memory for class
        // Look up class type to get size
        i := FStructTypes.IndexOf(TAstNewExpr(expr).ClassName);
        if i < 0 then
        begin
          FDiag.Error('unknown class type: ' + TAstNewExpr(expr).ClassName, expr.Span);
          Exit;
        end;
        
        // Check if it's a class with virtual methods
        hasVMT := False;
        if FStructTypes.Objects[i] is TAstClassDecl then
        begin
          cd := TAstClassDecl(FStructTypes.Objects[i]);
          if Length(cd.VirtualMethods) > 0 then
            hasVMT := True;
        end;
        
        // Allocate temp for pointer, emit irAlloc with size
        t0 := NewTemp;
        instr.Op := irAlloc;
        instr.Dest := t0;
        // Check if it's a class or struct - they have different layouts
        if FStructTypes.Objects[i] is TAstClassDecl then
        begin
          // Classes: Size already includes VMT pointer (added by ResolveVMTForClasses)
          instr.ImmInt := TAstClassDecl(FStructTypes.Objects[i]).Size;
        end
        else
          instr.ImmInt := TAstStructDecl(FStructTypes.Objects[i]).Size;
        if instr.ImmInt = 0 then
          instr.ImmInt := 8; // minimum allocation
        Emit(instr);
        
        // Initialize VMT pointer if class has virtual methods
        if hasVMT then
        begin
          // VMT pointer goes at offset 0 of the object
          // We need to store the VMT address into the allocated memory
          // This will be handled by the backend which knows the VMT data position
          // For now, emit a placeholder that will be patched
          // Actually, we can emit this directly: load VMT address from data section
          
          // Emit: mov rax, [rel _vmt_ClassName]  (load VMT address)
          // Then:  mov [t0], rax                   (store VMT pointer to object)
          
          // Load VMT address into temporary
          t1 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irLoadGlobalAddr;  // Use this to get the VMT address
          instr.Dest := t1;
          instr.ImmStr := '_vmt_' + TAstNewExpr(expr).ClassName;
          Emit(instr);
          
          // Store VMT pointer to object at offset 0
          instr := Default(TIRInstr);
          instr.Op := irStoreFieldHeap;
          instr.Src1 := t0;  // object pointer
          instr.Src2 := t1;  // VMT address
          instr.ImmInt := 0; // offset 0
          instr.FieldSize := 8; // VMT pointer is always 8 bytes
          Emit(instr);
        end;
        
        // If new has arguments, call the constructor (method named 'new')
        if Length(TAstNewExpr(expr).Args) > 0 then
        begin
          // Build args: [self (t0), original args...]
          argCount := Length(TAstNewExpr(expr).Args);
          SetLength(argTemps, argCount + 1);
          argTemps[0] := t0; // self is the allocated object pointer
          
          // Lower the constructor arguments
          for k := 0 to argCount - 1 do
            argTemps[k + 1] := LowerExpr(TAstNewExpr(expr).Args[k]);
          
          // Emit call to constructor (use the name from AST)
          t1 := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irCall;
          instr.Dest := t1;
          instr.ImmStr := '_L_' + TAstNewExpr(expr).ClassName + '_' + TAstNewExpr(expr).ConstructorName;
          instr.ImmInt := argCount + 1; // +1 for self
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount + 1);
          for k := 0 to argCount do
            instr.ArgTemps[k] := argTemps[k];
          Emit(instr);
          // Bootstrap compat: if constructor is 'Create', it handles its own allocation
          // and returns the properly initialized object. Use the constructor return value
          // instead of the pre-allocated t0 (which will be leaked but that's acceptable).
          if TAstNewExpr(expr).ConstructorName = 'Create' then
            t0 := t1;
        end
        else
        begin
          // No arguments: call 0-arg Create constructor if name is 'Create'
          if TAstNewExpr(expr).ConstructorName = 'Create' then
          begin
            t1 := NewTemp;
            instr := Default(TIRInstr);
            instr.Op := irCall;
            instr.Dest := t1;
            instr.ImmStr := '_L_' + TAstNewExpr(expr).ClassName + '_Create';
            instr.ImmInt := 1; // +1 for self (dummy t0)
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, 1);
            instr.ArgTemps[0] := t0; // pass pre-allocated ptr as dummy self
            Emit(instr);
            t0 := t1; // use constructor return value
          end;
        end;

        Result := t0;
      end;

    nkSuperCall:
      begin
        // super.method(args) - call base class method
        // Requires FCurrentClassDecl to be set (we're in a class method)
        if not Assigned(FCurrentClassDecl) or (FCurrentClassDecl.BaseClassName = '') then
        begin
          FDiag.Error('super call outside of derived class method', expr.Span);
          Result := -1;
          Exit;
        end;
        
        // Find base class in FClassTypes
        baseIdx := FClassTypes.IndexOf(FCurrentClassDecl.BaseClassName);
        if baseIdx < 0 then
        begin
          FDiag.Error('unknown base class: ' + FCurrentClassDecl.BaseClassName, expr.Span);
          Result := -1;
          Exit;
        end;
        
        // Build mangled name: _L_<BaseClass>_<MethodName>
        mangled := '_L_' + FCurrentClassDecl.BaseClassName + '_' + TAstSuperCall(expr).MethodName;
        
        // Build args: [self, originalArgs...]
        argCount := Length(TAstSuperCall(expr).Args);
        SetLength(argTemps, argCount + 1);
        
        // First arg is self (local index 0)
        t0 := NewTemp;
        instr.Op := irLoadLocal;
        instr.Dest := t0;
        instr.Src1 := 0; // self is always at local index 0
        Emit(instr);
        argTemps[0] := t0;
        
        // Lower remaining args
        for i := 0 to argCount - 1 do
          argTemps[i + 1] := LowerExpr(TAstSuperCall(expr).Args[i]);
        
        // Emit call
        t0 := NewTemp;
        instr.Op := irCall;
        instr.Dest := t0;
        instr.ImmStr := mangled;
        instr.ImmInt := argCount + 1; // +1 for self
        instr.CallMode := cmInternal;
        SetLength(instr.ArgTemps, argCount + 1);
        for i := 0 to argCount do
          instr.ArgTemps[i] := argTemps[i];
        Emit(instr);
        Result := t0;
      end;

    nkPanic:
      begin
        // panic(message) - write message to stderr and exit with error code
        // Lower the message expression first
        msgTmp := LowerExpr(TAstPanicExpr(expr).Message);
        if msgTmp < 0 then
          Exit(-1);
        
        // Emit panic instruction with string length info
        instr.Op := irPanic;
        instr.Src1 := msgTmp;
        // Store string length in ImmInt for the backend
        if TAstPanicExpr(expr).Message is TAstStrLit then
          instr.ImmInt := Length(TAstStrLit(TAstPanicExpr(expr).Message).Value)
        else
          instr.ImmInt := 0; // Will need runtime strlen
        Emit(instr);
        
        // panic never returns - emit unreachable code (or just return -1)
        Result := -1;
      end;

    nkCheck:
      begin
        // check(condition) - runtime-only assertion, panics if false without message
        // Expand to: if (!condition) panic("check failed")
        // Lower the condition expression first
        condTmp := LowerExpr(TAstCheckExpr(expr).Condition);
        if condTmp < 0 then
          Exit(-1);

        // Create labels for skip and panic
        skipLbl := NewLabel('Lcheck_ok');
        // if cond is true, jump to skip (use irBrTrue to jump if condition is true)
        instr := Default(TIRInstr);
        instr.Op := irBrTrue; // jump if true -> skip panic
        instr.Src1 := condTmp;
        instr.LabelName := skipLbl;
        Emit(instr);

        // panic("check failed") - use irPanic with ImmInt = -1 to signal default message
        instr := Default(TIRInstr);
        instr.Op := irPanic;
        instr.ImmInt := -1; // Signal default "check failed" message
        Emit(instr);

        // skip label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := skipLbl;
        Emit(instr);

        // check never returns on false, so we can assign any type
        Result := -1;
      end;

    // SIMD Expressions (v0.2.0)
    nkSIMDNew:
      begin
        // ParallelArray<T>(size) - SIMD-optimized array allocation
        // Allocate space on heap with proper alignment for SIMD (16-byte alignment for SSE/AVX)
        
        // Lower the size expression
        t0 := LowerExpr(TAstSIMDNew(expr).Size);
        if t0 < 0 then
          Exit(-1);
        
        // Calculate element size based on type
        case TAstSIMDNew(expr).ElementType of
          atInt8, atUInt8:   elemSize := 1;
          atInt16, atUInt16: elemSize := 2;
          atInt32, atUInt32, atF32: elemSize := 4;
          atInt64, atUInt64, atF64: elemSize := 8;
        else
          elemSize := 8; // default to 8 bytes
        end;
        
        // For SIMD, we need vector size alignment (16 bytes for SSE, 32 for AVX)
        // We'll use a multiple of 16 for alignment
        // Round up size to next multiple of 16 for SIMD alignment
        // This is a simplified version - full implementation would use aligned allocation
        
        // Allocate: totalSize = size * elementSize (rounded up to 16-byte alignment)
        instr.Op := irAlloc;
        t1 := NewTemp; // result pointer
        instr.Dest := t1;
        instr.Src1 := t0;  // size in elements
        instr.ImmInt := elemSize; // element size in ImmInt (abused field)
        Emit(instr);
        
        Result := t1;
      end;

    nkSIMDBinOp:
      begin
        // SIMD binary operation: element-wise operation on two vectors
        // TAstSIMDBinOp has: Op (token), Left, Right (both should be TAstSIMDNew or SIMD index access)
        
        // Lower left operand (should return a pointer to SIMD vector)
        t1 := LowerExpr(TAstSIMDBinOp(expr).Left);
        if t1 < 0 then
          Exit(-1);
        
        // Lower right operand
        t2 := LowerExpr(TAstSIMDBinOp(expr).Right);
        if t2 < 0 then
          Exit(-1);
        
        // Allocate result vector (same size as inputs)
        // For now, we allocate a new vector for the result
        tResult := NewTemp;
        // Copy the allocation logic from nkSIMDNew but with same size
        // Actually, we need to store the result somewhere - let's use a stack temporary
        // The backend will handle this by using XMM registers
        
        // Map operator to SIMD IR operation
        case TAstSIMDBinOp(expr).Op of
          tkPlus:   instr.Op := irSIMDAdd;
          tkMinus:  instr.Op := irSIMDSub;
          tkStar:   instr.Op := irSIMDMul;
          tkSlash:  instr.Op := irSIMDDiv;
          tkAnd:    instr.Op := irSIMDAnd;
          tkOr:     instr.Op := irSIMDOr;
          tkXor:    instr.Op := irSIMDXor;
          tkEq:     instr.Op := irSIMDCmpEq;
          tkNeq:    instr.Op := irSIMDCmpNe;
          tkLt:     instr.Op := irSIMDCmpLt;
          tkLe:     instr.Op := irSIMDCmpLe;
          tkGt:     instr.Op := irSIMDCmpGt;
          tkGe:     instr.Op := irSIMDCmpGe;
        else
          begin
            FDiag.Error('unsupported SIMD operator', expr.Span);
            Exit(-1);
          end;
        end;
        
        // Emit SIMD binary operation
        // Note: The current backend expects:
        // - Src1, Src2: stack slots containing vector addresses
        // - Dest: stack slot for result
        // This needs proper handling in the backend
        instr.Dest := tResult;
        instr.Src1 := t1;
        instr.Src2 := t2;
        Emit(instr);
        
        Result := tResult;
      end;

    nkSIMDUnaryOp:
      begin
        // SIMD unary operation: element-wise operation on a vector
        
        // Lower operand
        t1 := LowerExpr(TAstSIMDUnaryOp(expr).Operand);
        if t1 < 0 then
          Exit(-1);
        
        tResult := NewTemp;
        
        // Map operator to SIMD IR operation
        case TAstSIMDUnaryOp(expr).Op of
          tkMinus: instr.Op := irSIMDNeg;
          // Add more unary ops as needed
        else
          begin
            FDiag.Error('unsupported SIMD unary operator', expr.Span);
            Exit(-1);
          end;
        end;
        
        instr.Dest := tResult;
        instr.Src1 := t1;
        Emit(instr);
        
        Result := tResult;
      end;

    nkSIMDIndexAccess:
      begin
        // SIMD index access: vec[index] - returns scalar element at index
        // The vector expression evaluates to a heap pointer (from irAlloc).
        // We compute: element_addr = vec_ptr + index * elemSize
        // Then load the scalar value from that address.

        // Lower the vector (returns a temp holding the heap pointer)
        tVec := LowerExpr(TAstSIMDIndexAccess(expr).Obj);
        if tVec < 0 then
          Exit(-1);

        // Lower the index (must be integer)
        tIdx := LowerExpr(TAstSIMDIndexAccess(expr).Index);
        if tIdx < 0 then
          Exit(-1);

        // Determine element size from the SIMDKind of the object
        elemSize := 8; // default fallback
        if TAstSIMDIndexAccess(expr).Obj is TAstSIMDNew then
        begin
          case TAstSIMDNew(TAstSIMDIndexAccess(expr).Obj).SIMDKind of
            simdI8:  elemSize := 1;
            simdI16: elemSize := 2;
            simdI32: elemSize := 4;
            simdI64: elemSize := 8;
            simdF32: elemSize := 4;
            simdF64: elemSize := 8;
          end;
        end
        else if TAstSIMDIndexAccess(expr).Obj is TAstSIMDBinOp then
        begin
          case TAstSIMDBinOp(TAstSIMDIndexAccess(expr).Obj).SIMDKind of
            simdI8:  elemSize := 1;
            simdI16: elemSize := 2;
            simdI32: elemSize := 4;
            simdI64: elemSize := 8;
            simdF32: elemSize := 4;
            simdF64: elemSize := 8;
          end;
        end
        else if TAstSIMDIndexAccess(expr).Obj is TAstSIMDUnaryOp then
        begin
          case TAstSIMDUnaryOp(TAstSIMDIndexAccess(expr).Obj).SIMDKind of
            simdI8:  elemSize := 1;
            simdI16: elemSize := 2;
            simdI32: elemSize := 4;
            simdI64: elemSize := 8;
            simdF32: elemSize := 4;
            simdF64: elemSize := 8;
          end;
        end;

        // Use irLoadElem to load the element at the given index.
        // irLoadElem: Dest = *(Src1 + Src2 * elemSize)
        // We pass elemSize via ImmInt so the backend knows the stride.
        t0 := NewTemp;
        instr.Op := irLoadElem;
        instr.Dest := t0;
        instr.Src1 := tVec;   // base pointer (heap address)
        instr.Src2 := tIdx;   // index
        instr.ImmInt := elemSize; // element size for address calculation
        Emit(instr);

        Result := t0;
      end;

    nkFormatExpr:
      begin
        t1 := LowerExpr(TAstFormatExpr(expr).Expr);
        if t1 < 0 then Exit;
        t0 := NewTemp;
        instr := Default(TIRInstr);
        instr.Op := irCallBuiltin;
        instr.Dest := t0;
        instr.ImmStr := 'format_float';
        instr.ImmInt := 3;
        SetLength(instr.ArgTemps, 3);
        instr.ArgTemps[0] := t1;
        // Width as constant temp
        tWidth := NewTemp;
        instr2 := Default(TIRInstr);
        instr2.Op := irConstInt;
        instr2.Dest := tWidth;
        instr2.ImmInt := TAstFormatExpr(expr).Width;
        Emit(instr2);
        // Decimals as constant temp
        tDecimals := NewTemp;
        instr2 := Default(TIRInstr);
        instr2.Op := irConstInt;
        instr2.Dest := tDecimals;
        instr2.ImmInt := TAstFormatExpr(expr).Decimals;
        Emit(instr2);
        instr.ArgTemps[1] := tWidth;
        instr.ArgTemps[2] := tDecimals;
        Emit(instr);
        Result := t0;
      end;

  else
    FDiag.Error('lowering: unsupported expression kind', expr.Span);
    Result := -1;
  end;
end;

function TIRLowering.LowerStructLit(sl: TAstStructLit): Integer;
var
  instr: TIRInstr;
  sd: TAstStructDecl;
  baseLoc, slotsNeeded: Integer;
  i, fi, j, fldOffset, valTemp, addrTemp: Integer;
  elemSize, ptrTemp, lenTemp, elemTemp: Integer;
  fld: TStructField;
  arrLit: TAstArrayLit;
  fieldName: string;
  fieldFound: Boolean;
begin
  Result := -1;
  instr := Default(TIRInstr);
  
  // Get struct declaration (should have been set by sema)
  sd := sl.StructDecl;
  if not Assigned(sd) then
  begin
    // Try to look it up
    fi := FStructTypes.IndexOf(sl.TypeName);
    if fi < 0 then
    begin
      FDiag.Error('unknown struct type in literal: ' + sl.TypeName, sl.Span);
      Exit;
    end;
    sd := TAstStructDecl(FStructTypes.Objects[fi]);
  end;
  
  // Allocate stack slots for the struct
  slotsNeeded := (sd.Size + 7) div 8;
  if slotsNeeded < 1 then slotsNeeded := 1;
  
  // Use an anonymous name for the temporary struct
  baseLoc := AllocLocalMany('_structlit_' + IntToStr(FTempCounter), atUnresolved, slotsNeeded, True);
  
  // Zero-initialize first slot (other slots will be written to)
  addrTemp := NewTemp;
  instr.Op := irConstInt;
  instr.Dest := addrTemp;
  instr.ImmInt := 0;
  Emit(instr);
  instr.Op := irStoreLocal;
  instr.Dest := baseLoc;
  instr.Src1 := addrTemp;
  Emit(instr);
  
  // Get base address of the struct (lowest address = slot baseLoc + slotCount - 1)
  // Use irLoadStructAddr so the convention matches irCallStruct / irReturnStruct.
  addrTemp := NewTemp;
  instr.Op := irLoadStructAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  instr.StructSize := sd.Size;
  Emit(instr);

  // Initialize each field from the literal
  for i := 0 to High(sl.Fields) do
  begin
    fieldName := sl.Fields[i].Name;
    fieldFound := False;
    
    // Find field in struct declaration
    for fi := 0 to High(sd.Fields) do
    begin
      if sd.Fields[fi].Name = fieldName then
      begin
        fieldFound := True;
        fldOffset := sd.FieldOffsets[fi];
        fld       := sd.Fields[fi];

        // --- static inline array [N]T: store each element individually ---
        if fld.ArrayLen > 0 then
        begin
          if fld.ElemType <> atUnresolved then
            elemSize := TypeSizeBytes(fld.ElemType)
          else
            elemSize := TypeSizeBytes(fld.FieldType);
          if elemSize < 1 then elemSize := 8;

          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            for j := 0 to High(arrLit.Items) do
            begin
              elemTemp := LowerExpr(arrLit.Items[j]);
              if elemTemp < 0 then Continue;
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := elemTemp;
              instr.ImmInt    := fldOffset + j * elemSize;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end;
        end

        // --- dynamic array []T: store fat-pointer (ptr, len) ---
        else if (fld.ArrayLen < 0) or (fld.FieldType = atDynArray) then
        begin
          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            if Length(arrLit.Items) > 0 then
            begin
              baseLoc := AllocLocalMany('_dynfld_' + IntToStr(FTempCounter), atUnresolved,
                                        Length(arrLit.Items));
              SetLength(FLocalArrayLen, baseLoc + Length(arrLit.Items));
              for j := 0 to High(arrLit.Items) do
              begin
                FLocalArrayLen[baseLoc + j] := Length(arrLit.Items);
                elemTemp := LowerExpr(arrLit.Items[j]);
                if elemTemp >= 0 then
                begin
                  instr := Default(TIRInstr);
                  instr.Op   := irStoreLocal;
                  instr.Dest := baseLoc + (Length(arrLit.Items) - 1 - j);
                  instr.Src1 := elemTemp;
                  Emit(instr);
                end;
              end;
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op   := irLoadLocalAddr;
              instr.Dest := ptrTemp;
              instr.Src1 := baseLoc;
              Emit(instr);
            end
            else
            begin
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op     := irConstInt;
              instr.Dest   := ptrTemp;
              instr.ImmInt := 0;
              Emit(instr);
            end;
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := ptrTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
            lenTemp := NewTemp;
            instr := Default(TIRInstr);
            instr.Op     := irConstInt;
            instr.Dest   := lenTemp;
            instr.ImmInt := Length(arrLit.Items);
            Emit(instr);
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := lenTemp;
            instr.ImmInt    := fldOffset + 8;
            instr.FieldSize := 8;
            Emit(instr);
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := 8;
              Emit(instr);
            end;
          end;
        end

        // --- Map<K,V> and Set<T>: lower → pointer, store 8 bytes ---
        else if fld.FieldType in [atMap, atSet] then
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp >= 0 then
          begin
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := valTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
          end;
        end

        // --- scalar / named-type: single store ---
        else
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp < 0 then Continue;
          instr := Default(TIRInstr);
          instr.Op        := irStoreField;
          instr.Src1      := addrTemp;
          instr.Src2      := valTemp;
          instr.ImmInt    := fldOffset;
          instr.FieldSize := TypeSizeBytes(fld.FieldType);
          Emit(instr);
        end;

        Break;
      end;
    end;

    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;

  // Return the address temp (LowerStructLit)
  Result := addrTemp;
end;

function TIRLowering.LowerArrayLit(al: TAstArrayLit): Integer;
var
  instr: TIRInstr;
  arrLen, baseLoc, addrTemp, tmp, i: Integer;
  items: TAstExprList;
begin
  Result := -1;
  instr := Default(TIRInstr);

  items := al.Items;
  arrLen := Length(items);

  // Empty array: return -1 (no valid temp)
  if arrLen = 0 then
    Exit;

  // Allocate stack slots for the array elements
  baseLoc := AllocLocalMany('_arraylit_' + IntToStr(FTempCounter), atUnresolved, arrLen);

  // Record array length for bounds checking
  if baseLoc + arrLen > Length(FLocalArrayLen) then
    SetLength(FLocalArrayLen, baseLoc + arrLen);
  for i := 0 to arrLen - 1 do
    FLocalArrayLen[baseLoc + i] := arrLen;

  // Store elements in REVERSE order: arr[0] at highest slot (baseLoc + arrLen - 1 - i)
  for i := 0 to High(items) do
  begin
    tmp := LowerExpr(items[i]);
    if tmp < 0 then Continue;
    instr.Op := irStoreLocal;
    instr.Dest := baseLoc + (arrLen - 1 - i);
    instr.Src1 := tmp;
    Emit(instr);
  end;

  // Load the address of the array base slot
  addrTemp := NewTemp;
  instr.Op := irLoadLocalAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  Emit(instr);

  Result := addrTemp;
end;

procedure TIRLowering.LowerNestedFunc(funcDecl: TAstFuncDecl);
var
  fn: TIRFunction;
  j, captureSlot, outerSlot: Integer;
  structIdx: Integer;
  sd: TAstStructDecl;
  savedFunc: TIRFunction;
  savedDecl: TAstFuncDecl;
  savedLocalMap: TStringList;
  savedTempCounter: Integer;
  instr: TIRInstr;
begin
  // Save current function context
  savedFunc := FCurrentFunc;
  savedDecl := FCurrentFuncDecl;
  savedLocalMap := TStringList.Create;
  for j := 0 to FLocalMap.Count - 1 do
    savedLocalMap.AddObject(FLocalMap[j], FLocalMap.Objects[j]);
  savedTempCounter := FTempCounter;

  try
    // Create new function in module (use original name)
    fn := FModule.AddFunction(funcDecl.Name);
    FCurrentFunc := fn;
    FCurrentFuncDecl := funcDecl;
    FLocalMap.Clear;
    for j := 0 to Length(FLocalConst) - 1 do
      if Assigned(FLocalConst[j]) then
        FLocalConst[j].Free;
    SetLength(FLocalConst, 0);
    FTempCounter := 0;

    // Copy closure info from AST to IR
    fn.ParentFuncName := funcDecl.ParentFuncName;
    fn.NeedsStaticLink := funcDecl.NeedsStaticLink;

    // Params: if needs static link, add as implicit first param (slot 0 = static link)
    if funcDecl.NeedsStaticLink then
    begin
      fn.ParamCount := Length(funcDecl.Params) + 1; // +1 for static link
      fn.LocalCount := fn.ParamCount;
      SetLength(FLocalTypes, fn.LocalCount);
      SetLength(FLocalConst, fn.LocalCount);
      // Slot 0 = static link pointer (parent RBP)
      // Slots 1..N = regular params
      FLocalMap.AddObject('__static_link__', IntToObj(0));
      FLocalTypes[0] := atInt64;
      FLocalConst[0] := nil;
      for j := 0 to High(funcDecl.Params) do
      begin
        FLocalMap.AddObject(funcDecl.Params[j].Name, IntToObj(j + 1));
        FLocalTypes[j + 1] := funcDecl.Params[j].ParamType;
        FLocalConst[j + 1] := nil;
      end;
      // Register captured vars by name — they will be loaded via irLoadCaptured
      for j := 0 to High(funcDecl.CapturedVars) do
      begin
        captureSlot := fn.LocalCount;
        Inc(fn.LocalCount);
        SetLength(FLocalTypes, fn.LocalCount);
        SetLength(FLocalConst, fn.LocalCount);
        FLocalTypes[captureSlot] := funcDecl.CapturedVars[j].VarType;
        FLocalConst[captureSlot] := nil;
        // Register: name -> special marker slot (captured vars use irLoadCaptured)
        FLocalMap.AddObject(funcDecl.CapturedVars[j].Name, IntToObj(-100 - j));
      end;
    end
    else
    begin
      fn.ParamCount := Length(funcDecl.Params);
      fn.LocalCount := fn.ParamCount;
      for j := 0 to fn.ParamCount - 1 do
      begin
        FLocalMap.AddObject(funcDecl.Params[j].Name, IntToObj(j));
        FLocalTypes[j] := funcDecl.Params[j].ParamType;
        FLocalConst[j] := nil;
      end;
    end;

    // Calculate ReturnStructSize
    fn.ReturnStructSize := 0;
    if funcDecl.ReturnTypeName <> '' then
    begin
      structIdx := FStructTypes.IndexOf(funcDecl.ReturnTypeName);
      if structIdx >= 0 then
      begin
        sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
        fn.ReturnStructSize := sd.Size;
      end;
    end;

    // Lower the function body
    for j := 0 to High(funcDecl.Body.Stmts) do
      LowerStmt(funcDecl.Body.Stmts[j]);

  finally
    // Restore parent function context
    FCurrentFunc := savedFunc;
    FCurrentFuncDecl := savedDecl;
    FLocalMap.Clear;
    for j := 0 to savedLocalMap.Count - 1 do
      FLocalMap.AddObject(savedLocalMap[j], savedLocalMap.Objects[j]);
    savedLocalMap.Free;
    FTempCounter := savedTempCounter;
  end;
end;

procedure TIRLowering.LowerStructLitIntoLocal(sl: TAstStructLit; baseLoc: Integer; sd: TAstStructDecl);
var
  instr: TIRInstr;
  i, fi, j, fldOffset, valTemp, addrTemp: Integer;
  elemSize, ptrTemp, lenTemp, elemTemp, dynBase: Integer;
  fld: TStructField;
  arrLit: TAstArrayLit;
  fieldName: string;
  fieldFound: Boolean;
begin
  instr := Default(TIRInstr);

  // Get base address of the local struct (lowest address = slot baseLoc + slotCount - 1)
  // Use irLoadStructAddr (not irLoadLocalAddr) so the address convention matches
  // irCallStruct and irReturnStruct (both use SlotOffset(base+slotCount-1) as lowest address).
  addrTemp := NewTemp;
  instr.Op := irLoadStructAddr;
  instr.Dest := addrTemp;
  instr.Src1 := baseLoc;
  instr.StructSize := sd.Size;
  Emit(instr);
  
  // Initialize each field from the literal
  for i := 0 to High(sl.Fields) do
  begin
    fieldName := sl.Fields[i].Name;
    fieldFound := False;
    
    // Find field in struct declaration
    for fi := 0 to High(sd.Fields) do
    begin
      if sd.Fields[fi].Name = fieldName then
      begin
        fieldFound := True;
        fldOffset := sd.FieldOffsets[fi];
        fld       := sd.Fields[fi];

        if fld.ArrayLen > 0 then
        begin
          if fld.ElemType <> atUnresolved then
            elemSize := TypeSizeBytes(fld.ElemType)
          else
            elemSize := TypeSizeBytes(fld.FieldType);
          if elemSize < 1 then elemSize := 8;
          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            for j := 0 to High(arrLit.Items) do
            begin
              elemTemp := LowerExpr(arrLit.Items[j]);
              if elemTemp < 0 then Continue;
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := elemTemp;
              instr.ImmInt    := fldOffset + j * elemSize;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := elemSize;
              Emit(instr);
            end;
          end;
        end
        else if (fld.ArrayLen < 0) or (fld.FieldType = atDynArray) then
        begin
          if sl.Fields[i].Value is TAstArrayLit then
          begin
            arrLit := TAstArrayLit(sl.Fields[i].Value);
            if Length(arrLit.Items) > 0 then
            begin
              dynBase := AllocLocalMany('_dynfld_' + IntToStr(FTempCounter), atUnresolved,
                                        Length(arrLit.Items));
              SetLength(FLocalArrayLen, dynBase + Length(arrLit.Items));
              for j := 0 to High(arrLit.Items) do
              begin
                FLocalArrayLen[dynBase + j] := Length(arrLit.Items);
                elemTemp := LowerExpr(arrLit.Items[j]);
                if elemTemp >= 0 then
                begin
                  instr := Default(TIRInstr);
                  instr.Op   := irStoreLocal;
                  instr.Dest := dynBase + (Length(arrLit.Items) - 1 - j);
                  instr.Src1 := elemTemp;
                  Emit(instr);
                end;
              end;
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op   := irLoadLocalAddr;
              instr.Dest := ptrTemp;
              instr.Src1 := dynBase;
              Emit(instr);
            end
            else
            begin
              ptrTemp := NewTemp;
              instr := Default(TIRInstr);
              instr.Op     := irConstInt;
              instr.Dest   := ptrTemp;
              instr.ImmInt := 0;
              Emit(instr);
            end;
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := ptrTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
            lenTemp := NewTemp;
            instr := Default(TIRInstr);
            instr.Op     := irConstInt;
            instr.Dest   := lenTemp;
            instr.ImmInt := Length(arrLit.Items);
            Emit(instr);
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := lenTemp;
            instr.ImmInt    := fldOffset + 8;
            instr.FieldSize := 8;
            Emit(instr);
          end
          else
          begin
            valTemp := LowerExpr(sl.Fields[i].Value);
            if valTemp >= 0 then
            begin
              instr := Default(TIRInstr);
              instr.Op        := irStoreField;
              instr.Src1      := addrTemp;
              instr.Src2      := valTemp;
              instr.ImmInt    := fldOffset;
              instr.FieldSize := 8;
              Emit(instr);
            end;
          end;
        end
        else if fld.FieldType in [atMap, atSet] then
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp >= 0 then
          begin
            instr := Default(TIRInstr);
            instr.Op        := irStoreField;
            instr.Src1      := addrTemp;
            instr.Src2      := valTemp;
            instr.ImmInt    := fldOffset;
            instr.FieldSize := 8;
            Emit(instr);
          end;
        end
        else
        begin
          valTemp := LowerExpr(sl.Fields[i].Value);
          if valTemp < 0 then Continue;
          instr := Default(TIRInstr);
          instr.Op        := irStoreField;
          instr.Src1      := addrTemp;
          instr.Src2      := valTemp;
          instr.ImmInt    := fldOffset;
          instr.FieldSize := TypeSizeBytes(fld.FieldType);
          Emit(instr);
        end;

        Break;
      end;
    end;

    if not fieldFound then
      FDiag.Error('unknown field in struct literal: ' + fieldName, sl.Span);
  end;
end;

function TIRLowering.LowerStmt(stmt: TAstStmt): Boolean;
  var
    instr: TIRInstr;
    loc: Integer;
    tmp: Integer;
    condTmp: Integer;
    t0, t1, t2: Integer;
    thenLabel, elseLabel, endLabel: string;
    whileNode: TAstWhile;
    startLabel, bodyLabel, exitLabel: string;
    i, j, k: Integer;
    sw: TAstSwitch;
    switchTmp: Integer;
    endLbl, defaultLbl: string;
    caseLabels: TStringList;
    lbl: string;
    caseTmp: Integer;
    ltype: TAurumType;
    width: Integer;
    w: Integer;
    lit: Int64;
    mask64: UInt64;
    truncated: UInt64;
    half: UInt64;
    signedVal: Int64;
    cvLocal: TConstValue;
    vd: TAstVarDecl;
    items: TAstExprList;
    elemSize: Integer;
    fa: TAstFieldAssign;
    retStructDecl: TAstStructDecl;
    call: TAstCall;
    argCount: Integer;
    argTemps: array of Integer;
    ownerName: string;
    mangledName: string;
    arrLen: Integer;
    baseSlot: Integer;
    // bounds-check helpers
    gv: TAstVarDecl;
    tZero, tLen, tGe0, tLtLen, tOk, tLtZero, tGeLen: Integer;
    // assert/panic helpers
    cond, msg: Integer;
    skipLbl: string;
    msgTmp, codeTmp: Integer;
    staticIdx: Integer;
    errLbl: string;
    // struct helpers
    sd: TAstStructDecl;
    structIdx: Integer;
    structSlots: Integer;
    slotCount: Integer;
    // nested field access helpers
    baseExpr: TAstExpr;
    // class field resolution helpers
    cd: TAstClassDecl;
    fi: Integer;
    fldOffset: Integer;
    fldType: TAurumType;
    // range type helpers (aerospace-todo P1 #7)
    rtIdx, rtIdx2: Integer;
    rtDecl, rtDecl2: TAstTypeDecl;
  begin
  // Track source location from AST node for assembly listing (aerospace-todo 6.1)
  if Assigned(stmt) then
  begin
    FCurrentSourceLine := stmt.Span.Line;
    FCurrentSourceFile := stmt.Span.FileName;
    // Provenance Tracking (WP-F): set current AST node for IR provenance
    FCurrentASTNode := stmt;
  end;
  instr := Default(TIRInstr);
  Result := True;
  // Handle block statements (multiple statements in braces)
  if stmt is TAstBlock then
  begin
    for i := 0 to High(TAstBlock(stmt).Stmts) do
      LowerStmt(TAstBlock(stmt).Stmts[i]);
    Exit(True);
  end;

  // Handle expression statements (e.g., function calls, panic as statement)
  if stmt is TAstExprStmt then
  begin
    // Just lower the expression, discard the result
    LowerExpr(TAstExprStmt(stmt).Expr);
    Exit(True);
  end;

   if stmt is TAstVarDecl then
   begin
     vd := TAstVarDecl(stmt);
      // If ArrayLen not set but InitExpr is an array literal, infer the length
      arrLen := vd.ArrayLen;
      if (vd.InitExpr is TAstArrayLit) then
        arrLen := Length(TAstArrayLit(vd.InitExpr).Items);
      // Handle dynamic arrays: ArrayLen = -1 or DeclType = atDynArray
      if (arrLen = -1) or (vd.DeclType = atDynArray) then
      begin
          // Local array literal: allocate slots for elements only (no fat-pointer).
          // Store elements in REVERSE order so that arr[0] is at highest address.
          // This way, baseSlot + index*8 correctly addresses all elements.
          // Mark as NOT dynamic array - elements are stored inline.
          loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
          // Record array length for bounds checking
          SetLength(FLocalArrayLen, loc + arrLen);
          for i := 0 to arrLen - 1 do
            FLocalArrayLen[loc + i] := arrLen;
           if vd.InitExpr is TAstArrayLit then
          begin
            items := TAstArrayLit(vd.InitExpr).Items;
            if Length(items) <> arrLen then
              FDiag.Error('array literal length mismatch', vd.Span)
            else
            begin
              for i := 0 to High(items) do
              begin
                tmp := LowerExpr(items[i]);
                // store in REVERSE order: arr[0] at highest slot (loc + arrLen - 1 - i)
                instr.Op := irStoreLocal; instr.Dest := loc + (arrLen - 1 - i); instr.Src1 := tmp; Emit(instr);
              end;
            end;
          end
        else
        begin
          // initializer not an array literal: try to lower single expression into first element
          tmp := LowerExpr(vd.InitExpr);
          instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := tmp; Emit(instr);
        end;
        Exit(True);
      end
      else if vd.ArrayLen = -1 then
      begin

        // dynamic array: fat-pointer with 3 slots (ptr, len, cap)
        loc := AllocLocalMany(vd.Name, atPChar, 3);
        // mark base slot as dynamic array
        if loc >= Length(FLocalIsDynArray) then SetLength(FLocalIsDynArray, loc + 3);
        FLocalIsDynArray[loc] := True;
        // record element size for this local slot (needed by backend for element addressing)
          begin
            elemSize := 8; // default
            case vd.DeclType of
              atInt8, atUInt8: elemSize := 1;
              atInt16, atUInt16: elemSize := 2;
              atInt32, atUInt32: elemSize := 4;
              atInt64, atUInt64: elemSize := 8;
              atChar: elemSize := 1;
              atPChar: elemSize := 8;
            else
              elemSize := 8; // conservative default
            end;
            if loc >= Length(FLocalElemSize) then SetLength(FLocalElemSize, loc+1);
            FLocalElemSize[loc] := elemSize;
          end;

        // initializer: if empty array literal -> set nil (0)
        if vd.InitExpr is TAstArrayLit then
        begin
          // only allow empty literal for now
          if Length(TAstArrayLit(vd.InitExpr).Items) <> 0 then
            FDiag.Error('cannot initialize dynamic array with non-empty literal', vd.Span);
           // emit const 0 -> store
           t0 := NewTemp;
           instr.Op := irConstInt; instr.Dest := t0; instr.ImmInt := 0; Emit(instr);
           instr.Op := irStoreLocal; instr.Dest := loc;     instr.Src1 := t0; Emit(instr); // ptr = 0
           instr.Op := irStoreLocal; instr.Dest := loc + 1; instr.Src1 := t0; Emit(instr); // len = 0
           instr.Op := irStoreLocal; instr.Dest := loc + 2; instr.Src1 := t0; Emit(instr); // cap = 0

        end

       else
       begin
         tmp := LowerExpr(vd.InitExpr);
         instr.Op := irStoreLocal; instr.Dest := loc; instr.Src1 := tmp; Emit(instr);
       end;
       Exit(True);
     end
      else if (vd.DeclType = atParallelArray) or (vd.InitExpr is TAstSIMDNew) then
      begin
        // ParallelArray: heap-allocated SIMD array, stored as a single pointer slot.
        // The initializer (TAstSIMDNew) lowers to irAlloc which returns a heap pointer.
        loc := AllocLocal(vd.Name, atParallelArray);
        tmp := LowerExpr(vd.InitExpr);
        instr.Op := irStoreLocal;
        instr.Dest := loc;
        instr.Src1 := tmp;
        Emit(instr);
        // Record element size for this local (needed by index access in backend)
        elemSize := 8; // default
        if vd.InitExpr is TAstSIMDNew then
        begin
          case TAstSIMDNew(vd.InitExpr).ElementType of
            atInt8, atUInt8:   elemSize := 1;
            atInt16, atUInt16: elemSize := 2;
            atInt32, atUInt32, atF32: elemSize := 4;
            atInt64, atUInt64, atF64: elemSize := 8;
          end;
        end;
        if loc >= Length(FLocalElemSize) then SetLength(FLocalElemSize, loc + 1);
        FLocalElemSize[loc] := elemSize;
        Exit(True);
      end
      else if (vd.DeclTypeName <> '') and
              (((FStructTypes.IndexOf(vd.DeclTypeName) >= 0) and
                (FStructTypes.Objects[FStructTypes.IndexOf(vd.DeclTypeName)] is TAstClassDecl)) or
               (Assigned(FClassTypes) and (FClassTypes.IndexOf(vd.DeclTypeName) >= 0))) then
      begin
        // Class type: allocate a single pointer slot for the object reference
        loc := AllocLocal(vd.Name, vd.DeclType);
        
        // Record the class name for VMT lookup
        if loc < Length(FLocalTypeNames) then
          FLocalTypeNames[loc] := vd.DeclTypeName;
        
        // Initialize with new expression if present
        if Assigned(vd.InitExpr) then
        begin
          tmp := LowerExpr(vd.InitExpr);
          if tmp >= 0 then
          begin
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end
        else
        begin
          // No initializer - initialize to 0 (null pointer)
          tmp := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irConstInt;
          instr.Dest := tmp;
          instr.ImmInt := 0;
          Emit(instr);
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
        end;
        Exit(True);
      end
      else if (vd.DeclTypeName <> '') and (FStructTypes.IndexOf(vd.DeclTypeName) >= 0) then
      begin
        // Struct type: allocate multiple slots on stack
        structIdx := FStructTypes.IndexOf(vd.DeclTypeName);
        sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
        structSlots := (sd.Size + 7) div 8;
        if structSlots < 1 then structSlots := 1;
        
        // Allocate stack slots for the struct
        loc := AllocLocalMany(vd.Name, vd.DeclType, structSlots, True);
        // Record the struct type name so field assignments can resolve offsets
        // for imported function bodies where sema hasn't annotated FieldOffset.
        if loc < Length(FLocalTypeNames) then
          FLocalTypeNames[loc] := vd.DeclTypeName;

        // Initialize with struct literal if present
        if vd.InitExpr is TAstStructLit then
        begin
          LowerStructLitIntoLocal(TAstStructLit(vd.InitExpr), loc, sd);
        end
        else if Assigned(vd.InitExpr) and (vd.InitExpr is TAstCall) then
        begin
          // Struct assignment from function call
          // Use special handling: emit irCallStruct which stores RAX and RDX
          call := TAstCall(vd.InitExpr);
          argCount := Length(call.Args);
          SetLength(argTemps, argCount);
          for i := 0 to High(call.Args) do
            argTemps[i] := LowerExpr(call.Args[i]);
          
          // Emit irCallStruct with dest being the local base slot
          instr := Default(TIRInstr);
          instr.Op := irCallStruct;
          instr.Dest := loc;  // Base local slot (not temp!)
          instr.ImmStr := call.Name;
          instr.ImmInt := argCount;
          instr.StructSize := structSlots * 8;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
        end
        else if Assigned(vd.InitExpr) then
        begin
          // Struct assignment from other expression
          tmp := LowerExpr(vd.InitExpr);
          if tmp >= 0 then
          begin
            // Copy first quadword to first slot
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end;
        Exit(True);
      end
      else if vd.DeclType = atArray then
      begin
        // Static array: allocate multiple slots on stack
        arrLen := vd.ArrayLen;
        if arrLen <= 0 then
        begin
          // Try to infer from initializer
          if vd.InitExpr is TAstArrayLit then
            arrLen := Length(TAstArrayLit(vd.InitExpr).Items)
          else
            FDiag.Error('static array requires explicit length or initializer', vd.Span);
        end;
        if arrLen > 0 then
        begin
          loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
          // Record array length for this local
          SetLength(FLocalArrayLen, loc + arrLen);
          for i := 0 to arrLen - 1 do
            FLocalArrayLen[loc + i] := arrLen;
          // Initialize with initializer if present
          if vd.InitExpr is TAstArrayLit then
          begin
            items := TAstArrayLit(vd.InitExpr).Items;
            if Length(items) <> arrLen then
              FDiag.Error('array literal length mismatch', vd.Span)
            else
            begin
              for i := 0 to High(items) do
              begin
                tmp := LowerExpr(items[i]);
                instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
              end;
            end;
          end
          else if Assigned(vd.InitExpr) then
          begin
            // Single expression: broadcast to all elements
            tmp := LowerExpr(vd.InitExpr);
            for i := 0 to arrLen - 1 do
            begin
              instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
            end;
          end;
        end;
        Exit(True);
      end
      else if vd.DeclType = atArray then
      begin
        // Static array: allocate multiple slots on stack
        arrLen := vd.ArrayLen;
        if arrLen <= 0 then
        begin
          if vd.InitExpr is TAstArrayLit then
            arrLen := Length(TAstArrayLit(vd.InitExpr).Items)
          else
            FDiag.Error('static array requires explicit length or initializer', vd.Span);
        end;
        if arrLen > 0 then
        begin
          loc := AllocLocalMany(vd.Name, vd.DeclType, arrLen);
          SetLength(FLocalArrayLen, loc + arrLen);
          for i := 0 to arrLen - 1 do
            FLocalArrayLen[loc + i] := arrLen;
          if vd.InitExpr is TAstArrayLit then
          begin
            items := TAstArrayLit(vd.InitExpr).Items;
            if Length(items) <> arrLen then
              FDiag.Error('array literal length mismatch', vd.Span)
            else
            begin
              for i := 0 to High(items) do
              begin
                tmp := LowerExpr(items[i]);
                instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
              end;
            end;
          end
          else if Assigned(vd.InitExpr) then
          begin
            tmp := LowerExpr(vd.InitExpr);
            for i := 0 to arrLen - 1 do
            begin
              instr.Op := irStoreLocal; instr.Dest := loc + i; instr.Src1 := tmp; Emit(instr);
            end;
          end;
        end;
        Exit(True);
      end
      // Check for function pointer: either explicit atFnPtr type OR unresolved with function name as initializer
      // This handles the case where type declarations aren't resolved in sema.
      // Exclude the case where the initializer is a compile-time constant (e.g. enum value) —
      // those must not be treated as function addresses.
      else if (vd.DeclType = atFnPtr) or
              ((vd.DeclType = atUnresolved) and (vd.DeclTypeName <> '') and
               Assigned(vd.InitExpr) and (vd.InitExpr is TAstIdent) and
               (FConstMap.IndexOf(TAstIdent(vd.InitExpr).Name) < 0)) then
      begin
        // Function pointer: allocate one slot and initialize with function address
        loc := AllocLocal(vd.Name, atFnPtr);  // Use atFnPtr for function pointers
        
        // Check if initializer is a function identifier
        if Assigned(vd.InitExpr) and (vd.InitExpr is TAstIdent) then
        begin
          // Function name as initializer - load function address
          // Use irLoadGlobalAddr to get the function address
          // First load into a temp, then store to local slot
          tmp := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irLoadGlobalAddr;
          instr.Dest := tmp;
          instr.ImmStr := TAstIdent(vd.InitExpr).Name;
          Emit(instr);
          // Store to local slot
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
        end
        else if Assigned(vd.InitExpr) then
        begin
          // Other initializer - lower it normally
          tmp := LowerExpr(vd.InitExpr);
          if tmp >= 0 then
          begin
            instr.Op := irStoreLocal;
            instr.Dest := loc;
            instr.Src1 := tmp;
            Emit(instr);
          end;
        end
        else
        begin
          // No initializer - initialize to 0 (null function pointer)
          tmp := NewTemp;
          instr := Default(TIRInstr);
          instr.Op := irConstInt;
          instr.Dest := tmp;
          instr.ImmInt := 0;
          Emit(instr);
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
        end;
        Exit(True);
      end
      else
      begin
        // scalar local
       loc := AllocLocal(vd.Name, SubstType(vd.DeclType, vd.DeclTypeName));
       // Store type name so range checks can be emitted at assignment sites
       if (vd.DeclTypeName <> '') and (loc < Length(FLocalTypeNames)) then
         FLocalTypeNames[loc] := vd.DeclTypeName;
       // Bootstrap compat: if initializer is a cast to a class (e.g. var cfg: int64 := obj as CompilerConfig),
       // record the cast target class name so method calls can be resolved via _L_ClassName_MethodName.
       if Assigned(vd.InitExpr) and (vd.InitExpr is TAstCast) then
       begin
         if (TAstCast(vd.InitExpr).CastTypeName <> '') and
            (FClassTypes.IndexOf(TAstCast(vd.InitExpr).CastTypeName) >= 0) then
         begin
           if loc >= Length(FLocalTypeNames) then SetLength(FLocalTypeNames, loc + 1);
           FLocalTypeNames[loc] := TAstCast(vd.InitExpr).CastTypeName;
         end;
       end;
       // If initializer is constant integer and the local has narrower signed width, constant fold
       if (vd.InitExpr is TAstIntLit) then
       begin
         lit := TAstIntLit(vd.InitExpr).Value;
         ltype := GetLocalType(loc);
         if (ltype <> atUnresolved) and (ltype <> atInt64) then
         begin
           // determine width in bits
           width := 64;
           case ltype of
             atInt8, atUInt8: width := 8;
             atInt16, atUInt16: width := 16;
             atInt32, atUInt32: width := 32;
             atInt64, atUInt64: width := 64;
           end;
           mask64 := (UInt64(1) shl width) - 1;
           truncated := UInt64(lit) and mask64;
           if (ltype in [atInt8, atInt16, atInt32, atInt64]) then
           begin
             // signed interpretation
             half := UInt64(1) shl (width - 1);
             if truncated >= half then
               signedVal := Int64(truncated) - Int64(UInt64(1) shl width)
             else
               signedVal := Int64(truncated);
             // record local constant for future loads instead of emitting store
             cvLocal := TConstValue.Create;
             cvLocal.IsStr := False;
             cvLocal.IntVal := signedVal;
             if loc >= Length(FLocalConst) then SetLength(FLocalConst, loc+1);
             FLocalConst[loc] := cvLocal;
           end
           else
           begin
             // unsigned: record local constant zero-extended value
             cvLocal := TConstValue.Create;
             cvLocal.IsStr := False;
             cvLocal.IntVal := Int64(truncated);
             if loc >= Length(FLocalConst) then SetLength(FLocalConst, loc+1);
             FLocalConst[loc] := cvLocal;
           end;
           Exit(True);
         end;
       end;
        tmp := LowerExpr(vd.InitExpr);
        // If local has narrower integer width, truncate before store
        // Skip truncation for pointer-like types (Map, Set, DynArray)
        ltype := GetLocalType(loc);
        if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64)
           and (ltype <> atPChar) and (ltype <> atPCharNullable)
           and (ltype <> atMap) and (ltype <> atSet) and (ltype <> atDynArray)
           and (ltype <> atParallelArray) then
        begin
         // determine width in bits
         width := 64;
         case ltype of
           atInt8, atUInt8: width := 8;
           atInt16, atUInt16: width := 16;
           atInt32, atUInt32: width := 32;
           atInt64, atUInt64: width := 64;
         end;
         instr.Op := irTrunc; instr.Dest := NewTemp; instr.Src1 := tmp; instr.ImmInt := width; Emit(instr);
         tmp := instr.Dest;
       end;
       // Emit runtime range check if this variable has a range type (aerospace-todo P1 #7)
       if (vd.DeclTypeName <> '') and Assigned(FRangeTypes) then
       begin
         rtIdx := FRangeTypes.IndexOf(vd.DeclTypeName);
         if rtIdx >= 0 then
         begin
           rtDecl := TAstTypeDecl(FRangeTypes.Objects[rtIdx]);
           EmitRangeCheck(tmp, rtDecl.RangeMin, rtDecl.RangeMax, vd.DeclTypeName, vd.Span);
         end;
       end;
       instr.Op := irStoreLocal;
       instr.Dest := loc;
       instr.Src1 := tmp;
       Emit(instr);
       Exit(True);
     end;
   end;


    if stmt is TAstAssign then
    begin
      // Check if it's a global variable assignment
      if IsGlobalVar(TAstAssign(stmt).Name) then
      begin
        tmp := LowerExpr(TAstAssign(stmt).Value);
        instr.Op := irStoreGlobal;
        instr.ImmStr := TAstAssign(stmt).Name;
        instr.Src1 := tmp;
        Emit(instr);
        Exit(True);
      end;
      
      loc := ResolveLocal(TAstAssign(stmt).Name);
      if loc < 0 then
      begin
        FDiag.Error('assignment to undeclared variable: ' + TAstAssign(stmt).Name, stmt.Span);
        Exit(False);
      end;
      // invalidate any const-folded value for this local
      if (loc < Length(FLocalConst)) and Assigned(FLocalConst[loc]) then
      begin
        FLocalConst[loc].Free;
        FLocalConst[loc] := nil;
      end;
      // Special case: assigning a struct-returning function call to a struct local
      // Must use irCallStruct (sret ABI) instead of irCall (scalar RAX return)
      if (TAstAssign(stmt).Value is TAstCall) and
         (loc < Length(FLocalIsStruct)) and FLocalIsStruct[loc] and
         (loc < Length(FLocalTypeNames)) and (FLocalTypeNames[loc] <> '') then
      begin
        structIdx := FStructTypes.IndexOf(FLocalTypeNames[loc]);
        if structIdx >= 0 then
        begin
          sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
          call := TAstCall(TAstAssign(stmt).Value);
          argCount := Length(call.Args);
          SetLength(argTemps, argCount);
          for i := 0 to High(call.Args) do
            argTemps[i] := LowerExpr(call.Args[i]);
          instr := Default(TIRInstr);
          instr.Op := irCallStruct;
          instr.Dest := loc;
          instr.ImmStr := call.Name;
          instr.ImmInt := argCount;
          instr.StructSize := sd.Size;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
          Exit(True);
        end;
      end;
      tmp := LowerExpr(TAstAssign(stmt).Value);
      // truncate if local has narrower integer width
      ltype := GetLocalType(loc);
      if (ltype <> atUnresolved) and (ltype <> atInt64) and (ltype <> atUInt64) 
         and (ltype <> atPChar) and (ltype <> atPCharNullable)
         and (ltype <> atMap) and (ltype <> atSet) and (ltype <> atDynArray) then
      begin
        width := 64;
        case ltype of
          atInt8, atUInt8: width := 8;
          atInt16, atUInt16: width := 16;
          atInt32, atUInt32: width := 32;
        end;
        instr.Op := irTrunc; instr.Dest := NewTemp; instr.Src1 := tmp;
        instr.ImmInt := width; Emit(instr);
        tmp := instr.Dest;
      end;
      // Emit runtime range check for range-typed local (aerospace-todo P1 #7)
      if Assigned(FRangeTypes) and (loc < Length(FLocalTypeNames)) and (FLocalTypeNames[loc] <> '') then
      begin
        rtIdx2 := FRangeTypes.IndexOf(FLocalTypeNames[loc]);
        if rtIdx2 >= 0 then
        begin
          rtDecl2 := TAstTypeDecl(FRangeTypes.Objects[rtIdx2]);
          EmitRangeCheck(tmp, rtDecl2.RangeMin, rtDecl2.RangeMax, FLocalTypeNames[loc], stmt.Span);
        end;
      end;
      instr.Op := irStoreLocal;
      instr.Dest := loc;
      instr.Src1 := tmp;
      Emit(instr);
      Exit(True);
    end;

    // field assignment: obj.field := value
    if stmt is TAstFieldAssign then
    begin
      fa := TAstFieldAssign(stmt);
      // target is a TAstFieldAccess node
      
      // For nested field access like o.x.a, we need to find the root struct
      // and use the combined offset. The Sema has already calculated the
      // combined offset in fa.Target.FieldOffset.
      
      // Walk up the chain of field accesses to find the root (non-field) expression
      baseExpr := fa.Target.Obj;
      while (baseExpr is TAstFieldAccess) do
        baseExpr := TAstFieldAccess(baseExpr).Obj;
      
      // Now lower the root expression (e.g., 'o' in 'o.x.a')
      t1 := LowerExpr(baseExpr);
      if t1 < 0 then Exit(False);
      t2 := LowerExpr(fa.Value);
      if t2 < 0 then Exit(False);
      
      // Check if target's owner is a class (heap) or struct (stack)
      ownerName := fa.Target.OwnerName;
      fldOffset := fa.Target.FieldOffset;
      fldType := fa.Target.FieldType;
      // If sema didn't annotate the field offset (imported class method bodies),
      // resolve it now.  Determine receiver class: 'self' → FCurrentClassDecl,
      // named local → FLocalTypeNames lookup.
      if fldOffset < 0 then
      begin
        // First: try struct type lookup via FStructTypes (for imported function bodies
        // where sema hasn't annotated FieldOffset on the AST node).
        if (baseExpr is TAstIdent) then
        begin
          i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
          if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocalTypeNames)) and
             (FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])] <> '') then
          begin
            structIdx := FStructTypes.IndexOf(FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])]);
            if structIdx >= 0 then
            begin
              sd := TAstStructDecl(FStructTypes.Objects[structIdx]);
              ownerName := sd.Name;
              if Length(sd.FieldOffsets) = Length(sd.Fields) then
                for fi := 0 to High(sd.Fields) do
                begin
                  if sd.Fields[fi].Name = fa.Target.Field then
                  begin
                    fldOffset := sd.FieldOffsets[fi];
                    fldType := sd.Fields[fi].FieldType;
                    Break;
                  end;
                end;
            end;
          end;
        end;

        // Second: try class type lookup (for class method bodies)
        if fldOffset < 0 then
        begin
          cd := nil;
          if (baseExpr is TAstIdent) and (TAstIdent(baseExpr).Name <> 'self') then
          begin
            i := FLocalMap.IndexOf(TAstIdent(baseExpr).Name);
            if (i >= 0) and (ObjToInt(FLocalMap.Objects[i]) < Length(FLocalTypeNames)) and
               (FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])] <> '') then
            begin
              j := FClassTypes.IndexOf(FLocalTypeNames[ObjToInt(FLocalMap.Objects[i])]);
              if j >= 0 then
                cd := TAstClassDecl(FClassTypes.Objects[j]);
            end;
          end;
          if (cd = nil) and Assigned(FCurrentClassDecl) then
            cd := FCurrentClassDecl;
          if Assigned(cd) then
            ownerName := cd.Name;
          while Assigned(cd) do
          begin
            for fi := 0 to High(cd.Fields) do
            begin
              if cd.Fields[fi].Name = fa.Target.Field then
              begin
                fldOffset := cd.FieldOffsets[fi];
                fldType := cd.Fields[fi].FieldType;
                Break;
              end;
            end;
            if fldOffset >= 0 then Break;
            if cd.BaseClassName <> '' then
            begin
              i := FClassTypes.IndexOf(cd.BaseClassName);
              if i >= 0 then cd := TAstClassDecl(FClassTypes.Objects[i])
              else cd := nil;
            end
            else cd := nil;
          end;
        end;
      end;
      if (ownerName <> '') and (FClassTypes.IndexOf(ownerName) >= 0) then
      begin
        // Class: use positive offset (heap access)
        instr.Op := irStoreFieldHeap;
        instr.Src1 := t1; // base pointer (heap address)
        instr.Src2 := t2; // value temp
        if fldOffset >= 0 then
          instr.ImmInt := fldOffset // positive offset for heap
        else
          instr.LabelName := fa.Target.Field;
        instr.FieldSize := TypeSizeBytes(fldType);
        Emit(instr);
      end
      else
      begin
        // Struct: use negative offset (stack access)
        instr.Op := irStoreField;
        instr.Src1 := t1; // base pointer
        instr.Src2 := t2; // value temp
        if fldOffset >= 0 then
          instr.ImmInt := fldOffset
        else
          instr.LabelName := fa.Target.Field;
        instr.FieldSize := TypeSizeBytes(fldType);
        Emit(instr);
      end;
      Exit(True);
    end;

    // index assignment: arr[idx] := value
    if stmt is TAstIndexAssign then
    begin
      // Check if this is a Map assignment (map[key] := value)
      if TAstIndexAssign(stmt).Target.Obj.ResolvedType = atMap then
      begin
        // Map assignment: map[key] := value -> irMapSet(map, key, value)

        // Lower the map (object)
        t1 := LowerExpr(TAstIndexAssign(stmt).Target.Obj);
        if t1 < 0 then Exit(False);

        // Lower the key
        t2 := LowerExpr(TAstIndexAssign(stmt).Target.Index);
        if t2 < 0 then Exit(False);

        // Lower the value
        t0 := LowerExpr(TAstIndexAssign(stmt).Value);
        if t0 < 0 then Exit(False);

        // Emit map_set(map, key, value)
        instr := Default(TIRInstr);
        instr.Op := irMapSet;
        instr.Src1 := t1;  // map
        instr.Src2 := t2;  // key
        instr.Src3 := t0;  // value
        Emit(instr);
        Exit(True);
      end;

      // Check if this is a Set (not supported for assignment)
      if TAstIndexAssign(stmt).Target.Obj.ResolvedType = atSet then
      begin
        FDiag.Error('sets are not indexable, cannot assign to set elements', stmt.Span);
        Exit(False);
      end;

      // Regular array assignment
      // t1 = base array/pointer
      // Check if target is a global array - need address, not value
      if (TAstIndexAssign(stmt).Target.Obj is TAstIdent) and
         IsGlobalVar(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name) then
      begin
        // For global arrays: load the ADDRESS
        t1 := NewTemp;
        instr.Op := irLoadGlobalAddr;
        instr.Dest := t1;
        instr.ImmStr := TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name;
        Emit(instr);
      end
      else
      begin
        // Local array: need to load ADDRESS of array base, not value
        if TAstIndexAssign(stmt).Target.Obj is TAstIdent then
        begin
          loc := ResolveLocal(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
          if loc >= 0 then
          begin
            // ParallelArray: heap pointer stored in single slot - load pointer directly
            if GetLocalType(loc) = atParallelArray then
            begin
              t1 := NewTemp;
              instr.Op := irLoadLocal;
              instr.Dest := t1;
              instr.Src1 := loc;
              Emit(instr);
            end
            else
            begin
            // Array elements are stored in reverse order on stack.
            // arr[0] is at slot loc + arrayLen - 1, arr[arrayLen-1] is at slot loc.
            // Load address of arr[0] (highest slot) so base + index*8 works correctly.
            arrLen := GetLocalArrayLen(loc);
            if arrLen > 0 then
              baseSlot := loc + arrLen - 1  // base address points to arr[0]
            else
              baseSlot := loc;  // fallback for non-array locals
            
            t1 := NewTemp;
            instr.Op := irLoadLocalAddr;
            instr.Dest := t1;
            instr.Src1 := baseSlot;
            Emit(instr);
            end;
          end
          else
          begin
            // Fallback: use normal LowerExpr
            t1 := LowerExpr(TAstIndexAssign(stmt).Target.Obj);
            if t1 < 0 then Exit(False);
          end;
        end
        else
        begin
          // Non-identifier: use normal LowerExpr
          t1 := LowerExpr(TAstIndexAssign(stmt).Target.Obj);
          if t1 < 0 then Exit(False);
        end;
      end;
      
      // t2 = index expression
      t2 := LowerExpr(TAstIndexAssign(stmt).Target.Index);
      if t2 < 0 then Exit(False);
      // t0 = value to store
      t0 := LowerExpr(TAstIndexAssign(stmt).Value);
      if t0 < 0 then Exit(False);

       // check if index is a constant for static vs dynamic store
       if TAstIndexAssign(stmt).Target.Index is TAstIntLit then
       begin
         // static index: use irStoreElem with ImmInt, but first check compile-time bounds if available
         staticIdx := TAstIntLit(TAstIndexAssign(stmt).Target.Index).Value;
         // check global array length
         if (TAstIndexAssign(stmt).Target.Obj is TAstIdent) and IsGlobalVar(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name) then
         begin
           gv := GetGlobalVarDecl(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
           if Assigned(gv) and (gv.ArrayLen > 0) and (staticIdx >= gv.ArrayLen) then
           begin
             FDiag.Error('array index out of bounds (static)', stmt.Span);
           end
           else
           begin
             instr.Op := irStoreElem; instr.Src1 := t1; instr.Src2 := t0; instr.ImmInt := staticIdx; Emit(instr);
           end;
         end
         else
         begin
           // local array
           if (loc >= 0) and (GetLocalArrayLen(loc) > 0) and (staticIdx >= GetLocalArrayLen(loc)) then
           begin
             FDiag.Error('array index out of bounds (static)', stmt.Span);
           end
           else
           begin
             instr.Op := irStoreElem; instr.Src1 := t1; instr.Src2 := t0; instr.ImmInt := staticIdx; Emit(instr);
           end;
         end;
       end
       else
       begin
         // dynamic index: attempt runtime bounds check if length known
         gv := nil;
         if (TAstIndexAssign(stmt).Target.Obj is TAstIdent) and IsGlobalVar(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name) then
           gv := GetGlobalVarDecl(TAstIdent(TAstIndexAssign(stmt).Target.Obj).Name);
          if Assigned(gv) and (gv.ArrayLen > 0) then
          begin
            // emit runtime check for global array - use two separate branches
            tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
            tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := gv.ArrayLen; Emit(instr);
            // Check idx < 0
            tLtZero := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtZero; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
            errLbl := NewLabel('Larr_oob'); instr.Op := irBrTrue; instr.Src1 := tLtZero; instr.LabelName := errLbl; Emit(instr);
            // Check idx >= len
            tGeLen := NewTemp; instr.Op := irCmpGe; instr.Dest := tGeLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
            instr.Op := irBrTrue; instr.Src1 := tGeLen; instr.LabelName := errLbl; Emit(instr);

             instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

            skipLbl := NewLabel('Larr_ok');
            instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
            instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
            msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
            codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
            instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
          end
          else if (loc >= 0) and (GetLocalArrayLen(loc) > 0) then
          begin
            // emit runtime check for local array - use two separate branches
            tZero := NewTemp; instr.Op := irConstInt; instr.Dest := tZero; instr.ImmInt := 0; Emit(instr);
            tLen := NewTemp; instr.Op := irConstInt; instr.Dest := tLen; instr.ImmInt := GetLocalArrayLen(loc); Emit(instr);
            // Check idx < 0
            tLtZero := NewTemp; instr.Op := irCmpLt; instr.Dest := tLtZero; instr.Src1 := t2; instr.Src2 := tZero; Emit(instr);
            errLbl := NewLabel('Larr_oob'); instr.Op := irBrTrue; instr.Src1 := tLtZero; instr.LabelName := errLbl; Emit(instr);
            // Check idx >= len
            tGeLen := NewTemp; instr.Op := irCmpGe; instr.Dest := tGeLen; instr.Src1 := t2; instr.Src2 := tLen; Emit(instr);
            instr.Op := irBrTrue; instr.Src1 := tGeLen; instr.LabelName := errLbl; Emit(instr);

            instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);

            skipLbl := NewLabel('Larr_ok');
            instr.Op := irJmp; instr.LabelName := skipLbl; Emit(instr);
            instr.Op := irLabel; instr.LabelName := errLbl; Emit(instr);
            msgTmp := NewTemp; instr.Op := irConstStr; instr.Dest := msgTmp; instr.ImmStr := IntToStr(FModule.InternString('Array index out of bounds')); Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'PrintStr'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := msgTmp; Emit(instr);
            codeTmp := NewTemp; instr.Op := irConstInt; instr.Dest := codeTmp; instr.ImmInt := 1; Emit(instr);
            instr.Op := irCallBuiltin; instr.Dest := -1; instr.ImmStr := 'exit'; instr.ImmInt := 1; SetLength(instr.ArgTemps,1); instr.ArgTemps[0] := codeTmp; Emit(instr);
            instr.Op := irLabel; instr.LabelName := skipLbl; Emit(instr);
          end
         else
         begin
           // no bounds info, emit dynamic store
           instr.Op := irStoreElemDyn; instr.Src1 := t1; instr.Src2 := t2; instr.Src3 := t0; Emit(instr);
        end;
      end;
      Exit(True);
    end;

    // if (cond) { thenBranch } [else { elseBranch }]
    if stmt is TAstIf then
    begin
      condTmp := LowerExpr(TAstIf(stmt).Cond);
      if condTmp < 0 then Exit(False);

      if Assigned(TAstIf(stmt).ElseBranch) then
      begin
        // if-else: brfalse to else, then to end
        elseLabel := NewLabel('Lelse');
        endLabel := NewLabel('Lendif');

        instr := Default(TIRInstr);
        instr.Op := irBrFalse;
        instr.Src1 := condTmp;
        instr.LabelName := elseLabel;
        Emit(instr);

        // then branch
        LowerStmt(TAstIf(stmt).ThenBranch);

        // jump to end
        instr := Default(TIRInstr);
        instr.Op := irJmp;
        instr.LabelName := endLabel;
        Emit(instr);

        // else label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := elseLabel;
        Emit(instr);

        // else branch
        LowerStmt(TAstIf(stmt).ElseBranch);

        // end label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := endLabel;
        Emit(instr);
      end
      else
      begin
        // if without else: brfalse to end
        endLabel := NewLabel('Lendif');

        instr := Default(TIRInstr);
        instr.Op := irBrFalse;
        instr.Src1 := condTmp;
        instr.LabelName := endLabel;
        Emit(instr);

        // then branch
        LowerStmt(TAstIf(stmt).ThenBranch);

        // end label
        instr := Default(TIRInstr);
        instr.Op := irLabel;
        instr.LabelName := endLabel;
        Emit(instr);
      end;
      Exit(True);
    end;

    // while (cond) { body }
    if stmt is TAstWhile then
    begin
      startLabel := NewLabel('Lwhile_start');
      exitLabel := NewLabel('Lwhile_exit');

      // start label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := startLabel;
      Emit(instr);

      // evaluate condition
      condTmp := LowerExpr(TAstWhile(stmt).Cond);
      if condTmp < 0 then Exit(False);

      // brfalse to exit
      instr := Default(TIRInstr);
      instr.Op := irBrFalse;
      instr.Src1 := condTmp;
      instr.LabelName := exitLabel;
      Emit(instr);

      // push break/continue labels
      FBreakStack.AddObject(exitLabel, nil);
      FContinueStack.AddObject(startLabel, nil);

      // body
      LowerStmt(TAstWhile(stmt).Body);

      // pop break/continue labels
      FBreakStack.Delete(FBreakStack.Count - 1);
      FContinueStack.Delete(FContinueStack.Count - 1);

      // jump back to start
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := startLabel;
      Emit(instr);

      // exit label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := exitLabel;
      Emit(instr);

      Exit(True);
    end;

    // return [expr];
    if stmt is TAstReturn then
    begin
      if Assigned(TAstReturn(stmt).Value) then
      begin
        // Check if returning a struct variable directly
        if (TAstReturn(stmt).Value is TAstIdent) then
        begin
          loc := ResolveLocal(TAstIdent(TAstReturn(stmt).Value).Name);
          if (loc >= 0) and (loc < Length(FLocalIsStruct)) and FLocalIsStruct[loc] then
          begin
            // Get struct slot count
            slotCount := 1;
            if loc < Length(FLocalSlotCount) then
              slotCount := FLocalSlotCount[loc];
            if slotCount < 1 then slotCount := 1;

            // Struct return: use irReturnStruct with base local slot
            instr := Default(TIRInstr);
            instr.Op := irReturnStruct;
            instr.Src1 := loc;  // Base local slot index
            instr.StructSize := slotCount * 8;  // Size in bytes
            Emit(instr);
            Exit(True);
          end;
        end;

        // Check if returning a tuple literal: return (a, b)
        if (TAstReturn(stmt).Value is TAstTupleLit) then
        begin
          // Allocate two consecutive slots in reverse order so irReturnStruct works:
          //   irReturnStruct(Src1=loc_b): RAX←slot[loc_b+1]=loc_a, RDX←slot[loc_b]=loc_b
          loc := AllocLocal('_retb_' + IntToStr(FLabelCounter), atInt64);  // slot N
          AllocLocal('_reta_' + IntToStr(FLabelCounter), atInt64);          // slot N+1
          Inc(FLabelCounter);
          // lower first element → store into slot N+1 (loc+1)
          t0 := LowerExpr(TAstTupleLit(TAstReturn(stmt).Value).Elems[0]);
          instr := Default(TIRInstr);
          instr.Op := irStoreLocal;
          instr.Dest := loc + 1;
          instr.Src1 := t0;
          Emit(instr);
          // lower second element → store into slot N (loc)
          tmp := LowerExpr(TAstTupleLit(TAstReturn(stmt).Value).Elems[1]);
          instr := Default(TIRInstr);
          instr.Op := irStoreLocal;
          instr.Dest := loc;
          instr.Src1 := tmp;
          Emit(instr);
          // emit irReturnStruct with base=loc, size=16
          instr := Default(TIRInstr);
          instr.Op := irReturnStruct;
          instr.Src1 := loc;
          instr.StructSize := 16;
          Emit(instr);
          Exit(True);
        end;

        // Check if returning a struct from a function call (return someFunc(args...))
        // Without this, the call would be lowered via irCall (scalar return) instead of
        // irCallStruct (sret ABI), corrupting registers and memory.
        if (TAstReturn(stmt).Value is TAstCall) and (FCurrentFunc.ReturnStructSize > 16) then
        begin
          sd := GetReturnStructDecl;
          if Assigned(sd) then
          begin
            call := TAstCall(TAstReturn(stmt).Value);
            argCount := Length(call.Args);
            SetLength(argTemps, argCount);
            for i := 0 to argCount - 1 do
              argTemps[i] := LowerExpr(call.Args[i]);
            structSlots := (sd.Size + 7) div 8;
            if structSlots < 1 then structSlots := 1;
            loc := AllocLocalMany('_retcall_' + IntToStr(FLabelCounter), atUnresolved, structSlots, True);
            Inc(FLabelCounter);
            instr := Default(TIRInstr);
            instr.Op := irCallStruct;
            instr.Dest := loc;
            instr.ImmStr := call.Name;
            instr.ImmInt := argCount;
            instr.StructSize := sd.Size;
            instr.CallMode := cmInternal;
            SetLength(instr.ArgTemps, argCount);
            for i := 0 to argCount - 1 do
              instr.ArgTemps[i] := argTemps[i];
            Emit(instr);
            instr := Default(TIRInstr);
            instr.Op := irReturnStruct;
            instr.Src1 := loc;
            instr.StructSize := sd.Size;
            Emit(instr);
            Exit(True);
          end;
        end;

        // Check if returning a struct literal (e.g. return Pair { a: x, b: y })
        if (TAstReturn(stmt).Value is TAstStructLit) then
        begin
          sd := GetReturnStructDecl;
          if Assigned(sd) then
          begin
            structSlots := (sd.Size + 7) div 8;
            if structSlots < 1 then structSlots := 1;
            // Allocate local slots for the return struct and fill via field stores
            loc := AllocLocalMany('_retval_' + IntToStr(FLabelCounter), atUnresolved, structSlots, True);
            LowerStructLitIntoLocal(TAstStructLit(TAstReturn(stmt).Value), loc, sd);
            // Return via irReturnStruct so backend uses RAX/RDX correctly
            instr := Default(TIRInstr);
            instr.Op := irReturnStruct;
            instr.Src1 := loc;
            instr.StructSize := structSlots * 8;
            Emit(instr);
            Exit(True);
          end;
        end;

        // Normal return (non-struct or expression)
        tmp := LowerExpr(TAstReturn(stmt).Value);
        if tmp < 0 then Exit(False);
        instr := Default(TIRInstr);
        instr.Op := irFuncExit;
        instr.Src1 := tmp;
        Emit(instr);
      end
      else
      begin
        instr := Default(TIRInstr);
        instr.Op := irFuncExit;
        instr.Src1 := -1; // void return
        Emit(instr);
      end;
      Exit(True);
    end;

    // break;
    if stmt is TAstBreak then
    begin
      if FBreakStack.Count = 0 then
      begin
        FDiag.Error('break statement outside of loop', stmt.Span);
        Exit(False);
      end;
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := FBreakStack[FBreakStack.Count - 1];
      Emit(instr);
      Exit(True);
    end;

    // continue;
    if stmt is TAstContinue then
    begin
      if FContinueStack.Count = 0 then
      begin
        FDiag.Error('continue statement outside of loop', stmt.Span);
        Exit(False);
      end;
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := FContinueStack[FContinueStack.Count - 1];
      Emit(instr);
      Exit(True);
    end;

    // assert(cond, msg); - expand to if (!cond) { panic(msg); }
    if stmt is TAstAssert then
    begin
      // Lower: if (!condition) panic(message);
      cond := LowerExpr(TAstAssert(stmt).Condition);
      if cond < 0 then Exit(False);
      msg := LowerExpr(TAstAssert(stmt).Message);
      if msg < 0 then Exit(False);

      skipLbl := NewLabel('Lassert_ok');
      // if cond is true, jump to skip (use irBrTrue to jump if condition is true)
      instr := Default(TIRInstr);
      instr.Op := irBrTrue; // jump if true -> skip panic
      instr.Src1 := cond;
      instr.LabelName := skipLbl;
      Emit(instr);

      // panic(msg);
      instr := Default(TIRInstr);
      instr.Op := irPanic;
      instr.Src1 := msg;
      // Store string length in ImmInt for the backend
      if TAstAssert(stmt).Message is TAstStrLit then
        instr.ImmInt := Length(TAstStrLit(TAstAssert(stmt).Message).Value)
      else
        instr.ImmInt := 0; // Will need runtime strlen
      Emit(instr);

      // skip label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := skipLbl;
      Emit(instr);
      Exit(True);
    end;

    if stmt is TAstSwitch then
   begin
     // Lower switch by generating compares and branches
      sw := TAstSwitch(stmt);
      switchTmp := LowerExpr(sw.Expr);
      endLbl := NewLabel('Lswitch_end');
      defaultLbl := endLbl;
      if Assigned(sw.Default) then
        defaultLbl := NewLabel('Lswitch_default');

      // For each case, create label and compare
      caseLabels := TStringList.Create; try
        for i := 0 to High(sw.Cases) do
        begin
          lbl := NewLabel('Lcase');
          caseLabels.Add(lbl);
          // lower case value
          caseTmp := LowerExpr(sw.Cases[i].Value);
          // cmp eq
          instr.Op := irCmpEq; instr.Dest := NewTemp; instr.Src1 := switchTmp; instr.Src2 := caseTmp; Emit(instr);
          // br true -> caseLbl
          instr.Op := irBrTrue; instr.Src1 := instr.Dest; instr.LabelName := lbl; Emit(instr);
          // OR pattern extra values
          for j := 0 to High(sw.Cases[i].ExtraValues) do
          begin
            caseTmp := LowerExpr(sw.Cases[i].ExtraValues[j]);
            instr.Op := irCmpEq; instr.Dest := NewTemp; instr.Src1 := switchTmp; instr.Src2 := caseTmp; Emit(instr);
            instr.Op := irBrTrue; instr.Src1 := instr.Dest; instr.LabelName := lbl; Emit(instr);
          end;
        end;


       // no match -> jump default or end
       instr.Op := irJmp; instr.LabelName := defaultLbl; Emit(instr);

       // emit case bodies
       for i := 0 to High(sw.Cases) do
       begin
         instr.Op := irLabel; instr.LabelName := caseLabels[i]; Emit(instr);
         // push break label for cases
         FBreakStack.AddObject(endLbl, nil);
         LowerStmt(sw.Cases[i].Body);
         FBreakStack.Delete(FBreakStack.Count - 1);
         // after case body, jump to end
         instr.Op := irJmp; instr.LabelName := endLbl; Emit(instr);
       end;

       // default body
       if Assigned(sw.Default) then
       begin
         instr.Op := irLabel; instr.LabelName := defaultLbl; Emit(instr);
         FBreakStack.AddObject(endLbl, nil);
         LowerStmt(sw.Default);
         FBreakStack.Delete(FBreakStack.Count - 1);
         instr.Op := irJmp; instr.LabelName := endLbl; Emit(instr);
       end;

       // end label
       instr.Op := irLabel; instr.LabelName := endLbl; Emit(instr);
      finally
        caseLabels.Free;
      end;
      Exit(True);
    end;

    // pool { ... } - Memory Pool Block
    if stmt is TAstPoolStmt then
    begin
      // Pool-Block: Allokiere Pool-Speicher am Anfang und gib ihn am Ende frei
      // Für jetzt: Pool direkt als normalen Block behandeln
      // Die IR-Operationen irPoolAlloc/irPoolFree werden vom Backend verwendet
      LowerStmt(TAstPoolStmt(stmt).Body);
      Exit(True);
    end;

    // dispose expr; - free heap-allocated class instance
    if stmt is TAstDispose then
    begin
      // Lower the expression - this returns a temp index
      // For identifiers, this returns the slot index, which is fine for irLoadLocal
      t0 := LowerExpr(TAstDispose(stmt).Expr);
      if t0 < 0 then Exit(False);
      
      // Emit irFree instruction
      // The temp value t0 contains the pointer to free
      instr := Default(TIRInstr);
      instr.Op := irFree;
      instr.Src1 := t0;
      instr.ImmInt := 0;  // Default size handling in backend
      Emit(instr);
      Exit(True);
    end;

    // Nested function — lower inline as a separate function in the module
    if stmt is TAstFuncStmt then
    begin
      LowerNestedFunc(TAstFuncStmt(stmt).FuncDecl);
      Exit(True);
    end;

    // try { body } catch (e: int64) { handler }
    if stmt is TAstTry then
    begin
      // catch label is the jump target when an exception is thrown
      thenLabel := NewLabel('Lcatch');
      // end label is after the catch block
      elseLabel := NewLabel('Ltry_end');

      // irPushHandler: tells backend to call setjmp and jump to thenLabel on throw
      instr := Default(TIRInstr);
      instr.Op := irPushHandler;
      instr.LabelName := thenLabel;
      Emit(instr);

      // lower try body
      LowerStmt(TAstTry(stmt).TryBody);

      // irPopHandler: remove handler frame (normal path)
      instr := Default(TIRInstr);
      instr.Op := irPopHandler;
      Emit(instr);

      // jump past the catch block
      instr := Default(TIRInstr);
      instr.Op := irJmp;
      instr.LabelName := elseLabel;
      Emit(instr);

      // catch label: exception occurred
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := thenLabel;
      Emit(instr);

      // irPopHandler: remove handler frame (exception path)
      instr := Default(TIRInstr);
      instr.Op := irPopHandler;
      Emit(instr);

      // allocate the catch variable slot and load exception value into it
      loc := AllocLocal(TAstTry(stmt).CatchVar, atInt64);
      instr := Default(TIRInstr);
      instr.Op := irLoadHandlerExn;
      instr.Dest := loc;
      Emit(instr);

      // lower catch body
      LowerStmt(TAstTry(stmt).CatchBody);

      // end label
      instr := Default(TIRInstr);
      instr.Op := irLabel;
      instr.LabelName := elseLabel;
      Emit(instr);

      Exit(True);
    end;

    // throw expr;
    if stmt is TAstThrow then
    begin
      t0 := LowerExpr(TAstThrow(stmt).Value);
      if t0 < 0 then Exit(False);
      instr := Default(TIRInstr);
      instr.Op := irThrow;
      instr.Src1 := t0;
      Emit(instr);
      Exit(True);
    end;

    // var a, b := f() — tuple multi-return destructuring
    if stmt is TAstTupleVarDecl then
    begin
      with TAstTupleVarDecl(stmt) do
      begin
        if (Length(Names) = 2) and (InitExpr is TAstCall) then
        begin
          call := TAstCall(InitExpr);
          argCount := Length(call.Args);
          SetLength(argTemps, argCount);
          for i := 0 to High(call.Args) do
            argTemps[i] := LowerExpr(call.Args[i]);
          // irCallStruct stores RAX→slot[b+1]=a, RDX→slot[b]=b
          // allocate b first (lower slot index = higher address), then a
          loc := AllocLocal(Names[1], atInt64); // slot N   → RDX (second return)
          AllocLocal(Names[0], atInt64);        // slot N+1 → RAX (first return)
          instr := Default(TIRInstr);
          instr.Op := irCallStruct;
          instr.Dest := loc;  // base: RAX→loc+1, RDX→loc
          instr.ImmStr := call.Name;
          instr.ImmInt := argCount;
          instr.StructSize := 16;
          instr.CallMode := cmInternal;
          SetLength(instr.ArgTemps, argCount);
          for i := 0 to argCount - 1 do
            instr.ArgTemps[i] := argTemps[i];
          Emit(instr);
        end;
      end;
      Exit(True);
    end;

    FDiag.Error('lowering: unsupported statement', stmt.Span);
    Result := False;
  end;


{ DONE: Indirect Call Support (irVarCall)
  =========================================
  
  Indirect calls via function pointers are already supported.
  Implementation at line ~3257:
    - TAstCall.IsIndirectCall is checked
    - Function pointer is loaded via irLoadLocal/irLoadGlobal
    - Indirect call is emitted via irVarCall
  
  Backend support exists in:
    - x86_64_emit.pas (line 5857): indirect call via 'call rax'
    - x86_64_win64.pas (line 2828)
    - arm64_emit.pas (line 2533)
    - macosx64_emit.pas (line 1196)
    - win_arm64_emit.pas (line 1502)
}


end.
